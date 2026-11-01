import Foundation
import SalvageCore

/// Read-only access to the scanned device, kept open after a scan so results can be previewed and
/// recovered. Closing releases the raw-device session; it is idempotent.
///
/// `decryptors` (by volume UUID) are the keys of FileVault volumes unlocked for this scan (Story
/// 2.5); preview and recovery decrypt those volumes' files through them. They live only in memory,
/// with this session.
final class SourceSession: @unchecked Sendable {
    let device: BlockDevice
    let reader: any BlockReader
    let decryptors: [String: any ContentDecryptor]
    private let closer: @Sendable () async -> Void
    private let lock = NSLock()
    private var closed = false

    init(device: BlockDevice, reader: any BlockReader, decryptors: [String: any ContentDecryptor] = [:],
         close: @escaping @Sendable () async -> Void) {
        self.device = device; self.reader = reader; self.decryptors = decryptors; self.closer = close
    }

    var content: FileContentReader { FileContentReader(reader: reader, decryptors: decryptors) }

    func close() async {
        let first: Bool = lock.withLock { defer { closed = true }; return !closed }
        if first { await closer() }
    }
}
