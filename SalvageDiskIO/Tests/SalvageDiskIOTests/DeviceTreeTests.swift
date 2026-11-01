import Foundation
import IOKit
import SalvageCore
import Testing
@testable import SalvageDiskIO

// The Device Picker's Disk Utility-style tree, from injected disk descriptions shaped like
// DiskArbitration's real ones (keys and values checked against this machine's live descriptions).

private func whole(_ name: String, model: String, size: Int64, content: String = "GUID_partition_scheme",
                   isInternal: Bool = false, identity: UInt64 = 1, ancestors: [String]? = []) -> RawDiskDescription {
    RawDiskDescription(bsdName: name,
                       description: ["DAMediaWhole": true, "DAMediaSize": NSNumber(value: size), "DADeviceModel": model,
                                     "DAMediaContent": content, "DADeviceInternal": isInternal,
                                     "DAMediaName": "\(model) Media"],
                       mediaIdentity: identity, ancestorMedia: ancestors)
}

private func slice(_ name: String, size: Int64, content: String, mediaName: String? = nil,
                   volumeName: String? = nil, kind: String? = nil) -> RawDiskDescription {
    var description: [String: Any] = ["DAMediaWhole": false, "DAMediaSize": NSNumber(value: size), "DAMediaContent": content]
    if let mediaName { description["DAMediaName"] = mediaName }
    if let volumeName { description["DAVolumeName"] = volumeName }
    if let kind { description["DAVolumeKind"] = kind }
    return RawDiskDescription(bsdName: name, description: description)
}

private let simulatorPath = "/System/Library/AssetsV2/com_apple_MobileAsset_iOSSimulatorRuntime/26c9.asset/AssetData/Restore/094-56039-099.dmg"

/// A disk image's whole disk, as DiskArbitration describes one: model "Disk Image" on a
/// "Virtual Interface", no internal/external key; plus the driver's owner uid and file path.
private func imageWhole(_ name: String, size: Int64, identity: UInt64, owner: UInt32?, path: String?) -> RawDiskDescription {
    RawDiskDescription(bsdName: name,
                       description: ["DAMediaWhole": true, "DAMediaSize": NSNumber(value: size), "DADeviceModel": "Disk Image",
                                     "DADeviceProtocol": "Virtual Interface", "DAMediaContent": "GUID_partition_scheme",
                                     "DAMediaName": "Apple disk image Media"],
                       mediaIdentity: identity, ancestorMedia: [], imageOwnerUID: owner, imagePath: path)
}

/// An Xcode simulator runtime image: GPT, one APFS store, its synthesized container and volume.
private func simulatorImage(owner: UInt32) -> [RawDiskDescription] { [
    imageWhole("disk11", size: 18_083_776_000, identity: 11, owner: owner, path: simulatorPath),
    slice("disk11s1", size: 18_083_741_696, content: "7C3457EF-0000-11AA-AA11-00306543ECAC"),
    RawDiskDescription(bsdName: "disk12",
                       description: ["DAMediaWhole": true, "DAMediaSize": NSNumber(value: 18_083_741_696),
                                     "DADeviceModel": "Disk Image", "DADeviceProtocol": "Virtual Interface",
                                     "DAMediaContent": "EF57347C-0000-11AA-AA11-00306543ECAC"],
                       mediaIdentity: 12, ancestorMedia: ["disk11s1", "disk11"]),
    slice("disk12s1", size: 18_083_741_696, content: "41504653-0000-11AA-AA11-00306543ECAC",
          mediaName: "iOS 26.5 Simulator", volumeName: "iOS 26.5 Simulator", kind: "apfs"),
] }

private let efiGUID = "C12A7328-F81F-11D2-BA4B-00A0C93EC93B"
private let basicDataGUID = "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7"
private let apfsGUID = "7C3457EF-0000-11AA-AA11-00306543ECAC"
private let apfsVolumeGUID = "41504653-0000-11AA-AA11-00306543ECAC"

/// A USB stick: GPT with an EFI partition and an exFAT data partition.
private var usbStick: [RawDiskDescription] { [
    whole("disk6", model: "SanDisk Ultra USB", size: 64_000_000_000, identity: 6),
    slice("disk6s1", size: 209_715_200, content: efiGUID, mediaName: "EFI System Partition"),
    slice("disk6s2", size: 63_790_000_000, content: basicDataGUID, mediaName: "Untitled 1", volumeName: "Photos", kind: "exfat"),
] }

