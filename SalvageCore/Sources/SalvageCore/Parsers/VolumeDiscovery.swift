import Foundation

extension Data {
    func number(_ offset: Int, _ width: Int) throws -> UInt64 {
        guard offset >= 0, width > 0, width <= 8, offset <= count, width <= count - offset else {
            throw ScanError.malformed("Truncated structure.")
        }
        // One unaligned load for the common widths; same value as summing the bytes little-endian.
        return withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> UInt64 in
            switch width {
            case 1: return UInt64(buffer[offset])
            case 2: return UInt64(UInt16(littleEndian: buffer.loadUnaligned(fromByteOffset: offset, as: UInt16.self)))
            case 4: return UInt64(UInt32(littleEndian: buffer.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
            case 8: return UInt64(littleEndian: buffer.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
            default:
                var value: UInt64 = 0
                for index in 0..<width { value |= UInt64(buffer[offset + index]) << (index * 8) }
                return value
            }
        }
    }
    /// Big-endian counterpart of `number`, for HFS+ headers.
    func bigEndian(_ offset: Int, _ width: Int) throws -> UInt64 {
        guard offset >= 0, width > 0, width <= 8, offset <= count, width <= count - offset else {
            throw ScanError.malformed("Truncated structure.")
        }
        return (0..<width).reduce(0) { $0 << 8 | UInt64(self[startIndex + offset + $1]) }
    }
}

func checkedAdd(_ a: Int64, _ b: Int64) throws -> Int64 {
    let (value, overflow) = a.addingReportingOverflow(b)
    guard !overflow, value >= 0 else { throw ScanError.malformed("Offset overflow.") }
    return value
}
func checkedMultiply(_ a: Int64, _ b: Int64) throws -> Int64 {
    let (value, overflow) = a.multipliedReportingOverflow(by: b)
    guard !overflow, value >= 0 else { throw ScanError.malformed("Size overflow.") }
    return value
}
func signed(_ value: UInt64) throws -> Int64 {
    guard value <= UInt64(Int64.max) else { throw ScanError.malformed("Size overflow.") }
    return Int64(value)
}

struct VolumeExtent: Sendable {
    let offset: Int64
    let length: Int64
    var format: VolumeFormat = .fat
    /// A filesystem found in unallocated space (FR-9). It is read in place like any other extent;
    /// nothing is ever written back to the partition table.
    var isLost: Bool = false
    /// Plain-language name of the signature that revealed a lost volume (e.g. "exFAT"); nil means
    /// `format.displayName`.
    var formatName: String? = nil
}

/// Counts the bytes requested through a reader, so the probe byte budget measures real reads.
final class ByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64 = 0
    func add(_ count: Int) { lock.withLock { value += Int64(count) } }
    var bytes: Int64 { lock.withLock { value } }
}
struct CountingBlockReader: BlockReader {
    let base: any BlockReader
    let counter: ByteCounter
    var logicalBlockSize: Int { base.logicalBlockSize }
    var sizeBytes: Int64 { base.sizeBytes }
    func read(at offset: Int64, count: Int) async throws -> Data {
        counter.add(count)
        return try await base.read(at: offset, count: count)
    }
}

struct VolumeDiscovery {
    let reader: any BlockReader
    /// Bounds for the unallocated-space search. `maxProbes` is sized so a 2 TiB device is walked end
    /// to end (16,384 fine probes in the first 64 MiB, 65,536 at 1 MiB across the first 64 GiB, then
    /// one per 8 MiB: about 336k for 2 TiB); each probe is one 512-byte read, so the byte cap
    /// (which counts every header read exactly) mostly guards the follow-up reads after a hit.
    var maxProbes = 1 << 19
    var maxProbeBytes: Int64 = 512 << 20
    /// Consecutive probes that failed with an I/O error before the search gives up on the device.
    var maxConsecutiveProbeFailures = 64
    /// Lost volumes reported per device; later hits are dropped and a warning recorded.
    var maxCandidates = 256
    /// A header claiming less than this is implausible as a volume and is dropped.
    static let minimumVolumeLength: Int64 = 64 << 10
    /// Candidate offsets. Pass 1 (fine): 4 KiB steps across the first 64 MiB of the device and the
    /// first MiB after each known or found extent, every gap's own start, and the classic
    /// first-partition sectors (GPT's first usable LBA 34, CHS's sector 63) that no alignment
    /// reaches. Pass 2 (coarse): every MiB across the first 64 GiB, every 8 MiB beyond.
    static let fineStride: Int64 = 4096, coarseStride: Int64 = 1 << 20, sparseStride: Int64 = 8 << 20
    static let fineRegion: Int64 = 64 << 20, coarseRegion: Int64 = 64 << 30
    static let classicStarts: [Int64] = [34 * 512, 63 * 512]

