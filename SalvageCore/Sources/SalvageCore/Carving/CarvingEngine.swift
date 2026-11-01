import Foundation

/// A streaming consumer of the read-only sweep (AD-6). `ScanSession` feeds it every chunk it
/// reads, in device order, then calls `finish()`. Chunks are device-absolute and contiguous within
/// a volume extent; a new extent may start at any offset.
protocol Carver: Sendable {
    /// Byte ranges owned by files already found through metadata; carving skips them.
    func begin(claimed: [DataRun], deviceSizeBytes: Int64) async throws
    /// Announces the volume extent the following chunks belong to. Every call is a hard cut: open
    /// carves end at the previous extent's last consumed byte, and carved files report `offset`
    /// as their `volumeOffset` even when the first chunk starts later (a resumed sweep). Callers
    /// that never call it get the implicit behaviour: a chunk not contiguous with the previous one
    /// starts a new extent at its own offset.
    func beginExtent(offset: Int64, length: Int64) async throws
    func consume(_ chunk: Data, at deviceOffset: Int64) async throws
    func finish() async throws
    /// True once the carver stopped emitting because it reached its total file cap; the scan
    /// should tell the user that carving was incomplete.
    var hitFileLimit: Bool { get async }
}

extension Carver {
    func beginExtent(offset: Int64, length: Int64) async throws {}
    var hitFileLimit: Bool { get async { false } }
}

