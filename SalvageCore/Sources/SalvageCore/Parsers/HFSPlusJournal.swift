import Foundation

/// The HFS+ journal (TN1150, "Journal"): a circular buffer of transactions, each a block list
/// header followed by copies of metadata blocks. Every transaction that ever passed through the
/// buffer leaves its bytes behind until overwritten, so copies of catalog leaf nodes from before a
/// deletion are a rich source of intact file records.
struct HFSPlusJournal: Sendable {
    /// Volume-relative byte offset of the journal buffer (the journal header sits at its start).
    let base: Int64
    let size: Int64
    /// Sector size: the unit of `bnum` and the alignment of every block list header.
    let sectorSize: Int64
    let blockListHeaderSize: Int64
    let bigEndian: Bool
    /// Where the next transaction will be written (`start == end` for a usable journal).
    var end: Int64 = 0
    var maxBlocks: UInt64 { UInt64(blockListHeaderSize / 16) - 1 }

    static let magic: UInt64 = 0x4A4E_4C78
    static let endianMarker: UInt64 = 0x1234_5678
    static let swappedEndianMarker: UInt64 = 0x7856_3412
    /// JournalInfoBlock flags: journal lives inside the volume / needs initialization.
    static let inFilesystemFlag: UInt64 = 1, needsInitFlag: UInt64 = 4

    func field(_ data: Data, _ offset: Int, _ width: Int) throws -> UInt64 {
        bigEndian ? try data.hfsNumber(offset, width) : try data.number(offset, width)
    }

    /// The journal checksum: block list headers use their first 32 bytes and the journal header
    /// its first 44, each with the checksum field zeroed; data blocks use all their bytes.
    static func checksum(_ data: Data) -> UInt32 {
        var sum: UInt32 = 0
        for byte in data { sum = (sum << 8) ^ (sum &+ UInt32(byte)) }
        return ~sum
    }
}

/// One parsed block list header: its sequence number, whether per-block checksums are present,
/// the bytes it spans and its data blocks (after `binfo[0]`).
struct HFSPlusBlockList: Sendable {
    let sequence: UInt32
    let checksummed: Bool
    let bytesUsed: Int64
    let entries: [(bnum: Int64, size: Int64, checksum: UInt32)]
}

extension HFSPlusJournal {
    static let checkChecksumsFlag: UInt64 = 1
    /// Bytes of the journal header covered by its checksum (everything before `sequence_num`).
    static let headerChecksumSize = 44
    /// Length of the circular data area after the journal header.
    var ringSize: Int64 { size - sectorSize }

    /// Whether the circular span `[position, position + count)` strictly contains `end`: such a
    /// transaction was being overwritten by the newest ones and may be half replaced.
    func span(at position: Int64, count: Int64, contains end: Int64) -> Bool {
        let distance = ((end - position) % ringSize + ringSize) % ringSize
        return distance > 0 && distance < count
    }
}

extension HFSPlusVolume {
    /// Locates the journal and harvests catalog leaf nodes from every intact transaction still
    /// present in the buffer. On a journaled volume, a journal that is external, unreadable,
    /// outside the volume, invalid or not yet replayed disables deleted-file recovery, because
    /// unreplayed transactions (and so a stale bitmap) cannot be ruled out. An I/O or structural
    /// failure while harvesting only skips the journal as a source.
    func scanJournal() async throws {
        guard header.isJournaled else { stats.journal = "absent"; return }
        let journal: HFSPlusJournal
        do {
            switch try await locateJournal() {
            case .usable(let located): journal = located
            case .skip(let reason): stats.journal = "skipped: \(reason)"; return
            case .dirty:
                stats.journal = "skipped: unreplayed transactions"
                if recoveryDisabled == nil {
                    recoveryDisabled = "the journal holds unreplayed transactions, so the allocation bitmap may be stale"
                }
                return
            case .untrusted(let reason):
                stats.journal = "unreadable: \(reason)"
                if recoveryDisabled == nil {
                    recoveryDisabled = "the journal is unusable (\(reason)), so unreplayed transactions can't be ruled out"
                }
                return
            }
        } catch let error as ScanError {
            switch error {
            case .io, .malformed:
                stats.journal = "unreadable: \(error)"
                if recoveryDisabled == nil {
                    recoveryDisabled = "the journal could not be read, so unreplayed transactions can't be ruled out"
                }
                return
            default: throw error
            }
        }
        guard recoveryDisabled == nil else { stats.journal = "skipped"; return }
        stats.journal = "unreadable: harvest failed"
        try await harvest(journal)
        stats.journal = "scanned"
    }

    enum JournalLocation { case usable(HFSPlusJournal), skip(String), untrusted(String), dirty }

