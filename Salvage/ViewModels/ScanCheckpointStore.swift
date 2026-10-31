import Foundation
import SalvageCore

/// Persists the latest cold-start checkpoint per device as JSON, keyed by `mediaIdentity`.
/// Records hold only offsets, sizes and identifiers, never file names, paths or contents.
/// A record that is unreadable, corrupt, from another format version, or bound to a different
/// device identity or size is deleted on load and never applied.
struct ScanCheckpointStore: Sendable {
    static let formatVersion = 1

    private struct Record: Codable {
        let formatVersion: Int
        let mediaIdentity: UInt64
        let deviceSizeBytes: Int64
        let checkpoint: ScanCheckpoint
    }

    let directory: URL

    init(directory: URL) { self.directory = directory }

    /// `~/Library/Application Support/<bundle id>/ScanCheckpoints`.
    static func applicationSupport() -> ScanCheckpointStore? {
        guard let base = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                      appropriateFor: nil, create: true) else { return nil }
        let app = Bundle.main.bundleIdentifier ?? "dev.hsmith.Salvage"
        return ScanCheckpointStore(directory: base.appending(path: app, directoryHint: .isDirectory)
            .appending(path: "ScanCheckpoints", directoryHint: .isDirectory))
    }

    func load(for device: BlockDevice) -> ScanCheckpoint? {
        guard let identity = device.mediaIdentity else { return nil }
        let url = fileURL(identity)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url),
              let record = try? JSONDecoder().decode(Record.self, from: data),
              record.formatVersion == Self.formatVersion,
              record.mediaIdentity == identity,
              record.deviceSizeBytes == device.sizeBytes,
              record.checkpoint.isWellFormed,
              record.checkpoint.deviceSizeBytes == device.sizeBytes else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return record.checkpoint
    }

    func save(_ checkpoint: ScanCheckpoint, for device: BlockDevice) {
        guard let identity = device.mediaIdentity else { return }
        let record = Record(formatVersion: Self.formatVersion, mediaIdentity: identity,
                            deviceSizeBytes: device.sizeBytes, checkpoint: checkpoint)
        guard let data = try? JSONEncoder().encode(record) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: fileURL(identity), options: .atomic)
    }

    func remove(for device: BlockDevice) {
        guard let identity = device.mediaIdentity else { return }
        try? FileManager.default.removeItem(at: fileURL(identity))
    }

    private func fileURL(_ identity: UInt64) -> URL {
        directory.appending(path: "checkpoint-\(identity).json", directoryHint: .notDirectory)
    }
}
