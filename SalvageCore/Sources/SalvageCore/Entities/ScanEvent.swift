import Foundation

public enum ScanError: Error, Sendable, Equatable, CustomStringConvertible {
    case unsupportedFilesystem
    case malformed(String)
    case io(String)
    case unsafeTarget(String)
    case deviceInUse
    case permissionDenied
    case deviceChanged
    case unlockFailed(UnlockError)

    public var description: String {
        switch self {
        case .unsupportedFilesystem: "This filesystem isn't supported yet."
        case .malformed(let reason): "The filesystem metadata is damaged: \(reason)"
        case .io(let reason): "Couldn't read the device: \(reason)"
        case .unsafeTarget(let reason): reason
        case .deviceInUse: "In use by another scan."
        case .permissionDenied: "Allow Salvage in System Settings → Privacy & Security → Full Disk Access, then retry the scan. You may need to reopen Salvage."
        case .deviceChanged: "The device was removed or replaced. Reconnect it and select it again."
        case .unlockFailed: "Couldn't unlock this volume."
        }
    }
}

public enum UnlockError: Error, Sendable, Equatable { case wrongPassword, toolFailure }

public struct LostPartitionCandidate: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let offset: Int64
    public let sizeBytes: Int64
    public init(id: UUID = UUID(), offset: Int64, sizeBytes: Int64) {
        self.id = id; self.offset = offset; self.sizeBytes = sizeBytes
    }
}

/// Indexed intact metadata; this value does not mean a destination copy has been made.
public struct RecoveredFile: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let name: String
    public let path: String
    public let sizeBytes: Int64
    /// Last-modified time from source metadata; nil when the format or entry doesn't provide one.
    public let modified: Date?
    /// True when the source metadata marks the entry deleted (not a live file).
    public let isDeleted: Bool
    public let sourceMetadata: SourceMetadata
    public init(id: UUID = UUID(), name: String, path: String, sizeBytes: Int64,
                modified: Date? = nil, isDeleted: Bool = false, sourceMetadata: SourceMetadata) {
        self.id = id; self.name = name; self.path = path; self.sizeBytes = sizeBytes
        self.modified = modified; self.isDeleted = isDeleted
        self.sourceMetadata = sourceMetadata
    }
}

public struct SourceMetadata: Sendable, Equatable {
    public enum Filesystem: String, Sendable { case fat32, exfat, ntfs, ext }
    public let filesystem: Filesystem
    public let volumeOffset: Int64
    /// Device-absolute byte offset of the metadata record: FAT/exFAT directory entry, NTFS MFT
    /// record, or ext inode.
    public let recordOffset: Int64
    /// Format-specific allocation anchor: FAT/exFAT first cluster, NTFS MFT record number, or
    /// ext inode number.
    public let allocationStart: UInt64
    public let contiguous: Bool
    /// Original record bytes preserve timestamps and format-specific fields for later recovery.
    public let rawRecord: Data
    public init(filesystem: Filesystem, volumeOffset: Int64, recordOffset: Int64,
                allocationStart: UInt64, contiguous: Bool, rawRecord: Data) {
        self.filesystem = filesystem; self.volumeOffset = volumeOffset
        self.recordOffset = recordOffset; self.allocationStart = allocationStart
        self.contiguous = contiguous; self.rawRecord = rawRecord
    }
}

public enum ScanEvent: Sendable, Equatable {
    case progress(bytesScanned: Int64, totalBytes: Int64)
    case found(RecoveredFile)
    case lostPartitionFound(LostPartitionCandidate)
    case unlockRequired(BlockDevice)
    case error(ScanError)
    case completed
}