    /// Reads the journal info block and journal header and decides whether the journal is clean.
    func locateJournal() async throws -> JournalLocation {
        guard header.journalInfoBlock != 0, header.journalInfoBlock < header.totalBlocks else {
            return .untrusted("info block outside volume")
        }
        // JournalInfoBlock: flags, device_signature[32], offset, size (all big-endian).
        let info = try await read(Int64(header.journalInfoBlock) * header.blockSize, 52)
        let flags = try info.hfsNumber(0, 4)
        let offset = try info.hfsNumber(36, 8), size = try info.hfsNumber(44, 8)
        guard flags & HFSPlusJournal.inFilesystemFlag != 0 else { return .untrusted("journal is external") }
        // A journal awaiting initialization is discarded at mount: nothing in it can be replayed.
        guard flags & HFSPlusJournal.needsInitFlag == 0 else { return .skip("journal is uninitialized") }
        guard size >= 1024, offset <= UInt64(header.volumeBytes), size <= UInt64(header.volumeBytes) - offset else {
            return .untrusted("journal outside volume")
        }
        let base = try signed(offset)
        let head = try await read(base, 48)
        let bigEndian: Bool
        switch try head.number(4, 4) {
        case HFSPlusJournal.endianMarker: bigEndian = false
        case HFSPlusJournal.swappedEndianMarker: bigEndian = true
        default: return .untrusted("bad endian marker")
        }
        let probe = HFSPlusJournal(base: base, size: 0, sectorSize: 512, blockListHeaderSize: 0, bigEndian: bigEndian)
        guard try probe.field(head, 0, 4) == HFSPlusJournal.magic else { return .untrusted("bad magic") }
        var zeroed = head.prefix(HFSPlusJournal.headerChecksumSize)
        zeroed.replaceSubrange(zeroed.startIndex + 36..<zeroed.startIndex + 40, with: [0, 0, 0, 0])
        guard UInt64(HFSPlusJournal.checksum(zeroed)) == (try probe.field(head, 36, 4)) else { return .untrusted("bad header checksum") }
        let start = try probe.field(head, 8, 8), end = try probe.field(head, 16, 8)
        let journalSize = try probe.field(head, 24, 8)
        let blockListHeaderSize = try probe.field(head, 32, 4), sectorSize = try probe.field(head, 40, 4)
        guard journalSize == size, sectorSize >= 512, sectorSize <= 65536, sectorSize.nonzeroBitCount == 1,
              blockListHeaderSize >= 64, blockListHeaderSize % 16 == 0, blockListHeaderSize <= 1 << 24,
              blockListHeaderSize + sectorSize <= size,
              start >= sectorSize, start <= size, end >= sectorSize, end <= size else {
            return .untrusted("invalid journal header")
        }
        guard start == end else { return .dirty }
        guard size <= limits.maxJournalBytes else { return .skip("journal larger than the harvest cap") }
        var journal = HFSPlusJournal(base: base, size: try signed(size), sectorSize: Int64(sectorSize),
                                     blockListHeaderSize: Int64(blockListHeaderSize), bigEndian: bigEndian)
        journal.end = wrap(journal, try signed(end))
        return .usable(journal)
    }

    /// Probes every sector of the buffer for a block list header and harvests the catalog leaf
    /// nodes of each intact transaction.
    func harvest(_ journal: HFSPlusJournal) async throws {
        guard let catalog else { return }
        let nodeSize = Int64(catalog.nodeSize)
        var position = journal.sectorSize
        var chunks: [Int64: Data] = [:]
        while position + 32 <= journal.size {
            try Task.checkCancellation()
            let head = try await journalBytes(journal, position, 32, chunks: &chunks)
            guard let list = try await blockList(journal, head: head, at: position, chunks: &chunks) else {
                position += journal.sectorSize
                continue
            }
            stats.journalTransactions += 1
            // A stale transaction straddling `end` was partly overwritten by newer ones; the
            // newer headers inside its span must still be probed, so step by one sector.
            if journal.span(at: position, count: list.bytesUsed, contains: journal.end) {
                stats.journalTornTransactions += 1
                position += journal.sectorSize
                continue
            }
            var nodes: [(node: HFSPlusNode, deviceOffset: Int64)] = []
            var intact = true
            var dataPosition = position + journal.blockListHeaderSize
            for entry in list.entries {
                let logical = entry.bnum >= 0 ? try? checkedMultiply(entry.bnum, journal.sectorSize) : nil
                let catalogTarget = logical.map { catalog.map.logicalOffset(ofVolumeOffset: $0) != nil } ?? false
                if list.checksummed || catalogTarget {
                    let data = try await journalBytes(journal, dataPosition, Int(entry.size), chunks: &chunks)
                    if list.checksummed, HFSPlusJournal.checksum(data) != entry.checksum { intact = false; break }
                    if let logical, catalogTarget, entry.size % nodeSize == 0 {
                        // Each node of a multi-node block must itself be a whole catalog node.
                        for k in stride(from: Int64(0), to: entry.size, by: Int(nodeSize)) {
                            guard let inCatalog = catalog.map.logicalRange(ofVolumeOffset: logical + k, count: nodeSize),
                                  inCatalog % nodeSize == 0, inCatalog / nodeSize < Int64(catalog.header.totalNodes) else { continue }
                            let piece = data.subdata(in: Int(k)..<Int(k + nodeSize))
                            guard Int8(bitPattern: piece[8]) == HFSPlusNode.leafKind, let node = try? HFSPlusNode(piece) else { continue }
                            let wrapped = wrap(journal, dataPosition + k)
                            nodes.append((node, try checkedAdd(extent.offset, checkedAdd(journal.base, wrapped))))
                        }
                    }
                }
                dataPosition = wrap(journal, dataPosition + entry.size)
            }
            guard intact else {
                stats.journalChecksumFailures += 1
                position += journal.sectorSize
                continue
            }
            for (node, offset) in nodes {
                collectCandidates(in: node, deviceOffset: offset, source: .journal, includeRecords: true, sequence: list.sequence)
            }
            position += list.bytesUsed
        }
    }

