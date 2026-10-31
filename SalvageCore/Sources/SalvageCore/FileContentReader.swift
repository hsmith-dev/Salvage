import Foundation

public enum FileContentError: Error, Sendable, Equatable {
    case unmapped
    case runsShorterThanFile
    case runOutsideDevice
}

/// Streams a discovered file's bytes from the source device in bounded chunks. Read-only: it
/// only ever calls `BlockReader.read`.
public struct FileContentReader: Sendable {
    public let reader: any BlockReader
    public let chunkSize: Int
    public init(reader: any BlockReader, chunkSize: Int = 1024 * 1024) {
        self.reader = reader; self.chunkSize = max(512, chunkSize)
    }

    /// Validates that the content mapping covers the whole file and stays on the device.
    public func validate(_ file: RecoveredFile) throws {
        switch file.content {
        case .unmapped: throw FileContentError.unmapped
        case .resident(let data):
            guard Int64(data.count) >= file.sizeBytes else { throw FileContentError.runsShorterThanFile }
        case .runs(let runs):
            var covered: Int64 = 0
            for run in runs {
                guard run.length >= 0 else { throw FileContentError.runOutsideDevice }
                if let offset = run.deviceOffset {
                    guard offset >= 0, offset <= reader.sizeBytes, run.length <= reader.sizeBytes - offset else {
                        throw FileContentError.runOutsideDevice
                    }
                }
                let (sum, overflow) = covered.addingReportingOverflow(run.length)
                guard !overflow else { throw FileContentError.runOutsideDevice }
                covered = sum
                if covered >= file.sizeBytes { return }
            }
            guard covered >= file.sizeBytes || file.sizeBytes == 0 else { throw FileContentError.runsShorterThanFile }
        }
    }

    /// Called once per chunk the iterator produces (tests observe backpressure with it).
    var chunkObserver: (@Sendable () -> Void)?

    /// Reads up to `limit` bytes from the start of the file (e.g. for previews).
    public func prefix(of file: RecoveredFile, limit: Int64) async throws -> Data {
        var result = Data()
        for try await chunk in chunks(of: file, limit: limit) { result.append(chunk) }
        return result
    }

    /// The file's bytes in order, at most `limit` bytes (default: the whole file).
    ///
    /// Pull-based: there is no producer task and no buffer. Each `next()` reads (or, for a sparse
    /// hole, zero-fills) exactly one chunk of at most `chunkSize` bytes, so memory stays bounded
    /// by one chunk however large the file or its holes are, and a consumer that stops early
    /// costs nothing further.
    public func chunks(of file: RecoveredFile, limit: Int64? = nil) -> FileContentChunks {
        FileContentChunks(content: self, file: file, total: max(0, min(file.sizeBytes, limit ?? file.sizeBytes)))
    }
}

/// A file's content as an `AsyncSequence` of `Data` chunks; see `FileContentReader.chunks(of:limit:)`.
/// Each iterator starts from the beginning of the file.
public struct FileContentChunks: AsyncSequence, Sendable {
    public typealias Element = Data

    let content: FileContentReader
    let file: RecoveredFile
    let total: Int64

    public func makeAsyncIterator() -> AsyncIterator { AsyncIterator(content: content, file: file, total: total) }

    public struct AsyncIterator: AsyncIteratorProtocol {
        private let content: FileContentReader
        private let file: RecoveredFile
        private var remaining: Int64
        private var validated = false
        private var finished = false
        private var runIndex = 0
        private var offsetInRun: Int64 = 0
        private var zeros = Data()

        init(content: FileContentReader, file: RecoveredFile, total: Int64) {
            self.content = content; self.file = file; self.remaining = total
        }

        public mutating func next() async throws -> Data? {
            guard !finished else { return nil }
            do {
                let chunk = try await produce()
                if chunk == nil { finished = true } else { content.chunkObserver?() }
                return chunk
            } catch {
                finished = true
                throw error
            }
        }

        private mutating func produce() async throws -> Data? {
            if !validated { try content.validate(file); validated = true }
            guard remaining > 0 else { return nil }
            try Task.checkCancellation()
            switch file.content {
            case .unmapped: throw FileContentError.unmapped
            case .resident(let data):
                defer { remaining = 0 }
                return data.prefix(Int(remaining))
            case .runs(let runs):
                // Skip exhausted (or empty) runs; validation guarantees coverage of `remaining`.
                while runIndex < runs.count, offsetInRun >= runs[runIndex].length { runIndex += 1; offsetInRun = 0 }
                guard runIndex < runs.count else { throw FileContentError.runsShorterThanFile }
                let run = runs[runIndex]
                let count = Int(Swift.min(Int64(content.chunkSize), run.length - offsetInRun, remaining))
                let data: Data
                if let offset = run.deviceOffset {
                    data = try await content.reader.read(at: offset + offsetInRun, count: count)
                    guard data.count == count else { throw ScanError.io("Short read.") }
                } else {
                    // One zero buffer, allocated once and sliced, serves every hole chunk.
                    if zeros.count < count { zeros = Data(count: content.chunkSize) }
                    data = zeros.prefix(count)
                }
                offsetInRun += Int64(count)
                remaining -= Int64(count)
                return data
            }
        }
    }
}
