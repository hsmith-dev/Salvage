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
                                              checkpoints: run.checkpoints, resumingFrom: run.resumeFrom, device: run.device)
        await run.keepSource(SourceSession(device: run.device, reader: reader, close: { await reader.close() }))
    }
    @State private var showsTrust = false
    /// Story 2.4: the FileVault unlock sheet, offered before scanning a device the picker knows is
    /// locked, and after a scan that met encrypted volumes.
    @State private var unlock = UnlockViewModel()
    var body: some View {
        NavigationSplitView {
            DeviceListView(isScanning: scan.isActive, activeDeviceID: scan.device?.id) { device in
                if !unlock.offerBeforeScan(device) { scan.start(device) }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 280)
        } detail: {
            if scan.state == .idle {
                Text("Select a device to start scanning.").foregroundStyle(.secondary)
            } else if ResultsViewModel.showsResults(state: scan.state, isActive: scan.isActive, fileCount: scan.files.count) {
                // A fresh results surface per finished scan.
                ResultsView(scan: scan).id(scan.endedAt)
            } else { ScanProgressView(model: scan) }
        }
        // Closing the window stops the scan but keeps its checkpoint; only Cancel scan discards it.
        .onDisappear { scan.stopForTeardown() }
        .toolbar {
            Button("What Salvage reads and writes", systemImage: "info.circle") { showsTrust = true }
        }
        .trustPanel(isPresented: $showsTrust, isScanning: scan.isActive)
        .sheet(item: unlockRequest) { _ in FileVaultUnlockSheet(model: unlock) { device in scan.start(device) } }
        .onChange(of: scan.isActive) { _, active in if !active { unlock.offer(fromScan: scan.unlockRequests) } }
        .frame(minWidth: 760, minHeight: 480)
    }

    /// A system dismissal (should one get through) counts as Cancel, so a waiting scan still starts.
    private var unlockRequest: Binding<UnlockViewModel.Request?> {
        Binding(get: { unlock.request }, set: { value in
            if value == nil, let device = unlock.resolve() { scan.start(device) }
        })
    }
}

#Preview { ContentView() }