/// The startup drive: an APFS physical store "disk0s2" with its synthesized container "disk3"
/// (Macintosh HD and Data volumes, plus a snapshot that isn't shown).
private var bootDrive: [RawDiskDescription] { [
    whole("disk0", model: "APPLE SSD AP2048Z", size: 2_001_111_162_880, isInternal: true, identity: 100),
    slice("disk0s2", size: 1_995_165_736_960, content: apfsGUID, mediaName: "Container"),
    whole("disk3", model: "APPLE SSD AP2048Z", size: 1_995_165_736_960,
          content: "EF57347C-0000-11AA-AA11-00306543ECAC", isInternal: true, identity: 103, ancestors: ["disk0s2", "disk0"]),
    slice("disk3s1", size: 1_995_165_736_960, content: apfsVolumeGUID, mediaName: "Macintosh HD",
          volumeName: "Macintosh HD", kind: "apfs"),
    slice("disk3s5", size: 1_995_165_736_960, content: apfsVolumeGUID, mediaName: "Data", volumeName: "Data", kind: "apfs"),
    slice("disk3s1s1", size: 1_995_165_736_960, content: apfsVolumeGUID, mediaName: "com.apple.os.update-1"),
] }

@Suite("Device tree")
struct DeviceTreeTests {
    @Test("A USB stick lists its EFI and exFAT partitions beneath the drive")
    func usbStickWithEFIAndExFAT() throws {
        let devices = buildDeviceTree(usbStick, bootDisks: ["disk0"])
        let stick = try #require(devices.only)
        #expect(stick.bsdName == "disk6")
        #expect(stick.displayName == "SanDisk Ultra USB")
        #expect(stick.mediaIdentity == 6)
        #expect(!stick.isBootVolume)
        #expect(stick.partitions == [
            DevicePartition(bsdName: "disk6s1", displayName: "EFI", sizeBytes: 209_715_200, formatName: "EFI"),
            DevicePartition(bsdName: "disk6s2", displayName: "Photos", sizeBytes: 63_790_000_000, formatName: "exFAT"),
        ])
    }

    @Test("A synthesized APFS container nests under its physical store and is not a device of its own")
    func apfsContainerNestsUnderStore() throws {
        let devices = buildDeviceTree(bootDrive, bootDisks: ["disk0", "disk3"])
        #expect(devices.map(\.bsdName) == ["disk0"])
        let drive = try #require(devices.only)
        #expect(drive.isBootVolume)
        let container = try #require(drive.partitions.only)
        #expect(container.bsdName == "disk0s2")
        #expect(container.displayName == "APFS container")
        #expect(container.formatName == "APFS")
        #expect(container.sizeBytes == 1_995_165_736_960)
        // The snapshot (disk3s1s1) is left out; APFS volumes share their container's space.
        #expect(container.children == [
            DevicePartition(bsdName: "disk3s1", displayName: "Macintosh HD", sizeBytes: nil, formatName: "APFS"),
            DevicePartition(bsdName: "disk3s5", displayName: "Data", sizeBytes: nil, formatName: "APFS"),
        ])
    }

    @Test("A container is hidden by its content even when the registry walk failed, and its store shows no volumes")
    func containerWithUnknownStore() throws {
        var disks = bootDrive
        disks[2].ancestorMedia = nil
        let devices = buildDeviceTree(disks, bootDisks: ["disk0", "disk3"])
        #expect(devices.map(\.bsdName) == ["disk0"])
        #expect(devices.first?.partitions.only?.children == [])
        #expect(devices.first?.partitions.only?.displayName == "APFS container")
    }

    @Test("A disk image stays a top-level device, with its partition and APFS volume nested")
    func diskImage() throws {
        let image = [
            imageWhole("disk4", size: 18_559_829_504, identity: 4, owner: 501, path: nil),
            slice("disk4s1", size: 18_559_795_200, content: apfsGUID, mediaName: "Untitled 1"),
            whole("disk5", model: "Disk Image", size: 18_559_795_200, content: "EF57347C-0000-11AA-AA11-00306543ECAC",
                  identity: 5, ancestors: ["disk4s1", "disk4"]),
            slice("disk5s1", size: 18_559_795_200, content: apfsVolumeGUID, mediaName: "iOS 27.0 Simulator", kind: "apfs"),
        ]
        let devices = buildDeviceTree(bootDrive + image, bootDisks: ["disk0", "disk3"])
        #expect(devices.map(\.bsdName) == ["disk0", "disk4"])
        let disk = try #require(devices.last)
        #expect(!disk.isBootVolume)
        #expect(disk.displayName == "Disk Image")
        #expect(disk.isDiskImage && !disk.isSystemImage && !disk.isInternal)
        #expect(disk.partitions == [
            DevicePartition(bsdName: "disk4s1", displayName: "APFS container", sizeBytes: 18_559_795_200, formatName: "APFS",
                            children: [DevicePartition(bsdName: "disk5s1", displayName: "iOS 27.0 Simulator",
                                                       sizeBytes: nil, formatName: "APFS")]),
        ])
    }

    @Test("The boot drive stays listed, flagged, with its read-only tree; other drives are not flagged")
    func bootDriveListedWithTree() {
        let devices = buildDeviceTree(bootDrive + usbStick, bootDisks: ["disk0", "disk3"])
        #expect(devices.map(\.bsdName) == ["disk0", "disk6"])
        #expect(devices.map(\.isBootVolume) == [true, false])
        #expect(devices[0].partitions.first?.children.count == 2)
    }

    @Test("A malformed partition description shows the drive with no children")
    func malformedSliceShowsDriveWithoutChildren() throws {
        var disks = usbStick
        disks[1] = RawDiskDescription(bsdName: "disk6s1", description: ["DAMediaWhole": false, "DAMediaSize": "lots"])
        let drive = try #require(buildDeviceTree(disks, bootDisks: ["disk0"]).only)
        #expect(drive.bsdName == "disk6")
        #expect(drive.partitions.isEmpty)
    }

    @Test("A missing partition description shows the drive with no children")
    func missingSliceShowsDriveWithoutChildren() throws {
        var disks = usbStick
        disks[2] = RawDiskDescription(bsdName: "disk6s2", description: nil)
        let drive = try #require(buildDeviceTree(disks, bootDisks: ["disk0"]).only)
        #expect(drive.partitions.isEmpty)
    }

    @Test("A malformed volume inside a container empties that drive's tree, never a partial one")
    func malformedVolumeShowsDriveWithoutChildren() throws {
        var disks = bootDrive
        disks[4] = RawDiskDescription(bsdName: "disk3s5", description: nil)
        let drive = try #require(buildDeviceTree(disks, bootDisks: ["disk0", "disk3"]).only)
        #expect(drive.partitions.isEmpty)
    }

    @Test("A whole disk without a description or attachment identity is not published, as before")
    func unreadableWholeDiskSkipped() {
        let disks = [RawDiskDescription(bsdName: "disk6", description: nil, mediaIdentity: 6),
                     RawDiskDescription(bsdName: "disk7", description: whole("disk7", model: "X", size: 1).description,
                                        mediaIdentity: nil, ancestorMedia: [])]
        #expect(buildDeviceTree(disks, bootDisks: ["disk0"]).isEmpty)
    }

    @Test("A drive with no partition map has no children")
    func noPartitions() throws {
        let drive = try #require(buildDeviceTree([whole("disk8", model: "Card", size: 8)], bootDisks: ["disk0"]).only)
        #expect(drive.partitions.isEmpty)
        #expect(drive.displayName == "Card")
    }

    @Test("Partitions are ordered by slice number, not by name")
    func sliceOrdering() {
        let disks = [whole("disk6", model: "M", size: 1),
                     slice("disk6s10", size: 1, content: "Apple_HFS"),
                     slice("disk6s2", size: 1, content: "Windows_NTFS")]
        #expect(buildDeviceTree(disks, bootDisks: []).first?.partitions.map(\.bsdName) == ["disk6s2", "disk6s10"])
    }

    @Test("macOS's system and recovery containers are named in plain words")
    func supportContainerLabels() {
        let disks = [whole("disk0", model: "SSD", size: 10),
                     slice("disk0s1", size: 1, content: "69646961-6700-11AA-AA11-00306543ECAC", mediaName: "iBootSystemContainer"),
                     slice("disk0s3", size: 1, content: "52637672-7900-11AA-AA11-00306543ECAC", mediaName: "RecoveryOSContainer")]
        let partitions = buildDeviceTree(disks, bootDisks: ["disk0"]).first?.partitions ?? []
        #expect(partitions.map(\.displayName) == ["System container", "Recovery container"])
        #expect(partitions.map(\.formatName) == ["APFS", "APFS"])
    }

    @Test("Formats in plain words")
    func formatNames() {
        #expect(plainFormatName(volumeKind: "exfat", mediaContent: "Windows_NTFS") == "exFAT")
        #expect(plainFormatName(volumeKind: nil, mediaContent: "Windows_NTFS") == "NTFS")
        #expect(plainFormatName(volumeKind: "msdos", mediaContent: basicDataGUID) == "FAT32")
        #expect(plainFormatName(volumeKind: nil, mediaContent: "DOS_FAT_32") == "FAT32")
        #expect(plainFormatName(volumeKind: "hfs", mediaContent: nil) == "HFS+")
        #expect(plainFormatName(volumeKind: nil, mediaContent: "48465300-0000-11AA-AA11-00306543ECAC") == "HFS+")
        #expect(plainFormatName(volumeKind: nil, mediaContent: "0FC63DAF-8483-4772-8E79-3D69D8477DE4") == "Linux (EXT)")
        #expect(plainFormatName(volumeKind: nil, mediaContent: efiGUID) == "EFI")
        #expect(plainFormatName(volumeKind: nil, mediaContent: apfsGUID) == "APFS")
        #expect(plainFormatName(volumeKind: nil, mediaContent: basicDataGUID) == "Unknown")
        #expect(plainFormatName(volumeKind: nil, mediaContent: nil) == "Unknown")
    }

    @Test("An unnamed partition of a known format is \"Untitled\", as in Disk Utility")
    func unnamedKnownPartition() {
        let disks = [whole("disk17", model: "MK3252GSX", size: 320_072_933_376, content: "FDisk_partition_scheme"),
                     slice("disk17s1", size: 306_018_516_992, content: "Windows_NTFS"),
                     slice("disk17s2", size: 14_049_869_824, content: "Windows_NTFS", volumeName: "RECOVERY", kind: "ntfs")]
        let drive = buildDeviceTree(disks, bootDisks: []).first
        #expect(drive?.partitions.map(\.displayName) == ["Untitled", "RECOVERY"])
        #expect(drive?.partitions.map(\.formatName) == ["NTFS", "NTFS"])
        #expect(drive?.isDiskImage == false)
    }

    // MARK: Disk images: which are macOS's own ("Hidden")

    @Test("A disk image a system daemon attached (owner uid 0) is a system image, named after its file")
    func systemOwnedImage() throws {
        let image = simulatorImage(owner: 0)
        let disk = try #require(buildDeviceTree(image, bootDisks: []).only)
        #expect(disk.isDiskImage && disk.isSystemImage)
        #expect(disk.displayName == "094-56039-099.dmg")
        #expect(disk.diskImagePath == simulatorPath)
    }

    @Test("A user's image mounted nobrowse is a system image too; mounted normally it is not")
    func noBrowseImage() throws {
        let image = simulatorImage(owner: 501)
        #expect(buildDeviceTree(image, bootDisks: []).only?.isSystemImage == false)
        #expect(buildDeviceTree(image, bootDisks: [], noBrowseVolumes: ["disk12s1"]).only?.isSystemImage == true)
        #expect(buildDeviceTree(image, bootDisks: [], noBrowseVolumes: ["disk3s5"]).only?.isSystemImage == false)
    }

    @Test("A disk image is recognized by its virtual interface even with another model name")
    func imageByProtocol() throws {
        var raw = imageWhole("disk13", size: 21_491_200, identity: 13, owner: 501, path: "/Users/me/Desktop/Salvage-1.0.0.dmg")
        var description = try #require(raw.description)
        description["DADeviceModel"] = "Something"
        raw = RawDiskDescription(bsdName: raw.bsdName, description: description, mediaIdentity: 13, ancestorMedia: [],
                                 imageOwnerUID: 501, imagePath: raw.imagePath)
        let disk = try #require(buildDeviceTree([raw], bootDisks: []).only)
        #expect(disk.isDiskImage && !disk.isSystemImage)
        #expect(disk.displayName == "Salvage-1.0.0.dmg")
    }

    @Test("A physical drive is never a system image, even with a nobrowse volume or unknown owner")
    func physicalDriveNeverSystemImage() throws {
        let devices = buildDeviceTree(bootDrive, bootDisks: ["disk0", "disk3"], noBrowseVolumes: ["disk3s5"])
        let drive = try #require(devices.only)
        #expect(!drive.isDiskImage && !drive.isSystemImage && drive.isInternal)
    }

    @Test("An unnamed partition of unknown type gets plain words, not an empty name")
    func unnamedUnknownPartition() {
        let disks = [whole("disk6", model: "M", size: 1), slice("disk6s1", size: 5, content: basicDataGUID)]
        #expect(buildDeviceTree(disks, bootDisks: []).first?.partitions.first?.displayName == "Unnamed partition")
    }

    @Test("Lock-state annotation still lands on the drive row and keeps its tree")
    func lockAnnotationKeepsTree() throws {
        let device = try #require(buildDeviceTree(usbStick, bootDisks: ["disk0"]).only)
        let container = APFSListedContainer(reference: "disk9", physicalStoreWholeDisks: ["disk6"], volumes: [
            APFSListedVolume(uuid: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE", bsdName: "disk9s1", name: "Vault",
                             isEncrypted: true, isLocked: true),
        ])
        let annotated = try #require(annotateLocked([device], containers: [container]).only)
        #expect(annotated.encryptedVolumeName == "Vault")
        #expect(annotated.partitions == device.partitions)
    }

    // MARK: Partition offsets (recover a whole partition)

    @Test("A partition carries its IOMedia Base as its start offset")
    func partitionOffsetsFromBase() throws {
        var disks = usbStick
        disks[1].baseOffset = 20_480
        disks[2].baseOffset = 209_735_680
        let stick = try #require(buildDeviceTree(disks, bootDisks: ["disk0"]).only)
        #expect(stick.partitions.map(\.offsetBytes) == [20_480, 209_735_680])
        #expect(stick.partitions[1] == DevicePartition(bsdName: "disk6s2", displayName: "Photos", sizeBytes: 63_790_000_000,
                                                        formatName: "exFAT", offsetBytes: 209_735_680))
    }

    @Test("An APFS store has the container's offset; its volumes have none")
    func apfsContainerOffset() throws {
        var disks = bootDrive
        disks[1].baseOffset = 524_288_000
        disks[3].baseOffset = 4096  // relative to the synthesized container disk: never used
        let container = try #require(buildDeviceTree(disks, bootDisks: ["disk0", "disk3"]).only?.partitions.only)
        #expect(container.offsetBytes == 524_288_000)
        #expect(container.children.map(\.offsetBytes) == [nil, nil])
    }

    @Test("An unknown or negative Base leaves the offset unknown")
    func unknownOffset() throws {
        var disks = usbStick
        disks[1].baseOffset = -1
        let stick = try #require(buildDeviceTree(disks, bootDisks: ["disk0"]).only)
        #expect(stick.partitions.map(\.offsetBytes) == [nil, nil])
    }
}

