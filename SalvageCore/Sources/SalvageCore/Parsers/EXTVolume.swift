import Foundation

/// Read-only EXT2/3/4 parser. All offsets are relative to one validated partition; no read can
/// escape `extent`. Live metadata is fail-closed (`ScanError.malformed`); deleted-file recovery
/// is best effort and skips any candidate that does not validate.
actor EXTVolume {
    static let isImplemented = true
    let reader: any BlockReader
    let extent: VolumeExtent
    let emit: @Sendable (RecoveredFile) async throws -> Void

    var geometry = EXTGeometry()
    var groups: [EXTGroup] = []
    var limits = EXTLimits()
    var stats = EXTScanStats()
    var liveInodes: Set<UInt32> = []
    var visitedDirectories: Set<UInt32> = []
    /// Every directory the live walk reached, as a compact parent reference (index 0 is the root).
    /// Paths are built only when a file is emitted, so this grows with the number of directories
    /// in the image, never with path depth times directory count.
    var directories: [EXTDirectoryRecord] = []
    var candidates: [EXTDeletedCandidate] = []
    var candidateNameBytes = 0
    var candidateInodes: Set<UInt32> = []
    /// Inodes with a stale entry that could not be kept (past the candidate cap), so their
    /// collected entries can't be shown to agree.
    var conflictedInodes: Set<UInt32> = []
    var mappingCache: [UInt32: EXTMapping] = [:]
    var mappingCacheEntries = 0
    var deletedWorkRemaining: UInt64 = 0
    var bitmapCache: [UInt64: Data] = [:]
    var inodeBlockNumber: Int64 = -1
    var inodeBlock = Data()

    /// Bounds on traversal so hostile metadata always terminates.
    static let maxDirectoryDepth = 2048
    static let maxExtentDepth = 5
    static let maxCandidates = 200_000

    init(reader: any BlockReader, extent: VolumeExtent, emit: @escaping @Sendable (RecoveredFile) async throws -> Void) {
        self.reader = reader; self.extent = extent; self.emit = emit
    }

    /// Lowers the bounds (tests only; the defaults are the production limits).
    func setLimits(_ limits: EXTLimits) { self.limits = limits }

    func read(_ offset: Int64, _ count: Int) async throws -> Data {
        try Task.checkCancellation()
        guard offset >= 0, count >= 0, offset <= extent.length, Int64(count) <= extent.length - offset else {
            throw ScanError.malformed("Read outside partition.")
        }
        let data = try await reader.read(at: checkedAdd(extent.offset, offset), count: count)
        guard data.count == count else { throw ScanError.malformed("Truncated structure.") }
        return data
    }
    func readBlock(_ block: UInt64) async throws -> Data {
        try validBlock(block)
        return try await read(checkedMultiply(signed(block), geometry.blockSize), Int(geometry.blockSize))
    }

    func scan() async throws {
        let superblock = try await read(1024, 1024)
        geometry = try EXTGeometry.parse(superblock, volumeLength: extent.length)
        try await loadGroups()
        try await walkLiveTree()
        try await recoverDeleted()
    }

    // MARK: Group descriptors

    func loadGroups() async throws {
        let g = geometry
        let tableBytes = try checkedMultiply(signed(g.groupCount), Int64(g.descriptorSize))
        let tableBlock = g.firstDataBlock + 1
        let tableBlocks = UInt64((tableBytes + g.blockSize - 1) / g.blockSize)
        guard tableBlock + tableBlocks <= g.blocksCount else { throw ScanError.malformed("Group descriptors exceed volume.") }
        let tableOffset = try checkedMultiply(signed(tableBlock), g.blockSize)
        let itableBlocks = (UInt64(g.inodesPerGroup) * UInt64(g.inodeSize) + UInt64(g.blockSize) - 1) / UInt64(g.blockSize)
        groups.reserveCapacity(Int(g.groupCount))
        var done: Int64 = 0
        while done < tableBytes {
            let count = Int(min(1024 * 1024, tableBytes - done) / Int64(g.descriptorSize) * Int64(g.descriptorSize))
            let chunk = try await read(checkedAdd(tableOffset, done), count)
            for p in stride(from: 0, to: count, by: g.descriptorSize) {
                let wide = g.descriptorSize >= 64
                func field(_ lo: Int, _ hi: Int) throws -> UInt64 {
                    try chunk.number(p + lo, 4) | (wide ? chunk.number(p + hi, 4) << 32 : 0)
                }
                let group = EXTGroup(blockBitmap: try field(0, 0x20), inodeBitmap: try field(4, 0x24),
                                     inodeTable: try field(8, 0x28), flags: UInt16(try chunk.number(p + 18, 2)))
                for block in [group.blockBitmap, group.inodeBitmap] {
                    guard block > g.firstDataBlock, block < g.blocksCount else {
                        throw ScanError.malformed("Group bitmap outside volume.")
                    }
                }
                guard group.inodeTable > g.firstDataBlock, group.inodeTable <= g.blocksCount,
                      itableBlocks <= g.blocksCount - group.inodeTable else {
                    throw ScanError.malformed("Inode table outside volume.")
                }
                groups.append(group)
            }
            done += Int64(count)
        }
        guard UInt64(groups.count) == g.groupCount else { throw ScanError.malformed("Truncated group descriptors.") }
    }

    // MARK: Blocks, inodes and bitmaps

    func validBlock(_ block: UInt64) throws {
        guard block > geometry.firstDataBlock, block < geometry.blocksCount else {
            throw ScanError.malformed("Block outside volume.")
        }
    }

    /// Byte offset of an inode in the volume plus its raw bytes.
    func inode(_ number: UInt32) async throws -> (offset: Int64, data: Data) {
        let g = geometry
        guard number >= 1, number <= g.inodesCount else { throw ScanError.malformed("Inode number out of range.") }
        let index = UInt64(number - 1)
        let group = groups[Int(index / UInt64(g.inodesPerGroup))]
        let within = try checkedMultiply(signed(index % UInt64(g.inodesPerGroup)), Int64(g.inodeSize))
        let offset = try checkedAdd(checkedMultiply(signed(group.inodeTable), g.blockSize), within)
        // Inodes never straddle blocks (inode size is a power of two no larger than the block).
        let blockStart = offset / g.blockSize * g.blockSize
        if blockStart != inodeBlockNumber {
            inodeBlock = try await read(blockStart, Int(g.blockSize))
            inodeBlockNumber = blockStart
        }
        let start = Int(offset - blockStart)
        return (offset, inodeBlock.subdata(in: start..<start + g.inodeSize))
    }

    /// Returns a bitmap bit, or nil when the group's bitmap is not initialized on disk.
    func bitmapBit(blockOf group: Int, bit: UInt64, inodeBitmap: Bool) async throws -> Bool? {
        let descriptor = groups[group]
        if geometry.groupChecksums && descriptor.flags & (inodeBitmap ? 0x1 : 0x2) != 0 { return nil }
        let block = inodeBitmap ? descriptor.inodeBitmap : descriptor.blockBitmap
        let data: Data
        if let cached = bitmapCache[block] { data = cached } else {
            data = try await readBlock(block)
            if bitmapCache.count >= 256 { bitmapCache.removeAll() }
            bitmapCache[block] = data
        }
        return data[Int(bit / 8)] & (UInt8(1) << UInt8(bit % 8)) != 0
    }
    func blockInUse(_ block: UInt64) async throws -> Bool? {
        try validBlock(block)
        let relative = block - geometry.firstDataBlock
        let perGroup = UInt64(geometry.blocksPerGroup)
        return try await bitmapBit(blockOf: Int(relative / perGroup), bit: relative % perGroup, inodeBitmap: false)
    }
    func inodeInUse(_ number: UInt32) async throws -> Bool? {
        let index = UInt64(number - 1), perGroup = UInt64(geometry.inodesPerGroup)
        return try await bitmapBit(blockOf: Int(index / perGroup), bit: index % perGroup, inodeBitmap: true)
    }

    // MARK: Data mapping (extent trees and block maps)

    /// Maps an inode's data. `limit` caps the data plus tree/indirect blocks visited; exceeding it
    /// is `malformed`.
    func mapping(_ inode: EXTInode, limit: UInt64) async throws -> EXTMapping {
        stats.mappingComputations += 1
        var map = EXTMapping(limit: limit)
        if inode.flags & EXTInode.inlineDataFlag != 0 { throw ScanError.malformed("Unsupported inline-data inode.") }
        if inode.flags & EXTInode.extentsFlag != 0 {
            guard geometry.extents else { throw ScanError.malformed("Extent inode without extents feature.") }
            var visited: Set<UInt64> = [], next: UInt64 = 0
            try await walkExtentNode(inode.blockArea, root: true, expectedDepth: nil, low: 0, high: 1 << 32,
                                     map: &map, visited: &visited, next: &next)
        } else {
            var visited: Set<UInt64> = []
            let perBlock = UInt64(geometry.blockSize / 4)
            var logical: UInt64 = 0
            for slot in 0..<15 {
                let level = max(0, slot - 11)
                let pointer = try inode.blockArea.number(slot * 4, 4)
                if pointer != 0 {
                    try await walkBlockMap(pointer, level: level, logical: logical, map: &map, visited: &visited)
                }
                var span: UInt64 = 1
                for _ in 0..<level { span *= perBlock }
                logical += span
            }
        }
        return map
    }

    /// A live file's mapping, cached per inode number so hard links are mapped once.
    func liveMapping(_ inode: EXTInode, number: UInt32) async throws -> EXTMapping {
        if let cached = mappingCache[number] { return cached }
        let map = try await mapping(inode, limit: geometry.blocksCount)
        let entries = map.runs.count + map.metadata.count
        if entries <= limits.maxCachedMappingEntries {
            if mappingCacheEntries + entries > limits.maxCachedMappingEntries {
                mappingCache.removeAll(); mappingCacheEntries = 0
            }
            mappingCache[number] = map
            mappingCacheEntries += entries
        }
        return map
    }

    func walkBlockMap(_ block: UInt64, level: Int, logical: UInt64, map: inout EXTMapping,
                      visited: inout Set<UInt64>) async throws {
        try validBlock(block)
        if level == 0 {
            try map.add(logical: logical, physical: block, count: 1, initialized: true)
            return
        }
        guard visited.insert(block).inserted else { throw ScanError.malformed("Block-map cycle.") }
        try map.addMetadata(block)
        let data = try await readBlock(block)
        let perBlock = UInt64(geometry.blockSize / 4)
        var span: UInt64 = 1
        for _ in 0..<(level - 1) { span *= perBlock }
        for index in 0..<Int(perBlock) {
            let pointer = try data.number(index * 4, 4)
            if pointer == 0 { continue }
            try await walkBlockMap(pointer, level: level - 1, logical: logical + UInt64(index) * span,
                                   map: &map, visited: &visited)
        }
    }

    func walkExtentNode(_ node: Data, root: Bool, expectedDepth: Int?, low: UInt64, high: UInt64,
                        map: inout EXTMapping, visited: inout Set<UInt64>, next: inout UInt64) async throws {
        guard try node.number(0, 2) == 0xf30a else { throw ScanError.malformed("Invalid extent header.") }
        let entries = Int(try node.number(2, 2)), capacity = Int(try node.number(4, 2))
        let depth = Int(try node.number(6, 2))
        guard capacity <= (node.count - 12) / 12, entries <= capacity, depth <= Self.maxExtentDepth,
              expectedDepth.map({ $0 == depth }) ?? true, entries > 0 || (root && depth == 0) else {
            throw ScanError.malformed("Invalid extent node.")
        }
        var previous: UInt64? = nil
        for index in 0..<entries {
            try Task.checkCancellation()
            let p = 12 + index * 12
            let first = try node.number(p, 4)
            if let previous { guard first > previous else { throw ScanError.malformed("Extents out of order.") } }
            previous = first
            if depth == 0 {
                let raw = try node.number(p + 4, 2)
                let initialized = raw <= 32768
                let length = initialized ? raw : raw - 32768
                let start = try node.number(p + 6, 2) << 32 | node.number(p + 8, 4)
                guard length > 0, first >= next, first >= low, first + length <= high,
                      start > geometry.firstDataBlock, start <= geometry.blocksCount,
                      length <= geometry.blocksCount - start else {
                    throw ScanError.malformed("Invalid extent.")
                }
                try map.add(logical: first, physical: start, count: length, initialized: initialized)
                next = first + length
            } else {
                let child = try node.number(p + 8, 2) << 32 | node.number(p + 4, 4)
                let childHigh = index + 1 < entries ? try node.number(p + 12, 4) : high
                guard first >= low || index == 0, childHigh <= high else {
                    throw ScanError.malformed("Invalid extent index.")
                }
                try validBlock(child)
                guard visited.insert(child).inserted else { throw ScanError.malformed("Extent tree cycle.") }
                try map.addMetadata(child)
                let data = try await readBlock(child)
                try await walkExtentNode(data, root: false, expectedDepth: depth - 1, low: max(first, low),
                                         high: childHigh, map: &map, visited: &visited, next: &next)
            }
        }
    }

    // MARK: Directory walk

    /// The path of a directory reached by the live walk ("" for the root).
    func path(of index: Int) -> String {
        var names: [String] = []
        var current = index
        // Parents are always recorded before their children, so this walk strictly descends.
        while current > 0 {
            names.append(directories[current].name)
            current = directories[current].parent
        }
        return names.reversed().map { "/" + $0 }.joined()
    }

    func walkLiveTree() async throws {
        let rootInode = try await inode(2)
        let root = try EXTInode(rootInode.data, inodeSize: geometry.inodeSize)
        guard root.isDirectory else { throw ScanError.malformed("Root inode is not a directory.") }
        visitedDirectories.insert(2); liveInodes.insert(2)
        directories = [EXTDirectoryRecord(parent: -1, name: "", changed: root.changed)]
        var pending: [EXTPendingDirectory] = [EXTPendingDirectory(inode: 2, index: 0, depth: 0)]
        stats.peakPendingDirectories = 1
        while let current = pending.popLast() {
            let directory = try EXTInode(try await inode(current.inode).data, inodeSize: geometry.inodeSize)
            let path = path(of: current.index)
            let children = try await readDirectory(directory, index: current.index)
            for child in children {
                liveInodes.insert(child.inode)
                let (offset, data) = try await inode(child.inode)
                let node = try EXTInode(data, inodeSize: geometry.inodeSize)
                guard node.mode != 0 else {
                    // With an unreplayed journal the inode table can lag the directory, so the
                    // entry is skipped; on a clean volume this is corruption.
                    if geometry.needsRecovery { stats.skippedLiveEntries += 1; continue }
                    throw ScanError.malformed("Live entry references a free inode.")
                }
                if node.isDirectory {
                    guard current.depth < limits.maxDirectoryDepth else {
                        throw ScanError.malformed("Directory nesting too deep.")
                    }
                    guard visitedDirectories.insert(child.inode).inserted else {
                        throw ScanError.malformed("Directory cycle or hard-linked directory.")
                    }
                    directories.append(EXTDirectoryRecord(parent: current.index, name: child.name, changed: node.changed))
                    stats.directoryNameBytes += child.name.utf8.count
                    pending.append(EXTPendingDirectory(inode: child.inode, index: directories.count - 1,
                                                       depth: current.depth + 1))
                    stats.peakPendingDirectories = max(stats.peakPendingDirectories, pending.count)
                } else if node.isRegular {
                    let map = try await liveMapping(node, number: child.inode)
                    try await emit(file(name: child.name, path: path + "/" + child.name, inode: node,
                                        number: child.inode, offset: offset, raw: data + child.raw,
                                        contiguous: map.runs.count <= 1, deleted: false))
                }
            }
        }
    }

    /// Reads every block of a live directory linearly. Htree index blocks parse as entries that
    /// span the block, so the index is never followed.
    func readDirectory(_ directory: EXTInode, index: Int) async throws -> [EXTDirent] {
        let blockSize = UInt64(geometry.blockSize)
        guard directory.size > 0, directory.size % blockSize == 0, directory.size / blockSize <= geometry.blocksCount else {
            throw ScanError.malformed("Invalid directory size.")
        }
        let blocks = directory.size / blockSize
        let map = try await mapping(directory, limit: geometry.blocksCount)
        var children: [EXTDirent] = []
        var expected: UInt64 = 0
        for run in map.runs where run.logical < blocks {
            guard run.logical == expected, run.initialized else { throw ScanError.malformed("Directory hole.") }
            for k in 0..<min(run.count, blocks - run.logical) {
                let data = try await readBlock(run.physical + k)
                try parseDirectoryBlock(data, logical: run.logical + k, indexed: directory.flags & EXTInode.indexFlag != 0,
                                        directory: index, children: &children)
            }
            expected = min(blocks, run.logical + run.count)
        }
        guard expected == blocks else { throw ScanError.malformed("Truncated directory.") }
        return children
    }

    func parseDirectoryBlock(_ data: Data, logical: UInt64, indexed: Bool, directory: Int,
                             children: inout [EXTDirent]) throws {
        let size = data.count
        var p = 0
        while p < size {
            guard p + 8 <= size else { throw ScanError.malformed("Truncated directory entry.") }
            let number = UInt32(try data.number(p, 4))
            let length = recordLength(try data.number(p + 4, 2))
            let nameLength = geometry.fileType ? Int(data[p + 6]) : Int(try data.number(p + 6, 2))
            guard length >= 12, length % 4 == 0, length <= size - p, nameLength <= 255, 8 + nameLength <= length else {
                throw ScanError.malformed("Invalid directory entry length.")
            }
            let nameBytes = data.subdata(in: p + 8..<p + 8 + nameLength)
            var name = ""
            if number != 0 {
                guard nameLength > 0, number <= geometry.inodesCount else { throw ScanError.malformed("Invalid directory entry.") }
                guard !nameBytes.contains(0), !nameBytes.contains(0x2f) else { throw ScanError.malformed("Invalid filename.") }
                name = Self.liveName(nameBytes)
                if name != "." && name != ".." {
                    children.append(EXTDirent(inode: number, name: name, raw: data.subdata(in: p..<p + 8 + nameLength)))
                }
            }
            // An htree root's ".." entry and a dx_node's empty spanning entry hold index data, not
            // stale entries; leave them alone.
            let indexBlock = indexed && ((logical == 0 && name == "..") || (number == 0 && p == 0 && length == size))
            if !indexBlock {
                scanGap(data, from: p + Self.align(8 + nameLength), to: p + length, directory: directory)
            }
            p += length
        }
    }

    func recordLength(_ raw: UInt64) -> Int {
        if geometry.blockSize == 65536 && (raw == 0 || raw == 65535) { return 65536 }
        return Int(raw)
    }
    static func align(_ value: Int) -> Int { (value + 3) & ~3 }
    static func liveName(_ bytes: Data) -> String {
        if let name = String(bytes: bytes, encoding: .utf8), Data(name.utf8) == bytes { return name }
        // Linux names are arbitrary bytes. Escape non-UTF-8 bytes visibly instead of replacing
        // them silently; the raw entry bytes stay in the record.
        return bytes.map { $0 < 0x80 ? String(UnicodeScalar($0)) : String(format: "\\x%02X", $0) }.joined()
    }

    // MARK: Deleted-file recovery (best effort)

    /// Looks for plausible removed entries in the slack after a live entry's real length.
    func scanGap(_ data: Data, from start: Int, to end: Int, directory: Int) {
        // An unreplayed journal leaves the bitmaps untrustworthy, so nothing found here could be
        // emitted; don't collect.
        guard !geometry.needsRecovery else { return }
        var p = start
        while p + 12 <= end {
            guard let number = try? data.number(p, 4), let raw = try? data.number(p + 4, 2),
                  let header = try? data.number(p, 8) else { return }
            let length = recordLength(raw)
            let nameLength = Int(data[p + 6]), type = data[p + 7]
            let plausibleType = geometry.fileType ? type == 1 : type == 0
            if number >= UInt64(geometry.firstInode), number <= UInt64(geometry.inodesCount), nameLength > 0,
               plausibleType, 8 + nameLength <= end - p, length % 4 == 0,
               length >= Self.align(8 + nameLength), length <= end - p {
                let nameBytes = data.subdata(in: p + 8..<p + 8 + nameLength)
                if !nameBytes.contains(0), !nameBytes.contains(0x2f), let name = String(bytes: nameBytes, encoding: .utf8),
                   Data(name.utf8) == nameBytes, name != ".", name != ".." {
                    record(EXTDeletedCandidate(inode: UInt32(number), directory: directory, header: header, name: name))
                    p += Self.align(8 + nameLength)
                    continue
                }
            }
            p += 4
        }
    }

    func record(_ candidate: EXTDeletedCandidate) {
        let bytes = candidate.name.utf8.count
        if candidates.count < limits.maxCandidates, candidateNameBytes + bytes <= limits.maxCandidateNameBytes {
            candidates.append(candidate)
            candidateNameBytes += bytes
            candidateInodes.insert(candidate.inode)
        } else if candidateInodes.contains(candidate.inode) {
            // The entry itself is dropped, but it shows its inode has another stale name.
            conflictedInodes.insert(candidate.inode)
        }
    }

    func recoverDeleted() async throws {
        // An unreplayed journal means the bitmaps may be stale: free-block evidence can't be
        // trusted, so no deleted file is recovered from metadata on such a volume.
        guard !geometry.needsRecovery else { candidates = []; return }
        deletedWorkRemaining = limits.deletedWorkBudget ?? (4 * geometry.blocksCount + 1_000_000)
        candidates.sort { $0.inode < $1.inode }
        var accepted: [EXTDeletedCandidate] = [], contiguous: [Bool] = []
        var claims: [EXTClaim] = []
        var start = 0
        evaluation: while start < candidates.count {
            let first = candidates[start]
            var end = start + 1
            while end < candidates.count, candidates[end].inode == first.inode { end += 1 }
            defer { start = end }
            // Several stale entries naming different files (mv then rm, or reuse) can't tell which
            // name is right, so the inode is skipped entirely.
            guard candidates[start..<end].allSatisfy({ $0.directory == first.directory && $0.name == first.name }),
                  !liveInodes.contains(first.inode), !conflictedInodes.contains(first.inode) else { continue }
            do {
                guard let found = try await evaluate(first) else { continue }
                guard claims.count + found.claims.count <= limits.maxClaimedRanges else { break evaluation }
                claims.append(contentsOf: found.claims.map { EXTClaim(start: $0.0, end: $0.1, owner: accepted.count) })
                accepted.append(first); contiguous.append(found.contiguous)
            } catch ScanError.malformed(_) {
                // An implausible deleted candidate is skipped and never aborts the scan.
                continue
            } catch is EXTWorkBudgetExhausted {
                stats.deletedBudgetExhausted = true
                break evaluation
            }
        }
        candidates = []
        // Two deleted files claiming the same block can't both be right; skip all of them so data
        // is never attributed to the wrong file.
        let overlapping = Self.overlappingOwners(claims, owners: accepted.count)
        for (index, candidate) in accepted.enumerated() where !overlapping[index] {
            let (offset, data) = try await inode(candidate.inode)
            let node = try EXTInode(data, inodeSize: geometry.inodeSize)
            try await emit(file(name: candidate.name, path: path(of: candidate.directory) + "/" + candidate.name,
                                inode: node, number: candidate.inode, offset: offset, raw: data + candidate.raw,
                                contiguous: contiguous[index], deleted: true))
        }
    }

    /// Charges deleted-file work (mapped blocks and bitmap checks) against the per-volume budget.
    func spend(_ amount: UInt64) throws {
        guard amount <= deletedWorkRemaining else { deletedWorkRemaining = 0; throw EXTWorkBudgetExhausted() }
        deletedWorkRemaining -= amount
        stats.deletedWorkSpent += amount
    }

    /// Mapped blocks a deleted file may have beyond its size: tree/indirect blocks plus a little
    /// preallocation past EOF.
    static func mappingSlack(_ needed: UInt64) -> UInt64 { 16 + needed / 16 }

    /// Validates one deleted candidate. Returns the physical ranges it claims, or nil to skip it.
    func evaluate(_ candidate: EXTDeletedCandidate) async throws -> (claims: [(UInt64, UInt64)], contiguous: Bool)? {
        // The inode must be free, and a deleted regular file with nonzero size.
        try spend(1)
        guard try await inodeInUse(candidate.inode) == false else { return nil }
        let (_, data) = try await inode(candidate.inode)
        let node = try EXTInode(data, inodeSize: geometry.inodeSize)
        guard node.isRegular, node.dtime != 0 || node.links == 0, node.size > 0,
              node.flags & EXTInode.encryptFlag == 0 else { return nil }
        // The unlink that left this entry stale also changed its directory. A deletion time after
        // that change means the inode was reused and deleted again after the entry went stale.
        guard Int64(node.dtime) <= directories[candidate.directory].changed else { return nil }
        let blockSize = UInt64(geometry.blockSize)
        let needed = (node.size - 1) / blockSize + 1
        guard needed < geometry.blocksCount else { return nil }
        // A mapping much larger than the size needs is not this file's; the limit also bounds the work.
        // The whole limit is charged up front (a mapping that fails part-way still did the work),
        // and what it didn't use is refunded.
        let limit = min(geometry.blocksCount, needed + Self.mappingSlack(needed))
        try spend(limit)
        let map = try await mapping(node, limit: limit)
        deletedWorkRemaining += limit - map.visited
        stats.deletedWorkSpent -= limit - map.visited
        // Every logical block within the size must still be mapped (no partial recovery).
        var expected: UInt64 = 0
        for run in map.runs {
            if run.logical >= needed { break }
            guard run.logical == expected else { return nil }
            expected = min(needed, run.logical + run.count)
        }
        guard expected == needed else { return nil }
        // Every block the old mapping names, data and tree/indirect blocks, must now be free.
        var claims: [(UInt64, UInt64)] = []
        for block in map.metadata {
            try spend(1)
            guard try await blockInUse(block) == false else { return nil }
            claims.append((block, block + 1))
        }
        for run in map.runs {
            for k in 0..<run.count {
                try Task.checkCancellation()
                try spend(1)
                guard try await blockInUse(run.physical + k) == false else { return nil }
            }
            claims.append((run.physical, run.physical + run.count))
        }
        return (claims, map.runs.count <= 1)
    }

    /// Marks every owner that has a range overlapping any other range (its own included).
    static func overlappingOwners(_ claims: [EXTClaim], owners: Int) -> [Bool] {
        var flagged = [Bool](repeating: false, count: owners)
        var reachEnd: UInt64 = 0, reachOwner = -1
        for claim in claims.sorted(by: { $0.start < $1.start }) {
            if reachOwner >= 0, claim.start < reachEnd {
                flagged[claim.owner] = true; flagged[reachOwner] = true
            }
            if claim.end > reachEnd { reachEnd = claim.end; reachOwner = claim.owner }
        }
        return flagged
    }

    func file(name: String, path: String, inode: EXTInode, number: UInt32, offset: Int64, raw: Data,
              contiguous: Bool, deleted: Bool) throws -> RecoveredFile {
        RecoveredFile(name: name, path: path, sizeBytes: try signed(inode.size), modified: inode.modified,
                      isDeleted: deleted,
                      sourceMetadata: SourceMetadata(filesystem: .ext, volumeOffset: extent.offset,
                                                     recordOffset: try checkedAdd(extent.offset, offset),
                                                     allocationStart: UInt64(number),
                                                     contiguous: contiguous, rawRecord: raw))
    }
}

