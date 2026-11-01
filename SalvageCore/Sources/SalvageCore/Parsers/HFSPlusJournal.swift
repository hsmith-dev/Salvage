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
    var isEmpty: Bool
    var maxBlocks: UInt64 { UInt64(blockListHeaderSize / 16) - 1 }

    static let magic: UInt64 = 0x4A4E_4C78
    static let endianMarker: UInt64 = 0x1234_5678
    static let swappedEndianMarker: UInt64 = 0x7856_3412
    /// JournalInfoBlock flags: journal lives inside the volume / needs initialization.
    static let inFilesystemFlag: UInt64 = 1, needsInitFlag: UInt64 = 4

    func field(_ data: Data, _ offset: Int, _ width: Int) throws -> UInt64 {
        bigEndian ? try data.hfsNumber(offset, width) : try data.number(offset, width)
    }

    /// The checksum used for block list headers: computed over the first 32 bytes with the
    /// checksum field itself zeroed.
    static func checksum(_ data: Data) -> UInt32 {
        var sum: UInt32 = 0
        for byte in data { sum = (sum << 8) ^ (sum &+ UInt32(byte)) }
        return ~sum
    }
}

extension HFSPlusVolume {
    /// Locates the journal and harvests catalog leaf nodes from every transaction still present in
    /// the buffer. A journal that is absent, unreadable or not yet replayed is skipped and noted;
    /// an unreplayed journal also disables deleted-file recovery, because the on-disk bitmap can
    /// then disagree with the catalog.
    func scanJournal() async throws {
        guard header.isJournaled, header.journalInfoBlock != 0 else { stats.journal = "absent"; return }
        guard header.journalInfoBlock < header.totalBlocks else { stats.journal = "unreadable: info block outside volume"; return }
        // JournalInfoBlock: flags, device_signature[32], offset, size (all big-endian).
        let info = try await read(Int64(header.journalInfoBlock) * header.blockSize, 52)
        let flags = try info.hfsNumber(0, 4)
        let offset = try info.hfsNumber(36, 8), size = try info.hfsNumber(44, 8)
        guard flags & HFSPlusJournal.inFilesystemFlag != 0, flags & HFSPlusJournal.needsInitFlag == 0 else {
            stats.journal = "skipped: journal is external or uninitialized"; return
        }
        guard size >= 1024, size <= limits.maxJournalBytes, offset <= UInt64(header.volumeBytes),
              size <= UInt64(header.volumeBytes) - offset else {
            stats.journal = "unreadable: journal outside volume"; return
        }
        let base = try signed(offset)
        let head = try await read(base, 48)
        let bigEndian: Bool
        switch try head.number(4, 4) {
        case HFSPlusJournal.endianMarker: bigEndian = false
        case HFSPlusJournal.swappedEndianMarker: bigEndian = true
        default: stats.journal = "unreadable: bad endian marker"; return
        }
        var journal = HFSPlusJournal(base: base, size: 0, sectorSize: 512, blockListHeaderSize: 0, bigEndian: bigEndian, isEmpty: true)
        guard try journal.field(head, 0, 4) == HFSPlusJournal.magic else { stats.journal = "unreadable: bad magic"; return }
        let start = try journal.field(head, 8, 8), end = try journal.field(head, 16, 8)
        let journalSize = try journal.field(head, 24, 8)
        let blockListHeaderSize = try journal.field(head, 32, 4), sectorSize = try journal.field(head, 40, 4)
        guard journalSize == size, sectorSize >= 512, sectorSize <= 65536, sectorSize.nonzeroBitCount == 1,
              blockListHeaderSize >= 64, blockListHeaderSize % 16 == 0, blockListHeaderSize <= 1 << 24,
              blockListHeaderSize + sectorSize <= size,
              start >= sectorSize, start <= size, end >= sectorSize, end <= size else {
            stats.journal = "unreadable: invalid journal header"; return
        }
        journal = HFSPlusJournal(base: base, size: try signed(size), sectorSize: Int64(sectorSize),
                                 blockListHeaderSize: Int64(blockListHeaderSize), bigEndian: bigEndian, isEmpty: start == end)
        if !journal.isEmpty {
            stats.journal = "skipped: unreplayed transactions"
            recoveryDisabled = "the journal holds unreplayed transactions, so the allocation bitmap may be stale"
            return
        }
        guard recoveryDisabled == nil, let catalog else { stats.journal = "skipped"; return }
        var transactions = 0
        var position = journal.sectorSize
        var chunks: [Int64: Data] = [:]
        while position + 32 <= journal.size {
            try Task.checkCancellation()
            let head = try await journalBytes(journal, position, 32, chunks: &chunks)
            guard let entries = try await blockList(journal, head: head, at: position, chunks: &chunks) else {
                position += journal.sectorSize
                continue
            }
            transactions += 1
            var dataPosition = position + journal.blockListHeaderSize
            for entry in entries {
                if entry.bnum >= 0, entry.size % Int64(catalog.nodeSize) == 0,
                   let logical = try? checkedMultiply(entry.bnum, journal.sectorSize),
                   let logicalInCatalog = catalog.map.logicalOffset(ofVolumeOffset: logical),
                   logicalInCatalog % Int64(catalog.nodeSize) == 0 {
                    let data = try await journalBytes(journal, dataPosition, Int(entry.size), chunks: &chunks)
                    for k in stride(from: 0, to: data.count, by: catalog.nodeSize) {
                        let piece = data.subdata(in: k..<k + catalog.nodeSize)
                        guard Int8(bitPattern: piece[8]) == HFSPlusNode.leafKind, let node = try? HFSPlusNode(piece) else { continue }
                        let wrapped = wrap(journal, dataPosition + Int64(k))
                        collectCandidates(in: node, deviceOffset: try checkedAdd(extent.offset, checkedAdd(journal.base, wrapped)),
                                          source: .journal, includeRecords: true)
                    }
                }
                dataPosition = wrap(journal, dataPosition + entry.size)
            }
            position += entries.reduce(journal.blockListHeaderSize) { $0 + $1.size }
        }
        stats.journalTransactions = transactions
        stats.journal = "scanned"
    }

