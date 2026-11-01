import Foundation
import Observation
import SalvageCore
import SalvageDiskIO

/// Whether the FileVault unlock sheet may be shown at all.
enum FileVaultUnlockFeature {
    /// `false` in this build: Story 2.4's spike proved that an unlocked FileVault volume still can't
    /// be read through Salvage's raw path (every read of an APFS volume node fails with EACCES; only
    /// the container, which holds ciphertext, is readable). Asking for a password for a recovery
    /// that can't happen would be a broken promise, so neither the pre-scan nor the post-scan path
    /// presents the sheet; both show plain guidance instead (`UnlockViewModel.Copy.encryptedNotSupported`).
    ///
    /// Turn this on only with the follow-on story that implements one of AD-3's alternatives for
    /// reading the decrypted data (recommended: decrypt in `SalvageCore` from the container's raw
    /// bytes; see the "AD-3's alternatives" section of
    /// `spec-2-4-unlock-and-recover-from-a-filevault-encrypted-volume.md`). The unlocker, this view
    /// model and the sheet are kept, tested, and ready for it.
    static let canReadUnlockedVolumes = false
}

/// Drives the FileVault unlock sheet (FR-6 / AD-3). One request at a time: offered at device
/// selection for a device the picker knows is locked, or after a scan ends for each encrypted
/// volume the parser reported (queued, each offered once). While `FileVaultUnlockFeature` is off,
/// no request is ever presented and the same events produce `guidance` instead.
///
/// A "flow" is one device selection and the scan that follows it. Within a flow a volume is
/// offered at most once (no re-prompt loop after Cancel); selecting a device again starts a new
/// flow, so a locked row is offered again.
///
/// Secret handling: the `SecureField` is bound to `secret` (SwiftUI needs a `String` binding).
/// `submit()` moves it into an erasable `SensitiveBytes` buffer at once (a recovery key is
/// trimmed on the bytes, so no trimmed `String` copy is made) and clears `secret` in the same
/// step. What can't be zeroed, stated plainly: the `String` storage the field held while the user
/// typed (Swift strings are immutable and freed, not scrubbed) and whatever AppKit's secure text
/// field editor keeps internally. What is guaranteed is that the copy handed to `diskutil` is
/// erased, and nothing logs, prints or persists the secret.
@MainActor @Observable
final class UnlockViewModel {
    enum Phase: Equatable {
        case entering, unlocking, failed(UnlockError)
        /// Salvage unlocked the volume (credential verified) and then tried to relock it.
        case unlocked(UnlockedVolume)
        /// The volume was already unlocked; the credential was not checked, nothing was relocked.
        case alreadyUnlocked(UnlockedVolume)
    }

    /// What became of an attempt whose sheet was closed (Cancel) before it finished.
    enum AbandonedOutcome: Equatable {
        /// Salvage had unlocked it; it was locked again.
        case relocked(UnlockedVolume)
        /// Salvage had unlocked it; relocking failed (it locks again when the drive is unplugged).
        case leftUnlocked(UnlockedVolume)
        /// It was unlocked before Salvage touched it; left as it was.
        case alreadyUnlocked(UnlockedVolume)
        case failed(UnlockError)
    }

    struct Request: Identifiable, Equatable {
        let device: BlockDevice
        /// Offered at device selection: the scan of `device` starts once the sheet is resolved.
        let startsScanWhenResolved: Bool
        var id: String { volumeUUID }
        var volumeUUID: String { (device.encryptedVolumeUUID ?? "").uppercased() }
        var title: String { device.encryptedVolumeName ?? device.displayName }
    }

    typealias Unlock = @Sendable (String, UnlockCredential) async -> Result<UnlockOutcome, UnlockError>
    typealias Relock = @Sendable (String) async -> Bool