// MARK: - Supporting types

/// Traversal and memory bounds. The defaults are the production limits; tests may lower them.
struct EXTLimits: Sendable {
    var maxDirectoryDepth = EXTVolume.maxDirectoryDepth
    var maxCandidates = EXTVolume.maxCandidates
    /// Total name bytes kept across deleted candidates.
    var maxCandidateNameBytes = 16 << 20
    /// Physical ranges kept for the deleted-candidate overlap check.
    var maxClaimedRanges = 2_000_000
    /// Runs plus tree blocks kept in the per-inode mapping cache.
    var maxCachedMappingEntries = 1_000_000
    /// Deleted-candidate work (mapped blocks plus bitmap checks); nil means 4 × blocks + 1,000,000.
    var deletedWorkBudget: UInt64? = nil
}

/// Counters exposed for tests.
struct EXTScanStats: Sendable {
    var peakPendingDirectories = 0
    var directoryNameBytes = 0
    var mappingComputations = 0
    var deletedWorkSpent: UInt64 = 0
    var deletedBudgetExhausted = false
    var skippedLiveEntries = 0
}

struct EXTWorkBudgetExhausted: Error {}

struct EXTGeometry: Sendable {
    var blockSize: Int64 = 1024
    var blocksCount: UInt64 = 0
    var firstDataBlock: UInt64 = 0
    var blocksPerGroup: UInt32 = 0
    var inodesPerGroup: UInt32 = 0
    var inodesCount: UInt32 = 0
    var inodeSize = 128
    var firstInode: UInt32 = 11
    var groupCount: UInt64 = 0
    var descriptorSize = 32
    var fileType = false
    var extents = false
    var groupChecksums = false
    var needsRecovery = false