    /// Parses a block list header at `position` when it is one: the fixed fields, the checksum
    /// and the block sizes must all agree.
    func blockList(_ journal: HFSPlusJournal, head: Data, at position: Int64, chunks: inout [Int64: Data]) async throws
        -> HFSPlusBlockList? {
        let maxBlocks = try journal.field(head, 0, 2), numBlocks = try journal.field(head, 2, 2)
        let bytesUsed = try journal.field(head, 4, 4), checksum = try journal.field(head, 8, 4)
        let flags = try journal.field(head, 12, 4)
        guard maxBlocks == journal.maxBlocks, numBlocks >= 2, numBlocks <= maxBlocks,
              bytesUsed >= UInt64(journal.blockListHeaderSize + journal.sectorSize), bytesUsed <= UInt64(journal.ringSize),
              bytesUsed % UInt64(journal.sectorSize) == 0 else { return nil }
        var zeroed = head.prefix(32)
        zeroed.replaceSubrange(zeroed.startIndex + 8..<zeroed.startIndex + 12, with: [0, 0, 0, 0])
        guard UInt64(HFSPlusJournal.checksum(zeroed)) == checksum else { return nil }
        // binfo[0] carries the sequence number (bnum, bsize, then sequence_num); the data blocks
        // are binfo[1...], each with its checksum in the same slot.
        let sequence = UInt32(try journal.field(head, 16 + 12, 4))
        let table = try await journalBytes(journal, position + 16, Int(numBlocks) * 16, chunks: &chunks)
        var entries: [(Int64, Int64, UInt32)] = []
        var total = UInt64(journal.blockListHeaderSize)
        for index in 1..<Int(numBlocks) {
            let bnum = Int64(bitPattern: try journal.field(table, index * 16, 8))
            let size = try journal.field(table, index * 16 + 8, 4)
            let blockChecksum = UInt32(try journal.field(table, index * 16 + 12, 4))
            guard size > 0, size % UInt64(journal.sectorSize) == 0, size <= 16 << 20, bnum >= -1 else { return nil }
            total += size
            entries.append((bnum, Int64(size), blockChecksum))
        }
        guard total == bytesUsed else { return nil }
        return HFSPlusBlockList(sequence: sequence, checksummed: flags & HFSPlusJournal.checkChecksumsFlag != 0,
                                bytesUsed: Int64(bytesUsed), entries: entries)
    }

    /// Buffer positions wrap past the end to just after the journal header.
    func wrap(_ journal: HFSPlusJournal, _ position: Int64) -> Int64 {
        position >= journal.size ? journal.sectorSize + (position - journal.size) : position
    }

    /// Reads journal buffer bytes with wrap-around, through a two-chunk read cache.
    func journalBytes(_ journal: HFSPlusJournal, _ position: Int64, _ count: Int, chunks: inout [Int64: Data]) async throws -> Data {
        let chunkSize: Int64 = 1 << 20
        var result = Data(capacity: count)
        var position = wrap(journal, position), remaining = count
        while remaining > 0 {
            guard position >= 0, position < journal.size else { throw ScanError.malformed("Journal read out of range.") }
            let index = position / chunkSize
            let chunk: Data
            if let cached = chunks[index] { chunk = cached } else {
                let start = index * chunkSize
                chunk = try await read(try checkedAdd(journal.base, start), Int(min(chunkSize, journal.size - start)))
                if chunks.count >= 2 { chunks.removeAll() }
                chunks[index] = chunk
            }
            let within = Int(position - index * chunkSize)
            let take = min(remaining, chunk.count - within)
            guard take > 0 else { throw ScanError.malformed("Journal read out of range.") }
            result.append(chunk.subdata(in: within..<within + take))
            remaining -= take
            position = wrap(journal, position + Int64(take))
        }
        return result
    }
}
