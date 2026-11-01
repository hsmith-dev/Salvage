import Foundation

// On-disk HFS+/HFSX structures, written from Apple's Technical Note TN1150 ("HFS Plus Volume
// Format"). Everything here is big-endian except the journal, which is in the native byte order
// of the system that created it (see HFSPlusJournal.swift).

extension Data {
    /// Big-endian unsigned field (`number` is the little-endian counterpart).
    func hfsNumber(_ offset: Int, _ width: Int) throws -> UInt64 {
        guard offset >= 0, width > 0, width <= 8, offset <= count, width <= count - offset else {
            throw ScanError.malformed("Truncated structure.")
        }
        return (0..<width).reduce(0) { $0 << 8 | UInt64(self[startIndex + offset + $1]) }
    }
}

enum HFSPlus {
    static let rootParentID: UInt32 = 1
    static let rootFolderID: UInt32 = 2
    static let extentsFileID: UInt32 = 3
    static let catalogFileID: UInt32 = 4
    static let allocationFileID: UInt32 = 6
    static let attributesFileID: UInt32 = 8
    static let firstUserCatalogNodeID: UInt32 = 16
    /// Seconds from the HFS epoch (1904-01-01 00:00:00 UTC) to the Unix epoch.
    static let epochOffset: Double = 2_082_844_800
    /// The folder that holds hard-link indirect nodes: four NULs then "HFS+ Private Data".
    static let privateDataFolderName: [UInt16] = [0, 0, 0, 0] + Array("HFS+ Private Data".utf16)
    static let decmpfsAttributeName: [UInt16] = Array("com.apple.decmpfs".utf16)

    static func date(_ seconds: UInt32) -> Date? {
        seconds == 0 ? nil : Date(timeIntervalSince1970: Double(seconds) - epochOffset)
    }

    /// Decodes an HFS Unicode name (UTF-16BE, decomposed) as precomposed text. Nil when the units
    /// are not valid UTF-16 or contain "/", which the catalog never stores (it keeps ":" instead).
    static func name(_ units: [UInt16]) -> String? {
        let decoded = String(decoding: units, as: UTF16.self)
        guard Array(decoded.utf16) == units, !decoded.contains("/") else { return nil }
        return decoded.precomposedStringWithCanonicalMapping
    }

    /// The number in an indirect-node file name ("iNode123"), or nil for any other name.
    static func indirectNodeNumber(_ units: [UInt16]) -> UInt32? {
        let prefix = Array("iNode".utf16)
        guard units.count > prefix.count, units.count <= prefix.count + 10, Array(units.prefix(prefix.count)) == prefix else {
            return nil
        }
        var value: UInt64 = 0
        for unit in units.dropFirst(prefix.count) {
            guard unit >= 0x30, unit <= 0x39 else { return nil }
            value = value * 10 + UInt64(unit - 0x30)
        }
        guard value <= UInt64(UInt32.max) else { return nil }
        return UInt32(value)
    }
}

struct HFSPlusExtent: Sendable, Equatable {
    let startBlock: UInt32
    let blockCount: UInt32

    /// Reads `count` extent descriptors; only the leading non-empty ones are kept, and an empty
    /// descriptor followed by a used one is malformed.
    static func list(_ data: Data, at offset: Int, count: Int) throws -> [HFSPlusExtent] {
        var result: [HFSPlusExtent] = []
        var ended = false
        for index in 0..<count {
            let start = UInt32(try data.hfsNumber(offset + index * 8, 4))
            let blocks = UInt32(try data.hfsNumber(offset + index * 8 + 4, 4))
            if blocks == 0 { ended = true; continue }
            guard !ended else { throw ScanError.malformed("Extent list has a gap.") }
            result.append(HFSPlusExtent(startBlock: start, blockCount: blocks))
        }
        return result
    }
}

