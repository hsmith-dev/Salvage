import Foundation

/// A FileVault password or personal recovery key for one encrypted APFS volume (FR-6, Story 2.5).
///
/// The secret lives only in an owned buffer that `zero()` and `deinit` erase with `memset_s`. It
/// is never logged, persisted, copied into a `Data`, or put in an error, and `description` never
/// shows it. A check or scan that unwraps the volume key with this credential records the result
/// here (`decryptor` / `failure`). Once a decryptor is recorded the secret can be zeroed: later
/// scans given this credential use the recorded key, and preview and recovery use it too.
public final class VolumeCredential: @unchecked Sendable, CustomStringConvertible {
    public enum Kind: Sendable, Equatable { case password, recoveryKey }

    public let kind: Kind
    private let lock = NSLock()
    private let secret: SecretBytes
    private var recordedDecryptor: (any ContentDecryptor)?
    private var recordedFailure: UnlockError?

    /// Copies `secret`'s UTF-8 bytes into erasable storage. With `trimmingWhitespace`, leading and
    /// trailing ASCII whitespace is dropped on the bytes, so no trimmed `String` copy is made (a
    /// recovery key is read out and typed; a password may legitimately start or end with a space).
    ///
    /// A recovery key is also normalized on the bytes: without its whitespace and hyphens and in
    /// capitals, a 24-character key of letters and digits is stored in Apple's personal recovery
    /// key form, six groups of four joined by hyphens (`ABCD-EFGH-…`), however it was typed. Any
    /// other recovery-key text is kept as typed (after the trim).
    public init(kind: Kind, secret: String, trimmingWhitespace: Bool = false) {
        self.kind = kind
        var utf8 = secret.utf8[...]
        if trimmingWhitespace {
            while let first = utf8.first, Self.isSpace(first) { utf8 = utf8.dropFirst() }
            while let last = utf8.last, Self.isSpace(last) { utf8 = utf8.dropLast() }
        }
        if kind == .recoveryKey, let canonical = Self.canonicalRecoveryKey(utf8) {
            self.secret = canonical
        } else {
            self.secret = SecretBytes(copying: utf8)
        }
    }

    static let recoveryKeyCharacters = 24, recoveryKeyGroup = 4

    private static func isSpace(_ byte: UInt8) -> Bool { byte == 0x20 || (0x09...0x0d).contains(byte) }
    private static func isSeparator(_ byte: UInt8) -> Bool { isSpace(byte) || byte == 0x2d }
    private static func uppercased(_ byte: UInt8) -> UInt8 { (0x61...0x7a).contains(byte) ? byte - 0x20 : byte }
    private static func isKeyCharacter(_ byte: UInt8) -> Bool { (0x30...0x39).contains(byte) || (0x41...0x5a).contains(uppercased(byte)) }

    /// The typed key in the personal recovery key form, written straight into erasable bytes (no
    /// intermediate copy); nil when it isn't 24 letters and digits once separators are dropped.
    private static func canonicalRecoveryKey(_ typed: Substring.UTF8View) -> SecretBytes? {
        var characters = 0
        for byte in typed where !isSeparator(byte) {
            guard isKeyCharacter(byte), characters < recoveryKeyCharacters else { return nil }
            characters += 1
        }
        guard characters == recoveryKeyCharacters else { return nil }
        let canonical = SecretBytes(count: recoveryKeyCharacters + recoveryKeyCharacters / recoveryKeyGroup - 1)
        canonical.withMutableBytes { out in
            var index = 0, written = 0
            for byte in typed where !isSeparator(byte) {
                if written > 0, written % recoveryKeyGroup == 0 { out[index] = 0x2d; index += 1 }
                out[index] = uppercased(byte); index += 1; written += 1
            }
        }
        return canonical
    }

    /// The secret's length in bytes (0 once zeroed).
    public var count: Int { lock.withLock { secret.isZeroed ? 0 : secret.count } }
    public var isZeroed: Bool { lock.withLock { secret.isZeroed } }

    /// Erases the secret. Idempotent. A recorded decryptor is kept (it holds the volume key, not
    /// the secret) until `discardKeys()`.
    public func zero() { lock.withLock { secret.zero() } }

    /// Erases the secret and drops the recorded volume key. The decryptor holds no raw key bytes
    /// (only CommonCrypto key schedules, cleared when it is released), so it is gone once its last
    /// holder (e.g. a closed `SourceSession`) lets go. Idempotent.
    public func discardKeys() {
        lock.withLock { secret.zero(); recordedDecryptor = nil }
    }

    deinit { secret.zero() }

    /// The volume's content decryptor, once a scan using this credential unwrapped its key.
    public var decryptor: (any ContentDecryptor)? { lock.withLock { recordedDecryptor } }
    /// Why a scan using this credential couldn't unwrap the volume key, if it tried and failed.
    public var failure: UnlockError? { lock.withLock { recordedFailure } }

    public var description: String { "VolumeCredential(\(kind), redacted)" }

    /// Reads the secret in place. Throws `UnlockError.toolFailure` once zeroed (nothing to try).
    func withSecret<R>(_ body: (UnsafeRawBufferPointer) throws -> R) throws -> R {
        lock.lock(); defer { lock.unlock() }
        guard !secret.isZeroed, secret.count > 0 else { throw UnlockError.toolFailure }
        return try secret.withBytes(body)
    }

    func record(_ result: Result<any ContentDecryptor, UnlockError>) {
        lock.withLock {
            switch result {
            case .success(let decryptor): recordedDecryptor = decryptor; recordedFailure = nil
            case .failure(let error): recordedFailure = error
            }
        }
    }
}

/// Decrypts file content stored as ciphertext on the source (`FileContent.encryptedRuns`).
public protocol ContentDecryptor: Sendable {
    /// Decrypts `ciphertext`, a whole number of `contentDataUnitSize`-byte data units, the first
    /// of which is data unit `firstDataUnit`.
    func decrypt(_ ciphertext: Data, firstDataUnit: UInt64) throws -> Data
}

/// The data-unit size of every `ContentDecryptor` (APFS encrypts in 512-byte units).
public let contentDataUnitSize = 512
