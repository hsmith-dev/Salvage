import CommonCrypto
import Foundation

// Software-encrypted APFS volumes (Story 2.5), from Apple's public *Apple File System Reference*
// ("Encryption" and "Keybags" chapters) and published crypto standards only (AD-2): PBKDF2-HMAC-
// SHA256 (RFC 8018, vectors from RFC 7914), AES key wrap (RFC 3394) and XTS-AES (IEEE 1619). No
// GPL/LGPL implementation was read or ported. Original code.
//
//   container keybag  (`nx_keylocker`; AES-XTS, both key halves = the container UUID)
//     -> per volume: the wrapped VEK (KB_TAG_VOLUME_KEY) and the volume keybag's location
//   volume keybag     (AES-XTS, both key halves = the volume UUID)
//     -> unlock records (KB_TAG_VOLUME_UNLOCK_RECORDS): KEKs wrapped by a password-derived key
//   password --PBKDF2--> key --unwrap--> KEK --unwrap--> VEK
//   VEK = two AES-128 keys: XTS-AES-128 over 512-byte data units. A metadata block's first unit is
//   its physical block number x (block size / 512); a file extent's is its `crypto_id` x the same.
//
// Every failure fails closed: no key, no decryption, nothing parsed from guessed plaintext.

extension APFS {
    /// `APFS_FS_ONEKEY`: every file is encrypted with the volume key, with `crypto_id` as tweak.
    static let fsOneKey: UInt64 = 0x8
    /// `nx_keylocker` (`prange_t`) in `nx_superblock_t`.
    static let keylockerOffset = 0x510
}

// MARK: - Erasable key material

/// Owned bytes erased with `memset_s` on `zero()` and `deinit`. Callers synchronize access.
final class SecretBytes: @unchecked Sendable {
    private let pointer: UnsafeMutableRawBufferPointer
    let count: Int
    private(set) var isZeroed = false

    init(count: Int) {
        self.count = count
        pointer = UnsafeMutableRawBufferPointer.allocate(byteCount: max(count, 1), alignment: 16)
        pointer.initializeMemory(as: UInt8.self, repeating: 0)
    }

    /// Copies the bytes without an intermediate array (which would leave an unscrubbed copy).
    convenience init<S: Collection>(copying bytes: S) where S.Element == UInt8 {
        self.init(count: bytes.count)
        var index = 0
        for byte in bytes { pointer[index] = byte; index += 1 }
    }

    func withBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        try body(UnsafeRawBufferPointer(rebasing: pointer[0..<count]))
    }

    func withMutableBytes<R>(_ body: (UnsafeMutableRawBufferPointer) throws -> R) rethrows -> R {
        try body(UnsafeMutableRawBufferPointer(rebasing: pointer[0..<count]))
    }

    /// A copy of `range`, as new erasable bytes.
    func slice(_ range: Range<Int>) -> SecretBytes {
        withBytes { SecretBytes(copying: $0[range]) }
    }

    func zero() {
        _ = memset_s(pointer.baseAddress, pointer.count, 0, pointer.count)
        isZeroed = true
    }

    deinit {
        zero()
        pointer.deallocate()
    }
}

/// Erases a scratch buffer that held key-derived bytes.
func eraseBytes(_ buffer: UnsafeMutableRawBufferPointer) {
    _ = memset_s(buffer.baseAddress, buffer.count, 0, buffer.count)
}

// MARK: - Primitive adapter

/// The three primitives Core needs, behind a seam so a non-Apple Core adapter can supply its own.
/// The default is CommonCrypto, a system library (AD-1), not a third-party dependency.
protocol APFSCryptoProvider: Sendable {
    /// PBKDF2 with HMAC-SHA256 (RFC 8018).
    func pbkdf2SHA256(password: UnsafeRawBufferPointer, salt: Data, iterations: UInt32, keyLength: Int) throws -> SecretBytes
    /// AES key unwrap with the default initial value (RFC 3394). Nil when the integrity check
    /// fails, which is how a wrong key shows.
    func aesKeyUnwrap(kek: SecretBytes, wrapped: Data) throws -> SecretBytes?
    /// A raw AES block transform (ECB over whole 16-byte blocks), the building block of XTS.
    func aesBlockCipher(key: SecretBytes, encrypt: Bool) throws -> any AESBlockTransform
}