/// Signature-based carving over raw bytes (Stories 3.1 + 3.2).
///
/// The engine is generic: every format rule comes from a `FileSignature` (AD-6). It looks for
/// headers at sector-aligned offsets, follows each match to its end by the signature's rule
/// (size field, record walk, structure walker, footer) or, failing that, to `maxBytes`, the next
/// header, a claimed run or the end of the extent, and reports the result as a `RecoveredFile`
/// with `recoveryMethod: .carved`. Only offsets are kept; file bodies are never buffered. Matches
/// that straddle a chunk boundary are handled by carrying the unexamined tail of each chunk into
/// the next window.
///
/// Evidence reported (AD-7): a file whose end was validated by its footer, size field, record
/// walk or structure carries `overwriteConfidence` 0 and is not partial. A carve cut short by
/// `maxBytes`, the next header or the end of the extent, or whose size claim exceeds the
/// signature's `trustedMaxBytes`, is partial with 0.6. A carve cut by a claimed run (its bytes
/// belong to a live file) or whose own structure is inconsistent is partial with 1.0.
///
/// A JPEG (a signature with `entropy`) also has its scan data run through the baseline entropy
/// decoder: when the data stops decoding, a footer found later can't validate it, and the carve is
/// partial with 1.0 instead (the bytes past the break belong to something else).
///
/// Carved files are one contiguous run by default. With `Limits.reassembleFragmentedJPEGs`, a JPEG
/// whose scan data stops decoding, or is cut by the next header, may be joined with a later
/// fragment: the join is emitted, as two runs, only when the decoder validates every MCU of the
/// frame and the restart sequence across it, ending at EOI, and no other join validates (see
/// `JPEGReassembly.swift`, which also says why this is off by default).
actor SignatureCarver: Carver {
    static let isImplemented = true
    /// `rawRecord` keeps at most this many header bytes.
    static let rawRecordBytes = 64

    struct Limits: Sendable {
        /// Headers are looked for at multiples of this device offset.
        var sectorSize = 512
        var maxOpenCarves = 64
        var maxCarvedFiles = 250_000
        /// Cap for signatures that don't declare `maxBytes`.
        var defaultMaxBytes: Int64 = 256 * 1024 * 1024
        /// Largest validated size-field / record-walk size for signatures that don't declare
        /// `trustedMaxBytes`.
        var defaultTrustedMaxBytes: Int64 = 64 * 1024 * 1024
        /// Bifragment JPEG reassembly (see `JPEGReassembly.swift`). Off by default: entropy
        /// validation can't tell a JPEG's real second fragment from the orphaned tail of another
        /// JPEG with the same tables and dimensions (a sibling photo from the same camera), and
        /// measured on real images such tails validated in roughly 10-25% of the layouts where one
        /// sat in the search window. A wrong picture is worse than a partial one.
        var reassembleFragmentedJPEGs = false
        /// Second fragments are looked for at sector-aligned offsets in this many bytes after the
        /// first fragment breaks off ...
        var joinSearchBytes: Int64 = 16 * 1024 * 1024
        /// ... trying at most this many resume offsets ...
        var maxJoinResumeStarts = 4096
        /// ... from each of at most this many break points (sector boundaries since the last valid
        /// restart marker, nearest the point where decoding failed) ...
        var maxJoinBreaks = 16
        /// ... decoding at most this many entropy bytes in all, per JPEG.
        var maxJoinDecodeBytes: Int64 = 64 * 1024 * 1024
        /// JPEGs searching for a second fragment at the same time; more stay partial.
        var maxPendingJoins = 4
        static let `default` = Limits()
    }

    /// Why a carve ended; decides the partial flag and the overwrite estimate.
    enum Cut {
        case validated, limit, nextHeader, extentEnd, untrusted, claimed, inconsistent
        var partial: Bool { self != .validated }
        var overwrite: Double {
            switch self {
            case .validated: 0
            case .limit, .nextHeader, .extentEnd, .untrusted: 0.6
            case .claimed, .inconsistent: 1
            }
        }
    }

    struct OpenCarve {
        enum GIFState { case screen, block, lzwCode, subBlocks }
        enum Phase {
            /// Walking self-describing records; the value is the next record's device offset.
            case walking(Int64)
            /// Walking GIF blocks; the value is the next byte to read.
            case gif(Int64, GIFState)
            /// Searching for the footer from this device offset.
            case footer(Int64)
            /// The end is known; the carve closes once the stream has covered it.
            case ending(Int64, Cut)
            /// No end rule applies: runs to a limit.
            case openEnded(Cut)
            /// A structure walker (MP3 frames, OLE2 allocation table, gzip/DEFLATE) owns the walk.
            case walker(any CarveWalker)
        }
        let signature: FileSignature
        let start: Int64
        /// Start of the first claimed run after `start`; the carve can never reach past it.
        let claimLimit: Int64
        let maxEnd: Int64
        let trustedMax: Int64
        let headerBytes: Data
        var phase: Phase
        /// For `footerMode: last`: the end of the latest footer seen so far.
        var lastFooterEnd: Int64?
        /// The end came from a size field or a record walk (not a footer or a trailer), so it is
        /// only trusted up to `trustedMax`.
        var sizeDerived = false
        /// Entropy decoding of a JPEG's scan data (signatures with `entropy`).
        var jpeg: JPEGCarveTrack?

        /// Device offset up to which the signature's structure says the bytes belong to this file.
        var cover: Int64 {
            switch phase {
            case .walking(let next), .gif(let next, _): next
            case .ending(let end, _): end
            case .walker(let walker): walker.cover ?? start
            case .footer, .openEnded: start
            }
        }
    }

    struct Ended {
        let carve: OpenCarve
        let end: Int64
        var cut: Cut
        /// Set when the carve was reassembled from two fragments.
        var join: JPEGJoin?
        init(carve: OpenCarve, end: Int64, cut: Cut) { self.carve = carve; self.end = end; self.cut = cut }
    }

    let emit: @Sendable (RecoveredFile) async throws -> Void
    let signatures: [FileSignature]
    let limits: Limits
    /// Bytes past a candidate position every rule in the library can be evaluated with.
    let reach: Int
    /// Which signatures can possibly match at a position, from single bytes (see `HeaderDispatch`).
    let dispatch: HeaderDispatch

    private var claimed: [Range<Int64>] = []
    /// Bytes from `windowStart` to the end of the previous chunk that still need examining.
    private var carry = Data()
    private var windowStart: Int64 = 0
    /// Device offset just past the last consumed byte; nil before the first chunk of an extent.
    private var streamEnd: Int64?
    private var extentStart: Int64 = 0
    /// The extent announced by `beginExtent`, if any.
    private var explicitExtent: Range<Int64>?
    /// Next sector-aligned device offset to test for a header.
    private var nextHeaderSearch: Int64 = 0
    var open: [OpenCarve] = []
    private var usedNames: Set<String> = []
    /// JPEGs looking for their second fragment (see `JPEGReassembly.swift`).
    var joins: [PendingJoin] = []
    /// Recent byte ranges known to belong to other files, where no second fragment can start.
    var ownedRanges: [Range<Int64>] = []
    private(set) var emittedCount = 0
    /// True once `maxCarvedFiles` was reached and further carves were dropped. Exposed through
    /// `Carver.hitFileLimit` so the scan can report that carving stopped early.
    private(set) var hitFileLimit = false

    init(emit: @escaping @Sendable (RecoveredFile) async throws -> Void) {
        self.init(emit: emit, library: SignatureLibrary.bundled)
    }

    init(emit: @escaping @Sendable (RecoveredFile) async throws -> Void, library: SignatureLibrary, limits: Limits = .default) {
        self.emit = emit
        self.signatures = library.signatures
        self.limits = limits
        var reach = 1
        for signature in library.signatures {
            reach = max(reach, signature.headerReach, signature.footerReach, signature.segments?.reach ?? 0)
        }
        self.reach = reach
        self.dispatch = HeaderDispatch(library.signatures)
    }

    // MARK: Carver

    func begin(claimed runs: [DataRun], deviceSizeBytes: Int64) async throws {
        var ranges: [Range<Int64>] = []
        for run in runs {
            guard let offset = run.deviceOffset, run.length > 0, offset >= 0 else { continue }
            let (end, overflow) = offset.addingReportingOverflow(run.length)
            ranges.append(offset..<(overflow ? Int64.max : end))
        }
        ranges.sort { $0.lowerBound < $1.lowerBound }
        var merged: [Range<Int64>] = []
        for range in ranges {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        claimed = merged
        carry = Data(); streamEnd = nil; open = []; explicitExtent = nil
        joins = []; ownedRanges = []
    }

    func beginExtent(offset: Int64, length: Int64) async throws {
        try await endExtent()
        let (end, overflow) = offset.addingReportingOverflow(max(length, 0))
        explicitExtent = offset..<(overflow ? Int64.max : end)
        extentStart = offset
    }

    func consume(_ chunk: Data, at deviceOffset: Int64) async throws {
        guard !chunk.isEmpty, !signatures.isEmpty else { return }
        if let end = streamEnd, end != deviceOffset { try await endExtent() }
        if let extent = explicitExtent, !extent.contains(deviceOffset) {
            // Past the announced extent: what follows is a new, implicit extent.
            try await endExtent()
            explicitExtent = nil
        }
        if streamEnd == nil {
            extentStart = explicitExtent?.lowerBound ?? deviceOffset
            windowStart = deviceOffset
            nextHeaderSearch = alignUp(deviceOffset)
            carry = Data()
        }
        let (end, overflow) = deviceOffset.addingReportingOverflow(Int64(chunk.count))
        guard !overflow else { throw ScanError.malformed("Carving offset overflow.") }
        streamEnd = end
        let window = carry.isEmpty ? chunk : carry + chunk
        let ended = scan(window, final: false)
        for item in ended { try await finalize(item) }
    }

    func finish() async throws {
        try await endExtent()
    }

    /// The extent ended at `streamEnd`: examine what the carry still holds with no more bytes to
    /// come, then close every open carve at the extent end.
    private func endExtent() async throws {
        guard streamEnd != nil else { return }
        let ended = scan(carry, final: true)
        for item in ended { try await finalize(item) }
        carry = Data(); open = []; streamEnd = nil
    }

    // MARK: Scanning

    /// Examines `window` (device offsets `windowStart..<windowStart + window.count`): opens carves
    /// at sector-aligned headers, advances open carves, and leaves the unexamined tail in `carry`.
    /// With `final`, no more bytes follow, so rules are evaluated with what is available and every
    /// carve still open is cut at the window's end.
    private func scan(_ window: Data, final: Bool) -> [Ended] {
        let windowEnd = windowStart + Int64(window.count)
        var ended: [Ended] = []
        var carryStart = windowEnd
        window.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            let context = Window(buffer: buffer, start: windowStart, end: windowEnd, final: final)
            var position = nextHeaderSearch
            // Positions below `unclaimedUntil` are known to lie outside every claimed range, so
            // the binary search runs once per gap instead of once per sector.
            var unclaimedUntil = Int64.min
            while position < windowEnd, final || position + Int64(reach) <= windowEnd {
                if position >= unclaimedUntil {
                    if let range = claimedRange(containing: position) {
                        position = alignUp(range.upperBound)
                        continue
                    }
                    unclaimedUntil = nextClaimStart(after: position)
                }
                // Only signatures whose first header byte(s) fit are tested, in library order, so
                // `matched` is exactly what filtering every signature would give.
                if dispatch.mayMatch(context, at: position) {
                    var matched: [FileSignature] = []
                    dispatch.forEachCandidate(context, at: position) { index in
                        let signature = signatures[index]
                        if context.headerMatches(signature, at: position) && context.validates(signature, at: position) {
                            matched.append(signature)
                        }
                    }
                    if !matched.isEmpty { openCarves(matched, at: position, context, &ended) }
                }
                position += Int64(limits.sectorSize)
            }
            nextHeaderSearch = position
            // A header position not yet examined (it needs bytes the next chunk brings) may end
            // an open carve there, so nothing is advanced past it: a footer beyond it must not end
            // a carve the header would have cut.
            advanceAll(through: final ? windowEnd : min(windowEnd, nextHeaderSearch), context, &ended)
            if final {
                for carve in open { ended.append(cut(carve, at: windowEnd, .extentEnd)) }
                open = []
            }
            ended = settleJoins(ended, context)
            carryStart = min(carryStart, nextHeaderSearch)
            for carve in open {
                switch carve.phase {
                case .walking(let next), .footer(let next), .gif(let next, _): carryStart = min(carryStart, next)
                case .walker(let walker): carryStart = min(carryStart, walker.retainFrom)
                case .ending, .openEnded: break
                }
                if let retain = carve.jpeg?.retainFrom { carryStart = min(carryStart, retain) }
            }
            for join in joins where !join.searchDone { carryStart = min(carryStart, join.nextResume) }
        }
        carryStart = min(max(carryStart, windowStart), windowEnd)
        if !final {
            carry = window.subdata(in: window.startIndex + Int(carryStart - windowStart)..<window.endIndex)
            windowStart = carryStart
        }
        return ended
    }

    /// A header matched at `position`. Open carves are first resolved up to that point; if one
    /// of them accounts for the header as its own data (see `absorbs`), the header is ignored.
    /// Otherwise every open carve is cut here (partial) and new carves start.
    private func openCarves(_ matched: [FileSignature], at position: Int64, _ context: Window, _ ended: inout [Ended]) {
        advanceAll(through: position, context, &ended)
        if open.contains(where: { absorbs($0, matched, at: position) }) { return }
        for carve in open { ended.append(cut(carve, at: position, .nextHeader)) }
        open = []
        let claimLimit = nextClaimStart(after: position)
        for signature in matched.prefix(limits.maxOpenCarves) {
            open.append(makeCarve(signature, at: position, claimLimit: claimLimit, context))
        }
    }

    /// Whether an open carve accounts for headers found at `position` as its own data:
    /// - inside the range its size field or record walk covers: when the format may embed them
    ///   (`embeds`, honoured only while the claim is within `trustedMaxBytes`, so a garbage size
    ///   can't hide real files) or they are weak (`cutsOthers: false`);
    /// - while it searches for its footer: when they are weak, or embeddable and the footer can
    ///   tell its own record from a nested file's (`footerOffsetCheck`);
    /// - when it has no end rule: when they are weak and the format embeds them (MP3 frame syncs
    ///   inside an MP3; a new ID3 tag, a strong header, still starts a new file).
    /// Any other header ends the carve.
    private func absorbs(_ carve: OpenCarve, _ matched: [FileSignature], at position: Int64) -> Bool {
        let embedded = matched.allSatisfy { carve.signature.embeds.contains($0.id) }
        let weak = matched.allSatisfy { !$0.cutsOthers }
        switch carve.phase {
        case .walking, .gif, .ending:
            guard position < carve.cover else { return false }
            return weak || (embedded && carve.cover - carve.start <= carve.trustedMax)
        case .footer:
            return weak || (embedded && !carve.signature.footerOffsetCheck.isEmpty)
        case .openEnded:
            return embedded && weak
        case .walker(let walker):
            return walker.absorbs(at: position, weak: weak, embedded: embedded, trustedMax: carve.trustedMax)
        }
    }

    private func advanceAll(through limit: Int64, _ context: Window, _ ended: inout [Ended]) {
        var remaining: [OpenCarve] = []
        for var carve in open {
            if let done = advance(&carve, through: limit, context) { ended.append(done) } else { remaining.append(carve) }
        }
        open = remaining
    }

    private func makeCarve(_ signature: FileSignature, at start: Int64, claimLimit: Int64, _ context: Window) -> OpenCarve {
        let maxBytes = signature.maxBytes ?? limits.defaultMaxBytes
        let (maxEnd, overflow) = start.addingReportingOverflow(maxBytes)
        let headerEnd = min(start + Int64(Self.rawRecordBytes), context.end)
        let headerBytes = Data(UnsafeRawBufferPointer(rebasing: context.buffer[context.index(start)..<context.index(headerEnd)]))
        var carve = OpenCarve(signature: signature, start: start, claimLimit: claimLimit,
                              maxEnd: overflow ? Int64.max : maxEnd,
                              trustedMax: signature.trustedMaxBytes ?? limits.defaultTrustedMaxBytes,
                              headerBytes: headerBytes, phase: .openEnded(.limit))
        let minimumSize = Int64(signature.headerOffset + (signature.headers.map(\.count).max() ?? 0))
        if !signature.sizeFields.isEmpty {
            var total: Int64 = 0
            var readable = true, consistent = true
            for field in signature.sizeFields {
                guard start + Int64(field.reach) <= context.end else { readable = false; break }
                guard let value = context.readSize(field, at: start) else { consistent = false; break }
                let (sum, overflow) = total.addingReportingOverflow(value)
                guard !overflow else { consistent = false; break }
                total = sum
            }
            let (end, endOverflow) = start.addingReportingOverflow(total)
            if !readable {
                carve.phase = .openEnded(.limit)
            } else if !consistent || endOverflow || total < minimumSize || total > maxBytes {
                carve.phase = .openEnded(.inconsistent)
            } else if end > claimLimit {
                carve.phase = .ending(claimLimit, .claimed)
            } else {
                carve.phase = .ending(end, .validated)
                carve.sizeDerived = true
            }
        } else if let segments = signature.segments {
            carve.phase = .walking(start + Int64(segments.start))
            if signature.entropy == .jpegBaseline { carve.jpeg = JPEGCarveTrack() }
        } else if let structure = signature.structure {
            switch structure {
            case .gif: carve.phase = .gif(start + 6, .screen)
            case .mp3: carve.phase = .walker(MP3Walker(start: start, sectorSize: limits.sectorSize))
            case .ole2: carve.phase = .walker(OLE2Walker(start: start, maxBytes: maxBytes))
            case .gzip: carve.phase = .walker(GzipWalker(start: start, sectorSize: limits.sectorSize))
            }
        } else if signature.footer != nil {
            carve.phase = .footer(start + minimumSize)
        }
        return carve
    }

    /// Moves a carve forward as far as the bytes available allow, but not past `limit` (the next
    /// header position, or the window's end). Returns the carve when it has ended at or before
    /// `limit`.
    private func advance(_ carve: inout OpenCarve, through limit: Int64, _ context: Window) -> Ended? {
        carve.jpeg?.completePendingSegment(context)
        while true {
            switch carve.phase {
            case .ending(let end, let cut):
                return end <= limit ? Ended(carve: carve, end: end, cut: cut) : nil

            case .openEnded(let cut):
                let bound = min(carve.claimLimit, carve.maxEnd)
                guard bound <= limit else { return nil }
                return Ended(carve: carve, end: bound, cut: bound == carve.claimLimit && carve.claimLimit < carve.maxEnd ? .claimed : cut)

            case .walking(let next):
                guard next <= limit else { return nil }
                guard let segments = carve.signature.segments else { carve.phase = .openEnded(.limit); continue }
                // Reaching a bound mid-walk proves nothing about where the file ends.
                if next >= carve.claimLimit { return Ended(carve: carve, end: carve.claimLimit, cut: .claimed) }
                if next >= carve.maxEnd { return Ended(carve: carve, end: carve.maxEnd, cut: .limit) }
                if let fill = segments.fillByte {
                    guard next + 2 <= context.end else { return context.final ? cut(carve, at: context.end, .extentEnd) : nil }
                    if context.byte(at: next) == fill, context.byte(at: next + 1) == fill {
                        carve.phase = .walking(next + 1)
                        continue
                    }
                }
                if next + Int64(segments.reach) > context.end {
                    // The record header straddles the window; wait for more bytes.
                    return context.final ? cut(carve, at: context.end, .extentEnd) : nil
                }
                let first = next == carve.start + Int64(segments.start)
                let typeValid = context.recordTypeValid(segments, at: next)
                if segments.zeroSizeToEnd, typeValid, context.rawRecordSize(segments, at: next) == 0 {
                    // "Extends to the end of the file": no validated end exists.
                    carve.phase = .openEnded(.limit)
                    continue
                }
                guard let size = context.recordSize(segments, at: next), size >= segments.minimum, typeValid else {
                    if first { carve.phase = .openEnded(.inconsistent); continue }
                    // A walk that should continue to its stop record (JPEG's start-of-scan) found
                    // something that isn't a record: the structure is broken here.
                    if !segments.stopAt.isEmpty { return Ended(carve: carve, end: next, cut: .inconsistent) }
                    carve.sizeDerived = true
                    return Ended(carve: carve, end: next, cut: .validated)
                }
                let stop = segments.stopAt.contains(where: { context.matches($0, at: next + Int64(segments.typeOffset)) })
                if carve.jpeg != nil, let marker = context.byte(at: next + 1) {
                    carve.jpeg?.headerSegment(marker: marker, at: next, size: size, startsScan: stop, context)
                }
                if stop {
                    carve.phase = .footer(next)
                    continue
                }
                let (end, overflow) = next.addingReportingOverflow(size)
                if overflow {
                    return Ended(carve: carve, end: next, cut: .inconsistent)
                } else if end > carve.maxEnd {
                    carve.phase = .ending(carve.maxEnd, .limit)
                } else if end > carve.claimLimit {
                    carve.phase = .ending(carve.claimLimit, .claimed)
                } else {
                    carve.phase = .walking(end)
                }

            case .gif(let next, let state):
                guard next <= limit else { return nil }
                if next >= carve.claimLimit { return Ended(carve: carve, end: carve.claimLimit, cut: .claimed) }
                if next >= carve.maxEnd { return Ended(carve: carve, end: carve.maxEnd, cut: .limit) }
                guard let step = context.gifStep(at: next, state) else {
                    return context.final ? cut(carve, at: context.end, .extentEnd) : nil
                }
                switch step {
                case .next(let offset, let state): carve.phase = .gif(offset, state)
                case .trailer(let end): carve.phase = .ending(end, .validated)
                case .invalid:
                    // Not a block where one must be: the structure is broken here.
                    return Ended(carve: carve, end: next, cut: .inconsistent)
                }

            case .walker(let walker):
                // Reaching a bound mid-walk proves nothing about where the file ends.
                let bound = min(carve.claimLimit, carve.maxEnd)
                func boundCut() -> Ended {
                    Ended(carve: carve, end: bound, cut: bound == carve.claimLimit && carve.claimLimit < carve.maxEnd ? .claimed : .limit)
                }
                if walker.retainFrom >= bound { return boundCut() }
                switch walker.advance(through: min(limit, bound), context) {
                case .paused:
                    if walker.retainFrom >= bound { return boundCut() }
                    return nil
                case .needBytes:
                    return context.final ? cut(carve, at: context.end, .extentEnd) : nil
                case .end(let end, let kind):
                    carve.sizeDerived = walker.sizeDerived
                    if end > carve.maxEnd {
                        carve.phase = .ending(carve.maxEnd, .limit)
                    } else if end > carve.claimLimit {
                        carve.phase = .ending(carve.claimLimit, .claimed)
                    } else {
                        carve.phase = .ending(end, kind)
                    }
                case .openEnded(let kind):
                    carve.phase = .openEnded(kind)
                }

            case .footer(let from):
                guard let footer = carve.signature.footer else { carve.phase = .openEnded(.limit); continue }
                let signature = carve.signature
                let bound = min(carve.claimLimit, carve.maxEnd)
                let need = Int64(context.final ? footer.count : signature.footerReach)
                let searchEnd = min(limit, context.end - need + 1)
                var cursor = max(from, context.start)
                var found: Int64?
                while cursor < searchEnd, let match = context.firstMatch(footer, from: cursor, before: searchEnd) {
                    cursor = match + 1
                    switch context.footerEnd(signature, at: match, fileStart: carve.start) {
                    case .notThisFile:
                        continue
                    case .truncated:
                        // The footer record runs past the end of the extent.
                        feedEntropy(&carve, upTo: context.end, context)
                        return cut(carve, at: context.end, .extentEnd)
                    case .overflow:
                        feedEntropy(&carve, upTo: min(match, bound), context)
                        return Ended(carve: carve, end: min(match, bound), cut: .inconsistent)
                    case .end(let end):
                        if end > bound {
                            feedEntropy(&carve, upTo: min(bound, context.end), context)
                            return closeFooterSearch(carve, at: bound)
                        }
                        if signature.footerMode == .first { found = end } else { carve.lastFooterEnd = end }
                    }
                    if found != nil { break }
                }
                if let found {
                    feedEntropy(&carve, upTo: min(found, context.end), context)
                    carve.phase = .ending(found, .validated)
                    continue
                }
                carve.phase = .footer(max(from, searchEnd))
                feedEntropy(&carve, upTo: min(limit, bound, context.end), context)
                if bound <= limit { return closeFooterSearch(carve, at: bound) }
                return nil
            }
        }
    }

    /// Feeds a JPEG carve's entropy decoder the scan data up to `end`.
    private func feedEntropy(_ carve: inout OpenCarve, upTo end: Int64, _ context: Window) {
        guard carve.jpeg != nil else { return }
        carve.jpeg?.feed(upTo: end, context, sectorSize: Int64(limits.sectorSize),
                         maxBreaks: limits.reassembleFragmentedJPEGs ? limits.maxJoinBreaks : 0)
    }

    /// A footer-terminated carve reached its claim or size bound: it ends at the last footer seen,
    /// or is cut at the bound.
    private func closeFooterSearch(_ carve: OpenCarve, at bound: Int64) -> Ended {
        if let end = carve.lastFooterEnd { return Ended(carve: carve, end: end, cut: .validated) }
        return Ended(carve: carve, end: bound, cut: bound == carve.claimLimit && carve.claimLimit < carve.maxEnd ? .claimed : .limit)
    }

    /// Cuts an open carve at `position` because something outside its own structure ended it.
    private func cut(_ carve: OpenCarve, at position: Int64, _ cut: Cut) -> Ended {
        if let end = carve.lastFooterEnd { return Ended(carve: carve, end: end, cut: .validated) }
        // A carve whose own size information was inconsistent stays reported that way.
        let kind: Cut = if case .openEnded(.inconsistent) = carve.phase { .inconsistent } else { cut }
        return Ended(carve: carve, end: min(position, carve.claimLimit, carve.maxEnd), cut: kind)
    }

    // MARK: Emission

    private func finalize(_ item: Ended) async throws {
        let carve = item.carve
        if let join = item.join { return try await emitJoined(carve, join) }
        let size = item.end - carve.start
        guard size > 0 else { return }
        guard emittedCount < limits.maxCarvedFiles else { hitFileLimit = true; return }
        // A size claim this large usually means a fragmented file or a garbage field: the bytes
        // at the claimed end are unlikely to be this file's.
        let cut: Cut = item.cut == .validated && carve.sizeDerived && size > carve.trustedMax ? .untrusted : item.cut
        let signature = carve.signature
        let base = "\(signature.id)-\(String(format: "%012llx", carve.start))"
        var name = "\(base).\(signature.extension)"
        var sequence = 2
        while usedNames.contains(name) { name = "\(base)-\(sequence).\(signature.extension)"; sequence += 1 }
        usedNames.insert(name)
        let file = RecoveredFile(
            name: name, path: "/Reconstructed/\(signature.category.displayName)/\(name)", sizeBytes: size,
            modified: nil, isDeleted: false,
            sourceMetadata: SourceMetadata(filesystem: .carved, volumeOffset: extentStart, recordOffset: carve.start,
                                           allocationStart: UInt64(carve.start), contiguous: true, rawRecord: carve.headerBytes),
            content: .runs([DataRun(deviceOffset: carve.start, length: size)]),
            recoveryMethod: .carved, isPartial: cut.partial, overwriteConfidence: cut.overwrite)
        emittedCount += 1
        try await emit(file)
    }

    /// Emits a JPEG reassembled from two fragments. Two runs make it Low confidence (AD-7), and the
    /// overwrite estimate says the join is inferred, not recorded anywhere on disk.
    private func emitJoined(_ carve: OpenCarve, _ join: JPEGJoin) async throws {
        let first = join.breakAt - carve.start, second = join.end - join.resumeAt
        guard first >= 0, second > 0 else { return }
        guard emittedCount < limits.maxCarvedFiles else { hitFileLimit = true; return }
        let signature = carve.signature
        let base = "\(signature.id)-\(String(format: "%012llx", carve.start))"
        var name = "\(base).\(signature.extension)"
        var sequence = 2
        while usedNames.contains(name) { name = "\(base)-\(sequence).\(signature.extension)"; sequence += 1 }
        usedNames.insert(name)
        var runs: [DataRun] = []
        if first > 0 { runs.append(DataRun(deviceOffset: carve.start, length: first)) }
        runs.append(DataRun(deviceOffset: join.resumeAt, length: second))
        let file = RecoveredFile(
            name: name, path: "/Reconstructed/\(signature.category.displayName)/\(name)", sizeBytes: first + second,
            modified: nil, isDeleted: false,
            sourceMetadata: SourceMetadata(filesystem: .carved, volumeOffset: extentStart, recordOffset: carve.start,
                                           allocationStart: UInt64(carve.start), contiguous: false, rawRecord: carve.headerBytes),
            content: .runs(runs), recoveryMethod: .carved, isPartial: false, overwriteConfidence: Self.joinedOverwrite)
        emittedCount += 1
        try await emit(file)
    }

    /// Overwrite estimate reported for a reassembled JPEG.
    static let joinedOverwrite = 0.3

    // MARK: Claimed runs

    func claimedRange(containing offset: Int64) -> Range<Int64>? {
        var low = 0, high = claimed.count
        while low < high {
            let middle = (low + high) / 2
            if claimed[middle].upperBound <= offset { low = middle + 1 } else { high = middle }
        }
        guard low < claimed.count, claimed[low].contains(offset) else { return nil }
        return claimed[low]
    }

    func nextClaimStart(after offset: Int64) -> Int64 {
        var low = 0, high = claimed.count
        while low < high {
            let middle = (low + high) / 2
            if claimed[middle].lowerBound <= offset { low = middle + 1 } else { high = middle }
        }
        return low < claimed.count ? claimed[low].lowerBound : Int64.max
    }

    func alignUp(_ offset: Int64) -> Int64 {
        let sector = Int64(limits.sectorSize)
        let remainder = offset % sector
        guard remainder != 0 else { return offset }
        let (aligned, overflow) = offset.addingReportingOverflow(sector - remainder)
        return overflow ? Int64.max : aligned
    }
}

