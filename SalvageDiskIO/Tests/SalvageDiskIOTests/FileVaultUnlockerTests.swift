import Darwin
import Foundation
import SalvageCore
import Testing
@testable import SalvageDiskIO

// Story 2.4: the FileVault unlocker over an injected `diskutil`. No real diskutil runs here; the
// only live subprocesses are /bin/cat, /bin/sh and /bin/sleep for the bounded runner itself.

/// Records every `diskutil` invocation (arguments and a snapshot of the stdin bytes) and answers
/// from a table keyed by the diskutil subcommand.
final class DiskUtilFake: @unchecked Sendable {
    struct Call: Equatable { let arguments: [String]; let input: [UInt8]? }
    private let lock = NSLock()
    private var recorded: [Call] = []
    private var responses: [String: BoundedProcessOutput?]

    init(_ responses: [String: BoundedProcessOutput?]) { self.responses = responses }

    var calls: [Call] { lock.withLock { recorded } }

    func run(_ arguments: [String], _ input: SensitiveBytes?) -> BoundedProcessOutput? {
        let snapshot = input.map { $0.withUnsafeBytes { Array($0) } }
        lock.withLock { recorded.append(Call(arguments: arguments, input: snapshot)) }
        guard arguments.count >= 2, let response = responses[arguments[1]] else { return nil }
        return response
    }

    var unlocker: FileVaultUnlocker { FileVaultUnlocker(run: run) }
}

private let secretUUID = "34CFAFFA-3ECE-46A6-937D-93E622EAA34B"

private func plistData(_ object: [String: Any]) -> Data {
    try! PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
}

/// The spike image: one container (disk19 on store disk18s1) with a plain and an encrypted volume.
func sampleListPlist(secretLocked: Bool = true, secretEncrypted: Bool = true) -> [String: Any] {
    ["Containers": [[
        "ContainerReference": "disk19",
        "PhysicalStores": [["DeviceIdentifier": "disk18s1", "DiskUUID": "E8BA64D7-8870-4994-8337-1C1CBA46B925"]],
        "Volumes": [
            ["APFSVolumeUUID": "C4B7686F-BBB2-4B3E-813B-94F5A1AD9C28", "DeviceIdentifier": "disk19s1", "Name": "SpikePlain",
             "Encryption": false, "FileVault": false, "Locked": false, "Roles": []],
            ["APFSVolumeUUID": secretUUID.lowercased(), "DeviceIdentifier": "disk19s2", "Name": "Secret",
             "Encryption": secretEncrypted, "FileVault": secretEncrypted, "Locked": secretLocked, "Roles": []],
        ],
    ]]]
}

private func listOutput(secretLocked: Bool = true, secretEncrypted: Bool = true) -> BoundedProcessOutput {
    BoundedProcessOutput(status: 0, standardOutput: plistData(sampleListPlist(secretLocked: secretLocked, secretEncrypted: secretEncrypted)), standardError: Data())
}

private let unlockedOutput = BoundedProcessOutput(
    status: 0, standardOutput: plistData(["Success": true, "DiskManagementErrorCode": 0, "CryptoUserUUID": secretUUID]),
    standardError: Data("Unlocking any cryptographic user on APFS Volume disk19s2\nUnlocked but did not mount APFS Volume\n".utf8))

private let wrongPasswordByCode = BoundedProcessOutput(
    status: 1, standardOutput: plistData(["Success": false, "DiskManagementErrorCode": -69591, "RateLimitStateLockout": false]),
    standardError: Data("Passphrase incorrect or user does not exist\n".utf8))

private let wrongPasswordByText = BoundedProcessOutput(
    status: 1, standardOutput: Data("Passphrase incorrect or user does not exist\nUnlocking any cryptographic user on APFS Volume disk19s2\n".utf8),
    standardError: Data())

private let notFoundOutput = BoundedProcessOutput(status: 1, standardOutput: Data("Could not find APFS Volume disk19s2\n".utf8), standardError: Data())

@Suite("FileVault unlocker")
struct FileVaultUnlockerTests {
    @Test func unlocksThroughStdinAndReportsTheVolume() async {
        let fake = DiskUtilFake(["list": listOutput(), "unlockVolume": unlockedOutput])
        let credential = UnlockCredential(kind: .password, secret: "spike-pass-123")
        let result = await fake.unlocker.unlock(volumeUUID: secretUUID.lowercased(), credential: credential)
        #expect(result == .success(UnlockedVolume(volumeUUID: secretUUID, bsdName: "disk19s2", name: "Secret")))
        let calls = fake.calls
        #expect(calls.count == 2)
        #expect(calls[0] == .init(arguments: ["apfs", "list", "-plist"], input: nil))
        #expect(calls[1].arguments == ["apfs", "unlockVolume", "disk19s2", "-nomount", "-stdinpassphrase", "-plist"])
        // The secret reaches diskutil through stdin only: never an argument, never the UUID.
        #expect(calls[1].input == Array("spike-pass-123".utf8))
        #expect(!calls.flatMap(\.arguments).contains { $0.contains("spike-pass") })
        #expect(credential.isZeroed)
        #expect(credential.count == "spike-pass-123".utf8.count)
    }

