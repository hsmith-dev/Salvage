import Foundation
import SalvageCore

// Story 2.4 (FR-6 / AD-3): unlock a FileVault (encrypted APFS) volume with a password or recovery
// key through `diskutil apfs unlockVolume <volume> -nomount -stdinpassphrase`, never mounting it.
// The credential reaches diskutil through its stdin only (never an argument, so it is never in
// the process table), lives in a `SensitiveBytes` buffer that is erased as soon as the call ends,
// and is never logged, persisted or put in defaults. Automated tests inject the subprocess.
//
// Spike result (spec Implementation Notes): even after `unlockVolume -nomount` succeeds, an
// unprivileged read of the unlocked volume's own device node fails with EACCES at read time (the
// APFS driver refuses raw reads of volume devices; the container node reads fine but holds the
// ciphertext). So this story ships the unlock and the guidance only; no follow-on raw read.

/// A password or recovery key, held in erasable memory only for the duration of an unlock.
public final class UnlockCredential: @unchecked Sendable {
    public enum Kind: Sendable, Hashable { case password, recoveryKey }
    public let kind: Kind
    let bytes: SensitiveBytes

    /// `trimmingWhitespace` drops leading and trailing ASCII whitespace (a recovery key is read
    /// out and typed, so surrounding spaces are never part of it) on the byte buffer itself, so no
    /// trimmed `String` copy of the secret is ever made. The `String` the caller passes is the
    /// one copy this type cannot erase; callers release it as soon as this returns.
    public init(kind: Kind, secret: String, trimmingWhitespace: Bool = false) {
        self.kind = kind
        let view = secret.utf8
        var start = view.startIndex, end = view.endIndex
        if trimmingWhitespace {
            func isSpace(_ byte: UInt8) -> Bool { byte == 0x20 || (0x09...0x0D).contains(byte) }
            while start < end, isSpace(view[start]) { start = view.index(after: start) }
            while start < end, isSpace(view[view.index(before: end)]) { end = view.index(before: end) }
        }
        // Built in one allocation of exactly the kept bytes (no trimmed-then-shifted buffer that
        // would leave stray secret bytes past `count`, where `zero()` can't see them).
        bytes = SensitiveBytes(Array(view[start..<end]))
    }

    public var isZeroed: Bool { bytes.isZeroed }
    /// Byte count of the secret (unchanged by `zero()`), so a caller can check what it handed over
    /// without reading it back.
    public var count: Int { bytes.count }
    /// Erases the secret. Called by `FileVaultUnlocker.unlock` on every path; callers may call it
    /// again (idempotent), for example when the user cancels before unlocking.
    public func zero() { bytes.zero() }
}

/// The volume after a successful unlock: still unmounted, identified for the follow-on step.
public struct UnlockedVolume: Sendable, Equatable {
    public let volumeUUID: String
    /// The volume's own device node, e.g. "disk19s2" (from `diskutil apfs list -plist`).
    public let bsdName: String
    public let name: String?

    public init(volumeUUID: String, bsdName: String, name: String?) {
        self.volumeUUID = volumeUUID; self.bsdName = bsdName; self.name = name
    }
}

/// How an unlock request ended well. The two cases differ in what the caller may conclude and do:
/// only `.unlocked` says anything about the credential, and only an `.unlocked` volume may be
/// locked again by Salvage, because only that one was unlocked by Salvage.
public enum UnlockOutcome: Sendable, Equatable {
    /// Salvage unlocked the volume in this call, so the credential was verified by diskutil.
    case unlocked(UnlockedVolume)
    /// The volume was already unlocked before this call (by the user, outside Salvage). The
    /// credential was **not** checked against it, and the volume is not Salvage's to relock.
    case alreadyUnlocked(UnlockedVolume)

    public var volume: UnlockedVolume {
        switch self {
        case .unlocked(let volume), .alreadyUnlocked(let volume): return volume
        }
    }
}

/// The subprocess seam: `diskutil` arguments plus optional stdin bytes, returning the exit status
/// and both pipes, or `nil` for a launch failure or timeout.
typealias DiskUtilRunner = @Sendable (_ arguments: [String], _ input: SensitiveBytes?) -> BoundedProcessOutput?

public struct FileVaultUnlocker: Sendable {
    private let run: DiskUtilRunner

    /// Real `diskutil`: metadata queries get the usual 10 s; an unlock derives keys and can take
    /// a few seconds on its own, so it gets 60 s. Both are hard deadlines with drained pipes.
    public static let live = FileVaultUnlocker { arguments, input in
        runBoundedProcess(executable: URL(fileURLWithPath: "/usr/sbin/diskutil"), arguments: arguments,
                          input: input, timeout: input == nil ? 10 : 60)
    }

    init(run: @escaping DiskUtilRunner) { self.run = run }

