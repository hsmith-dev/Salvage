import Foundation
import Observation
import SalvageCore
import SalvageDiskIO

/// spec-tech-image-drive: "Image This Drive…" -- a byte-for-byte copy of a whole drive into a
/// `.img` file on a different drive, so a failing drive is read once and the image scanned as
/// often as needed.
///
/// The drive is only ever opened through `RawBlockReader.prepare` (boot-disk refusal, unmount,
/// read-only descriptor checks, the privileged helper), or by reusing a finished scan's session of
/// the same drive, which was opened that way. The image is written with plain file I/O into a new
/// file (`ImageOutputFile`); the copy loop itself is `DriveImager` in SalvageDiskIO.
struct DriveImagingEnvironment: Sendable {
    /// An open, read-only source and how to give it back.
    struct Source: Sendable {
        let reader: any BlockReader
        let close: @Sendable () async -> Void
    }

    var openSource: @Sendable (BlockDevice) async throws -> Source
    /// The destination folder's verdict against the drive (`DestinationSafety`).
    var assess: @Sendable (URL, BlockDevice) -> DestinationAssessment
    var freeSpace: @Sendable (URL) -> Int64?
    var filesystemType: @Sendable (URL) -> String?
    var imager = DriveImager()

    /// The live environment. `session` is the window's finished scan session: when it is of this
    /// same drive it already holds the drive's read reservation, so the image is read through it
    /// rather than opening the drive a second time.
    static func live(reusing session: SourceSession?) -> DriveImagingEnvironment {
        DriveImagingEnvironment(
            openSource: { device in
                #if DEBUG
                if UITestFixture.active != nil { throw ScanError.unsafeTarget("Imaging isn't available with UI-test fixtures.") }
                #endif
                if let session, session.device.id == device.id, session.device.mediaIdentity == device.mediaIdentity,
                   !session.isClosed {
                    return Source(reader: SessionImagingReader(session: session), close: {})
                }
                let reader = try await RawBlockReader.prepare(device: device)
                return Source(reader: reader, close: { await reader.close() })
            },
            assess: { folder, device in DestinationSafety.live.assess(destination: folder, source: device) },
            freeSpace: { RecoveryCoordinator.availableCapacity(at: $0) },
            filesystemType: { ImageOutputFile.filesystemType(ofPath: $0.resolvingSymlinksInPath().path) })
    }
}

/// A finished scan's reader, refusing to read once its session has closed (leaving results or
/// starting another scan), so a closed session ends the copy instead of reading as bad blocks.
struct SessionImagingReader: BlockReader {
    struct Closed: LocalizedError, CustomStringConvertible {
        var description: String { "The drive's read session was closed (another scan started or its results were closed)." }
        var errorDescription: String? { description }
    }

    let session: SourceSession
    var sizeBytes: Int64 { session.reader.sizeBytes }
    var logicalBlockSize: Int { session.reader.logicalBlockSize }

    func read(at offset: Int64, count: Int) async throws -> Data {
        guard !session.isClosed else { throw Closed() }
        do { return try await session.reader.read(at: offset, count: count) } catch {
            if session.isClosed { throw Closed() }
            throw error
        }
    }
}

/// What a finished (or stopped) imaging run left behind.
struct DriveImagingSummary: Equatable, Sendable {
    let outcome: ImagingOutcome
    let deviceName: String
    let imageURL: URL
    let sidecarURL: URL?
    /// Why the bad-block list couldn't be saved, if it couldn't.
    let sidecarError: String?
    let bytesCopied: Int64
    let totalBytes: Int64
    let unreadableBytes: Int64
    let badRanges: [ImagingBadRange]
    let sha256: String?
    let elapsed: TimeInterval

    var isComplete: Bool { outcome == .completed }

    var title: String {
        switch outcome {
        case .completed: "Image complete"
        case .cancelled: "Imaging canceled"
        case .stopped: "Imaging stopped"
        }
    }

    /// The plain-language note shown in the summary and saved in the sidecar.
    var note: String {
        let copied = DriveImagingFormat.bytes(bytesCopied), total = DriveImagingFormat.bytes(totalBytes)
        let partial = "The image file holds only the first \(copied) of \(total); the rest of the drive isn't in it, so a scan of it finds only what lies in that part. Image the drive again to get a full copy."
        switch outcome {
        case .completed where badRanges.isEmpty:
            return "Every sector of “\(deviceName)” was read. Scan the image instead of the drive from now on."
        case .completed:
            return "\(DriveImagingFormat.areas(badRanges.count)) (\(DriveImagingFormat.bytes(unreadableBytes))) couldn't be read and are zeros in the image. Everything else was copied. Scan the image instead of the drive from now on."
        case .cancelled:
            return "Imaging was canceled. \(partial)"
        case .stopped(let reason):
            return "\(reason) \(partial)"
        }
    }