    static let incompatFileType: UInt64 = 0x2, incompatRecover: UInt64 = 0x4, incompatMetaBG: UInt64 = 0x10
    static let incompatExtents: UInt64 = 0x40, incompat64Bit: UInt64 = 0x80, incompatFlexBG: UInt64 = 0x200
    static let incompatLargeDir: UInt64 = 0x4000
    /// Incompat features this read-only parser fully understands. `meta_bg` is not implemented,
    /// so it is deliberately absent; every other bit (inline_data, encrypt, casefold, journal_dev,
    /// compression, mmp, csum_seed, ...) is refused rather than parsed partially.
    static let supportedIncompat = incompatFileType | incompatRecover | incompatExtents | incompat64Bit |
        incompatFlexBG | incompatLargeDir
    static let roCompatGDTChecksum: UInt64 = 0x10, roCompatMetadataChecksum: UInt64 = 0x400
    /// bigalloc makes bitmap bits clusters rather than blocks; refused rather than misread.
    static let roCompatBigalloc: UInt64 = 0x200

    static func parse(_ sb: Data, volumeLength: Int64) throws -> EXTGeometry {
        guard try sb.number(56, 2) == 0xef53 else { throw ScanError.malformed("Missing ext superblock magic.") }
        var g = EXTGeometry()
        let revision = try sb.number(76, 4)
        guard revision <= 1 else { throw ScanError.unsupportedFilesystem }
        let incompat = revision == 0 ? 0 : try sb.number(96, 4)
        let roCompat = revision == 0 ? 0 : try sb.number(100, 4)
        guard incompat & ~supportedIncompat == 0, roCompat & roCompatBigalloc == 0 else {
            throw ScanError.unsupportedFilesystem
        }
        if roCompat & roCompatMetadataChecksum != 0 {
            guard sb[373] == 1 else { throw ScanError.malformed("Unknown metadata checksum type.") }
            guard UInt64(crc32cUpdate(0xffffffff, sb.prefix(1020))) == (try sb.number(1020, 4)) else {
                throw ScanError.malformed("Invalid superblock checksum.")
            }
        }
        let logBlock = try sb.number(24, 4)
        guard logBlock <= 6 else { throw ScanError.malformed("Invalid ext block size.") }
        g.blockSize = Int64(1024) << logBlock
        g.fileType = incompat & incompatFileType != 0
        g.extents = incompat & incompatExtents != 0
        g.needsRecovery = incompat & incompatRecover != 0
        g.groupChecksums = roCompat & (roCompatGDTChecksum | roCompatMetadataChecksum) != 0
        let wide = incompat & incompat64Bit != 0
        g.blocksCount = try sb.number(4, 4) | (wide ? sb.number(336, 4) << 32 : 0)
        g.firstDataBlock = try sb.number(20, 4)
        g.blocksPerGroup = UInt32(try sb.number(32, 4))
        g.inodesPerGroup = UInt32(try sb.number(40, 4))
        g.inodesCount = UInt32(try sb.number(0, 4))
        if revision >= 1 {
            g.inodeSize = Int(try sb.number(88, 2))
            g.firstInode = UInt32(try sb.number(84, 4))
        }
        if wide {
            g.descriptorSize = Int(try sb.number(254, 2))
            guard g.descriptorSize >= 64, g.descriptorSize <= 1024, g.descriptorSize & (g.descriptorSize - 1) == 0 else {
                throw ScanError.malformed("Invalid group descriptor size.")
            }
        }
        let bitsPerBlock = UInt64(g.blockSize) * 8
        guard g.firstDataBlock == (g.blockSize == 1024 ? 1 : 0),
              g.blocksPerGroup > 0, UInt64(g.blocksPerGroup) <= bitsPerBlock,
              g.inodesPerGroup > 0, UInt64(g.inodesPerGroup) <= bitsPerBlock,
              g.inodeSize >= 128, g.inodeSize <= g.blockSize, g.inodeSize & (g.inodeSize - 1) == 0,
              g.blocksCount > g.firstDataBlock + 1,
              g.firstInode >= 11, g.firstInode <= g.inodesCount else {
            throw ScanError.malformed("Invalid ext geometry.")
        }
        guard g.blocksCount <= UInt64(volumeLength / g.blockSize) else {
            throw ScanError.malformed("Ext volume exceeds partition.")
        }
        g.groupCount = (g.blocksCount - g.firstDataBlock + UInt64(g.blocksPerGroup) - 1) / UInt64(g.blocksPerGroup)
        guard g.groupCount <= 1 << 22, g.groupCount * UInt64(g.inodesPerGroup) == UInt64(g.inodesCount) else {
            throw ScanError.malformed("Inconsistent ext group count.")
        }
        return g
    }
}

