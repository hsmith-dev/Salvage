import AppKit
import Foundation
import Observation
import SalvageCore
import SalvageDiskIO

/// spec-tech-batch-7 §A: a disk image file opened in the app ("File > Open Disk Image…" or a drop
/// on the device list). It is listed under "Disk images" and scanned like a drive, always
/// read-only:
///
/// - a raw image is read straight from the file (`ImageFileReader`, O_RDONLY + pread);
/// - a UDIF `.dmg` or sparse image is attached by `hdiutil` read-only and unmounted
///   (`-readonly -nomount -noverify -noautofsck`) when its scan starts, read through
///   `RawBlockReader` like any drive, and detached when its session closes (or the app quits).
///
/// Its `device` is a stand-in `BlockDevice` whose name ("image-…") is never a BSD name, so no
/// drive code path (`RawBlockReader`, `DestinationSafety`) can ever act on it by mistake; the
/// runner and the destination check look the image up by that id instead.
struct OpenedDiskImage: Identifiable, Equatable, Sendable {
    let id: String
    let url: URL
    let format: DiskImageFormat
    let sizeBytes: Int64
    let identity: FileIdentity

    var name: String { url.lastPathComponent }

    var device: BlockDevice {
        BlockDevice(bsdName: id, displayName: name, sizeBytes: sizeBytes, isInternal: false, isBootVolume: false)
    }

    static func isImageDeviceID(_ id: String) -> Bool { id.hasPrefix("image-") }
}

/// The images opened this launch, by device id, readable from any thread (the scan runner and the
/// recovery destination check run off the main actor). Entries are never forgotten, so results
/// from an image removed from the list still get the image's destination check.
final class DiskImageRegistry: @unchecked Sendable {
    static let shared = DiskImageRegistry()
    private let lock = NSLock()
    private var images: [String: OpenedDiskImage] = [:]
    private var attachments: [String: AttachedDiskImage] = [:]

    func register(_ image: OpenedDiskImage) { lock.withLock { images[image.id] = image } }
    func image(forDeviceID id: String) -> OpenedDiskImage? { lock.withLock { images[id] } }

    func track(_ attachment: AttachedDiskImage, for id: String) { lock.withLock { attachments[id] = attachment } }
    func untrack(_ id: String) { lock.withLock { _ = attachments.removeValue(forKey: id) } }
    var attached: [String: AttachedDiskImage] { lock.withLock { attachments } }
}

@MainActor @Observable
final class DiskImageLibrary {
    static let shared = DiskImageLibrary()

    private(set) var images: [OpenedDiskImage] = []
    /// The last open that failed, in plain language; cleared by the next successful open.
    private(set) var openError: String?
    /// Whole disks of images Salvage itself attached: hidden from the drive list, since the image
    /// is already listed under "Disk images".
    private(set) var hiddenDrives: Set<String> = []

    private let registry: DiskImageRegistry
    private var terminationObserver: (any NSObjectProtocol)?

