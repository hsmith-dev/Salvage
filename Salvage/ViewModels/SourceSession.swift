import Foundation
import SalvageCore

/// Read-only access to the scanned device, kept open after a scan so results can be previewed and
/// recovered. Closing releases the raw-device session; it is idempotent.
final class SourceSession: @unchecked Sendable {
    let device: BlockDevice
    let reader: any BlockReader
    private let closer: @Sendable () async -> Void
    private let lock = NSLock()
    private var closed = false

    init(device: BlockDevice, reader: any BlockReader, close: @escaping @Sendable () async -> Void) {
        self.device = device; self.reader = reader; self.closer = close
    }

    var content: FileContentReader { FileContentReader(reader: reader) }

    func close() async {
        let first: Bool = lock.withLock { defer { closed = true }; return !closed }
        if first { await closer() }
    }
}
