import CryptoKit
import Foundation
import SalvageCore

/// spec-tech-image-drive: one unreadable stretch of the source, filled with zeros in the image.
public struct ImagingBadRange: Codable, Sendable, Equatable {
    public let offset: Int64
    public let length: Int64
    public init(offset: Int64, length: Int64) { self.offset = offset; self.length = length }
    public var end: Int64 { offset + length }
}

/// Where a copy stands: bytes written to the image so far (always a prefix of the source) and the
/// unreadable bytes among them.
public struct ImagingProgress: Sendable, Equatable {
    public var bytesDone: Int64
    public var totalBytes: Int64
    public var unreadableBytes: Int64
    public var badRangeCount: Int
    public init(bytesDone: Int64 = 0, totalBytes: Int64, unreadableBytes: Int64 = 0, badRangeCount: Int = 0) {
        self.bytesDone = bytesDone; self.totalBytes = totalBytes
        self.unreadableBytes = unreadableBytes; self.badRangeCount = badRangeCount
    }
}

public enum ImagingOutcome: Sendable, Equatable {
    /// Every byte of the source is in the image (unreadable blocks as zeros).
    case completed
    /// The user canceled; the image holds the first `bytesDone` bytes.
    case cancelled
    /// Copying stopped on its own: the drive stopped responding, went away, or the image couldn't
    /// be written. The image holds the first `bytesDone` bytes.
    case stopped(String)
}

public struct ImagingResult: Sendable, Equatable {
    public let outcome: ImagingOutcome
    public let progress: ImagingProgress
    public let badRanges: [ImagingBadRange]
    /// Lowercase hex SHA-256 of the whole image, only for a completed copy with hashing on.
    public let sha256: String?
}

/// Where the image's bytes go. Writes arrive strictly in order, each starting where the last ended.
public protocol ImageSink: Sendable {
    func write(_ data: Data, at offset: Int64) throws
    /// Flushes everything written to stable storage.
    func synchronize() throws
}

/// The copy loop behind "Image This Drive…": reads the source in bounded chunks and writes each to
/// the sink in order. It never writes to the source; `BlockReader` has no write operation.
///
/// Unreadable sectors: a chunk that fails with `ScanError.io` is re-read in smaller pieces (each
/// of `retrySizes`, down to the source's block size); a piece is split further only when some of
/// its siblings read, so a solidly bad region is marked in a few reads instead of one per sector.
/// What stays unreadable is zero-filled and reported as merged `ImagingBadRange`s.
///
/// Timeouts: `pread(2)` on a raw device can't be interrupted, so each read runs in its own task
/// and the loop stops waiting after `readTimeout`, ending with `.stopped` (the drive "stopped
/// responding"). The stuck read is abandoned, not killed: it ends whenever the kernel's own
/// retries give up. Copying doesn't carry on past it, because further reads of the same session
/// would queue behind the stuck one.
public struct DriveImager: Sendable {
    public var chunkSize: Int
    public var retrySizes: [Int]
    public var readTimeout: Duration
    public var computesHash: Bool
    /// The least time between two progress reports (the last one is always sent).
    public var progressInterval: Duration

    public static let defaultChunkSize = 4 * 1024 * 1024

    public init(chunkSize: Int = DriveImager.defaultChunkSize, retrySizes: [Int] = [64 * 1024, 4096],
                readTimeout: Duration = .seconds(120), computesHash: Bool = true,
                progressInterval: Duration = .milliseconds(100)) {
        self.chunkSize = chunkSize; self.retrySizes = retrySizes; self.readTimeout = readTimeout
        self.computesHash = computesHash; self.progressInterval = progressInterval
    }

