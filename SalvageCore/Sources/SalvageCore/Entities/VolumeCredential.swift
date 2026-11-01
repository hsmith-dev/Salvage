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
    public init(kind: Kind, secret: String, trimmingWhitespace: Bool = false) {
        self.kind = kind
        var utf8 = secret.utf8[...]
        if trimmingWhitespace {
            let isSpace: (UInt8) -> Bool = { $0 == 0x20 || $0 == 0x09 || $0 == 0x0a || $0 == 0x0d }
            while let first = utf8.first, isSpace(first) { utf8 = utf8.dropFirst() }
            while let last = utf8.last, isSpace(last) { utf8 = utf8.dropLast() }
        }
        self.secret = SecretBytes(copying: utf8)
    }

    /// The secret's length in bytes (0 once zeroed).
    public var count: Int { lock.withLock { secret.isZeroed ? 0 : secret.count } }
    public var isZeroed: Bool { lock.withLock { secret.isZeroed } }

    /// Erases the secret. Idempotent. A recorded decryptor is kept (it holds the volume key, not
    /// the secret) until the caller drops it.
    public func zero() { lock.withLock { secret.zero() } }

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
