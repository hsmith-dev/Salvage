import Foundation

/// Volume formats recognized by signature during discovery. `.fat` covers FAT32 and exFAT;
/// `FATVolume` distinguishes them while validating geometry.
enum VolumeFormat: Sendable, Equatable {
    case fat, ntfs, ext

    /// Discovery skips recognized volumes whose parser isn't implemented yet, so they are never
    /// reported as scanned.
    var isScannable: Bool {
        switch self {
        case .fat: true
        case .ntfs: NTFSVolume.isImplemented
        case .ext: EXTVolume.isImplemented
        }
    }
}

func scanVolume(_ extent: VolumeExtent, reader: any BlockReader,
                emit: @escaping @Sendable (RecoveredFile) async throws -> Void) async throws {
    switch extent.format {
    case .fat: try await FATVolume(reader: reader, extent: extent, emit: emit).scan()
    case .ntfs: try await NTFSVolume(reader: reader, extent: extent, emit: emit).scan()
    case .ext: try await EXTVolume(reader: reader, extent: extent, emit: emit).scan()
    }
}