    /// What discovery found, plus how far the lost-partition search was trusted.
    struct Result: Sendable {
        var extents: [VolumeExtent]
        /// Plain-language reasons the result may be incomplete (a damaged table that was ignored,
        /// a search cut short); empty when there is nothing to say.
        var warnings: [String] = []
        /// True when the unallocated-space search stopped before covering the device (budget,
        /// repeated read failures, or the candidate cap); `searchedBytes` says how far it got.
        var probesTruncated = false
        var searchedBytes: Int64? = nil
        /// Probes skipped because the device could not be read there.
        var failedProbes = 0
    }

    func read(_ offset: Int64, _ count: Int) async throws -> Data {
        try Task.checkCancellation()
        guard offset >= 0, count >= 0, offset <= reader.sizeBytes,
              Int64(count) <= reader.sizeBytes - offset else { throw ScanError.malformed("Read outside device.") }
        var data = Data()
        while data.count < count {
            try Task.checkCancellation()
            let chunkCount = min(1024 * 1024, count - data.count)
            let chunk = try await reader.read(at: checkedAdd(offset, Int64(data.count)), count: chunkCount)
            guard chunk.count == chunkCount else { throw ScanError.malformed("Truncated device.") }
            data.append(chunk)
        }
        return data
    }
    func discover() async throws -> Result {
        guard reader.logicalBlockSize == 512 else {
            throw ScanError.malformed("Only devices with 512-byte logical sectors are supported in this version.")
        }
        let boot = try await read(0, 512)
        if let format = try await format(boot: boot, at: 0, length: reader.sizeBytes) {
            guard format.isScannable else { throw ScanError.unsupportedFilesystem }
            return Result(extents: [VolumeExtent(offset: 0, length: reader.sizeBytes, format: format)])
        }
        // Every table entry is a known extent, supported or not: the unallocated-space search never
        // probes inside one, so a mapped partition always wins over a stale header within it.
        var known: [VolumeExtent] = []
        var warnings: [String] = []
        if try boot.number(510, 2) == 0xaa55 {
            do { known = try await partitions(boot) }
            catch ScanError.malformed(let reason) {
                // A damaged table (bad GPT checksum, overlapping or out-of-range entries, a map this
                // version can't read) is treated as absent: nothing is known, so the whole device is
                // searched for signatures instead of failing before any volume is looked at.
                warnings.append("The partition table is damaged and was ignored (\(reason)) The whole device was searched for filesystem signatures instead.")
            }
        }
        var supported: [VolumeExtent] = []
        for extent in known {
            if let format = try await format(at: extent.offset, length: extent.length), format.isScannable {
                supported.append(VolumeExtent(offset: extent.offset, length: extent.length, format: format))
            }
        }
        let search = try await lostVolumes(excluding: known)
        var result = Result(extents: (supported + search.found).sorted { $0.offset < $1.offset },
                            warnings: warnings + search.warnings, probesTruncated: search.truncated,
                            searchedBytes: search.searchedBytes, failedProbes: search.failedProbes)
        if result.extents.isEmpty {
            // A table whose volumes are all recognized but unsupported keeps the honest "not supported"
            // answer. With no table and no signature anywhere, one raw extent lets the sweep and the
            // carver still run, so completion reports carved files or none, never a silent skip.
            guard known.isEmpty else { throw ScanError.unsupportedFilesystem }
            result.extents = [VolumeExtent(offset: 0, length: reader.sizeBytes, format: .raw)]
        }
        return result
    }

