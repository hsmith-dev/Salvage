import AppKit
import SalvageCore
import SalvageDiskIO
import SwiftUI

/// spec-tech-batch-7 §B: File → Open Scan… and Save Scan…, for the focused window's scan.
struct ScanArchiveCommands: Commands {
    @FocusedValue(\.scanArchiveTarget) private var scan

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Open Scan…") { if let scan { ScanArchiveActions.open(into: scan) } }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(scan == nil || scan?.isActive == true)
            Button("Save Scan…") { if let scan { ScanArchiveActions.save(scan) } }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!(scan?.canSaveArchive ?? false))
        }
    }
}

struct ScanArchiveTargetKey: FocusedValueKey { typealias Value = ScanViewModel }

extension FocusedValues {
    /// The window's scan, published by `ContentView` for `ScanArchiveCommands`.
    var scanArchiveTarget: ScanViewModel? {
        get { self[ScanArchiveTargetKey.self] }
        set { self[ScanArchiveTargetKey.self] = newValue }
    }
}

/// Saving goes only where the user chooses in the save panel, which carries the one privacy
/// warning (`ScanArchive.privacyNotice`). A DEBUG build launched with a UI-test fixture and
/// `-SalvageUITestArchive <path>` uses that path instead of either panel.
@MainActor enum ScanArchiveActions {
    static func save(_ scan: ScanViewModel) {
        guard var archive = scan.makeArchive(), let url = saveURL(suggesting: archive.device.displayName) else { return }
        // A reopened scan's small NTFS files stay marked as living in their MFT records.
        if let token = scan.reopened?.token { archive.residentRecords = ReopenedArchives.residentRecords(for: token) }
        let finished = archive
        Task {
            do { try await Task.detached(priority: .userInitiated) { try finished.write(to: url) }.value }
            catch { alert("Couldn't save the scan.", detail: describe(error)) }
        }
    }

    static func open(into scan: ScanViewModel) {
        guard !scan.isActive, let url = openURL() else { return }
        Task {
            do {
                let archive = try await Task.detached(priority: .userInitiated) { try ScanArchive.read(from: url) }.value
                scan.openArchive(archive)
                if let token = scan.reopened?.token { ReopenedArchives.register(archive.residentRecords, for: token) }
            } catch { alert("Couldn't open this saved scan.", detail: describe(error)) }
        }
    }

    private static func saveURL(suggesting name: String) -> URL? {
        if let preset = presetURL { return preset }
        let panel = NSSavePanel()
        panel.title = "Save Scan"
        panel.prompt = "Save"
        panel.message = ScanArchive.privacyNotice
        panel.nameFieldStringValue = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        panel.allowedContentTypes = [ScanArchive.contentType]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, var url = panel.url else { return nil }
        if url.pathExtension.lowercased() != ScanArchive.fileExtension { url.appendPathExtension(ScanArchive.fileExtension) }
        return url
    }

    private static func openURL() -> URL? {
        if let preset = presetURL { return preset }
        // A `.salvagescan` package is a folder that macOS doesn't know as a package type, so folders
        // stay browsable and only a `.salvagescan` one can be opened.
        let panel = NSOpenPanel()
        let delegate = OpenPanelDelegate()
        panel.title = "Open Scan"
        panel.prompt = "Open"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.delegate = delegate
        let response = withExtendedLifetime(delegate) { panel.runModal() }
        guard response == .OK else { return nil }
        return panel.url
    }

    private static var presetURL: URL? {
        #if DEBUG
        guard UITestFixture.active != nil else { return nil }
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-SalvageUITestArchive"), arguments.indices.contains(index + 1) else { return nil }
        return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        #else
        return nil
        #endif
    }

    private static func describe(_ error: Error) -> String {
        (error as? ScanArchiveError)?.description ?? ScanArchiveError.couldNotWrite("").description
    }

    private static func alert(_ message: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.runModal()
    }
}

@MainActor private final class OpenPanelDelegate: NSObject, NSOpenSavePanelDelegate {
    func panel(_ sender: Any, validate url: URL) throws {
        guard url.pathExtension.lowercased() == ScanArchive.fileExtension else {
            throw NSError(domain: "Salvage", code: 1, userInfo: [NSLocalizedDescriptionKey: "Choose a saved scan, a file ending in .\(ScanArchive.fileExtension)."])
        }
    }
}

