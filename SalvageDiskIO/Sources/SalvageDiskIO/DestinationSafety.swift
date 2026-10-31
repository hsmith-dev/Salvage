import Foundation
import IOKit
import SalvageCore

/// Whether a recovery destination is safe to write to (FR-15, AD-8).
public enum DestinationVerdict: Sendable, Equatable {
    /// The destination lives on a different physical device from the source.
    case safe
    /// The destination lives on the same physical device as the source.
    case sameDevice
    /// The destination's device couldn't be positively determined; treated exactly like
    /// `.sameDevice` by every caller (fail closed).
    case undetermined

    public var isSafe: Bool { self == .safe }
}

/// A verdict plus the volume it was reached for, so a writer can confirm that the directory it
/// actually opened is on that same volume (`fstatfs` of the open descriptor).
public struct DestinationAssessment: Sendable, Equatable {
    public let verdict: DestinationVerdict
    /// The checked volume's `f_mntfromname` (e.g. `/dev/disk7s1`); `nil` when undetermined.
    public let mountSource: String?

    public init(verdict: DestinationVerdict, mountSource: String?) {
        self.verdict = verdict
        self.mountSource = mountSource
    }

    /// True only for a `.safe` verdict whose checked volume is exactly `openedMountSource`.
    public func covers(openedMountSource: String?) -> Bool {
        guard verdict.isSafe, let mountSource, let openedMountSource else { return false }
        return Array(mountSource.utf8) == Array(openedMountSource.utf8)
    }
}

/// What backs a whole disk, as far as destination safety is concerned.
public enum DiskBacking: Sendable, Equatable {
    /// A physical disk, or a synthesized APFS container (its physical stores are expanded by the
    /// physical-disk resolver).
    case physical
    /// An attached disk image; the path is the image file (or bundle) on its host volume.
    case diskImage(path: String)
    /// A virtual disk whose backing store can't be identified (AppleRAID, CoreStorage, an image
    /// missing from `hdiutil info`, ...). Always blocks.
    case unknownVirtual
}

/// Decides whether a destination folder lives on the same physical device as the source.
///
/// The destination's volume is found with `statfs` (`f_mntfromname`), reduced to its whole disk,
/// and expanded to the physical disk(s) backing it (APFS physical stores), reusing the boot-disk
/// helpers. A virtual whole disk is followed to what backs it: a disk image is resolved to the
/// host volume of its image file (`hdiutil info`, then `statfs` of the image path), and that host
/// is evaluated the same way, up to `maxVirtualDepth` levels; any other virtual disk is
/// undetermined. The source device is expanded through its APFS physical stores and, when it
/// carries a media identity from the scan, must still be the device at its BSD name. Any step
/// that can't be answered positively yields `.undetermined`, never `.safe`.
public struct DestinationSafety: Sendable {
    /// Returns the mount source (`f_mntfromname`, e.g. `/dev/disk7s1`) of the volume holding the
    /// given path, or `nil` if it can't be determined.
    public typealias MountSourceResolver = @Sendable (String) -> String?
    /// Returns the physical whole disk(s) backing a whole-disk BSD name, or `nil` on failure.
    public typealias PhysicalDiskResolver = @Sendable (String) -> Set<String>?
    /// Classifies a whole disk as physical or virtual (and, for a disk image, its image file), or
    /// `nil` on failure.
    public typealias DiskBackingResolver = @Sendable (String) -> DiskBacking?
    /// Returns the current media identity (IORegistry entry ID) of a whole-disk BSD name, or `nil`.
    public typealias MediaIdentityResolver = @Sendable (String) -> UInt64?

    /// How many disk-image-on-disk-image hops are followed before giving up (undetermined).
    public static let maxVirtualDepth = 4

    private let mountSource: MountSourceResolver
    private let physicalDisks: PhysicalDiskResolver
    private let backing: DiskBackingResolver
    private let mediaIdentity: MediaIdentityResolver

