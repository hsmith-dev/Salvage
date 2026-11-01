import SalvageCore
import SalvageDiskIO
import SwiftUI

/// The FileVault unlock sheet (FR-6): native sheet, secure field, password / recovery key
/// toggle, and the explicit wrong-password vs tool-failure distinction EXPERIENCE.md requires.
/// Composition follows `mockups/filevault-unlock-sheet.html`. The sheet is left only through its
/// own buttons (Escape is Cancel), so a request is always resolved exactly once. Presented only
/// while `FileVaultUnlockFeature.canReadUnlockedVolumes` is on (the model never raises a request
/// otherwise). The secure field writes into `UnlockViewModel.secret`, which `submit()` moves into
/// erasable bytes and clears at once; see that type for what can't be zeroed.
struct FileVaultUnlockSheet: View {
    @Bindable var model: UnlockViewModel
    /// Called with the device whose scan was waiting on this sheet.
    var onResolved: (BlockDevice) -> Void = { _ in }
    @FocusState private var secretFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let request = model.request {
                Text("Unlock \u{201C}\(request.title)\u{201D}")
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                if let message = model.unlockedMessage { unlocked(message) } else { entry }
            }
        }
        .padding(24)
        .frame(width: 440)
        .interactiveDismissDisabled()
        .onAppear { secretFocused = true }
    }

    private var credentialLabel: String { model.credentialKind == .recoveryKey ? "Recovery key" : "Password" }

    private var entry: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(UnlockViewModel.Copy.subtitle)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Unlock with", selection: $model.credentialKind) {
                Text("Password").tag(UnlockCredential.Kind.password)
                Text("Recovery Key").tag(UnlockCredential.Kind.recoveryKey)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Unlock with")
            .disabled(model.isUnlocking)

            VStack(alignment: .leading, spacing: 6) {
                Text(credentialLabel).font(.subheadline).foregroundStyle(.secondary)
                SecureField(credentialLabel, text: $model.secret)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .focused($secretFocused)
                    .onSubmit { model.submit() }
                    .disabled(model.isUnlocking)
                    .accessibilityLabel(credentialLabel)
                    .accessibilityValue(model.failureMessage ?? "")
            }

            if let message = model.failureMessage {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").accessibilityHidden(true)
                    Text(message).fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(.red)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Unlock failed. \(message)")
            }

            HStack(spacing: 8) {
                if model.isUnlocking {
                    ProgressView().controlSize(.small)
                    Text("Unlocking…").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) { resolve() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityHint("Closes without unlocking. Other results are kept.")
                Button("Unlock") { model.submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canSubmit)
            }
        }
    }

    private func unlocked(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "lock.open").accessibilityHidden(true)
                Text(message).fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            HStack {
                Spacer()
                Button("Continue") { resolve() }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private func resolve() {
        if let device = model.resolve() { onResolved(device) }
    }
}