    /// MBR (or protective-MBR + GPT) entries as bare extents, sorted and non-overlapping.
    func partitions(_ boot: Data) async throws -> [VolumeExtent] {
        var extents: [VolumeExtent] = []
        var protective = false
        for n in 0..<4 {
            let p = 446 + n * 16
            let type = try boot.number(p + 4, 1)
            if type == 0 { continue }
            if type == 0xee { protective = true; continue }
            guard ![0x05, 0x0f, 0x85].contains(type) else { throw ScanError.malformed("Extended partitions aren't supported.") }
            let start = try signed(boot.number(p + 8, 4))
            let sectors = try signed(boot.number(p + 12, 4))
            extents.append(try extent(start: start, sectors: sectors))
        }
        if protective {
            guard extents.isEmpty else { throw ScanError.malformed("Hybrid partition maps aren't supported.") }
            extents = try await gpt()
        }
        let sorted = extents.sorted { $0.offset < $1.offset }
        for n in sorted.indices.dropFirst() {
            guard try checkedAdd(sorted[n-1].offset, sorted[n-1].length) <= sorted[n].offset else {
                throw ScanError.malformed("Overlapping partitions.")
            }
        }
        return sorted
    }

    // MARK: Unallocated space (FR-9)

    /// Unallocated byte ranges: the device minus `known` (sorted, non-overlapping, within the device).
    static func gaps(in sizeBytes: Int64, excluding known: [VolumeExtent]) -> [Range<Int64>] {
        var gaps: [Range<Int64>] = [], cursor: Int64 = 0
        for extent in known {
            if extent.offset > cursor { gaps.append(cursor..<extent.offset) }
            cursor = max(cursor, extent.offset + extent.length)
        }
        if cursor < sizeBytes { gaps.append(cursor..<sizeBytes) }
        return gaps
    }

    enum Pass { case fine, coarse }
    enum Stop: Equatable { case budget, failures, candidates }

    struct ProbeState {
        /// Found lost extents, sorted by offset and disjoint, so containment and overlap checks are
        /// binary searches.
        private(set) var found: [VolumeExtent] = []
        /// Offsets the fine pass probed, so the coarse pass skips them. Only fine-pass offsets go in
        /// (at most the first 64 MiB at 4 KiB plus a MiB per extent); the coarse pass never repeats.
        var probed: Set<Int64> = []
        var probes = 0
        var bytes: Int64 = 0
        var failedProbes = 0
        var consecutiveFailures = 0
        var stop: Stop?
        var stoppedAt: Int64?

        /// Index of the first found extent starting at or after `offset`.
        func index(startingAtOrAfter offset: Int64) -> Int {
            var low = 0, high = found.count
            while low < high {
                let middle = (low + high) / 2
                if found[middle].offset < offset { low = middle + 1 } else { high = middle }
            }
            return low
        }
        func hit(containing offset: Int64) -> VolumeExtent? {
            let index = index(startingAtOrAfter: offset)
            if index < found.count, found[index].offset == offset { return found[index] }
            if index > 0, offset < found[index - 1].offset + found[index - 1].length { return found[index - 1] }
            return nil
        }
        func overlaps(_ range: Range<Int64>) -> Bool {
            let index = index(startingAtOrAfter: range.lowerBound)
            if index < found.count, found[index].offset < range.upperBound { return true }
            if index > 0, range.lowerBound < found[index - 1].offset + found[index - 1].length { return true }
            return false
        }
        mutating func insert(_ extent: VolumeExtent) {
            found.insert(extent, at: index(startingAtOrAfter: extent.offset))
        }
    }

    struct Search {
        var found: [VolumeExtent]
        var warnings: [String] = []
        var truncated = false
        var searchedBytes: Int64? = nil
        var failedProbes = 0
    }