    /// Parses a block list header at `position` when it is one: the fixed fields, the checksum
    /// and the block sizes must all agree. Returns the data block entries after `binfo[0]`.
    func blockList(_ journal: HFSPlusJournal, head: Data, at position: Int64, chunks: inout [Int64: Data]) async throws
        -> [(bnum: Int64, size: Int64)]? {
        let maxBlocks = try journal.field(head, 0, 2), numBlocks = try journal.field(head, 2, 2)
        let bytesUsed = try journal.field(head, 4, 4), checksum = try journal.field(head, 8, 4)
        guard maxBlocks == journal.maxBlocks, numBlocks >= 2, numBlocks <= maxBlocks,
              bytesUsed >= UInt64(journal.blockListHeaderSize + journal.sectorSize), bytesUsed <= UInt64(journal.size - journal.sectorSize),
              bytesUsed % UInt64(journal.sectorSize) == 0 else { return nil }
        var zeroed = head.prefix(32)
        zeroed.replaceSubrange(zeroed.startIndex + 8..<zeroed.startIndex + 12, with: [0, 0, 0, 0])
        guard UInt64(HFSPlusJournal.checksum(zeroed)) == checksum else { return nil }
        // binfo[0] carries the sequence number; the data blocks are binfo[1...].
        let table = try await journalBytes(journal, position + 16, Int(numBlocks) * 16, chunks: &chunks)
        var entries: [(Int64, Int64)] = []
        var total = UInt64(journal.blockListHeaderSize)
        for index in 1..<Int(numBlocks) {
            let bnum = Int64(bitPattern: try journal.field(table, index * 16, 8))
            let size = try journal.field(table, index * 16 + 8, 4)
            guard size > 0, size % UInt64(journal.sectorSize) == 0, size <= 16 << 20, bnum >= -1 else { return nil }
            total += size
            entries.append((bnum, Int64(size)))
        }
        guard total == bytesUsed else { return nil }
        return entries
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