    public func run(reader: any BlockReader, sink: any ImageSink,
                    progress report: @Sendable (ImagingProgress) -> Void = { _ in }) async -> ImagingResult {
        let total = reader.sizeBytes
        let block = max(1, reader.logicalBlockSize)
        // Chunks are whole blocks, at most the 4 MiB a raw read allows.
        let chunk = max(block, min(chunkSize, 4 * 1024 * 1024) / block * block)
        let sizes = ([chunk] + retrySizes.filter { $0 < chunk && $0 > block }.map { $0 / block * block } + [block])
            .reduce(into: [Int]()) { if $0.last != $1, $1 > 0 { $0.append($1) } }
        var state = ImagingProgress(totalBytes: total)
        var bad: [ImagingBadRange] = []
        var hasher = computesHash ? SHA256() : nil
        let clock = ContinuousClock()
        var lastReport = clock.now
        report(state)

        func finish(_ outcome: ImagingOutcome) -> ImagingResult {
            report(state)
            let digest = outcome == .completed ? hasher.map { $0.finalize().map { String(format: "%02x", $0) }.joined() } : nil
            return ImagingResult(outcome: outcome, progress: state, badRanges: bad, sha256: digest)
        }

        while state.bytesDone < total {
            if Task.isCancelled { return finish(.cancelled) }
            let offset = state.bytesDone
            let count = Int(min(Int64(chunk), total - offset))
            var pieces: [Piece] = []
            switch await readRecovering(reader, offset: offset, count: count, sizes: sizes, level: 0, into: &pieces) {
            case .ok: break
            case .cancelled: return finish(.cancelled)
            case .fatal(let reason): return finish(.stopped(reason))
            }
            var data = Data(capacity: count)
            for piece in pieces {
                switch piece {
                case .bytes(let bytes): data.append(bytes)
                case .unreadable(let start, let length):
                    data.append(Data(count: length))
                    if let last = bad.last, last.end == start {
                        bad[bad.count - 1] = ImagingBadRange(offset: last.offset, length: last.length + Int64(length))
                    } else {
                        bad.append(ImagingBadRange(offset: start, length: Int64(length)))
                    }
                    state.unreadableBytes += Int64(length)
                }
            }
            do { try sink.write(data, at: offset) } catch {
                return finish(.stopped("Couldn't write the image: \(Self.describe(error))"))
            }
            hasher?.update(data: data)
            state.bytesDone += Int64(count)
            state.badRangeCount = bad.count
            if clock.now - lastReport >= progressInterval || state.bytesDone == total {
                lastReport = clock.now
                report(state)
            }
        }
        do { try sink.synchronize() } catch {
            return finish(.stopped("Couldn't finish writing the image: \(Self.describe(error))"))
        }
        return finish(.completed)
    }

    private enum Piece { case bytes(Data), unreadable(Int64, Int) }
    private enum ReadStatus { case ok, cancelled, fatal(String) }
    private enum Attempt { case data(Data), unreadable, cancelled, fatal(String) }

    /// Reads `[offset, offset + count)` as one read and, if that is unreadable, in smaller pieces.
    /// Appends what was read (or found unreadable) to `pieces`, in order.
    private func readRecovering(_ reader: any BlockReader, offset: Int64, count: Int, sizes: [Int], level: Int,
                                into pieces: inout [Piece]) async -> ReadStatus {
        switch await attempt(reader, offset: offset, count: count) {
        case .data(let data): pieces.append(.bytes(data)); return .ok
        case .cancelled: return .cancelled
        case .fatal(let reason): return .fatal(reason)
        case .unreadable: return await splitFailed(reader, offset: offset, count: count, sizes: sizes, level: level, into: &pieces)
        }
    }