/// The live `Base` read on a GPT exFAT disk image this test creates in its own temp directory and
/// attaches without mounting. Metadata only: no raw reads, no writes to any device.
@Suite("Partition offset from a real disk image",
       .enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/hdiutil")
                && ProcessInfo.processInfo.environment["SALVAGE_SKIP_HDIUTIL"] == nil))
struct LivePartitionOffsetTests {
    @Test func ioMediaBaseOfAnAttachedImagesPartition() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("salvage-base-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = directory.appendingPathComponent("gpt.dmg").path
        guard run(["create", "-quiet", "-size", "64m", "-fs", "ExFAT", "-volname", "BASE", "-layout", "GPTSPUD",
                   "-type", "UDIF", image]).status == 0 else {
            print("Skipping: hdiutil couldn't create an image here."); return
        }
        let attach = run(["attach", "-nobrowse", "-nomount", image])
        let nodes = attach.output.split(separator: "\n").compactMap { line in
            line.split(separator: "\t").first.map { $0.trimmingCharacters(in: .whitespaces) }
        }.filter { $0.hasPrefix("/dev/disk") }
        guard attach.status == 0, let whole = nodes.min(by: { $0.count < $1.count }) else {
            print("Skipping: hdiutil couldn't attach an image here."); return
        }
        defer { _ = run(["detach", "-force", whole]) }
        let partition = try #require(nodes.first { $0 != whole })
        let name = String(partition.dropFirst("/dev/".count))
        let media = IOServiceGetMatchingService(kIOMainPortDefault, IOBSDNameMatching(kIOMainPortDefault, 0, name))
        defer { if media != 0 { IOObjectRelease(media) } }
        // hdiutil's GPTSPUD layout puts the single partition at 1 MiB.
        #expect(ioMediaBaseOffset(media) == 1_048_576)
        #expect(ioMediaBaseOffset(0) == nil)
    }

    private func run(_ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

#if DEBUG
/// Acceptance check against this machine's real disks: read-only metadata (DiskArbitration
/// descriptions, IORegistry properties, `diskutil info -plist` for the boot set). No raw reads, no
/// mounts or unmounts. Opt in with `SALVAGE_LIVE_TREE_DUMP=1`.
@Suite("Live device tree dump", .enabled(if: ProcessInfo.processInfo.environment["SALVAGE_LIVE_TREE_DUMP"] == "1"))
struct LiveDeviceTreeDump {
    @Test func dumpLiveTree() throws {
        guard case .success(let boot) = resolveBootDisks() else { Issue.record("boot disks unresolved"); return }
        let dump = try #require(DiskWatchRegistration.debugLiveTreeDump(bootDisks: boot))
        print("LIVE DEVICE TREE (boot set: \(boot.sorted()))\n\(dump)")
    }
}
#endif

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
