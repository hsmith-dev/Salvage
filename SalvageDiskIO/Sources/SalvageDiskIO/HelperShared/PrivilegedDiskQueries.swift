import Darwin
import Foundation
import IOKit
import Security

// Story 1.12: live, read-only system queries the privileged helper needs. Compiled into both
// SalvageDiskIO and `SalvageHelper`. Deliberately limited to kernel and IORegistry reads
// (statfs, getfsstat, IOKit property reads, the process's own code signature): no subprocess,
// no DiskArbitration session, no writes. Every failure returns `nil`, which callers treat as a
// refusal.

/// A whole-disk IOMedia as the IORegistry describes it.
struct RegistryDiskMedia: Sendable, Equatable {
    let registryID: UInt64
    let isWhole: Bool
    let major: Int32
    let minor: Int32
    /// Whole-disk names of every IOMedia above this one (e.g. "disk0" for an APFS container
    /// synthesized from "disk0s2"). Empty for a plain physical disk.
    let ancestorWholeDisks: Set<String>
    /// The media is an attached disk image or is layered on one (see `isDiskImageEntry`).
    let isDiskImage: Bool
}

/// Returns the whole-disk BSD name (e.g. "disk3") hosting whatever "/" is currently mounted
/// from, by asking the kernel directly (`statfs`). On an APFS system this is the synthesized
/// *container* disk, not the physical disk backing it.
func bootWholeDiskBSDName() -> String? {
    var stat = statfs()
    guard statfs("/", &stat) == 0 else { return nil }
    let mntFromTuple = stat.f_mntfromname
    let capacity = MemoryLayout.size(ofValue: mntFromTuple)
    let mntFrom = withUnsafePointer(to: mntFromTuple) { ptr -> String in
        ptr.withMemoryRebound(to: CChar.self, capacity: capacity) { chars -> String in
            // Bounded decode: stop at the first NUL within the buffer's own fixed capacity.
            let buffer = UnsafeBufferPointer(start: chars, count: capacity)
            let length = buffer.firstIndex(of: 0) ?? capacity
            return String(decoding: buffer[0..<length].map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
    }
    return wholeDiskBSDName(fromDevicePath: mntFrom)
}

/// Looks up a whole disk's IOMedia by BSD name. `nil` on any registry failure.
func registryDiskMedia(bsdName: String) -> RegistryDiskMedia? {
    guard isWholeDiskBSDName(bsdName) else { return nil }
    let media = IOServiceGetMatchingService(kIOMainPortDefault, IOBSDNameMatching(kIOMainPortDefault, 0, bsdName))
    guard media != 0 else { return nil }
    defer { IOObjectRelease(media) }
    var registryID: UInt64 = 0
    guard IOObjectConformsTo(media, "IOMedia") != 0,
          registryProperty(media, "BSD Name") as? String == bsdName,
          IORegistryEntryGetRegistryEntryID(media, &registryID) == KERN_SUCCESS,
          let isWhole = registryProperty(media, "Whole") as? Bool,
          let major = (registryProperty(media, "BSD Major") as? NSNumber)?.int32Value,
          let minor = (registryProperty(media, "BSD Minor") as? NSNumber)?.int32Value,
          let ancestry = registryAncestry(of: media),
          let wholeAncestors = wholeDiskNames(ancestry.mediaBSDNames, excluding: bsdName) else { return nil }
    return RegistryDiskMedia(registryID: registryID, isWhole: isWhole, major: major, minor: minor,
                             ancestorWholeDisks: wholeAncestors,
                             isDiskImage: ancestry.isDiskImage || isDiskImageEntry(media))
}

/// Whole-disk names of every IOMedia above the media named `name` (a whole disk, slice, APFS
/// volume or snapshot, e.g. "disk5s1" -> {"disk5", "disk4"} for an APFS volume whose container
/// is synthesized from "disk4s1"). The media's own whole disk is not included. `nil` on any
/// registry failure, which `isMounted` treats as mounted.
func registryAncestorWholeDisks(ofMediaNamed name: String) -> Set<String>? {
    guard isDiskNodeBSDName(name) else { return nil }
    let media = IOServiceGetMatchingService(kIOMainPortDefault, IOBSDNameMatching(kIOMainPortDefault, 0, name))
    guard media != 0 else { return nil }
    defer { IOObjectRelease(media) }
    guard IOObjectConformsTo(media, "IOMedia") != 0,
          registryProperty(media, "BSD Name") as? String == name,
          let ancestry = registryAncestry(of: media) else { return nil }
    return wholeDiskNames(ancestry.mediaBSDNames, excluding: wholeDiskBSDName(fromDevicePath: name) ?? name)
}

private func wholeDiskNames(_ mediaNames: [String], excluding own: String) -> Set<String>? {
    var wholes: Set<String> = []
    for ancestor in mediaNames {
        guard let whole = wholeDiskBSDName(fromDevicePath: ancestor), isWholeDiskBSDName(whole) else { return nil }
        if whole != own { wholes.insert(whole) }
    }
    return wholes
}

/// The startup disk set, resolved without spawning anything: statfs("/") for the container and
/// an IORegistry walk for its physical stores. `nil` (fail closed) on any failure.
func registryProtectedBootDisks() -> Set<String>? {
    guard let container = bootWholeDiskBSDName(), isWholeDiskBSDName(container) else { return nil }
    let media = IOServiceGetMatchingService(kIOMainPortDefault, IOBSDNameMatching(kIOMainPortDefault, 0, container))
    guard media != 0 else { return nil }
    defer { IOObjectRelease(media) }
    return protectedBootDisks(containerWholeDisk: container, ancestorMediaBSDNames: registryAncestry(of: media)?.mediaBSDNames)
}

/// What an IOService-plane walk above an entry found.
private struct RegistryAncestry {
    /// BSD names of every IOMedia ancestor.
    var mediaBSDNames: [String] = []
    /// Whether any ancestor is part of a disk-image driver chain.
    var isDiskImage = false
}

/// Walks every ancestor of `entry` in the IOService plane (all parents, not only the first, so a
/// multi-store container is covered). Bounded against pathological graphs; `nil` on any failure.
private func registryAncestry(of entry: io_registry_entry_t) -> RegistryAncestry? {
    var ancestry = RegistryAncestry()
    var visited: Set<UInt64> = []
    var frontier: [io_registry_entry_t] = []
    var iterator: io_iterator_t = 0
    guard IORegistryEntryGetParentIterator(entry, kIOServicePlane, &iterator) == KERN_SUCCESS else { return nil }
    defer { frontier.forEach { IOObjectRelease($0) } }
    func drain(_ iterator: io_iterator_t) {
        var parent = IOIteratorNext(iterator)
        while parent != 0 {
            frontier.append(parent)
            parent = IOIteratorNext(iterator)
        }
        IOObjectRelease(iterator)
    }
    drain(iterator)
    var budget = 512
    while let next = frontier.popLast() {
        defer { IOObjectRelease(next) }
        budget -= 1
        guard budget > 0 else { return nil }
        var id: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(next, &id) == KERN_SUCCESS else { return nil }
        guard visited.insert(id).inserted else { continue }
        if IOObjectConformsTo(next, "IOMedia") != 0 {
            guard let name = registryProperty(next, "BSD Name") as? String else { return nil }
            ancestry.mediaBSDNames.append(name)
        }
        if isDiskImageEntry(next) { ancestry.isDiskImage = true }
        var parents: io_iterator_t = 0
        guard IORegistryEntryGetParentIterator(next, kIOServicePlane, &parents) == KERN_SUCCESS else { return nil }
        drain(parents)
    }
    return ancestry
}

/// Driver classes of the disk-image stacks: `AppleDiskImageDevice` (diskimagesiod, macOS 11+)
/// and the IOHDIX family (older and in-kernel images).
private let diskImageDriverClasses = [
    "AppleDiskImageDevice", "AppleDiskImagesController", "IOHDIXController", "IOHDIXHDDrive",
    "IOHDIXHDDriveInKernel", "IODiskImageBlockStorageDeviceInKernel",
]

/// Whether a registry entry belongs to a disk-image driver chain: a disk-image driver class, a
/// "Disk Image" / file-backed protocol characteristic, or Apple's "Disk Image" product name.
/// Erring towards "image" only ever refuses a request.
private func isDiskImageEntry(_ entry: io_registry_entry_t) -> Bool {
    if diskImageDriverClasses.contains(where: { IOObjectConformsTo(entry, $0) != 0 }) { return true }
    if let protocolInfo = registryProperty(entry, "Protocol Characteristics") as? [String: Any] {
        if protocolInfo["Physical Interconnect"] as? String == "Disk Image"
            || protocolInfo["Physical Interconnect Location"] as? String == "File" { return true }
    }
    if let device = registryProperty(entry, "Device Characteristics") as? [String: Any],
       device["Product Name"] as? String == "Disk Image" { return true }
    return false
}

private func registryProperty(_ entry: io_registry_entry_t, _ key: String) -> Any? {
    IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
}

/// Every mounted filesystem's source device. getfsstat writes caller-owned storage; unlike
/// getmntinfo it shares no static mount buffer. `nil` if the mount table couldn't be read.
func mountSourcesSnapshot() -> [String]? {
    for _ in 0..<3 {
        let count = getfsstat(nil, 0, MNT_NOWAIT)
        guard count > 0, count < 1_000_000 else { break }
        var mounts = Array(repeating: statfs(), count: Int(count) + 16)
        let fetched = mounts.withUnsafeMutableBufferPointer {
            getfsstat($0.baseAddress, Int32($0.count * MemoryLayout<statfs>.stride), MNT_NOWAIT)
        }
        guard fetched >= 0 else { break }
        if fetched >= mounts.count { continue }
        return mounts.prefix(Int(fetched)).map { mount in
            withUnsafeBytes(of: mount.f_mntfromname) { bytes in
                String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
        }
    }
    return nil
}

/// The helper's real system: kernel and IORegistry reads only, plus the one read-only open.
struct LivePrivilegedOpenSystem: PrivilegedOpenSystem {
    func diskMedia(bsdName: String) -> RegistryDiskMedia? { registryDiskMedia(bsdName: bsdName) }
    func protectedBootDisks() -> Set<String>? { registryProtectedBootDisks() }
    func mountSources() -> [String]? { mountSourcesSnapshot() }
    func ancestorWholeDisks(ofMediaNamed name: String) -> Set<String>? { registryAncestorWholeDisks(ofMediaNamed: name) }
    func nodeStatus(atPath path: String) -> NodeStatus? {
        var node = stat()
        guard lstat(path, &node) == 0 else { return nil }
        return NodeStatus(mode: node.st_mode, rdev: node.st_rdev, uid: node.st_uid)
    }
    func openReadOnly(path: String) -> PrivilegedOpenAttempt {
        let descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        return descriptor >= 0 ? .opened(descriptor) : .failed(errno: errno)
    }
    func nodeStatus(ofDescriptor descriptor: Int32) -> NodeStatus? {
        var node = stat()
        guard fstat(descriptor, &node) == 0 else { return nil }
        return NodeStatus(mode: node.st_mode, rdev: node.st_rdev, uid: node.st_uid)
    }
    func closeDescriptor(_ descriptor: Int32) { close(descriptor) }
}

/// The Team ID in this process's own code signature, or `nil` when it is unsigned, ad-hoc
/// signed, or has no team (every such case disables the helper connection: fail closed).
func currentProcessTeamIdentifier() -> String? {
    var code: SecCode?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
    var info: CFDictionary?
    guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
          let info = info as? [String: Any] else { return nil }
    return info[kSecCodeInfoTeamIdentifier as String] as? String
}
