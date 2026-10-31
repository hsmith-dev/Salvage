import DiskArbitration
import Foundation

func listDevices() {
    guard let session = DASessionCreate(kCFAllocatorDefault) else {
        print("FAILED: DASessionCreate returned nil.")
        exit(1)
    }

    var bootDisks: Set<String> = []
    switch resolveBootDisks() {
    case .success(let disks):
        bootDisks = disks
    case .failure(let error):
        // Listing is read-only/informational -- unlike --read, nothing destructive happens here
        // -- but a reader must not be left thinking the (possibly incomplete) BOOT tags below
        // are authoritative.
        print("WARNING: could not positively determine the boot disk set (\(error)) -- BOOT tags below may be incomplete. Do not rely on their absence as proof a disk is safe to target with --read; --read performs its own fail-closed check regardless.")
        print("")
    }

    print("Enumerating whole disks via DiskArbitration (metadata only -- no Full Disk Access required for this step):")
    print("")

    var found = 0
    for n in 0...63 {
        let name = "disk\(n)"
        guard let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, name) else { continue }
        guard let descCF = DADiskCopyDescription(disk) else { continue }
        let desc = descCF as NSDictionary
        found += 1

        let isInternal = (desc[kDADiskDescriptionDeviceInternalKey as String] as? Bool) ?? false
        let isWhole = (desc[kDADiskDescriptionMediaWholeKey as String] as? Bool) ?? false
        let sizeBytes = (desc[kDADiskDescriptionMediaSizeKey as String] as? NSNumber)?.int64Value ?? 0
        let model = ((desc[kDADiskDescriptionDeviceModelKey as String] as? String) ?? "unknown")
            .trimmingCharacters(in: .whitespaces)
        let protocolName = (desc[kDADiskDescriptionDeviceProtocolKey as String] as? String) ?? "unknown"
        let sizeStr = ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)

        var tags: [String] = [isInternal ? "internal" : "external"]
        tags.append(isWhole ? "whole-disk" : "partition")
        if isWithinBootDiskSet(name, bootDisks: bootDisks) {
            tags.append("BOOT -- this harness refuses --read against this disk")
        }

        print("/dev/\(name)  (raw: /dev/r\(name))  \(sizeStr)  \(protocolName)  \(model)  [\(tags.joined(separator: ", "))]")
    }

    print("")
    if found == 0 {
        print("No disks enumerated -- unexpected. Check that DiskArbitration is available in this environment.")
    } else {
        print("\(found) disk(s) enumerated.")
    }
}
