import Foundation

public struct ScanSession: Sendable, Identifiable {
    public let id = UUID()
    private let reader: any BlockReader
    private let now: @Sendable () -> Duration
    private let progressInterval: Duration
    public init(reader: any BlockReader) {
        self.reader = reader
        let start = ContinuousClock.now
        self.now = { start.duration(to: .now) }
        self.progressInterval = .milliseconds(500)
    }
    init(reader: any BlockReader, progressInterval: Duration, now: @escaping @Sendable () -> Duration) {
        self.reader = reader; self.progressInterval = progressInterval; self.now = now
    }

    /// The consumer owns a task and passes its continuation to `run`; cancellation therefore
    /// reaches every parser read directly, without an unstructured producer outliving cleanup.
    public func run(events: AsyncStream<ScanEvent>.Continuation) async {
        let emit: @Sendable (ScanEvent) async throws -> Void = { try await events.send($0) }
        do {
            try Task.checkCancellation()
            let extents = try await VolumeDiscovery(reader: reader).discover()
            var total: Int64 = 0
            for extent in extents { total = try checkedAdd(total, extent.length) }
            let measured = MeasuredReader(base: reader, extents: extents, total: total, emit: emit, interval: progressInterval, now: now)
            try await emit(.progress(bytesScanned: 0, totalBytes: total))
            for extent in extents {
                try await scanVolume(extent, reader: measured, emit: { file in
                    try await emit(.found(file))
                })
            }
            // Finish a bounded, read-only pass over supported volumes. Progress measures unique
            // source bytes actually read, including metadata; unsupported partitions are skipped.
            for extent in extents {
                var offset: Int64 = 0
                while offset < extent.length {
                    try Task.checkCancellation()
                    let count = Int(min(1024 * 1024, extent.length - offset))
                    _ = try await measured.read(at: checkedAdd(extent.offset, offset), count: count)
                    offset += Int64(count)
                }
            }
            try Task.checkCancellation()
            try await emit(.completed)
        } catch is CancellationError {
            // Cancellation has no completed event; the app retains previous discoveries.
        } catch {
            if !Task.isCancelled { try? await emit(.error((error as? ScanError) ?? .io(error.localizedDescription))) }
        }
        events.finish()
    }
}

/// Union of successfully read byte ranges, never elapsed-time-based or double-counted work.
actor MeasuredReader: BlockReader {
    let base: any BlockReader
    nonisolated let sizeBytes: Int64
    let extents: [VolumeExtent]
    let total: Int64
    let emit: @Sendable (ScanEvent) async throws -> Void
    let interval: Duration
    let now: @Sendable () -> Duration
    var ranges: [Range<Int64>] = []
    var lastEmission: Duration
    var measured: Int64 = 0
    init(base: any BlockReader, extents: [VolumeExtent], total: Int64,
         emit: @escaping @Sendable (ScanEvent) async throws -> Void,
         interval: Duration, now: @escaping @Sendable () -> Duration) {
        self.base = base; self.sizeBytes = base.sizeBytes; self.extents = extents
        self.total = total; self.emit = emit; self.interval = interval; self.now = now; self.lastEmission = now()
    }
    func read(at offset: Int64, count: Int) async throws -> Data {
        try Task.checkCancellation()
        let end = try checkedAdd(offset, Int64(count))
        guard extents.contains(where: { offset >= $0.offset && end <= $0.offset + $0.length }) else {
            throw ScanError.malformed("Read outside supported volume.")
        }
        let data = try await base.read(at: offset, count: count)
        guard data.count == count else { throw ScanError.malformed("Truncated device.") }
        cover(offset..<end)
        let now = now()
        if now - lastEmission >= interval || measured == total {
            try await emit(.progress(bytesScanned: measured, totalBytes: total))
            lastEmission = now
        }
        return data
    }

    /// `ranges` stays sorted, disjoint and non-touching. Binary search finds the first range that
    /// overlaps or touches `added`; only the neighbors actually merged are visited.
    func cover(_ added: Range<Int64>) {
        var lower = added.lowerBound, upper = added.upperBound
        var low = 0, high = ranges.count
        while low < high {
            let middle = (low + high) / 2
            if ranges[middle].upperBound < lower { low = middle + 1 } else { high = middle }
        }
        var last = low
        while last < ranges.count, ranges[last].lowerBound <= upper {
            measured -= ranges[last].upperBound - ranges[last].lowerBound
            lower = min(lower, ranges[last].lowerBound); upper = max(upper, ranges[last].upperBound)
            last += 1
        }
        measured += upper - lower
        ranges.replaceSubrange(low..<last, with: CollectionOfOne(lower..<upper))
    }
}

public extension AsyncStream<ScanEvent>.Continuation {
    /// Use bufferingOldest at the consumer. Retry a rejected new element without dropping it.
    func send(_ event: ScanEvent) async throws {
        while true {
            try Task.checkCancellation()
            switch yield(event) {
            case .enqueued: return
            case .terminated: throw CancellationError()
            case .dropped:
                try await Task.sleep(for: .milliseconds(1))
            @unknown default: throw CancellationError()
            }
        }
    }
}
