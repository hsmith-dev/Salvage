import Foundation

/// A cold-start resume point (AD-11). It holds offsets and sizes only, never file names, paths
/// or contents. `sweepOffset` is relative to the start of volume `sweepVolumeIndex`; every byte of
/// earlier volumes and every byte of that volume before `sweepOffset` has already been read.
public struct ScanCheckpoint: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public let version: Int
    /// The source device size when the checkpoint was taken; a different size means a different device.
    public let deviceSizeBytes: Int64
    public let totalBytes: Int64
    public let sweepVolumeIndex: Int
    public let sweepOffset: Int64
    public let bytesScanned: Int64

    public init(version: Int = ScanCheckpoint.currentVersion, deviceSizeBytes: Int64, totalBytes: Int64,
                sweepVolumeIndex: Int, sweepOffset: Int64, bytesScanned: Int64) {
        self.version = version; self.deviceSizeBytes = deviceSizeBytes; self.totalBytes = totalBytes
        self.sweepVolumeIndex = sweepVolumeIndex; self.sweepOffset = sweepOffset; self.bytesScanned = bytesScanned
    }

    /// Structural sanity that does not depend on the device being scanned.
    public var isWellFormed: Bool {
        version == Self.currentVersion && deviceSizeBytes > 0 && totalBytes > 0
            && sweepVolumeIndex >= 0 && sweepOffset >= 0
            && bytesScanned >= 0 && bytesScanned <= totalBytes && totalBytes <= deviceSizeBytes
    }
}
