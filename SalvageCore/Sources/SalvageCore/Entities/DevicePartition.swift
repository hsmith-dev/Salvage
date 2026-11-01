import Foundation

/// One partition or volume shown beneath a drive in the Device Picker's tree (Disk Utility style):
/// a slice of a drive's partition map, an APFS container held by such a slice, or a volume inside
/// that container. Pure data (Architecture AD-1); `SalvageDiskIO` produces these from the
/// platform's disk descriptions.
///
/// Informational only. The scan target is always the whole `BlockDevice` the partition belongs
/// to; a partition is never selectable for scanning on its own.
public struct DevicePartition: Identifiable, Equatable, Sendable {
    /// The partition's or volume's BSD name, e.g. `"disk6s2"` or `"disk3s5"`. Unique across the
    /// whole device tree, so it doubles as `id`.
    public let bsdName: String

    /// The volume name, or the partition type in plain words when the partition is unnamed
    /// (e.g. `"EFI"`, `"APFS container"`).
    public let displayName: String

    /// The partition's size in bytes. `nil` for an APFS volume, whose space is shared with the
    /// other volumes of its container, so no per-volume size is meaningful here.
    public let sizeBytes: Int64?

    /// The format in plain words: "exFAT", "APFS", "NTFS", "FAT32", "HFS+", "Linux (EXT)", "EFI"
    /// or "Unknown".
    public let formatName: String

    /// What sits inside this node: an APFS container's volumes. Empty for an ordinary partition.
    public let children: [DevicePartition]

    /// Where the partition starts on its drive, in bytes from the drive's first byte (the IOMedia
    /// `Base`). Lets scan results, which record each volume's start offset, be matched to this
    /// partition by equality. `nil` when unknown, and for a volume inside an APFS container (its
    /// files are found at the container's offset).
    public let offsetBytes: Int64?

    public init(bsdName: String, displayName: String, sizeBytes: Int64?, formatName: String,
                children: [DevicePartition] = [], offsetBytes: Int64? = nil) {
        self.bsdName = bsdName
        self.displayName = displayName
        self.sizeBytes = sizeBytes
        self.formatName = formatName
        self.children = children
        self.offsetBytes = offsetBytes
    }

    public var id: String { bsdName }
}
