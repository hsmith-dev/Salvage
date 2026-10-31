import Darwin
import Foundation
import SalvageCore

/// Persists the latest cold-start checkpoint per device as JSON, keyed by `mediaIdentity`.
/// Records hold only offsets, sizes and identifiers, never file names, paths or contents.
///
/// IORegistry entry IDs are reused after a reboot, so each record is also bound to the boot session
/// it was written in. A record that is unreadable, corrupt, from another format version, bound to a
/// different device identity, size or boot session, or older than `maxAge` is deleted on load and
/// never applied.
struct ScanCheckpointStore: Sendable {
    /// Version 2 added `bootSessionUUID` and `savedAt`.
    static let formatVersion = 2
    static let maxAge: TimeInterval = 7 * 24 * 60 * 60

    private struct Record: Codable {
        let formatVersion: Int
        let mediaIdentity: UInt64
        let deviceSizeBytes: Int64
        let bootSessionUUID: String
        let savedAt: Date
        let checkpoint: ScanCheckpoint
    }

    let directory: URL
    private let bootSession: @Sendable () -> String?
    private let now: @Sendable () -> Date

    /// `bootSession` and `now` are injectable for tests; by default they read the kernel's boot
    /// session UUID and the wall clock.
    init(directory: URL, bootSession: @escaping @Sendable () -> String? = { ScanCheckpointStore.currentBootSession() },
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory; self.bootSession = bootSession; self.now = now
    }

    /// `~/Library/Application Support/<bundle id>/ScanCheckpoints`.
    static func applicationSupport() -> ScanCheckpointStore? {
        guard let base = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                      appropriateFor: nil, create: true) else { return nil }
        let app = Bundle.main.bundleIdentifier ?? "dev.hsmith.Salvage"
        return ScanCheckpointStore(directory: base.appending(path: app, directoryHint: .isDirectory)
            .appending(path: "ScanCheckpoints", directoryHint: .isDirectory))
    }

    /// The kernel's per-boot UUID (`kern.bootsessionuuid`), or nil if it cannot be read.
    static func currentBootSession() -> String? {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 else { return nil }
        let value = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return value.isEmpty ? nil : value
    }

    func load(for device: BlockDevice) -> ScanCheckpoint? {
        guard let identity = device.mediaIdentity else { return nil }
        let url = fileURL(identity)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let age = { (record: Record) in now().timeIntervalSince(record.savedAt) }
        guard let data = try? Data(contentsOf: url),
              let record = try? JSONDecoder().decode(Record.self, from: data),
              record.formatVersion == Self.formatVersion,
              record.mediaIdentity == identity,
              record.deviceSizeBytes == device.sizeBytes,
              let session = bootSession(), record.bootSessionUUID == session,
              age(record) <= Self.maxAge,
              record.checkpoint.isWellFormed,
              record.checkpoint.deviceSizeBytes == device.sizeBytes else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return record.checkpoint
    }

    /// Without a readable boot session a record could not be bound safely, so nothing is saved.
    func save(_ checkpoint: ScanCheckpoint, for device: BlockDevice) {
        guard let identity = device.mediaIdentity, let session = bootSession() else { return }
        let record = Record(formatVersion: Self.formatVersion, mediaIdentity: identity,
                            deviceSizeBytes: device.sizeBytes, bootSessionUUID: session, savedAt: now(),
                            checkpoint: checkpoint)
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