    public init(mountSource: @escaping MountSourceResolver, physicalDisks: @escaping PhysicalDiskResolver,
                backing: @escaping DiskBackingResolver, mediaIdentity: @escaping MediaIdentityResolver) {
        self.mountSource = mountSource
        self.physicalDisks = physicalDisks
        self.backing = backing
        self.mediaIdentity = mediaIdentity
    }

    /// The real resolvers: `statfs`, `diskutil info -plist`, `hdiutil info -plist` (metadata only,
    /// each bounded by a timeout) and the IORegistry. It may block for a few seconds, so call it
    /// off the main thread.
    public static let live = DestinationSafety(
        mountSource: { path in mountSourceName(ofPath: path) },
        physicalDisks: { bsdName in physicalWholeDisks(backing: bsdName) },
        backing: { bsdName in liveDiskBacking(of: bsdName) },
        mediaIdentity: { bsdName in liveMediaIdentity(ofBSDName: bsdName) }
    )

    public func check(destination: URL, source: BlockDevice) -> DestinationVerdict {
        assess(destination: destination, source: source).verdict
    }

    public func assess(destination: URL, source: BlockDevice) -> DestinationAssessment {
        guard destination.isFileURL else { return DestinationAssessment(verdict: .undetermined, mountSource: nil) }
        let path = destination.resolvingSymlinksInPath().path
        guard !path.isEmpty, let mountFrom = mountSource(path) else {
            return DestinationAssessment(verdict: .undetermined, mountSource: nil)
        }
        return DestinationAssessment(verdict: verdict(mountFrom: mountFrom, source: source), mountSource: mountFrom)
    }

    private func verdict(mountFrom: String, source: BlockDevice) -> DestinationVerdict {
        guard let destinationSet = deviceSet(ofMountSource: mountFrom, depth: 0),
              let sourceSet = sourceDeviceSet(source)
        else { return .undetermined }
        return destinationSet.isDisjoint(with: sourceSet) ? .safe : .sameDevice
    }

    /// The source's whole disk plus its physical stores. When the scan captured a media identity,
    /// the device currently at the source's BSD name must still carry it: a reused or renumbered
    /// BSD name means the source can't be located, so the answer is `nil` (undetermined).
    private func sourceDeviceSet(_ source: BlockDevice) -> Set<String>? {
        guard let sourceWhole = wholeDiskBSDName(fromDevicePath: source.bsdName) else { return nil }
        if let expected = source.mediaIdentity {
            guard let current = mediaIdentity(sourceWhole), current == expected else { return nil }
        }
        guard let physical = physicalDisks(sourceWhole) else { return nil }
        return physical.union([sourceWhole])
    }

    /// Every whole disk the volume mounted from `mountFrom` depends on, following disk images to
    /// their host volumes. `nil` if any part can't be determined.
    private func deviceSet(ofMountSource mountFrom: String, depth: Int) -> Set<String>? {
        // Only a local device node counts; a network share named e.g. "//host/disk3" must never
        // be read as a local disk. Compared on bytes so no Unicode normalization can intervene.
        guard depth <= Self.maxVirtualDepth,
              mountFrom.utf8.starts(with: "/dev/".utf8),
              let whole = wholeDiskBSDName(fromDevicePath: mountFrom),
              let physical = physicalDisks(whole)
        else { return nil }
        var result = physical.union([whole])
        for disk in result.sorted() {
            switch backing(disk) {
            case .physical?:
                continue
            case .diskImage(let imagePath)?:
                guard !imagePath.isEmpty,
                      let hostMount = mountSource(URL(fileURLWithPath: imagePath).resolvingSymlinksInPath().path),
                      let host = deviceSet(ofMountSource: hostMount, depth: depth + 1)
                else { return nil }
                result.formUnion(host)
            case .unknownVirtual?, nil:
                return nil
            }
        }
        return result
    }
}

// MARK: - Live resolvers

/// `statfs(path).f_mntfromname`, decoded with a bounded NUL search; `nil` if `statfs` fails.
public func mountSourceName(ofPath path: String) -> String? {
    var stat = statfs()
    guard statfs(path, &stat) == 0 else { return nil }
    return decodeMountFrom(stat)
}

