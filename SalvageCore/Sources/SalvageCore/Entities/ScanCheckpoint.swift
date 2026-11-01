import Foundation

/// A cold-start resume point (AD-11). It holds offsets and sizes only, never file names, paths
/// or contents. `sweepOffset` is relative to the start of volume `sweepVolumeIndex`; every byte of
/// earlier volumes and every byte of that volume before `sweepOffset` has already been read.
public struct ScanCheckpoint: Codable, Sendable, Equatable {
    /// Version 2 added the `extents` layout fingerprint; version 3 added `carveBackfillOffset`.
    public static let currentVersion = 3

    /// One discovered volume extent, as a device-absolute byte range.
    public struct Extent: Codable, Sendable, Equatable, Hashable {
        public let offset: Int64
        public let length: Int64
        public init(offset: Int64, length: Int64) { self.offset = offset; self.length = length }
    }

    public let version: Int
    /// The source device size when the checkpoint was taken; a different size means a different device.
    public let deviceSizeBytes: Int64
    public let totalBytes: Int64
    /// The ordered layout of supported volumes the sweep walked. A resume is applied only when the
    /// device's freshly discovered layout matches this exactly.
    public let extents: [Extent]
    public let sweepVolumeIndex: Int
    public let sweepOffset: Int64
    public let bytesScanned: Int64
    /// Set only while a resumed scan re-carves the bytes it skipped (the carve backfill). The sweep
    /// is then complete, and `sweepVolumeIndex`/`sweepOffset` name where that resumed sweep began:
    /// the end of the backfill region. The value is how far the backfill has carved, as a position
    /// in the concatenated `extents` (0 is the first extent's first byte). Absent in JSON when nil.
    public let carveBackfillOffset: Int64?

    public init(version: Int = ScanCheckpoint.currentVersion, deviceSizeBytes: Int64, totalBytes: Int64,
                extents: [Extent], sweepVolumeIndex: Int, sweepOffset: Int64, bytesScanned: Int64,
                carveBackfillOffset: Int64? = nil) {
        self.version = version; self.deviceSizeBytes = deviceSizeBytes; self.totalBytes = totalBytes
        self.extents = extents
        self.sweepVolumeIndex = sweepVolumeIndex; self.sweepOffset = sweepOffset; self.bytesScanned = bytesScanned
        self.carveBackfillOffset = carveBackfillOffset
    }

    /// Structural sanity that does not depend on the device being scanned.
    public var isWellFormed: Bool {
        version == Self.currentVersion && deviceSizeBytes > 0 && totalBytes > 0
            && sweepVolumeIndex >= 0 && sweepOffset >= 0
            && bytesScanned >= 0 && bytesScanned <= totalBytes && totalBytes <= deviceSizeBytes
            && (carveBackfillOffset.map { $0 >= 0 && $0 <= totalBytes } ?? true)
            && extents.indices.contains(sweepVolumeIndex)
            && extents.allSatisfy { $0.offset >= 0 && $0.length > 0 }
            && extents.reduce(Int64(0)) { $0.addingReportingOverflow($1.length).partialValue } == totalBytes
    }
}
