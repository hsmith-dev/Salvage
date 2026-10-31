import Foundation

/// APFS parser (AD-2: original Swift from Apple's public APFS Reference; no GPL/LGPL code).
/// Handles a container (NXSB at block 0) and a bare unlocked volume device (APSB at block 0).
/// All offsets are relative to one validated partition.
actor APFSContainer {
    static let isImplemented = false
    let reader: any BlockReader
    let extent: VolumeExtent
    /// The scanned device, annotated and emitted with `.unlockRequired` for an encrypted volume.
    let device: BlockDevice?
    let emit: @Sendable (ScanEvent) async throws -> Void

    init(reader: any BlockReader, extent: VolumeExtent, device: BlockDevice?,
         emit: @escaping @Sendable (ScanEvent) async throws -> Void) {
        self.reader = reader; self.extent = extent; self.device = device; self.emit = emit
    }
    func scan() async throws { throw ScanError.unsupportedFilesystem }
}
