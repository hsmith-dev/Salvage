import CommonCrypto
import Foundation
import Testing
@testable import SalvageCore

// Story 2.5: FileVault (software-encrypted APFS) decryption. Every primitive is checked against
// published test vectors before anything is built on it; the unlock logic is checked on synthetic
// keybags; and a real encrypted volume, made with `diskutil apfs addVolume … -passphrase` on a
// disposable image in a private temp directory, is scanned and compared byte for byte.

private func hex(_ text: String) -> Data {
    let digits = Array(text.filter { !$0.isWhitespace })
    var data = Data()
    var index = 0
    while index + 1 < digits.count {
        data.append(UInt8(String(digits[index...index + 1]), radix: 16)!)
        index += 2
    }
    return data
}

private func secret(_ data: Data) -> SecretBytes { SecretBytes(copying: data) }
private let provider = CommonCryptoProvider()

private func xts(_ key1: String, _ key2: String) throws -> AESXTS {
    try AESXTS(key1: secret(hex(key1)), key2: secret(hex(key2)), provider: provider)
}

/// Encrypts with `CCSymmetricKeyWrap` (the test's own wrap, so the unwrap path is exercised end to end).
private func wrap(_ key: Data, with kek: Data) -> Data {
    var output = [UInt8](repeating: 0, count: key.count + 8)
    var length = output.count
    let status = kek.withUnsafeBytes { kekBytes in
        key.withUnsafeBytes { keyBytes in
            CCSymmetricKeyWrap(CCWrappingAlgorithm(kCCWRAPAES), CCrfc3394_iv, CCrfc3394_ivLen,
                               kekBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), kekBytes.count,
                               keyBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), keyBytes.count, &output, &length)
        }
    }
    precondition(status == kCCSuccess)
    return Data(output.prefix(length))
}

private func pbkdf2(_ password: String, salt: Data, iterations: UInt32) throws -> Data {
    let key = try Array(password.utf8).withUnsafeBytes { try provider.pbkdf2SHA256(password: $0, salt: salt, iterations: iterations, keyLength: 32) }
    return key.withBytes { Data($0) }
}

// MARK: - Published test vectors