    enum Copy {
        static let subtitle = "This volume is protected by FileVault. Enter your password or recovery key to continue. Salvage unlocks it without mounting it."
        static let wrongPassword = "Wrong password."
        static let wrongRecoveryKey = "Wrong recovery key."
        static let toolFailure = "Couldn't unlock this volume — try again or use your recovery key."
        static let unlockedButUnreadable = "The volume was unlocked. This version of Salvage can't read an unlocked FileVault volume without mounting it, and Salvage never mounts a drive it recovers from, so the files on it can't be recovered yet. The rest of the drive can still be scanned."
        static let relocked = "The volume has been locked again."
        static let notRelocked = "The volume is unlocked but not mounted; it locks again when the drive is unplugged."
        /// Never claims the credential worked: it was not checked.
        static let alreadyUnlocked = "This volume was already unlocked before Salvage asked, so your password or recovery key wasn't checked, and Salvage left the volume as it was. This version of Salvage can't recover files from an encrypted volume yet. The rest of the drive can still be scanned."
        /// Shown instead of the sheet while `FileVaultUnlockFeature.canReadUnlockedVolumes` is off.
        static let encryptedNotSupported = "This drive has a FileVault-encrypted volume. Salvage can't recover files from encrypted volumes yet; its unencrypted volumes are scanned as usual."
    }

    /// The Device Picker row's inline note for a locked device, while the sheet is withheld.
    static func pickerNote(for device: BlockDevice, sheetEnabled: Bool = FileVaultUnlockFeature.canReadUnlockedVolumes) -> String? {
        guard !sheetEnabled, !device.isBootVolume, device.encryptedVolumeUUID != nil else { return nil }
        return Copy.encryptedNotSupported
    }

    private(set) var request: Request?
    private(set) var phase: Phase = .entering
    var credentialKind: UnlockCredential.Kind = .password
    /// Bound to the secure field. Moved into erasable bytes and cleared by `submit()`.
    var secret = ""
    /// Whether the volume was locked again after Salvage unlocked it.
    private(set) var relocked = false
    /// Volumes already offered (or explained) in the current flow.
    private(set) var handledVolumeUUIDs: Set<String> = []
    /// Encrypted volumes met in the current flow while the sheet is withheld, in order, once each.
    private(set) var guidanceVolumeUUIDs: [String] = []
    /// Outcomes of attempts whose sheet was closed before they finished, oldest first.
    private(set) var abandonedOutcomes: [AbandonedOutcome] = []
    let presentsSheet: Bool
    private var queue: [Request] = []
    private let unlock: Unlock
    private let relock: Relock
    /// The unlock in flight, if any. Never cancelled: a scan waits for it (`waitForPendingUnlock`),
    /// and a volume it unlocked is always relocked, even after the sheet closed.
    private var pending: Task<Void, Never>?
    private var attemptCounter = 0
    /// The attempt whose result the open sheet is waiting for; `nil` once the sheet is closed.
    private var liveAttempt: Int?

    init(presentsSheet: Bool = FileVaultUnlockFeature.canReadUnlockedVolumes,
         unlock: @escaping Unlock = { uuid, credential in await FileVaultUnlocker.live.unlock(volumeUUID: uuid, credential: credential) },
         relock: @escaping Relock = { bsdName in await FileVaultUnlocker.live.lock(bsdName: bsdName) }) {
        self.presentsSheet = presentsSheet
        self.unlock = unlock
        self.relock = relock
    }

    /// Guidance for the results / progress surface while the sheet is withheld.
    var guidance: String? { guidanceVolumeUUIDs.isEmpty ? nil : Copy.encryptedNotSupported }

    /// At device selection; starts a new flow. `true` when the sheet now shows and the scan must
    /// wait for it.
    func offerBeforeScan(_ device: BlockDevice) -> Bool {
        guard request == nil else { return false }
        handledVolumeUUIDs = []; guidanceVolumeUUIDs = []; queue = []
        guard isOfferable(device) else { return false }
        guard presentsSheet else { explain(device); return false }
        present(Request(device: device, startsScanWhenResolved: true))
        return true
    }

    /// After a scan ends: every encrypted volume the scan reported that this flow hasn't handled
    /// yet is queued and offered once, one sheet at a time (or explained once, while the sheet is
    /// withheld). Other results are untouched.
    func offer(fromScan requests: [BlockDevice]) {
        for device in requests where isOfferable(device) {
            if presentsSheet {
                handledVolumeUUIDs.insert(uuid(of: device))
                queue.append(Request(device: device, startsScanWhenResolved: false))
            } else {
                explain(device)
            }
        }
        presentNextIfIdle()
    }

    private func uuid(of device: BlockDevice) -> String { (device.encryptedVolumeUUID ?? "").uppercased() }

