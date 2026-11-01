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
/// of `retrySizes`), and every failed piece is split again, depth first, down to single blocks,
/// so only the sectors that really fail become zeros (reported as merged `ImagingBadRange`s).
/// The cost stays bounded by the run of consecutive unreadable bytes since the last good read:
///
/// - past `coarseAfterUnreadable` (32 KiB by default) a failed piece is no longer split; only a
///   failed whole chunk is still split once, into the first retry size, so good data after a bad
///   area is found again within 64 KiB. Any good read ends the run.
/// - past `stopAfterUnreadable` (64 MiB) the copy stops instead of "completing" a drive that
///   returns nothing but errors: the device's presence is re-checked and the outcome is either
///   "removed" or "The drive stopped returning data…".
///
/// A 0-byte read ("Short raw-device read.") counts as unreadable only while the device is still
/// present (`stillPresent`); a read from a closed session always ends the copy.
///
/// Timeouts: `pread(2)` on a raw device can't be interrupted, so each read runs in its own task
/// and the loop stops waiting after `readTimeout`, ending with `.stopped` (the drive "stopped
/// responding"). The stuck read is abandoned, not killed: it ends whenever the kernel's own
/// retries give up. Copying doesn't carry on past it, because further reads of the same reader
/// would queue behind the stuck one; for the same reason the caller must not wait to close it.
public struct DriveImager: Sendable {
    public var chunkSize: Int
    public var retrySizes: [Int]
    public var readTimeout: Duration
    public var computesHash: Bool
    /// The least time between two progress reports (the last one is always sent).
    public var progressInterval: Duration
    /// Consecutive unreadable bytes after which failed pieces are no longer split down to sectors.
    public var coarseAfterUnreadable: Int64 = 32 * 1024
    /// Consecutive unreadable bytes after which the copy stops (checked between chunks).
    public var stopAfterUnreadable: Int64 = 64 * 1024 * 1024
    /// Whether the source device is still attached; nil means "assume it is".
    public var stillPresent: (@Sendable () async -> Bool)?

    public static let defaultChunkSize = 4 * 1024 * 1024
    /// `RawBlockReader`'s messages for a 0-byte read and for a read after `close()`.
    static let shortReadMessage = "Short raw-device read."
    static let closedSessionMessage = "The read session is closed."

    public init(chunkSize: Int = DriveImager.defaultChunkSize, retrySizes: [Int] = [64 * 1024, 4096],
                readTimeout: Duration = .seconds(120), computesHash: Bool = true,
                progressInterval: Duration = .milliseconds(100)) {
        self.chunkSize = chunkSize; self.retrySizes = retrySizes; self.readTimeout = readTimeout
        self.computesHash = computesHash; self.progressInterval = progressInterval
    }

