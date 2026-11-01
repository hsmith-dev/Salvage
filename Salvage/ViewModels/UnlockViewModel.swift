import Foundation
import Observation
import SalvageCore

/// Whether the FileVault unlock sheet may be shown at all.
enum FileVaultUnlockFeature {
    /// `true` since Story 2.5: Salvage decrypts a software-encrypted (FileVault) APFS volume itself,
    /// from the container's raw bytes (`SalvageCore`'s `APFSCrypto`, AD-3 option (a)), so a correct
    /// password or recovery key really does let its files be listed, previewed and recovered.
    /// Story 2.4's spike had shown that macOS refuses raw reads of an unlocked volume's own node,
    /// which is why the sheet was withheld until now. Nothing is mounted and `diskutil` isn't used.
    /// With the flag off (tests), both paths show plain guidance instead (`Copy.encryptedNotSupported`).
    static let canReadUnlockedVolumes = true
}

/// Drives the FileVault unlock sheet (FR-6 / AD-3). One request at a time: offered at device
/// selection for a device the picker knows is locked, or after a scan ends for each encrypted
/// volume the parser reported (queued, each offered once). While `FileVaultUnlockFeature` is off,
/// no request is ever presented and the same events produce `guidance` instead.
///
/// A "flow" is one device selection and the scans that follow it. Within a flow a volume is
/// offered at most once (no re-prompt loop after Cancel); selecting a device again starts a new
/// flow, so a locked row is offered again.
///
/// A submitted credential is checked by `verify` (SalvageCore reads the keybags and unwraps the
/// volume key; nothing is mounted). Wrong password, a volume Salvage can't decrypt, and a failed
/// check each have their own message, and the sheet stays open to retry. On success the volume's
/// key is recorded on the credential, its secret is zeroed at once, and when no other volume is
/// waiting to be asked about, `onUnlocked` starts a fresh scan of the device with every volume
/// unlocked in this flow. Those keys live only in memory, for the flow and the scan's session.
///
/// Secret handling: the `SecureField` is bound to `secret` (SwiftUI needs a `String` binding).
/// `submit()` moves it into an erasable `VolumeCredential` at once (a recovery key is trimmed on
/// the bytes, so no trimmed `String` copy is made) and clears `secret` in the same step. What
/// can't be zeroed, stated plainly: the `String` storage the field held while the user typed
/// (Swift strings are immutable and freed, not scrubbed) and whatever AppKit's secure text field
/// editor keeps internally. Nothing logs, prints or persists the secret.
@MainActor @Observable
final class UnlockViewModel {
    enum Phase: Equatable { case entering, unlocking, failed(UnlockError) }

    struct Request: Identifiable, Equatable {
        let device: BlockDevice
        /// Offered at device selection: the scan of `device` starts once the sheet is resolved.
        let startsScanWhenResolved: Bool
        var id: String { volumeUUID }
        var volumeUUID: String { (device.encryptedVolumeUUID ?? "").uppercased() }
        var title: String { device.encryptedVolumeName ?? device.displayName }
    }

    /// Checks a credential against the request's volume. Must not retain the credential.
    typealias Verify = @Sendable (BlockDevice, VolumeCredential) async -> Result<Void, UnlockError>
    /// Starts a scan of the device with the unlocked volumes' credentials (by volume UUID).
    typealias Rescan = @MainActor (BlockDevice, [String: VolumeCredential]) -> Void

    enum Copy {
        static let subtitle = "This volume is protected by FileVault. Enter your password or recovery key to continue. Salvage decrypts it itself, without mounting it."
        static let wrongPassword = "Wrong password."
        static let wrongRecoveryKey = "Wrong recovery key."
        static let toolFailure = "Couldn't unlock this volume — try again or use your recovery key."
        /// Hardware-bound encryption (the internal storage of a Mac with a T2 or Apple silicon chip).
        static let unsupported = "This volume's encryption is tied to the Mac it came from, so Salvage can't unlock it on this Mac. The rest of the drive can still be scanned."
        /// The credential was right, but the volume's file list failed its checks.
        static let damaged = "Salvage unlocked this volume but its file list is damaged, so its files can't be listed. The rest of the drive can still be scanned."
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
    var credentialKind: VolumeCredential.Kind = .password
    /// The kind of credential whose check failed (the toggle may have moved since).
    private(set) var failedKind: VolumeCredential.Kind = .password
    /// Bound to the secure field. Moved into erasable bytes and cleared by `submit()`.
    var secret = ""
    /// Volumes already offered (or explained) in the current flow.
    private(set) var handledVolumeUUIDs: Set<String> = []
    /// Encrypted volumes met in the current flow while the sheet is withheld, in order, once each.
    private(set) var guidanceVolumeUUIDs: [String] = []
    /// Volumes unlocked in the current flow (their keys recorded, their secrets zeroed).
    private(set) var unlockedCredentials: [String: VolumeCredential] = [:]
    let presentsSheet: Bool
    private var queue: [Request] = []
    private let verify: Verify
    private let rescan: Rescan
    /// The device to re-scan once no volume is left to ask about; set by a success.
    private var pendingRescan: BlockDevice?
    /// The check in flight, if any. A scan waits for it (`waitForPendingUnlock`).
    private var pending: Task<Void, Never>?
    private var attemptCounter = 0
    /// The attempt whose result the open sheet is waiting for; `nil` once the sheet is closed.
    private var liveAttempt: Int?

