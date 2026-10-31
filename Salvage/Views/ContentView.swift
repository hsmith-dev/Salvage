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
                                              checkpoints: run.checkpoints, resumingFrom: run.resumeFrom)
        await reader.close()
    }
    @State private var showsTrust = false
    var body: some View {
        NavigationSplitView {
            DeviceListView(isScanning: scan.isActive, activeDeviceID: scan.device?.id) { device in scan.start(device) }
                .navigationSplitViewColumnWidth(min: 220, ideal: 280)
        } detail: {
            if scan.state == .idle {
                Text("Select a device to start scanning.").foregroundStyle(.secondary)
            } else { ScanProgressView(model: scan) }
        }
        .onDisappear { scan.cancel() }
        .toolbar {
            Button("What Salvage reads and writes", systemImage: "info.circle") { showsTrust = true }
        }
        .trustPanel(isPresented: $showsTrust, isScanning: scan.isActive)
        .frame(minWidth: 760, minHeight: 480)
    }
}

#Preview { ContentView() }