    @Test(arguments: [wrongPasswordByCode, wrongPasswordByText])
    func wrongPasswordIsDistinguished(_ output: BoundedProcessOutput) async {
        let fake = DiskUtilFake(["list": listOutput(), "unlockVolume": output])
        let credential = UnlockCredential(kind: .recoveryKey, secret: "not-the-key")
        #expect(await fake.unlocker.unlock(volumeUUID: secretUUID, credential: credential) == .failure(.wrongPassword))
        #expect(credential.isZeroed)
    }

    @Test func toolFailuresAreNotWrongPassword() async {
        // diskutil failing for another reason, timing out, or being too old to answer.
        for output: BoundedProcessOutput? in [notFoundOutput, nil, BoundedProcessOutput(status: 0, standardOutput: plistData(["Success": false]), standardError: Data())] {
            let fake = DiskUtilFake(["list": listOutput(), "unlockVolume": output])
            let credential = UnlockCredential(kind: .password, secret: "pw")
            #expect(await fake.unlocker.unlock(volumeUUID: secretUUID, credential: credential) == .failure(.toolFailure))
            #expect(credential.isZeroed)
        }
    }

    @Test func listingProblemsRefuseBeforeTheCredentialIsUsed() async {
        let unlisted = "11111111-2222-3333-4444-555555555555"
        let cases: [(DiskUtilFake, String)] = [
            (DiskUtilFake(["list": nil, "unlockVolume": unlockedOutput]), secretUUID),
            (DiskUtilFake(["list": BoundedProcessOutput(status: 1, standardOutput: Data(), standardError: Data()), "unlockVolume": unlockedOutput]), secretUUID),
            (DiskUtilFake(["list": listOutput(), "unlockVolume": unlockedOutput]), unlisted),
            // An unencrypted volume has nothing to unlock.
            (DiskUtilFake(["list": listOutput(secretLocked: false, secretEncrypted: false), "unlockVolume": unlockedOutput]), secretUUID),
        ]
        for (fake, uuid) in cases {
            let credential = UnlockCredential(kind: .password, secret: "pw")
            #expect(await fake.unlocker.unlock(volumeUUID: uuid, credential: credential) == .failure(.toolFailure))
            #expect(fake.calls.map(\.arguments) == [["apfs", "list", "-plist"]])
            #expect(credential.isZeroed)
        }
    }

    @Test func alreadyUnlockedVolumeSucceedsWithoutRunningUnlock() async {
        let fake = DiskUtilFake(["list": listOutput(secretLocked: false), "unlockVolume": wrongPasswordByCode])
        let credential = UnlockCredential(kind: .password, secret: "irrelevant")
        #expect(await fake.unlocker.unlock(volumeUUID: secretUUID, credential: credential)
                == .success(UnlockedVolume(volumeUUID: secretUUID, bsdName: "disk19s2", name: "Secret")))
        #expect(fake.calls.count == 1)
        #expect(credential.isZeroed)
    }

    @Test(arguments: ["", "disk19s2", "-nomount", "34CFAFFA-3ECE-46A6-937D-93E622EAA34B -plist", "34CFAFFA3ECE46A6937D93E622EAA34B",
                      "34CFAFFA-3ECE-46A6-937D-93E622EAA34G", "../34CFAFFA-3ECE-46A6-937D-93E622EAA34B"])
    func malformedUUIDIsRefusedBeforeAnyProcess(_ uuid: String) async {
        let fake = DiskUtilFake(["list": listOutput(), "unlockVolume": unlockedOutput])
        let credential = UnlockCredential(kind: .password, secret: "pw")
        #expect(await fake.unlocker.unlock(volumeUUID: uuid, credential: credential) == .failure(.toolFailure))
        #expect(fake.calls.isEmpty)
        #expect(credential.isZeroed)
    }

    @Test func relockRunsLockVolumeOnASliceOnly() async {
        let fake = DiskUtilFake(["lockVolume": BoundedProcessOutput(status: 0, standardOutput: Data(), standardError: Data())])
        #expect(await fake.unlocker.lock(bsdName: "disk19s2"))
        #expect(fake.calls == [.init(arguments: ["apfs", "lockVolume", "disk19s2"], input: nil)])
        for name in ["disk19", "/dev/disk19s2", "rdisk19s2", "", "disk19s2 -force"] {
            #expect(!(await fake.unlocker.lock(bsdName: name)), "\(name)")
        }
        #expect(fake.calls.count == 1)
        let failing = DiskUtilFake(["lockVolume": nil])
        #expect(!(await failing.unlocker.lock(bsdName: "disk19s2")))
    }

    @Test func unlockOutputInterpretation() {
        #expect(interpretUnlockOutput(unlockedOutput) == nil)
        #expect(interpretUnlockOutput(BoundedProcessOutput(status: 0, standardOutput: Data(), standardError: Data())) == nil)
        #expect(interpretUnlockOutput(wrongPasswordByCode) == .wrongPassword)
        #expect(interpretUnlockOutput(wrongPasswordByText) == .wrongPassword)
        // "The given APFS Volume is not locked (-69589)": the goal state already holds.
        #expect(interpretUnlockOutput(BoundedProcessOutput(status: 1, standardOutput: plistData(["Success": false, "DiskManagementErrorCode": -69589]), standardError: Data())) == nil)
        #expect(interpretUnlockOutput(BoundedProcessOutput(status: 1, standardOutput: plistData(["Success": false, "DiskManagementErrorCode": -69593]), standardError: Data())) == .toolFailure)
        #expect(interpretUnlockOutput(notFoundOutput) == .toolFailure)
        #expect(interpretUnlockOutput(nil) == .toolFailure)
    }
}