    /// Filesystem headers in unallocated space. Two bounded passes in device order: the fine pass
    /// (every gap's start, the classic first-partition sectors, 4 KiB steps across the first 64 MiB
    /// and across the first MiB after each known or found extent) spends budget before the coarse
    /// walk (every MiB to 64 GiB, every 8 MiB beyond). A hit's span (from its own header geometry)
    /// is skipped, and a candidate that would run into a known extent or an earlier hit is dropped:
    /// known extents and earlier hits win. An unreadable probe is skipped and counted; too many in a
    /// row, an exhausted budget, or the candidate cap end the search early and say so.
    func lostVolumes(excluding known: [VolumeExtent]) async throws -> Search {
        let gaps = Self.gaps(in: reader.sizeBytes, excluding: known)
        let counter = ByteCounter()
        let probing = VolumeDiscovery(reader: CountingBlockReader(base: reader, counter: counter))
        // `discover()` has already checked offset 0 against the whole device.
        var state = ProbeState(probed: [0])
        passes: for pass in [Pass.fine, .coarse] {
            for gap in gaps {
                var offset = gap.lowerBound
                var fineUntil = pass == .fine ? gap.lowerBound + Self.coarseStride : gap.lowerBound
                while offset < gap.upperBound {
                    try Task.checkCancellation()
                    if state.probes >= maxProbes || state.bytes >= maxProbeBytes { state.stop = .budget }
                    if state.found.count >= maxCandidates { state.stop = .candidates }
                    if state.stop != nil { state.stoppedAt = offset; break passes }
                    if let hit = state.hit(containing: offset) {
                        // Probe finely right after a found volume, as after a known extent.
                        offset = hit.offset + hit.length; fineUntil = offset + Self.coarseStride; continue
                    }
                    if pass == .fine, offset >= Self.fineRegion, offset >= fineUntil { break }
                    if !state.probed.contains(offset) {
                        if pass == .fine { state.probed.insert(offset) }
                        if let extent = try await probe(at: offset, gapEnd: gap.upperBound, state: &state, probing: probing, counter: counter) {
                            state.insert(extent); continue
                        }
                    }
                    guard let next = Self.nextCandidate(after: offset, fineUntil: fineUntil, pass: pass) else { break }
                    offset = next
                }
            }
        }
        var search = Search(found: state.found, failedProbes: state.failedProbes)
        if let stop = state.stop, let at = state.stoppedAt {
            search.truncated = true
            search.searchedBytes = at
            let reached = ByteCountFormatter.string(fromByteCount: at, countStyle: .file)
            switch stop {
            case .budget: search.warnings.append("The search for lost partitions was limited to the first \(reached) of the device.")
            case .failures: search.warnings.append("The search for lost partitions stopped at \(reached): \(maxConsecutiveProbeFailures) consecutive reads failed there.")
            case .candidates: search.warnings.append("The search for lost partitions stopped at \(reached) after \(maxCandidates) candidates.")
            }
        } else if state.failedProbes > 0 {
            search.warnings.append("\(state.failedProbes) unreadable spots were skipped while searching for lost partitions.")
        }
        return search
    }

    /// The next candidate offset after `offset`, or nil when the pass has none left in this gap.
    static func nextCandidate(after offset: Int64, fineUntil: Int64, pass: Pass) -> Int64? {
        func aligned(_ stride: Int64) -> Int64 { (offset / stride + 1) * stride }
        switch pass {
        case .fine:
            var next = aligned(fineStride)
            if let classic = classicStarts.first(where: { $0 > offset }) { next = min(next, classic) }
            return next
        case .coarse:
            var next = offset < coarseRegion ? aligned(coarseStride) : aligned(sparseStride)
            if offset + 1 < fineUntil { next = min(next, aligned(fineStride)) }
            return next
        }
    }

    /// One header probe. A hit returns a lost extent whose length comes from the header and fits the
    /// gap (clamped to the device end); a header with implausible geometry (zero, overflowing or
    /// under `minimumVolumeLength`), or one that overlaps a known extent or an earlier hit, is
    /// dropped. A read failure skips the probe: the device is unreadable there, which says nothing
    /// about the rest of it, but `maxConsecutiveProbeFailures` in a row ends the search.
    func probe(at offset: Int64, gapEnd: Int64, state: inout ProbeState,
               probing: VolumeDiscovery, counter: ByteCounter) async throws -> VolumeExtent? {
        state.probes += 1
        defer { state.bytes = counter.bytes }
        let remaining = gapEnd - offset
        guard remaining >= 512 else { return nil }
        let header: (format: VolumeFormat, boot: Data, length: Int64)?
        do { header = try await probing.header(at: offset, remaining: remaining) }
        catch ScanError.io {
            state.failedProbes += 1; state.consecutiveFailures += 1
            if state.consecutiveFailures >= maxConsecutiveProbeFailures { state.stop = .failures }
            return nil
        }
        state.consecutiveFailures = 0
        guard let header, header.length > 0 else { return nil }
        // A header running past the device end is clamped (a short image or an overwritten tail);
        // one running into a known extent is dropped, since the mapped partition wins. Header
        // values are untrusted: an end that overflows is dropped, never computed.
        let (declaredEnd, overflow) = offset.addingReportingOverflow(header.length)
        guard !overflow else { return nil }
        let end = min(declaredEnd, reader.sizeBytes)
        guard end <= gapEnd, end - offset >= Self.minimumVolumeLength else { return nil }
        guard !state.overlaps(offset..<end) else { return nil }
        let boot = header.boot
        let name = header.format == .fat ? (String(decoding: boot[3..<11], as: UTF8.self) == "EXFAT   " ? "exFAT" : "FAT32") : header.format.displayName
        return VolumeExtent(offset: offset, length: end - offset, format: header.format, isLost: true, formatName: name)
    }

