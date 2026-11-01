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
    ///
    /// `pauseGate` suspends the scan between units of work without cancelling it (AD-11).
    /// `checkpoints` receives a resume point after each sweep unit; use `bufferingNewest(1)`.
    /// `resumingFrom` re-runs metadata traversal (rebuilding discoveries) but skips sweep bytes the
    /// checkpoint already covered, counting them as scanned. A checkpoint that does not fit this
    /// device's volumes is ignored and the scan starts from zero.
    /// `credentials` (by encrypted APFS volume UUID) unlock FileVault volumes; each records its outcome.
    public func run(events: AsyncStream<ScanEvent>.Continuation, pauseGate: ScanPauseGate? = nil,
                    checkpoints: AsyncStream<ScanCheckpoint>.Continuation? = nil,
                    resumingFrom checkpoint: ScanCheckpoint? = nil, device: BlockDevice? = nil,
                    credentials: [String: VolumeCredential] = [:]) async {
        let emit: @Sendable (ScanEvent) async throws -> Void = { try await events.send($0) }
        // Byte ranges owned by files found through metadata; the carver skips them.
        let claimed = ClaimedRuns()
        let carver: any Carver = SignatureCarver(emit: { try await emit(.found($0)) })
        do {
            try Task.checkCancellation()
            let discovery = try await VolumeDiscovery(reader: reader).discover()
            let extents = discovery.extents
            var total: Int64 = 0
            for extent in extents { total = try checkedAdd(total, extent.length) }
            let fingerprint = extents.map { ScanCheckpoint.Extent(offset: $0.offset, length: $0.length) }
            let measured = MeasuredReader(base: reader, extents: extents, total: total, emit: emit,
                                          interval: progressInterval, now: now, gate: pauseGate)
            let start = checkpoint.flatMap { Self.sweepStart($0, extents: extents, total: total, deviceSize: reader.sizeBytes) }
            if let start {
                for (index, extent) in extents.enumerated() where index <= start.volume {
                    let covered = index < start.volume ? extent.length : start.offset
                    if covered > 0 { await measured.cover(extent.offset..<(extent.offset + covered)) }
                }
            }
            try await emit(.progress(bytesScanned: await measured.measured, totalBytes: total))
            // Per lost extent: whether its own parser finished, and whether the device failed to read
            // inside it (then nothing more is read there).
            var parserFailed = Set<Int>(), unreadable = Set<Int>()
            for (index, extent) in extents.enumerated() {
                do {
                    try await scanVolume(extent, reader: measured, device: device, credentials: credentials, emit: { event in
                        if case .found(let file) = event, case .runs(let runs) = file.content { await claimed.add(runs) }
                        try await emit(event)
                    })
                } catch let error as ScanError where extent.isLost && error.isContainedInLostExtent {
                    // A lost partition is detected, not confirmed: damaged or unsupported metadata, or an
                    // unreadable spot, inside it stops only its own parser. Its files found so far stay and
                    // every other volume is unaffected. Mapped volumes keep failing closed.
                    parserFailed.insert(index)
                    if case .io = error { unreadable.insert(index) }
                }
                // Lost partitions (FR-9) are announced once their parser has finished, so the name can
                // say whether it got through: " (damaged)" when it stopped part-way.
                if extent.isLost {
                    let name = extent.formatName ?? extent.format.displayName
                    try await emit(.lostPartitionFound(LostPartitionCandidate(
                        offset: extent.offset, sizeBytes: extent.length,
                        formatName: parserFailed.contains(index) ? name + Self.damagedSuffix : name)))
                }
            }
            // Finish a bounded, read-only pass over supported volumes. Progress measures unique
            // source bytes actually read, including metadata; unsupported partitions are skipped.
            // The carver sees every swept chunk (a resumed scan carves only the remaining bytes).
            try await carver.begin(claimed: await claimed.runs, deviceSizeBytes: reader.sizeBytes)
            for (index, extent) in extents.enumerated() {
                guard index >= (start?.volume ?? 0) else { continue }
                // Every lost extent is swept for the carver, including one whose parser failed or
                // stopped on damaged metadata; only one the device couldn't read is left alone.
                if unreadable.contains(index) { continue }
                try await carver.beginExtent(offset: extent.offset, length: extent.length)
                var offset: Int64 = index == start?.volume ? start?.offset ?? 0 : 0
                while offset < extent.length {
                    try Task.checkCancellation()
                    try await pauseGate?.wait()
                    let count = Int(min(1024 * 1024, extent.length - offset))
                    let deviceOffset = try checkedAdd(extent.offset, offset)
                    let chunk: Data
                    do { chunk = try await measured.read(at: deviceOffset, count: count) }
                    catch ScanError.io(let reason) {
                        // An unreadable spot in a lost partition ends that partition's sweep only.
                        guard extent.isLost else { throw ScanError.io(reason) }
                        break
                    }
                    try await carver.consume(chunk, at: deviceOffset)
                    offset += Int64(count)
                    checkpoints?.yield(ScanCheckpoint(deviceSizeBytes: reader.sizeBytes, totalBytes: total,
                                                      extents: fingerprint, sweepVolumeIndex: index, sweepOffset: offset,
                                                      bytesScanned: await measured.measured))
                }
            }
            try await carver.finish()
            try Task.checkCancellation()
            try await emit(.completed)
        } catch is CancellationError {
            // Cancellation has no completed event; the app retains previous discoveries.
        } catch {
            if !Task.isCancelled { try? await emit(.error((error as? ScanError) ?? .io(error.localizedDescription))) }
        }
        checkpoints?.finish()
        events.finish()
    }

    /// Appended to a lost partition's format name when its parser stopped part-way.
    static let damagedSuffix = " (damaged)"

    /// The sweep position a checkpoint resumes from, or nil when it does not fit this device's layout.
    /// The checkpoint's extent fingerprint must equal the freshly discovered layout exactly, so a
    /// re-partitioned device with the same size, total and volume count still scans from zero.
    static func sweepStart(_ checkpoint: ScanCheckpoint, extents: [VolumeExtent], total: Int64,
                           deviceSize: Int64) -> (volume: Int, offset: Int64)? {
        guard checkpoint.isWellFormed, checkpoint.deviceSizeBytes == deviceSize, checkpoint.totalBytes == total,
              checkpoint.extents == extents.map({ ScanCheckpoint.Extent(offset: $0.offset, length: $0.length) }),
              extents.indices.contains(checkpoint.sweepVolumeIndex),
              checkpoint.sweepOffset <= extents[checkpoint.sweepVolumeIndex].length else { return nil }
        return (checkpoint.sweepVolumeIndex, checkpoint.sweepOffset)
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
    let gate: ScanPauseGate?
    init(base: any BlockReader, extents: [VolumeExtent], total: Int64,
         emit: @escaping @Sendable (ScanEvent) async throws -> Void,
         interval: Duration, now: @escaping @Sendable () -> Duration, gate: ScanPauseGate? = nil) {
        self.base = base; self.sizeBytes = base.sizeBytes; self.extents = extents
        self.total = total; self.emit = emit; self.interval = interval; self.now = now; self.lastEmission = now()
        self.gate = gate
    }
    func read(at offset: Int64, count: Int) async throws -> Data {
        // Parsers read only through here, so no source read is issued while paused.
        try await gate?.wait()
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

extension ScanError {
    /// Failures that describe the metadata being read rather than the device or the session.
    var isMetadataFailure: Bool {
        switch self {
        case .malformed, .unsupportedFilesystem: true
        default: false
        }
    }
    /// Failures a lost extent's parser may hit without stopping the scan: its metadata, or an
    /// unreadable spot inside it. Device removal, permissions and cancellation still propagate.
    var isContainedInLostExtent: Bool {
        if case .io = self { return true }
        return isMetadataFailure
    }
}

/// Device-absolute byte ranges owned by files found through metadata.
actor ClaimedRuns {
    private(set) var runs: [DataRun] = []
    func add(_ new: [DataRun]) { runs.append(contentsOf: new.filter { $0.deviceOffset != nil }) }
}
