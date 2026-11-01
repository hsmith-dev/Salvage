import Foundation

// Bifragment JPEG reassembly.
//
// A JPEG carve runs its scan data through `JPEGScanDecoder` while it searches for the EOI footer,
// and keeps a snapshot of the decoder at each sector boundary since the last valid restart marker.
// When the decode fails (the bytes are no longer this JPEG's) or the carve is cut by the next
// header or a claimed run while the decode is still incomplete, the first fragment ended at or
// before that point, on a sector boundary: each kept snapshot is a candidate break.
//
// The carver then looks at later, unclaimed, sector-aligned offsets within `joinSearchBytes` that
// aren't inside another known file (a header, a validated carve, another JPEG's validly decoded
// scan data). At each one it continues every candidate break's decoder, at that break's bit
// position, on the bytes found there. A join is emitted only when exactly one (break, resume)
// pair decodes the frame's remaining MCUs with the right restart sequence and ends at EOI, and
// the search has finished: two validating joins are ambiguous, so neither is used. Work is
// bounded per JPEG by `maxJoinResumeStarts`, `maxJoinBreaks` and `maxJoinDecodeBytes`; a search
// that runs out of budget, or reaches the end of the extent, keeps the original partial carve.
//
// Why this is off by default (`Limits.reassembleFragmentedJPEGs`): the decoder proves that the
// joined bytes are *a* valid scan with the frame's MCU count, not that they are *this* image's.
// The orphaned tail of another JPEG with the same Huffman tables and dimensions (photos from one
// camera) resynchronizes after a few symbols (Huffman codes self-synchronize), and one of the
// thousands of (break, resume) pairs tried lands it on exactly the right MCU index, after which it
// decodes to EOI with the right count and, with restart markers, the right restart numbers. In
// experiments with tiles of a real photo re-encoded by ImageIO, such a tail validated in 4 of 37
// (320x240), 4 of 17 (640x480) and 1 of 5 (1024x768) layouts; synthetic images, 2 of 210. A
// vertical DC-continuity test across the seam rejected most but not all of them while also
// rejecting some true joins, so it was not kept. The search also emits nothing when the gap holds
// zeros and the tables code zeros as flat blocks: a shifted join through the zeros validates as
// well as the true one, and the tie is refused.

/// Where a reassembled JPEG's two fragments are: `carve.start..<breakAt`, then `resumeAt..<end`.
struct JPEGJoin: Sendable, Equatable {
    let breakAt: Int64
    let resumeAt: Int64
    let end: Int64
}

/// A decoder snapshot at a sector boundary of the first fragment.
struct JPEGBreak: Sendable {
    let offset: Int64
    let state: JPEGScanDecoder
}

/// Entropy decoding state of one open JPEG carve.
struct JPEGCarveTrack: Sendable {
    var header = JPEGHeaderParser()
    /// A header segment the decoder needs that wasn't fully in the window yet.
    private(set) var pendingSegment: (start: Int64, end: Int64, marker: UInt8, startsScan: Bool)?
    private(set) var decoder: JPEGScanDecoder?
    /// Snapshots at sector boundaries since the last restart marker, oldest first.
    private(set) var breaks: [JPEGBreak] = []
    /// Set once a reassembly search was started (or refused) for this carve.
    var joinStarted = false

    /// Earliest offset the track still needs to read.
    var retainFrom: Int64? {
        if let pendingSegment { return pendingSegment.start }
        if let decoder, decoder.isLive { return decoder.position }
        return nil
    }

    /// A marker segment of the header walk: `size` bytes from `start` (marker included).
    mutating func headerSegment(marker: UInt8, at start: Int64, size: Int64, startsScan: Bool, _ context: Window) {
        guard header.unsupported == nil else { return }
        guard startsScan || JPEGHeaderParser.needsPayload(marker) else {
            header.segment(marker: marker, payload: UnsafeRawBufferPointer(start: nil, count: 0))
            return
        }
        guard size >= 4, size <= 65537 else { return header.markUnsupported("bad segment length") }
        pendingSegment = (start, start + size, marker, startsScan)
        completePendingSegment(context)
    }

    /// Parses the pending header segment once the window holds all of it.
    mutating func completePendingSegment(_ context: Window) {
        guard let segment = pendingSegment else { return }
        guard segment.start >= context.start else {
            pendingSegment = nil
            return header.markUnsupported("header segment no longer readable")
        }
        guard segment.end <= context.end else {
            if context.final {
                pendingSegment = nil
                header.markUnsupported("truncated header segment")
            }
            return
        }
        pendingSegment = nil
        let lower = context.index(segment.start + 4), upper = context.index(segment.end)
        let payload = UnsafeRawBufferPointer(rebasing: context.buffer[lower..<upper])
        if segment.startsScan {
            if let layout = header.layout(startOfScan: payload) { decoder = JPEGScanDecoder(layout: layout, start: segment.end) }
        } else {
            header.segment(marker: segment.marker, payload: payload)
        }
    }