    /// The signature at `offset` and the length its header declares, or nil when there is no
    /// recognizable or well-formed header there. I/O errors and cancellation propagate.
    func header(at offset: Int64, remaining: Int64) async throws -> (format: VolumeFormat, boot: Data, length: Int64)? {
        do {
            let boot = try await read(offset, 512)
            guard let format = try await format(boot: boot, at: offset, length: remaining),
                  let length = try await volumeLength(format: format, boot: boot, at: offset) else { return nil }
            return (format, boot, length)
        } catch ScanError.malformed { return nil } catch ScanError.unsupportedFilesystem { return nil }
    }

    /// A volume's byte length from its own header only: FAT BPB total sectors, NTFS total sectors
    /// (plus the backup boot sector), ext blocks count × block size, APFS container block count ×
    /// block size, HFS+ total blocks × block size. Nil when the header carries no size (a bare
    /// APFS volume superblock, a raw region). Not clamped; the caller fits it to the device.
    func volumeLength(format: VolumeFormat, at offset: Int64) async throws -> Int64? {
        try await volumeLength(format: format, boot: read(offset, 512), at: offset)
    }
    func volumeLength(format: VolumeFormat, boot: Data, at offset: Int64) async throws -> Int64? {
        switch format {
        case .fat:
            if String(decoding: boot[3..<11], as: UTF8.self) == "EXFAT   " {
                let shift = try boot.number(108, 1)
                guard (9...12).contains(shift) else { throw ScanError.malformed("Unsupported exFAT sector size.") }
                return try checkedMultiply(signed(boot.number(72, 8)), Int64(1) << shift)
            }
            let sector = try signed(boot.number(11, 2))
            var total = try signed(boot.number(32, 4))
            if total == 0 { total = try signed(boot.number(19, 2)) }
            return try checkedMultiply(total, sector)
        case .ntfs:
            let sector = try signed(boot.number(11, 2))
            guard (512...4096).contains(sector), sector & (sector - 1) == 0 else { throw ScanError.malformed("Unsupported NTFS sector size.") }
            return try checkedMultiply(checkedAdd(signed(boot.number(0x28, 8)), 1), sector)
        case .apfs:
            guard String(decoding: boot[32..<36], as: UTF8.self) == "NXSB" else { return nil }
            let blockSize = try signed(boot.number(36, 4))
            guard (4096...65536).contains(blockSize), blockSize & (blockSize - 1) == 0 else { throw ScanError.malformed("Unsupported APFS block size.") }
            return try checkedMultiply(signed(boot.number(40, 8)), blockSize)
        case .ext:
            let sb = try await read(checkedAdd(offset, 1024), 1024)
            let logBlock = try sb.number(24, 4)
            guard logBlock <= 6 else { throw ScanError.malformed("Invalid ext block size.") }
            let wide = try sb.number(76, 4) >= 1 && sb.number(96, 4) & 0x80 != 0
            let blocks = try sb.number(4, 4) | (wide ? sb.number(336, 4) << 32 : 0)
            return try checkedMultiply(signed(blocks), Int64(1024) << logBlock)
        case .hfsPlus:
            let header = try await read(checkedAdd(offset, 1024), 512)
            return try checkedMultiply(signed(header.bigEndian(44, 4)), signed(header.bigEndian(40, 4)))
        case .raw:
            return nil
        }
    }

