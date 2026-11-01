import Darwin
import Foundation
import SalvageCore
import Testing
@testable import SalvageDiskIO

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

    /// Blocking subprocess work runs on a GCD global queue: not the main thread, and not
    /// one of the cooperative pool's few threads.
    @Test func blockingWorkRunsOnAGlobalQueueNotTheCooperativePool() async {
        let (label, isMain) = await offCooperativePool { (String(cString: __dispatch_queue_get_label(nil)), Thread.isMainThread) }
        #expect(!isMain)
        #expect(label.hasPrefix("com.apple.root."), "\(label)")
        #expect(!label.contains("cooperative"), "\(label)")
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
        // The child exits at once without reading. The input is well past the pipe buffer (64 KB
        // on macOS), so the writer is guaranteed to block on a full pipe and then see the read end
        // close: it must come back with EPIPE (never SIGPIPE) and never hang the runner.
        let input = SensitiveBytes([UInt8](repeating: UInt8(ascii: "x"), count: 256 * 1024))
        let started = ContinuousClock.now
        let output = try #require(runBoundedProcess(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "exit 0"], input: input, timeout: 10))
        #expect(output.status == 0)
        #expect(started.duration(to: .now) < .seconds(10))
    }

    @Test func plistFromProcessStillDecodesStdout() throws {
        let plist = try #require(plistFromProcess(executable: URL(fileURLWithPath: "/bin/sh"),
                                                  arguments: ["-c", #"printf '<plist version="1.0"><dict><key>a</key><integer>1</integer></dict></plist>'"#], timeout: 10))
        #expect(plist["a"] as? Int == 1)
        #expect(plistFromProcess(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "exit 1"], timeout: 10) == nil)
    }
}
