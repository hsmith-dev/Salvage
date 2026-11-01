import Foundation
import SalvageCore

/// Read-only access to the scanned device, kept open after a scan so results can be previewed and
/// recovered. Closing releases the raw-device session; it is idempotent.
///
/// `decryptors` (by volume UUID) are the keys of FileVault volumes unlocked for this scan (Story
/// 2.5); preview and recovery decrypt those volumes' files through them. They live only in memory,
/// with this session, and `close()` drops them.
final class SourceSession: @unchecked Sendable {
    let device: BlockDevice
    let reader: any BlockReader
    private let closer: @Sendable () async -> Void
    private let lock = NSLock()
    private var closed = false
    private var keys: [String: any ContentDecryptor]

    init(device: BlockDevice, reader: any BlockReader, decryptors: [String: any ContentDecryptor] = [:],
         close: @escaping @Sendable () async -> Void) {
        self.device = device; self.reader = reader; self.keys = decryptors; self.closer = close
    }

    /// The unlocked volumes' decryptors; empty once closed.
    var decryptors: [String: any ContentDecryptor] { lock.withLock { keys } }

    /// True once `close()` has begun; the reader may fail any read from then on.
    var isClosed: Bool { lock.withLock { closed } }

    var content: FileContentReader { FileContentReader(reader: reader, decryptors: decryptors) }

    func close() async {
        let first: Bool = lock.withLock { defer { closed = true; keys = [:] }; return !closed }
        if first { await closer() }
    }
}
