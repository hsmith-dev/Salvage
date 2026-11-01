import SalvageCore
import SalvageDiskIO
import SwiftUI

/// The composition root is the only place connecting a platform reader to the Core engine.
struct ContentView: View {
    @State private var scan: ScanViewModel
    init() {
        let rescan: UnlockViewModel.Rescan
        #if DEBUG
        // UI tests only (`-SalvageUITestFixture`): in-memory fakes, no checkpoints saved.
        if let fixture = UITestFixture.active {
            // An opened disk image is read from its file; fixture drives from the fixture.
            let scan = ScanViewModel(runner: DiskImageLibrary.runner(otherwise: fixture.runScan), checkpointStore: nil)
            _scan = State(initialValue: scan)
            rescan = { device, credentials in Task { @MainActor in scan.start(device, credentials: credentials) } }
            _unlock = State(initialValue: UnlockViewModel(verify: fixture.verifyUnlock, rescan: rescan))
            return
        }
        #endif
        // spec-tech-batch-7 §A: an opened disk image is read from its file; drives as before.
        let scan = ScanViewModel(runner: DiskImageLibrary.runner(otherwise: Self.runScan), checkpointStore: .applicationSupport())
        _scan = State(initialValue: scan)
        rescan = { device, credentials in Task { @MainActor in scan.start(device, credentials: credentials) } }
        _unlock = State(initialValue: UnlockViewModel(
            verify: { device, credential in await Self.verifyUnlock(device, credential, source: await scan.source) },
            rescan: rescan))
    }
    nonisolated private static func runScan(run: ScanRun, events: AsyncStream<ScanEvent>.Continuation) async throws {
        let reader = try await RawBlockReader.prepare(device: run.device)
        await ScanSession(reader: reader).run(events: events, pauseGate: run.pauseGate,
                                              checkpoints: run.checkpoints,
                                              notices: run.notices,
                                              resumingFrom: run.resumeFrom, device: run.device,
                                              credentials: run.credentials)
        // Story 2.5: the unlocked volumes' keys stay with the session for preview and recovery;
        // every secret is zeroed now (they were already, once their keys were recorded).
        let decryptors = run.credentials.compactMapValues(\.decryptor)
        for credential in run.credentials.values { credential.zero() }
        await run.keepSource(SourceSession(device: run.device, reader: reader, decryptors: decryptors, close: { await reader.close() }))
    }

    /// Story 2.5: checks a password or recovery key against an encrypted volume by reading its
    /// keybags (no mount, no `diskutil`), through the finished scan's open session when it is of
    /// the same device, or a fresh read-only one otherwise.
    nonisolated private static func verifyUnlock(_ device: BlockDevice, _ credential: VolumeCredential,
                                                 source: SourceSession?) async -> Result<Void, UnlockError> {
        guard let uuid = device.encryptedVolumeUUID else { return .failure(.toolFailure) }
        if let source, source.device.id == device.id, source.device.mediaIdentity == device.mediaIdentity {
            return await EncryptedVolumeUnlock.verify(reader: source.reader, volumeUUID: uuid, credential: credential)
        }
        guard let reader = try? await RawBlockReader.prepare(device: device) else { return .failure(.toolFailure) }
        let result = await EncryptedVolumeUnlock.verify(reader: reader, volumeUUID: uuid, credential: credential)
        await reader.close()
        return result
    }
    @State private var showsTrust = false
    @State private var partitionRequest: PartitionRecoveryRequest?
    /// Story 2.4/2.5: the FileVault unlock sheet, offered before scanning a device the picker knows
    /// is locked, and after a scan that met encrypted volumes. A correct credential re-scans the
    /// device with the volume decrypted. Withheld while `FileVaultUnlockFeature.canReadUnlockedVolumes`
    /// is off; the model then yields `guidance`.
    @State private var unlock: UnlockViewModel
    var body: some View {
        NavigationSplitView {
            DeviceListView(isScanning: scan.isActive, activeDeviceID: scan.device?.id,
                           finishedScanDevice: scan.deviceWithFinishedResults,
                           onRecoverPartition: { partitionRequest = PartitionRecoveryRequest(partition: $0) }) { device in
                if !unlock.offerBeforeScan(device) { startAfterPendingUnlock(device) }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 280)
        } detail: {
            Group {
                if scan.state == .idle {
                    Text("Select a device to start scanning.").foregroundStyle(.secondary)
                } else if ResultsViewModel.showsResults(state: scan.state, isActive: scan.isActive, fileCount: scan.files.count) {
                    // A fresh results surface per finished scan.
                    ResultsView(scan: scan, partitionRequest: $partitionRequest).id(scan.endedAt)
                } else { ScanProgressView(model: scan) }
            }
            .safeAreaInset(edge: .bottom) {
                if let guidance = unlock.guidance, scan.state != .idle { EncryptedVolumeNote(text: guidance) }
            }
        }
        // Closing the window stops the scan but keeps its checkpoint; only Cancel scan discards it.
        // The unlock flow's keys go with the window (the session's own are dropped as it closes).
        .onDisappear { scan.stopForTeardown(); unlock.tearDown() }
        .toolbar {
            Button("What Salvage reads and writes", systemImage: "info.circle") { showsTrust = true }
        }
        .trustPanel(isPresented: $showsTrust, isScanning: scan.isActive)
        .sheet(item: unlockRequest) { _ in FileVaultUnlockSheet(model: unlock) { device in startAfterPendingUnlock(device) } }
        // Every scan's encrypted volumes, each once per flow (queued by the model).
        .onChange(of: scan.endedAt) { _, ended in if ended != nil, !scan.isActive { unlock.offer(fromScan: scan.unlockRequests) } }
        .frame(minWidth: 760, minHeight: 480)
    }

