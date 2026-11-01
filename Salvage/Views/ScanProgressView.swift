import SalvageCore
import SalvageDiskIO
import SwiftUI

struct ScanProgressView: View {
    let model: ScanViewModel
    var body: some View {
        let volumeLabels = model.sourceVolumeLabels
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title2)
                .accessibilityIdentifier("scan-title")
            if let device = model.device { Text(device.displayName).foregroundStyle(.inkSecondary) }
            if model.state == .resumable {
                resumeOffer
            } else if model.state == .preparing, model.isAwaitingAdministratorPassword {
                AdministratorPasswordExplanation()
            } else if model.state == .preparing {
                HStack { ProgressView().controlSize(.small); Text("Preparing the device for read-only scanning…") }
            } else if model.totalBytes > 0 {
                ProgressView(value: Double(model.bytesScanned), total: Double(model.totalBytes))
                    .accessibilityLabel("Source bytes scanned")
                    // EXPERIENCE.md: the scan's state is spoken with its progress, not only shown in the title.
                    .accessibilityValue("\(model.state == .paused ? "Paused" : "Scanning"), \(percent(model.bytesScanned, of: model.totalBytes)) percent")
                    .accessibilityIdentifier("scan-progress")
                Text("\(Int(Double(model.bytesScanned) / Double(model.totalBytes) * 100))% of supported volume bytes read")
                    .font(.subheadline).foregroundStyle(.inkSecondary)
                    .accessibilityIdentifier("scan-progress-percent")
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
                }.font(.subheadline).foregroundStyle(.inkSecondary)
            }
            if case .failed(let error) = model.state, error == .administratorPasswordNeeded {
                // spec-tech-authopen: the password dialog was cancelled or left unanswered.
                AdministratorPasswordExplanation(onTryAgain: { model.retryAfterAdministratorPassword() })
            } else if case .failed(let error) = model.state {
                let needsApproval = PrivilegedHelperApproval.isApprovalRequired(error)
                Text(needsApproval ? PrivilegedHelperApproval.guidance : error.description).textSelection(.enabled)
                if needsApproval {
                    Button("Open System Settings") { PrivilegedHelperApproval.openSystemSettings() }
                        .accessibilityHint("Opens Login Items in System Settings, where you allow Salvage to read drives")
                }
                if error == .permissionDenied || needsApproval || model.canRetryFromCheckpoint, !model.isActive, let device = model.device {
                    // With a kept checkpoint, retrying offers Resume again rather than starting from zero.
                    Button("Retry scan") { model.start(device) }
                }
            }
            Text("Files listed here have been indexed from intact metadata. No files have been copied or recovered.")
                .font(.subheadline).foregroundStyle(.inkSecondary)
            List(model.files) { file in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(file.path).lineLimit(2).textSelection(.enabled)
                        if let volume = volumeLabels[file.sourceMetadata.volumeOffset] {
                            Text(volume).font(.caption).foregroundStyle(.inkSecondary)
                        }
                    }
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: file.sizeBytes, countStyle: .file)).foregroundStyle(.inkSecondary)
                }
                // One read-only line per file: its path, volume and size (combining the children
                // kept only the size, as the selectable path text isn't merged).
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits(.isStaticText)
                .accessibilityLabel([file.path, volumeLabels[file.sourceMetadata.volumeOffset],
                                     ByteCountFormatter.string(fromByteCount: file.sizeBytes, countStyle: .file)]
                    .compactMap { $0 }.joined(separator: ", "))
            }
            .accessibilityLabel("Files indexed so far")
            if model.state == .paused {
                Text("Scan paused. Salvage is not reading the device. Resume continues from the same point.")
                    .font(.subheadline).foregroundStyle(.inkSecondary)
            } else if model.resumedFromCheckpoint, model.isActive {
                // Set only once the core's first progress shows it accepted the checkpoint.
                Text("Resumed from where the previous scan stopped.")
                    .font(.subheadline).foregroundStyle(.inkSecondary)
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