/// A first-byte dispatch table over a signature library. For each distinct `headerOffset`, a
/// 256-entry table says which signatures have a header pattern whose first byte (under its mask)
/// equals that byte. A signature can only match at a position if its entry for the byte at
/// `position + headerOffset` is set; `Window.headerMatches` still makes the full test. Signatures
/// with an empty header pattern (which `matches` accepts anywhere in the window) are always
/// candidates.
struct HeaderDispatch: Sendable {
    struct Group: Sendable {
        let offset: Int64
        /// `words` bitset words per byte value, byte-major.
        let table: [UInt64]
    }
    let groups: [Group]
    let words: Int
    /// Signatures to test at every position.
    let always: [UInt64]

    init(_ signatures: [FileSignature]) {
        let words = max(1, (signatures.count + 63) / 64)
        var always = [UInt64](repeating: 0, count: words)
        var tables: [Int: [UInt64]] = [:]
        for (index, signature) in signatures.enumerated() {
            let word = index / 64, bit = UInt64(1) << UInt64(index % 64)
            for pattern in signature.headers {
                guard pattern.count > 0 else { always[word] |= bit; continue }
                var table = tables[signature.headerOffset] ?? [UInt64](repeating: 0, count: 256 * words)
                for byte in 0..<256 where UInt8(byte) & pattern.mask[0] == pattern.bytes[0] {
                    table[byte * words + word] |= bit
                }
                tables[signature.headerOffset] = table
            }
        }
        self.words = words
        self.always = always
        self.groups = tables.keys.sorted().map { Group(offset: Int64($0), table: tables[$0]!) }
    }

