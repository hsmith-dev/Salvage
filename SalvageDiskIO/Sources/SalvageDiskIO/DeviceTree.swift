import DiskArbitration
import IOKit
import Foundation
import SalvageCore

// The Device Picker's Disk Utility-style tree: each physical drive (or attached disk image) is a
// top-level `BlockDevice`, with its partitions, any APFS container on them, and that container's
// volumes nested beneath it as `DevicePartition`s.
//
// Pure: `buildDeviceTree` turns already-read disk descriptions into the tree, so every shape
// (USB stick, APFS physical store with its synthesized container, disk image, boot drive,
// malformed description) has unit coverage with injected dictionaries, no live disk required.
// `DiskWatchRegistration.readDiskDescriptions` does the live DiskArbitration/IORegistry reads.

/// One disk node (whole disk, partition, APFS volume) as read from the system: its DiskArbitration
/// description, plus what only the IORegistry knows. Built by the live reader, consumed by
/// `buildDeviceTree`.
struct RawDiskDescription {
    let bsdName: String
    /// `DADiskCopyDescription`'s dictionary, `nil` when it couldn't be read.
    let description: [String: Any]?
    /// The IORegistry entry ID of a whole disk's IOMedia (attachment identity). A whole disk
    /// without one is not published, as before the tree existed.
    var mediaIdentity: UInt64?
    /// BSD names of the IOMedia ancestors of a whole disk, from the same IOService-plane walk the
    /// startup-disk protection uses (`registryAncestorMediaBSDNames`). Non-empty for a disk macOS
    /// synthesizes on top of another disk's partition (an APFS container: `["disk0s2", "disk0"]`);
    /// empty for a physical drive or a disk image; `nil` when the walk failed.
    var ancestorMedia: [String]?
    /// Where a partition starts on its whole disk, in bytes: the IOMedia `Base` property (the
    /// DiskArbitration description carries no offset). `nil` when it couldn't be read.
    var baseOffset: Int64?
}

