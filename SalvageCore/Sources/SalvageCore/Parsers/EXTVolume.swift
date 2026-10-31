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
    var liveInodes: Set<UInt32> = []
    var visitedDirectories: Set<UInt32> = []
    var candidates: [EXTDeletedCandidate] = []
    var bitmapCache: [UInt64: Data] = [:]
    var inodeBlockNumber: Int64 = -1
    var inodeBlock = Data()

    /// Bounds on traversal so hostile metadata always terminates.
    static let maxDirectoryDepth = 2048
    static let maxExtentDepth = 5
    static let maxCandidates = 1_000_000

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

    func mapping(_ inode: EXTInode) async throws -> EXTMapping {
        var map = EXTMapping()
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

    func walkBlockMap(_ block: UInt64, level: Int, logical: UInt64, map: inout EXTMapping,
                      visited: inout Set<UInt64>) async throws {
        try validBlock(block)
        if level == 0 {
            try map.add(logical: logical, physical: block, count: 1, initialized: true, limit: geometry.blocksCount)
            return
        }
        guard visited.insert(block).inserted else { throw ScanError.malformed("Block-map cycle.") }
        try map.addMetadata(block, limit: geometry.blocksCount)
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
                try map.add(logical: first, physical: start, count: length, initialized: initialized,
                            limit: geometry.blocksCount)
                next = first + length
            } else {
                let child = try node.number(p + 8, 2) << 32 | node.number(p + 4, 4)
                let childHigh = index + 1 < entries ? try node.number(p + 12, 4) : high
                guard first >= low || index == 0, childHigh <= high else {
                    throw ScanError.malformed("Invalid extent index.")
                }
                try validBlock(child)
                guard visited.insert(child).inserted else { throw ScanError.malformed("Extent tree cycle.") }
                try map.addMetadata(child, limit: geometry.blocksCount)
                let data = try await readBlock(child)
                try await walkExtentNode(data, root: false, expectedDepth: depth - 1, low: max(first, low),
                                         high: childHigh, map: &map, visited: &visited, next: &next)
            }
        }
    }

    // MARK: Directory walk

    func walkLiveTree() async throws {
        let rootInode = try await inode(2)
        let root = try EXTInode(rootInode.data, inodeSize: geometry.inodeSize)
        guard root.isDirectory else { throw ScanError.malformed("Root inode is not a directory.") }
        visitedDirectories.insert(2); liveInodes.insert(2)
        var pending: [(EXTInode, String, Int)] = [(root, "", 0)]
        while let (directory, path, depth) = pending.popLast() {
            let children = try await readDirectory(directory, path: path)
            for child in children {
                liveInodes.insert(child.inode)
                let (offset, data) = try await inode(child.inode)
                let node = try EXTInode(data, inodeSize: geometry.inodeSize)
                guard node.mode != 0 else { throw ScanError.malformed("Live entry references a free inode.") }
                let fullPath = path + "/" + child.name
                if node.isDirectory {
                    guard depth < Self.maxDirectoryDepth else { throw ScanError.malformed("Directory nesting too deep.") }
                    guard visitedDirectories.insert(child.inode).inserted else {
                        throw ScanError.malformed("Directory cycle or hard-linked directory.")
                    }
                    pending.append((node, fullPath, depth + 1))
                } else if node.isRegular {
                    let map = try await mapping(node)
                    try await emit(file(name: child.name, path: fullPath, inode: node, number: child.inode,
                                        offset: offset, raw: data + child.raw, map: map, deleted: false))
                }
            }
        }
    }

    /// Reads every block of a live directory linearly. Htree index blocks parse as entries that
    /// span the block, so the index is never followed.
    func readDirectory(_ directory: EXTInode, path: String) async throws -> [EXTDirent] {
        let blockSize = UInt64(geometry.blockSize)
        guard directory.size > 0, directory.size % blockSize == 0, directory.size / blockSize <= geometry.blocksCount else {
            throw ScanError.malformed("Invalid directory size.")
        }
        let blocks = directory.size / blockSize
        let map = try await mapping(directory)
        var children: [EXTDirent] = []
        var expected: UInt64 = 0
        for run in map.runs where run.logical < blocks {
            guard run.logical == expected, run.initialized else { throw ScanError.malformed("Directory hole.") }
            for k in 0..<min(run.count, blocks - run.logical) {
                let data = try await readBlock(run.physical + k)
                try parseDirectoryBlock(data, logical: run.logical + k, indexed: directory.flags & EXTInode.indexFlag != 0,
                                        path: path, children: &children)
            }
            expected = min(blocks, run.logical + run.count)
        }
        guard expected == blocks else { throw ScanError.malformed("Truncated directory.") }
        return children
    }

    func parseDirectoryBlock(_ data: Data, logical: UInt64, indexed: Bool, path: String,
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
                scanGap(data, from: p + Self.align(8 + nameLength), to: p + length, path: path)
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
        if let name = String(bytes: bytes, encoding: .utf8) { return name }
        // Linux names are arbitrary bytes. Escape non-UTF-8 bytes visibly instead of replacing
        // them silently; the raw entry bytes stay in the record.
        return bytes.map { $0 < 0x80 ? String(UnicodeScalar($0)) : String(format: "\\x%02X", $0) }.joined()
    }

    // MARK: Deleted-file recovery (best effort)

    /// Looks for plausible removed entries in the slack after a live entry's real length.
    func scanGap(_ data: Data, from start: Int, to end: Int, path: String) {
        var p = start
        while p + 12 <= end, candidates.count < Self.maxCandidates {
            guard let number = try? data.number(p, 4), let raw = try? data.number(p + 4, 2) else { return }
            let length = recordLength(raw)
            let nameLength = Int(data[p + 6]), type = data[p + 7]
            let plausibleType = geometry.fileType ? type == 1 : type == 0
            if number >= UInt64(geometry.firstInode), number <= UInt64(geometry.inodesCount), nameLength > 0,
               plausibleType, 8 + nameLength <= end - p, length % 4 == 0,
               length >= Self.align(8 + nameLength), length <= end - p {
                let nameBytes = data.subdata(in: p + 8..<p + 8 + nameLength)
                if !nameBytes.contains(0), !nameBytes.contains(0x2f), let name = String(bytes: nameBytes, encoding: .utf8),
                   name != ".", name != ".." {
                    candidates.append(EXTDeletedCandidate(inode: UInt32(number), name: name, path: path,
                                                          raw: data.subdata(in: p..<p + 8 + nameLength)))
                    p += Self.align(8 + nameLength)
                    continue
                }
            }
            p += 4
        }
    }

    func recoverDeleted() async throws {
        var seen: Set<UInt32> = []
        for candidate in candidates where !liveInodes.contains(candidate.inode) {
            guard seen.insert(candidate.inode).inserted else { continue }
            do {
                if let file = try await deletedFile(candidate) { try await emit(file) }
            } catch ScanError.malformed(_) {
                // An implausible deleted candidate is skipped and never aborts the scan.
                continue
            }
        }
    }

    func deletedFile(_ candidate: EXTDeletedCandidate) async throws -> RecoveredFile? {
        // The inode must be free, and a deleted regular file with nonzero size.
        guard try await inodeInUse(candidate.inode) == false else { return nil }
        let (offset, data) = try await inode(candidate.inode)
        let node = try EXTInode(data, inodeSize: geometry.inodeSize)
        guard node.isRegular, node.dtime != 0 || node.links == 0, node.size > 0,
              node.flags & EXTInode.encryptFlag == 0 else { return nil }
        let map = try await mapping(node)
        // Every logical block within the size must still be mapped (no partial recovery).
        let blockSize = UInt64(geometry.blockSize)
        let needed = (node.size - 1) / blockSize + 1
        var expected: UInt64 = 0
        for run in map.runs {
            if run.logical >= needed { break }
            guard run.logical == expected else { return nil }
            expected = min(needed, run.logical + run.count)
        }
        guard expected == needed else { return nil }
        // Every block the old mapping names, data and tree/indirect blocks, must now be free.
        for block in map.metadata {
            guard try await blockInUse(block) == false else { return nil }
        }
        for run in map.runs {
            for k in 0..<run.count {
                try Task.checkCancellation()
                guard try await blockInUse(run.physical + k) == false else { return nil }
            }
        }
        return try file(name: candidate.name, path: candidate.path + "/" + candidate.name, inode: node,
                        number: candidate.inode, offset: offset, raw: data + candidate.raw, map: map, deleted: true)
    }

    func file(name: String, path: String, inode: EXTInode, number: UInt32, offset: Int64, raw: Data,
              map: EXTMapping, deleted: Bool) throws -> RecoveredFile {
        RecoveredFile(name: name, path: path, sizeBytes: try signed(inode.size), modified: inode.modified,
                      isDeleted: deleted,
                      sourceMetadata: SourceMetadata(filesystem: .ext, volumeOffset: extent.offset, recordOffset: offset,
                                                     allocationStart: UInt64(number),
                                                     contiguous: map.runs.count <= 1, rawRecord: raw))
    }
}