    /// Candidate bits of word `word` at `position`.
    @inline(__always)
    private func bits(_ context: Window, at position: Int64, word: Int) -> UInt64 {
        var bits = always[word]
        for group in groups {
            let at = position + group.offset
            guard at >= context.start, at < context.end else { continue }
            bits |= group.table[Int(context.buffer[Int(at - context.start)]) * words + word]
        }
        return bits
    }

    /// False when no signature can match at `position`.
    @inline(__always)
    func mayMatch(_ context: Window, at position: Int64) -> Bool {
        for word in 0..<words where bits(context, at: position, word: word) != 0 { return true }
        return false
    }

    /// Calls `body` with each candidate signature index, ascending.
    func forEachCandidate(_ context: Window, at position: Int64, _ body: (Int) -> Void) {
        for word in 0..<words {
            var bits = bits(context, at: position, word: word)
            while bits != 0 {
                let bit = bits.trailingZeroBitCount
                body(word * 64 + bit)
                bits &= bits - 1
            }
        }
    }
}

/// One window of bytes with its device offsets, for the synchronous matching helpers and the
/// structure walkers.
struct Window {
    let buffer: UnsafeRawBufferPointer
    let start: Int64
    let end: Int64
    let final: Bool

    func index(_ offset: Int64) -> Int { Int(offset - start) }

