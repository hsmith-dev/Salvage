import Foundation

// Ported, close to verbatim, from Story 1.2's spike harness
// (scripts/spike-raw-device-access/Sources/spike-raw-device-access/BootDiskSafety.swift) --
// the harness's one hard safety boundary, hardened through a real safety-focused review pass
// (see that story's Review Triage Log #1: boot-disk resolution must fail closed, with real
// physical-store resolution, never a guessed/hardcoded disk). Re-deriving this logic fresh here
// risks reintroducing the exact fail-open bugs that review caught, per spec-1-3's Resolved
// decision -- so it is ported, not re-derived. The logic itself is unchanged from the spike;
// only its home module changes.

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

// `bootWholeDiskBSDName()` moved to HelperShared/PrivilegedDiskQueries.swift (Story 1.12) so the
// privileged helper, which must never spawn `diskutil`, can share the statfs logic.

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
        // Validate through the same chokepoint every other disk-path input in this file goes
        // through -- an unvalidated `ParentWholeDisk` string would otherwise be trusted as a
        // disk name outright, undermining this function's fail-closed guarantee.
        guard let parentWhole = wholeDiskBSDName(fromDevicePath: parent) else { return nil }
        return [parentWhole]
    }

    return nil
}

/// Runs `diskutil info -plist <bsdName>` and decodes its output. Metadata only -- confirmed
/// empirically in Story 1.2 (and consistent with that spike's Intent) that device
/// enumeration/metadata reads need no Full Disk Access, only byte-level raw reads do.
func diskUtilInfoPlist(for bsdName: String) -> [String: Any]? {
    plistFromProcess(executable: URL(fileURLWithPath: "/usr/sbin/diskutil"), arguments: ["info", "-plist", bsdName])
}

/// Runs a metadata subprocess with a hard deadline and decodes its stdout as a dictionary plist.
/// stderr goes to the null device so it can never fill an undrained pipe and wedge the child;
/// stdout is drained concurrently so a large plist cannot either. Timeout, launch failure,
/// non-zero exit or undecodable output all return `nil`, which every caller treats as a failed
/// protection check (fail closed: the device is refused).
func plistFromProcess(executable: URL, arguments: [String], timeout: TimeInterval = 10) -> [String: Any]? {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    let outputPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice
    let exited = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exited.signal() }
    do {
        try process.run()
    } catch {
        return nil
    }
    let output = ProcessOutput()
    let drained = DispatchSemaphore(value: 0)
    let reader = outputPipe.fileHandleForReading
    DispatchQueue.global(qos: .userInitiated).async {
        output.store(reader.readDataToEndOfFile())
        drained.signal()
    }
    guard exited.wait(timeout: .now() + timeout) == .success else {
        process.terminate()
        if exited.wait(timeout: .now() + 1) == .timedOut { kill(process.processIdentifier, SIGKILL) }
        return nil
    }
    // The child has exited, so its write end is closed; bound the drain anyway in case a
    // grandchild inherited the pipe.
    guard drained.wait(timeout: .now() + 2) == .success, process.terminationStatus == 0 else { return nil }
    return (try? PropertyListSerialization.propertyList(from: output.data, options: [], format: nil)) as? [String: Any]
}

private final class ProcessOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = Data()
    func store(_ data: Data) { lock.withLock { stored = data } }
    var data: Data { lock.withLock { stored } }
}

/// Resolves the physical whole disk(s) backing `bsdName`, combining the two functions above.
func physicalWholeDisks(backing bsdName: String) -> Set<String>? {
    guard let plist = diskUtilInfoPlist(for: bsdName) else { return nil }
    return physicalWholeDisks(fromDiskUtilInfoPlist: plist, bsdName: bsdName)
}

/// Resolves the full set of BSD whole-disk names that must never be targeted by a raw read: the
/// boot container disk itself, plus whatever physical disk(s) back it. `.failure` means "could
/// not positively determine the boot disk set" -- callers performing a raw read MUST treat that
/// as "refuse to proceed" (fail closed), never as "assume nothing is protected." The device picker also refuses
/// to publish selectable devices until this resolution succeeds.
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