/// HFSPlusForkData (80 bytes): logical size, clump size, total blocks and the first eight extents.
struct HFSPlusForkData: Sendable, Equatable {
    var logicalSize: UInt64 = 0
    var totalBlocks: UInt32 = 0
    var extents: [HFSPlusExtent] = []

    init() {}
    init(_ data: Data, at offset: Int) throws {
        logicalSize = try data.hfsNumber(offset, 8)
        totalBlocks = UInt32(try data.hfsNumber(offset + 12, 4))
        extents = try HFSPlusExtent.list(data, at: offset + 16, count: 8)
    }
    var extentBlocks: UInt64 { extents.reduce(0) { $0 + UInt64($1.blockCount) } }
}

/// The volume header at byte 1024.
struct HFSPlusVolumeHeader: Sendable {
    var isHFSX = false
    var attributes: UInt32 = 0
    var journalInfoBlock: UInt32 = 0
    var blockSize: Int64 = 4096
    var totalBlocks: UInt32 = 0
    var nextCatalogID: UInt32 = 0
    var allocationFile = HFSPlusForkData()
    var extentsFile = HFSPlusForkData()
    var catalogFile = HFSPlusForkData()
    var attributesFile = HFSPlusForkData()

    static let journaledBit: UInt32 = 1 << 13
    static let catalogNodeIDsReusedBit: UInt32 = 1 << 12
    var isJournaled: Bool { attributes & Self.journaledBit != 0 }
    var catalogNodeIDsReused: Bool { attributes & Self.catalogNodeIDsReusedBit != 0 }
    var volumeBytes: Int64 { Int64(totalBlocks) * blockSize }

    static func parse(_ data: Data, volumeLength: Int64) throws -> HFSPlusVolumeHeader {
        let signature = try data.hfsNumber(0, 2)
        // "BD" is an HFS (wrapper) volume: recognized, deliberately not parsed.
        if signature == 0x4244 { throw ScanError.unsupportedFilesystem }
        guard signature == 0x482B || signature == 0x4858 else {
            throw ScanError.malformed("Missing HFS+ volume header signature.")
        }
        var header = HFSPlusVolumeHeader()
        header.isHFSX = signature == 0x4858
        let version = try data.hfsNumber(2, 2)
        guard version == 4 || version == 5 else { throw ScanError.malformed("Unsupported HFS+ version.") }
        header.attributes = UInt32(try data.hfsNumber(4, 4))
        header.journalInfoBlock = UInt32(try data.hfsNumber(12, 4))
        let blockSize = try data.hfsNumber(40, 4)
        guard blockSize >= 512, blockSize <= 1 << 20, blockSize.nonzeroBitCount == 1 else {
            throw ScanError.malformed("Invalid HFS+ block size.")
        }
        header.blockSize = Int64(blockSize)
        let totalBlocks = try data.hfsNumber(44, 4)
        guard totalBlocks > 0, totalBlocks <= UInt64(UInt32.max), totalBlocks * blockSize >= 2048,
              totalBlocks * blockSize <= UInt64(volumeLength) else {
            throw ScanError.malformed("HFS+ volume exceeds partition.")
        }
        header.totalBlocks = UInt32(totalBlocks)
        header.nextCatalogID = UInt32(try data.hfsNumber(64, 4))
        header.allocationFile = try HFSPlusForkData(data, at: 112)
        header.extentsFile = try HFSPlusForkData(data, at: 192)
        header.catalogFile = try HFSPlusForkData(data, at: 272)
        header.attributesFile = try HFSPlusForkData(data, at: 352)
        for fork in [header.allocationFile, header.extentsFile, header.catalogFile, header.attributesFile] {
            try header.validate(fork)
        }
        guard header.catalogFile.logicalSize >= 1024, !header.catalogFile.extents.isEmpty,
              header.extentsFile.logicalSize >= 512, !header.extentsFile.extents.isEmpty,
              header.allocationFile.logicalSize * 8 >= totalBlocks, !header.allocationFile.extents.isEmpty,
              header.nextCatalogID >= HFSPlus.firstUserCatalogNodeID else {
            throw ScanError.malformed("Invalid HFS+ special file geometry.")
        }
        return header
    }