    /// Identifies a volume by its on-disk signature; the format's own parser validates the rest.
    func format(at offset: Int64, length: Int64) async throws -> VolumeFormat? {
        try await format(boot: read(offset, 512), at: offset, length: length)
    }
    func format(boot: Data, at offset: Int64, length: Int64) async throws -> VolumeFormat? {
        if isFAT(boot) { return .fat }
        if String(decoding: boot[3..<11], as: UTF8.self) == "NTFS    " { return .ntfs }
        // APFS: nx_superblock (container) or apfs_superblock (bare unlocked volume), magic at 32.
        let apfsMagic = String(decoding: boot[32..<36], as: UTF8.self)
        if apfsMagic == "NXSB" || apfsMagic == "APSB" { return .apfs }
        // ext superblock and the HFS+ volume header both sit 1024 bytes into the volume.
        guard length >= 2048 else { return nil }
        let block = try await read(checkedAdd(offset, 1024), 512)
        if try block.number(56, 2) == 0xef53 { return .ext }
        // HFS+ signature is big-endian "H+" (0x482B) or "HX" (HFSX, 0x4858).
        if block[0] == 0x48, block[1] == 0x2B || block[1] == 0x58 { return .hfsPlus }
        return nil
    }
    func isFAT(_ data: Data) -> Bool {
        guard data.count >= 90 else { return false }
        if String(decoding: data[3..<11], as: UTF8.self) == "EXFAT   " { return true }
        // The FAT label is informational. Identify a FAT32 BPB from its structure; geometry
        // validation derives the FAT type from the data-cluster count.
        return (try? data.number(11, 2)).map { [512, 1024, 2048, 4096].contains($0) } == true &&
            (try? data.number(13, 1)) != 0 && (try? data.number(14, 2)) != 0 &&
            (try? data.number(17, 2)) == 0 && (try? data.number(22, 2)) == 0 &&
            (try? data.number(36, 4)) != 0
    }
    func extent(start: Int64, sectors: Int64) throws -> VolumeExtent {
        let offset = try checkedMultiply(start, 512)
        let length = try checkedMultiply(sectors, 512)
        guard start > 0, sectors > 0, offset <= reader.sizeBytes, length <= reader.sizeBytes - offset else {
            throw ScanError.malformed("Partition outside device.")
        }
        return VolumeExtent(offset: offset, length: length)
    }
    func gpt() async throws -> [VolumeExtent] {
        let header = try await read(512, 512)
        guard String(decoding: header[0..<8], as: UTF8.self) == "EFI PART",
              try header.number(12, 4) >= 92, try header.number(12, 4) <= 512,
              try header.number(24, 8) == 1 else { throw ScanError.malformed("Invalid GPT header.") }
        let headerSize = Int(try header.number(12, 4))
        var checksumHeader = header.subdata(in: 0..<headerSize)
        checksumHeader.replaceSubrange(16..<20, with: [0, 0, 0, 0])
        guard UInt64(crc32(checksumHeader)) == (try header.number(16, 4)),
              try header.number(8, 4) == 0x10000, try header.number(20, 4) == 0,
              try header.number(32, 8) == UInt64(reader.sizeBytes / 512 - 1) else {
            throw ScanError.malformed("Invalid GPT header checksum or backup location.")
        }
        let first = try signed(header.number(40, 8)), last = try signed(header.number(48, 8))
        let tableLBA = try signed(header.number(72, 8))
        let count = try signed(header.number(80, 4)), stride = try signed(header.number(84, 4))
        guard first <= last, last < reader.sizeBytes / 512, count > 0, count <= 16384,
              stride >= 128, stride <= 4096, stride % 8 == 0, tableLBA >= 2 else {
            throw ScanError.malformed("Unsupported GPT geometry.")
        }
        let tableOffset = try checkedMultiply(tableLBA, 512)
        let tableSize = try checkedMultiply(count, stride)
        guard try checkedAdd(tableOffset, tableSize) <= checkedMultiply(first, 512) else {
            throw ScanError.malformed("GPT table overlaps usable space.")
        }
        let backupTableSectors = (tableSize + 511) / 512
        guard last < reader.sizeBytes / 512 - 1 - backupTableSectors else {
            throw ScanError.malformed("GPT usable space overlaps backup metadata.")
        }
        guard tableSize <= 64 * 1024 * 1024 else { throw ScanError.malformed("GPT table is too large.") }
        let table = try await read(tableOffset, Int(tableSize))
        guard UInt64(crc32(table)) == (try header.number(88, 4)) else { throw ScanError.malformed("Invalid GPT partition-table checksum.") }
        var result: [VolumeExtent] = []
        for n in 0..<count {
            let entry = table.subdata(in: Int(n * stride)..<Int((n + 1) * stride))
            if entry[0..<16].allSatisfy({ $0 == 0 }) { continue }
            let start = try signed(entry.number(32, 8)), end = try signed(entry.number(40, 8))
            guard start >= first, end <= last, start <= end else { throw ScanError.malformed("Invalid GPT partition bounds.") }
            result.append(try extent(start: start, sectors: checkedAdd(end - start, 1)))
        }
        return result
    }
}

func crc32(_ data: Data) -> UInt32 {
    var crc: UInt32 = 0xffffffff
    for byte in data {
        crc ^= UInt32(byte)
        for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xedb88320 : 0) }
    }
    return ~crc
}