    /// The live presence check for an attached whole disk: its BSD name still carries the media
    /// identity it had when it was opened (IORegistry metadata only).
    public static func presence(of device: BlockDevice) -> @Sendable () async -> Bool {
        let name = device.bsdName, expected = device.mediaIdentity
        return { expected != nil && liveMediaIdentity(ofBSDName: name) == expected }
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
        var walk = Walk()
        let clock = ContinuousClock()
        var lastReport = clock.now
        report(state)

        func finish(_ outcome: ImagingOutcome) -> ImagingResult {
            var outcome = outcome
            if outcome != .completed {
                // A partial image is flushed too; a cancel that can't be flushed says so.
                do { try sink.synchronize() } catch {
                    if outcome == .cancelled { outcome = .stopped("Couldn't finish writing the image: \(Self.describe(error))") }
                }
            }
            report(state)
            let digest = outcome == .completed ? hasher.map { $0.finalize().map { String(format: "%02x", $0) }.joined() } : nil
            return ImagingResult(outcome: outcome, progress: state, badRanges: bad, sha256: digest)
        }

        while state.bytesDone < total {
            if Task.isCancelled { return finish(.cancelled) }
            if walk.run >= stopAfterUnreadable {
                if let stillPresent, !(await stillPresent()) { return finish(.stopped(ScanError.deviceChanged.description)) }
                return finish(.stopped("The drive stopped returning data: the last \(Self.bytes(walk.run)) couldn't be read at all, so Salvage stopped. The image keeps everything up to that point."))
            }
            let offset = state.bytesDone
            let count = Int(min(Int64(chunk), total - offset))
            walk.pieces = []
            switch await read(reader, offset: offset, count: count, sizes: sizes, level: 0, walk: &walk) {
            case .ok: break
            case .cancelled: return finish(.cancelled)
            case .fatal(let reason): return finish(.stopped(reason))
            }
            var data = Data(capacity: count)
            for piece in walk.pieces {
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

    /// The current chunk's pieces in order, and the run of consecutive unreadable bytes (which
    /// carries over from chunk to chunk until something reads).
    private struct Walk {
        var pieces: [Piece] = []
        var run: Int64 = 0
    }

    /// Reads `[offset, offset + count)` as one read; if that is unreadable, splits it into pieces
    /// of the next smaller size and reads each the same way, depth first.
    private func read(_ reader: any BlockReader, offset: Int64, count: Int, sizes: [Int], level: Int,
                      walk: inout Walk) async -> ReadStatus {
        switch await attempt(reader, offset: offset, count: count) {
        case .data(let data):
            walk.pieces.append(.bytes(data)); walk.run = 0; return .ok
        case .cancelled: return .cancelled
        case .fatal(let reason): return .fatal(reason)
        case .unreadable: break
        }
        let coarse = walk.run >= coarseAfterUnreadable
        guard !(coarse && level > 0),
              let size = sizes.dropFirst(level + 1).first(where: { $0 < count }),
              let next = sizes.firstIndex(of: size) else {
            walk.pieces.append(.unreadable(offset, count)); walk.run += Int64(count); return .ok
        }
        var position = offset
        let end = offset + Int64(count)
        while position < end {
            let length = Int(min(Int64(size), end - position))
            // In a long unreadable run, a split chunk's pieces are read once each (level > 0
            // stops them splitting again), until one reads and normal splitting resumes.
            let status = await read(reader, offset: position, count: length, sizes: sizes, level: next, walk: &walk)
            guard case .ok = status else { return status }
            position += Int64(length)
        }
        return .ok
    }

    /// One bounded read. Only `ScanError.io` counts as unreadable; a removed drive, a permission
    /// error, a closed session or anything else ends the copy.
    private func attempt(_ reader: any BlockReader, offset: Int64, count: Int) async -> Attempt {
        if Task.isCancelled { return .cancelled }
        do {
            let data = try await TimedRead.read(reader, offset: offset, count: count, timeout: readTimeout)
            guard data.count == count else { return await shortRead() }
            return .data(data)
        } catch is CancellationError {
            return .cancelled
        } catch is TimedRead.Timeout {
            return .fatal("The drive stopped responding (one read took longer than \(Self.seconds(readTimeout))). Disconnect it and connect it again before trying more.")
        } catch let error as ScanError {
            guard case .io(let message) = error else { return .fatal(error.description) }
            if Task.isCancelled { return .cancelled }
            if message == Self.closedSessionMessage { return .fatal(error.description) }
            if message == Self.shortReadMessage { return await shortRead() }
            return .unreadable
        } catch {
            return .fatal(Self.describe(error))
        }
    }

    /// A read that returned fewer bytes than asked: a bad area only while the drive is still there.
    private func shortRead() async -> Attempt {
        if let stillPresent, !(await stillPresent()) { return .fatal(ScanError.deviceChanged.description) }
        return .unreadable
    }

    static func describe(_ error: any Error) -> String {
        if let error = error as? ImageOutputError { return error.description }
        if let error = error as? ScanError { return error.description }
        return error.localizedDescription
    }

    private static func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }

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