    /// Every extent inside the volume and consistent with the fork's own totals.
    func validate(_ fork: HFSPlusForkData) throws {
        for extent in fork.extents { try validate(extent) }
        guard fork.extentBlocks <= UInt64(fork.totalBlocks),
              fork.logicalSize <= UInt64(fork.totalBlocks) * UInt64(blockSize) else {
            throw ScanError.malformed("Fork size disagrees with its extents.")
        }
    }
    func validate(_ extent: HFSPlusExtent) throws {
        guard extent.blockCount > 0, UInt64(extent.startBlock) + UInt64(extent.blockCount) <= UInt64(totalBlocks) else {
            throw ScanError.malformed("Extent outside volume.")
        }
    }
}

/// A fork's extents as a logical-to-volume byte map with cumulative starts for binary search.
struct HFSPlusForkMap: Sendable {
    let extents: [HFSPlusExtent]
    /// `starts[i]` is the logical byte offset where extent `i` begins; the last entry is the total.
    let starts: [Int64]
    let blockSize: Int64

    init(_ extents: [HFSPlusExtent], blockSize: Int64) throws {
        var starts: [Int64] = [0]
        starts.reserveCapacity(extents.count + 1)
        for extent in extents {
            starts.append(try checkedAdd(starts[starts.count - 1], checkedMultiply(Int64(extent.blockCount), blockSize)))
        }
        self.extents = extents; self.starts = starts; self.blockSize = blockSize
    }
    var length: Int64 { starts[starts.count - 1] }

    /// Index of the extent holding a logical byte, or nil past the mapped length.
    func extentIndex(of logical: Int64) -> Int? {
        guard logical >= 0, logical < length else { return nil }
        var low = 0, high = extents.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if starts[middle] <= logical { low = middle } else { high = middle - 1 }
        }
        return low
    }

    /// Volume-relative byte offset of a logical byte, or nil past the mapped length.
    func volumeOffset(of logical: Int64) throws -> Int64? {
        guard let index = extentIndex(of: logical) else { return nil }
        return try checkedAdd(checkedMultiply(Int64(extents[index].startBlock), blockSize), logical - starts[index])
    }

    /// Volume-relative pieces covering `offset ..< offset + count`, in order.
    func pieces(offset: Int64, count: Int) throws -> [(volumeOffset: Int64, count: Int)] {
        guard offset >= 0, count >= 0, offset <= length, Int64(count) <= length - offset else {
            throw ScanError.malformed("Read past fork extents.")
        }
        var result: [(Int64, Int)] = []
        var logical = offset, remaining = count
        while remaining > 0 {
            guard let index = extentIndex(of: logical), let volume = try volumeOffset(of: logical) else {
                throw ScanError.malformed("Read past fork extents.")
            }
            let take = Int(min(Int64(remaining), starts[index + 1] - logical))
            result.append((volume, take))
            logical += Int64(take); remaining -= take
        }
        return result
    }

    /// The logical offset of a volume-relative byte if it lies inside this fork, else nil.
    func logicalOffset(ofVolumeOffset volume: Int64) -> Int64? {
        for (index, extent) in extents.enumerated() {
            let start = Int64(extent.startBlock) * blockSize
            let end = start + Int64(extent.blockCount) * blockSize
            if volume >= start, volume < end { return starts[index] + (volume - start) }
        }
        return nil
    }
}

/// B-tree header record (node 0, offset 14).
struct HFSPlusBTreeHeader: Sendable {
    var treeDepth = 0
    var rootNode: UInt32 = 0
    var firstLeafNode: UInt32 = 0
    var lastLeafNode: UInt32 = 0
    var nodeSize = 512
    var totalNodes: UInt32 = 0
    var keyCompareType: UInt8 = 0
    var attributes: UInt32 = 0