/// Applies AES to whole 16-byte blocks independently. Not thread-safe; `AESXTS` serializes it.
protocol AESBlockTransform: AnyObject {
    func apply(_ input: UnsafeRawBufferPointer, into output: UnsafeMutableRawBufferPointer) throws
}

enum APFSCryptoError: Error, Equatable { case primitiveFailed(Int32), invalidLength }

struct CommonCryptoProvider: APFSCryptoProvider {
    func pbkdf2SHA256(password: UnsafeRawBufferPointer, salt: Data, iterations: UInt32, keyLength: Int) throws -> SecretBytes {
        let key = SecretBytes(count: keyLength)
        let status = key.withMutableBytes { out in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                     password.baseAddress?.assumingMemoryBound(to: CChar.self), password.count,
                                     saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), saltBytes.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations,
                                     out.baseAddress?.assumingMemoryBound(to: UInt8.self), keyLength)
            }
        }
        guard status == kCCSuccess else { throw APFSCryptoError.primitiveFailed(status) }
        return key
    }

    func aesKeyUnwrap(kek: SecretBytes, wrapped: Data) throws -> SecretBytes? {
        guard wrapped.count >= 24, wrapped.count % 8 == 0, [16, 24, 32].contains(kek.count) else { throw APFSCryptoError.invalidLength }
        let key = SecretBytes(count: wrapped.count - 8)
        var length = key.count
        let status = key.withMutableBytes { out in
            kek.withBytes { kekBytes in
                wrapped.withUnsafeBytes { wrappedBytes in
                    CCSymmetricKeyUnwrap(CCWrappingAlgorithm(kCCWRAPAES), CCrfc3394_iv, CCrfc3394_ivLen,
                                         kekBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), kekBytes.count,
                                         wrappedBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), wrappedBytes.count,
                                         out.baseAddress?.assumingMemoryBound(to: UInt8.self), &length)
                }
            }
        }
        // CommonCrypto reports a failed integrity check as an error status; either way, no key.
        guard status == kCCSuccess, length == key.count else { key.zero(); return nil }
        return key
    }

    func aesBlockCipher(key: SecretBytes, encrypt: Bool) throws -> any AESBlockTransform {
        try CommonCryptoECB(key: key, encrypt: encrypt)
    }
}

final class CommonCryptoECB: AESBlockTransform {
    private let cryptor: CCCryptorRef

    init(key: SecretBytes, encrypt: Bool) throws {
        guard [16, 24, 32].contains(key.count) else { throw APFSCryptoError.invalidLength }
        var reference: CCCryptorRef?
        let status = key.withBytes { bytes in
            CCCryptorCreate(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionECBMode), bytes.baseAddress, bytes.count, nil, &reference)
        }
        guard status == kCCSuccess, let reference else { throw APFSCryptoError.primitiveFailed(status) }
        cryptor = reference
    }

    func apply(_ input: UnsafeRawBufferPointer, into output: UnsafeMutableRawBufferPointer) throws {
        guard input.count % 16 == 0, output.count >= input.count else { throw APFSCryptoError.invalidLength }
        var moved = 0
        let status = CCCryptorUpdate(cryptor, input.baseAddress, input.count, output.baseAddress, output.count, &moved)
        guard status == kCCSuccess, moved == input.count else { throw APFSCryptoError.primitiveFailed(status) }
    }

    /// CommonCrypto clears the key schedule when the cryptor is released.
    deinit { CCCryptorRelease(cryptor) }
}

// MARK: - XTS-AES (IEEE 1619)