    /// A credential check still in flight (e.g. Cancel pressed during "Unlocking…", which cancels
    /// it) finishes before any scan starts.
    private func startAfterPendingUnlock(_ device: BlockDevice) {
        Task {
            await unlock.waitForPendingUnlock()
            scan.start(device)
        }
    }

    /// A system dismissal (should one get through) counts as Cancel, so a waiting scan still starts.
    private var unlockRequest: Binding<UnlockViewModel.Request?> {
        Binding(get: { unlock.request }, set: { value in
            if value == nil, let device = unlock.resolve() { startAfterPendingUnlock(device) }
        })
    }
}

/// The live adapters views reach for outside `ContentView` (the Device Picker's watcher and the
/// recovery flow's destination check and folder). Release builds always get the live ones; only a
/// DEBUG build launched with `-SalvageUITestFixture` gets the UI-test fakes (`UITestFixture`).
enum CompositionRoot {
    @MainActor static func deviceWatcher() -> any DeviceWatching {
        #if DEBUG
        if let fixture = UITestFixture.active { return fixture.deviceWatcher }
        #endif
        return DeviceWatcher()
    }

    @MainActor static func recoveryCoordinator(files: [RecoveredFile], source: SourceSession, rootName: String? = nil,
                                               reconstructedFiles: [RecoveredFile] = [],
                                               sourceLabel: String? = nil) -> RecoveryCoordinator {
        // spec-tech-batch-7 §A: an image's results refuse the drive that holds the image file.
        if let imageCheck = DiskImageLibrary.destinationCheck(for: source.device) {
            return RecoveryCoordinator(files: files, content: source.content, deviceName: source.device.displayName,
                                       rootName: rootName, reconstructedFiles: reconstructedFiles, sourceLabel: sourceLabel,
                                       destinationCheck: imageCheck)
        }
        #if DEBUG
        if let fixture = UITestFixture.active {
            return RecoveryCoordinator(files: files, content: source.content, deviceName: source.device.displayName,
                                       rootName: rootName, reconstructedFiles: reconstructedFiles, sourceLabel: sourceLabel,
                                       destinationCheck: fixture.destinationCheck)
        }
        #endif
        return RecoveryCoordinator(files: files, source: source, rootName: rootName,
                                   reconstructedFiles: reconstructedFiles, sourceLabel: sourceLabel)
    }

    /// A destination chosen in advance, replacing the folder picker; always nil in Release.
    static var presetDestination: URL? {
        #if DEBUG
        return UITestFixture.active?.destination
        #else
        return nil
        #endif
    }
}

/// Story 2.4: plain guidance while the unlock sheet is withheld (`FileVaultUnlockFeature`).
private struct EncryptedVolumeNote: View {
    let text: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "lock.fill").accessibilityHidden(true)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .accessibilityElement(children: .combine)
    }
}

#Preview { ContentView() }