    static let bigKeysMask: UInt32 = 2

    static func parse(_ node: Data) throws -> HFSPlusBTreeHeader {
        guard node.count >= 512, Int8(bitPattern: node[node.startIndex + 8]) == HFSPlusNode.headerKind else {
            throw ScanError.malformed("Missing B-tree header node.")
        }
        var header = HFSPlusBTreeHeader()
        header.treeDepth = Int(try node.hfsNumber(14, 2))
        header.rootNode = UInt32(try node.hfsNumber(16, 4))
        header.firstLeafNode = UInt32(try node.hfsNumber(24, 4))
        header.lastLeafNode = UInt32(try node.hfsNumber(28, 4))
        header.nodeSize = Int(try node.hfsNumber(32, 2))
        header.totalNodes = UInt32(try node.hfsNumber(36, 4))
        header.keyCompareType = UInt8(try node.hfsNumber(51, 1))
        header.attributes = UInt32(try node.hfsNumber(52, 4))
        guard header.nodeSize >= 512, header.nodeSize <= 32768, header.nodeSize.nonzeroBitCount == 1 else {
            throw ScanError.malformed("Invalid B-tree node size.")
        }
        guard header.attributes & Self.bigKeysMask != 0 else { throw ScanError.malformed("B-tree without big keys.") }
        let empty = header.rootNode == 0 && header.firstLeafNode == 0 && header.lastLeafNode == 0 && header.treeDepth == 0
        guard header.totalNodes > 0, empty || (header.treeDepth >= 1 && header.treeDepth <= 16 &&
              header.rootNode > 0 && header.rootNode < header.totalNodes &&
              header.firstLeafNode > 0 && header.firstLeafNode < header.totalNodes &&
              header.lastLeafNode > 0 && header.lastLeafNode < header.totalNodes) else {
            throw ScanError.malformed("Invalid B-tree header.")
        }
        return header
    }
}

struct HFSPlusBTree: Sendable {
    let map: HFSPlusForkMap
    let header: HFSPlusBTreeHeader
    var nodeSize: Int { header.nodeSize }
}

/// One B-tree node: descriptor plus validated record offsets.
struct HFSPlusNode: Sendable {
    static let leafKind: Int8 = -1, indexKind: Int8 = 0, headerKind: Int8 = 1, mapKind: Int8 = 2

    let data: Data
    let fLink: UInt32
    let bLink: UInt32
    let kind: Int8
    let height: UInt8
    let numRecords: Int
    /// `numRecords + 1` strictly increasing offsets; the last one is where free space begins.
    let offsets: [Int]

    init(_ raw: Data) throws {
        let data = raw.startIndex == 0 ? raw : Data(raw)
        guard data.count >= 512, data.count <= 32768, data.count.nonzeroBitCount == 1 else {
            throw ScanError.malformed("Invalid B-tree node size.")
        }
        fLink = UInt32(try data.hfsNumber(0, 4))
        bLink = UInt32(try data.hfsNumber(4, 4))
        kind = Int8(bitPattern: data[8])
        height = data[9]
        numRecords = Int(try data.hfsNumber(10, 2))
        let tableStart = data.count - 2 * (numRecords + 1)
        guard tableStart >= 14 else { throw ScanError.malformed("B-tree node record count exceeds node.") }
        var offsets: [Int] = []
        offsets.reserveCapacity(numRecords + 1)
        var previous = 13
        for index in 0...numRecords {
            let offset = Int(try data.hfsNumber(data.count - 2 * (index + 1), 2))
            guard offset > previous, offset <= tableStart else {
                throw ScanError.malformed("B-tree node record offsets out of order.")
            }
            offsets.append(offset); previous = offset
        }
        self.data = data; self.offsets = offsets
    }
    var isLeaf: Bool { kind == Self.leafKind }
    func record(_ index: Int) -> Data { data.subdata(in: offsets[index]..<offsets[index + 1]) }
    /// Bytes between the last record and the offset table, where removed records may linger.
    var slack: Range<Int> { offsets[numRecords]..<(data.count - 2 * (numRecords + 1)) }
}