/// XTS-AES over whole 512-byte data units (APFS never needs ciphertext stealing). Built on the raw
/// block transform: CommonCrypto's public headers no longer declare an XTS mode.
final class AESXTS: @unchecked Sendable {
    static let dataUnitSize = 512
    private let lock = NSLock()
    private let decryptor: any AESBlockTransform
    private let encryptor: any AESBlockTransform
    private let tweaker: any AESBlockTransform

    /// `key1` encrypts the data, `key2` the tweak (IEEE 1619's Key1 / Key2).
    init(key1: SecretBytes, key2: SecretBytes, provider: any APFSCryptoProvider) throws {
        guard key1.count == key2.count else { throw APFSCryptoError.invalidLength }
        decryptor = try provider.aesBlockCipher(key: key1, encrypt: false)
        encryptor = try provider.aesBlockCipher(key: key1, encrypt: true)
        tweaker = try provider.aesBlockCipher(key: key2, encrypt: true)
    }

    func decrypt(_ data: Data, firstDataUnit: UInt64) throws -> Data { try crypt(data, firstDataUnit: firstDataUnit, encrypt: false) }
    func encrypt(_ data: Data, firstDataUnit: UInt64) throws -> Data { try crypt(data, firstDataUnit: firstDataUnit, encrypt: true) }

    private func crypt(_ data: Data, firstDataUnit: UInt64, encrypt: Bool) throws -> Data {
        guard data.count % Self.dataUnitSize == 0 else { throw APFSCryptoError.invalidLength }
        let units = data.count / Self.dataUnitSize
        guard units > 0 else { return Data() }
        guard firstDataUnit <= UInt64.max - UInt64(units - 1) else { throw APFSCryptoError.invalidLength }
        lock.lock(); defer { lock.unlock() }
        // One tweak per data unit: E_K2(unit number as a 128-bit little-endian value).
        var tweaks = Data(count: units * 16)
        try tweaks.withUnsafeMutableBytes { buffer in
            for unit in 0..<units {
                buffer.storeBytes(of: (firstDataUnit + UInt64(unit)).littleEndian, toByteOffset: unit * 16, as: UInt64.self)
            }
            try tweaker.apply(UnsafeRawBufferPointer(buffer), into: buffer)
        }
        // The whitening mask: within a unit, T_{j+1} = T_j x alpha in GF(2^128).
        var mask = Data(count: data.count)
        mask.withUnsafeMutableBytes { maskBytes in
            tweaks.withUnsafeBytes { tweakBytes in
                for unit in 0..<units {
                    var low = tweakBytes.loadUnaligned(fromByteOffset: unit * 16, as: UInt64.self).littleEndian
                    var high = tweakBytes.loadUnaligned(fromByteOffset: unit * 16 + 8, as: UInt64.self).littleEndian
                    for block in 0..<(Self.dataUnitSize / 16) {
                        let offset = unit * Self.dataUnitSize + block * 16
                        maskBytes.storeBytes(of: low.littleEndian, toByteOffset: offset, as: UInt64.self)
                        maskBytes.storeBytes(of: high.littleEndian, toByteOffset: offset + 8, as: UInt64.self)
                        let carry = high >> 63
                        high = (high << 1) | (low >> 63)
                        low = (low << 1) ^ (carry * 0x87)
                    }
                }
            }
        }
        var work = data
        work.withUnsafeMutableBytes { workBytes in
            mask.withUnsafeBytes { maskBytes in
                for index in stride(from: 0, to: workBytes.count, by: 8) {
                    let value = workBytes.loadUnaligned(fromByteOffset: index, as: UInt64.self) ^ maskBytes.loadUnaligned(fromByteOffset: index, as: UInt64.self)
                    workBytes.storeBytes(of: value, toByteOffset: index, as: UInt64.self)
                }
            }
        }
        var output = Data(count: data.count)
        try output.withUnsafeMutableBytes { outBytes in
            try work.withUnsafeBytes { workBytes in
                try (encrypt ? encryptor : decryptor).apply(workBytes, into: outBytes)
            }
            mask.withUnsafeBytes { maskBytes in
                for index in stride(from: 0, to: outBytes.count, by: 8) {
                    let value = outBytes.loadUnaligned(fromByteOffset: index, as: UInt64.self) ^ maskBytes.loadUnaligned(fromByteOffset: index, as: UInt64.self)
                    outBytes.storeBytes(of: value, toByteOffset: index, as: UInt64.self)
                }
            }
        }
        // The masks are derived from the tweak key; erase them with the intermediate.
        mask.withUnsafeMutableBytes(eraseBytes); tweaks.withUnsafeMutableBytes(eraseBytes); work.withUnsafeMutableBytes(eraseBytes)
        return output
    }
}

