import AppKit
import SalvageCore
import SwiftUI

/// Recovery Confirmation and Recovery Summary (FR-14–FR-16): pick a destination on a different
/// drive, copy the selected files, and show what was actually written.
struct RecoverySheet: View {
    let onDone: () -> Void
    @State private var coordinator: RecoveryCoordinator

    init(files: [RecoveredFile], source: SourceSession, onDone: @escaping () -> Void) {
        self.onDone = onDone
        _coordinator = State(initialValue: RecoveryCoordinator(files: files, source: source))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch coordinator.phase {
            case .ready, .failedToStart: confirmation
            case .running: running
            case .finished(let summary): RecoverySummaryView(summary: summary, onDone: onDone)
            }
        }
        .padding(24)
        .frame(minWidth: 480, idealWidth: 520)
    }

    // MARK: Confirmation

    private var confirmation: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Recover \(fileCount(coordinator.files.count))")
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text("\(byteString(coordinator.totalBytes)) will be copied into a new folder inside the destination you choose. Nothing is written to the drive you're recovering from.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Image(systemName: "folder").accessibilityHidden(true)
                Text(coordinator.destination?.path ?? "No destination chosen")
                    .lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(coordinator.destination == nil ? .secondary : .primary)
                Spacer()
                if coordinator.destinationStatus == .checking { ProgressView().controlSize(.small) }
                Button("Choose…", action: chooseDestination)
                    .disabled(!coordinator.isConfirming)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Destination")

            if coordinator.destinationStatus == .blocked { DestinationBlockBanner() }
            if case .failedToStart(let reason) = coordinator.phase {
                // Not a block: the user can choose another folder (which clears this) or retry.
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").accessibilityHidden(true)
                    Text("\(reason) Choose another folder or try again.")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onDone).keyboardShortcut(.cancelAction)
                Button(isRetry ? "Try Again" : "Recover") { coordinator.start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!coordinator.canRecover)
            }
        }
    }

    private var isRetry: Bool {
        if case .failedToStart = coordinator.phase { return true }
        return false
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose a folder on a different drive from the one you're recovering."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await coordinator.chooseDestination(url) }
    }

    // MARK: Running

    private var running: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Recovering \(fileCount(coordinator.files.count))")
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            ProgressView(value: Double(coordinator.progress.bytesDone),
                         total: Double(max(coordinator.totalBytes, 1)))
                .accessibilityLabel("Recovery progress")
            Text("\(coordinator.progress.filesFinished) of \(coordinator.files.count) files · \(byteString(coordinator.progress.bytesDone)) of \(byteString(coordinator.totalBytes))")
                .monospacedDigit()
            if let name = coordinator.progress.currentName {
                Text(name).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { coordinator.cancel() }.keyboardShortcut(.cancelAction)
            }
        }
    }
}

/// The destination = source block (FR-15). The only place the `blocking` color appears.
struct DestinationBlockBanner: View {
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "xmark.octagon.fill").accessibilityHidden(true)
            Text(RecoveryCoordinator.blockedMessage).fixedSize(horizontal: false, vertical: true)
        }
        .font(.body.weight(.medium))
        .foregroundStyle(BlockingColors.text)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BlockingColors.surface, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Destination blocked. \(RecoveryCoordinator.blockedMessage)")
    }
}

/// DESIGN.md `blocking` tokens. The text hexes are darkened (light) and lightened (dark) from the
/// spine's starting values so they reach WCAG AA 4.5:1 on their surfaces; see spec-1-10 notes.
private enum BlockingColors {
    static let text = Color(nsColor: dynamic(light: 0xBF3434, dark: 0xE87870))
    static let surface = Color(nsColor: dynamic(light: 0xFCEEED, dark: 0x3A2422))

    private static func dynamic(light: Int, dark: Int) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
    }
}

// MARK: Summary

struct RecoverySummaryView: View {
    let summary: RecoverySummary
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(summary.cancelled ? "Recovery cancelled" : "Recovery finished")
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text(headline).fixedSize(horizontal: false, vertical: true)
            Text(summary.root.path).font(.callout).foregroundStyle(.secondary)
                .lineLimit(2).truncationMode(.middle).textSelection(.enabled)

            if !summary.failed.isEmpty {
                Text("Not recovered").font(.headline).accessibilityAddTraits(.isHeader)
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(summary.failed) { failure in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(failure.name).fontWeight(.medium)
                                Text(failure.reason).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 200)
            }

            HStack {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([summary.root])
                }
                Spacer()
                Button("Done", action: onDone).keyboardShortcut(.defaultAction)
            }
        }
    }

    private var headline: String {
        var text = "Recovered \(summary.written.count) of \(fileCount(summary.selectedCount)) (\(byteString(summary.bytesWritten)) written)."
        if !summary.failed.isEmpty { text += " \(fileCount(summary.failed.count)) couldn't be recovered." }
        if summary.notAttempted > 0 {
            text += " \(fileCount(summary.notAttempted)) \(summary.notAttempted == 1 ? "wasn't" : "weren't") recovered because you cancelled."
        }
        return text
    }
}

private func fileCount(_ count: Int) -> String { count == 1 ? "1 file" : "\(count) files" }
private func byteString(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
