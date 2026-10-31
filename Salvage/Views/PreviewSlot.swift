import SalvageCore
import SwiftUI

/// Placeholder for Story 1.9's `FilePreviewView(file:source:)`, with the same signature so the
/// swap in `FileBrowserView.previewPane` is a rename. Delete this file once 1.9 lands.
struct PreviewSlot: View {
    let file: RecoveredFile
    let source: SourceSession?
    var body: some View {
        Text("No preview available")
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
