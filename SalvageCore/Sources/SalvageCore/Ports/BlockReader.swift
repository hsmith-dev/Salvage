import Foundation

/// Exact, bounded reads. Adapters must throw on short reads and never expose source writes.
public protocol BlockReader: Sendable {
    var logicalBlockSize: Int { get }
    var sizeBytes: Int64 { get }
    func read(at offset: Int64, count: Int) async throws -> Data
}

public extension BlockReader { var logicalBlockSize: Int { 512 } }