/// Fixed-size bitmap of visited node numbers.
struct HFSPlusNodeSet: Sendable {
    private var words: [UInt64]
    init(count: UInt32) { words = [UInt64](repeating: 0, count: (Int(count) + 63) / 64) }
    func contains(_ node: UInt32) -> Bool {
        let index = Int(node / 64)
        return index < words.count && words[index] & (1 << UInt64(node % 64)) != 0
    }
    /// Returns false when the node was already present (or out of range).
    mutating func insert(_ node: UInt32) -> Bool {
        let index = Int(node / 64)
        guard index < words.count else { return false }
        let bit: UInt64 = 1 << UInt64(node % 64)
        guard words[index] & bit == 0 else { return false }
        words[index] |= bit
        return true
    }
}

/// HFSPlusCatalogKey: parent CNID plus the node's Unicode name.
struct HFSPlusCatalogKey: Sendable {
    let parentID: UInt32
    let nameUnits: [UInt16]
    /// Offset (relative to the record start) of the record data that follows the key.
    let dataOffset: Int

    init(_ record: Data, at offset: Int = 0) throws {
        let keyLength = Int(try record.hfsNumber(offset, 2))
        guard keyLength >= 6, keyLength <= 6 + 2 * 255, keyLength % 2 == 0 else {
            throw ScanError.malformed("Invalid catalog key length.")
        }
        parentID = UInt32(try record.hfsNumber(offset + 2, 4))
        let nameLength = Int(try record.hfsNumber(offset + 6, 2))
        guard nameLength == (keyLength - 6) / 2 else { throw ScanError.malformed("Catalog key name length mismatch.") }
        var units: [UInt16] = []
        units.reserveCapacity(nameLength)
        for index in 0..<nameLength { units.append(UInt16(try record.hfsNumber(offset + 8 + index * 2, 2))) }
        nameUnits = units
        dataOffset = offset + 2 + keyLength
    }
    var name: String? { HFSPlus.name(nameUnits) }
}

enum HFSPlusCatalogRecordType {
    static let folder: UInt64 = 1, file: UInt64 = 2, folderThread: UInt64 = 3, fileThread: UInt64 = 4
}

/// HFSPlusCatalogFolder (88 bytes); only the fields the scan needs.
struct HFSPlusCatalogFolder: Sendable {
    static let size = 88
    let folderID: UInt32
    init(_ record: Data, at offset: Int) throws {
        guard try record.hfsNumber(offset, 2) == HFSPlusCatalogRecordType.folder, offset + Self.size <= record.count else {
            throw ScanError.malformed("Truncated catalog folder record.")
        }
        folderID = UInt32(try record.hfsNumber(offset + 8, 4))
    }
}

/// HFSPlusCatalogFile (248 bytes); only the fields the scan needs.
struct HFSPlusCatalogFile: Sendable, Equatable {
    static let size = 248
    let flags: UInt16
    let fileID: UInt32
    let contentModDate: UInt32
    /// BSD `st_flags` low byte (UF_COMPRESSED is 0x20).
    let ownerFlags: UInt8
    let fileMode: UInt16
    /// iNodeNum for hard links, link count otherwise.
    let special: UInt32
    let fdType: UInt32
    let fdCreator: UInt32
    let dataFork: HFSPlusForkData

