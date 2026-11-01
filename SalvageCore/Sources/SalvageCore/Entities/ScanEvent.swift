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

/// Why an encrypted volume couldn't be unlocked. Never carries the credential.
public enum UnlockError: Error, Sendable, Equatable {
    /// The password or recovery key doesn't unwrap any of the volume's keys.
    case wrongPassword
    /// The unlock couldn't be attempted or didn't finish (unreadable or damaged keybag, volume not found).
    case toolFailure
    /// The volume's key isn't protected by a password Salvage can use: hardware encryption tied to
    /// the Mac it came from (T2 / Apple silicon internal storage), or a layout Salvage doesn't read.
    case unsupported
    /// The credential unwrapped the volume key, but the volume's file tree failed its checksum or structure check.
    case damaged
}

public struct LostPartitionCandidate: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let offset: Int64
    public let sizeBytes: Int64
    /// Plain-language filesystem name from the signature that revealed it, e.g. "exFAT".
    public let formatName: String
    public init(id: UUID = UUID(), offset: Int64, sizeBytes: Int64, formatName: String = "Unknown") {
        self.id = id; self.offset = offset; self.sizeBytes = sizeBytes; self.formatName = formatName
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
    /// Where the file's bytes live, in file order. Empty with `residentData == nil` means the
    /// parser couldn't map the contents; preview and recovery must treat it as unavailable.
    public let content: FileContent
    /// How the file was found (AD-7). Filesystem parsers report `.metadata`; the carving engine
    /// reports `.carved`.
    public let recoveryMethod: RecoveryMethod
    /// True when the producer knows the content is incomplete (e.g. a carve cut short by a
    /// missing footer). Shown as "Partial — may be incomplete"; never presented as complete.
    public let isPartial: Bool
    /// Producer's estimate, in `0...1`, that the bytes were overwritten since the file was lost.
    /// Metadata parsers report 0 (deleted files already passed a free-space check).
    public let overwriteConfidence: Double
    public init(id: UUID = UUID(), name: String, path: String, sizeBytes: Int64,
                modified: Date? = nil, isDeleted: Bool = false, sourceMetadata: SourceMetadata,
                content: FileContent = .unmapped, recoveryMethod: RecoveryMethod = .metadata,
                isPartial: Bool = false, overwriteConfidence: Double = 0) {
        self.id = id; self.name = name; self.path = path; self.sizeBytes = sizeBytes
        self.modified = modified; self.isDeleted = isDeleted
        self.sourceMetadata = sourceMetadata; self.content = content
        self.recoveryMethod = recoveryMethod; self.isPartial = isPartial
        self.overwriteConfidence = overwriteConfidence
    }
}

/// A contiguous piece of file data in file order. `deviceOffset == nil` is a sparse hole that
/// reads as zeros.
public struct DataRun: Sendable, Equatable {
    public let deviceOffset: Int64?
    public let length: Int64
    /// Only inside `FileContent.encryptedRuns`: the cipher's data-unit number (tweak) of the
    /// first `contentDataUnitSize`-byte unit at `deviceOffset`; later units count up from it.
    public let firstDataUnit: UInt64?
    public init(deviceOffset: Int64?, length: Int64, firstDataUnit: UInt64? = nil) {
        self.deviceOffset = deviceOffset; self.length = length; self.firstDataUnit = firstDataUnit
    }
}

public enum FileContent: Sendable, Equatable {
    /// The parser didn't (or couldn't) map this file's bytes.
    case unmapped
    /// Bytes stored inside the metadata record itself (e.g. NTFS resident `$DATA`).
    case resident(Data)
    /// Device-absolute runs covering at least `sizeBytes` in file order; reads stop at `sizeBytes`.
    case runs([DataRun])
    /// Like `runs`, but the bytes on the device are ciphertext (an unlocked FileVault volume, Story
    /// 2.5). Every placed run carries its `firstDataUnit`, and its device range, rounded up to whole
    /// data units, holds the ciphertext. Reads decrypt through the `ContentDecryptor` registered
    /// for `keyID` (the volume UUID) with `FileContentReader`; without one the content is locked.
    case encryptedRuns([DataRun], keyID: String)
}

public struct SourceMetadata: Sendable, Equatable {
    public enum Filesystem: String, Sendable { case fat32, exfat, ntfs, ext, apfs, hfsPlus, carved }
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
    /// The volume's name inside a container that holds several volumes at one `volumeOffset`
    /// (APFS); nil for formats with one volume per offset.
    public let volumeName: String?
    /// That volume's identity (the APFS volume UUID, uppercased), so volumes sharing a container
    /// offset stay apart; nil for formats with one volume per offset.
    public let volumeID: String?
    public init(filesystem: Filesystem, volumeOffset: Int64, recordOffset: Int64,
                allocationStart: UInt64, contiguous: Bool, rawRecord: Data,
                volumeName: String? = nil, volumeID: String? = nil) {
        self.filesystem = filesystem; self.volumeOffset = volumeOffset
        self.recordOffset = recordOffset; self.allocationStart = allocationStart
        self.contiguous = contiguous; self.rawRecord = rawRecord
        self.volumeName = volumeName; self.volumeID = volumeID
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