    /// The byte at `offset`, or nil outside the window.
    func byte(at offset: Int64) -> UInt8? {
        guard offset >= start, offset < end else { return nil }
        return buffer[index(offset)]
    }

    func matches(_ pattern: FileSignature.Pattern, at offset: Int64) -> Bool {
        guard offset >= start, offset + Int64(pattern.count) <= end else { return false }
        let base = index(offset)
        for position in 0..<pattern.count where (buffer[base + position] & pattern.mask[position]) != pattern.bytes[position] {
            return false
        }
        return true
    }

    func headerMatches(_ signature: FileSignature, at offset: Int64) -> Bool {
        let at = offset + Int64(signature.headerOffset)
        return signature.headers.contains { matches($0, at: at) }
    }

    /// The signature's structural header check, if it declares one.
    func validates(_ signature: FileSignature, at offset: Int64) -> Bool {
        switch signature.validation {
        case nil: return true
        case .mpegFrames:
            // Two consecutive frames: the first header's frame length must land exactly on a
            // second valid header of the same version, layer and sample rate.
            guard let first = mpegFrame(at: offset) else { return false }
            guard let second = mpegFrame(at: offset + Int64(first.length)) else { return false }
            return first.key == second.key
        }
    }

    /// Parses an MPEG audio frame header: its frame length in bytes and a key of the fields
    /// that stay constant within a stream (version, layer, sample rate).
    func mpegFrame(at offset: Int64) -> (length: Int, key: Int)? {
        guard offset >= start, offset + 4 <= end else { return nil }
        let base = index(offset)
        let b1 = buffer[base + 1], b2 = buffer[base + 2], b3 = buffer[base + 3]
        guard buffer[base] == 0xFF, b1 & 0xE0 == 0xE0 else { return nil }
        let version = Int(b1 >> 3 & 3)       // 0: MPEG-2.5, 1: reserved, 2: MPEG-2, 3: MPEG-1
        let layer = Int(b1 >> 1 & 3)         // 1: III, 2: II, 3: I, 0: reserved
        let bitrateIndex = Int(b2 >> 4)
        let rateIndex = Int(b2 >> 2 & 3)
        let padding = Int(b2 >> 1 & 1)
        guard version != 1, layer != 0, (1...14).contains(bitrateIndex), rateIndex != 3, b3 & 3 != 2 else { return nil }
        let mpeg1 = version == 3
        let kbps: [Int] = switch (mpeg1, layer) {
        case (true, 3): [32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448]
        case (true, 2): [32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384]
        case (true, _): [32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]
        case (false, 3): [32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256]
        case (false, _): [8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160]
        }
        let rates = [44100, 48000, 32000]
        let rate = rates[rateIndex] >> (version == 3 ? 0 : version == 2 ? 1 : 2)
        let bitrate = kbps[bitrateIndex - 1] * 1000
        let length: Int = switch layer {
        case 3: (12 * bitrate / rate + padding) * 4
        case 2: 144 * bitrate / rate + padding
        default: (mpeg1 ? 144 : 72) * bitrate / rate + padding
        }
        guard length >= 4 else { return nil }
        return (length, version << 4 | layer << 2 | rateIndex)
    }