    /// Unlocks the encrypted APFS volume with this UUID without mounting it. The credential is
    /// erased before this returns, whatever the outcome. `.wrongPassword` is diskutil's own
    /// verdict on the credential; `.toolFailure` is everything else (volume not found, diskutil
    /// missing or old, timeout, unexpected output). A volume that is already unlocked, whether the
    /// listing says so or diskutil answers "not locked" (-69589) to the attempt, comes back as
    /// `.alreadyUnlocked`: the credential was not verified and the volume is not Salvage's to
    /// relock, so it is never reported as `.unlocked`.
    public func unlock(volumeUUID: String, credential: UnlockCredential) async -> Result<UnlockOutcome, UnlockError> {
        defer { credential.zero() }
        guard isAPFSVolumeUUID(volumeUUID) else { return .failure(.toolFailure) }
        let run = run
        return await offCooperativePool {
            guard let containers = run(["apfs", "list", "-plist"], nil).flatMap(Self.decodeContainers),
                  let volume = apfsVolume(uuid: volumeUUID, in: containers), volume.isEncrypted else {
                return .failure(.toolFailure)
            }
            let listed = UnlockedVolume(volumeUUID: volume.uuid, bsdName: volume.bsdName, name: volume.name)
            // Already unlocked (by the user, earlier): nothing to do, nothing to verify, nothing to relock.
            guard volume.isLocked else { return .success(.alreadyUnlocked(listed)) }
            let output = run(["apfs", "unlockVolume", volume.bsdName, "-nomount", "-stdinpassphrase", "-plist"], credential.bytes)
            switch interpretUnlockOutput(output) {
            case .unlocked: return .success(.unlocked(listed))
            case .alreadyUnlocked: return .success(.alreadyUnlocked(listed))
            case .failed(let error): return .failure(error)
            }
        }
    }

    /// Locks an unlocked, unmounted volume again (`diskutil apfs lockVolume`). Best effort: used
    /// to leave a volume as Salvage found it when the unlock can't be followed by a read.
    public func lock(bsdName: String) async -> Bool {
        guard isDiskNodeBSDName(bsdName), !isWholeDiskBSDName(bsdName) else { return false }
        let run = run
        return await offCooperativePool { run(["apfs", "lockVolume", bsdName], nil)?.status == 0 }
    }

    private static func decodeContainers(_ output: BoundedProcessOutput) -> [APFSListedContainer]? {
        guard output.status == 0,
              let plist = (try? PropertyListSerialization.propertyList(from: output.standardOutput, options: [], format: nil)) as? [String: Any]
        else { return nil }
        return apfsContainers(fromListPlist: plist)
    }
}

/// diskutil's error codes seen in the spike (spec Implementation Notes).
enum DiskUtilUnlockCode {
    /// "Passphrase incorrect or user does not exist".
    static let passphraseIncorrect = -69591
    /// "The given APFS Volume is not locked": the goal state already holds.
    static let notLocked = -69589
}

/// What one `diskutil apfs unlockVolume` run said.
enum UnlockInterpretation: Equatable {
    /// Exit 0 (and no explicit `Success = false`): the credential opened the volume.
    case unlocked
    /// "The given APFS Volume is not locked" (-69589): someone unlocked it between the listing and
    /// the attempt. The credential was not checked, so this is not a success of the credential.
    case alreadyUnlocked
    case failed(UnlockError)
}

/// Pure interpretation of `diskutil apfs unlockVolume ... -plist`'s result. Exit 0 is
/// `.unlocked` unless the plist explicitly says `Success = false`. A wrong credential is
/// recognised by diskutil's error code (preferred) or its message text (older diskutil without
/// `-plist` support); everything else, including a timeout (`nil` output), is a tool failure.
func interpretUnlockOutput(_ output: BoundedProcessOutput?) -> UnlockInterpretation {
    guard let output else { return .failed(.toolFailure) }
    let plist = (try? PropertyListSerialization.propertyList(from: output.standardOutput, options: [], format: nil)) as? [String: Any]
    let code = (plist?["DiskManagementErrorCode"] as? NSNumber)?.intValue
    if output.status == 0 {
        if let success = plist?["Success"] as? Bool, !success { return .failed(.toolFailure) }
        return .unlocked
    }
    switch code {
    case DiskUtilUnlockCode.passphraseIncorrect?: return .failed(.wrongPassword)
    case DiskUtilUnlockCode.notLocked?: return .alreadyUnlocked
    default: break
    }
    let text = String(decoding: output.standardOutput + output.standardError, as: UTF8.self)
    if text.contains("Passphrase incorrect") { return .failed(.wrongPassword) }
    return .failed(.toolFailure)
}

/// Runs blocking subprocess work on a global GCD queue so it never ties up a cooperative-pool
/// thread (or the main actor) for the length of a key derivation or a `diskutil` listing. Shared
/// by the unlocker and `DeviceWatcher`'s lock-state annotation.
func offCooperativePool<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: work()) }
    }
}