    init(presentsSheet: Bool = FileVaultUnlockFeature.canReadUnlockedVolumes,
         verify: @escaping Verify = { _, _ in .failure(.toolFailure) },
         rescan: @escaping Rescan = { _, _ in }) {
        self.presentsSheet = presentsSheet
        self.verify = verify
        self.rescan = rescan
    }

    /// Guidance for the results / progress surface while the sheet is withheld.
    var guidance: String? { guidanceVolumeUUIDs.isEmpty ? nil : Copy.encryptedNotSupported }

    /// At device selection; starts a new flow (dropping the previous flow's unlocked keys). `true`
    /// when the sheet now shows and the scan must wait for it.
    func offerBeforeScan(_ device: BlockDevice) -> Bool {
        guard request == nil else { return false }
        handledVolumeUUIDs = []; guidanceVolumeUUIDs = []; queue = []
        endFlowKeys()
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
        return !handledVolumeUUIDs.contains(key) && request?.volumeUUID != key && unlockedCredentials[key] == nil
    }

    private func explain(_ device: BlockDevice) {
        let key = uuid(of: device)
        handledVolumeUUIDs.insert(key)
        if !guidanceVolumeUUIDs.contains(key) { guidanceVolumeUUIDs.append(key) }
    }

    private func presentNextIfIdle() {
        guard request == nil else { return }
        guard !queue.isEmpty else {
            // Nothing left to ask about: re-scan with every volume unlocked in this flow.
            if let device = pendingRescan {
                pendingRescan = nil
                rescan(device, unlockedCredentials)
            }
            return
        }
        present(queue.removeFirst())
    }

    private func present(_ request: Request) {
        handledVolumeUUIDs.insert(request.volumeUUID)
        self.request = request
        phase = .entering; secret = ""; credentialKind = .password
    }

    /// Drops the keys of a finished flow: every secret is erased and every recorded volume key
    /// discarded. A scan's session holds its own decryptors and drops them when it closes.
    private func endFlowKeys() {
        for credential in unlockedCredentials.values { credential.discardKeys() }
        unlockedCredentials = [:]; pendingRescan = nil
    }

    /// Window teardown: cancels a check in flight, closes the sheet without starting anything, and
    /// drops the flow's keys.
    func tearDown() {
        pending?.cancel()
        liveAttempt = nil; request = nil; queue = []
        phase = .entering; secret = ""
        endFlowKeys()
    }

    var isUnlocking: Bool { phase == .unlocking }
    var canSubmit: Bool {
        guard request != nil, !secret.isEmpty else { return false }
        switch phase {
        case .entering, .failed: return true
        case .unlocking: return false
        }
    }

    var failureMessage: String? {
        guard case .failed(let error) = phase else { return nil }
        switch error {
        case .wrongPassword: return failedKind == .recoveryKey ? Copy.wrongRecoveryKey : Copy.wrongPassword
        case .toolFailure: return Copy.toolFailure
        case .unsupported: return Copy.unsupported
        case .damaged: return Copy.damaged
        }
    }

    func submit() {
        guard let request, canSubmit else { return }
        // Into erasable bytes at once, and the bound String released in the same step. A recovery
        // key is read out and typed, so surrounding whitespace is dropped (on the bytes); a
        // password may legitimately start or end with a space.
        let typed = secret
        secret = ""
        let credential = VolumeCredential(kind: credentialKind, secret: typed, trimmingWhitespace: credentialKind == .recoveryKey)
        guard credential.count > 0 else { credential.zero(); return }
        attemptCounter += 1
        let attempt = attemptCounter
        liveAttempt = attempt
        phase = .unlocking
        let previous = pending
        pending = Task { [verify] in
            await previous?.value
            let result = await verify(request.device, credential)
            // The secret is never needed again: on success the key is recorded on the credential.
            credential.zero()
            self.finish(result, credential: credential, attempt: attempt, request: request)
        }
    }

    private func finish(_ result: Result<Void, UnlockError>, credential: VolumeCredential, attempt: Int, request finished: Request) {
        if attempt == attemptCounter { pending = nil }
        // The sheet was closed while this ran: the user declined, so the result is dropped (the
        // check only read the device; there is nothing to undo).
        guard liveAttempt == attempt, request?.id == finished.id else { return }
        liveAttempt = nil
        switch result {
        case .success:
            // `verify` recorded the volume's key on the credential.
            unlockedCredentials[finished.volumeUUID] = credential
            pendingRescan = finished.device
            request = nil
            phase = .entering
            presentNextIfIdle()
        case .failure(let error):
            failedKind = credential.kind
            phase = .failed(error)
        }
    }

    /// Returns once no check is in flight. Any scan must start only after this.
    func waitForPendingUnlock() async {
        // The newest attempt clears `pending` when it finishes; an older one chained before it.
        while let task = pending { await task.value }
    }

    /// Cancel: closes the sheet and cancels an attempt still running (the Core check stops between
    /// key derivations), whose result is dropped. The next
    /// queued volume from the scan, if any, is offered; once none is left, volumes unlocked in this
    /// flow are re-scanned. Returns the device whose scan was waiting on this sheet (pre-scan
    /// path); the caller starts it after `waitForPendingUnlock()`.
    @discardableResult
    func resolve() -> BlockDevice? {
        guard let request else { return nil }
        pending?.cancel()
        liveAttempt = nil
        self.request = nil
        phase = .entering; secret = ""
        presentNextIfIdle()
        return request.startsScanWhenResolved ? request.device : nil
    }
}
