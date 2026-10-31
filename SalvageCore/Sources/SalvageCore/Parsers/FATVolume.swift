import Foundation

/// All offsets are relative to one validated partition. No parser can escape this extent.
actor FATVolume {
    let reader: any BlockReader
    let extent: VolumeExtent
    let emit: @Sendable (RecoveredFile) async throws -> Void
    var exfat = false
    var sector: Int64 = 512
    var clusterBytes: Int64 = 0
    var fatOffset: Int64 = 0
    var fatBytes: Int64 = 0
    var heapOffset: Int64 = 0
    var clusterCount: Int64 = 0
    var root: UInt32 = 0
    var visitedDirectories: Set<UInt32> = []
    var fatPageOffset: Int64 = -1
    var fatPage = Data()
    var owners: [UInt32: String] = [:]
    var activeFat: UInt8 = 0
    var bitmapClusters: [UInt32] = []
    var bitmapLength: Int64 = 0
    var bitmapPageOffset: Int64 = -1
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
        let b = try await read(0, 512)
        guard try b.number(510, 2) == 0xaa55 else { throw ScanError.malformed("Missing boot signature.") }
        exfat = String(decoding: b[3..<11], as: UTF8.self) == "EXFAT   "
        if exfat { try exfatGeometry(b); try await validateExfatBoot() } else { try fatGeometry(b) }
        guard clusterCount > 0, clusterCount <= 0xfffffff5,
              try checkedMultiply(clusterCount + 2, 4) <= fatBytes,
              try checkedAdd(heapOffset, checkedMultiply(clusterCount, clusterBytes)) <= extent.length else {
            throw ScanError.malformed("Allocation geometry exceeds partition.")
        }
        try validCluster(root)
        if exfat { try await loadBitmap() }
        var pending: [(UInt32, String, Int64?, Bool)] = [(root, "", nil, false)]
        while let (cluster, path, length, contiguous) = pending.popLast() {
            guard visitedDirectories.insert(cluster).inserted else { throw ScanError.malformed("Directory cycle or shared directory.") }
            try await validateFile(cluster, length: length ?? 1, contiguous: contiguous, owner: "directory:\(cluster)")
            let children = try await directory(cluster, path: path, length: length, contiguous: contiguous)
            pending.append(contentsOf: children)
        }
    }
    func validateExfatBoot() async throws {
        let boot = try await read(0, Int(sector * 12))
        var checksum: UInt32 = 0
        for index in 0..<Int(sector * 11) where index != 106 && index != 107 && index != 112 {
            checksum = ((checksum & 1) << 31) &+ (checksum >> 1) &+ UInt32(boot[index])
        }
        for offset in stride(from: Int(sector * 11), to: Int(sector * 12), by: 4) {
            guard try boot.number(offset, 4) == UInt64(checksum) else { throw ScanError.malformed("Invalid exFAT boot checksum.") }
        }
        for index in 1...8 {
            guard try boot.number(Int(sector) * (index + 1) - 4, 4) == 0xaa550000 else {
                throw ScanError.malformed("Invalid exFAT extended boot signature.")
            }
        }
    }
    func fatGeometry(_ b: Data) throws {
        sector = try signed(b.number(11, 2))
        let spc = try signed(b.number(13, 1)), reserved = try signed(b.number(14, 2))
        let fats = try signed(b.number(16, 1)), fatSectors = try signed(b.number(36, 4))
        let total = try signed(b.number(32, 4)), flags = try b.number(40, 2)
        guard [512, 1024, 2048, 4096].contains(sector), spc > 0, spc <= 128,
              spc & (spc - 1) == 0, reserved > 0, (1...2).contains(fats), fatSectors > 0,
              try b.number(17, 2) == 0, try b.number(22, 2) == 0, try b.number(19, 2) == 0,
              try b.number(42, 2) == 0 else { throw ScanError.unsupportedFilesystem }
        clusterBytes = try checkedMultiply(sector, spc)
        let heapSector = try checkedAdd(reserved, checkedMultiply(fats, fatSectors))
        guard total > heapSector, try checkedMultiply(total, sector) <= extent.length else {
            throw ScanError.malformed("Invalid FAT32 volume length.")
        }
        clusterCount = (total - heapSector) / spc
        guard clusterCount >= 65525, clusterCount < 0xffffff5 else { throw ScanError.unsupportedFilesystem }
        let active = flags & 0x80 == 0 ? 0 : Int64(flags & 15)
        guard active < fats else { throw ScanError.malformed("Invalid active FAT.") }
        fatBytes = try checkedMultiply(fatSectors, sector)
        fatOffset = try checkedAdd(checkedMultiply(reserved, sector), checkedMultiply(active, fatBytes))
        heapOffset = try checkedMultiply(heapSector, sector)
        root = UInt32(try b.number(44, 4))
    }
    func exfatGeometry(_ b: Data) throws {
        let ss = try b.number(108, 1), cs = try b.number(109, 1)
        let fats = try b.number(110, 1), flags = try b.number(106, 2)
        guard (9...12).contains(ss), cs <= 25 - ss, (1...2).contains(fats),
              try b.number(104, 2) == 0x100, b[11..<64].allSatisfy({ $0 == 0 }) else {
            throw ScanError.malformed("Unsupported exFAT geometry or revision.")
        }
        sector = Int64(1) << ss
        clusterBytes = sector << cs
        let volumeSectors = try signed(b.number(72, 8)), fatSector = try signed(b.number(80, 4))
        let fatSectors = try signed(b.number(84, 4)), heap = try signed(b.number(88, 4))
        clusterCount = try signed(b.number(92, 4))
        let active = Int64(flags & 1)
        activeFat = UInt8(active)
        guard active < fats, fatSector >= 24, fatSectors > 0,
              try heap >= checkedAdd(fatSector, checkedMultiply(Int64(fats), fatSectors)),
              try checkedMultiply(volumeSectors, sector) <= extent.length,
              try checkedAdd(heap, checkedMultiply(clusterCount, Int64(1) << cs)) <= volumeSectors else {
            throw ScanError.malformed("Invalid exFAT volume bounds.")
        }
        fatBytes = try checkedMultiply(fatSectors, sector)
        fatOffset = try checkedAdd(checkedMultiply(fatSector, sector), checkedMultiply(active, fatBytes))
        heapOffset = try checkedMultiply(heap, sector)
        root = UInt32(try b.number(96, 4))
    }
    func strictUTF16(_ units: [UInt16]) -> String? {
        let value = String(decoding: units, as: UTF16.self)
        return Array(value.utf16) == units ? value : nil
    }
    func loadBitmap() async throws {
        var current: UInt32? = root, seen: Set<UInt32> = [], selected: Data?, upcase: Data?
        var finished = false
        while let cluster = current, !finished {
            guard seen.insert(cluster).inserted else { throw ScanError.malformed("Root allocation cycle.") }
            var within: Int64 = 0
            while within < clusterBytes && !finished {
                let count = Int(min(65536, clusterBytes - within))
                let data = try await read(checkedAdd(clusterOffset(cluster), within), count)
                for offset in stride(from: 0, to: count, by: 32) {
                    let entry = data.subdata(in: offset..<offset+32)
                    if entry[0] == 0 { finished = true; break }
                    if entry[0] == 0x81 && entry[1] & 1 == activeFat {
                        guard selected == nil else { throw ScanError.malformed("Duplicate active allocation bitmap.") }
                        selected = entry
                    }
                    if entry[0] == 0x82 {
                        guard upcase == nil else { throw ScanError.malformed("Duplicate up-case table.") }
                        upcase = entry
                    }
                }
                within += Int64(count)
            }
            if !finished { current = try await next(cluster) }
        }
        guard let selected else { throw ScanError.malformed("Missing active allocation bitmap.") }
        bitmapLength = try signed(selected.number(24, 8))
        guard bitmapLength == (clusterCount + 7) / 8 else { throw ScanError.malformed("Invalid allocation bitmap length.") }
        current = UInt32(try selected.number(20, 4)); seen = []
        while let cluster = current {
            try validCluster(cluster)
            guard seen.insert(cluster).inserted else { throw ScanError.malformed("Allocation bitmap cycle.") }
            bitmapClusters.append(cluster)
            current = try await next(cluster)
        }
        guard Int64(bitmapClusters.count) == (bitmapLength - 1) / clusterBytes + 1 else {
            throw ScanError.malformed("Truncated allocation bitmap.")
        }
        for cluster in bitmapClusters { try await claim(cluster, owner: "allocation bitmap") }
        // The up-case table is FAT-chained metadata like the bitmap; claiming it makes a file
        // chain that overlaps it a detected cross-link instead of silently shared clusters.
        if let upcase {
            let length = try signed(upcase.number(24, 8))
            guard length > 0 else { throw ScanError.malformed("Invalid up-case table length.") }
            let required = (length - 1) / clusterBytes + 1
            var clusters: [UInt32] = []
            current = UInt32(try upcase.number(20, 4)); seen = []
            while let cluster = current {
                try validCluster(cluster)
                guard seen.insert(cluster).inserted, Int64(clusters.count) < required else {
                    throw ScanError.malformed("Invalid up-case table allocation.")
                }
                clusters.append(cluster)
                current = try await next(cluster)
            }
            guard Int64(clusters.count) == required else { throw ScanError.malformed("Truncated up-case table.") }
            for cluster in clusters { try await claim(cluster, owner: "up-case table") }
        }
    }
    func claim(_ cluster: UInt32, owner: String) async throws {
        try validCluster(cluster)
        if let previous = owners[cluster], previous != owner { throw ScanError.malformed("Cross-linked allocations.") }
        if exfat {
            guard try await allocatedInBitmap(cluster) else {
                throw ScanError.malformed("Live entry references a free allocation cluster.")
            }
        }
        owners[cluster] = owner
    }
    /// The active exFAT allocation bitmap's bit for `cluster`, read through a bounded page cache.
    func allocatedInBitmap(_ cluster: UInt32) async throws -> Bool {
        try validCluster(cluster)
        let index = Int64(cluster) - 2, byte = index / 8
        let bitmapCluster = bitmapClusters[Int(byte / clusterBytes)]
        let within = byte % clusterBytes
        let page = within / 4096 * 4096
        let offset = try checkedAdd(clusterOffset(bitmapCluster), page)
        if offset != bitmapPageOffset {
            bitmapPage = try await read(offset, Int(min(4096, clusterBytes - page)))
            bitmapPageOffset = offset
        }
        return bitmapPage[Int(within - page)] & (UInt8(1) << UInt8(index % 8)) != 0
    }
    func validCluster(_ cluster: UInt32) throws {
        guard cluster >= 2, cluster < (exfat ? 0xfffffff7 : 0x0ffffff0), Int64(cluster) - 2 < clusterCount else { throw ScanError.malformed("Invalid cluster.") }
    }
    func clusterOffset(_ cluster: UInt32) throws -> Int64 {
        try validCluster(cluster)
        return try checkedAdd(heapOffset, checkedMultiply(Int64(cluster) - 2, clusterBytes))
    }
    func next(_ cluster: UInt32) async throws -> UInt32? {
        let value = try await fatEntry(cluster)
        if exfat ? value == 0xffffffff : value >= 0x0ffffff8 { return nil }
        try validCluster(value)
        return value
    }
    /// The raw (masked) FAT entry for `cluster`; 0 means the cluster is free.
    func fatEntry(_ cluster: UInt32) async throws -> UInt32 {
        try validCluster(cluster)
        let position = Int64(cluster) * 4
        guard position <= fatBytes - 4 else { throw ScanError.malformed("FAT index outside table.") }
        let pageOffset = position / 65536 * 65536
        if pageOffset != fatPageOffset {
            fatPage = try await read(checkedAdd(fatOffset, pageOffset), Int(min(65536, fatBytes - pageOffset)))
            fatPageOffset = pageOffset
        }
        return UInt32(try fatPage.number(Int(position - pageOffset), 4)) & (exfat ? 0xffffffff : 0x0fffffff)
    }
    func validateFile(_ cluster: UInt32, length: Int64, contiguous: Bool, owner: String) async throws {
        if length == 0 { return }
        try validCluster(cluster)
        let required = (length - 1) / clusterBytes + 1
        guard required <= clusterCount else { throw ScanError.malformed("File exceeds volume.") }
        if contiguous {
            guard Int64(cluster) - 2 <= clusterCount - required else { throw ScanError.malformed("Contiguous file exceeds volume.") }
            for offset in 0..<required { try await claim(cluster + UInt32(offset), owner: owner) }
            return
        }
        var seen: Set<UInt32> = [], current: UInt32? = cluster
        var count: Int64 = 0
        while let value = current {
            try Task.checkCancellation()
            guard seen.insert(value).inserted, count < clusterCount else { throw ScanError.malformed("Allocation cycle.") }
            try await claim(value, owner: owner)
            count += 1
            current = try await next(value)
        }
        guard count >= required else { throw ScanError.malformed("Truncated file allocation.") }
    }
    func directory(_ first: UInt32, path: String, length: Int64?, contiguous: Bool) async throws -> [(UInt32, String, Int64?, Bool)] {
        var current: UInt32? = first, seen: Set<UInt32> = []
        var children: [(UInt32, String, Int64?, Bool)] = []
        var lfn: [Data] = [], entries: [Data] = [], entryOffset: Int64 = 0
        // Deleted metadata is collected separately: it is validated per entry and never aborts the scan.
        var deletedLfn: [Data] = [], deletedSet: [Data] = [], deletedOffset: Int64 = 0
        var bytes: Int64 = 0
        while let cluster = current {
            guard seen.insert(cluster).inserted, Int64(seen.count) <= clusterCount else { throw ScanError.malformed("Directory allocation cycle.") }
            let offset = try clusterOffset(cluster)
            // Read directories in bounded chunks, even when exFAT clusters are large.
            var within: Int64 = 0
            while within < clusterBytes {
                let count = Int(min(65536, clusterBytes - within))
                let data = try await read(checkedAdd(offset, within), count)
                for p in stride(from: 0, to: count, by: 32) {
                    if let length, bytes >= length { break }
                    let entry = data.subdata(in: p..<p+32)
                    let location = try checkedAdd(extent.offset, checkedAdd(offset, within + Int64(p)))
                    bytes += 32
                    let type = entry[0]
                    if type == 0 {
                        guard entries.isEmpty else { throw ScanError.malformed("Truncated exFAT entry set.") }
                        guard lfn.isEmpty else { throw ScanError.malformed("Unterminated long filename entries.") }
                        return children
                    }
                    if exfat {
                        if !deletedSet.isEmpty && entries.isEmpty {
                            if type & 0x80 == 0 && type != 0x05 {
                                deletedSet.append(entry)
                                if deletedSet.count == Int(deletedSet[0][1]) + 1 {
                                    try await deletedExfatEntry(deletedSet, at: deletedOffset, path: path)
                                    deletedSet = []
                                }
                                continue
                            }
                            // A live entry (or a new deleted primary) overwrote the rest of this set;
                            // drop it and process this entry normally.
                            deletedSet = []
                        }
                        if !entries.isEmpty {
                            entries.append(entry)
                            let needed = Int(entries[0][1]) + 1
                            if entries.count == needed {
                                if let child = try await exfatEntry(entries, at: entryOffset, path: path) { children.append(child) }
                                entries = []
                            }
                        } else if type == 0x85 {
                            guard entry[1] >= 2 else { throw ScanError.malformed("Missing exFAT secondary entries.") }
                            entries = [entry]; entryOffset = location
                        } else if type == 0x05 {
                            if entry[1] >= 2 { deletedSet = [entry]; deletedOffset = location }
                        } else if type & 0x80 != 0 && type & 0x20 == 0 && ![0x81,0x82,0x83].contains(type) {
                            throw ScanError.malformed("Unsupported critical exFAT entry.")
                        }
                    } else {
                        // Deleted (0xE5) slots reset any live run without error: deleted LFN slots
                        // legitimately precede their deleted short entry.
                        if type == 0xe5 {
                            lfn = []
                            if entry[11] == 0x0f {
                                deletedLfn.append(entry); if deletedLfn.count > 20 { deletedLfn.removeFirst() }
                                continue
                            }
                            let slots = deletedLfn; deletedLfn = []
                            try await deletedFatEntry(entry, long: slots, at: location, path: path)
                            continue
                        }
                        deletedLfn = []
                        if entry[11] == 0x0f { lfn.append(entry); if lfn.count > 20 { lfn = [] }; continue }
                        defer { lfn = [] }
                        // A live LFN run must be owned by a live short entry, never a volume label or dot entry.
                        if entry[11] & 8 != 0 {
                            guard lfn.isEmpty else { throw ScanError.malformed("Orphaned long filename entries.") }
                            continue
                        }
                        let name = fatName(entry, long: lfn)
                        if name == "." || name == ".." {
                            guard lfn.isEmpty else { throw ScanError.malformed("Orphaned long filename entries.") }
                            continue
                        }
                        try validName(name)
                        let cluster = UInt32(try entry.number(20, 2)) << 16 | UInt32(try entry.number(26, 2))
                        let size = try signed(entry.number(28, 4))
                        let fullPath = path + "/" + name
                        if entry[11] & 0x10 != 0 {
                            try validCluster(cluster); children.append((cluster, fullPath, nil, false))
                        } else {
                            try await validateFile(cluster, length: size, contiguous: false, owner: "file:\(location)")
                            try await emit(RecoveredFile(name: name, path: fullPath, sizeBytes: size,
                                modified: Self.fatTimestamp(entry),
                                sourceMetadata: SourceMetadata(filesystem: .fat32, volumeOffset: extent.offset,
                                    recordOffset: location, allocationStart: UInt64(cluster), contiguous: false,
                                    rawRecord: lfn.reduce(Data(), +) + entry)))
                        }
                    }
                }
                within += Int64(count)
            }
            if let length, bytes >= length { current = nil }
            else if contiguous {
                guard length != nil else { throw ScanError.malformed("Contiguous directory has no length.") }
                let (following, overflow) = cluster.addingReportingOverflow(1)
                guard !overflow else { throw ScanError.malformed("Cluster overflow.") }
                try validCluster(following); current = following
            } else { current = try await next(cluster) }
        }
        guard entries.isEmpty else { throw ScanError.malformed("Truncated exFAT entry set.") }
        guard lfn.isEmpty else { throw ScanError.malformed("Unterminated long filename entries.") }
        if let length, bytes < length { throw ScanError.malformed("Truncated directory allocation.") }
        return children
    }
    func validName(_ name: String) throws {
        guard !name.isEmpty, !name.contains("/"), !name.contains("\0"), name != ".", name != ".." else {
            throw ScanError.malformed("Invalid filename.")
        }
    }
    func fatName(_ entry: Data, long: [Data]) -> String {
        var checksum: UInt8 = 0
        for byte in entry.prefix(11) { checksum = ((checksum & 1) << 7) &+ (checksum >> 1) &+ byte }
        if !long.isEmpty, long.count <= 20, long[0][0] == UInt8(long.count) | 0x40,
           long.enumerated().allSatisfy({ index, data in
               data[0] == UInt8(long.count - index) | (index == 0 ? 0x40 : 0) && data[13] == checksum
           }), let name = lfnName(long) { return name }
        return shortName(entry)
    }
    /// Decodes LFN slots given in on-disk order (last name part first). Ordinals are not checked here.
    func lfnName(_ long: [Data]) -> String? {
        guard !long.isEmpty, long.count <= 20, long.allSatisfy({
            $0.count == 32 && $0[11] == 0x0f && $0[12] == 0 && $0[26] == 0 && $0[27] == 0
        }) else { return nil }
        var units: [UInt16] = []
        for data in long.reversed() {
            for offset in Self.lfnOffsets {
                if let value = try? data.number(offset, 2) { units.append(UInt16(value)) }
            }
        }
        let end = units.firstIndex(of: 0) ?? units.count
        let paddingValid = end == units.count || units.dropFirst(end + 1).allSatisfy { $0 == 0xffff }
        let nameUnits = Array(units.prefix(end))
        guard paddingValid, !nameUnits.isEmpty, nameUnits.count <= 255, !nameUnits.contains(0xffff) else { return nil }
        return strictUTF16(nameUnits)
    }
    static let lfnOffsets = [1,3,5,7,9,14,16,18,20,22,24,28,30]
    func shortName(_ entry: Data) -> String {
        var base = Array(entry.prefix(8)); if base[0] == 0x05 { base[0] = 0xe5 }
        var name = String(bytes: base, encoding: String.Encoding(rawValue: 0x80000400)) ?? String(decoding: base, as: UTF8.self)
        name = name.trimmingCharacters(in: .whitespaces)
        var ext = String(bytes: entry[8..<11], encoding: String.Encoding(rawValue: 0x80000400)) ?? ""
        ext = ext.trimmingCharacters(in: .whitespaces)
        if entry[12] & 8 != 0 { name = name.lowercased() }; if entry[12] & 16 != 0 { ext = ext.lowercased() }
        return name + (ext.isEmpty ? "" : "." + ext)
    }
    struct ExfatSet {
        let name: String, sizeBytes: Int64, validBytes: Int64, cluster: UInt32
        let contiguous: Bool, isDirectory: Bool, modified: Date?
    }
    /// Validates and decodes a file entry set. Entries must carry their in-use bits.
    func parseExfatSet(_ entries: [Data]) throws -> ExfatSet {
        let raw = entries.reduce(Data(), +)
        var checksum: UInt16 = 0
        for (index, byte) in raw.enumerated() where index != 2 && index != 3 {
            checksum = ((checksum & 1) << 15) &+ (checksum >> 1) &+ UInt16(byte)
        }
        guard entries.count >= 2, UInt64(checksum) == (try entries[0].number(2, 2)), entries[1][0] == 0xc0,
              entries.dropFirst(2).allSatisfy({ $0[0] == 0xc1 || $0[0] & 0xe0 == 0xe0 }) else {
            throw ScanError.malformed("Invalid exFAT file entry set.")
        }
        let stream = entries[1], nameLength = Int(stream[3])
        let filenameCount = (nameLength + 14) / 15
        guard nameLength > 0, entries.count >= 2 + filenameCount, stream[1] & 1 != 0,
              entries[2..<2+filenameCount].allSatisfy({ $0[0] == 0xc1 }),
              entries.dropFirst(2 + filenameCount).allSatisfy({ $0[0] & 0xe0 == 0xe0 }) else {
            throw ScanError.malformed("Invalid exFAT stream.")
        }
        var units: [UInt16] = []
        for entry in entries[2..<2+filenameCount] { for index in 0..<15 { units.append(UInt16(try entry.number(2 + index * 2, 2))) } }
        let filenameUnits = Array(units.prefix(nameLength))
        guard let name = strictUTF16(filenameUnits) else { throw ScanError.malformed("Invalid exFAT filename encoding.") }
        try validName(name)
        let size = try signed(stream.number(24, 8)), valid = try signed(stream.number(8, 8))
        guard valid <= size else { throw ScanError.malformed("Invalid exFAT valid data length.") }
        let primary = entries[0]
        return ExfatSet(name: name, sizeBytes: size, validBytes: valid, cluster: UInt32(try stream.number(20, 4)),
                        contiguous: stream[1] & 2 != 0, isDirectory: try primary.number(4, 2) & 0x10 != 0,
                        modified: Self.exfatTimestamp(UInt32(try primary.number(12, 4)),
                                                      tenMs: primary[21], utcOffset: primary[23]))
    }
    func exfatEntry(_ entries: [Data], at location: Int64, path: String) async throws -> (UInt32, String, Int64?, Bool)? {
        let raw = entries.reduce(Data(), +)
        let set = try parseExfatSet(entries)
        let size = set.sizeBytes, cluster = set.cluster, contiguous = set.contiguous
        let fullPath = path + "/" + set.name
        if set.isDirectory {
            guard size > 0, size % clusterBytes == 0, set.validBytes == size else { throw ScanError.malformed("Invalid exFAT directory size.") }
            try validCluster(cluster)
            return (cluster, fullPath, size, contiguous)
        }
        try await validateFile(cluster, length: size, contiguous: contiguous, owner: "file:\(location)")
        try await emit(RecoveredFile(name: set.name, path: fullPath, sizeBytes: size, modified: set.modified,
             sourceMetadata: SourceMetadata(filesystem: .exfat, volumeOffset: extent.offset,
                recordOffset: location, allocationStart: UInt64(cluster), contiguous: contiguous, rawRecord: raw)))
        return nil
    }

    // MARK: Deleted entries
    //
    // Deleted metadata is expected to be partly stale. Each entry is validated on its own and
    // skipped (never thrown) when implausible. Deleted entries never claim() clusters, so they
    // can't raise cross-links against live files or cause live files to be rejected.

    /// True when `required` clusters starting at `first` lie inside the heap and are all free in
    /// the active FAT (FAT32) or the active allocation bitmap (exFAT).
    func freeRun(from first: UInt32, required: Int64) async throws -> Bool {
        guard (try? validCluster(first)) != nil, required > 0,
              required <= clusterCount - (Int64(first) - 2) else { return false }
        for offset in 0..<required {
            if offset % 4096 == 0 { try Task.checkCancellation() }
            let cluster = first + UInt32(offset)
            let free = exfat ? !(try await allocatedInBitmap(cluster)) : try await fatEntry(cluster) == 0
            guard free else { return false }
        }
        return true
    }
    func deletedFatEntry(_ entry: Data, long: [Data], at location: Int64, path: String) async throws {
        // Volume labels and deleted directories are not reported; directories aren't descended into.
        guard entry[11] & 0x18 == 0 else { return }
        var used: [Data] = []
        var name = recoverDeletedLongName(entry, slots: long, used: &used)
        if name == nil {
            var short = entry; short[0] = UInt8(ascii: "_")
            name = shortName(short); used = []
        }
        guard let name, (try? validName(name)) != nil else { return }
        let cluster = UInt32(try entry.number(20, 2)) << 16 | UInt32(try entry.number(26, 2))
        let size = try signed(entry.number(28, 4))
        // Deletion zeroes the chain, so assume a contiguous run from the first cluster.
        if size > 0 {
            guard try await freeRun(from: cluster, required: (size - 1) / clusterBytes + 1) else { return }
        }
        try await emit(RecoveredFile(name: name, path: path + "/" + name, sizeBytes: size,
            modified: Self.fatTimestamp(entry), isDeleted: true,
            sourceMetadata: SourceMetadata(filesystem: .fat32, volumeOffset: extent.offset,
                recordOffset: location, allocationStart: UInt64(cluster), contiguous: true,
                rawRecord: used.reduce(Data(), +) + entry)))
    }
    /// Rebuilds a deleted long name. Ordinals are overwritten with 0xE5, so the run is identified by
    /// position (the slots immediately preceding the short entry) and a shared checksum.
    ///
    /// The short name's first byte is lost too, and the checksum is a bijection in that byte, so
    /// "some byte matches" proves nothing. Instead the byte is derived from the recovered long name
    /// the way short names are generated (its first character uppercased, or `_` for one that is
    /// not valid in 8.3), and the checksum must match with one of those candidates.
    func recoverDeletedLongName(_ entry: Data, slots: [Data], used: inout [Data]) -> String? {
        guard let last = slots.last else { return nil }
        let checksum = last[13]
        var run = Array(slots.reversed().prefix { $0[13] == checksum }.reversed())
        // The on-disk first slot of a run holds the name terminator; drop stale slots before it.
        if let start = run.lastIndex(where: { slot in Self.lfnOffsets.contains { (try? slot.number($0, 2)) == 0 } }) {
            run = Array(run[start...])
        }
        guard let name = lfnName(run) else { return nil }
        var candidates: [UInt8] = [UInt8(ascii: "_")]
        if let first = name.unicodeScalars.first(where: { $0 != "." && $0 != " " }), first.isASCII {
            let byte = UInt8(first.value)
            candidates.append((0x61...0x7a).contains(byte) ? byte - 0x20 : byte)
        }
        let tail = entry.dropFirst().prefix(10)
        let matches = candidates.contains { first in
            var sum: UInt8 = first
            for byte in tail { sum = ((sum & 1) << 7) &+ (sum >> 1) &+ byte }
            return sum == checksum
        }
        guard matches else { return nil }
        used = run
        return name
    }
    func deletedExfatEntry(_ entries: [Data], at location: Int64, path: String) async throws {
        // The set checksum covers the in-use bits, so validate with them restored.
        let restored = entries.map { entry -> Data in var copy = entry; copy[copy.startIndex] |= 0x80; return copy }
        guard let set = try? parseExfatSet(restored), !set.isDirectory else { return }
        if set.sizeBytes > 0 {
            let required = (set.sizeBytes - 1) / clusterBytes + 1
            // A FAT-chained (possibly fragmented) deleted file can't be followed reliably.
            guard set.contiguous || required == 1 else { return }
            guard try await freeRun(from: set.cluster, required: required) else { return }
        }
        try await emit(RecoveredFile(name: set.name, path: path + "/" + set.name, sizeBytes: set.sizeBytes,
            modified: set.modified, isDeleted: true,
            sourceMetadata: SourceMetadata(filesystem: .exfat, volumeOffset: extent.offset,
                recordOffset: location, allocationStart: UInt64(set.cluster), contiguous: true,
                rawRecord: entries.reduce(Data(), +))))
    }

    // MARK: Timestamps

    /// FAT32 write date/time (offsets 24 and 22): local time, 2-second resolution.
    static func fatTimestamp(_ entry: Data) -> Date? {
        guard let time = try? entry.number(22, 2), let date = try? entry.number(24, 2) else { return nil }
        return timestamp(date: Int(date), time: Int(time), centiseconds: 0, utcOffsetMinutes: nil)
    }
    /// exFAT last-modified timestamp with its 10 ms increment, in the recorded UTC offset when that
    /// offset is valid and in local time otherwise.
    static func exfatTimestamp(_ stamp: UInt32, tenMs: UInt8, utcOffset: UInt8) -> Date? {
        guard tenMs <= 199 else { return nil }
        var offset: Int?
        if utcOffset & 0x80 != 0 {
            let raw = Int(utcOffset & 0x7f), quarters = raw >= 64 ? raw - 128 : raw
            if (-48...56).contains(quarters) { offset = quarters * 15 }
        }
        return timestamp(date: Int(stamp >> 16), time: Int(stamp & 0xffff), centiseconds: Int(tenMs), utcOffsetMinutes: offset)
    }
    /// DOS date/time fields; any out-of-range component yields nil rather than a normalized date.
    static func timestamp(date: Int, time: Int, centiseconds: Int, utcOffsetMinutes: Int?) -> Date? {
        let day = date & 31, month = (date >> 5) & 15, year = 1980 + (date >> 9)
        let second = (time & 31) * 2, minute = (time >> 5) & 63, hour = time >> 11
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard (1...12).contains(month), (1...days[month - 1]).contains(day),
              hour <= 23, minute <= 59, second <= 58 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        if let utcOffsetMinutes {
            guard let zone = TimeZone(secondsFromGMT: utcOffsetMinutes * 60) else { return nil }
            calendar.timeZone = zone
        } else {
            calendar.timeZone = .current
        }
        let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        return calendar.date(from: components)?.addingTimeInterval(Double(centiseconds) / 100)
    }
}
