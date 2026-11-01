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
        guard let archive = scan.makeArchive(), let url = saveURL(suggesting: archive.device.displayName) else { return }
        Task {
            do { try await Task.detached(priority: .userInitiated) { try archive.write(to: url) }.value }
            catch { alert("Couldn't save the scan.", detail: describe(error)) }
        }
    }

    static func open(into scan: ScanViewModel) {
        guard !scan.isActive, let url = openURL() else { return }
        Task {
            do {
                let archive = try await Task.detached(priority: .userInitiated) { try ScanArchive.read(from: url) }.value
                scan.openArchive(archive)
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

/// Opens a reconnected device for a saved scan, read-only, exactly as a scan does.
enum ScanArchiveSource {
    @Sendable static func open(_ device: BlockDevice,
                               onAdministratorPasswordPrompt: @escaping @Sendable () async -> Void = {}) async throws -> SourceSession {
        #if DEBUG
        if let fixture = UITestFixture.active {
            let reader = InMemoryArchiveReader(data: fixture.image)
            return SourceSession(device: device, reader: reader, close: {})
        }
        #endif
        let reader = try await RawBlockReader.prepare(device: device, onAdministratorPasswordPrompt: onAdministratorPasswordPrompt)
        return SourceSession(device: device, reader: reader, close: { await reader.close() })
    }
}

/// Carries the banner's "asking for the password" update across to the main actor.
private struct PasswordPrompt: Sendable {
    let update: @MainActor () -> Void
    func show() async {
        await MainActor.run(body: update)
        // Let the explanation render before the dialog takes focus.
        try? await Task.sleep(for: ScanViewModel.passwordExplanationLead)
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
/// attached devices and offers Reconnect once one has the saved media identity and size; the
/// fingerprint check then runs in `ScanViewModel.reconnect`. Reconnecting is the user's choice,
/// because opening the device unmounts its volumes, as a scan does.
struct SavedScanBanner: View {
    let scan: ScanViewModel
    @State private var candidate: BlockDevice?
    @State private var openFailed = false
    /// spec-tech-authopen: macOS's password dialog is up, or was cancelled.
    @State private var password: PasswordStep?
    enum PasswordStep: Equatable { case asking, declined }

    var body: some View {
        if let reopened = scan.reopened, let device = scan.device {
            VStack(alignment: .leading, spacing: 6) {
                if reopened.status != .connected {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(Self.message(reopened.status, device: device.displayName, openFailed: openFailed, password: password))
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
                if password != nil, reopened.status != .connected {
                    Text(AdministratorPasswordExplanation.explanation)
                        .font(.subheadline).foregroundStyle(.inkSecondary)
                        .accessibilityIdentifier("reconnect-password-explanation")
                }
                if reopened.hasEncryptedFiles {
                    Text("Files on encrypted volumes need the password again. Scan \(device.displayName) again and unlock it to preview or recover them.")
                        .font(.subheadline).foregroundStyle(.inkSecondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
            .task(id: reopened.token) { await watch(for: device) }
        }
    }

    static func message(_ status: ScanViewModel.ReopenedScan.Status, device: String, openFailed: Bool,
                        password: PasswordStep? = nil) -> String {
        switch status {
        case .waiting where password == .declined:
            "Salvage needs your administrator password to read \(device). Click Reconnect to try again."
        case .waiting, .connected:
            openFailed ? "Salvage couldn't open \(device). Check that it's connected, then try again."
                       : "Reconnect \(device) to preview or recover these files."
        case .checking where password == .asking: "Waiting for your administrator password\u{2026}"
        case .checking: "Checking that this is the same \(device)…"
        case .changed: "\(device) has changed since this scan was saved, so Salvage won't read from it. Scan it again to preview or recover files."
        case .unverifiable: "This scan stopped before Salvage mapped \(device), so it can't be reconnected. Scan the drive again to preview or recover files."
        }
    }

    private func reconnect(_ device: BlockDevice) {
        openFailed = false
        password = nil
        let asking = PasswordPrompt { password = .asking }
        Task {
            let result = await scan.reconnect(device, open: { candidate in
                try await ScanArchiveSource.open(candidate, onAdministratorPasswordPrompt: { await asking.show() })
            })
            openFailed = result == .unavailable
            password = result == .needsAdministratorPassword ? .declined : nil
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
