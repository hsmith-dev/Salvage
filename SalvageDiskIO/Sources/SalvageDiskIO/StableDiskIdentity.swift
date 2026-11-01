import DiskArbitration
import Foundation
import IOKit
import SalvageCore

// spec-tech-batch-7 §B: what identifies a drive across unplugging and restarts, so a saved scan can
// reconnect to it. `BlockDevice.mediaIdentity` (the IORegistry entry ID) is new on every
// attachment; these values live on the drive itself or in its firmware.
//
// Metadata only: everything comes from DiskArbitration descriptions and IORegistry properties
// macOS has already read. Nothing here opens or reads the device.
//
// - GPT: the disk GUID from the partition table header. macOS publishes it as the `UUID` property
//   of the `IOGUIDPartitionScheme` object beneath the whole disk's IOMedia; the whole disk's own
//   description has no `DAMediaUUID`.
// - Every drive: its volumes' filesystem UUIDs (`DAVolumeUUID`, derived from each filesystem's own
//   serial number or UUID), with their offsets. On a GPT drive they must match as well as the GUID,
//   since erasing a volume in place keeps the GUID (and, for the same format, the layout).
// - MBR, or no partition table: macOS publishes no MBR disk signature (not in the description, not
//   on `IOFDiskPartitionScheme`), so the volume UUIDs alone identify the drive.
// - Size, model, and the serial number when the interface reports one.

enum StableDiskIdentity {
    static let gptScheme = "GUID_partition_scheme"

    /// The identity from already-read values. Nil when there is nothing that survives a replug: a
    /// GPT drive whose GUID wasn't published, or a drive with no GPT and no volume UUIDs.
    static func identity(content: String?, schemeUUID: String?, volumes: [BlockDevice.StableIdentity.Volume],
                         sizeBytes: Int64, model: String?, serial: String?) -> BlockDevice.StableIdentity? {
        guard sizeBytes > 0 else { return nil }
        let model = clean(model), serial = clean(serial)
        let sorted = volumes.sorted { $0.offsetBytes < $1.offsetBytes }
        if content == gptScheme {
            guard let guid = clean(schemeUUID).flatMap(UUID.init(uuidString:)) else { return nil }
            return BlockDevice.StableIdentity(diskGUID: guid.uuidString, volumes: sorted, sizeBytes: sizeBytes, model: model,
                                              serial: serial)
        }
        guard !sorted.isEmpty else { return nil }
        return BlockDevice.StableIdentity(diskGUID: nil, volumes: sorted, sizeBytes: sizeBytes, model: model, serial: serial)
    }

    /// Fills in `stableIdentity` on each device from the descriptions the tree was built from, plus
    /// the IORegistry properties only it holds (the GPT GUID, the serial number).
    static func annotate(_ devices: [BlockDevice], descriptions: [RawDiskDescription], session: DASession) -> [BlockDevice] {
        devices.map { device in
            guard let whole = descriptions.first(where: { $0.bsdName == device.bsdName }),
                  let description = whole.description else { return device }
            let registry = registryValues(bsdName: device.bsdName, session: session)
            let identity = identity(content: description[DiskKey.mediaContent] as? String, schemeUUID: registry.schemeUUID,
                                    volumes: volumes(of: device.bsdName, whole: description, descriptions: descriptions),
                                    sizeBytes: device.sizeBytes, model: description[DiskKey.deviceModel] as? String,
                                    serial: registry.serial)
            return BlockDevice(bsdName: device.bsdName, displayName: device.displayName, sizeBytes: device.sizeBytes,
                               isInternal: device.isInternal, isBootVolume: device.isBootVolume,
                               mediaIdentity: device.mediaIdentity, encryptedVolumeUUID: device.encryptedVolumeUUID,
                               encryptedVolumeName: device.encryptedVolumeName, partitions: device.partitions,
                               stableIdentity: identity)
        }
    }

    /// The filesystem UUIDs of a whole disk's own volume (no partition table) and of its partitions.
    /// A partition without a known offset is left out rather than guessed.
    static func volumes(of wholeName: String, whole: [String: Any],
                        descriptions: [RawDiskDescription]) -> [BlockDevice.StableIdentity.Volume] {
        var result: [BlockDevice.StableIdentity.Volume] = []
        if let uuid = volumeUUID(whole) { result.append(.init(offsetBytes: 0, volumeUUID: uuid)) }
        for slice in descriptions where sliceDepth(slice.bsdName) == 1 && wholeDiskBSDName(fromDevicePath: slice.bsdName) == wholeName {
            guard let description = slice.description, let offset = slice.baseOffset, let uuid = volumeUUID(description) else { continue }
            result.append(.init(offsetBytes: offset, volumeUUID: uuid))
        }
        return result
    }

    static func volumeUUID(_ description: [String: Any]) -> String? {
        guard let value = description[kDADiskDescriptionVolumeUUIDKey as String] else { return nil }
        let cf = value as CFTypeRef
        guard CFGetTypeID(cf) == CFUUIDGetTypeID() else { return nil }
        // swiftlint:disable:next force_cast
        return CFUUIDCreateString(kCFAllocatorDefault, (cf as! CFUUID)) as String?
    }

    /// The GPT scheme's `UUID` and the device's serial number, from the IORegistry. Both nil when
    /// the disk's IOMedia can't be found.
    static func registryValues(bsdName: String, session: DASession) -> (schemeUUID: String?, serial: String?) {
        guard let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsdName) else { return (nil, nil) }
        let media = DADiskCopyIOMedia(disk)
        guard media != 0 else { return (nil, nil) }
        defer { IOObjectRelease(media) }
        return (gptSchemeUUID(below: media), serialNumber(above: media))
    }

    /// The `UUID` of the `IOGUIDPartitionScheme` child of a whole disk's IOMedia: the disk GUID.
    static func gptSchemeUUID(below media: io_registry_entry_t) -> String? {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(media, kIOServicePlane, &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var found: String?
        while case let child = IOIteratorNext(iterator), child != 0 {
            defer { IOObjectRelease(child) }
            guard found == nil, IOObjectConformsTo(child, "IOGUIDPartitionScheme") != 0 else { continue }
            found = IORegistryEntryCreateCFProperty(child, "UUID" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
        }
        return found
    }

    /// The nearest serial number above the media: a USB device's, or the one in a storage device's
    /// "Device Characteristics" (NVMe, SATA).
    static func serialNumber(above media: io_registry_entry_t) -> String? {
        let options = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
        func search(_ key: String) -> CFTypeRef? {
            IORegistryEntrySearchCFProperty(media, kIOServicePlane, key as CFString, kCFAllocatorDefault, options)
        }
        for key in ["USB Serial Number", "kUSBSerialNumberString"] {
            if let serial = clean(search(key) as? String) { return serial }
        }
        if let characteristics = search("Device Characteristics") as? [String: Any],
           let serial = clean(characteristics["Serial Number"] as? String) { return serial }
        return clean(search("Serial Number") as? String)
    }

    private static func clean(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters)), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
