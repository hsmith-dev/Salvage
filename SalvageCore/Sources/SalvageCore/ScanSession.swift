import Foundation

public struct ScanSession: Sendable, Identifiable {
    public let id = UUID()
    private let reader: any BlockReader
    private let now: @Sendable () -> Duration
    private let progressInterval: Duration
    /// The carver's signatures and limits. Tests inject small ones to reach the `ScanNotice` producers.
    var signatureLibrary: SignatureLibrary = .bundled
    var carverLimits: SignatureCarver.Limits = .default
    /// How far the carve backfill reads past the point a resumed sweep began, so a file that
    /// starts before that point is not cut there. Carves that start at or after it were already
    /// found by the sweep and are dropped.
    var backfillOverrunBytes: Int64 = 256 * 1024 * 1024
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
    /// checkpoint already covered, counting them as scanned; after the sweep it carves those bytes
    /// in a carve-only pass that leaves progress unchanged. A checkpoint that does not fit this
    /// device's volumes is ignored and the scan starts from zero.
    /// `notices` receives what the scan could not do (`ScanNotice`), beside the closed `ScanEvent`
    /// stream (AD-11); a notice never duplicates an `.error`. It is finished when the scan ends.
    /// `credentials` (by encrypted APFS volume UUID) unlock FileVault volumes; each records its outcome.
    public func run(events: AsyncStream<ScanEvent>.Continuation, pauseGate: ScanPauseGate? = nil,
                    checkpoints: AsyncStream<ScanCheckpoint>.Continuation? = nil,
                    notices: AsyncStream<ScanNotice>.Continuation? = nil,
                    resumingFrom checkpoint: ScanCheckpoint? = nil, device: BlockDevice? = nil,
                    credentials: [String: VolumeCredential] = [:]) async {
        let emit: @Sendable (ScanEvent) async throws -> Void = { try await events.send($0) }
        // Byte ranges owned by files found through metadata; the carver skips them.
        let claimed = ClaimedRuns()
        let dropped = CarveDropRange()
        let carver: any Carver = SignatureCarver(emit: { file in
            if dropped.drops(file) { return }
            try await emit(.found(file))
        }, library: signatureLibrary, limits: carverLimits)
        // A resumed scan owes a carve-only pass over the bytes it skipped until that pass ends.
        var backfillOutstanding = false
        do {
            try Task.checkCancellation()
            let discovery = try await VolumeDiscovery(reader: reader).discover()
            let extents = discovery.extents
            for notice in Self.discoveryNotices(discovery, deviceBytes: reader.sizeBytes) { notices?.yield(notice) }
            var total: Int64 = 0
            for extent in extents { total = try checkedAdd(total, extent.length) }
            let fingerprint = extents.map { ScanCheckpoint.Extent(offset: $0.offset, length: $0.length) }
            let measured = MeasuredReader(base: reader, extents: extents, total: total, emit: emit,
                                          interval: progressInterval, now: now, gate: pauseGate)
            let start = checkpoint.flatMap { Self.sweepStart($0, extents: extents, total: total, deviceSize: reader.sizeBytes) }
            if let start {
                for (index, extent) in extents.enumerated() where index <= start.volume {
                    let covered = index < start.volume ? extent.length : start.offset
                    if covered > 0 { measured.cover(extent.offset..<(extent.offset + covered)) }
                }
            }
            backfillOutstanding = start.map { $0.volume > 0 || $0.offset > 0 } ?? false
            try await emit(.progress(bytesScanned: measured.measured, totalBytes: total))
            // Per lost extent: whether its own parser finished, and whether the device failed to read
            // inside it (then nothing more is read there).
            var parserFailed = Set<Int>(), unreadable = Set<Int>()
            for (index, extent) in extents.enumerated() {
                do {
                    try await scanVolume(extent, reader: measured, device: device, credentials: credentials, notice: { notices?.yield($0) }, emit: { event in
                        // Encrypted files' blocks are claimed too, so carving never reads ciphertext as content.
                        if case .found(let file) = event {
                            switch file.content {
                            case .runs(let runs), .encryptedRuns(let runs, _): claimed.add(runs)
                            case .unmapped, .resident: break
                            }
                        }
                        try await emit(event)
                    })
                } catch let error as ScanError where extent.isLost && error.isContainedInLostExtent {
                    // A lost partition is detected, not confirmed: damaged or unsupported metadata, or an
                    // unreadable spot, inside it stops only its own parser. Its files found so far stay and
                    // every other volume is unaffected. Mapped volumes keep failing closed.
                    parserFailed.insert(index)
                    if case .io = error { unreadable.insert(index) }
                } catch let error as ScanError where !extent.isLost && error.isMetadataFailure && extents.count > 1 {
                    // A mapped volume whose metadata can't be read is skipped, not fatal, when the device
                    // has other volumes: its files found so far stay, the other volumes are still parsed,
                    // and its bytes are still swept for the carver. I/O errors and cancellation still end
                    // the scan, and a device whose only volume fails still reports the error.
                    notices?.yield(.volumeSkipped(formatName: extent.formatName ?? extent.format.displayName,
                                                  offset: extent.offset, reason: error.description))
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
            // The carver sees every swept chunk; a resumed scan then carves the skipped bytes too.
            if !signatureLibrary.skipped.isEmpty { notices?.yield(.signaturesSkipped(signatureLibrary.skipped.map(\.file))) }
            try await carver.begin(claimed: claimed.runs, deviceSizeBytes: reader.sizeBytes)
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
                                                      bytesScanned: measured.measured))
                }
            }
            if let start, backfillOutstanding {
                try await carveBackfill(before: start, extents: extents, unreadable: unreadable, carver: carver,
                                        dropped: dropped, pauseGate: pauseGate, checkpoint: { carved in
                    checkpoints?.yield(ScanCheckpoint(deviceSizeBytes: reader.sizeBytes, totalBytes: total, extents: fingerprint,
                                                      sweepVolumeIndex: extents.count - 1, sweepOffset: extents[extents.count - 1].length,
                                                      bytesScanned: measured.measured, carveBackfillOffset: carved))
                })
            }
            try await carver.finish()
            backfillOutstanding = false
            if await carver.hitFileLimit { notices?.yield(.carvingLimitReached(count: carverLimits.maxCarvedFiles)) }
            try Task.checkCancellation()
            try await emit(.completed)
        } catch is CancellationError {
            // Cancellation has no completed event; the app retains previous discoveries. Stopping a
            // resumed scan before its backfill ended leaves carving incomplete, so say so.
            if backfillOutstanding { notices?.yield(.resumedCarvingPartial) }
        } catch {
            if !Task.isCancelled { try? await emit(.error((error as? ScanError) ?? .io(error.localizedDescription))) }
        }
        checkpoints?.finish()
        notices?.finish()
        events.finish()
    }

    /// The carve backfill of a resumed scan: a carve-only pass over every byte before the point the
    /// sweep resumed from. Those bytes were counted as scanned when the checkpoint was applied, so
    /// they are read from the source directly and progress does not move; `.completed` follows the
    /// pass, so the scan shows as running until it ends. Pause and cancellation are honoured per chunk.
    ///
    /// Every extent is a hard cut for the carver, as in the sweep. On the extent the sweep resumed
    /// inside, carving reads on for up to `backfillOverrunBytes` past the resume point, so a file
    /// that straddles it is carved whole; files that start at or after it came from the sweep and
    /// are dropped by `dropped`.
    ///
    /// `checkpoint` receives how far the pass has carved, as a position in the concatenated extents.
    /// Carved files don't survive a cold start (the app clears its results), so a scan resumed from
    /// such a checkpoint skips the finished sweep and carves every byte again.
    private func carveBackfill(before start: (volume: Int, offset: Int64), extents: [VolumeExtent],
                               unreadable: Set<Int>, carver: any Carver, dropped: CarveDropRange,
                               pauseGate: ScanPauseGate?,
                               checkpoint: (Int64) async -> Void) async throws {
        var base: Int64 = 0
        for (index, extent) in extents.enumerated() where index <= start.volume {
            let extentBase = base
            base = try checkedAdd(base, extent.length)
            let region = index < start.volume ? extent.length : start.offset
            // A lost extent the device couldn't read is left alone, as in the sweep.
            guard region > 0, !unreadable.contains(index) else { continue }
            let overrunEnd = try checkedAdd(region, max(0, backfillOverrunBytes))
            let readEnd = index < start.volume ? extent.length : min(extent.length, overrunEnd)
            if readEnd > region {
                let from = try checkedAdd(extent.offset, region), to = try checkedAdd(extent.offset, extent.length)
                dropped.set(from..<to)
            }
            try await carver.beginExtent(offset: extent.offset, length: extent.length)
            var offset: Int64 = 0
            while offset < readEnd {
                try Task.checkCancellation()
                try await pauseGate?.wait()
                let count = Int(min(1024 * 1024, readEnd - offset))
                let deviceOffset = try checkedAdd(extent.offset, offset)
                let chunk: Data
                do { chunk = try await reader.read(at: deviceOffset, count: count) }
                catch ScanError.io(let reason) {
                    guard extent.isLost else { throw ScanError.io(reason) }
                    break
                }
                guard chunk.count == count else { throw ScanError.malformed("Truncated device.") }
                try await carver.consume(chunk, at: deviceOffset)
                offset += Int64(count)
                await checkpoint(extentBase + min(offset, region))
            }
        }
    }

    /// What discovery says it could not do: an ignored partition table, a lost-partition search
    /// that stopped early, unreadable probes it skipped.
    static func discoveryNotices(_ discovery: VolumeDiscovery.Result, deviceBytes: Int64) -> [ScanNotice] {
        var result: [ScanNotice] = []
        // `VolumeDiscovery` reports the ignored table as one warning sentence around its reason.
        let prefix = "The partition table is damaged and was ignored ("
        let suffix = ") The whole device was searched for filesystem signatures instead."
        for warning in discovery.warnings where warning.hasPrefix(prefix) {
            var reason = String(warning.dropFirst(prefix.count))
            if reason.hasSuffix(suffix) { reason = String(reason.dropLast(suffix.count)) }
            result.append(.partitionTableIgnored(reason: reason))
        }
        if discovery.probesTruncated, let searched = discovery.searchedBytes {
            result.append(.lostPartitionSearchLimited(searchedBytes: searched, deviceBytes: deviceBytes))
        }
        if discovery.failedProbes > 0 { result.append(.unreadableAreasSkipped(count: discovery.failedProbes)) }
        return result
    }

    /// Appended to a lost partition's format name when its parser stopped part-way.
    static let damagedSuffix = " (damaged)"

    /// The sweep position a checkpoint resumes from, or nil when it does not fit this device's layout.
    /// Everything before it is carved again after the sweep (`carveBackfill`).
    /// The checkpoint's extent fingerprint must equal the freshly discovered layout exactly, so a
    /// re-partitioned device with the same size, total and volume count still scans from zero.
    static func sweepStart(_ checkpoint: ScanCheckpoint, extents: [VolumeExtent], total: Int64,
                           deviceSize: Int64) -> (volume: Int, offset: Int64)? {
        guard checkpoint.isWellFormed, checkpoint.deviceSizeBytes == deviceSize, checkpoint.totalBytes == total,
              checkpoint.extents == extents.map({ ScanCheckpoint.Extent(offset: $0.offset, length: $0.length) }),
              extents.indices.contains(checkpoint.sweepVolumeIndex),
              checkpoint.sweepOffset <= extents[checkpoint.sweepVolumeIndex].length else { return nil }
        // A backfill checkpoint is only ever taken once the sweep has finished.
        if checkpoint.carveBackfillOffset != nil {
            guard checkpoint.sweepVolumeIndex == extents.count - 1,
                  checkpoint.sweepOffset == extents[checkpoint.sweepVolumeIndex].length else { return nil }
        }
        return (checkpoint.sweepVolumeIndex, checkpoint.sweepOffset)
    }
}

