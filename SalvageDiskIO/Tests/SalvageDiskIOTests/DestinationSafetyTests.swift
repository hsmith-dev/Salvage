import Foundation
import SalvageCore
import Testing
@testable import SalvageDiskIO

@Suite("Destination safety")
struct DestinationSafetyTests {
    let source = BlockDevice(bsdName: "disk6", displayName: "Source", sizeBytes: 1 << 30,
                             isInternal: false, isBootVolume: false)
    let destination = URL(fileURLWithPath: "/Volumes/Backup/Recovered")

    /// Physical stores keyed by whole disk; unknown disks are their own physical disk. `mounts`
    /// maps other paths (disk image files) to their volume; `backings` marks virtual disks.
    func safety(mount: String?, stores: [String: Set<String>] = [:], failing: Set<String> = [],
                mounts: [String: String] = [:], backings: [String: DiskBacking?] = [:],
                identities: [String: UInt64] = [:]) -> DestinationSafety {
        DestinationSafety(mountSource: { path in mounts[path] ?? mount },
                          physicalDisks: { failing.contains($0) ? nil : (stores[$0] ?? [$0]) },
                          backing: { disk in backings.keys.contains(disk) ? backings[disk]! : .physical },
                          mediaIdentity: { identities[$0] })
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

    // MARK: Virtual disks (disk images, AppleRAID, CoreStorage)

    @Test func diskImageWhoseFileLivesOnTheSourceIsBlocked() {
        // Destination volume disk7s1 is a disk image whose file sits on the source's disk6s2.
        let check = safety(mount: "/dev/disk7s1", mounts: ["/Volumes/Source/backup.dmg": "/dev/disk6s2"],
                           backings: ["disk7": .diskImage(path: "/Volumes/Source/backup.dmg")])
        #expect(check.check(destination: destination, source: source) == .sameDevice)
    }

    @Test func diskImageOnAnotherDriveIsSafe() {
        let check = safety(mount: "/dev/disk7s1", mounts: ["/Volumes/Other/backup.dmg": "/dev/disk8s1"],
                           backings: ["disk7": .diskImage(path: "/Volumes/Other/backup.dmg")])
        #expect(check.check(destination: destination, source: source) == .safe)
    }

    @Test func nestedDiskImagesAreFollowedToTheSource() {
        // APFS container disk9 on image disk7, whose file is on image disk8, whose file is on disk6.
        let check = safety(mount: "/dev/disk9s1", stores: ["disk9": ["disk7"]],
                           mounts: ["/Volumes/A/outer.dmg": "/dev/disk8s1", "/Volumes/B/inner.sparseimage": "/dev/disk6s1"],
                           backings: ["disk7": .diskImage(path: "/Volumes/A/outer.dmg"),
                                      "disk8": .diskImage(path: "/Volumes/B/inner.sparseimage")])
        #expect(check.check(destination: destination, source: source) == .sameDevice)
    }

    @Test func unresolvableVirtualDisksFailClosed() {
        // AppleRAID / CoreStorage, an image missing from hdiutil, a failed lookup, an image on a share.
        #expect(safety(mount: "/dev/disk7s1", backings: ["disk7": .unknownVirtual]).check(destination: destination, source: source) == .undetermined)
        #expect(safety(mount: "/dev/disk7s1", backings: ["disk7": nil]).check(destination: destination, source: source) == .undetermined)
        let onShare = safety(mount: "/dev/disk7s1", mounts: ["/Volumes/Share/x.dmg": "//user@server/share"],
                             backings: ["disk7": .diskImage(path: "/Volumes/Share/x.dmg")])
        #expect(onShare.check(destination: destination, source: source) == .undetermined)
    }

    @Test func diskImageCycleIsBoundedAndFailsClosed() {
        // An image whose file is (impossibly) on itself must terminate, undetermined.
        let check = safety(mount: "/dev/disk7s1", mounts: ["/Volumes/Self/loop.dmg": "/dev/disk7s1"],
                           backings: ["disk7": .diskImage(path: "/Volumes/Self/loop.dmg")])
        #expect(check.check(destination: destination, source: source) == .undetermined)
    }

    @Test func diskBackingParsesDiskutilAndHdiutil() {
        let images: [String: Any] = ["images": [
            ["image-path": "/Volumes/Source/a.dmg", "system-entities": [["dev-entry": "/dev/disk7"], ["dev-entry": "/dev/disk7s1"]]],
            ["image-path": "/Users/me/b.dmg", "system-entities": [["dev-entry": "/dev/disk8"]]],
        ]]
        let image: [String: Any] = ["BusProtocol": "Disk Image", "VirtualOrPhysical": "Virtual"]
        #expect(diskBacking(fromDiskUtilInfo: image, hdiutilInfo: images, wholeDisk: "disk7") == .diskImage(path: "/Volumes/Source/a.dmg"))
        #expect(diskBacking(fromDiskUtilInfo: image, hdiutilInfo: images, wholeDisk: "disk17") == nil)
        #expect(diskBacking(fromDiskUtilInfo: image, hdiutilInfo: nil, wholeDisk: "disk7") == nil)
        let raid: [String: Any] = ["BusProtocol": "SATA", "VirtualOrPhysical": "Virtual"]
        #expect(diskBacking(fromDiskUtilInfo: raid, hdiutilInfo: images, wholeDisk: "disk5") == .unknownVirtual)
        let container: [String: Any] = ["VirtualOrPhysical": "Virtual", "APFSPhysicalStores": [["APFSPhysicalStore": "disk0s2"]]]
        #expect(diskBacking(fromDiskUtilInfo: container, hdiutilInfo: nil, wholeDisk: "disk3") == .physical)
        #expect(diskBacking(fromDiskUtilInfo: ["BusProtocol": "USB", "VirtualOrPhysical": "Physical"], hdiutilInfo: nil, wholeDisk: "disk6") == .physical)
        #expect(diskBacking(fromDiskUtilInfo: [:], hdiutilInfo: nil, wholeDisk: "disk6") == nil)
    }

    // MARK: Source identity and the checked volume

    @Test func sourceIdentityMustStillMatchItsBSDName() {
        let scanned = BlockDevice(bsdName: "disk6", displayName: "Source", sizeBytes: 1 << 30,
                                  isInternal: false, isBootVolume: false, mediaIdentity: 42)
        #expect(safety(mount: "/dev/disk7s1", identities: ["disk6": 42]).check(destination: destination, source: scanned) == .safe)
        // disk6 now names a different device (the source was re-attached elsewhere), or nothing.
        #expect(safety(mount: "/dev/disk7s1", identities: ["disk6": 99]).check(destination: destination, source: scanned) == .undetermined)
        #expect(safety(mount: "/dev/disk7s1").check(destination: destination, source: scanned) == .undetermined)
    }

    @Test func assessmentRecordsTheCheckedVolume() {
        let assessment = safety(mount: "/dev/disk7s1").assess(destination: destination, source: source)
        #expect(assessment == DestinationAssessment(verdict: .safe, mountSource: "/dev/disk7s1"))
        #expect(assessment.covers(openedMountSource: "/dev/disk7s1"))
        #expect(!assessment.covers(openedMountSource: "/dev/disk7s2"))
        #expect(!assessment.covers(openedMountSource: nil))
        let blocked = safety(mount: "/dev/disk6s1").assess(destination: destination, source: source)
        #expect(!blocked.covers(openedMountSource: "/dev/disk6s1"))
    }

    @Test func symlinkedDestinationIsCheckedAtItsTarget() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("SalvageSafety-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let real = base.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = base.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let seen = PathRecorder()
        let check = DestinationSafety(mountSource: { path in seen.record(path); return path.hasSuffix("/real") ? "/dev/disk6s1" : "/dev/disk7s1" },
                                      physicalDisks: { [$0] }, backing: { _ in .physical }, mediaIdentity: { _ in nil })
        // The link itself is on another disk; its target is on the source. The target decides.
        #expect(check.check(destination: link, source: source) == .sameDevice)
        #expect(seen.paths == [real.resolvingSymlinksInPath().path])
    }

    @Test func liveDescriptorLookupMatchesPathLookup() {
        let path = FileManager.default.temporaryDirectory.path
        let fd = open(path, O_RDONLY | O_DIRECTORY)
        defer { close(fd) }
        #expect(mountSourceName(ofDescriptor: fd) == mountSourceName(ofPath: path))
        #expect(mountSourceName(ofDescriptor: -1) == nil)
    }
}

private final class PathRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func record(_ path: String) { lock.withLock { stored.append(path) } }
    var paths: [String] { lock.withLock { stored } }
}
