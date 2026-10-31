import SalvageCore
import SwiftUI

struct ScanProgressView: View {
    let model: ScanViewModel
    var body: some View {
        let volumeLabels = model.sourceVolumeLabels
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title2)
            if let device = model.device { Text(device.displayName).foregroundStyle(.secondary) }
            if model.state == .preparing {
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
                    if model.isActive {
                        Text("Remaining: \(model.estimatedRemaining(at: context.date).map(duration) ?? "Calculating…")")
                    }
                    Text("\(model.files.count) files indexed")
                }.font(.subheadline).foregroundStyle(.secondary)
            }
            if case .failed(let error) = model.state {
                Text(error.description).textSelection(.enabled)
                if error == .permissionDenied, !model.isActive, let device = model.device {
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
            if model.isActive {
                Button("Cancel scan") { model.cancel() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityHint("Stops scanning and keeps files already indexed")
            }
        }.padding(24)
    }
    private var title: String {
        switch model.state {
        case .idle: "Select a device"
        case .preparing: "Preparing scan"
        case .running: "Scanning…"
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
