import Foundation

/// The layout fingerprint a scan records (spec-tech-batch-7 §B): the ordered volume extents that
/// volume discovery finds on a device, exactly as `ScanCheckpoint.extents` holds them. A saved
/// scan is reconnected to a device only when the device's fingerprint, taken fresh here, equals the
/// one the scan recorded, so a drive that was re-partitioned or reformatted since is refused.
///
/// Discovery reads only partition tables, filesystem headers and the bounded lost-partition probes
/// (`VolumeDiscovery`); it never sweeps file contents.
public enum ExtentFingerprint {
    public static func of(_ reader: any BlockReader) async throws -> [ScanCheckpoint.Extent] {
        try await VolumeDiscovery(reader: reader).discover().extents
            .map { ScanCheckpoint.Extent(offset: $0.offset, length: $0.length) }
    }
}