    func report(device: BlockDevice, blockSize: Int, startedAt: Date, finishedAt: Date) -> ImagingReport {
        let status: ImagingReport.Status = switch outcome {
        case .completed: .complete
        case .cancelled: .cancelled
        case .stopped: .stopped
        }
        return ImagingReport(imageFile: imageURL.lastPathComponent, sourceName: device.displayName, sourceDevice: device.bsdName,
                             sourceSizeBytes: totalBytes, blockSize: blockSize, status: status, note: note,
                             bytesCopied: bytesCopied, unreadableBytes: unreadableBytes, badRanges: badRanges,
                             sha256: sha256, startedAt: startedAt, finishedAt: finishedAt)
    }
}

enum DriveImagingFormat {
    static func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }
    static func areas(_ count: Int) -> String { count == 1 ? "1 area" : "\(count) areas" }

    static func speed(_ bytesPerSecond: Double) -> String {
        "\(ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond.rounded()), countStyle: .file))/s"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let value = Int(min(max(0, seconds), Double(Int.max / 2)).rounded())
        if value >= 3600 { return "\(value / 3600) h \(value % 3600 / 60) min" }
        if value >= 60 { return "\(value / 60) min \(value % 60) s" }
        return "\(value) s"
    }

    /// The suggested file name for a drive's image: its name, without characters a file name
    /// can't hold, plus ".img".
    static func suggestedFileName(for device: BlockDevice) -> String {
        let cleaned = device.displayName
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (cleaned.isEmpty ? device.bsdName : cleaned) + ".img"
    }
}

/// One imaging run, shown by `ImageDriveSheet`.
@MainActor @Observable
final class DriveImagingModel: Identifiable {
    enum Phase: Equatable {
        /// Checking the destination and opening the drive.
        case checking
        case copying
        case finished(DriveImagingSummary)
        /// The destination is on the drive being imaged (DESIGN.md's one blocking state).
        case blocked(String)
        /// Nothing was written (the destination or the drive was refused).
        case failed(String)
    }

    let id = UUID()
    let device: BlockDevice
    let destination: URL
    let replacingConfirmed: Bool
    private(set) var phase: Phase = .checking
    private(set) var progress: ImagingProgress
    private(set) var copyStartedAt: Date?
    private var samples: [(time: Date, bytes: Int64)] = []
    private var task: Task<Void, Never>?
    private let environment: DriveImagingEnvironment

    init(device: BlockDevice, destination: URL, replacingConfirmed: Bool, environment: DriveImagingEnvironment) {
        self.device = device
        self.destination = destination
        self.replacingConfirmed = replacingConfirmed
        self.environment = environment
        self.progress = ImagingProgress(totalBytes: device.sizeBytes)
    }

    var isActive: Bool {
        switch phase {
        case .checking, .copying: true
        case .finished, .failed, .blocked: false
        }
    }

    private(set) var cancelRequested = false
    var isCancelling: Bool { cancelRequested && isActive }

    func start() {
        guard task == nil else { return }
        let device = device, destination = destination, replacing = replacingConfirmed, environment = environment
        // The run keeps the model alive until it ends (the sheet may close first only once it has).
        task = Task.detached(priority: .userInitiated) { [self] in
            let phase = await Self.perform(device: device, destination: destination, replacingConfirmed: replacing,
                                           environment: environment,
                                           copying: { await self.beginCopying() },
                                           progress: { value in Task { @MainActor in self.record(value) } })
            await self.finish(phase)
        }
    }

    /// Stops the copy after the current read; what was written stays in the file.
    func cancel() {
        guard isActive else { return }
        cancelRequested = true
        task?.cancel()
    }

    /// Waits for the run to end (tests).
    func waitUntilFinished() async { await task?.value }

    private func beginCopying() {
        phase = .copying
        copyStartedAt = Date()
    }

    private func record(_ value: ImagingProgress) {
        guard isActive, value.bytesDone >= progress.bytesDone else { return }
        progress = value
        let now = Date()
        samples.append((now, value.bytesDone))
        samples.removeAll { now.timeIntervalSince($0.time) > 10 }
    }

    private func finish(_ final: Phase) {
        if case .finished(let summary) = final {
            progress = ImagingProgress(bytesDone: summary.bytesCopied, totalBytes: summary.totalBytes,
                                       unreadableBytes: summary.unreadableBytes, badRangeCount: summary.badRanges.count)
        }
        phase = final
    }

    /// Recent copy speed (bytes per second) over the last few seconds, once there is enough to say.
    func speed(at now: Date = Date()) -> Double? {
        let recent = samples.filter { now.timeIntervalSince($0.time) <= 5 }
        guard let first = recent.first, let last = recent.last, last.time.timeIntervalSince(first.time) >= 1 else {
            guard let started = copyStartedAt, now.timeIntervalSince(started) >= 2, progress.bytesDone > 0 else { return nil }
            return Double(progress.bytesDone) / now.timeIntervalSince(started)
        }
        return Double(last.bytes - first.bytes) / last.time.timeIntervalSince(first.time)
    }