struct EXTGroup: Sendable { let blockBitmap: UInt64; let inodeBitmap: UInt64; let inodeTable: UInt64; let flags: UInt16 }

struct EXTInode: Sendable {
    static let indexFlag: UInt32 = 0x1000, extentsFlag: UInt32 = 0x80000
    static let inlineDataFlag: UInt32 = 0x10000000, encryptFlag: UInt32 = 0x800
    let mode: UInt16
    let size: UInt64
    let dtime: UInt32
    let links: UInt16
    let flags: UInt32
    let blockArea: Data
    let modified: Date
    /// The later of the inode's mtime and ctime, in seconds (with the extra epoch bits).
    let changed: Int64

    init(_ data: Data, inodeSize: Int) throws {
        mode = UInt16(try data.number(0, 2))
        size = try data.number(4, 4) | data.number(108, 4) << 32
        dtime = UInt32(try data.number(20, 4))
        links = UInt16(try data.number(26, 2))
        flags = UInt32(try data.number(32, 4))
        blockArea = data.subdata(in: 40..<100)
        var seconds = Int64(Int32(bitPattern: UInt32(try data.number(16, 4))))
        var changeSeconds = Int64(Int32(bitPattern: UInt32(try data.number(12, 4))))
        var nanoseconds: UInt64 = 0
        // i_ctime_extra (offset 132) and i_mtime_extra (offset 136) exist when i_extra_isize covers them.
        if inodeSize > 128, let extra = try? data.number(128, 2), 128 + Int(extra) <= inodeSize {
            if extra >= 8 { changeSeconds += Int64(try data.number(132, 4) & 3) << 32 }
            if extra >= 12 {
                let high = try data.number(136, 4)
                seconds += Int64(high & 3) << 32
                nanoseconds = high >> 2
            }
        }
        let fraction = nanoseconds < 1_000_000_000 ? Double(nanoseconds) / 1e9 : 0
        modified = Date(timeIntervalSince1970: Double(seconds) + fraction)
        changed = max(seconds, changeSeconds)
    }
    var isRegular: Bool { mode & 0xf000 == 0x8000 }
    var isDirectory: Bool { mode & 0xf000 == 0x4000 }
}