/// An unlocked volume's key (VEK): decrypts its metadata blocks and file extents.
final class APFSVolumeDecryptor: ContentDecryptor, @unchecked Sendable {
    let xts: AESXTS
    init(xts: AESXTS) { self.xts = xts }
    func decrypt(_ ciphertext: Data, firstDataUnit: UInt64) throws -> Data {
        try xts.decrypt(ciphertext, firstDataUnit: firstDataUnit)
    }
}

// MARK: - DER (X.690) key blobs

/// A minimal, bounds-checked DER reader: definite lengths only, at most 4 length bytes.
struct DERElement: Sendable {
    let tag: UInt8
    let value: Data

    static func elements(in data: Data) throws -> [DERElement] {
        var result: [DERElement] = []
        var index = data.startIndex
        while index < data.endIndex {
            guard result.count < 64, data.endIndex - index >= 2 else { throw ScanError.malformed("Key blob is truncated.") }
            let tag = data[index]
            var length = Int(data[index + 1])
            var header = 2
            if length & 0x80 != 0 {
                let bytes = length & 0x7f
                guard bytes >= 1, bytes <= 4, data.endIndex - index >= 2 + bytes else { throw ScanError.malformed("Key blob length is invalid.") }
                length = 0
                for offset in 0..<bytes { length = length << 8 | Int(data[index + 2 + offset]) }
                header += bytes
            }
            guard length <= data.endIndex - index - header else { throw ScanError.malformed("Key blob overruns its entry.") }
            let start = index + header
            result.append(DERElement(tag: tag, value: Data(data[start..<start + length])))
            index = start + length
        }
        return result
    }

    static func first(_ tag: UInt8, in elements: [DERElement]) -> Data? { elements.first { $0.tag == tag }?.value }
}

/// A wrapped KEK or VEK: SEQUENCE { [0] version, [1] HMAC, [2] salt, [3] { [0] version, [1] UUID,
/// [2] flags, [3] wrapped key, [4] PBKDF2 iterations (KEK only), [5] PBKDF2 salt (KEK only) } }.
struct APFSWrappedKey: Sendable {
    let uuid: Data?
    let wrapped: Data
    let iterations: UInt32?
    let salt: Data?

    /// PBKDF2 work a hostile image may ask for; above this the record is unsupported, not tried.
    static let maxIterations: UInt32 = 20_000_000

    init(_ blob: Data) throws {
        guard let sequence = DERElement.first(0x30, in: try DERElement.elements(in: blob)),
              let inner = DERElement.first(0xa3, in: try DERElement.elements(in: sequence)) else {
            throw ScanError.malformed("Key blob has no key.")
        }
        let fields = try DERElement.elements(in: inner)
        guard let wrapped = DERElement.first(0x83, in: fields) else { throw ScanError.malformed("Key blob has no wrapped key.") }
        self.wrapped = wrapped
        uuid = DERElement.first(0x81, in: fields)
        salt = DERElement.first(0x85, in: fields)
        if let raw = DERElement.first(0x84, in: fields) {
            guard !raw.isEmpty, raw.count <= 5 else { throw ScanError.malformed("Key blob iteration count is invalid.") }
            let value = raw.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            guard value > 0, value <= UInt64(UInt32.max) else { throw ScanError.malformed("Key blob iteration count is invalid.") }
            iterations = UInt32(value)
        } else {
            iterations = nil
        }
    }
}

// MARK: - Keybags

