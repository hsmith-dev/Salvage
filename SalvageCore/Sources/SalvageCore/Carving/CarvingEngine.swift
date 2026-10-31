import Foundation

/// A streaming consumer of the read-only sweep (AD-6). `ScanSession` feeds it every chunk it
/// reads, in device order, then calls `finish()`. Chunks are device-absolute and contiguous within
/// a volume extent; a new extent may start at any offset.
protocol Carver: Sendable {
    /// Byte ranges owned by files already found through metadata; carving skips them.
    func begin(claimed: [DataRun], deviceSizeBytes: Int64) async throws
    func consume(_ chunk: Data, at deviceOffset: Int64) async throws
    func finish() async throws
}

/// Signature-based carving over raw bytes (Story 3.1). Until implemented it consumes nothing.
actor SignatureCarver: Carver {
    static let isImplemented = false
    let emit: @Sendable (RecoveredFile) async throws -> Void

    init(emit: @escaping @Sendable (RecoveredFile) async throws -> Void) { self.emit = emit }

    func begin(claimed: [DataRun], deviceSizeBytes: Int64) async throws {}
    func consume(_ chunk: Data, at deviceOffset: Int64) async throws {}
    func finish() async throws {}
}