    /// Decodes the scan data up to `end`, snapshotting the decoder at every sector boundary.
    mutating func feed(upTo end: Int64, _ context: Window, sectorSize: Int64, maxBreaks: Int) {
        guard var decoder, decoder.isLive, end > decoder.position else { return }
        guard decoder.position >= context.start, end <= context.end else {
            // The bytes it needs are gone; the decoder can no longer judge this file.
            self.decoder = nil; breaks = []
            return header.markUnsupported("scan data no longer readable")
        }
        while decoder.isLive {
            let at = decoder.position
            if maxBreaks > 0, at % sectorSize == 0, breaks.last.map({ $0.offset < at }) ?? true {
                breaks.append(JPEGBreak(offset: at, state: decoder))
                let floor = decoder.lastRestart
                if let first = breaks.first, first.offset < floor { breaks.removeAll { $0.offset < floor } }
                if breaks.count > maxBreaks { breaks.removeFirst(breaks.count - maxBreaks) }
            }
            guard at < end else { break }
            let boundary = (at / sectorSize + 1) * sectorSize
            decoder.feed(context.buffer, at: context.start, upTo: min(end, boundary))
        }
        self.decoder = decoder
    }
}

/// A JPEG whose first fragment broke off, searching for its second.
struct PendingJoin: Sendable {
    struct Candidate: Sendable {
        let breakAt: Int64
        let resumeAt: Int64
        /// The second fragment can't reach this offset (a claimed run, or the size cap).
        let limit: Int64
        var decoder: JPEGScanDecoder
    }

    let carveStart: Int64
    /// Largest total size the reassembled file may have.
    let maxBytes: Int64
    let breaks: [JPEGBreak]
    /// Next sector-aligned offset to try as a second fragment's start.
    var nextResume: Int64
    /// Second fragments must start before this offset.
    let searchEnd: Int64
    var starts = 0
    var work: Int64 = 0
    var live: [Candidate] = []
    var successes: [JPEGJoin] = []
    /// Ambiguous, or over budget: no join is emitted.
    var abandoned = false
    var searchDone = false
    /// The carve's own result, once the carve has ended.
    var ended: SignatureCarver.Ended?
}

extension SignatureCarver {
    /// Whether a carve cut this way may have a second fragment worth looking for.
    static func joinable(_ cut: Cut) -> Bool {
        switch cut {
        case .nextHeader, .inconsistent, .claimed: true
        case .validated, .limit, .extentEnd, .untrusted: false
        }
    }

    /// Routes carves that ended in this window through reassembly, advances the searches over the
    /// window, and returns what should be emitted now.
    func settleJoins(_ ended: [Ended], _ context: Window) -> [Ended] {
        var result: [Ended] = []
        for var item in ended {
            if let track = item.carve.jpeg, let decoder = track.decoder, decoder.status != .complete {
                // The footer can't vouch for scan data that doesn't decode.
                if decoder.status == .invalid, item.cut == .validated { item.cut = .inconsistent }
                if let index = joins.firstIndex(where: { $0.carveStart == item.carve.start }) {
                    joins[index].ended = item
                    continue
                }
                if !track.joinStarted, Self.joinable(item.cut),
                   var join = makeJoin(item.carve, track, bound: min(decoder.position, item.end), context) {
                    join.ended = item
                    joins.append(join)
                    continue
                }
            }
            noteOwned(item)
            result.append(item)
        }
        for index in open.indices {
            guard let track = open[index].jpeg, !track.joinStarted, let decoder = track.decoder, decoder.status == .invalid else { continue }
            open[index].jpeg?.joinStarted = true
            if let join = makeJoin(open[index], track, bound: decoder.position, context) { joins.append(join) }
        }
        advanceJoins(context)
        var remaining: [PendingJoin] = []
        for join in joins {
            if (join.searchDone || context.final), var item = join.ended {
                if !join.abandoned, join.successes.count == 1, let found = join.successes.first {
                    item.cut = .validated
                    item.join = found
                    ownedRanges.append(found.resumeAt..<found.end)
                } else {
                    noteOwned(item)
                }
                result.append(item)
            } else if !context.final {
                remaining.append(join)
            }
        }
        joins = remaining
        pruneOwned()
        return result
    }

    private func makeJoin(_ carve: OpenCarve, _ track: JPEGCarveTrack, bound: Int64, _ context: Window) -> PendingJoin? {
        guard limits.reassembleFragmentedJPEGs, joins.count < limits.maxPendingJoins else { return nil }
        let breaks = track.breaks.filter { $0.offset <= bound }
        guard !breaks.isEmpty else { return nil }
        let first = max(alignUp(bound), alignUp(context.start))
        let (searchEnd, overflow) = first.addingReportingOverflow(limits.joinSearchBytes)
        let maxBytes = carve.signature.maxBytes ?? limits.defaultMaxBytes
        return PendingJoin(carveStart: carve.start, maxBytes: maxBytes, breaks: breaks, nextResume: first,
                           searchEnd: overflow ? Int64.max : searchEnd)
    }

