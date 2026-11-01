import Foundation

/// Something a scan could not do, told to the user once it is known. Notices travel beside
/// `ScanEvent` on their own stream (AD-11 keeps `ScanEvent` closed), never replace an `.error`,
/// and never stop a scan: each one describes a scan that still ran.
public enum ScanNotice: Sendable, Equatable {
    /// The partition table was damaged and ignored; the whole device was searched instead.
    case partitionTableIgnored(reason: String)
    /// The search for lost partitions stopped after `searchedBytes` of a `deviceBytes` device.
    case lostPartitionSearchLimited(searchedBytes: Int64, deviceBytes: Int64)
    /// Spots the lost-partition search could not read and skipped.
    case unreadableAreasSkipped(count: Int)
    /// The carver reached its total file cap after `count` reconstructed files.
    case carvingLimitReached(count: Int)
    /// Signature files that failed to load, so their file types weren't reconstructed.
    case signaturesSkipped([String])
    /// A resumed scan was stopped before its carve-only pass over the pre-checkpoint bytes finished.
    case resumedCarvingPartial
    /// A mapped volume whose metadata couldn't be read; the rest of the device was still scanned.
    case volumeSkipped(formatName: String, offset: Int64, reason: String)
    /// Damaged files or folders on a volume were skipped (never listed with wrong contents).
    case damagedItemsSkipped(count: Int, examples: [String])

    /// Plain-language text for the dashboard (EXPERIENCE.md voice: short, complete, factual).
    public var text: String {
        switch self {
        case .partitionTableIgnored:
            return "This drive's partition table is damaged, so Salvage ignored it and searched the whole drive for volumes instead."
        case .lostPartitionSearchLimited(let searched, let device):
            return "The search for lost partitions covered the first \(Self.bytes(searched)) of this \(Self.bytes(device)) drive."
        case .unreadableAreasSkipped(let count):
            return count == 1
                ? "Part of this drive couldn't be read, so 1 area was skipped."
                : "Part of this drive couldn't be read, so \(count.formatted()) areas were skipped."
        case .carvingLimitReached(let count):
            return "Salvage stopped reconstructing files after \(count.formatted()), so some files that could be reconstructed aren't listed."
        case .signaturesSkipped(let files):
            return "Some file-type definitions couldn't be loaded (\(files.joined(separator: ", "))), so files of those types weren't reconstructed."
        case .resumedCarvingPartial:
            return "This scan continued from where it was interrupted and was stopped before it finished reconstructing files from the part scanned earlier, so some of those aren't listed. Start the scan over to include them."
        case .volumeSkipped(let name, let offset, let reason):
            return "Salvage couldn't read the \(name) volume that starts \(Self.bytes(offset)) into this drive, so some of its files may be missing. \(reason) The rest of the drive was still scanned."
        case .damagedItemsSkipped(let count, let examples):
            let list = examples.isEmpty ? "" : " For example: \(examples.joined(separator: ", "))."
            return count == 1
                ? "1 damaged file or folder was skipped rather than listed with the wrong contents.\(list)"
                : "\(count.formatted()) damaged files or folders were skipped rather than listed with the wrong contents, or flagged as possibly damaged.\(list)"
        }
    }

    static func bytes(_ count: Int64) -> String { ByteCountFormatter.string(fromByteCount: count, countStyle: .file) }
}
