import Foundation

// Boot-disk identification -- the harness's one hard safety boundary (spec's Boundaries &
// Constraints, "Never attempt a raw read against the live internal boot volume"). Everything
// here is deliberately fail-closed: if the boot disk set cannot be positively determined, the
// caller must refuse to proceed, never fall back to "assume nothing is protected."

enum BootDiskResolutionError: Error, CustomStringConvertible {
    case statfsFailed
    case physicalStoreResolutionFailed(container: String)

    var description: String {
        switch self {
        case .statfsFailed:
            return "could not determine the boot volume's BSD device via statfs(\"/\")"
        case .physicalStoreResolutionFailed(let container):
            return "could not resolve the physical whole disk(s) backing boot container \"\(container)\" via `diskutil info -plist` (process failed, or neither APFSPhysicalStores, WholeDisk, nor ParentWholeDisk was present/parseable)"
        }
    }
}

/// Returns the whole-disk BSD name (e.g. "disk3") hosting whatever "/" is currently mounted
/// from, by asking the kernel directly (`statfs`). On an APFS system this is the synthesized
/// *container* disk, not the physical disk backing it -- see `physicalWholeDisks`.
func bootWholeDiskBSDName() -> String? {
    var stat = statfs()
    guard statfs("/", &stat) == 0 else { return nil }
    let mntFromTuple = stat.f_mntfromname
    let mntFrom = withUnsafePointer(to: mntFromTuple) { ptr -> String in
        ptr.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: mntFromTuple)) {
            String(cString: $0)
        }
    }
    return wholeDiskBSDName(fromDevicePath: mntFrom)
}

/// Pure interpretation of `diskutil info -plist <bsdName>`'s already-decoded output. Kept
/// separate from the process-spawning I/O in `diskUtilInfoPlist` so it has direct unit coverage
/// with fabricated dictionaries, no live disk or subprocess required.
///
/// - If `APFSPhysicalStores` is present and non-empty (the case for a synthesized APFS
///   container disk, e.g. "disk3"), resolves each listed physical store (e.g. "disk0s2") down to
///   its own whole-disk name (e.g. "disk0") -- this is the real physical-parent relationship
///   DiskArbitration itself does not expose for a synthesized disk.
/// - Otherwise, if `WholeDisk` is true, `bsdName` is already its own physical whole disk.
/// - Otherwise, falls back to `ParentWholeDisk` if present.
/// - Returns `nil` (never a guess) if none of the above yields a usable answer.
func physicalWholeDisks(fromDiskUtilInfoPlist plist: [String: Any], bsdName: String) -> Set<String>? {
    if let physicalStores = plist["APFSPhysicalStores"] as? [[String: Any]], !physicalStores.isEmpty {
        var wholeDisks: Set<String> = []
        for store in physicalStores {
            guard let storeBSD = store["APFSPhysicalStore"] as? String,
                let storeWhole = wholeDiskBSDName(fromDevicePath: storeBSD)
            else {
                return nil
            }
            wholeDisks.insert(storeWhole)
        }
        return wholeDisks.isEmpty ? nil : wholeDisks
    }

    if let isWhole = plist["WholeDisk"] as? Bool, isWhole {
        return [bsdName]
    }

    if let parent = plist["ParentWholeDisk"] as? String {
        return [parent]
    }

    return nil
}

/// Runs `diskutil info -plist <bsdName>` and decodes its output. Metadata only -- confirmed
/// empirically this session (and consistent with the spec's Intent) that device
/// enumeration/metadata reads need no Full Disk Access, only byte-level raw reads do.
func diskUtilInfoPlist(for bsdName: String) -> [String: Any]? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
    process.arguments = ["info", "-plist", bsdName]
    let outputPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = Pipe()
    do {
        try process.run()
    } catch {
        return nil
    }
    let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    return (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any]
}

/// Resolves the physical whole disk(s) backing `bsdName`, combining the two functions above.
func physicalWholeDisks(backing bsdName: String) -> Set<String>? {
    guard let plist = diskUtilInfoPlist(for: bsdName) else { return nil }
    return physicalWholeDisks(fromDiskUtilInfoPlist: plist, bsdName: bsdName)
}

/// Resolves the full set of BSD whole-disk names that must never be targeted by a raw read: the
/// boot container disk itself, plus whatever physical disk(s) back it. `.failure` means "could
/// not positively determine the boot disk set" -- callers MUST treat that as "refuse to proceed"
/// (fail closed), never as "assume nothing is protected."
func resolveBootDisks() -> Result<Set<String>, BootDiskResolutionError> {
    guard let containerName = bootWholeDiskBSDName() else {
        return .failure(.statfsFailed)
    }
    guard let physical = physicalWholeDisks(backing: containerName) else {
        return .failure(.physicalStoreResolutionFailed(container: containerName))
    }
    return .success(physical.union([containerName]))
}

/// Pure membership check, kept separate from the live `resolveBootDisks()` I/O above so it has
/// direct, trivial unit coverage against a few known disk IDs.
func isWithinBootDiskSet(_ candidate: String, bootDisks: Set<String>) -> Bool {
    bootDisks.contains(candidate)
}
