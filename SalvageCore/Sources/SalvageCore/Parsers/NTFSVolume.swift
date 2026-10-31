import Foundation

/// NTFS parser. All offsets are relative to one validated partition.
///
/// Two read-only passes over the MFT: the first indexes directories (live and deleted) and the
/// `$Bitmap` location; the second emits files in MFT order, so discoveries stream while the scan
/// runs and an in-use record found damaged in the first pass is reported at its own position.
actor NTFSVolume {
    static let isImplemented = true
    static let maxPathDepth = 1024
    static let orphanedDirectory = "/Orphaned Files"
    static let rootRecord: UInt64 = 5, bitmapRecord: UInt64 = 6, firstUserRecord: UInt64 = 16

    struct Directory {
        let sequence: UInt16
        let inUse: Bool
        let name: NTFSFileName

        /// A deleted directory's sequence number was incremented when it was freed, so a child
        /// deleted with it still holds the previous value. NTFS never uses sequence 0, so the value
        /// after 0xFFFF is 1.
        func matches(_ reference: UInt16) -> Bool {
            sequence == reference || (!inUse && sequence == (reference == 0xffff ? 1 : reference &+ 1))
        }
    }

    /// One placed run of a deleted candidate's unnamed `$DATA`, collected in pass 1.
    struct DeletedRun { let start: Int64; let end: Int64; let record: UInt64 }

    /// Bounds the runs collected for the deleted-file overlap check. Candidates whose runs don't fit
    /// can't be checked, so they are skipped rather than risk emitting another file's contents.
    static let maxDeletedRuns = 1 << 20

    let reader: any BlockReader
    let extent: VolumeExtent
    let emit: @Sendable (RecoveredFile) async throws -> Void
    var geometry: NTFSGeometry?
    var mftRuns: [NTFSRun] = []
    var recordCount: Int64 = 0
    var directories: [UInt64: Directory] = [:]
    var directoryPaths: [UInt64: String] = [:]
    var damaged: Set<UInt64> = []
    var bitmap: NTFSDataStream?
    var bitmapPageIndex: Int64 = -1
    var bitmapPage = Data()
    /// Deleted candidates (by record number) whose runs were all collected, and those among them
    /// whose runs overlap another deleted candidate's.
    var deletedRuns: [DeletedRun] = []
    var collectedDeleted: Set<UInt64> = []
    var overlappingDeleted: Set<UInt64> = []
    /// Remaining `$Bitmap` bits the deleted-file check may still examine on this volume. Once a
    /// candidate doesn't fit, it drops to zero and every later deleted candidate is skipped.
    var deletedCheckBudget: Int64 = 0
    var deletedCheckBudgetOverride: Int64?
    /// `$Bitmap` lookups made by the deleted-file check (one per bit, byte or 64-bit word tested).
    var bitmapChecks = 0

    /// Test seam: replaces the default per-volume budget of `4 × clusterCount + 1_000_000` bits.
    func limitDeletedChecks(to bits: Int64) { deletedCheckBudgetOverride = bits }

    init(reader: any BlockReader, extent: VolumeExtent, emit: @escaping @Sendable (RecoveredFile) async throws -> Void) {
        self.reader = reader; self.extent = extent; self.emit = emit
    }

    func read(_ offset: Int64, _ count: Int) async throws -> Data {
        try Task.checkCancellation()
        guard offset >= 0, count >= 0, offset <= extent.length, Int64(count) <= extent.length - offset else {
            throw ScanError.malformed("Read outside partition.")
        }
        let data = try await reader.read(at: checkedAdd(extent.offset, offset), count: count)
        guard data.count == count else { throw ScanError.malformed("Truncated structure.") }
        return data
    }

    func scan() async throws {
        let g = try NTFSGeometry(boot: try await read(0, 512), volumeLength: extent.length)
        geometry = g
        try await bootstrapMFT(g)
        try await forEachRecord { number, _, raw in try self.index(number, raw, g) }
        guard directories[Self.rootRecord]?.inUse == true else { throw ScanError.malformed("NTFS root directory is missing.") }
        guard bitmap != nil else { throw ScanError.malformed("NTFS $Bitmap is missing.") }
        markOverlappingDeletedRuns()
        deletedCheckBudget = try deletedCheckBudgetOverride ?? checkedAdd(checkedMultiply(4, g.clusterCount), 1_000_000)
        try await forEachRecord { number, offset, raw in try await self.emitFile(number, offset, raw, g) }
    }

    // MARK: - $MFT

    func bootstrapMFT(_ g: NTFSGeometry) async throws {
        let offset = try checkedMultiply(g.mftCluster, g.clusterBytes)
        var record = try await read(offset, Int(g.recordBytes))
        guard String(decoding: record.prefix(4), as: UTF8.self) == "FILE", applyNTFSFixup(&record) else {
            throw ScanError.malformed("NTFS $MFT record is damaged.")
        }
        let mft = try NTFSRecord(record, geometry: g)
        guard mft.inUse, mft.baseReference == 0 else { throw ScanError.malformed("NTFS $MFT record is not in use.") }
        guard let data = mft.data else {
            if mft.dataInExtensionRecords { throw ScanError.unsupportedFilesystem }
            throw ScanError.malformed("NTFS $MFT has no data.")
        }
        guard data.residentValue == nil, let first = data.runs.first, first.lcn == g.mftCluster,
              data.runs.allSatisfy({ $0.lcn != nil }),
              // Record 0 was read contiguously from the boot sector's $MFT cluster.
              try checkedMultiply(first.length, g.clusterBytes) >= g.recordBytes else {
            throw ScanError.malformed("NTFS $MFT runs are invalid.")
        }
        // Records past the initialized size were never written by NTFS; stale bytes there aren't records.
        recordCount = data.initialized / g.recordBytes
        guard recordCount > Int64(Self.bitmapRecord), recordCount <= Int64(UInt32.max) else {
            throw ScanError.malformed("NTFS $MFT is too small.")
        }
        mftRuns = data.runs
    }

    /// Streams every MFT record (fixup not yet applied) with its volume-relative offset. Records may
    /// span run boundaries when clusters are smaller than records.
    func forEachRecord(_ body: (UInt64, Int64, Data) async throws -> Void) async throws {
        guard let g = geometry else { return }
        let needed = try checkedMultiply(recordCount, g.recordBytes)
        var buffer = Data(), streamed: Int64 = 0, number: UInt64 = 0
        var recordStarts: [Int64] = [], startCursor = 0
        for run in mftRuns {
            guard let lcn = run.lcn else { throw ScanError.malformed("Sparse NTFS $MFT run.") }
            let start = try checkedMultiply(lcn, g.clusterBytes)
            let runBytes = try checkedMultiply(run.length, g.clusterBytes)
            var done: Int64 = 0
            while done < runBytes, streamed < needed {
                let count = min(1024 * 1024, runBytes - done, needed - streamed)
                let chunkOffset = try checkedAdd(start, done)
                // Every record whose first byte falls in this chunk records its location.
                var first = (streamed + g.recordBytes - 1) / g.recordBytes * g.recordBytes
                while first < streamed + count {
                    recordStarts.append(chunkOffset + (first - streamed)); first += g.recordBytes
                }
                buffer.append(try await read(chunkOffset, Int(count)))
                done += count; streamed += count
                var cursor = 0
                while buffer.count - cursor >= Int(g.recordBytes) {
                    let record = buffer.subdata(in: cursor..<cursor + Int(g.recordBytes))
                    try await body(number, recordStarts[startCursor], record)
                    number += 1; cursor += Int(g.recordBytes); startCursor += 1
                }
                buffer = buffer.subdata(in: cursor..<buffer.count)
                // Drop consumed starts once per chunk, leaving at most the one straddling record.
                recordStarts.removeFirst(startCursor); startCursor = 0
            }
        }
        guard streamed == needed else { throw ScanError.malformed("NTFS $MFT runs are shorter than its size.") }
    }

    enum Classified { case skip, damaged, record(NTFSRecord, Data) }

    /// Distinguishes unusable records: a damaged in-use record is an error, a damaged deleted one
    /// (or one that was never initialized) is skipped.
    func classify(_ raw: Data, _ g: NTFSGeometry) -> Classified {
        guard String(decoding: raw.prefix(4), as: UTF8.self) == "FILE" else { return .skip }
        let inUse = NTFSRecord.flags(of: raw) & 0x01 != 0
        var fixed = raw
        guard applyNTFSFixup(&fixed) else { return inUse ? .damaged : .skip }
        do { return .record(try NTFSRecord(fixed, geometry: g), fixed) } catch { return inUse ? .damaged : .skip }
    }

    // MARK: - Pass 1

    func index(_ number: UInt64, _ raw: Data, _ g: NTFSGeometry) throws {
        let system = number < Self.firstUserRecord
        guard !system || number == Self.rootRecord || number == Self.bitmapRecord else { return }
        switch classify(raw, g) {
        case .skip:
            if system { throw ScanError.malformed("NTFS system record \(number) is missing.") }
        case .damaged:
            if system { throw ScanError.malformed("NTFS system record \(number) is damaged.") }
            damaged.insert(number)
        case .record(let record, _):
            guard record.baseReference == 0 else { return }
            if number == Self.bitmapRecord {
                let minimum = (g.clusterCount + 7) / 8
                guard record.inUse, let data = record.data, data.size >= minimum,
                      data.residentValue != nil || data.runs.allSatisfy({ $0.lcn != nil }) else {
                    throw ScanError.malformed("NTFS $Bitmap is invalid.")
                }
                bitmap = data
                return
            }
            if number == Self.rootRecord {
                guard record.inUse, record.isDirectory, record.fileNameAttributes > 0 else {
                    throw ScanError.malformed("NTFS root directory is invalid.")
                }
                // The root's own name is "."; it never appears in a path, so it isn't needed.
                let name = NTFSFileName(parent: Self.rootRecord, parentSequence: record.sequence, namespace: 3, name: "")
                directories[number] = Directory(sequence: record.sequence, inUse: true, name: name)
                return
            }
            if record.isDirectory, let name = record.bestName {
                directories[number] = Directory(sequence: record.sequence, inUse: record.inUse, name: name)
            }
            if !system, !record.inUse, !record.isDirectory, let data = record.data { collectDeletedRuns(number, data) }
        }
    }

    func collectDeletedRuns(_ number: UInt64, _ data: NTFSDataStream) {
        let placed = data.runs.compactMap { run in run.lcn.map { DeletedRun(start: $0, end: $0 + run.length, record: number) } }
        guard !placed.isEmpty, placed.count <= Self.maxDeletedRuns - deletedRuns.count else { return }
        deletedRuns += placed
        collectedDeleted.insert(number)
    }

    /// Marks every deleted candidate whose runs overlap a different candidate's. Runs inside one
    /// attribute never overlap, so a sweep over runs sorted by start, tracking the run that reaches
    /// furthest, finds every cross-record overlap.
    func markOverlappingDeletedRuns() {
        var furthest: DeletedRun?
        for run in deletedRuns.sorted(by: { $0.start < $1.start }) {
            if let reach = furthest, run.start < reach.end, run.record != reach.record {
                overlappingDeleted.insert(run.record); overlappingDeleted.insert(reach.record)
            }
            if furthest.map({ run.end > $0.end }) ?? true { furthest = run }
        }
        deletedRuns = []
    }

    // MARK: - Pass 2

    func emitFile(_ number: UInt64, _ offset: Int64, _ raw: Data, _ g: NTFSGeometry) async throws {
        guard number >= Self.firstUserRecord else { return }
        if damaged.contains(number) { throw ScanError.malformed("NTFS MFT record \(number) is damaged.") }
        guard case .record(let record, let fixed) = classify(raw, g) else { return }
        guard record.baseReference == 0, !record.isDirectory else { return }
        guard let name = record.bestName else {
            // Names that would have to be altered to decode are skipped; no name at all is damage.
            if record.inUse && !record.hasAttributeList && record.fileNameAttributes == 0 { throw ScanError.malformed("NTFS MFT record \(number) has no name.") }
            return
        }
        // Files whose unnamed stream lives in extension records are skipped rather than sized wrongly.
        guard let data = record.data else { return }
        guard let parent = try directoryPath(name.parent, name.parentSequence) else { return }
        if parent.isEmpty, name.name.hasPrefix("$") { return }
        if !record.inUse, !(try await deletedClustersAreFree(number, data, g)) { return }
        try await emit(RecoveredFile(
            name: name.name, path: parent + "/" + name.name, sizeBytes: data.size,
            modified: record.modified, isDeleted: !record.inUse,
            sourceMetadata: SourceMetadata(filesystem: .ntfs, volumeOffset: extent.offset,
                                           recordOffset: try checkedAdd(extent.offset, offset),
                                           allocationStart: number,
                                           contiguous: data.runs.count == 1 && data.runs[0].lcn != nil,
                                           rawRecord: fixed)))
    }

    /// The directory's path ("" for the root), "/Orphaned Files…" when the chain is broken, or nil
    /// for system metafile directories such as `$Extend`.
    func directoryPath(_ reference: UInt64, _ sequence: UInt16) throws -> String? {
        var chain: [(UInt64, String)] = [], visited: Set<UInt64> = []
        var current = reference, currentSequence = sequence
        var prefix: String
        while true {
            if damaged.contains(current) { throw ScanError.malformed("NTFS MFT record \(current) is damaged.") }
            if current < Self.firstUserRecord, current != Self.rootRecord { return nil }
            guard let directory = directories[current], directory.matches(currentSequence) else {
                prefix = Self.orphanedDirectory; break
            }
            if current == Self.rootRecord { prefix = ""; break }
            if let cached = directoryPaths[current] { prefix = cached; break }
            guard visited.insert(current).inserted else { throw ScanError.malformed("NTFS directory cycle.") }
            guard chain.count < Self.maxPathDepth else { throw ScanError.malformed("NTFS directory tree is too deep.") }
            chain.append((current, directory.name.name))
            current = directory.name.parent; currentSequence = directory.name.parentSequence
        }
        for (record, name) in chain.reversed() {
            prefix += "/" + name
            directoryPaths[record] = prefix
        }
        return prefix
    }

    // MARK: - $Bitmap

    /// Whether a deleted file's clusters can still hold its data: no other deleted candidate claims
    /// them, the volume's check budget isn't spent, and `$Bitmap` marks every one free. Clusters
    /// reused since deletion mean the data has probably been overwritten.
    func deletedClustersAreFree(_ number: UInt64, _ data: NTFSDataStream, _ g: NTFSGeometry) async throws -> Bool {
        let placed = data.runs.compactMap { run in run.lcn.map { (lcn: $0, length: run.length) } }
        guard !placed.isEmpty else { return true }
        guard collectedDeleted.contains(number), !overlappingDeleted.contains(number) else { return false }
        // Runs of one attribute are disjoint and inside the volume, so this can't exceed clusterCount.
        let clusters = try placed.reduce(Int64(0)) { try checkedAdd($0, $1.length) }
        guard clusters <= deletedCheckBudget else { deletedCheckBudget = 0; return false }
        deletedCheckBudget -= clusters
        for run in placed {
            try Task.checkCancellation()
            if try await anyClusterUsed(run.lcn, run.length, g) { return false }
        }
        return true
    }

    /// Tests clusters `lcn..<lcn + length`, a 64-bit word or a byte at a time where aligned, so a
    /// fully free word or byte costs one lookup.
    func anyClusterUsed(_ lcn: Int64, _ length: Int64, _ g: NTFSGeometry) async throws -> Bool {
        var cluster = lcn
        let end = try checkedAdd(lcn, length)
        while cluster < end {
            let remaining = end - cluster
            bitmapChecks += 1
            if cluster % 64 == 0, remaining >= 64 {
                // A word starting on an 8-byte boundary never crosses a (power-of-two) page.
                if try await bitmapBytes(cluster / 8, 8, g) != 0 { return true }
                cluster += 64
            } else if cluster % 8 == 0, remaining >= 8 {
                if try await bitmapBytes(cluster / 8, 1, g) != 0 { return true }
                cluster += 8
            } else {
                if try await bitmapBytes(cluster / 8, 1, g) & (1 << UInt64(cluster % 8)) != 0 { return true }
                cluster += 1
            }
        }
        return false
    }

    /// `count` (1...8) consecutive `$Bitmap` bytes from one page, little-endian. Bytes beyond the
    /// stream's initialized size read as zero (free), as NTFS defines.
    func bitmapBytes(_ byte: Int64, _ count: Int, _ g: NTFSGeometry) async throws -> UInt64 {
        guard let bitmap else { throw ScanError.malformed("NTFS $Bitmap is missing.") }
        guard byte >= 0, Int64(count) <= bitmap.size - byte else { throw ScanError.malformed("NTFS $Bitmap is too small.") }
        guard byte < bitmap.initialized else { return 0 }
        let page: Data, pageStart: Int64
        if let resident = bitmap.residentValue {
            page = resident; pageStart = 0
        } else {
            let pageBytes = min(g.clusterBytes, 64 * 1024)
            let index = byte / pageBytes
            pageStart = index * pageBytes
            if index != bitmapPageIndex {
                var vcn = pageStart / g.clusterBytes
                var location: Int64?
                for run in bitmap.runs {
                    if vcn < run.length { location = run.lcn.map { $0 + vcn }; break }
                    vcn -= run.length
                }
                guard let lcn = location else { throw ScanError.malformed("NTFS $Bitmap doesn't cover the volume.") }
                let offset = try checkedAdd(checkedMultiply(lcn, g.clusterBytes), pageStart % g.clusterBytes)
                bitmapPage = try await read(offset, Int(pageBytes))
                bitmapPageIndex = index
            }
            page = bitmapPage
        }
        var value: UInt64 = 0
        for i in 0..<count where byte + Int64(i) < bitmap.initialized {
            value |= UInt64(page[Int(byte - pageStart) + i]) << UInt64(i * 8)
        }
        return value
    }
}