/// One `keybag_entry_t`.
struct APFSKeybagEntry: Sendable {
    let uuid: Data
    let tag: UInt16
    let data: Data
}

enum APFSKeybag {
    /// `APFS_KEYBAG_VERSION`.
    static let version: UInt64 = 2
    /// `OBJECT_TYPE_MEDIA_KEYBAG` ('keys') and `OBJECT_TYPE_MEDIA_KEYBAG`'s volume form ('recs').
    static let containerType: UInt32 = 0x6b65_7973, volumeType: UInt32 = 0x7265_6373
    /// `KB_TAG_VOLUME_KEY`, `KB_TAG_VOLUME_UNLOCK_RECORDS`.
    static let tagVolumeKey: UInt16 = 2, tagUnlockRecords: UInt16 = 3
    /// The personal recovery key's unlock-record UUID (`APFS_FV_PERSONAL_RECOVERY_KEY_UUID`).
    static let personalRecoveryKeyUUID = Data([0xEB, 0xC6, 0xC0, 0x64, 0x00, 0x00, 0x11, 0xAA,
                                               0xAA, 0x11, 0x00, 0x30, 0x65, 0x43, 0xEC, 0xAC])
    /// A keybag is a few blocks at most; this bounds a hostile `prange_t`.
    static let maxBlocks: Int64 = 16
    static let maxEntries = 256

    /// The entries of a decrypted keybag object, which must verify and be of `type`.
    static func entries(in object: Data, type: UInt32) throws -> [APFSKeybagEntry] {
        guard apfsChecksumIsValid(object) else { throw ScanError.malformed("Keybag checksum mismatch.") }
        // A keybag's `o_type` is the whole four-character code, not a masked type.
        guard UInt32(try object.number(24, 4)) == type else {
            throw ScanError.malformed("Keybag has the wrong object type.")
        }
        guard try object.number(32, 2) == version else { throw ScanError.unsupportedFilesystem }
        let count = Int(try object.number(34, 2))
        let bytes = Int(try object.number(36, 4))
        // `kl_nbytes` counts the 16-byte locker header and the entries.
        guard count <= maxEntries, bytes >= 16, bytes <= object.count - 32 else { throw ScanError.malformed("Keybag size is invalid.") }
        let end = 32 + bytes
        var offset = 48, result: [APFSKeybagEntry] = []
        for _ in 0..<count {
            guard end - offset >= 24 else { throw ScanError.malformed("Keybag entry overruns the keybag.") }
            let tag = UInt16(try object.number(offset + 16, 2))
            let length = Int(try object.number(offset + 18, 2))
            guard length <= end - offset - 24 else { throw ScanError.malformed("Keybag entry overruns the keybag.") }
            let start = object.startIndex + offset
            result.append(APFSKeybagEntry(uuid: Data(object[start..<start + 16]), tag: tag,
                                          data: Data(object[start + 24..<start + 24 + length])))
            offset += (24 + length + 15) & ~15
        }
        return result
    }
}

// MARK: - Unwrapping

/// Derives a volume's key from a credential. Each step's failure has one meaning: no unlock record
/// accepts the credential -> `wrongPassword`; no software-wrapped key at all, or a password-unwrapped
/// KEK that doesn't unwrap the VEK -> `unsupported` (hardware-bound or unknown); anything unreadable
/// -> `toolFailure`. Derived buffers are erased as soon as they're no longer needed.
struct APFSKeyUnwrapper {
    let provider: any APFSCryptoProvider
    static let maxRecordsTried = 16

