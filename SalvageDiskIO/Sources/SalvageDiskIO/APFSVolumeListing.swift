import Foundation

// Story 2.4 (FR-6 / AD-3): read-only interpretation of `diskutil apfs list -plist`. Pure
// functions over an already-decoded dictionary, so they have direct unit coverage with
// fabricated plists; the one live function at the bottom spawns the subprocess.
//
// Verified against diskutil's output in this story's spike (spec Implementation Notes): a
// container has `ContainerReference` ("disk19"), `PhysicalStores[].DeviceIdentifier`
// ("disk18s1") and `Volumes[]`, each with `APFSVolumeUUID`, `DeviceIdentifier`, `Name`,
// `Encryption` and `Locked`.

/// One APFS volume as `diskutil apfs list -plist` reports it.
struct APFSListedVolume: Sendable, Equatable {
    /// Uppercased, so lookups never depend on diskutil's letter case.
    let uuid: String
    let bsdName: String
    let name: String?
    let isEncrypted: Bool
    let isLocked: Bool
}

/// One APFS container: the synthesized whole disk, the whole disks of its physical stores, and
/// its volumes.
struct APFSListedContainer: Sendable, Equatable {
    let reference: String?
    let physicalStoreWholeDisks: Set<String>
    let volumes: [APFSListedVolume]
}

/// Decodes the containers of a `diskutil apfs list -plist` dictionary. `nil` when the shape is
/// not the documented one (no `Containers` array, or a volume without UUID or device name), which
/// callers treat as "lock state unknown": nothing is marked locked, nothing is unlocked.
func apfsContainers(fromListPlist plist: [String: Any]) -> [APFSListedContainer]? {
    guard let containers = plist["Containers"] as? [[String: Any]] else { return nil }
    var result: [APFSListedContainer] = []
    for container in containers {
        var stores: Set<String> = []
        for store in (container["PhysicalStores"] as? [[String: Any]]) ?? [] {
            guard let identifier = store["DeviceIdentifier"] as? String,
                  let whole = wholeDiskBSDName(fromDevicePath: identifier) else { return nil }
            stores.insert(whole)
        }
        var volumes: [APFSListedVolume] = []
        for volume in (container["Volumes"] as? [[String: Any]]) ?? [] {
            guard let uuid = volume["APFSVolumeUUID"] as? String, isAPFSVolumeUUID(uuid),
                  let bsdName = volume["DeviceIdentifier"] as? String, isDiskNodeBSDName(bsdName) else { return nil }
            volumes.append(APFSListedVolume(uuid: uuid.uppercased(), bsdName: bsdName, name: volume["Name"] as? String,
                                            isEncrypted: volume["Encryption"] as? Bool ?? false,
                                            isLocked: volume["Locked"] as? Bool ?? false))
        }
        let reference = container["ContainerReference"] as? String
        result.append(APFSListedContainer(reference: reference.flatMap { isWholeDiskBSDName($0) ? $0 : nil },
                                          physicalStoreWholeDisks: stores, volumes: volumes))
    }
    return result
}

/// The volume with this UUID (case-insensitive), if listed.
func apfsVolume(uuid: String, in containers: [APFSListedContainer]) -> APFSListedVolume? {
    let wanted = uuid.uppercased()
    for container in containers {
        if let volume = container.volumes.first(where: { $0.uuid == wanted }) { return volume }
    }
    return nil
}

/// The Device Picker's "Locked" state for a whole disk: every APFS volume of every container the
/// disk takes part in (as the synthesized container disk itself, or as a physical store) is
/// locked, and there is at least one. Returns the first such volume so the picker can offer to
/// unlock it; `nil` for a disk with no container, or with any volume that isn't locked.
func lockedVolume(onWholeDisk name: String, containers: [APFSListedContainer]) -> APFSListedVolume? {
    var first: APFSListedVolume?
    for container in containers where container.reference == name || container.physicalStoreWholeDisks.contains(name) {
        for volume in container.volumes {
            guard volume.isLocked else { return nil }
            if first == nil { first = volume }
        }
    }
    return first
}

/// Strict 8-4-4-4-12 hexadecimal UUID. The one shape ever passed to `diskutil` as a volume
/// identifier, so a value from a parsed on-disk structure can't smuggle in an option or a path.
func isAPFSVolumeUUID(_ value: String) -> Bool {
    let bytes = Array(value.utf8)
    let groups = [8, 4, 4, 4, 12]
    guard bytes.count == 36 else { return false }
    var index = 0
    for (position, length) in groups.enumerated() {
        for _ in 0..<length {
            let byte = bytes[index]
            let isHex = (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
                || (UInt8(ascii: "A")...UInt8(ascii: "F")).contains(byte)
            guard isHex else { return false }
            index += 1
        }
        if position < groups.count - 1 {
            guard bytes[index] == UInt8(ascii: "-") else { return false }
            index += 1
        }
    }
    return true
}

/// Live: `diskutil apfs list -plist`, metadata only (no ownership or Full Disk Access needed,
/// like `diskutil info`), bounded by `plistFromProcess`'s deadline.
func diskUtilAPFSListPlist() -> [String: Any]? {
    plistFromProcess(executable: URL(fileURLWithPath: "/usr/sbin/diskutil"), arguments: ["apfs", "list", "-plist"])
}

/// Live: the containers currently attached, or `nil` when the listing failed.
func liveAPFSContainers() -> [APFSListedContainer]? {
    diskUtilAPFSListPlist().flatMap(apfsContainers(fromListPlist:))
}
