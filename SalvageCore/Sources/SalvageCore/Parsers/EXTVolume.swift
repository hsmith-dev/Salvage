import Foundation

/// EXT2/3/4 parser. All offsets are relative to one validated partition.
actor EXTVolume {
    static let isImplemented = false
    let reader: any BlockReader
    let extent: VolumeExtent
    let emit: @Sendable (RecoveredFile) async throws -> Void

    init(reader: any BlockReader, extent: VolumeExtent, emit: @escaping @Sendable (RecoveredFile) async throws -> Void) {
        self.reader = reader; self.extent = extent; self.emit = emit
    }
    func scan() async throws { throw ScanError.unsupportedFilesystem }
}