@Suite("Crypto primitives match published test vectors")
struct CryptoVectorTests {
    /// IEEE 1619-2007 Annex B, XTS-AES-128 vectors 1, 2 and 4 (vector 4: a 512-byte data unit).
    @Test func xtsAES128MatchesIEEE1619() throws {
        let zero = String(repeating: "00", count: 16)
        // Vectors 1 and 2 are 32 bytes; XTS here works in whole 512-byte units, and a unit's later
        // blocks don't affect its earlier ones, so the first 32 bytes of a unit are compared.
        let v1 = try xts(zero, zero).encrypt(Data(count: 512), firstDataUnit: 0)
        #expect(v1.prefix(32) == hex("917cf69ebd68b2ec9b9fe9a3eadda692cd43d2f59598ed858c02c2652fbf922e"))

        let cipher2 = try xts(String(repeating: "11", count: 16), String(repeating: "22", count: 16))
        let v2 = try cipher2.encrypt(Data(repeating: 0x44, count: 512), firstDataUnit: 0x33_3333_3333)
        #expect(v2.prefix(32) == hex("c454185e6a16936e39334038acef838bfb186fff7480adc4289382ecd6d394f0"))

        let plaintext = Data((0..<512).map { UInt8($0 % 256) })
        let cipher4 = try xts("27182818284590452353602874713526", "31415926535897932384626433832795")
        let v4 = try cipher4.encrypt(plaintext, firstDataUnit: 0)
        #expect(v4 == hex("""
            27a7479befa1d476489f308cd4cfa6e2a96e4bbe3208ff25287dd3819616e89cc78cf7f5e543445f8333d8fa7f56000005279fa5d8b5e4ad40e736ddb4d35412
            328063fd2aab53e5ea1e0a9f332500a5df9487d07a5c92cc512c8866c7e860ce93fdf166a24912b422976146ae20ce846bb7dc9ba94a767aaef20c0d61ad0265
            5ea92dc4c4e41a8952c651d33174be51a10c421110e6d81588ede82103a252d8a750e8768defffed9122810aaeb99f9172af82b604dc4b8e51bcb08235a6f434
            1332e4ca60482a4ba1a03b3e65008fc5da76b70bf1690db4eae29c5f1badd03c5ccf2a55d705ddcd86d449511ceb7ec30bf12b1fa35b913f9f747a8afd1b130e
            94bff94effd01a91735ca1726acd0b197c4e5b03393697e126826fb6bbde8ecc1e08298516e2c9ed03ff3c1b7860f6de76d4cecd94c8119855ef5297ca67e9f3
            e7ff72b1e99785ca0a7e7720c5b36dc6d72cac9574c8cbbc2f801e23e56fd344b07f22154beba0f08ce8891e643ed995c94d9a69c9f1b5f499027a78572aeebd
            74d20cc39881c213ee770b1010e4bea718846977ae119f7a023ab58cca0ad752afe656bb3c17256a9f6e9bf19fdd5a38fc82bbe872c5539edb609ef4f79c203e
            bb140f2e583cb2ad15b4aa5b655016a8449277dbd477ef2c8d6c017db738b18deb4a427d1923ce3ff262735779a418f20a282df920147beabe421ee5319d0568
            """))
        #expect(try cipher4.decrypt(v4, firstDataUnit: 0) == plaintext)
        // Several units in one call equal unit-by-unit calls with consecutive unit numbers.
        let three = Data((0..<1536).map { UInt8(($0 * 7) % 256) })
        let together = try cipher4.encrypt(three, firstDataUnit: 41)
        var separately = Data()
        for unit in 0..<3 { separately += try cipher4.encrypt(three.subdata(in: unit * 512..<(unit + 1) * 512), firstDataUnit: 41 + UInt64(unit)) }
        #expect(together == separately)
        #expect(throws: APFSCryptoError.invalidLength) { try cipher4.decrypt(Data(count: 100), firstDataUnit: 0) }
    }

    /// RFC 3394 §4.1 (128-bit KEK) and §4.6 (256-bit KEK, 256-bit key); a tampered blob fails.
    @Test func aesKeyUnwrapMatchesRFC3394() throws {
        let k1 = try provider.aesKeyUnwrap(kek: secret(hex("000102030405060708090A0B0C0D0E0F")),
                                           wrapped: hex("1FA68B0A8112B447AEF34BD8FB5A7B829D3E862371D2CFE5"))
        #expect(k1?.withBytes { Data($0) } == hex("00112233445566778899AABBCCDDEEFF"))
        let kek = secret(hex("000102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F"))
        var wrapped = hex("28C9F404C4B810F4CBCCB35CFB87F8263F5786E2D80ED326CBC7F0E71A99F43BFB988B9B7A02DD21")
        let k6 = try provider.aesKeyUnwrap(kek: kek, wrapped: wrapped)
        #expect(k6?.withBytes { Data($0) } == hex("00112233445566778899AABBCCDDEEFF000102030405060708090A0B0C0D0E0F"))
        wrapped[3] ^= 1
        #expect(try provider.aesKeyUnwrap(kek: kek, wrapped: wrapped) == nil)
        #expect(throws: APFSCryptoError.invalidLength) { try provider.aesKeyUnwrap(kek: kek, wrapped: Data(count: 20)) }
    }

    /// RFC 7914 §11 PBKDF2-HMAC-SHA256 vectors.
    @Test func pbkdf2MatchesRFC7914() throws {
        func derive(_ password: String, _ salt: String, _ iterations: UInt32) throws -> Data {
            try Array(password.utf8).withUnsafeBytes {
                try provider.pbkdf2SHA256(password: $0, salt: Data(salt.utf8), iterations: iterations, keyLength: 64)
            }.withBytes { Data($0) }
        }
        #expect(try derive("passwd", "salt", 1) == hex("""
            55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc49ca9cccf179b645991664b39d77ef317c71b845b1e30bd509112041d3a19783
            """))
        #expect(try derive("Password", "NaCl", 80000) == hex("""
            4ddcd8f60b98be21830cee5ef22701f9641a4418d04c0414aeff08876b34ab56a1d425a1225833549adb841b51c9b3176a272bdebba1d078478f62b397f33c8d
            """))
    }

    @Test func secretBytesAreErased() throws {
        let bytes = SecretBytes(copying: Data("hunter2".utf8))
        #expect(bytes.withBytes { Data($0) } == Data("hunter2".utf8))
        bytes.zero()
        #expect(bytes.isZeroed)
        #expect(bytes.withBytes { Data($0) } == Data(count: 7))

        let credential = VolumeCredential(kind: .recoveryKey, secret: "  ABCD-EFGH \n", trimmingWhitespace: true)
        #expect(credential.count == 9)
        #expect(!credential.description.contains("ABCD"))
        #expect(try credential.withSecret { Data($0) } == Data("ABCD-EFGH".utf8))
        credential.zero()
        #expect(credential.isZeroed && credential.count == 0)
        #expect(throws: UnlockError.toolFailure) { try credential.withSecret { _ in () } }
    }
}

// MARK: - Synthetic keybags and unwrapping

/// DER as the Reference's key blobs use it: short or two-byte lengths.
private func der(_ tag: UInt8, _ value: Data) -> Data {
    var out = Data([tag])
    if value.count < 0x80 { out.append(UInt8(value.count)) } else { out += [0x82, UInt8(value.count >> 8), UInt8(value.count & 0xff)] }
    return out + value
}

private func blob(uuid: Data, wrapped: Data, iterations: UInt32? = nil, salt: Data? = nil) -> Data {
    var inner = der(0x80, Data([0])) + der(0x81, uuid) + der(0x82, Data(count: 8)) + der(0x83, wrapped)
    if let iterations { inner += der(0x84, Data([UInt8(iterations >> 16), UInt8((iterations >> 8) & 0xff), UInt8(iterations & 0xff)])) }
    if let salt { inner += der(0x85, salt) }
    return der(0x30, der(0x80, Data([0])) + der(0x81, Data(count: 32)) + der(0x82, Data(count: 8)) + der(0xa3, inner))
}

private let volumeUUID = Data((0..<16).map { UInt8($0 + 0x30) })
private let userUUID = Data((0..<16).map { UInt8($0 + 0x90) })
private let vek = Data((0..<32).map { UInt8($0 * 3 + 1) })
private let kekBytes = Data((0..<32).map { UInt8(0xa0 &+ UInt8($0)) })

/// An unlock record for `password` wrapping the KEK.
private func record(_ password: String, uuid: Data = userUUID, iterations: UInt32 = 1000, kek: Data = kekBytes) throws -> APFSKeybagEntry {
    let salt = Data((0..<16).map { UInt8($0 ^ 0x5a) })
    let derived = try pbkdf2(password, salt: salt, iterations: iterations)
    return APFSKeybagEntry(uuid: uuid, tag: APFSKeybag.tagUnlockRecords, data: blob(uuid: volumeUUID, wrapped: wrap(kek, with: derived), iterations: iterations, salt: salt))
}

/// A keybag object (`obj_phys_t` + `kb_locker_t`) with a valid checksum.
private func keybagObject(type: UInt32, entries: [APFSKeybagEntry], size: Int = 4096) -> Data {
    var object = Data(count: size)
    object.put(24, UInt64(type), 4)
    object.put(32, APFSKeybag.version, 2)
    object.put(34, UInt64(entries.count), 2)
    var offset = 48
    for entry in entries {
        object.replaceSubrange(offset..<offset + 16, with: entry.uuid)
        object.put(offset + 16, UInt64(entry.tag), 2)
        object.put(offset + 18, UInt64(entry.data.count), 2)
        object.replaceSubrange(offset + 24..<offset + 24 + entry.data.count, with: entry.data)
        offset += (24 + entry.data.count + 15) & ~15
    }
    object.put(36, UInt64(offset - 32), 4)
    object.put(0, apfsFletcher64(object), 8)
    return object
}

/// Counts PBKDF2 work instead of doing it; unwrapping is real, so a derived
/// all-zero key never opens anything.
private final class CountingProvider: APFSCryptoProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var spent: UInt64 = 0, made = 0
    /// Runs inside each derivation with its 1-based call number (e.g. to hold it, as a slow KDF).
    let onDerive: @Sendable (Int) -> Void
    init(onDerive: @escaping @Sendable (Int) -> Void = { _ in }) { self.onDerive = onDerive }
    var iterations: UInt64 { lock.withLock { spent } }
    var calls: Int { lock.withLock { made } }

    func pbkdf2SHA256(password: UnsafeRawBufferPointer, salt: Data, iterations: UInt32, keyLength: Int) throws -> SecretBytes {
        let call = lock.withLock { spent += UInt64(iterations); made += 1; return made }
        onDerive(call)
        return SecretBytes(count: keyLength)
    }
    func aesKeyUnwrap(kek: SecretBytes, wrapped: Data) throws -> SecretBytes? { try provider.aesKeyUnwrap(kek: kek, wrapped: wrapped) }
    func aesBlockCipher(key: SecretBytes, encrypt: Bool) throws -> any AESBlockTransform { try provider.aesBlockCipher(key: key, encrypt: encrypt) }
}

@Suite("FileVault keybags and key unwrapping")
struct APFSKeyUnwrapTests {
    let unwrapper = APFSKeyUnwrapper(provider: provider)

    @Test func correctPasswordUnwrapsTheVolumeKey() throws {
        let kek = try unwrapper.unwrapKEK(records: [try record("correct horse")], credential: VolumeCredential(kind: .password, secret: "correct horse"))
        #expect(kek.withBytes { Data($0) } == kekBytes)
        let cipher = try unwrapper.unwrapVEK(blob(uuid: volumeUUID, wrapped: wrap(vek, with: kekBytes)), kek: kek)
        // The derived XTS key is the VEK's two halves.
        let reference = try xts(vek.prefix(16).map { String(format: "%02x", $0) }.joined(), vek.suffix(16).map { String(format: "%02x", $0) }.joined())
        let sample = Data((0..<1024).map { UInt8($0 & 0xff) })
        #expect(try cipher.encrypt(sample, firstDataUnit: 9) == (try reference.encrypt(sample, firstDataUnit: 9)))
    }

    @Test func wrongPasswordIsWrongPasswordNeverAToolFailure() throws {
        let records = [try record("correct horse"), try record("other user", uuid: Data(repeating: 7, count: 16))]
        #expect(throws: UnlockError.wrongPassword) {
            try unwrapper.unwrapKEK(records: records, credential: VolumeCredential(kind: .password, secret: "battery staple"))
        }
        // Any record may match: the second user's password works.
        let kek = try unwrapper.unwrapKEK(records: records, credential: VolumeCredential(kind: .password, secret: "other user"))
        #expect(kek.withBytes { Data($0) } == kekBytes)
    }

    @Test func recoveryKeyUnlocksThroughItsRecordEvenTypedInLowercase() throws {
        let prk = "ABCD-EFGH-IJKL-MNOP-QRST-UVWX"
        let records = [try record("user password"), try record(prk, uuid: APFSKeybag.personalRecoveryKeyUUID)]
        for typed in [prk, prk.lowercased(), "  \(prk)\n", "ABCDEFGHIJKLMNOPQRSTUVWX", "abcd efgh ijkl mnop qrst uvwx",
                      "AbCd-EfGh - IjKl-MnOp\tQRST uvwx"] {
            let credential = VolumeCredential(kind: .recoveryKey, secret: typed, trimmingWhitespace: true)
            let kek = try unwrapper.unwrapKEK(records: records, credential: credential)
            #expect(kek.withBytes { Data($0) } == kekBytes)
        }
        #expect(throws: UnlockError.wrongPassword) {
            try unwrapper.unwrapKEK(records: records, credential: VolumeCredential(kind: .recoveryKey, secret: "AAAA-BBBB"))
        }
    }

    /// No software unlock record, or a KEK that doesn't open the VEK (hardware-bound), is
    /// "unsupported" -- never a wrong password.
    @Test func hardwareBoundOrRecordlessVolumesAreUnsupported() throws {
        let credential = VolumeCredential(kind: .password, secret: "pw")
        #expect(throws: UnlockError.unsupported) { try unwrapper.unwrapKEK(records: [], credential: credential) }
        let noSalt = APFSKeybagEntry(uuid: userUUID, tag: 3, data: blob(uuid: volumeUUID, wrapped: Data(count: 40)))
        #expect(throws: UnlockError.unsupported) { try unwrapper.unwrapKEK(records: [noSalt], credential: credential) }
        // A VEK wrapped by some other key (e.g. one only the Secure Enclave holds).
        let otherKEK = Data(repeating: 0x42, count: 32)
        #expect(throws: UnlockError.unsupported) {
            try unwrapper.unwrapVEK(blob(uuid: volumeUUID, wrapped: wrap(vek, with: otherKEK)), kek: secret(kekBytes))
        }
        #expect(throws: UnlockError.unsupported) { try unwrapper.unwrapVEK(Data([0x30, 0x00]), kek: secret(kekBytes)) }
    }

    /// Apple's personal recovery key form: 24 letters or digits in six hyphenated groups of four,
    /// however they were typed. Anything else is kept as typed.
    @Test func recoveryKeysAreNormalizedOnTheBytes() throws {
        func stored(_ typed: String, _ kind: VolumeCredential.Kind = .recoveryKey) throws -> String {
            try VolumeCredential(kind: kind, secret: typed, trimmingWhitespace: kind == .recoveryKey).withSecret { String(decoding: $0, as: UTF8.self) }
        }
        let canonical = "ABCD-EFGH-1JKL-MNOP-QRS7-UVWX"
        for typed in [canonical, "ABCDEFGH1JKLMNOPQRS7UVWX", "abcd-efgh-1jkl-mnop-qrs7-uvwx", "abcdefgh1jklmnopqrs7uvwx",
                      "ABCD EFGH 1JKL MNOP QRS7 UVWX", " abcd - efgh - 1jkl - mnop - qrs7 - uvwx \n", "ABCD--EFGH1JKL\tMNOP-QRS7-UVWX"] {
            #expect(try stored(typed) == canonical, "\(typed.debugDescription)")
        }
        // Not 24 key characters, or other characters in it: passed through unchanged (trimmed).
        #expect(try stored("ABCD-EFGH") == "ABCD-EFGH")
        #expect(try stored("abcd-efgh-ijkl-mnop-qrst-uvw") == "abcd-efgh-ijkl-mnop-qrst-uvw")
        #expect(try stored("abcd-efgh-ijkl-mnop-qrst-uvwxy") == "abcd-efgh-ijkl-mnop-qrst-uvwxy")
        #expect(try stored("abcd-efgh-ijkl-mnop-qrst-uvw!") == "abcd-efgh-ijkl-mnop-qrst-uvw!")
        #expect(try stored("abcd-efgh-ijkl-mnop-qrst-uvwé") == "abcd-efgh-ijkl-mnop-qrst-uvwé")
        // A password is never rewritten.
        #expect(try stored("abcd efgh ijkl mnop qrst uvwx", .password) == "abcd efgh ijkl mnop qrst uvwx")
    }

    /// A hostile keybag of many expensive records is refused once one attempt's PBKDF2 budget is
    /// spent, rather than costing every record's iterations.
    @Test func manyHighIterationRecordsAreRefusedWithinTheBudget() throws {
        let counting = CountingProvider()
        let hostile = (0..<16).map { index in
            APFSKeybagEntry(uuid: Data(repeating: UInt8(index), count: 16), tag: 3,
                            data: blob(uuid: volumeUUID, wrapped: Data(count: 40), iterations: 9_000_000, salt: Data(count: 16)))
        }
        #expect(throws: UnlockError.toolFailure) {
            try APFSKeyUnwrapper(provider: counting).unwrapKEK(records: hostile, credential: VolumeCredential(kind: .password, secret: "pw"))
        }
        #expect(counting.iterations <= APFSKeyUnwrapper.iterationBudget + 9_000_000)
        #expect(counting.calls == 2)
        // Ordinary records are all tried: the budget only bounds hostile work.
        let ordinary = (0..<5).map { index in
            APFSKeybagEntry(uuid: Data(repeating: UInt8(index), count: 16), tag: 3,
                            data: blob(uuid: volumeUUID, wrapped: Data(count: 40), iterations: 200_000, salt: Data(count: 16)))
        }
        let fresh = CountingProvider()
        #expect(throws: UnlockError.wrongPassword) {
            try APFSKeyUnwrapper(provider: fresh).unwrapKEK(records: ordinary, credential: VolumeCredential(kind: .password, secret: "pw"))
        }
        #expect(fresh.calls == 5)
    }

    /// Cancelling a check stops it between records instead of deriving every record's key: the
    /// first derivation is held (a slow KDF) until the check is cancelled, and none follows it.
    @Test func cancellationStopsBetweenRecords() async throws {
        let started = DispatchSemaphore(value: 0), proceed = DispatchSemaphore(value: 0)
        let slow = CountingProvider { call in if call == 1 { started.signal(); proceed.wait() } }
        let records = (0..<16).map { index in
            APFSKeybagEntry(uuid: Data(repeating: UInt8(index), count: 16), tag: 3,
                            data: blob(uuid: volumeUUID, wrapped: Data(count: 40), iterations: 1000, salt: Data(count: 16)))
        }
        let credential = VolumeCredential(kind: .password, secret: "pw")
        let task = Task.detached { try APFSKeyUnwrapper(provider: slow).unwrapKEK(records: records, credential: credential) }
        await withCheckedContinuation { continuation in DispatchQueue.global().async { started.wait(); continuation.resume() } }
        task.cancel()
        proceed.signal()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(slow.calls == 1)
    }

    /// `discardKeys()` releases the recorded volume key and erases the secret.
    @Test func discardingKeysReleasesTheRecordedDecryptor() throws {
        let credential = VolumeCredential(kind: .password, secret: "pw")
        weak var released: APFSVolumeDecryptor?
        do {
            let decryptor = APFSVolumeDecryptor(xts: try xts(String(repeating: "01", count: 16), String(repeating: "02", count: 16)))
            released = decryptor
            credential.record(.success(decryptor))
        }
        #expect(released != nil && credential.decryptor != nil)
        credential.discardKeys()
        #expect(credential.decryptor == nil && credential.isZeroed)
        #expect(released == nil)
    }

    @Test func iterationCountAboveTheBoundIsNotTried() throws {
        let salt = Data(count: 16)
        let tooMany = APFSWrappedKey.maxIterations + 1
        var inner = der(0x81, volumeUUID) + der(0x83, Data(count: 40))
        inner += der(0x84, Data([UInt8(tooMany >> 24), UInt8((tooMany >> 16) & 0xff), UInt8((tooMany >> 8) & 0xff), UInt8(tooMany & 0xff)]))
        inner += der(0x85, salt)
        let entry = APFSKeybagEntry(uuid: userUUID, tag: 3, data: der(0x30, der(0xa3, inner)))
        #expect(throws: UnlockError.unsupported) {
            try unwrapper.unwrapKEK(records: [entry], credential: VolumeCredential(kind: .password, secret: "pw"))
        }
        // Above the per-record ceiling the blob itself is malformed.
        #expect(APFSWrappedKey.maxIterations == 10_000_000)
        #expect(throws: ScanError.self) { try APFSWrappedKey(der(0x30, der(0xa3, inner))) }
    }

    @Test func keybagObjectsParseAndHostileOnesFailClosed() throws {
        let entries = [APFSKeybagEntry(uuid: volumeUUID, tag: 2, data: Data(repeating: 9, count: 33)),
                       APFSKeybagEntry(uuid: volumeUUID, tag: 3, data: Data(count: 16))]
        let object = keybagObject(type: APFSKeybag.containerType, entries: entries)
        let parsed = try APFSKeybag.entries(in: object, type: APFSKeybag.containerType)
        #expect(parsed.map(\.tag) == [2, 3])
        #expect(parsed[0].data == Data(repeating: 9, count: 33))
        #expect(parsed[1].uuid == volumeUUID)
        // Wrong type, bad checksum, a lying entry length, and an oversized locker all fail.
        #expect(throws: ScanError.self) { try APFSKeybag.entries(in: object, type: APFSKeybag.volumeType) }
        var corrupt = object; corrupt[60] ^= 0xff
        #expect(throws: ScanError.self) { try APFSKeybag.entries(in: corrupt, type: APFSKeybag.containerType) }
        var lying = object; lying.put(48 + 18, 4000, 2); lying.put(0, apfsFletcher64(lying), 8)
        #expect(throws: ScanError.self) { try APFSKeybag.entries(in: lying, type: APFSKeybag.containerType) }
        var huge = object; huge.put(36, 100_000, 4); huge.put(0, apfsFletcher64(huge), 8)
        #expect(throws: ScanError.self) { try APFSKeybag.entries(in: huge, type: APFSKeybag.containerType) }
        // DER that overruns its container fails instead of reading past it.
        #expect(throws: ScanError.self) { try DERElement.elements(in: Data([0x30, 0x82, 0xff, 0xff, 0x00])) }
        #expect(throws: ScanError.self) { try APFSWrappedKey(Data([0x30, 0x03, 0xa3, 0x01, 0x00])) }
    }
}

// MARK: - Reading encrypted content

private struct XTSDecryptor: ContentDecryptor {
    let cipher: AESXTS
    func decrypt(_ ciphertext: Data, firstDataUnit: UInt64) throws -> Data { try cipher.decrypt(ciphertext, firstDataUnit: firstDataUnit) }
}

@Suite("Encrypted file content")
struct EncryptedContentTests {
    @Test func encryptedRunsDecryptAcrossChunksTailsAndHoles() async throws {
        let cipher = try xts(String(repeating: "ab", count: 16), String(repeating: "cd", count: 16))
        // Two extents with unrelated tweaks (as `crypto_id` allows), a hole between them, and a
        // file that ends mid data unit.
        let first = Data((0..<4096).map { UInt8($0 % 251) }), second = Data((0..<4096).map { UInt8($0 % 241) })
        var image = Data(count: 8192 + 4096 * 2)
        image.replaceSubrange(4096..<8192, with: try cipher.encrypt(first, firstDataUnit: 800))
        image.replaceSubrange(12288..<16384, with: try cipher.encrypt(second, firstDataUnit: 77))
        let size: Int64 = 4096 + 1000 + 3000
        let runs = [DataRun(deviceOffset: 4096, length: 4096, firstDataUnit: 800), DataRun(deviceOffset: nil, length: 1000),
                    DataRun(deviceOffset: 12288, length: 3000, firstDataUnit: 77)]
        let file = RecoveredFile(name: "f", path: "/f", sizeBytes: size,
                                 sourceMetadata: SourceMetadata(filesystem: .apfs, volumeOffset: 0, recordOffset: 0, allocationStart: 0, contiguous: false, rawRecord: Data()),
                                 content: .encryptedRuns(runs, keyID: "abc-key"))
        let expected = first + Data(count: 1000) + second.prefix(3000)
        for chunkSize in [512, 1000, 1536, 1 << 20] {
            let reader = FileContentReader(reader: ImageReader(data: image), chunkSize: chunkSize, decryptors: ["ABC-KEY": XTSDecryptor(cipher: cipher)])
            #expect(try await reader.prefix(of: file, limit: size) == expected, "chunk size \(chunkSize)")
            #expect(try await reader.prefix(of: file, limit: 700) == expected.prefix(700))
        }
        // Without the volume's decryptor the content is locked, never returned as ciphertext.
        let locked = FileContentReader(reader: ImageReader(data: image))
        #expect(throws: FileContentError.locked) { try locked.validate(file) }
        await #expect(throws: FileContentError.locked) { _ = try await locked.prefix(of: file, limit: 10) }
        // A placed run without its data unit, or whose rounded-up ciphertext leaves the device, is rejected.
        let noTweak = RecoveredFile(name: "f", path: "/f", sizeBytes: 10, sourceMetadata: file.sourceMetadata,
                                    content: .encryptedRuns([DataRun(deviceOffset: 0, length: 10)], keyID: "abc-key"))
        let reader = FileContentReader(reader: ImageReader(data: image), decryptors: ["abc-key": XTSDecryptor(cipher: cipher)])
        #expect(throws: FileContentError.runOutsideDevice) { try reader.validate(noTweak) }
        let pastEnd = RecoveredFile(name: "f", path: "/f", sizeBytes: 10, sourceMetadata: file.sourceMetadata,
                                    content: .encryptedRuns([DataRun(deviceOffset: Int64(image.count) - 10, length: 10, firstDataUnit: 1)], keyID: "abc-key"))
        #expect(throws: FileContentError.runOutsideDevice) { try reader.validate(pastEnd) }
        #expect(pastEnd.isUnmapped == false)
    }

    @Test func encryptedRunsCoalesceOnlyWhenTheTweakContinues() {
        let continuing = APFSContainer.coalesce([DataRun(deviceOffset: 4096, length: 4096, firstDataUnit: 8),
                                                 DataRun(deviceOffset: 8192, length: 4096, firstDataUnit: 16)])
        #expect(continuing == [DataRun(deviceOffset: 4096, length: 8192, firstDataUnit: 8)])
        let jumping = APFSContainer.coalesce([DataRun(deviceOffset: 4096, length: 4096, firstDataUnit: 8),
                                              DataRun(deviceOffset: 8192, length: 4096, firstDataUnit: 900)])
        #expect(jumping.count == 2)
    }
}

// MARK: - A real FileVault volume (diskutil apfs addVolume … -passphrase)

private let diskutilAvailable = FileManager.default.isExecutableFile(atPath: "/usr/sbin/diskutil")
    && FileManager.default.isExecutableFile(atPath: "/usr/bin/hdiutil")
    && ProcessInfo.processInfo.environment["SALVAGE_SKIP_HDIUTIL"] == nil

/// A disposable raw (UDIF) image holding one encrypted APFS volume, made without `sudo` in a
/// private temp directory; only devices this image attached are ever touched, and it is detached
/// in `destroy()`/`deinit`. A 64 MB container allows one volume, so the default one is deleted
/// and the encrypted one added in its place. `layout` is hdiutil's partition layout: `GPTSPUD`
/// puts the container in a GPT partition at a non-zero offset, `NONE` at offset 0.
private final class EncryptedScratchImage {
    let directory: URL
    let imageURL: URL
    let volumeName: String
    let password: String
    private(set) var wholeDisk: String?
    private(set) var mountPoint: URL?

    init(password: String, layout: String) throws {
        self.password = password
        volumeName = "SalvageFV" + String(UUID().uuidString.prefix(8))
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("salvage-fv-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        imageURL = directory.appendingPathComponent("image.dmg")
        _ = try Self.run("/usr/bin/hdiutil", ["create", "-quiet", "-size", "64m", "-fs", "APFS", "-volname", "Plain",
                                              "-layout", layout, "-type", "UDIF", imageURL.path])
        let output = try Self.run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-nomount", imageURL.path])
        let disks = output.split(separator: "\n").compactMap { $0.split(separator: "\t").first.map { $0.trimmingCharacters(in: .whitespaces) } }
            .filter { $0.hasPrefix("/dev/disk") }
        wholeDisk = disks.first
        // The synthesized container disk is the one whose first volume is "<container>s1"; with a
        // partition map the image's own disk (with its partition "s1") comes first, so take the last.
        guard let container = disks.last(where: { disk in disks.contains(disk + "s1") }) else {
            throw ScanError.io("No APFS container in: \(output)")
        }
        _ = try Self.run("/usr/sbin/diskutil", ["apfs", "deleteVolume", container + "s1"])
        _ = try Self.run("/usr/sbin/diskutil", ["apfs", "addVolume", container, "APFS", volumeName, "-passphrase", password])
        let info = try Self.run("/usr/sbin/diskutil", ["info", container + "s1"])
        guard let line = info.split(separator: "\n").first(where: { $0.contains("Mount Point:") }),
              let path = line.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces), path.hasPrefix("/") else {
            throw ScanError.io("The encrypted volume didn't mount: \(info)")
        }
        mountPoint = URL(fileURLWithPath: path)
    }

    /// Detaches the whole image (the volume is unmounted and locked with it).
    func detach() {
        if let wholeDisk { _ = try? Self.run("/usr/bin/hdiutil", ["detach", "-force", wholeDisk]); self.wholeDisk = nil; mountPoint = nil }
    }

    func destroy() {
        detach()
        try? FileManager.default.removeItem(at: directory)
    }

    deinit { destroy() }

    static func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        // Never echo the arguments: one of them is the test password.
        guard process.terminationStatus == 0 else { throw ScanError.io("\((executable as NSString).lastPathComponent) failed: \(output)") }
        return output
    }
}

/// nil for success, else the error (Result<Void, _> isn't Equatable).
private func outcome(_ result: Result<Void, UnlockError>) -> UnlockError?? {
    switch result { case .success: .some(nil); case .failure(let error): .some(error) }
}

private actor EventLog {
    var events: [ScanEvent] = []
    func add(_ event: ScanEvent) { events.append(event) }
}

private final class NoticeLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [ScanNotice] = []
    func add(_ notice: ScanNotice) { lock.withLock { stored.append(notice) } }
    var notices: [ScanNotice] { lock.withLock { stored } }
}

/// A full `ScanSession` (discovery, parsers, sweep): its events without progress, and its notices.
private func scanSession(_ reader: any BlockReader, credentials: [String: VolumeCredential]) async -> (events: [ScanEvent], notices: [ScanNotice]) {
    let (stream, continuation) = AsyncStream<ScanEvent>.makeStream(bufferingPolicy: .bufferingOldest(64))
    let (noticeStream, notices) = AsyncStream<ScanNotice>.makeStream()
    let task = Task { await ScanSession(reader: reader).run(events: continuation, notices: notices, credentials: credentials) }
    let collected = Task { var all: [ScanNotice] = []; for await notice in noticeStream { all.append(notice) }; return all }
    var events: [ScanEvent] = []
    for await event in stream { if case .progress = event { continue }; events.append(event) }
    await task.value
    notices.finish()
    return (events, await collected.value)
}

/// Drives `APFSContainer` alone over the image's APFS partition: no discovery, no sweep.
private func containerEvents(_ reader: any BlockReader, extent: VolumeExtent, credentials: [String: VolumeCredential],
                             notice: @escaping @Sendable (ScanNotice) -> Void = { _ in }) async throws -> [ScanEvent] {
    let log = EventLog()
    try await APFSContainer(reader: reader, extent: extent, device: nil, credentials: credentials, notice: notice,
                            emit: { await log.add($0) }).scan()
    return await log.events
}

/// Reads an image, letting `patch` rewrite any 4096-byte container block on the way (to corrupt
/// or alter metadata without editing the image). `base` is the container's device offset; the
/// patch sees container-relative block numbers.
private struct PatchingReader: BlockReader {
    let data: Data
    var base: Int64 = 0
    let patch: @Sendable (_ block: Int64, _ bytes: inout Data) -> Void
    var sizeBytes: Int64 { Int64(data.count) }
    func read(at offset: Int64, count: Int) async throws -> Data {
        var result = data.subdata(in: Int(offset)..<Int(offset) + count)
        var start = (offset + 4095) / 4096 * 4096
        while start + 4096 <= offset + Int64(count) {
            let range = Int(start - offset)..<Int(start - offset) + 4096
            // Only blocks that could be metadata are offered (an all-zero first word never is).
            if start >= base, result[range.lowerBound..<range.lowerBound + 8].contains(where: { $0 != 0 }) {
                var piece = result.subdata(in: range)
                patch((start - base) / 4096, &piece)
                result.replaceSubrange(range, with: piece)
            }
            start += 4096
        }
        return result
    }
}

private func isUnlockRequest(_ event: ScanEvent) -> Bool { if case .unlockRequired = event { true } else { false } }
private func isMetadataFile(_ event: ScanEvent) -> Bool { if case .found(let file) = event { file.recoveryMethod == .metadata } else { false } }

@Suite("A real FileVault volume", .enabled(if: diskutilAvailable), .serialized)
struct FileVaultRealImageTests {
    struct Written { let path: String; let data: Data }

    /// Builds the image, writes files with known contents, deletes one, and detaches. Returns the
    /// raw image bytes plus what was written.
    fileprivate func makeImage(layout: String) throws -> (image: EncryptedScratchImage, data: Data, kept: [Written], deleted: [Written], uuid: String) {
        let image = try EncryptedScratchImage(password: "fv-test-\(UUID().uuidString.prefix(6))", layout: layout)
        let root = try #require(image.mountPoint)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("docs"), withIntermediateDirectories: true)
        var generator = SystemRandomNumberGenerator()
        func random(_ count: Int) -> Data { Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) }) }
        let kept = [Written(path: "/note.txt", data: Data("FileVault note: the quick brown fox.\n".utf8)),
                    Written(path: "/docs/big.bin", data: random(3_000_000)), Written(path: "/docs/mid.dat", data: random(70_001)),
                    Written(path: "/docs/empty.txt", data: Data())]
        let deleted = [Written(path: "/docs/gone.bin", data: random(100_000))]
        for file in kept + deleted { try file.data.write(to: root.appendingPathComponent(String(file.path.dropFirst()))) }
        _ = try? EncryptedScratchImage.run("/bin/sync", []); Thread.sleep(forTimeInterval: 1.5)
        for file in deleted { try FileManager.default.removeItem(at: root.appendingPathComponent(String(file.path.dropFirst()))) }
        _ = try? EncryptedScratchImage.run("/bin/sync", []); Thread.sleep(forTimeInterval: 1.5)
        let info = try EncryptedScratchImage.run("/usr/sbin/diskutil", ["info", root.path])
        let uuidLine = try #require(info.split(separator: "\n").first { $0.contains("Volume UUID:") })
        let uuid = String(uuidLine.split(separator: ":", maxSplits: 1)[1]).trimmingCharacters(in: .whitespaces)
        image.detach()
        return (image, try Data(contentsOf: image.imageURL), kept, deleted, uuid)
    }

    /// `GPTSPUD` puts the container in a partition at a non-zero device offset, so a tweak or block
    /// address taken device-relative instead of container-relative would fail; `NONE` keeps the
    /// container at offset 0.
    @Test(arguments: ["GPTSPUD", "NONE"])
    func correctPasswordListsAndDecryptsFilesWrongPasswordAndCorruptKeybagFailClosed(layout: String) async throws {
        let (image, data, kept, deleted, uuid) = try makeImage(layout: layout)
        defer { image.destroy() }
        let apfs = try #require(try await VolumeDiscovery(reader: ImageReader(data: data)).discover().extents.first { $0.format == .apfs })
        if layout == "NONE" { #expect(apfs.offset == 0) } else { #expect(apfs.offset > 0) }
        #expect(apfs.offset % 4096 == 0)
        let base = Int(apfs.offset)
        #expect(String(decoding: data[base + 32..<base + 36], as: UTF8.self) == "NXSB")

        // No credential: exactly as before Story 2.5.
        let locked = try await containerEvents(ImageReader(data: data), extent: apfs, credentials: [:])
        #expect(locked.contains { if case .unlockRequired(let device) = $0 { device.encryptedVolumeUUID?.uppercased() == uuid.uppercased() } else { false } })
        #expect(!locked.contains(where: isMetadataFile))

        // The correct password: every file listed, content byte-identical after decryption.
        let credential = VolumeCredential(kind: .password, secret: image.password)
        #expect(outcome(await EncryptedVolumeUnlock.verify(reader: ImageReader(data: data), volumeUUID: uuid, credential: credential)) == .some(nil))
        let (events, _) = await scanSession(ImageReader(data: data), credentials: [uuid.lowercased(): credential])
        #expect(events.last == .completed, "\(String(describing: events.last))")
        #expect(!events.contains(where: isUnlockRequest))
        let decryptor = try #require(credential.decryptor)
        credential.zero()
        let files = events.compactMap { if case .found(let file) = $0, file.recoveryMethod == .metadata { file } else { nil } }
        let reader = FileContentReader(reader: ImageReader(data: data), decryptors: [uuid: decryptor])
        // macOS adds its own `.fseventsd` logs to a volume it mounted; they're real files too.
        let live = files.filter { !$0.isDeleted && !$0.path.hasPrefix("/.fseventsd/") }
        #expect(files.contains { $0.path.hasPrefix("/.fseventsd/") })
        #expect(Set(live.map(\.path)) == Set(kept.map(\.path)))
        for expected in kept {
            let file = try #require(live.first { $0.path == expected.path })
            #expect(file.sizeBytes == Int64(expected.data.count))
            if expected.data.isEmpty { continue }
            guard case .encryptedRuns(let runs, let keyID) = file.content else { Issue.record("\(file.path) isn't encrypted content"); continue }
            #expect(keyID.uppercased() == uuid.uppercased())
            // Runs are device-relative, inside the partition.
            #expect(runs.allSatisfy { ($0.deviceOffset ?? apfs.offset) >= apfs.offset })
            #expect(try await reader.prefix(of: file, limit: file.sizeBytes) == expected.data, "\(expected.path)")
            // The raw bytes on disk really are ciphertext.
            #expect(data.range(of: expected.data.prefix(64)) == nil)
        }
        // Deleted files from an older checkpoint whose blocks are still pending free.
        let recovered = files.filter(\.isDeleted)
        #expect(Set(recovered.map(\.path)) == Set(deleted.map(\.path)))
        for expected in deleted {
            let file = try #require(recovered.first { $0.path == expected.path })
            #expect(try await reader.prefix(of: file, limit: file.sizeBytes) == expected.data)
        }

        // A wrong password: wrongPassword, nothing parsed, the unlock request stays.
        let wrong = VolumeCredential(kind: .password, secret: "not-the-password")
        #expect(outcome(await EncryptedVolumeUnlock.verify(reader: ImageReader(data: data), volumeUUID: uuid, credential: wrong)) == .some(.wrongPassword))
        let wrongEvents = try await containerEvents(ImageReader(data: data), extent: apfs, credentials: [uuid: wrong])
        #expect(wrong.failure == .wrongPassword && wrong.decryptor == nil)
        #expect(wrongEvents.contains(where: isUnlockRequest))
        #expect(!wrongEvents.contains(where: isMetadataFile))

        // A corrupt container keybag: fail closed, `.unlockRequired` remains, no garbage files.
        let keylocker = Int64(try data.number(base + APFS.keylockerOffset, 8))
        #expect(keylocker > 0)
        let corruptReader = PatchingReader(data: data, base: apfs.offset) { block, bytes in if block == keylocker { bytes[100] ^= 0x5a } }
        let corrupt = VolumeCredential(kind: .password, secret: image.password)
        #expect(outcome(await EncryptedVolumeUnlock.verify(reader: corruptReader, volumeUUID: uuid, credential: corrupt)) == .some(.toolFailure))
        let corruptEvents = try await containerEvents(corruptReader, extent: apfs, credentials: [uuid: corrupt])
        #expect(corruptEvents.contains(where: isUnlockRequest))
        #expect(!corruptEvents.contains { if case .found = $0 { true } else { false } })
        #expect(corrupt.failure == .toolFailure)

        // A volume whose files don't all use the volume key (no ONEKEY: per-file keys, how
        // hardware-encrypted volumes are laid out) is unsupported, not a wrong password.
        let perFileKeys = PatchingReader(data: data, base: apfs.offset) { _, bytes in
            guard bytes.count == 4096, String(decoding: bytes[32..<36], as: UTF8.self) == "APSB" else { return }
            bytes[264] &= ~UInt8(APFS.fsOneKey)
            bytes.put(0, apfsFletcher64(bytes), 8)
        }
        let hardware = VolumeCredential(kind: .password, secret: image.password)
        #expect(outcome(await EncryptedVolumeUnlock.verify(reader: perFileKeys, volumeUUID: uuid, credential: hardware)) == .some(.unsupported))

        // The right password but a damaged file tree (every encrypted node's ciphertext altered,
        // so none decrypts to a verified node): `.damaged`, not "tied to another Mac", and the
        // scan reports the volume skipped (`.volumeSkipped`) instead of asking for an unlock.
        let probe = APFSContainer(reader: ImageReader(data: data), extent: apfs, device: nil,
                                  credentials: [uuid: VolumeCredential(kind: .password, secret: image.password)], emit: { _ in })
        try await probe.scan()
        let encryptedNodes = Set(await probe.nodeCache.keys.filter(\.decrypted).map(\.address))
        #expect(!encryptedNodes.isEmpty)
        let damagedReader = PatchingReader(data: data, base: apfs.offset) { block, bytes in
            if encryptedNodes.contains(block) { bytes[200] ^= 0x5a }
        }
        let damaged = VolumeCredential(kind: .password, secret: image.password)
        #expect(outcome(await EncryptedVolumeUnlock.verify(reader: damagedReader, volumeUUID: uuid, credential: damaged)) == .some(.damaged))
        let damagedNotices = NoticeLog()
        let damagedScan = VolumeCredential(kind: .password, secret: image.password)
        let damagedEvents = try await containerEvents(damagedReader, extent: apfs, credentials: [uuid: damagedScan], notice: { damagedNotices.add($0) })
        #expect(damagedScan.failure == .damaged)
        #expect(!damagedEvents.contains(where: isMetadataFile))
        #expect(!damagedEvents.contains(where: isUnlockRequest))
        let skipped = ScanNotice.volumeSkipped(formatName: "APFS", offset: apfs.offset, reason: APFSContainer.damagedUnlockedVolumeReason)
        #expect(damagedNotices.notices == [skipped])
        // Through a whole scan too (scanVolume hands APFS the session's notice channel).
        let session = await scanSession(damagedReader, credentials: [uuid: VolumeCredential(kind: .password, secret: image.password)])
        #expect(session.events.last == .completed)
        #expect(session.notices.contains(skipped))
        #expect(!session.events.contains(where: isUnlockRequest))

        // A credential whose key was recorded keeps working after its secret is zeroed (the flow
        // re-scans with every volume unlocked so far), and only with the right key.
        #expect(credential.isZeroed)
        let again = try await containerEvents(ImageReader(data: data), extent: apfs, credentials: [uuid: credential])
        let againFiles = again.compactMap { if case .found(let file) = $0, file.recoveryMethod == .metadata, !file.isDeleted { file } else { nil } }
        #expect(Set(againFiles.map(\.path)).isSuperset(of: kept.map(\.path)))
    }
}