    init(registry: DiskImageRegistry = .shared, detachOnQuit: Bool = true) {
        self.registry = registry
        guard detachOnQuit else { return }
        // A session still open at quit is detached here; its own close may never get to run.
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
            for attachment in DiskImageRegistry.shared.attached.values { DiskImageAttacher.live.detach(attachment) }
        }
    }

    /// Opens each file as a disk image; one already listed is not added twice.
    func open(_ urls: [URL]) {
        for url in urls { open(url) }
    }

    @discardableResult
    func open(_ url: URL) -> OpenedDiskImage? {
        let info: DiskImageInfo
        do { info = try DiskImageFile.inspect(url) } catch {
            openError = (error as? DiskImageOpenError)?.description ?? "Salvage couldn't open “\(url.lastPathComponent)”."
            return nil
        }
        openError = nil
        if let existing = images.first(where: { $0.identity == info.identity }) { return existing }
        let image = OpenedDiskImage(id: "image-\(UUID().uuidString)", url: info.url, format: info.format,
                                    sizeBytes: info.sizeBytes, identity: info.identity)
        registry.register(image)
        images.append(image)
        return image
    }

    func remove(_ id: OpenedDiskImage.ID) {
        images.removeAll { $0.id == id }
    }

    func image(withDeviceID id: String) -> OpenedDiskImage? { images.first { $0.id == id } }

    fileprivate func setHidden(_ disks: Set<String>, hidden: Bool) {
        if hidden { hiddenDrives.formUnion(disks) } else { hiddenDrives.subtract(disks) }
    }

    /// "File > Open Disk Image…": the system open panel, any file (raw images have no fixed type).
    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.title = "Open Disk Image"
        panel.message = "Choose a disk image to scan. Salvage only reads it and never changes it."
        panel.prompt = "Open"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.treatsFilePackagesAsDirectories = false
        guard panel.runModal() == .OK else { return }
        open(panel.urls)
    }

    // MARK: Scanning

    /// The scan runner: an opened image's scan is read from the image; any other device goes to
    /// `otherwise` (the live drive runner, or a UI-test fixture's).
    nonisolated static func runner(registry: DiskImageRegistry = .shared, attacher: DiskImageAttacher = .live,
                                   otherwise: @escaping ScanViewModel.Runner) -> ScanViewModel.Runner {
        { run, events in
            guard OpenedDiskImage.isImageDeviceID(run.device.id) else { return try await otherwise(run, events) }
            guard let image = registry.image(forDeviceID: run.device.id) else {
                throw ScanError.io("This disk image is no longer open. Open it again to scan it.")
            }
            try await scan(image, run: run, events: events, registry: registry, attacher: attacher)
        }
    }

    nonisolated private static func scan(_ image: OpenedDiskImage, run: ScanRun, events: AsyncStream<ScanEvent>.Continuation,
                                         registry: DiskImageRegistry, attacher: DiskImageAttacher) async throws {
        let reader: any BlockReader
        let close: @Sendable () async -> Void
        switch image.format {
        case .raw:
            let file: ImageFileReader
            do { file = try ImageFileReader(path: image.url.path) } catch {
                throw ScanError.io("Salvage couldn't read “\(image.name)”. Check that the file is still there.")
            }
            reader = file
            close = { file.close() }
        case .attachable:
            let attachment: AttachedDiskImage
            do { attachment = try attacher.attach(image.url) } catch {
                throw ScanError.io((error as? DiskImageOpenError)?.description ?? "macOS couldn't open “\(image.name)” as a disk image.")
            }
            registry.track(attachment, for: image.id)
            await MainActor.run { DiskImageLibrary.shared.setHidden(attachment.allWholeDisks, hidden: true) }
            let detach: @Sendable () async -> Void = {
                attacher.detach(attachment)
                registry.untrack(image.id)
                await MainActor.run { DiskImageLibrary.shared.setHidden(attachment.allWholeDisks, hidden: false) }
            }
            do {
                guard let device = DiskImageAttacher.device(for: attachment, displayName: image.name) else { throw ScanError.deviceChanged }
                let raw = try await RawBlockReader.prepare(device: device)
                reader = raw
                close = { await raw.close(); await detach() }
            } catch {
                await detach()
                throw error
            }
        }
        await ScanSession(reader: reader).run(events: events, pauseGate: run.pauseGate, checkpoints: run.checkpoints,
                                              notices: run.notices, resumingFrom: run.resumeFrom, device: run.device,
                                              credentials: run.credentials)
        let decryptors = run.credentials.compactMapValues(\.decryptor)
        for credential in run.credentials.values { credential.zero() }
        await run.keepSource(SourceSession(device: run.device, reader: reader, decryptors: decryptors, close: close))
    }

    // MARK: Recovery

    /// The destination check for an image's results: refuse the drive holding the image file
    /// (`DiskImageDestinationSafety`). Nil for a drive, which keeps its own check.
    nonisolated static func destinationCheck(for device: BlockDevice, registry: DiskImageRegistry = .shared,
                                             safety: DiskImageDestinationSafety = .live) -> (@Sendable (URL) -> DestinationAssessment)? {
        guard OpenedDiskImage.isImageDeviceID(device.id) else { return nil }
        guard let image = registry.image(forDeviceID: device.id) else {
            return { _ in DestinationAssessment(verdict: .undetermined, mountSource: nil) }
        }
        let file = image.url
        return { safety.assess(destination: $0, imageFile: file) }
    }

    // MARK: UI tests

    #if DEBUG
    /// `-SalvageUITestOpenImage <path>` (DEBUG only): writes the UI-test fixture's exFAT volume to
    /// `<path>` (a temporary file the test owns) and opens it as a raw disk image, standing in for
    /// the open panel. The scan then reads the real file through `ImageFileReader`.
    static let uiTestImageArgument = "-SalvageUITestOpenImage"

    func openUITestImageIfRequested(arguments: [String] = ProcessInfo.processInfo.arguments) {
        guard let index = arguments.firstIndex(of: Self.uiTestImageArgument), arguments.indices.contains(index + 1) else { return }
        let url = URL(fileURLWithPath: arguments[index + 1])
        let bytes = ExFATFixtureImage.build(files: UITestFixture.files(), sizeBytes: 8 * 1024 * 1024)
        guard (try? bytes.write(to: url)) != nil else { return }
        open(url)
    }
    #endif
}
