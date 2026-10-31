import SalvageCore
import SalvageDiskIO
import SwiftUI

struct ScanProgressView: View {
    let model: ScanViewModel
    var body: some View {
        let volumeLabels = model.sourceVolumeLabels
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title2)
            if let device = model.device { Text(device.displayName).foregroundStyle(.secondary) }
            if model.state == .resumable {
                resumeOffer
            } else if model.state == .preparing {
                HStack { ProgressView().controlSize(.small); Text("Preparing the device for read-only scanning…") }
            } else if model.totalBytes > 0 {
                ProgressView(value: Double(model.bytesScanned), total: Double(model.totalBytes))
                    .accessibilityLabel("Source bytes scanned")
                Text("\(Int(Double(model.bytesScanned) / Double(model.totalBytes) * 100))% of supported volume bytes read")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: 24) {
                    Text("Elapsed: \(duration(model.elapsed(at: context.date)))")
                    if model.state == .paused {
                        Text("Remaining: Paused")
                    } else if model.isActive {
                        Text("Remaining: \(model.estimatedRemaining(at: context.date).map(duration) ?? "Calculating…")")
                    }
                    Text("\(model.files.count) files indexed")
                }.font(.subheadline).foregroundStyle(.secondary)
            }
            if case .failed(let error) = model.state {
                let needsApproval = PrivilegedHelperApproval.isApprovalRequired(error)
                if needsApproval { HelperApprovalView() } else { Text(error.description).textSelection(.enabled) }
                if error == .permissionDenied || needsApproval || model.canRetryFromCheckpoint, !model.isActive, let device = model.device {
                    // With a kept checkpoint, retrying offers Resume again rather than starting from zero.
                    Button("Retry scan") { model.start(device) }
                }
            }
            Text("Files listed here have been indexed from intact metadata. No files have been copied or recovered.")
                .font(.subheadline).foregroundStyle(.secondary)
            List(model.files) { file in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(file.path).lineLimit(2).textSelection(.enabled)
                        if let volume = volumeLabels[file.sourceMetadata.volumeOffset] {
                            Text(volume).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: file.sizeBytes, countStyle: .file)).foregroundStyle(.secondary)
                }.accessibilityElement(children: .combine)
            }
            if model.state == .paused {
                Text("Scan paused. Salvage is not reading the device. Resume continues from the same point.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else if model.resumedFromCheckpoint, model.isActive {
                // Set only once the core's first progress shows it accepted the checkpoint.
                Text("Resumed from where the previous scan stopped.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            if model.isActive {
                HStack {
                    if model.state == .paused {
                        Button("Resume") { model.resume() }
                            .keyboardShortcut(.defaultAction)
                            .accessibilityHint("Continues scanning from the same point")
                    } else {
                        Button("Pause") { model.pause() }
                            .disabled(!model.canPause)
                            .accessibilityHint("Stops reading the device without ending the scan")
                    }
                    Button("Cancel scan") { model.cancel() }
                        .keyboardShortcut(.cancelAction)
                        .accessibilityHint("Stops scanning and keeps files already indexed")
                }
            }
        }.padding(24)
    }
    @ViewBuilder private var resumeOffer: some View {
        if let checkpoint = model.pendingCheckpoint {
            Text("A previous scan of this device stopped before it finished, at \(percent(checkpoint.bytesScanned, of: checkpoint.totalBytes))% of supported volume bytes. Resume to continue from there, or start over.")
            HStack {
                Button("Resume scan") { model.resumeInterruptedScan() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityHint("Rebuilds the file list and continues reading from where the previous scan stopped")
                Button("Start over") { model.startOver() }
                    .accessibilityHint("Discards the saved position and scans from the beginning")
            }
        }
    }
    private func percent(_ part: Int64, of whole: Int64) -> Int {
        whole > 0 ? Int(Double(part) / Double(whole) * 100) : 0
    }
    private var title: String {
        switch model.state {
        case .idle: "Select a device"
        case .preparing: "Preparing scan"
        case .running: "Scanning…"
        case .paused: "Paused"
        case .resumable: "Previous scan interrupted"
        case .completed: "Scan complete"
        case .cancelled: "Scan cancelled"
        case .failed: "Scan stopped"
        }
    }
    private func duration(_ seconds: TimeInterval) -> String {
        let value = Int(min(max(0, seconds), Double(Int.max / 2)))
        return value >= 3600 ? "\(value / 3600)h \(value % 3600 / 60)m" : "\(value / 60)m \(value % 60)s"
    }
}
