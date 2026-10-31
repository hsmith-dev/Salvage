import Foundation

/// HFS+ parser. All offsets are relative to one validated partition.
actor HFSPlusVolume {
    static let isImplemented = false
    let reader: any BlockReader
    let extent: VolumeExtent
    let emit: @Sendable (RecoveredFile) async throws -> Void

    init(reader: any BlockReader, extent: VolumeExtent, emit: @escaping @Sendable (RecoveredFile) async throws -> Void) {
        self.reader = reader; self.extent = extent; self.emit = emit
    }
    func scan() async throws { throw ScanError.unsupportedFilesystem }
}