/// What a reopened scan remembers beyond its files: which of them are NTFS resident data kept as
/// runs inside their MFT records (`ScanArchive.residentRecords`), by the reopening's token. The
/// view model holds only files, so this rides alongside it for the reconnect and a later save.
@MainActor enum ReopenedArchives {
    private static var entries: [(token: UUID, records: [UUID: Int])] = []
    private static let kept = 16

    static func register(_ records: [UUID: Int], for token: UUID) {
        entries.removeAll { $0.token == token }
        entries.append((token, records))
        if entries.count > kept { entries.removeFirst(entries.count - kept) }
    }

    static func residentRecords(for token: UUID) -> [UUID: Int] {
        entries.last { $0.token == token }?.records ?? [:]
    }
}

/// Opens a reconnected device for a saved scan, read-only, exactly as a scan does. Reads of a
/// resident file's runs pass through `ResidentRecordGuard`, so they are served only after its MFT
/// record has been re-read and found to still hold that file.
enum ScanArchiveSource {
    @Sendable static func open(_ device: BlockDevice) async throws -> SourceSession {
        try await open(device, guarding: [])
    }

    static func open(_ device: BlockDevice, guarding entries: [ResidentRecordGuard.Entry]) async throws -> SourceSession {
        #if DEBUG
        if let fixture = UITestFixture.active {
            let reader = ResidentRecordGuard.wrapping(InMemoryArchiveReader(data: fixture.image), entries: entries)
            return SourceSession(device: device, reader: reader, close: {})
        }
        #endif
        let raw = try await RawBlockReader.prepare(device: device)
        return SourceSession(device: device, reader: ResidentRecordGuard.wrapping(raw, entries: entries),
                             close: { await raw.close() })
    }
}

/// A reader for a reconnected device that checks each resident NTFS file's MFT record before any
/// read touches it (`NTFSResidentData.revalidate`: the same record number, name, date, size, and
/// runs that still map its resident data). A record that no longer holds its file makes every
/// read overlapping it fail with "Rescan to recover this file." instead of returning other bytes.
/// Verdicts are kept for the session; other reads pass straight through.
struct ResidentRecordGuard: BlockReader {
    struct Entry: Sendable {
        let file: RecoveredFile
        let recordBytes: Int
        var range: Range<Int64> { file.sourceMetadata.recordOffset..<file.sourceMetadata.recordOffset + Int64(recordBytes) }
    }

    let base: any BlockReader
    private let entries: [Entry]
    private let verdicts = Verdicts()
    var sizeBytes: Int64 { base.sizeBytes }
    var logicalBlockSize: Int { base.logicalBlockSize }

    /// `base` itself when there is nothing to guard.
    static func wrapping(_ base: any BlockReader, entries: [Entry]) -> any BlockReader {
        entries.isEmpty ? base : ResidentRecordGuard(base: base, entries: entries)
    }