/// Union of successfully read byte ranges, never elapsed-time-based or double-counted work.
///
/// Every parser read goes through here, so it is a lock-protected class rather than an actor:
/// a read costs no executor hop of its own. The coverage update and the decision to report
/// progress happen together under the lock; the source read and the progress event happen
/// outside it, as they did while the actor was suspended on them.
final class MeasuredReader: BlockReader, @unchecked Sendable {
    let base: any BlockReader
    let sizeBytes: Int64
    let extents: [VolumeExtent]
    let total: Int64
    let emit: @Sendable (ScanEvent) async throws -> Void
    let interval: Duration
    let now: @Sendable () -> Duration
    let gate: ScanPauseGate?
    private let lock = NSLock()
    /// Guarded by `lock`.
    private var state: State
    private struct State {
        var ranges: [Range<Int64>] = []
        var lastEmission: Duration
        var measured: Int64 = 0
    }
    init(base: any BlockReader, extents: [VolumeExtent], total: Int64,
         emit: @escaping @Sendable (ScanEvent) async throws -> Void,
         interval: Duration, now: @escaping @Sendable () -> Duration, gate: ScanPauseGate? = nil) {
        self.base = base; self.sizeBytes = base.sizeBytes; self.extents = extents
        self.total = total; self.emit = emit; self.interval = interval; self.now = now
        self.state = State(lastEmission: now())
        self.gate = gate
    }
    var ranges: [Range<Int64>] { lock.withLock { state.ranges } }
    var measured: Int64 { lock.withLock { state.measured } }

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
        let report: Int64? = lock.withLock {
            Self.cover(offset..<end, in: &state)
            let now = now()
            guard now - state.lastEmission >= interval || state.measured == total else { return nil }
            state.lastEmission = now
            return state.measured
        }
        if let report { try await emit(.progress(bytesScanned: report, totalBytes: total)) }
        return data
    }

    func cover(_ added: Range<Int64>) {
        lock.withLock { Self.cover(added, in: &state) }
    }

    /// `ranges` stays sorted, disjoint and non-touching. Binary search finds the first range that
    /// overlaps or touches `added`; only the neighbors actually merged are visited.
    private static func cover(_ added: Range<Int64>, in state: inout State) {
        var lower = added.lowerBound, upper = added.upperBound
        var low = 0, high = state.ranges.count
        while low < high {
            let middle = (low + high) / 2
            if state.ranges[middle].upperBound < lower { low = middle + 1 } else { high = middle }
        }
        var last = low
        while last < state.ranges.count, state.ranges[last].lowerBound <= upper {
            state.measured -= state.ranges[last].upperBound - state.ranges[last].lowerBound
            lower = min(lower, state.ranges[last].lowerBound); upper = max(upper, state.ranges[last].upperBound)
            last += 1
        }
        state.measured += upper - lower
        state.ranges.replaceSubrange(low..<last, with: CollectionOfOne(lower..<upper))
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

/// Carved files starting inside `range` are not emitted: the carve backfill's overrun past the
/// resume point finds again what the resumed sweep already reported.
/// Lock-protected rather than an actor: it is asked once per carved file, so no executor hop.
final class CarveDropRange: @unchecked Sendable {
    private let lock = NSLock()
    private var range: Range<Int64>?
    func set(_ range: Range<Int64>) { lock.withLock { self.range = range } }
    func drops(_ file: RecoveredFile) -> Bool {
        guard let range = lock.withLock({ self.range }), case .runs(let runs) = file.content,
              let first = runs.first?.deviceOffset else { return false }
        return range.contains(first)
    }
}

/// Device-absolute byte ranges owned by files found through metadata. Appended once per found
/// file, from the parser's own task, so it is a lock-protected buffer rather than an actor: a
/// claim costs no executor hop. Runs keep the order they were added in.
final class ClaimedRuns: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: [DataRun] = []
    var runs: [DataRun] { lock.withLock { buffer } }
    func add(_ new: [DataRun]) {
        lock.withLock { for run in new where run.deviceOffset != nil { buffer.append(run) } }
    }
}