    /// The KEK from the first unlock record that `credential` opens.
    func unwrapKEK(records: [APFSKeybagEntry], credential: VolumeCredential) throws -> SecretBytes {
        guard !records.isEmpty else { throw UnlockError.unsupported }
        // A recovery key goes to its own record first; every record is tried either way.
        let ordered = records.filter { $0.uuid == APFSKeybag.personalRecoveryKeyUUID } + records.filter { $0.uuid != APFSKeybag.personalRecoveryKeyUUID }
        let candidates = credential.kind == .recoveryKey ? ordered : records
        var tried = 0, parsed = 0
        for record in candidates.prefix(Self.maxRecordsTried) {
            guard let key = try? APFSWrappedKey(record.data), let salt = key.salt, let iterations = key.iterations,
                  !salt.isEmpty, salt.count <= 64, iterations <= APFSWrappedKey.maxIterations, key.wrapped.count == 40 else { continue }
            parsed += 1
            for variant in try secretVariants(credential) {
                defer { variant.zero() }
                tried += 1
                let derived = try variant.withBytes { try provider.pbkdf2SHA256(password: $0, salt: salt, iterations: iterations, keyLength: 32) }
                defer { derived.zero() }
                if let kek = try provider.aesKeyUnwrap(kek: derived, wrapped: key.wrapped) { return kek }
            }
        }
        // No record in a form Salvage can try means the key isn't protected by a usable password.
        guard parsed > 0, tried > 0 else { throw UnlockError.unsupported }
        throw UnlockError.wrongPassword
    }

    /// The secret as typed, and for a recovery key also its ASCII-uppercased form (recovery keys
    /// are shown in capitals). Each variant is erasable.
    func secretVariants(_ credential: VolumeCredential) throws -> [SecretBytes] {
        try credential.withSecret { bytes in
            var variants = [SecretBytes(copying: bytes)]
            if credential.kind == .recoveryKey, bytes.contains(where: { $0 >= 0x61 && $0 <= 0x7a }) {
                variants.append(SecretBytes(copying: bytes.lazy.map { $0 >= 0x61 && $0 <= 0x7a ? $0 - 0x20 : $0 }))
            }
            return variants
        }
    }

    /// The volume's XTS key from its wrapped VEK and the unwrapped KEK.
    func unwrapVEK(_ blob: Data, kek: SecretBytes) throws -> AESXTS {
        guard let key = try? APFSWrappedKey(blob), key.wrapped.count == 40 else { throw UnlockError.unsupported }
        guard let vek = try provider.aesKeyUnwrap(kek: kek, wrapped: key.wrapped) else { throw UnlockError.unsupported }
        defer { vek.zero() }
        guard vek.count == 32 else { throw UnlockError.unsupported }
        let key1 = vek.slice(0..<16), key2 = vek.slice(16..<32)
        defer { key1.zero(); key2.zero() }
        return try AESXTS(key1: key1, key2: key2, provider: provider)
    }
}

/// XTS keyed by a UUID in both halves: how the Reference protects a keybag at rest.
func apfsKeybagCipher(uuid: Data, provider: any APFSCryptoProvider) throws -> AESXTS {
    guard uuid.count == 16 else { throw ScanError.malformed("Keybag UUID is invalid.") }
    let key1 = SecretBytes(copying: uuid), key2 = SecretBytes(copying: uuid)
    defer { key1.zero(); key2.zero() }
    return try AESXTS(key1: key1, key2: key2, provider: provider)
}

// MARK: - Checking a credential before a scan

/// Checks a password or recovery key against one encrypted APFS volume on a device, reading only
/// the metadata an unlock needs (partition map, container checkpoint, keybags, the volume's root
/// tree). On success the credential also records the volume's decryptor.
public enum EncryptedVolumeUnlock {
    public static func verify(reader: any BlockReader, volumeUUID: String,
                              credential: VolumeCredential) async -> Result<Void, UnlockError> {
        do {
            let extents = try await VolumeDiscovery(reader: reader).discover().extents.filter { $0.format == .apfs }
            for extent in extents {
                let container = APFSContainer(reader: reader, extent: extent, device: nil,
                                              credentials: [volumeUUID: credential], emit: { _ in })
                if let result = try await container.verifyUnlock(volumeUUID: volumeUUID) {
                    if case .failure(let error) = result { credential.record(.failure(error)) }
                    return result
                }
            }
            return .failure(.toolFailure)
        } catch {
            return .failure(.toolFailure)
        }
    }
}
