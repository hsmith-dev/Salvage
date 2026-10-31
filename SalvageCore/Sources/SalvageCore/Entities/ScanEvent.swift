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
    public let sourceMetadata: SourceMetadata
    public init(id: UUID = UUID(), name: String, path: String, sizeBytes: Int64, sourceMetadata: SourceMetadata) {
        self.id = id; self.name = name; self.path = path; self.sizeBytes = sizeBytes
        self.sourceMetadata = sourceMetadata
    }
}

public struct SourceMetadata: Sendable, Equatable {
    public enum Filesystem: String, Sendable { case fat32, exfat }
    public let filesystem: Filesystem
    public let volumeOffset: Int64
    public let directoryEntryOffset: Int64
    public let firstCluster: UInt32
    public let contiguous: Bool
    /// Original entry bytes preserve timestamps and format-specific fields for later recovery.
    public let directoryEntries: Data
    public init(filesystem: Filesystem, volumeOffset: Int64, directoryEntryOffset: Int64,
                firstCluster: UInt32, contiguous: Bool, directoryEntries: Data) {
        self.filesystem = filesystem; self.volumeOffset = volumeOffset
        self.directoryEntryOffset = directoryEntryOffset; self.firstCluster = firstCluster
        self.contiguous = contiguous; self.directoryEntries = directoryEntries
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