    func remaining(at now: Date = Date()) -> TimeInterval? {
        guard let speed = speed(at: now), speed > 0 else { return nil }
        return Double(progress.totalBytes - progress.bytesDone) / speed
    }

    func elapsed(at now: Date = Date()) -> TimeInterval { copyStartedAt.map { now.timeIntervalSince($0) } ?? 0 }

    // MARK: The run

    nonisolated static let sameDriveMessage = "This destination is on the drive you're imaging. Choose a folder on a different drive."
    nonisolated static let undeterminedMessage = "Salvage couldn't confirm that this destination is on a different drive from the one you're imaging, so it was refused. Choose a folder on another drive."

    nonisolated static func perform(device: BlockDevice, destination: URL, replacingConfirmed: Bool,
                                    environment: DriveImagingEnvironment,
                                    copying: @Sendable () async -> Void,
                                    progress: @escaping @Sendable (ImagingProgress) -> Void) async -> Phase {
        let folder = destination.deletingLastPathComponent()
        let assessment = environment.assess(folder, device)
        switch assessment.verdict {
        case .safe: break
        case .sameDevice: return .blocked(sameDriveMessage)
        case .undetermined: return .failed(undeterminedMessage)
        }
        if let type = environment.filesystemType(folder), let limit = ImageOutputFile.maximumFileSize(filesystemType: type),
           device.sizeBytes > limit {
            return .failed("The destination drive is formatted MS-DOS (FAT), which can't hold a file larger than 4 GB, and this image is \(DriveImagingFormat.bytes(device.sizeBytes)). Choose a drive formatted APFS, Mac OS Extended or exFAT.")
        }
        guard let free = environment.freeSpace(folder) else {
            return .failed("Salvage couldn't read how much free space the destination has, so it didn't start. Choose a folder on another drive.")
        }
        // A file the save panel confirmed replacing frees its space when it is replaced.
        let replaced = replacingConfirmed ? existingRegularFileSize(destination) : 0
        let (sum, overflow) = max(0, free).addingReportingOverflow(replaced)
        let available = overflow ? Int64.max : sum
        guard available >= device.sizeBytes else {
            return .failed("The image needs \(DriveImagingFormat.bytes(device.sizeBytes)) of free space, but the destination has only \(DriveImagingFormat.bytes(available)). Choose a drive with more free space.")
        }
        if Task.isCancelled { return .failed("Canceled. Nothing was copied.") }

        let source: DriveImagingEnvironment.Source
        do { source = try await environment.openSource(device) } catch is CancellationError {
            return .failed("Canceled. Nothing was copied.")
        } catch {
            return .failed(describe(error))
        }
        guard source.reader.sizeBytes == device.sizeBytes else {
            await source.close()
            return .failed(ScanError.deviceChanged.description)
        }
        let output: ImageOutputFile
        do { output = try ImageOutputFile(creating: destination, replacingConfirmed: replacingConfirmed, checked: assessment) } catch {
            await source.close()
            return .failed(describe(error))
        }
        await copying()
        let started = Date()
        let result = await environment.imager.run(reader: source.reader, sink: output, progress: progress)
        output.close()
        await source.close()
        let finished = Date()

        var summary = DriveImagingSummary(
            outcome: result.outcome, deviceName: device.displayName, imageURL: output.url, sidecarURL: output.sidecarURL,
            sidecarError: nil, bytesCopied: result.progress.bytesDone, totalBytes: result.progress.totalBytes,
            unreadableBytes: result.progress.unreadableBytes, badRanges: result.badRanges, sha256: result.sha256,
            elapsed: finished.timeIntervalSince(started))
        do {
            try output.writeSidecar(summary.report(device: device, blockSize: source.reader.logicalBlockSize,
                                                   startedAt: started, finishedAt: finished))
        } catch {
            summary = DriveImagingSummary(
                outcome: summary.outcome, deviceName: summary.deviceName, imageURL: summary.imageURL, sidecarURL: nil,
                sidecarError: describe(error), bytesCopied: summary.bytesCopied, totalBytes: summary.totalBytes,
                unreadableBytes: summary.unreadableBytes, badRanges: summary.badRanges, sha256: summary.sha256,
                elapsed: summary.elapsed)
        }
        return .finished(summary)
    }

    nonisolated private static func existingRegularFileSize(_ url: URL) -> Int64 {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return 0 }
        return Int64(info.st_size)
    }

    nonisolated static func describe(_ error: any Error) -> String {
        if let error = error as? ScanError {
            if error == .deviceInUse { return "This drive is in use by a scan. Wait for the scan to finish or cancel it, then try again." }
            return error.description
        }
        if let error = error as? ImageOutputError { return error.description }
        if let error = error as? SessionImagingReader.Closed { return error.description }
        return error.localizedDescription
    }
}
