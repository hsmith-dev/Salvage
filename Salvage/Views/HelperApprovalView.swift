import SalvageCore
import SalvageDiskIO
import SwiftUI

/// spec-tech-authopen: why macOS is about to ask (or just asked) for an administrator password.
/// Shown while the system dialog is up, and again with Try Again when it was cancelled. Plain
/// body text, as DESIGN.md asks of error states; no color, no decorative icon.
struct AdministratorPasswordExplanation: View {
    static let explanation = "macOS will ask for an administrator password so Salvage can read this drive. Salvage only reads it \u{2014} it never writes to it."

    /// Nil while the dialog is up; the retry action once it was cancelled.
    var onTryAgain: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let onTryAgain {
                Text(ScanError.administratorPasswordNeeded.description).textSelection(.enabled)
                    .accessibilityIdentifier("admin-password-declined")
                Text(Self.explanation).foregroundStyle(.inkSecondary).textSelection(.enabled)
                Button("Try Again", action: onTryAgain)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityHint("Asks for your administrator password again, then starts the scan")
                    .accessibilityIdentifier("admin-password-try-again")
                HelperApprovalView()
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for your administrator password\u{2026}")
                }
                .accessibilityElement(children: .combine)
                Text(Self.explanation).textSelection(.enabled)
                    .accessibilityIdentifier("admin-password-explanation")
            }
        }
    }
}

/// Story 1.12, demoted by spec-tech-authopen to an optional, secondary path: in a signed build
/// that embeds the read-only helper, the user can approve it once to skip the password next
/// time. Unsigned and development builds (and builds where it is already on) show nothing. The
/// text comes from SalvageDiskIO; this view adds the register and System Settings actions.
struct HelperApprovalView: View {
    @State private var offer: PrivilegedHelperApproval.Offer?
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch offer {
            case .canRegister:
                Text(PrivilegedHelperApproval.skipPasswordGuidance)
                    .font(.subheadline).foregroundStyle(.inkSecondary).textSelection(.enabled)
                Button("Skip the password next time") {
                    working = true
                    Task {
                        offer = await PrivilegedHelperApproval.register()
                        working = false
                    }
                }
                .disabled(working)
                .accessibilityHint("Sets up Salvage's read-only disk access, which you then allow once in System Settings")
                .accessibilityIdentifier("helper-skip-password")
            case .awaitingApproval:
                Text(PrivilegedHelperApproval.guidance)
                    .font(.subheadline).foregroundStyle(.inkSecondary).textSelection(.enabled)
                Button("Open System Settings") { PrivilegedHelperApproval.openSystemSettings() }
                    .accessibilityHint("Opens Login Items in System Settings, where you allow Salvage to read drives")
            case .unavailable, .enabled, nil:
                EmptyView()
            }
        }
        .padding(.top, offer == .canRegister || offer == .awaitingApproval ? 8 : 0)
        .task { offer = await PrivilegedHelperApproval.currentOffer() }
    }
}

#Preview("Waiting") { AdministratorPasswordExplanation().padding() }
#Preview("Cancelled") { AdministratorPasswordExplanation(onTryAgain: {}).padding() }