    init(base: any BlockReader, entries: [Entry]) {
        self.base = base
        self.entries = entries.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    /// The guarded files of a reopened scan.
    static func entries(files: [RecoveredFile], residentRecords: [UUID: Int]) -> [Entry] {
        guard !residentRecords.isEmpty else { return [] }
        return files.compactMap { file in
            guard let bytes = residentRecords[file.id], file.sourceMetadata.recordOffset >= 0,
                  file.sourceMetadata.recordOffset <= Int64.max - Int64(bytes) else { return nil }
            return Entry(file: file, recordBytes: bytes)
        }
    }

    func read(at offset: Int64, count: Int) async throws -> Data {
        let (end, overflow) = offset.addingReportingOverflow(Int64(max(count, 0)))
        guard !overflow else { throw ScanError.io("Read outside the device.") }
        // Records don't overlap, so ranges are sorted by both bounds: find the first that ends past
        // `offset`, then walk while they start before `end`.
        var low = 0, high = entries.count
        while low < high {
            let mid = (low + high) / 2
            if entries[mid].range.upperBound <= offset { low = mid + 1 } else { high = mid }
        }
        var index = low
        while index < entries.count, entries[index].range.lowerBound < end {
            guard await verdicts.holds(entries[index], on: base) else { throw ScanError.io(ScanArchive.rescanToRecover) }
            index += 1
        }
        return try await base.read(at: offset, count: count)
    }

    private actor Verdicts {
        private var known: [UUID: Bool] = [:]
        func holds(_ entry: Entry, on reader: any BlockReader) async -> Bool {
            if let verdict = known[entry.file.id] { return verdict }
            let verdict = await NTFSResidentData.revalidate(entry.file, recordBytes: entry.recordBytes, reader: reader)
            known[entry.file.id] = verdict
            return verdict
        }
    }
}

#if DEBUG
/// The UI-test fixture image, read from memory (no device).
private struct InMemoryArchiveReader: BlockReader {
    let data: Data
    var sizeBytes: Int64 { Int64(data.count) }
    func read(at offset: Int64, count: Int) async throws -> Data {
        guard offset >= 0, count >= 0, offset <= sizeBytes, Int64(count) <= sizeBytes - offset else {
            throw ScanError.io("Read outside the fixture image.")
        }
        return data.subdata(in: Int(offset)..<Int(offset) + count)
    }
}
#endif

/// Above a reopened scan's results (stacked above them in `ResultsView`, not a safe-area inset,
/// which pushed the File Browser's header out of the window): what it takes to preview or recover again. It watches the
/// attached devices and offers Reconnect once one is the same drive (`ScanArchive.admits`: the
/// same attachment, or the same replug-stable identity, and the saved size); the
/// fingerprint check then runs in `ScanViewModel.reconnect`. Reconnecting is the user's choice,
/// because opening the device unmounts its volumes, as a scan does.
struct SavedScanBanner: View {
    let scan: ScanViewModel
    @State private var candidate: BlockDevice?
    @State private var openFailed = false

    var body: some View {
        if let reopened = scan.reopened, let device = scan.device {
            VStack(alignment: .leading, spacing: 6) {
                if reopened.status != .connected {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(Self.message(reopened.status, device: device.displayName, openFailed: openFailed))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("reconnect-message")
                        if reopened.status == .checking { ProgressView().controlSize(.small) }
                        if reopened.status == .waiting, let candidate {
                            Button("Reconnect") { reconnect(candidate) }
                                .help("Salvage checks that this is the same drive before reading from it.")
                                .accessibilityIdentifier("reconnect-source")
                        }
                    }
                }
                if reopened.hasEncryptedFiles {
                    Text("Files on encrypted volumes need the password again. Scan \(device.displayName) again and unlock it to preview or recover them.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
            .task(id: reopened.token) { await watch(for: device) }
        }
    }

    static func message(_ status: ScanViewModel.ReopenedScan.Status, device: String, openFailed: Bool) -> String {
        switch status {
        case .waiting, .connected:
            openFailed ? "Salvage couldn't open \(device). Check that it's connected, then try again."
                       : "Reconnect \(device) to preview or recover these files."
        case .checking: "Checking that this is the same \(device)…"
        case .changed: "\(device) has changed since this scan was saved, so Salvage won't read from it. Scan it again to preview or recover files."
        case .unverifiable: "This scan stopped before Salvage mapped \(device), so it can't be reconnected. Scan the drive again to preview or recover files."
        }
    }

    private func reconnect(_ device: BlockDevice) {
        openFailed = false
        let records = scan.reopened.map { ReopenedArchives.residentRecords(for: $0.token) } ?? [:]
        let entries = ResidentRecordGuard.entries(files: scan.files, residentRecords: records)
        Task {
            openFailed = await scan.reconnect(device, open: { try await ScanArchiveSource.open($0, guarding: entries) }) == .unavailable
        }
    }

    private func watch(for device: BlockDevice) async {
        candidate = nil
        guard let stream = try? await CompositionRoot.deviceWatcher().watch() else { return }
        for await devices in stream {
            candidate = devices.first { ScanArchive.admits($0, for: device) }
        }
    }
}