    private func isOfferable(_ device: BlockDevice) -> Bool {
        guard let uuid = device.encryptedVolumeUUID, !uuid.isEmpty else { return false }
        let key = uuid.uppercased()
        return !handledVolumeUUIDs.contains(key) && request?.volumeUUID != key
    }

    private func explain(_ device: BlockDevice) {
        let key = uuid(of: device)
        handledVolumeUUIDs.insert(key)
        if !guidanceVolumeUUIDs.contains(key) { guidanceVolumeUUIDs.append(key) }
    }

    private func presentNextIfIdle() {
        guard request == nil, !queue.isEmpty else { return }
        present(queue.removeFirst())
    }

    private func present(_ request: Request) {
        handledVolumeUUIDs.insert(request.volumeUUID)
        self.request = request
        phase = .entering; secret = ""; credentialKind = .password; relocked = false
    }

    var isUnlocking: Bool { phase == .unlocking }
    var canSubmit: Bool {
        guard request != nil, !secret.isEmpty else { return false }
        switch phase {
        case .entering, .failed: return true
        case .unlocking, .unlocked, .alreadyUnlocked: return false
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
        switch phase {
        case .unlocked: return "\(Copy.unlockedButUnreadable) \(relocked ? Copy.relocked : Copy.notRelocked)"
        case .alreadyUnlocked: return Copy.alreadyUnlocked
        default: return nil
        }
    }

    func submit() {
        guard let request, canSubmit else { return }
        // Into erasable bytes at once, and the bound String released in the same step. A recovery
        // key is read out and typed, so surrounding whitespace is dropped (on the bytes); a
        // password may legitimately start or end with a space.
        let typed = secret
        secret = ""
        let credential = UnlockCredential(kind: credentialKind, secret: typed, trimmingWhitespace: credentialKind == .recoveryKey)
        guard credential.count > 0 else { credential.zero(); return }
        attemptCounter += 1
        let attempt = attemptCounter
        liveAttempt = attempt
        phase = .unlocking
        let previous = pending
        pending = Task { [unlock, relock] in
            await previous?.value
            let result = await unlock(request.volumeUUID, credential)
            credential.zero()
            // Only a volume Salvage itself unlocked in this call is relocked -- and always, even if
            // the sheet was closed meanwhile: nothing in this version can read it.
            var didRelock = false
            if case .success(.unlocked(let volume)) = result { didRelock = await relock(volume.bsdName) }
            self.finish(result, relocked: didRelock, attempt: attempt, request: request)
        }
    }

    private func finish(_ result: Result<UnlockOutcome, UnlockError>, relocked didRelock: Bool, attempt: Int, request finished: Request) {
        if attempt == attemptCounter { pending = nil }
        guard liveAttempt == attempt, request?.id == finished.id else {
            // The sheet was closed while this ran: record what happened instead of dropping it.
            switch result {
            case .success(.unlocked(let volume)): abandonedOutcomes.append(didRelock ? .relocked(volume) : .leftUnlocked(volume))
            case .success(.alreadyUnlocked(let volume)): abandonedOutcomes.append(.alreadyUnlocked(volume))
            case .failure(let error): abandonedOutcomes.append(.failed(error))
            }
            return
        }
        liveAttempt = nil
        switch result {
        case .success(.unlocked(let volume)):
            relocked = didRelock
            phase = .unlocked(volume)
        case .success(.alreadyUnlocked(let volume)):
            relocked = false
            phase = .alreadyUnlocked(volume)
        case .failure(let error):
            phase = .failed(error)
        }
    }

    /// Returns once no unlock is in flight. Any scan must start only after this, so an unlock
    /// (and its relock) never overlaps a scan of the same drive.
    func waitForPendingUnlock() async {
        // The newest attempt clears `pending` when it finishes; an older one chained before it.
        while let task = pending { await task.value }
    }

    /// Cancel or Continue: closes the sheet. An attempt still running is not dropped: it finishes,
    /// is relocked if Salvage unlocked the volume, and lands in `abandonedOutcomes`. The next
    /// queued volume from the scan, if any, is offered. Returns the device whose scan was waiting
    /// on this sheet; the caller starts it after `waitForPendingUnlock()`.
    @discardableResult
    func resolve() -> BlockDevice? {
        guard let request else { return nil }
        liveAttempt = nil
        self.request = nil
        phase = .entering; secret = ""
        presentNextIfIdle()
        return request.startsScanWhenResolved ? request.device : nil
    }
}
