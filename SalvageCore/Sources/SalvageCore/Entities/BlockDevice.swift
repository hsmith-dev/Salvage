import Foundation

/// A whole physical/logical block device (a disk, not an individual mounted volume) that is a
/// candidate scan target. Pure data, per Architecture AD-1/AD-9 -- no DiskArbitration or any
/// platform import anywhere in `SalvageCore`. `SalvageDiskIO` is the sole module that discovers
/// real devices and produces `BlockDevice` values (see `DeviceWatcher`, `BootDiskSafety`).
///
/// The scan target is always the whole disk, never an individual volume/partition -- matches the
/// ERD (`ScanSession` targets a whole `BlockDevice` or a `LostPartitionCandidate`, never an
/// arbitrary volume) and FR-1 / UJ-1 ("selects the external SSD from the device list"). The
/// disk's partitions and volumes ride along in `partitions` for display only.
public struct BlockDevice: Identifiable, Equatable, Sendable {
    /// The whole-disk BSD device name, e.g. `"disk6"` (no leading `/dev/`, no partition suffix).
    /// Stable and unique among currently-attached devices, so it doubles as `id`.
    public let bsdName: String

    /// Attachment identity from the adapter; protects selection against BSD-name reuse.
    public let mediaIdentity: UInt64?

    /// A human-readable label for the device row (e.g. a vendor/model string), shown as-is --
    /// the boot-volume reason and any "grayed" treatment are a presentation concern for the
    /// view layer, not baked into this value.
    public let displayName: String

    /// The device's total size in bytes.
    public let sizeBytes: Int64

    /// `true` for an internal device, `false` for external. Internal and external devices still
    /// render together in one unified list (FR-1) -- this flag is row metadata, not a basis for
    /// splitting the list into sections.
    public let isInternal: Bool

    /// `true` if this device is, or backs, the live, currently-running boot volume. A boot
    /// device is never omitted from the list: it is shown grayed with a stated reason and is not
    /// a valid scan-selection target (Architecture AD-4's boot-volume exception).
    public let isBootVolume: Bool

    /// Set only on the value carried by `ScanEvent.unlockRequired`: the encrypted APFS volume
    /// (UUID and name) inside this device that needs a password or recovery key (FR-6).
    public let encryptedVolumeUUID: String?
    public let encryptedVolumeName: String?

    /// The disk's partition tree (partitions, any APFS container on them, and its volumes), shown
    /// beneath the drive in the Device Picker. Informational only: never a scan target. Empty when
    /// the tree is unknown or couldn't be read.
    public let partitions: [DevicePartition]

    /// What identifies this drive across unplugging and restarts (spec-tech-batch-7 §B), read by
    /// `SalvageDiskIO` from DiskArbitration and IORegistry metadata only, never from the device's
    /// bytes. Nil when the adapter couldn't read one (or for a value built without it).
    public let stableIdentity: StableIdentity?

    /// A drive's metadata-level identity. `mediaIdentity` changes on every attachment; this doesn't.
    public struct StableIdentity: Equatable, Sendable, Codable {
        /// The GPT disk GUID (uppercased), when the drive has a GUID partition table.
        public let diskGUID: String?
        /// For a drive without a GPT (an MBR drive, or one with no partition table), which has no disk
        /// GUID: each volume's byte offset and the filesystem volume UUID macOS reports for it
        /// (`DAVolumeUUID`), in offset order. Empty for a GPT drive.
        public let volumes: [Volume]
        public let sizeBytes: Int64
        public let model: String?
        /// The device's serial number, when its interface reports one (USB, NVMe, SATA).
        public let serial: String?

        public struct Volume: Equatable, Sendable, Codable {
            public let offsetBytes: Int64
            public let volumeUUID: String
            public init(offsetBytes: Int64, volumeUUID: String) { self.offsetBytes = offsetBytes; self.volumeUUID = volumeUUID }
        }

        public init(diskGUID: String?, volumes: [Volume] = [], sizeBytes: Int64, model: String?, serial: String?) {
            self.diskGUID = diskGUID; self.volumes = volumes; self.sizeBytes = sizeBytes
            self.model = model; self.serial = serial
        }
    }

    public init(
        bsdName: String,
        displayName: String,
        sizeBytes: Int64,
        isInternal: Bool,
        isBootVolume: Bool,
        mediaIdentity: UInt64? = nil,
        encryptedVolumeUUID: String? = nil,
        encryptedVolumeName: String? = nil,
        partitions: [DevicePartition] = [],
        stableIdentity: StableIdentity? = nil
    ) {
        self.bsdName = bsdName
        self.mediaIdentity = mediaIdentity
        self.displayName = displayName
        self.sizeBytes = sizeBytes
        self.isInternal = isInternal
        self.isBootVolume = isBootVolume
        self.encryptedVolumeUUID = encryptedVolumeUUID
        self.encryptedVolumeName = encryptedVolumeName
        self.partitions = partitions
        self.stableIdentity = stableIdentity
    }

    /// The same device, annotated with the encrypted volume that blocked part of its scan.
    public func requiringUnlock(volumeUUID: String, volumeName: String?) -> BlockDevice {
        BlockDevice(bsdName: bsdName, displayName: displayName, sizeBytes: sizeBytes, isInternal: isInternal,
                    isBootVolume: isBootVolume, mediaIdentity: mediaIdentity,
                    encryptedVolumeUUID: volumeUUID, encryptedVolumeName: volumeName, partitions: partitions,
                    stableIdentity: stableIdentity)
    }

    public var id: String { bsdName }
}
