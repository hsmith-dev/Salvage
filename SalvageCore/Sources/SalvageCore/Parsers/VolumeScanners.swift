import Foundation

/// Volume formats recognized by signature during discovery. `.fat` covers FAT32 and exFAT;
/// `FATVolume` distinguishes them while validating geometry. `.apfs` covers both a container
/// (NXSB at block 0) and a bare, unlocked volume device (APSB at block 0). `.raw` is a region with
/// no recognized metadata, read only by the sweep and the carving engine.
enum VolumeFormat: Sendable, Equatable {
    case fat, ntfs, ext, apfs, hfsPlus, raw

    /// Discovery skips recognized volumes whose parser isn't implemented yet, so they are never
    /// reported as scanned.
    var isScannable: Bool {
        switch self {
        case .fat, .raw: true
        case .ntfs: NTFSVolume.isImplemented
        case .ext: EXTVolume.isImplemented
        case .apfs: APFSContainer.isImplemented
        case .hfsPlus: HFSPlusVolume.isImplemented
        }
    }

    var displayName: String {
        switch self {
        case .fat: "FAT32/exFAT"
        case .ntfs: "NTFS"
        case .ext: "EXT2/3/4"
        case .apfs: "APFS"
        case .hfsPlus: "HFS+"
        case .raw: "Unknown"
        }
    }
}

/// Runs the metadata parser for one volume. Parsers emit `.found`; APFS may also emit
/// `.unlockRequired` for an encrypted volume (carrying `device` annotated with the volume).
func scanVolume(_ extent: VolumeExtent, reader: any BlockReader, device: BlockDevice?,
                emit: @escaping @Sendable (ScanEvent) async throws -> Void) async throws {
    let found: @Sendable (RecoveredFile) async throws -> Void = { try await emit(.found($0)) }
    switch extent.format {
    case .fat: try await FATVolume(reader: reader, extent: extent, emit: found).scan()
    case .ntfs: try await NTFSVolume(reader: reader, extent: extent, emit: found).scan()
    case .ext: try await EXTVolume(reader: reader, extent: extent, emit: found).scan()
    case .apfs: try await APFSContainer(reader: reader, extent: extent, device: device, emit: emit).scan()
    case .hfsPlus: try await HFSPlusVolume(reader: reader, extent: extent, emit: found).scan()
    case .raw: break
    }
}
