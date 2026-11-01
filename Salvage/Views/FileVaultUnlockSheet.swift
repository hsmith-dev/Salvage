import SalvageCore
import SwiftUI

/// The FileVault unlock sheet (FR-6): native sheet, secure field, password / recovery key
/// toggle, and the explicit wrong-password vs unsupported vs tool-failure distinction
/// EXPERIENCE.md requires. Composition follows `mockups/filevault-unlock-sheet.html`. The sheet is
/// left through its own buttons (Escape is Cancel) or by a successful unlock, which closes it and
/// re-scans the drive with the volume decrypted (Story 2.5). Presented only while
/// `FileVaultUnlockFeature.canReadUnlockedVolumes` is on. The secure field writes into
/// `UnlockViewModel.secret`, which `submit()` moves into erasable bytes and clears at once; see
/// that type for what can't be zeroed.
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
                entry
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
                .foregroundStyle(.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Unlock with", selection: $model.credentialKind) {
                Text("Password").tag(VolumeCredential.Kind.password)
                Text("Recovery Key").tag(VolumeCredential.Kind.recoveryKey)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Unlock with")
            .disabled(model.isUnlocking)

            VStack(alignment: .leading, spacing: 6) {
                Text(credentialLabel).font(.subheadline).foregroundStyle(.inkSecondary)
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
                    Text("Unlocking…").foregroundStyle(.inkSecondary)
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

    private func resolve() {
        if let device = model.resolve() { onResolved(device) }
    }
}
