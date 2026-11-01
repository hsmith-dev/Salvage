import SalvageCore
import SalvageDiskIO
import SwiftUI

/// The composition root is the only place connecting a platform reader to the Core engine.
struct ContentView: View {
    @State private var scan: ScanViewModel
    init() {
        _scan = State(initialValue: ScanViewModel(runner: Self.runScan, checkpointStore: .applicationSupport()))
    }
    nonisolated private static func runScan(run: ScanRun, events: AsyncStream<ScanEvent>.Continuation) async throws {
        let reader = try await RawBlockReader.prepare(device: run.device)
        await ScanSession(reader: reader).run(events: events, pauseGate: run.pauseGate,
                                              checkpoints: run.checkpoints,
                                              notices: run.notices,
                                              resumingFrom: run.resumeFrom, device: run.device)
        await run.keepSource(SourceSession(device: run.device, reader: reader, close: { await reader.close() }))
    }
    @State private var showsTrust = false
    /// Story 2.4: the FileVault unlock sheet, offered before scanning a device the picker knows is
    /// locked, and after a scan that met encrypted volumes. Withheld while
    /// `FileVaultUnlockFeature.canReadUnlockedVolumes` is off; the model then yields `guidance`.
    @State private var unlock = UnlockViewModel()
    var body: some View {
        NavigationSplitView {
            DeviceListView(isScanning: scan.isActive, activeDeviceID: scan.device?.id) { device in
                if !unlock.offerBeforeScan(device) { startAfterPendingUnlock(device) }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 280)
        } detail: {
            Group {
                if scan.state == .idle {
                    Text("Select a device to start scanning.").foregroundStyle(.secondary)
                } else if ResultsViewModel.showsResults(state: scan.state, isActive: scan.isActive, fileCount: scan.files.count) {
                    // A fresh results surface per finished scan.
                    ResultsView(scan: scan).id(scan.endedAt)
                } else { ScanProgressView(model: scan) }
            }
            .safeAreaInset(edge: .bottom) {
                if let guidance = unlock.guidance, scan.state != .idle { EncryptedVolumeNote(text: guidance) }
            }
        }
        // Closing the window stops the scan but keeps its checkpoint; only Cancel scan discards it.
        .onDisappear { scan.stopForTeardown() }
        .toolbar {
            Button("What Salvage reads and writes", systemImage: "info.circle") { showsTrust = true }
        }
        .trustPanel(isPresented: $showsTrust, isScanning: scan.isActive)
        .sheet(item: unlockRequest) { _ in FileVaultUnlockSheet(model: unlock) { device in startAfterPendingUnlock(device) } }
        // Every scan's encrypted volumes, each once per flow (queued by the model).
        .onChange(of: scan.endedAt) { _, ended in if ended != nil, !scan.isActive { unlock.offer(fromScan: scan.unlockRequests) } }
        .frame(minWidth: 760, minHeight: 480)
    }

    /// An unlock still in flight (e.g. Cancel pressed during "Unlocking…") finishes, and is
    /// relocked if Salvage unlocked it, before any scan starts.
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