// MARK: - Supporting types

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

    static func parse(_ sb: Data, volumeLength: Int64) throws -> EXTGeometry {
        guard try sb.number(56, 2) == 0xef53 else { throw ScanError.malformed("Missing ext superblock magic.") }
        var g = EXTGeometry()
        let revision = try sb.number(76, 4)
        guard revision <= 1 else { throw ScanError.unsupportedFilesystem }
        let incompat = revision == 0 ? 0 : try sb.number(96, 4)
        let roCompat = revision == 0 ? 0 : try sb.number(100, 4)
        guard incompat & ~supportedIncompat == 0 else { throw ScanError.unsupportedFilesystem }
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

    init(_ data: Data, inodeSize: Int) throws {
        mode = UInt16(try data.number(0, 2))
        size = try data.number(4, 4) | data.number(108, 4) << 32
        dtime = UInt32(try data.number(20, 4))
        links = UInt16(try data.number(26, 2))
        flags = UInt32(try data.number(32, 4))
        blockArea = data.subdata(in: 40..<100)
        var seconds = Int64(Int32(bitPattern: UInt32(try data.number(16, 4))))
        var nanoseconds: UInt64 = 0
        // i_mtime_extra (offset 136) exists when i_extra_isize covers it.
        if inodeSize > 128, let extra = try? data.number(128, 2), extra >= 12, 128 + Int(extra) <= inodeSize {
            let high = try data.number(136, 4)
            seconds += Int64(high & 3) << 32
            nanoseconds = high >> 2
        }
        let fraction = nanoseconds < 1_000_000_000 ? Double(nanoseconds) / 1e9 : 0
        modified = Date(timeIntervalSince1970: Double(seconds) + fraction)
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

    mutating func add(logical: UInt64, physical: UInt64, count: UInt64, initialized: Bool, limit: UInt64) throws {
        visited += count
        guard visited <= limit else { throw ScanError.malformed("File maps more blocks than the volume holds.") }
        if var last = runs.last, last.initialized == initialized, last.logical + last.count == logical,
           last.physical + last.count == physical {
            last.count += count
            runs[runs.count - 1] = last
        } else {
            runs.append(EXTRun(logical: logical, physical: physical, count: count, initialized: initialized))
        }
    }
    mutating func addMetadata(_ block: UInt64, limit: UInt64) throws {
        visited += 1
        guard visited <= limit else { throw ScanError.malformed("File maps more blocks than the volume holds.") }
        metadata.append(block)
    }
}

struct EXTDirent: Sendable { let inode: UInt32; let name: String; let raw: Data }
struct EXTDeletedCandidate: Sendable { let inode: UInt32; let name: String; let path: String; let raw: Data }

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
