import SalvageDiskIO
import SwiftUI

/// Story 1.12: shown when a scan stopped only because the read-only disk access hasn't been
/// approved yet. The text comes from SalvageDiskIO; this view adds the System Settings shortcut.
struct HelperApprovalView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(PrivilegedHelperApproval.guidance).textSelection(.enabled)
            Button("Open System Settings") { PrivilegedHelperApproval.openSystemSettings() }
                .accessibilityHint("Opens Login Items in System Settings, where you allow Salvage to read drives")
        }
    }
}

#Preview { HelperApprovalView().padding() }
