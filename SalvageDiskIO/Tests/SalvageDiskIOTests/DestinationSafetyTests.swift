import Foundation
import SalvageCore
import Testing
@testable import SalvageDiskIO

@Suite("Destination safety")
struct DestinationSafetyTests {
    let source = BlockDevice(bsdName: "disk6", displayName: "Source", sizeBytes: 1 << 30,
                             isInternal: false, isBootVolume: false)
    let destination = URL(fileURLWithPath: "/Volumes/Backup/Recovered")

    /// Physical stores keyed by whole disk; unknown disks are their own physical disk.
    func safety(mount: String?, stores: [String: Set<String>] = [:], failing: Set<String> = []) -> DestinationSafety {
        DestinationSafety(mountSource: { _ in mount },
                          physicalDisks: { failing.contains($0) ? nil : (stores[$0] ?? [$0]) })
    }

    @Test func differentPhysicalDiskIsSafe() {
        #expect(safety(mount: "/dev/disk7s1").check(destination: destination, source: source) == .safe)
    }

    @Test func partitionOfSourceDiskIsBlocked() {
        #expect(safety(mount: "/dev/disk6s2").check(destination: destination, source: source) == .sameDevice)
    }

    @Test func apfsContainerBackedBySourceIsBlocked() {
        // Destination on synthesized container disk9, whose physical store is disk6s2.
        let check = safety(mount: "/dev/disk9s1", stores: ["disk9": ["disk6"]])
        #expect(check.check(destination: destination, source: source) == .sameDevice)
    }

    @Test func sourceContainerSharingPhysicalDiskIsBlocked() {
        // Source is a synthesized container (disk9 on disk6); destination is another disk6 partition.
        let container = BlockDevice(bsdName: "disk9", displayName: "Container", sizeBytes: 1 << 30,
                                    isInternal: false, isBootVolume: false)
        let check = safety(mount: "/dev/disk6s1", stores: ["disk9": ["disk6"]])
        #expect(check.check(destination: destination, source: container) == .sameDevice)
    }

    @Test func unknownMountFailsClosed() {
        #expect(safety(mount: nil).check(destination: destination, source: source) == .undetermined)
        #expect(safety(mount: "//user@server/share").check(destination: destination, source: source) == .undetermined)
        #expect(safety(mount: "//user@server/disk7").check(destination: destination, source: source) == .undetermined)
        #expect(safety(mount: "map auto_home").check(destination: destination, source: source) == .undetermined)
    }

    @Test func physicalStoreFailureFailsClosed() {
        #expect(safety(mount: "/dev/disk7s1", failing: ["disk7"]).check(destination: destination, source: source) == .undetermined)
        #expect(safety(mount: "/dev/disk7s1", failing: ["disk6"]).check(destination: destination, source: source) == .undetermined)
    }

    @Test func nonFileURLFailsClosed() {
        let remote = URL(string: "ftp://example.invalid/folder")!
        #expect(safety(mount: "/dev/disk7s1").check(destination: remote, source: source) == .undetermined)
    }

    @Test func liveStatfsResolvesTemporaryDirectory() {
        // Read-only metadata query against the test's own temporary directory.
        let mount = mountSourceName(ofPath: FileManager.default.temporaryDirectory.path)
        #expect(mount?.isEmpty == false)
        #expect(mountSourceName(ofPath: "/nonexistent-\(UUID().uuidString)") == nil)
    }
}
