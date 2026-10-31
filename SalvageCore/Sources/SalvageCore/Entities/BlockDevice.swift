import Foundation

/// A whole physical/logical block device (a disk, not an individual mounted volume) that is a
/// candidate scan target. Pure data, per Architecture AD-1/AD-9 -- no DiskArbitration or any
/// platform import anywhere in `SalvageCore`. `SalvageDiskIO` is the sole module that discovers
/// real devices and produces `BlockDevice` values (see `DeviceWatcher`, `BootDiskSafety`).
///
/// Models whole disks only, never an individual volume/partition -- matches the ERD
/// (`ScanSession` targets a whole `BlockDevice` or a `LostPartitionCandidate`, never an arbitrary
/// volume) and FR-1 / UJ-1 ("selects the external SSD from the device list").
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

    public init(
        bsdName: String,
        displayName: String,
        sizeBytes: Int64,
        isInternal: Bool,
        isBootVolume: Bool,
        mediaIdentity: UInt64? = nil
    ) {
        self.bsdName = bsdName
        self.mediaIdentity = mediaIdentity
        self.displayName = displayName
        self.sizeBytes = sizeBytes
        self.isInternal = isInternal
        self.isBootVolume = isBootVolume
    }

    public var id: String { bsdName }
}