    /// A carve's bytes known to be its own (validated end, or validly decoded scan data).
    private func noteOwned(_ item: Ended) {
        if item.cut == .validated {
            ownedRanges.append(item.carve.start..<item.end)
        } else if let decoder = item.carve.jpeg?.decoder, item.carve.start < decoder.validUpTo {
            ownedRanges.append(item.carve.start..<decoder.validUpTo)
        }
    }

    private func pruneOwned() {
        guard let floor = joins.lazy.filter({ !$0.searchDone }).map(\.nextResume).min() else {
            ownedRanges = []
            return
        }
        ownedRanges.removeAll { $0.upperBound <= floor }
        if ownedRanges.count > 4096 { ownedRanges.removeFirst(ownedRanges.count - 4096) }
    }

    /// End of the bytes an open carve's structure already accounts for, if it can tell.
    private func ownedEnd(of carve: OpenCarve) -> Int64? {
        switch carve.phase {
        case .walking(let next), .gif(let next, _): return next
        case .ending(let end, .validated): return end
        case .walker(let walker): return walker.cover
        case .footer:
            if let decoder = carve.jpeg?.decoder, decoder.status != .invalid { return decoder.position }
            return nil
        case .ending, .openEnded: return nil
        }
    }

    /// Whether a second fragment can't start at `offset` because the bytes there are another file's.
    private func knownElsewhere(_ offset: Int64, excluding start: Int64, _ context: Window) -> Int64? {
        if let range = claimedRange(containing: offset) { return range.upperBound }
        if let range = ownedRanges.last(where: { $0.contains(offset) }) { return range.upperBound }
        for carve in open where carve.start != start && carve.start <= offset {
            if let end = ownedEnd(of: carve), offset < end { return end }
        }
        if signatures.contains(where: { context.headerMatches($0, at: offset) && context.validates($0, at: offset) }) {
            return offset + 1
        }
        return nil
    }

    private func advanceJoins(_ context: Window) {
        let sector = Int64(limits.sectorSize)
        for index in joins.indices where !joins[index].searchDone {
            var join = joins[index]
            var survivors: [PendingJoin.Candidate] = []
            for var candidate in join.live where step(&candidate, &join, context) { survivors.append(candidate) }
            join.live = survivors
            let spawnEnd = context.final ? context.end : context.end - Int64(reach)
            var offset = join.nextResume
            while offset < min(spawnEnd, join.searchEnd), join.starts < limits.maxJoinResumeStarts, !join.abandoned {
                if let skip = knownElsewhere(offset, excluding: join.carveStart, context) {
                    offset = max(offset + sector, alignUp(skip))
                    continue
                }
                join.starts += 1
                let claimEnd = nextClaimStart(after: offset)
                for snapshot in join.breaks where snapshot.offset < offset {
                    let room = join.maxBytes - (snapshot.offset - join.carveStart)
                    let (sizeEnd, overflow) = offset.addingReportingOverflow(max(room, 0))
                    var candidate = PendingJoin.Candidate(breakAt: snapshot.offset, resumeAt: offset,
                                                          limit: min(claimEnd, overflow ? Int64.max : sizeEnd),
                                                          decoder: snapshot.state.resumed(at: offset))
                    if step(&candidate, &join, context) { join.live.append(candidate) }
                }
                offset += sector
            }
            join.nextResume = offset
            if join.successes.count > 1 || join.work > limits.maxJoinDecodeBytes { join.abandoned = true }
            let exhausted = offset >= join.searchEnd || join.starts >= limits.maxJoinResumeStarts
            if join.abandoned || context.final || (join.live.isEmpty && exhausted) {
                join.searchDone = true
                join.live = []
            }
            joins[index] = join
        }
    }

    /// Continues one candidate over the window; false once it validated or failed.
    private func step(_ candidate: inout PendingJoin.Candidate, _ join: inout PendingJoin, _ context: Window) -> Bool {
        let stop = min(candidate.limit, context.end)
        if stop > candidate.decoder.position {
            join.work += candidate.decoder.feed(context.buffer, at: context.start, upTo: stop)
        }
        switch candidate.decoder.status {
        case .complete:
            join.successes.append(JPEGJoin(breakAt: candidate.breakAt, resumeAt: candidate.resumeAt, end: candidate.decoder.position))
            return false
        case .invalid:
            return false
        case .decoding, .awaitingRestart, .awaitingEnd:
            return candidate.decoder.position < candidate.limit
        }
    }
}

