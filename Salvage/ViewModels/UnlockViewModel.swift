import Foundation
import Observation
import SalvageCore
import SalvageDiskIO

/// Drives the FileVault unlock sheet (FR-6 / AD-3). One request at a time: offered at device
/// selection for a device the picker knows is locked, or after a scan ends for each encrypted
/// volume the parser reported. The typed secret is handed to `SalvageDiskIO` in an erasable
/// buffer and the bound text is cleared the moment an attempt starts; nothing here logs or
/// persists it.
///
/// Story 2.4's spike found that an unlocked volume's device node still refuses raw reads from
/// user space, so a successful unlock ends in guidance (and the volume is locked again) rather
/// than a follow-on scan. Declining or finishing a request marks its volume handled, so the same
/// volume is never offered twice in a session (no retry loop).
@MainActor @Observable
final class UnlockViewModel {
    enum Phase: Equatable { case entering, unlocking, failed(UnlockError), unlocked(UnlockedVolume) }

    struct Request: Identifiable, Equatable {
        let device: BlockDevice
        /// Offered at device selection: the scan of `device` starts once the sheet is resolved.
        let startsScanWhenResolved: Bool
        var id: String { volumeUUID }
        var volumeUUID: String { (device.encryptedVolumeUUID ?? "").uppercased() }
        var title: String { device.encryptedVolumeName ?? device.displayName }
    }

    typealias Unlock = @Sendable (String, UnlockCredential) async -> Result<UnlockedVolume, UnlockError>
    typealias Relock = @Sendable (String) async -> Bool

    enum Copy {
        static let subtitle = "This volume is protected by FileVault. Enter your password or recovery key to continue. Salvage unlocks it without mounting it."
        static let wrongPassword = "Wrong password."
        static let wrongRecoveryKey = "Wrong recovery key."
        static let toolFailure = "Couldn't unlock this volume — try again or use your recovery key."
        static let unlockedButUnreadable = "The volume was unlocked. This version of Salvage can't read an unlocked FileVault volume without mounting it, and Salvage never mounts a drive it recovers from, so the files on it can't be recovered yet. The rest of the drive can still be scanned."
        static let relocked = "The volume has been locked again."
        static let notRelocked = "The volume is unlocked but not mounted; it locks again when the drive is unplugged."
    }

    private(set) var request: Request?
    private(set) var phase: Phase = .entering
    var credentialKind: UnlockCredential.Kind = .password
    /// Bound to the secure field. Cleared when an attempt starts, so the plain text exists only
    /// while it is being typed.
    var secret = ""
    /// Whether the volume was locked again after a successful unlock.
    private(set) var relocked = false
    private(set) var handledVolumeUUIDs: Set<String> = []
    private let unlock: Unlock
    private let relock: Relock
    private var task: Task<Void, Never>?

    init(unlock: @escaping Unlock = { uuid, credential in await FileVaultUnlocker.live.unlock(volumeUUID: uuid, credential: credential) },
         relock: @escaping Relock = { bsdName in await FileVaultUnlocker.live.lock(bsdName: bsdName) }) {
        self.unlock = unlock
        self.relock = relock
    }

    /// At device selection. `true` when the sheet now shows and the scan must wait for it.
    func offerBeforeScan(_ device: BlockDevice) -> Bool {
        guard request == nil, isOfferable(device) else { return false }
        present(Request(device: device, startsScanWhenResolved: true))
        return true
    }

    /// After a scan ends: offers the first encrypted volume the scan reported that hasn't been
    /// handled yet. Other results are untouched.
    func offer(fromScan requests: [BlockDevice]) {
        guard request == nil, let device = requests.first(where: isOfferable) else { return }
        present(Request(device: device, startsScanWhenResolved: false))
    }

    private func isOfferable(_ device: BlockDevice) -> Bool {
        guard let uuid = device.encryptedVolumeUUID, !uuid.isEmpty else { return false }
        return !handledVolumeUUIDs.contains(uuid.uppercased())
    }

    private func present(_ request: Request) {
        self.request = request
        phase = .entering; secret = ""; credentialKind = .password; relocked = false
    }

    var isUnlocking: Bool { phase == .unlocking }
    var canSubmit: Bool {
        guard request != nil, !secret.isEmpty else { return false }
        switch phase {
        case .entering, .failed: return true
        case .unlocking, .unlocked: return false
        }
    }

    var failureMessage: String? {
        guard case .failed(let error) = phase else { return nil }
        switch error {
        case .wrongPassword: return credentialKind == .recoveryKey ? Copy.wrongRecoveryKey : Copy.wrongPassword
        case .toolFailure: return Copy.toolFailure
        }
    }

    var unlockedMessage: String? {
        guard case .unlocked = phase else { return nil }
        return "\(Copy.unlockedButUnreadable) \(relocked ? Copy.relocked : Copy.notRelocked)"
    }

    func submit() {
        guard let request, canSubmit else { return }
        // A recovery key is read out and typed; surrounding whitespace is never part of it. A
        // password may legitimately start or end with a space.
        let text = credentialKind == .recoveryKey ? secret.trimmingCharacters(in: .whitespacesAndNewlines) : secret
        secret = ""
        guard !text.isEmpty else { return }
        let credential = UnlockCredential(kind: credentialKind, secret: text)
        phase = .unlocking
        task = Task { [unlock, relock] in
            let result = await unlock(request.volumeUUID, credential)
            credential.zero()
            guard !Task.isCancelled, self.request?.id == request.id else { return }
            switch result {
            case .success(let volume):
                // Nothing in this version can read the unlocked volume (spike), so leave it as found.
                relocked = await relock(volume.bsdName)
                guard !Task.isCancelled, self.request?.id == request.id else { return }
                handledVolumeUUIDs.insert(request.volumeUUID)
                phase = .unlocked(volume)
            case .failure(let error):
                phase = .failed(error)
            }
            task = nil
        }
    }

    /// Cancel or Continue: closes the sheet and marks the volume handled. Returns the device
    /// whose scan was waiting on this sheet, if any.
    @discardableResult
    func resolve() -> BlockDevice? {
        guard let request else { return nil }
        task?.cancel(); task = nil
        handledVolumeUUIDs.insert(request.volumeUUID)
        self.request = nil
        phase = .entering; secret = ""
        return request.startsScanWhenResolved ? request.device : nil
    }
}