    enum GIFStep {
        case next(Int64, SignatureCarver.OpenCarve.GIFState)
        case trailer(Int64)
        case invalid
    }

    /// One step of the GIF block walk at `offset`; nil when the bytes it needs aren't in the window.
    func gifStep(at offset: Int64, _ state: SignatureCarver.OpenCarve.GIFState) -> GIFStep? {
        func colorTable(_ packed: UInt8) -> Int64 { packed & 0x80 != 0 ? 3 << (Int64(packed & 7) + 1) : 0 }
        switch state {
        case .screen:
            // Logical screen descriptor: width, height, packed, background, aspect.
            guard let packed = byte(at: offset + 4), offset + 7 <= end else { return nil }
            return .next(offset + 7 + colorTable(packed), .block)
        case .block:
            guard let introducer = byte(at: offset) else { return nil }
            switch introducer {
            case 0x3B: return .trailer(offset + 1)
            case 0x21:
                guard offset + 2 <= end else { return nil }
                return .next(offset + 2, .subBlocks)
            case 0x2C:
                // Image descriptor: left, top, width, height, packed.
                guard let packed = byte(at: offset + 9) else { return nil }
                return .next(offset + 10 + colorTable(packed), .lzwCode)
            default: return .invalid
            }
        case .lzwCode:
            guard let size = byte(at: offset) else { return nil }
            return (1...12).contains(size) ? .next(offset + 1, .subBlocks) : .invalid
        case .subBlocks:
            guard let size = byte(at: offset) else { return nil }
            return size == 0 ? .next(offset + 1, .block) : .next(offset + 1 + Int64(size), .subBlocks)
        }
    }