struct EXTRun: Sendable, Equatable { var logical: UInt64; var physical: UInt64; var count: UInt64; var initialized: Bool }

/// Logical-to-physical runs of a file, merged where adjacent, plus the tree/indirect blocks.
struct EXTMapping: Sendable {
    var runs: [EXTRun] = []
    var metadata: [UInt64] = []
    var visited: UInt64 = 0
    /// The most data plus tree/indirect blocks this mapping may visit.
    var limit: UInt64

    init(limit: UInt64) { self.limit = limit }

    mutating func add(logical: UInt64, physical: UInt64, count: UInt64, initialized: Bool) throws {
        visited += count
        guard visited <= limit else { throw ScanError.malformed("File maps more blocks than allowed.") }
        if var last = runs.last, last.initialized == initialized, last.logical + last.count == logical,
           last.physical + last.count == physical {
            last.count += count
            runs[runs.count - 1] = last
        } else {
            runs.append(EXTRun(logical: logical, physical: physical, count: count, initialized: initialized))
        }
    }
    mutating func addMetadata(_ block: UInt64) throws {
        visited += 1
        guard visited <= limit else { throw ScanError.malformed("File maps more blocks than allowed.") }
        metadata.append(block)
    }
}

struct EXTDirent: Sendable { let inode: UInt32; let name: String; let raw: Data }