@Suite("Sensitive bytes")
struct SensitiveBytesTests {
    @Test func zeroErasesInPlaceAndIsIdempotent() {
        let bytes = SensitiveBytes(utf8: "correct horse")
        #expect(!bytes.isZeroed)
        #expect(bytes.count == 13)
        #expect(bytes.withUnsafeBytes { Array($0) } == Array("correct horse".utf8))
        bytes.zero(); bytes.zero()
        #expect(bytes.isZeroed)
        #expect(bytes.count == 13)
        #expect(bytes.withUnsafeBytes { $0.allSatisfy { $0 == 0 } })
        let empty = SensitiveBytes([])
        empty.zero()
        #expect(empty.isZeroed && empty.count == 0)
    }

    @Test func credentialWrapsKindAndZeroing() {
        let credential = UnlockCredential(kind: .recoveryKey, secret: "ABCD-EFGH")
        #expect(credential.kind == .recoveryKey)
        #expect(credential.count == 9)
        #expect(!credential.isZeroed)
        credential.zero()
        #expect(credential.isZeroed)
        #expect(credential.bytes.withUnsafeBytes { $0.allSatisfy { $0 == 0 } })
    }
}

@Suite("Bounded subprocess runner")
struct BoundedProcessTests {
    @Test func stdinReachesTheChildAndBothPipesAreCaptured() throws {
        let input = SensitiveBytes(utf8: "piped secret")
        let echoed = try #require(runBoundedProcess(executable: URL(fileURLWithPath: "/bin/cat"), arguments: [], input: input, timeout: 10))
        #expect(echoed.status == 0)
        #expect(echoed.standardOutput == Data("piped secret".utf8))
        #expect(echoed.standardError.isEmpty)
        #expect(!input.isZeroed) // The runner reads in place; erasing is the owner's call.
        input.zero()

        let both = try #require(runBoundedProcess(executable: URL(fileURLWithPath: "/bin/sh"),
                                                  arguments: ["-c", "printf out; printf err >&2; exit 3"], timeout: 10))
        #expect(both.status == 3)
        #expect(both.standardOutput == Data("out".utf8))
        #expect(both.standardError == Data("err".utf8))
    }

    @Test func timeoutAndLaunchFailureReturnNil() {
        let started = ContinuousClock.now
        #expect(runBoundedProcess(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], timeout: 0.2) == nil)
        #expect(started.duration(to: .now) < .seconds(10))
        #expect(runBoundedProcess(executable: URL(fileURLWithPath: "/nonexistent/tool"), arguments: [], timeout: 1) == nil)
    }

    @Test func childThatIgnoresStdinStillCompletes() throws {
        // The child exits without reading: the writer must not SIGPIPE or hang the runner.
        let input = SensitiveBytes(utf8: String(repeating: "x", count: 10_000))
        let output = try #require(runBoundedProcess(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "exit 0"], input: input, timeout: 10))
        #expect(output.status == 0)
    }

    @Test func plistFromProcessStillDecodesStdout() throws {
        let plist = try #require(plistFromProcess(executable: URL(fileURLWithPath: "/bin/sh"),
                                                  arguments: ["-c", #"printf '<plist version="1.0"><dict><key>a</key><integer>1</integer></dict></plist>'"#], timeout: 10))
        #expect(plist["a"] as? Int == 1)
        #expect(plistFromProcess(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "exit 1"], timeout: 10) == nil)
    }
}
