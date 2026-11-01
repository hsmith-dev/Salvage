import Darwin
import Foundation
import SalvageCore
import Testing
@testable import SalvageDiskIO

/// spec-tech-batch-7 §A. Every image lives in a fresh temporary folder that is deleted afterwards;
/// the live attach test detaches its image and checks `hdiutil info` no longer lists it.
@Suite("Disk image sources")
struct DiskImageSourceTests {
    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SalvageImageTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func pattern(_ count: Int) -> Data { Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }) }

    // MARK: Classification

    @Test func udifAndSparseAreAttachedEverythingElseIsRaw() {
        #expect(DiskImageFile.format(head: Data([0xeb, 0x76, 0x90, 0x45]), trailer: Data("koly".utf8)) == .attachable)
        #expect(DiskImageFile.format(head: Data("sprs".utf8), trailer: nil) == .attachable)
        #expect(DiskImageFile.format(head: Data([0, 0, 0, 0]), trailer: Data([0, 0, 0, 0])) == .raw)
        #expect(DiskImageFile.format(head: Data("CD00".utf8), trailer: nil) == .raw)
    }

    @Test func inspectReadsRawImagesAndRefusesDevicesFoldersAndEmptyFiles() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let raw = dir.appendingPathComponent("card.img")
        try pattern(8192).write(to: raw)
        let info = try DiskImageFile.inspect(raw)
        #expect(info.format == .raw)
        #expect(info.sizeBytes == 8192)

        #expect(throws: DiskImageOpenError.isDevice(name: "null")) { try DiskImageFile.inspect(URL(fileURLWithPath: "/dev/null")) }
        let link = dir.appendingPathComponent("drive.img")
        #expect(symlink("/dev/null", link.path) == 0)
        #expect(throws: DiskImageOpenError.isDevice(name: "drive.img")) { try DiskImageFile.inspect(link) }
        #expect(throws: DiskImageOpenError.notAnImage(name: dir.lastPathComponent)) { try DiskImageFile.inspect(dir) }
        let empty = dir.appendingPathComponent("empty.dd")
        FileManager.default.createFile(atPath: empty.path, contents: Data())
        #expect(throws: DiskImageOpenError.empty(name: "empty.dd")) { try DiskImageFile.inspect(empty) }
        #expect(throws: DiskImageOpenError.unreadable(name: "missing.iso")) {
            try DiskImageFile.inspect(dir.appendingPathComponent("missing.iso"))
        }
    }

    @Test func aRawImageIsReadOnlyAndByteExact() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("disk.bin")
        let bytes = pattern(1 << 20)
        try bytes.write(to: url)
        let before = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        let reader = try ImageFileReader(path: url.path)
        #expect(try await reader.read(at: 4096, count: 65536) == bytes[4096..<(4096 + 65536)])
        reader.close()
        #expect(try Data(contentsOf: url) == bytes)
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date == before)
    }

    // MARK: Attach output

    @Test func attachOutputNamesTheImagesOwnDiskFirst() {
        let plist: [String: Any] = ["system-entities": [
            ["dev-entry": "/dev/disk7", "content-hint": "GUID_partition_scheme"],
            ["dev-entry": "/dev/disk7s1", "content-hint": "Apple_APFS"],
            ["dev-entry": "/dev/disk8", "content-hint": "EF57347C-0000-11AA-AA11-00306543ECAC"],
            ["dev-entry": "/dev/disk8s1"],
        ]]
        let attached = DiskImageAttacher.parseAttach(plist, imagePath: "/tmp/x.dmg")
        #expect(attached == AttachedDiskImage(wholeDisk: "disk7", allWholeDisks: ["disk7", "disk8"], imagePath: "/tmp/x.dmg"))
        #expect(DiskImageAttacher.parseAttach(["system-entities": []], imagePath: "/tmp/x.dmg") == nil)
        #expect(DiskImageAttacher.attachArguments(imagePath: "/tmp/x.dmg")
                == ["attach", "-readonly", "-nomount", "-noverify", "-noautofsck", "-plist", "/tmp/x.dmg"])
    }

    /// Detach only touches a disk `hdiutil info` still shows as this same image.
    @Test func detachNeverTouchesADiskThatIsNoLongerThisImage() throws {
        let calls = Calls()
        let other: [String: Any] = ["images": [["image-path": "/tmp/other.dmg", "system-entities": [["dev-entry": "/dev/disk7"]]]]]
        let info = try PropertyListSerialization.data(fromPropertyList: other, format: .xml, options: 0)
        let attacher = DiskImageAttacher { arguments, _ in
            calls.append(arguments)
            return arguments.first == "info" ? (0, info) : (0, Data())
        }
        let image = AttachedDiskImage(wholeDisk: "disk7", allWholeDisks: ["disk7"], imagePath: "/tmp/mine.dmg")
        #expect(attacher.detach(image))
        #expect(calls.all == [["info", "-plist"]], "disk7 now belongs to another image, so it is left alone")
    }

    // MARK: Destination safety

    private func safety(imageMount: String, destinationMount: String, backings: [String: DiskBacking] = [:],
                        mounts: [String: String] = [:], stores: [String: Set<String>] = [:]) -> DiskImageDestinationSafety {
        let mountOf: @Sendable (String) -> String? = { path in
            if path == "/Users/me/backup.dmg" { return imageMount }
            if path.hasPrefix("/Volumes/Dest") { return destinationMount }
            return mounts[path]
        }
        let backing: @Sendable (String) -> DiskBacking? = { backings[$0] ?? .physical }
        let physical: @Sendable (String) -> Set<String>? = { stores[$0] ?? [$0] }
        return DiskImageDestinationSafety(
            mountSource: mountOf, backing: backing,
            devices: DestinationSafety(mountSource: mountOf, physicalDisks: physical, backing: backing, mediaIdentity: { _ in nil }),
            imageFile: ImageFileDestinationSafety(mountSource: mountOf, physicalDisks: physical, backing: backing,
                                                  fileIdentity: { $0 == "/Users/me/backup.dmg" ? FileIdentity(device: 1, inode: 2) : nil }))
    }

    private let image = URL(fileURLWithPath: "/Users/me/backup.dmg")
    private let destination = URL(fileURLWithPath: "/Volumes/Dest/Recovered")

    @Test func aDestinationOnTheDriveHoldingTheImageIsRefused() {
        // Same volume, another partition of the same drive, and an APFS container on that drive.
        #expect(safety(imageMount: "/dev/disk3s5", destinationMount: "/dev/disk3s5").assess(destination: destination, imageFile: image).verdict == .sameDevice)
        #expect(safety(imageMount: "/dev/disk3s5", destinationMount: "/dev/disk3s1").assess(destination: destination, imageFile: image).verdict == .sameDevice)
        #expect(safety(imageMount: "/dev/disk3s5", destinationMount: "/dev/disk9s1", stores: ["disk3": ["disk0"], "disk9": ["disk0"]])
            .assess(destination: destination, imageFile: image).verdict == .sameDevice)
    }

    @Test func aDestinationOnAnotherDriveIsSafe() {
        let result = safety(imageMount: "/dev/disk3s5", destinationMount: "/dev/disk6s2").assess(destination: destination, imageFile: image)
        #expect(result == DestinationAssessment(verdict: .safe, mountSource: "/dev/disk6s2"))
    }

    /// The image sits on an attached image (disk5) whose own file is on disk6: disk6 is refused too.
    @Test func theDriveUnderAnImageOnAnImageIsRefused() {
        let check = safety(imageMount: "/dev/disk5s1", destinationMount: "/dev/disk6s2",
                           backings: ["disk5": .diskImage(path: "/Volumes/Outer/outer.sparseimage")],
                           mounts: ["/Volumes/Outer/outer.sparseimage": "/dev/disk6s1"])
        #expect(check.assess(destination: destination, imageFile: image).verdict == .sameDevice)
    }

    @Test func anUnresolvableHostIsUndetermined() {
        #expect(safety(imageMount: "//server/share", destinationMount: "/dev/disk6s2").assess(destination: destination, imageFile: image).verdict == .undetermined)
        #expect(safety(imageMount: "/dev/disk5s1", destinationMount: "/dev/disk6s2", backings: ["disk5": .unknownVirtual])
            .assess(destination: destination, imageFile: image).verdict == .undetermined)
    }

    /// The real check: an image in a temporary folder and a destination beside it are on the same
    /// drive, so the destination is refused.
    @Test func liveCheckRefusesTheImagesOwnDrive() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("card.img")
        try pattern(4096).write(to: url)
        let destination = dir.appendingPathComponent("Recovered", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        #expect(!DiskImageDestinationSafety.live.assess(destination: destination, imageFile: url).verdict.isSafe)
    }

    // MARK: Live attach (hdiutil, temporary folder only)

    /// A compressed .dmg made from raw bytes is attached read-only and unmounted, read byte for
    /// byte through `RawBlockReader`, and detached; afterwards nothing of it stays attached.
    @Test(.timeLimit(.minutes(3))) func dmgAttachReadDetachLeavesNothingAttached() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let raw = dir.appendingPathComponent("source.img"), dmg = dir.appendingPathComponent("source.dmg")
        let bytes = pattern(2 << 20)
        try bytes.write(to: raw)
        let converted = runBoundedProcess(executable: URL(fileURLWithPath: "/usr/bin/hdiutil"),
                                          arguments: ["convert", raw.path, "-format", "UDZO", "-o", dmg.path, "-quiet"], timeout: 60)
        try #require(converted?.status == 0, "hdiutil convert")
        let info = try DiskImageFile.inspect(dmg)
        #expect(info.format == .attachable)
        let stamp = try FileManager.default.attributesOfItem(atPath: dmg.path)[.modificationDate] as? Date

        let attacher = DiskImageAttacher.live
        let attached = try attacher.attach(dmg)
        var detached = false
        defer { if !detached { attacher.detach(attached) } }
        #expect(attacher.attachedDisks(imagePath: dmg.path)?.contains(attached.wholeDisk) == true)
        // Nothing mounted from it.
        let mounts = mountSourcesSnapshot() ?? []
        #expect(!mounts.contains { wholeDiskBSDName(fromDevicePath: $0).map(attached.allWholeDisks.contains) ?? false })

        let device = try #require(DiskImageAttacher.device(for: attached, displayName: "source.dmg"))
        let reader = try await RawBlockReader.prepare(device: device)
        #expect(try await reader.read(at: 0, count: 65536) == bytes[0..<65536])
        #expect(try await reader.read(at: Int64(bytes.count - 4096), count: 4096) == bytes[(bytes.count - 4096)...])
        await reader.close()

        detached = attacher.detach(attached)
        #expect(detached)
        #expect(attacher.attachedDisks(imagePath: dmg.path) == [])
        #expect(try FileManager.default.attributesOfItem(atPath: dmg.path)[.modificationDate] as? Date == stamp)
    }
}

private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [[String]] = []
    func append(_ call: [String]) { lock.withLock { calls.append(call) } }
    var all: [[String]] { lock.withLock { calls } }
}