    /// Device offset of the first match of `pattern` starting in `from..<before`, or nil.
    func firstMatch(_ pattern: FileSignature.Pattern, from: Int64, before: Int64) -> Int64? {
        guard pattern.count > 0, from >= start, before <= end else { return nil }
        var position = index(from)
        let stop = index(before)
        guard let base = buffer.baseAddress else { return nil }
        if pattern.mask[0] == 0xFF {
            while position < stop {
                guard let hit = memchr(base + position, Int32(pattern.bytes[0]), stop - position) else { return nil }
                let candidate = base.distance(to: UnsafeRawPointer(hit))
                if matches(pattern, at: start + Int64(candidate)) { return start + Int64(candidate) }
                position = candidate + 1
            }
        } else {
            while position < stop {
                if matches(pattern, at: start + Int64(position)) { return start + Int64(position) }
                position += 1
            }
        }
        return nil
    }

    enum FooterEnd {
        case end(Int64)
        /// The footer belongs to another file (failed `footerOffsetCheck`, or an impossible length).
        case notThisFile
        /// The footer record needs bytes past the end of the extent.
        case truncated
        case overflow
    }

    /// Where a footer matched at `match` ends the file that starts at `fileStart`.
    func footerEnd(_ signature: FileSignature, at match: Int64, fileStart: Int64) -> FooterEnd {
        guard let footer = signature.footer else { return .notThisFile }
        if match + Int64(signature.footerReach) > end { return final ? .truncated : .notThisFile }
        if !signature.footerOffsetCheck.isEmpty {
            var sum: Int64 = 0
            for field in signature.footerOffsetCheck {
                guard let value = readSize(field, at: match) else { return .notThisFile }
                let (total, overflow) = sum.addingReportingOverflow(value)
                guard !overflow else { return .notThisFile }
                sum = total
            }
            guard sum == match - fileStart else { return .notThisFile }
        }
        guard let field = signature.footerSizeField else {
            let (end, overflow) = match.addingReportingOverflow(Int64(signature.footerLength))
            return overflow ? .overflow : .end(end)
        }
        guard let length = readSize(field, at: match) else { return .overflow }
        guard length >= Int64(footer.count) else { return .notThisFile }
        let (end, overflow) = match.addingReportingOverflow(length)
        return overflow ? .overflow : .end(end)
    }

