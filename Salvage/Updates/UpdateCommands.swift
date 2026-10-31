import Observation
import SwiftUI

/// App-wide record of whether any window has a scan running, so "Check for Updates…" can be
/// disabled while scanning even when the focused window isn't the one scanning.
@MainActor @Observable
final class ScanActivity {
    private var activeWindows: Set<UUID> = []
    var isAnyScanActive: Bool { !activeWindows.isEmpty }

    func set(_ window: UUID, active: Bool) {
        if active { activeWindows.insert(window) } else { activeWindows.remove(window) }
    }
}

/// Salvage ▸ Check for Updates… -- the app's one user-initiated network action (FR-17).
struct UpdateCommands: Commands {
    let checker: UpdateChecker
    let activity: ScanActivity

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            CheckForUpdatesMenuItem(checker: checker, activity: activity)
        }
    }
}

private struct CheckForUpdatesMenuItem: View {
    let checker: UpdateChecker
    let activity: ScanActivity
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Check for Updates…") {
            openWindow(id: UpdateWindow.id)
            Task { await checker.check() }
        }
        .disabled(activity.isAnyScanActive || checker.isChecking)
    }
}

/// Shows the result of the last check. Opening this window never starts a check by itself.
struct UpdateWindow: View {
    static let id = "check-for-updates"
    @Environment(UpdateChecker.self) private var checker
    @Environment(ScanActivity.self) private var activity

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Check for Updates").font(.headline)
            UpdateCheckStatus(checker: checker)
            HStack {
                Spacer()
                Button("Check Again") { Task { await checker.check() } }
                    .disabled(activity.isAnyScanActive || checker.isChecking || checker.state == .idle)
            }
            if activity.isAnyScanActive {
                Text("Checking for updates is unavailable while a scan is running.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Plain-language status for the current check, shared by the update window and the Trust Panel.
struct UpdateCheckStatus: View {
    let checker: UpdateChecker

    var body: some View {
        switch checker.state {
        case .idle:
            Text("Salvage only checks for updates when you ask it to.")
                .foregroundStyle(.secondary)
        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking GitHub for the latest version…")
            }
        case .finished(.upToDate(let current)):
            Text("Salvage is up to date (version \(current)).")
        case .finished(.available(let version, let current, let page)):
            VStack(alignment: .leading, spacing: 8) {
                Text("Version \(version) is available. You have version \(current).")
                Button("Open Release Page") { checker.openReleasePage(page) }
            }
        case .finished(.failed(let message)):
            Text(message)
        }
    }
}
