import SalvageCore
import SwiftUI

/// Placeholder for Story 1.10's `RecoverySheet(files:source:onDone:)`, with the same signature
/// so the swap in `FileBrowserView.recoverySheet` is a rename. Delete this file once 1.10 lands.
struct RecoverySlot: View {
    let files: [RecoveredFile]
    let source: SourceSession
    let onDone: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Recover \(files.count) \(files.count == 1 ? "file" : "files")").font(.headline)
            Text("Recovery isn't available in this build yet. Nothing has been copied.")
                .foregroundStyle(.secondary)
            HStack { Spacer(); Button("Close", action: onDone).keyboardShortcut(.cancelAction) }
        }
        .padding(24)
        .frame(minWidth: 420)
    }
}