/// `fstatfs(fd).f_mntfromname`: the volume an already-open file or directory actually lives on.
public func mountSourceName(ofDescriptor fd: Int32) -> String? {
    var stat = statfs()
    guard fstatfs(fd, &stat) == 0 else { return nil }
    return decodeMountFrom(stat)
}

private func decodeMountFrom(_ stat: statfs) -> String? {
    let tuple = stat.f_mntfromname
    let capacity = MemoryLayout.size(ofValue: tuple)
    let name = withUnsafePointer(to: tuple) { ptr in
        ptr.withMemoryRebound(to: CChar.self, capacity: capacity) { chars in
            let buffer = UnsafeBufferPointer(start: chars, count: capacity)
            let length = buffer.firstIndex(of: 0) ?? capacity
            return String(decoding: buffer[0..<length].map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
    }
    return name.isEmpty ? nil : name
}

/// Pure interpretation of `diskutil info -plist <wholeDisk>` and (only for a disk image)
/// `hdiutil info -plist`. A disk is virtual when `BusProtocol` is "Disk Image", or when
/// `VirtualOrPhysical` is "Virtual" and it has no APFS physical stores. A disk image resolves to
/// the `image-path` of the `hdiutil` image one of whose `dev-entry` values is on this whole disk.
func diskBacking(fromDiskUtilInfo info: [String: Any], hdiutilInfo: [String: Any]?, wholeDisk: String) -> DiskBacking? {
    let bus = info["BusProtocol"] as? String
    let kind = info["VirtualOrPhysical"] as? String
    let stores = (info["APFSPhysicalStores"] as? [Any]) ?? []
    let isImage = bus == "Disk Image"
    let isVirtual = isImage || (kind == "Virtual" && stores.isEmpty)
    guard isVirtual else {
        // A disk diskutil can't classify at all is not assumed physical.
        return (kind == nil && bus == nil) ? nil : .physical
    }
    guard let hdiutilInfo, let images = hdiutilInfo["images"] as? [[String: Any]] else {
        return isImage ? nil : .unknownVirtual
    }
    for image in images {
        guard let entities = image["system-entities"] as? [[String: Any]] else { continue }
        let onThisDisk = entities.contains { entity in
            guard let entry = entity["dev-entry"] as? String else { return false }
            return wholeDiskBSDName(fromDevicePath: entry) == wholeDisk
        }
        if onThisDisk {
            guard let path = image["image-path"] as? String, !path.isEmpty else { return nil }
            return .diskImage(path: path)
        }
    }
    return isImage ? nil : .unknownVirtual
}

func liveDiskBacking(of wholeDisk: String) -> DiskBacking? {
    guard let info = diskUtilInfoPlist(for: wholeDisk) else { return nil }
    let bus = info["BusProtocol"] as? String
    let kind = info["VirtualOrPhysical"] as? String
    let stores = (info["APFSPhysicalStores"] as? [Any]) ?? []
    let needsImages = bus == "Disk Image" || (kind == "Virtual" && stores.isEmpty)
    let images = needsImages
        ? plistFromProcess(executable: URL(fileURLWithPath: "/usr/bin/hdiutil"), arguments: ["info", "-plist"])
        : nil
    return diskBacking(fromDiskUtilInfo: info, hdiutilInfo: images, wholeDisk: wholeDisk)
}

/// The IORegistry entry ID of the IOMedia named `bsdName` -- the same identity `DeviceWatcher`
/// records as `BlockDevice.mediaIdentity`.
func liveMediaIdentity(ofBSDName bsdName: String) -> UInt64? {
    guard let matching = IOBSDNameMatching(kIOMainPortDefault, 0, bsdName) else { return nil }
    let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
    guard service != 0 else { return nil }
    defer { IOObjectRelease(service) }
    var identity: UInt64 = 0
    guard IORegistryEntryGetRegistryEntryID(service, &identity) == KERN_SUCCESS else { return nil }
    return identity
}