    /// A range whose single read already failed: read it as pieces of the next size down. When no
    /// piece reads, the whole range is marked unreadable without splitting further; otherwise
    /// each failed piece is split the same way, down to one block.
    private func splitFailed(_ reader: any BlockReader, offset: Int64, count: Int, sizes: [Int], level: Int,
                             into pieces: inout [Piece]) async -> ReadStatus {
        guard let size = sizes.dropFirst(level + 1).first(where: { $0 < count }) else {
            pieces.append(.unreadable(offset, count)); return .ok
        }
        let nextLevel = sizes.firstIndex(of: size) ?? sizes.count - 1
        var results: [(offset: Int64, count: Int, data: Data?)] = []
        var position = offset
        let end = offset + Int64(count)
        while position < end {
            let length = Int(min(Int64(size), end - position))
            switch await attempt(reader, offset: position, count: length) {
            case .data(let data): results.append((position, length, data))
            case .unreadable: results.append((position, length, nil))
            case .cancelled: return .cancelled
            case .fatal(let reason): return .fatal(reason)
            }
            position += Int64(length)
        }
        if results.allSatisfy({ $0.data == nil }) { pieces.append(.unreadable(offset, count)); return .ok }
        for result in results {
            if let data = result.data { pieces.append(.bytes(data)); continue }
            let status = await splitFailed(reader, offset: result.offset, count: result.count, sizes: sizes,
                                           level: nextLevel, into: &pieces)
            guard case .ok = status else { return status }
        }
        return .ok
    }

    /// One bounded read. Only `ScanError.io` counts as unreadable; a removed drive, a permission
    /// error or anything else ends the copy.
    private func attempt(_ reader: any BlockReader, offset: Int64, count: Int) async -> Attempt {
        if Task.isCancelled { return .cancelled }
        do {
            let data = try await TimedRead.read(reader, offset: offset, count: count, timeout: readTimeout)
            guard data.count == count else { return .unreadable }
            return .data(data)
        } catch is CancellationError {
            return .cancelled
        } catch is TimedRead.Timeout {
            return .fatal("The drive stopped responding (one read took longer than \(Self.seconds(readTimeout))). Disconnect it and connect it again before trying more.")
        } catch let error as ScanError {
            if case .io = error { return Task.isCancelled ? .cancelled : .unreadable }
            return .fatal(error.description)
        } catch {
            return .fatal(Self.describe(error))
        }
    }

    static func describe(_ error: any Error) -> String {
        if let error = error as? ImageOutputError { return error.description }
        if let error = error as? ScanError { return error.description }
        return error.localizedDescription
    }

    private static func seconds(_ duration: Duration) -> String {
        let value = duration.components.seconds
        return value >= 60 ? "\(value / 60) min" : "\(max(1, value)) s"
    }
}

/// Races one read against a timer. The read runs in its own task so a read stuck in the kernel
/// can be abandoned; the caller resumes as soon as either side (or cancellation) finishes.
enum TimedRead {
    struct Timeout: Error {}

    private final class Race: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Data, any Error>?
        private var outcome: Result<Data, any Error>?
        private var tasks: [Task<Void, Never>] = []

        func install(_ continuation: CheckedContinuation<Data, any Error>) {
            let ready: Result<Data, any Error>? = lock.withLock {
                if let outcome { return outcome }
                self.continuation = continuation
                return nil
            }
            if let ready { continuation.resume(with: ready) }
        }

        func add(_ task: Task<Void, Never>) {
            let finished = lock.withLock { () -> Bool in
                if outcome != nil { return true }
                tasks.append(task); return false
            }
            if finished { task.cancel() }
        }

        func finish(_ result: Result<Data, any Error>) {
            let (waiting, pending): (CheckedContinuation<Data, any Error>?, [Task<Void, Never>]) = lock.withLock {
                guard outcome == nil else { return (nil, []) }
                outcome = result
                defer { continuation = nil; tasks = [] }
                return (continuation, tasks)
            }
            for task in pending { task.cancel() }
            waiting?.resume(with: result)
        }
    }

    static func read(_ reader: any BlockReader, offset: Int64, count: Int, timeout: Duration) async throws -> Data {
        let race = Race()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.install(continuation)
                race.add(Task.detached {
                    do { race.finish(.success(try await reader.read(at: offset, count: count))) }
                    catch { race.finish(.failure(error)) }
                })
                race.add(Task.detached {
                    do { try await Task.sleep(for: timeout) } catch { return }
                    race.finish(.failure(Timeout()))
                })
            }
        } onCancel: {
            race.finish(.failure(CancellationError()))
        }
    }
}
