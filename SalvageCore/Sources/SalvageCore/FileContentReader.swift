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

    /// Reads up to `limit` bytes from the start of the file (e.g. for previews).
    public func prefix(of file: RecoveredFile, limit: Int64) async throws -> Data {
        var result = Data()
        for try await chunk in chunks(of: file, limit: limit) { result.append(chunk) }
        return result
    }

    /// The file's bytes in order, at most `limit` bytes (default: the whole file).
    public func chunks(of file: RecoveredFile, limit: Int64? = nil) -> AsyncThrowingStream<Data, Error> {
        let total = min(file.sizeBytes, limit ?? file.sizeBytes)
        let reader = self.reader, chunkSize = self.chunkSize
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try validate(file)
                    var remaining = total
                    switch file.content {
                    case .unmapped: throw FileContentError.unmapped
                    case .resident(let data):
                        if remaining > 0 { continuation.yield(data.prefix(Int(remaining))) }
                    case .runs(let runs):
                        for run in runs where remaining > 0 {
                            var done: Int64 = 0
                            let length = min(run.length, remaining)
                            while done < length {
                                try Task.checkCancellation()
                                let count = Int(min(Int64(chunkSize), length - done))
                                if let offset = run.deviceOffset {
                                    let data = try await reader.read(at: offset + done, count: count)
                                    guard data.count == count else { throw ScanError.io("Short read.") }
                                    continuation.yield(data)
                                } else {
                                    continuation.yield(Data(count: count))
                                }
                                done += Int64(count)
                            }
                            remaining -= length
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