    init(_ record: Data, at offset: Int) throws {
        guard try record.hfsNumber(offset, 2) == HFSPlusCatalogRecordType.file, offset + Self.size <= record.count else {
            throw ScanError.malformed("Truncated catalog file record.")
        }
        flags = UInt16(try record.hfsNumber(offset + 2, 2))
        fileID = UInt32(try record.hfsNumber(offset + 8, 4))
        contentModDate = UInt32(try record.hfsNumber(offset + 16, 4))
        ownerFlags = UInt8(try record.hfsNumber(offset + 32 + 9, 1))
        fileMode = UInt16(try record.hfsNumber(offset + 32 + 10, 2))
        special = UInt32(try record.hfsNumber(offset + 32 + 12, 4))
        fdType = UInt32(try record.hfsNumber(offset + 48, 4))
        fdCreator = UInt32(try record.hfsNumber(offset + 52, 4))
        dataFork = try HFSPlusForkData(record, at: offset + 88)
    }

    /// 'hlnk' / 'hfs+': a hard link whose data lives in an indirect node.
    var isHardLink: Bool { fdType == 0x686C_6E6B && fdCreator == 0x6866_732B }
    /// 'fdrp' / 'MACS': a directory hard link alias.
    var isDirectoryHardLink: Bool { fdType == 0x6664_7270 && fdCreator == 0x4D41_4353 }
    /// 'jrnl' / 'hfs+': the hidden .journal and .journal_info_block files.
    var isJournalFile: Bool { fdType == 0x6A72_6E6C && fdCreator == 0x6866_732B }
    var isSymlink: Bool { fileMode & 0xF000 == 0xA000 }
    /// A mode of 0 means the BSD info is unused (classic Mac OS); such entries are plain files.
    var isRegular: Bool { fileMode == 0 || fileMode & 0xF000 == 0x8000 }
    var isCompressed: Bool { ownerFlags & 0x20 != 0 }
}

/// A folder known to the scan: its parent and precomposed name.
struct HFSPlusFolderEntry: Sendable { let parent: UInt32; let name: String }

enum HFSPlusCandidateSource: Sendable { case journal, staleNode, slack }

/// A catalog file record found outside the live tree (journal, unlinked node, node slack).
struct HFSPlusCandidate: Sendable {
    let file: HFSPlusCatalogFile
    let parentID: UInt32
    let name: String
    /// Device-absolute offset of the record bytes.
    let recordOffset: Int64
    let raw: Data
    let source: HFSPlusCandidateSource
    var conflicted = false

    /// Two copies describe the same final state of the file.
    func agrees(with other: HFSPlusCandidate) -> Bool {
        parentID == other.parentID && name == other.name && file.dataFork == other.file.dataFork &&
            file.contentModDate == other.file.contentModDate
    }
}

/// A physical block range [start, end) claimed by an accepted deleted candidate.
struct HFSPlusClaim: Sendable { let start: UInt64; let end: UInt64; let owner: Int }

struct HFSPlusWorkBudgetExhausted: Error {}

/// Traversal and memory bounds. The defaults are the production limits; tests may lower them.
struct HFSPlusLimits: Sendable {
    var maxPathDepth = 2048
    var maxCandidates = 100_000
    /// Total raw record bytes kept across deleted candidates.
    var maxCandidateBytes = 64 << 20
    var maxStaleFolders = 200_000
    var maxOverflowRecords = 2_000_000
    var maxExtentsPerFile = 1 << 20
    var maxCompressedEntries = 2_000_000
    /// Physical ranges kept for the deleted-candidate overlap check.
    var maxClaimedRanges = 2_000_000
    var maxJournalBytes: UInt64 = 1 << 30
    /// Deleted-candidate work (bitmap checks and stale nodes examined); nil means 4 × blocks + 1,000,000.
    var deletedWorkBudget: UInt64? = nil
}

/// Counters and notes exposed for tests.
struct HFSPlusScanStats: Sendable {
    var journal = "not scanned"
    var journalTransactions = 0
    var candidatesFound = 0
    var candidatesDropped = 0
    var staleNodesExamined = 0
    var compressedFiles = 0
    var unresolvedHardLinks = 0
    var deletedWorkSpent: UInt64 = 0
    var deletedBudgetExhausted = false
    var deletedRecoveryDisabled: String? = nil
    var notes: [String] = []
}
