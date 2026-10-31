import Darwin
import DiskArbitration
import Foundation

/// Checks `targetWholeDisk` against a freshly-resolved boot disk set and, on any match or any
/// resolution failure, prints why and returns `true` ("refuse"). Called twice from
/// `performRead` -- once up front, and again immediately before `open()` -- rather than once
/// and cached, because the up-to-20s `DADiskUnmount` wait in between is enough time for a device
/// swap reusing the same BSD name to slip past a stale check.
func refuseIfBootDisk(_ targetWholeDisk: String) -> Bool {
    switch resolveBootDisks() {
    case .failure(let error):
        print("REFUSED: could not positively determine the boot disk set (\(error)).")
        print("Failing closed rather than risking a raw read against the live boot volume.")
        return true
    case .success(let bootDisks):
        guard isWithinBootDiskSet(targetWholeDisk, bootDisks: bootDisks) else {
            return false
        }
        print("REFUSED: \(targetWholeDisk) is in the boot disk set (\(bootDisks.sorted().joined(separator: ", "))) -- it hosts, or backs, the live running boot volume.")
        print("This harness never attempts a raw read against the live boot volume -- no override exists (spike's Boundaries & Constraints, AD-4's boot-volume exception).")
        return true
    }
}

func performRead(path: String, skipUnmount: Bool) {
    let fileName = (path as NSString).lastPathComponent
    if !fileName.hasPrefix("r") {
        print("WARNING: \(path) does not look like a raw device node (expected /dev/rdiskN, got a buffered-looking node) -- continuing anyway since this is what was asked for.")
    }

    guard let targetWholeDisk = wholeDiskBSDName(fromDevicePath: path) else {
        print("ERROR: could not parse a BSD whole-disk name (e.g. \"disk6\") from \"\(path)\" -- expected a raw or buffered device node like /dev/rdisk6 or /dev/rdisk6s1.")
        exit(64)
    }

    if refuseIfBootDisk(targetWholeDisk) {
        exit(1)
    }

    guard let session = DASessionCreate(kCFAllocatorDefault) else {
        print("FAILED: DASessionCreate returned nil.")
        exit(1)
    }

    guard let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, targetWholeDisk) else {
        print("FAILED: DADiskCreateFromBSDName(\"\(targetWholeDisk)\") returned nil -- no such device attached?")
        exit(1)
    }

    if skipUnmount {
        print("SKIPPING DADiskUnmount (--no-unmount) -- documenting actual behavior while \(targetWholeDisk) may still be mounted (I/O matrix row 3).")
    } else {
        print("Unmounting \(targetWholeDisk) via DADiskUnmount (whole-disk), per AD-4...")
        switch unmountWholeDisk(disk, session: session) {
        case .success:
            print("DADiskUnmount: succeeded.")
        case .failure(let reason):
            print("DADiskUnmount: FAILED -- \(reason)")
            print("Continuing to attempt the raw read anyway, to observe and report actual behavior rather than assume the read will also fail (spec: 'report what actually happened, not an assumption').")
        }
    }

    // Re-check immediately before open() -- see refuseIfBootDisk's doc comment for why a single
    // up-front check is not enough.
    if refuseIfBootDisk(targetWholeDisk) {
        exit(1)
    }

    print("Attempting raw open(\"\(path)\", O_RDONLY)...")
    let fd = open(path, O_RDONLY)
    if fd < 0 {
        let err = errno
        print("RESULT: open() FAILED -- errno \(err): \(String(cString: strerror(err)))")
        exit(1)
    }
    defer { close(fd) }
    print("RESULT: open() succeeded (fd \(fd)).")

    print("Attempting read() of 512 bytes...")
    var buffer = [UInt8](repeating: 0, count: 512)
    let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
        read(fd, rawBuffer.baseAddress, rawBuffer.count)
    }
    if bytesRead < 0 {
        let err = errno
        print("RESULT: read() FAILED -- errno \(err): \(String(cString: strerror(err)))")
        exit(1)
    }

    print("RESULT: read() succeeded -- \(bytesRead) bytes returned.")
    let hexCount = min(bytesRead, 64)
    let hex = buffer.prefix(hexCount).map { String(format: "%02x", $0) }.joined(separator: " ")
    print("First \(hexCount) bytes (hex): \(hex)")
}