/// A directory reached by the live walk: its parent's index, its own name and its last change.
struct EXTDirectoryRecord: Sendable { let parent: Int; let name: String; let changed: Int64 }
struct EXTPendingDirectory: Sendable { let inode: UInt32; let index: Int; let depth: Int }

/// A stale entry found in directory slack. It keeps the 8 header bytes and the validated UTF-8
/// name instead of a raw copy; `raw` rebuilds the exact on-disk entry bytes when it is emitted.
struct EXTDeletedCandidate: Sendable {
    let inode: UInt32
    let directory: Int
    let header: UInt64
    let name: String
    var raw: Data {
        var bytes = Data((0..<8).map { UInt8(truncatingIfNeeded: header >> ($0 * 8)) })
        bytes.append(contentsOf: name.utf8)
        return bytes
    }
}

/// A physical block range [start, end) claimed by an accepted deleted candidate.
struct EXTClaim: Sendable { let start: UInt64; let end: UInt64; let owner: Int }

/// Standard CRC32C (Castagnoli). ext4 stores the raw register (seed ~0, no final inversion),
/// which is the bitwise complement of this value.
func crc32c(_ data: Data) -> UInt32 { ~crc32cUpdate(0xffffffff, data) }
func crc32cUpdate(_ seed: UInt32, _ data: Data) -> UInt32 {
    var crc = seed
    for byte in data {
        crc ^= UInt32(byte)
        for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0x82f63b78 : 0) }
    }
    return crc
}