/// The IOMedia `Base` property of `media` (a partition's byte offset on its whole disk), or nil
/// when it is missing or not a non-negative number. A metadata read only.
func ioMediaBaseOffset(_ media: io_registry_entry_t) -> Int64? {
    guard media != 0,
          let value = IORegistryEntryCreateCFProperty(media, "Base" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
          let number = value as? NSNumber else { return nil }
    let offset = number.int64Value
    return offset >= 0 ? offset : nil
}

/// DiskArbitration description keys. The literal values are what DiskArbitration uses, so tests
/// can build descriptions without importing the framework.
enum DiskKey {
    static let whole = kDADiskDescriptionMediaWholeKey as String            // "DAMediaWhole"
    static let size = kDADiskDescriptionMediaSizeKey as String              // "DAMediaSize"
    static let mediaName = kDADiskDescriptionMediaNameKey as String         // "DAMediaName"
    static let mediaContent = kDADiskDescriptionMediaContentKey as String   // "DAMediaContent"
    static let volumeName = kDADiskDescriptionVolumeNameKey as String       // "DAVolumeName"
    static let volumeKind = kDADiskDescriptionVolumeKindKey as String       // "DAVolumeKind"
    static let deviceModel = kDADiskDescriptionDeviceModelKey as String     // "DADeviceModel"
    static let deviceInternal = kDADiskDescriptionDeviceInternalKey as String // "DADeviceInternal"
}

/// Partition-type identifiers (GPT GUIDs and the names DiskArbitration reports for MBR and Apple
/// partition types) the tree recognizes.
enum PartitionContent {
    static let apfsContainerScheme = "EF57347C-0000-11AA-AA11-00306543ECAC" // a synthesized container disk
    static let apfsVolume = "41504653-0000-11AA-AA11-00306543ECAC"
    static let apfs: Set<String> = ["7C3457EF-0000-11AA-AA11-00306543ECAC", "Apple_APFS"]
    static let apfsISC: Set<String> = ["69646961-6700-11AA-AA11-00306543ECAC", "Apple_APFS_ISC"]
    static let apfsRecovery: Set<String> = ["52637672-7900-11AA-AA11-00306543ECAC", "Apple_APFS_Recovery"]
    static let efi: Set<String> = ["C12A7328-F81F-11D2-BA4B-00A0C93EC93B", "EFI"]
    static let hfs: Set<String> = ["48465300-0000-11AA-AA11-00306543ECAC", "Apple_HFS", "Apple_HFSX",
                                   "48465858-0000-11AA-AA11-00306543ECAC"]
    static let ntfs: Set<String> = ["Windows_NTFS"]
    static let fat: Set<String> = ["DOS_FAT_32", "Windows_FAT_32", "DOS_FAT_32_LBA", "DOS_FAT_16", "DOS_FAT_12",
                                   "Windows_FAT_16", "DOS_FAT_16_S"]
    static let linux: Set<String> = ["0FC63DAF-8483-4772-8E79-3D69D8477DE4", "Linux", "Linux_Ext"]
}

/// The format in plain words. A mounted volume's filesystem kind wins over the partition type,
/// which can be ambiguous (MBR type 0x07 is either NTFS or exFAT).
func plainFormatName(volumeKind: String?, mediaContent: String?) -> String {
    switch volumeKind?.lowercased() {
    case "apfs": return "APFS"
    case "exfat": return "exFAT"
    case "msdos": return "FAT32"
    case "ntfs": return "NTFS"
    case "hfs": return "HFS+"
    case let kind? where kind.hasPrefix("ext") || kind.contains("ext2") || kind.contains("ext4"): return "Linux (EXT)"
    default: break
    }
    guard let content = mediaContent else { return "Unknown" }
    if PartitionContent.apfs.contains(content) || PartitionContent.apfsISC.contains(content)
        || PartitionContent.apfsRecovery.contains(content) || content == PartitionContent.apfsVolume
        || content == PartitionContent.apfsContainerScheme { return "APFS" }
    if PartitionContent.efi.contains(content) { return "EFI" }
    if PartitionContent.hfs.contains(content) { return "HFS+" }
    if PartitionContent.ntfs.contains(content) { return "NTFS" }
    if PartitionContent.fat.contains(content) { return "FAT32" }
    if PartitionContent.linux.contains(content) { return "Linux (EXT)" }
    return "Unknown"
}

/// A node's description, decoded. `nil` when a key the tree relies on is missing or mistyped.
private struct DecodedSlice {
    let bsdName: String
    let sizeBytes: Int64
    let mediaName: String?
    let mediaContent: String?
    let volumeName: String?
    let volumeKind: String?
    let baseOffset: Int64?
    var format: String { plainFormatName(volumeKind: volumeKind, mediaContent: mediaContent) }

    init?(_ raw: RawDiskDescription) {
        guard let description = raw.description,
              let isWhole = description[DiskKey.whole] as? Bool, !isWhole,
              let size = (description[DiskKey.size] as? NSNumber)?.int64Value, size >= 0 else { return nil }
        bsdName = raw.bsdName
        sizeBytes = size
        mediaName = Self.text(description[DiskKey.mediaName])
        mediaContent = Self.text(description[DiskKey.mediaContent])
        volumeName = Self.text(description[DiskKey.volumeName])
        volumeKind = Self.text(description[DiskKey.volumeKind])
        baseOffset = raw.baseOffset.flatMap { $0 >= 0 ? $0 : nil }
    }

    private static func text(_ value: Any?) -> String? {
        guard let string = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !string.isEmpty
        else { return nil }
        return string
    }
}

/// The number of slice components in a BSD name: 0 for "disk3", 1 for "disk3s5", 2 for an APFS
/// snapshot "disk3s1s1". `nil` for anything that isn't a disk node name.
func sliceDepth(_ name: String) -> Int? {
    guard isDiskNodeBSDName(name) else { return nil }
    return name.dropFirst("disk".count).filter { $0 == "s" }.count
}

/// The trailing slice number ("disk3s12" -> 12), for ordering partitions as the partition map does.
private func sliceNumber(_ name: String) -> Int {
    guard let index = name.lastIndex(of: "s") else { return 0 }
    return Int(name[name.index(after: index)...]) ?? 0
}

/// Builds the Device Picker's device set from disk descriptions.
///
/// - A whole disk macOS synthesizes on another disk's partition (an APFS container: its
///   IORegistry ancestors include that partition, or its content is the APFS container scheme)
///   is not a top-level device. Its physical store is the scan target, which covers the
///   container; the container is nested under that store's partition, its volumes beneath it.
/// - Every other whole disk is a top-level device, as before: physical drives, and disk images,
///   which are their own device with their own partitions nested. The boot drive stays listed,
///   flagged `isBootVolume`, with its tree.
/// - Fail soft: a drive any of whose partitions (or nested volumes) has a missing or malformed
///   description is shown with no children, never with a partial or guessed tree.
func buildDeviceTree(_ disks: [RawDiskDescription], bootDisks: Set<String>) -> [BlockDevice] {
    var byWhole: [String: [RawDiskDescription]] = [:]
    var wholes: [RawDiskDescription] = []
    for disk in disks {
        guard let depth = sliceDepth(disk.bsdName) else { continue }
        if depth == 0 {
            guard isWholeDiskBSDName(disk.bsdName), !wholes.contains(where: { $0.bsdName == disk.bsdName }) else { continue }
            wholes.append(disk)
        } else if depth == 1, let whole = wholeDiskBSDName(fromDevicePath: disk.bsdName) {
            // Depth 2+ are APFS snapshots, which Disk Utility doesn't list either.
            byWhole[whole, default: []].append(disk)
        }
    }

    func isSynthesized(_ disk: RawDiskDescription) -> Bool {
        if let ancestors = disk.ancestorMedia, !ancestors.isEmpty { return true }
        return disk.description?[DiskKey.mediaContent] as? String == PartitionContent.apfsContainerScheme
    }

    let topLevel = wholes.filter { ($0.description?[DiskKey.whole] as? Bool) == true && !isSynthesized($0) }
    let topLevelNames = Set(topLevel.map(\.bsdName))

    // Synthesized disk -> the partition it lives on: its nearest IOMedia ancestor that is a
    // partition of a top-level drive. One store per container (a multi-store Fusion container is
    // nested under its first store only, so the tree never shows one node twice).
    var synthesizedOnStore: [String: RawDiskDescription] = [:]
    for disk in wholes where isSynthesized(disk) {
        guard let store = disk.ancestorMedia?.first(where: { name in
            sliceDepth(name) == 1 && wholeDiskBSDName(fromDevicePath: name).map(topLevelNames.contains) == true
        }), synthesizedOnStore[store] == nil else { continue }
        synthesizedOnStore[store] = disk
    }

    func slices(of whole: String) -> [RawDiskDescription] {
        (byWhole[whole] ?? []).sorted { sliceNumber($0.bsdName) < sliceNumber($1.bsdName) }
    }

    /// The volumes inside a synthesized disk. `nil` if any is unreadable.
    func volumes(of synthesized: RawDiskDescription) -> [DevicePartition]? {
        var result: [DevicePartition] = []
        for raw in slices(of: synthesized.bsdName) {
            guard let volume = DecodedSlice(raw) else { return nil }
            let name = volume.volumeName ?? volume.mediaName ?? "\(volume.format) volume"
            // An APFS volume's media size is its container's; its space is shared, so no size.
            // Nor an offset: its `Base` is relative to the synthesized container disk, and its
            // files are found at the store partition's offset.
            let isAPFS = volume.format == "APFS"
            result.append(DevicePartition(bsdName: volume.bsdName, displayName: name,
                                          sizeBytes: isAPFS ? nil : volume.sizeBytes, formatName: volume.format))
        }
        return result
    }

    func partitions(of drive: RawDiskDescription) -> [DevicePartition] {
        var result: [DevicePartition] = []
        for raw in slices(of: drive.bsdName) {
            guard let slice = DecodedSlice(raw) else { return [] }
            let synthesized = synthesizedOnStore[slice.bsdName]
            var children: [DevicePartition] = []
            if let synthesized {
                guard let found = volumes(of: synthesized) else { return [] }
                children = found
            }
            let holdsAPFS = slice.mediaContent.map(isAPFSStore) == true
                || synthesized?.description?[DiskKey.mediaContent] as? String == PartitionContent.apfsContainerScheme
            if holdsAPFS {
                // The store partition is the container's node, as in Disk Utility: drive, then
                // "APFS container", then its volumes.
                result.append(DevicePartition(bsdName: slice.bsdName, displayName: containerLabel(slice.mediaContent),
                                              sizeBytes: slice.sizeBytes, formatName: "APFS", children: children,
                                              offsetBytes: slice.baseOffset))
            } else {
                let format = slice.format
                let name = slice.volumeName ?? (format == "Unknown" ? "Unnamed partition" : format)
                result.append(DevicePartition(bsdName: slice.bsdName, displayName: name,
                                              sizeBytes: slice.sizeBytes, formatName: format, children: children,
                                              offsetBytes: slice.baseOffset))
            }
        }
        return result
    }

    var devices: [BlockDevice] = []
    for drive in topLevel {
        guard let description = drive.description, let mediaIdentity = drive.mediaIdentity else { continue }
        let model = ((description[DiskKey.deviceModel] as? String) ?? "").trimmingCharacters(in: .whitespaces)
        devices.append(BlockDevice(
            bsdName: drive.bsdName,
            displayName: model.isEmpty ? drive.bsdName : model,
            sizeBytes: (description[DiskKey.size] as? NSNumber)?.int64Value ?? 0,
            isInternal: (description[DiskKey.deviceInternal] as? Bool) ?? false,
            isBootVolume: isWithinBootDiskSet(drive.bsdName, bootDisks: bootDisks),
            mediaIdentity: mediaIdentity,
            partitions: partitions(of: drive)
        ))
    }
    return devices
}

private func isAPFSStore(_ content: String) -> Bool {
    PartitionContent.apfs.contains(content) || PartitionContent.apfsISC.contains(content)
        || PartitionContent.apfsRecovery.contains(content)
}

/// Plain-words names the tree gives APFS physical-store partitions, by partition type.
public enum DeviceTreeLabel {
    public static let apfsContainer = "APFS container"
    /// Apple silicon's iBoot system container (firmware support volumes).
    public static let systemContainer = "System container"
    public static let recoveryContainer = "Recovery container"
    /// macOS's own support containers, which the picker starts collapsed (Disk Utility hides them
    /// by default); they are listed, just not expanded.
    public static let supportContainers: Set<String> = [systemContainer, recoveryContainer]
}

private func containerLabel(_ content: String?) -> String {
    guard let content else { return DeviceTreeLabel.apfsContainer }
    if PartitionContent.apfsISC.contains(content) { return DeviceTreeLabel.systemContainer }
    if PartitionContent.apfsRecovery.contains(content) { return DeviceTreeLabel.recoveryContainer }
    return DeviceTreeLabel.apfsContainer
}

#if DEBUG
/// Debug-only: the tree as indented text with BSD names and sizes, for checking the live
/// enumeration against `diskutil list` (read-only metadata; no raw reads, no unmounts).
func debugDescription(ofDeviceTree devices: [BlockDevice]) -> String {
    var lines: [String] = []
    func walk(_ partitions: [DevicePartition], depth: Int) {
        for partition in partitions {
            let size = partition.sizeBytes.map { " \($0)" } ?? ""
            let offset = partition.offsetBytes.map { " @\($0)" } ?? ""
            lines.append(String(repeating: "   ", count: depth) + "└ \(partition.bsdName)\(size)\(offset) \(partition.formatName) \"\(partition.displayName)\"")
            walk(partition.children, depth: depth + 1)
        }
    }
    for device in devices {
        lines.append("\(device.bsdName) \(device.sizeBytes) \"\(device.displayName)\"\(device.isBootVolume ? " [startup disk, can't scan]" : "")")
        walk(device.partitions, depth: 1)
    }
    return lines.joined(separator: "\n")
}
#endif