    func readUInt(at offset: Int64, width: Int, endian: FileSignature.Endian) -> UInt64? {
        guard offset >= start, offset + Int64(width) <= end else { return nil }
        let base = index(offset)
        var value: UInt64 = 0
        for position in 0..<width {
            let byte = UInt64(buffer[base + position])
            value = endian == .big ? (value << 8) | byte : value | (byte << (8 * UInt64(position)))
        }
        return value
    }

    /// `value * scale + adjust` read relative to `base`; nil when unreadable or overflowing.
    func readSize(_ field: FileSignature.SizeField, at base: Int64, raw override: UInt64? = nil) -> Int64? {
        guard let raw = override ?? readUInt(at: base + Int64(field.offset), width: field.width, endian: field.endian),
              var value = Int64(exactly: raw) else { return nil }
        if let scale = field.scale {
            guard let rawScale = readUInt(at: base + Int64(scale.offset), width: scale.width, endian: scale.endian),
                  var factor = Int64(exactly: rawScale) else { return nil }
            if factor == 1, let oneMeans = scale.oneMeans { factor = oneMeans }
            let (product, overflow) = value.multipliedReportingOverflow(by: factor)
            guard !overflow else { return nil }
            value = product
        }
        let (sum, overflow) = value.addingReportingOverflow(field.adjust)
        return overflow ? nil : sum
    }

    func rawRecordSize(_ segments: FileSignature.Segments, at record: Int64) -> UInt64? {
        readUInt(at: record + Int64(segments.size.offset), width: segments.size.width, endian: segments.size.endian)
    }

    func recordSize(_ segments: FileSignature.Segments, at record: Int64) -> Int64? {
        guard let raw = rawRecordSize(segments, at: record) else { return nil }
        if let large = segments.largeSize, Int64(exactly: raw) == large.ifValue {
            guard let wide = readUInt(at: record + Int64(large.offset), width: large.width, endian: segments.size.endian) else { return nil }
            return readSize(segments.size, at: record, raw: wide)
        }
        return readSize(segments.size, at: record, raw: raw)
    }

    func recordTypeValid(_ segments: FileSignature.Segments, at record: Int64) -> Bool {
        let type = record + Int64(segments.typeOffset)
        if let pattern = segments.typeMatch, !matches(pattern, at: type) { return false }
        if segments.typePrintable {
            guard type >= start, type + Int64(segments.typeLength) <= end else { return false }
            let base = index(type)
            for position in 0..<segments.typeLength where buffer[base + position] < 0x20 || buffer[base + position] > 0x7E { return false }
        }
        return true
    }
}
