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
        /// deleted with it still holds the previous value.
        func matches(_ reference: UInt16) -> Bool {
            sequence == reference || (!inUse && sequence == reference &+ 1)
        }
    }

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
        var recordStarts: [Int64] = []
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
                    try await body(number, recordStarts.removeFirst(), record)
                    number += 1; cursor += Int(g.recordBytes)
                }
                buffer = buffer.subdata(in: cursor..<buffer.count)
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
            if number == Self.rootRecord, !(record.inUse && record.isDirectory) {
                throw ScanError.malformed("NTFS root directory is invalid.")
            }
            if record.isDirectory, let name = record.bestName {
                directories[number] = Directory(sequence: record.sequence, inUse: record.inUse, name: name)
            }
        }
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
        if !record.inUse {
            for run in data.runs {
                guard let lcn = run.lcn else { continue }
                for cluster in lcn..<lcn + run.length {
                    // Clusters reused since deletion mean the data has probably been overwritten.
                    if try await clusterInUse(cluster, g) { return }
                }
            }
        }
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

    func clusterInUse(_ cluster: Int64, _ g: NTFSGeometry) async throws -> Bool {
        guard let bitmap else { throw ScanError.malformed("NTFS $Bitmap is missing.") }
        let byte = cluster / 8, bit = UInt8(1) << (cluster % 8)
        if let resident = bitmap.residentValue {
            guard byte < Int64(resident.count) else { throw ScanError.malformed("NTFS $Bitmap is too small.") }
            return resident[Int(byte)] & bit != 0
        }
        let pageBytes = min(g.clusterBytes, 64 * 1024)
        let page = byte / pageBytes
        if page != bitmapPageIndex {
            let pageStart = page * pageBytes
            var vcn = pageStart / g.clusterBytes
            var location: Int64?
            for run in bitmap.runs {
                if vcn < run.length { location = run.lcn.map { $0 + vcn }; break }
                vcn -= run.length
            }
            guard let lcn = location else { throw ScanError.malformed("NTFS $Bitmap doesn't cover the volume.") }
            let offset = try checkedAdd(checkedMultiply(lcn, g.clusterBytes), pageStart % g.clusterBytes)
            bitmapPage = try await read(offset, Int(pageBytes))
            bitmapPageIndex = page
        }
        return bitmapPage[Int(byte % pageBytes)] & bit != 0
    }
}
