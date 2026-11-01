import Foundation
import Testing
@testable import SalvageCore

extension Data {
    mutating func putBigEndian(_ offset: Int, _ value: UInt64, _ width: Int) {
        for index in 0..<width { self[offset + index] = UInt8(truncatingIfNeeded: value >> ((width - 1 - index) * 8)) }
    }
}

/// Builds small synthetic HFS+ volumes (4 KiB blocks and nodes). Layout: block 0 boot/header,
/// block 1 allocation file, blocks 2-3 extents overflow tree, blocks 4-11 catalog (node n at block
/// 4 + n), blocks 12-15 attributes tree, block 16 journal info block, blocks 17-48 journal, data
/// from block 64. Blocks below 64 are marked used; file data blocks are marked by `file(...)`.
struct HFSImage {
    static let blockSize = 4096, nodeSize = 4096
    static let catalogBlock = 4, catalogNodes = 8, extentsBlock = 2, attributesBlock = 12
    static let journalInfoBlock = 16, journalBlock = 17, journalBlocks = 32
    static let dataStart = 64

    var data: Data
    let blocks: Int
    var signature: UInt64 = 0x482B, version: UInt64 = 4
    var attributes: UInt64 = 1 << 8
    var nextCatalogID: UInt64 = 100
    var hasJournal = false
    var hasAttributes = false
    /// Where the extents overflow tree lives (first block, block count).
    var extentsTree = (block: HFSImage.extentsBlock, blocks: 2)

    init(blocks: Int = 256) {
        self.blocks = blocks
        data = Data(repeating: 0, count: blocks * Self.blockSize)
        for block in 0..<Self.dataStart { mark(block: block) }
        // Empty extents overflow tree: header node only.
        writeNode(tree: Self.extentsBlock, 0, Self.headerNode(totalNodes: 2, root: 0, firstLeaf: 0, lastLeaf: 0, depth: 0))
    }

    var image: Data {
        var result = data
        let h = 1024
        result.putBigEndian(h, signature, 2); result.putBigEndian(h + 2, version, 2)
        result.putBigEndian(h + 4, attributes | (hasJournal ? 1 << 13 : 0), 4)
        result.putBigEndian(h + 12, hasJournal ? UInt64(Self.journalInfoBlock) : 0, 4)
        result.putBigEndian(h + 40, UInt64(Self.blockSize), 4); result.putBigEndian(h + 44, UInt64(blocks), 4)
        result.putBigEndian(h + 64, nextCatalogID, 4)
        Self.fork(&result, at: h + 112, size: UInt64(Self.blockSize), extents: [(1, 1)])
        Self.fork(&result, at: h + 192, size: UInt64(extentsTree.blocks * Self.blockSize), extents: [(extentsTree.block, extentsTree.blocks)])
        Self.fork(&result, at: h + 272, size: UInt64(Self.catalogNodes * Self.blockSize), extents: [(Self.catalogBlock, Self.catalogNodes)])
        if hasAttributes { Self.fork(&result, at: h + 352, size: 4 * UInt64(Self.blockSize), extents: [(Self.attributesBlock, 4)]) }
        return result
    }

    static func fork(_ data: inout Data, at offset: Int, size: UInt64, extents: [(Int, Int)]) {
        data.putBigEndian(offset, size, 8)
        data.putBigEndian(offset + 12, UInt64(extents.reduce(0) { $0 + $1.1 }), 4)
        for (index, extent) in extents.enumerated() {
            data.putBigEndian(offset + 16 + index * 8, UInt64(extent.0), 4)
            data.putBigEndian(offset + 20 + index * 8, UInt64(extent.1), 4)
        }
    }

    mutating func mark(block: Int, used: Bool = true) {
        let byte = Self.blockSize + block / 8
        let bit: UInt8 = 0x80 >> UInt8(block % 8)
        if used { data[byte] |= bit } else { data[byte] &= ~bit }
    }

    // MARK: B-tree nodes

    static func headerNode(totalNodes: Int, root: UInt32, firstLeaf: UInt32, lastLeaf: UInt32, depth: Int,
                           nodeSize: Int = HFSImage.nodeSize, attributes: UInt64 = 2 | 4) -> Data {
        var node = Data(repeating: 0, count: Self.nodeSize)
        node[8] = 1; node.putBigEndian(10, 3, 2)
        node.putBigEndian(14, UInt64(depth), 2); node.putBigEndian(16, UInt64(root), 4)
        node.putBigEndian(24, UInt64(firstLeaf), 4); node.putBigEndian(28, UInt64(lastLeaf), 4)
        node.putBigEndian(32, UInt64(nodeSize), 2); node.putBigEndian(34, 516, 2)
        node.putBigEndian(36, UInt64(totalNodes), 4); node.putBigEndian(40, UInt64(max(0, totalNodes - 2)), 4)
        node[51] = 0xCF; node.putBigEndian(52, attributes, 4)
        node.putBigEndian(Self.nodeSize - 2, 14, 2); node.putBigEndian(Self.nodeSize - 4, 120, 2)
        node.putBigEndian(Self.nodeSize - 6, 248, 2); node.putBigEndian(Self.nodeSize - 8, UInt64(Self.nodeSize - 8), 2)
        return node
    }

    static func leafNode(_ records: [Data], fLink: UInt32 = 0, bLink: UInt32 = 0, slack: Data = Data()) -> Data {
        var node = Data(repeating: 0, count: Self.nodeSize)
        node.putBigEndian(0, UInt64(fLink), 4); node.putBigEndian(4, UInt64(bLink), 4)
        node[8] = 0xFF; node[9] = 1; node.putBigEndian(10, UInt64(records.count), 2)
        var p = 14
        for (index, record) in records.enumerated() {
            node.replaceSubrange(p..<p + record.count, with: record)
            node.putBigEndian(Self.nodeSize - 2 * (index + 1), UInt64(p), 2)
            p += record.count
        }
        node.putBigEndian(Self.nodeSize - 2 * (records.count + 1), UInt64(p), 2)
        node.replaceSubrange(p..<p + slack.count, with: slack)
        return node
    }

    /// An index node (height `height`) whose records are (12-byte extents key, child node).
    static func extentsIndexNode(_ records: [(UInt32, UInt32, UInt32)], height: UInt8 = 2) -> Data {
        var node = leafNode(records.map { fileID, startBlock, child -> Data in
            var record = Data(repeating: 0, count: 16)
            record.putBigEndian(0, 10, 2); record.putBigEndian(4, UInt64(fileID), 4); record.putBigEndian(8, UInt64(startBlock), 4)
            record.putBigEndian(12, UInt64(child), 4)
            return record
        })
        node[8] = 0; node[9] = height
        return node
    }

    /// One extents overflow leaf record: (fileID, startBlock, extents).
    static func overflowRecord(_ fileID: UInt32, _ startBlock: UInt32, _ extents: [(Int, Int)]) -> Data {
        var record = Data(repeating: 0, count: 12 + 64)
        record.putBigEndian(0, 10, 2); record.putBigEndian(4, UInt64(fileID), 4); record.putBigEndian(8, UInt64(startBlock), 4)
        for (index, extent) in extents.enumerated() {
            record.putBigEndian(12 + index * 8, UInt64(extent.0), 4); record.putBigEndian(16 + index * 8, UInt64(extent.1), 4)
        }
        return record
    }

    mutating func writeNode(tree block: Int, _ node: Int, _ bytes: Data) {
        let offset = (block + node) * Self.blockSize
        data.replaceSubrange(offset..<offset + Self.nodeSize, with: bytes)
    }

    /// Writes the catalog: header node 0, leaves at nodes 1...n chained in order.
    mutating func catalog(_ leaves: [[Data]]) {
        let n = leaves.count
        writeNode(tree: Self.catalogBlock, 0, Self.headerNode(totalNodes: Self.catalogNodes, root: n == 1 ? 1 : UInt32(n + 1),
                                                                firstLeaf: 1, lastLeaf: UInt32(n), depth: n == 1 ? 1 : 2))
        for (index, records) in leaves.enumerated() {
            let number = index + 1
            writeNode(tree: Self.catalogBlock, number,
                      Self.leafNode(records, fLink: number < n ? UInt32(number + 1) : 0, bLink: UInt32(number - 1)))
        }
        if n > 1 {
            var index = Data(repeating: 0, count: Self.nodeSize)
            index[8] = 0; index[9] = 2
            writeNode(tree: Self.catalogBlock, n + 1, index)
        }
    }

    /// Writes an extents overflow tree with one leaf of (fileID, startBlock, extents) records.
    mutating func overflow(_ records: [(UInt32, UInt32, [(Int, Int)])]) {
        writeNode(tree: Self.extentsBlock, 0, Self.headerNode(totalNodes: 2, root: 1, firstLeaf: 1, lastLeaf: 1, depth: 1))
        writeNode(tree: Self.extentsBlock, 1, Self.leafNode(records.map { Self.overflowRecord($0.0, $0.1, $0.2) }))
    }

    /// Writes an attributes tree holding inline decmpfs headers (file ID → uncompressed size).
    mutating func decmpfs(_ sizes: [(UInt32, UInt64)]) {
        hasAttributes = true
        writeNode(tree: Self.attributesBlock, 0, Self.headerNode(totalNodes: 4, root: 1, firstLeaf: 1, lastLeaf: 1, depth: 1))
        let records = sizes.map { fileID, size -> Data in
            let name = Array("com.apple.decmpfs".utf16)
            var record = Data(repeating: 0, count: 2 + 12 + 2 * name.count + 16 + 16)
            record.putBigEndian(0, UInt64(12 + 2 * name.count), 2); record.putBigEndian(4, UInt64(fileID), 4)
            record.putBigEndian(12, UInt64(name.count), 2)
            for (index, unit) in name.enumerated() { record.putBigEndian(14 + index * 2, UInt64(unit), 2) }
            let d = 14 + 2 * name.count
            record.putBigEndian(d, 0x10, 4); record.putBigEndian(d + 12, 16, 4)
            record.replaceSubrange(d + 16..<d + 20, with: Array("fpmc".utf8)); record.put(d + 20, 3, 4); record.put(d + 24, size, 8)
            return record
        }
        writeNode(tree: Self.attributesBlock, 1, Self.leafNode(records))
    }

    // MARK: Catalog records

    static func key(_ parent: UInt32, _ name: String) -> Data { key(parent, Array(name.utf16)) }
    static func key(_ parent: UInt32, _ units: [UInt16]) -> Data {
        var key = Data(repeating: 0, count: 8 + 2 * units.count)
        key.putBigEndian(0, UInt64(6 + 2 * units.count), 2); key.putBigEndian(2, UInt64(parent), 4)
        key.putBigEndian(6, UInt64(units.count), 2)
        for (index, unit) in units.enumerated() { key.putBigEndian(8 + index * 2, UInt64(unit), 2) }
        return key
    }
    static func folder(_ id: UInt32, contentModDate: UInt64 = 0, attributeModDate: UInt64 = 0) -> Data {
        var record = Data(repeating: 0, count: 88)
        record.putBigEndian(0, 1, 2); record.putBigEndian(8, UInt64(id), 4); record.putBigEndian(42, 0o40755, 2)
        record.putBigEndian(16, contentModDate, 4); record.putBigEndian(20, attributeModDate, 4)
        return record
    }
    static func thread(file: Bool, parent: UInt32, name: String) -> Data {
        let units = Array(name.utf16)
        var record = Data(repeating: 0, count: 10 + 2 * units.count)
        record.putBigEndian(0, file ? 4 : 3, 2); record.putBigEndian(4, UInt64(parent), 4); record.putBigEndian(8, UInt64(units.count), 2)
        for (index, unit) in units.enumerated() { record.putBigEndian(10 + index * 2, UInt64(unit), 2) }
        return record
    }
    static func file(_ id: UInt32, size: UInt64, extents: [(Int, Int)], mtime: UInt64 = 3_900_000_000, mode: UInt64 = 0o100644,
                     ownerFlags: UInt64 = 0, special: UInt64 = 1, fdType: String = "\0\0\0\0", fdCreator: String = "\0\0\0\0",
                     totalBlocks: Int? = nil) -> Data {
        var record = Data(repeating: 0, count: 248)
        record.putBigEndian(0, 2, 2); record.putBigEndian(2, 0x86, 2); record.putBigEndian(8, UInt64(id), 4)
        record.putBigEndian(12, mtime, 4); record.putBigEndian(16, mtime, 4)
        record[41] = UInt8(ownerFlags); record.putBigEndian(42, mode, 2); record.putBigEndian(44, special, 4)
        record.replaceSubrange(48..<52, with: Array(fdType.utf8)); record.replaceSubrange(52..<56, with: Array(fdCreator.utf8))
        record.putBigEndian(88, size, 8)
        record.putBigEndian(100, UInt64(totalBlocks ?? extents.reduce(0) { $0 + $1.1 }), 4)
        for (index, extent) in extents.prefix(8).enumerated() {
            record.putBigEndian(104 + index * 8, UInt64(extent.0), 4); record.putBigEndian(108 + index * 8, UInt64(extent.1), 4)
        }
        return record
    }
    /// A live file record: key + record, with its blocks marked used.
    mutating func file(_ parent: UInt32, _ name: String, id: UInt32, size: UInt64, extents: [(Int, Int)], mtime: UInt64 = 3_900_000_000,
                       mode: UInt64 = 0o100644, ownerFlags: UInt64 = 0) -> Data {
        for extent in extents { for block in extent.0..<extent.0 + extent.1 { mark(block: block) } }
        return Self.key(parent, name) + Self.file(id, size: size, extents: extents, mtime: mtime, mode: mode, ownerFlags: ownerFlags)
    }
    static func root(_ name: String = "VOL") -> [Data] { [key(1, name) + folder(2), key(2, "") + thread(file: false, parent: 1, name: name)] }

    /// Distinct bytes for one block, so a block read from the wrong place never compares equal.
    static func pattern(_ block: Int) -> Data {
        Data((0..<blockSize).map { UInt8(truncatingIfNeeded: block &* 31 &+ $0 &* 7 &+ 1) })
    }
    @discardableResult
    mutating func fill(_ blocks: [Int]) -> Data {
        var expected = Data()
        for block in blocks {
            data.replaceSubrange(block * Self.blockSize..<(block + 1) * Self.blockSize, with: Self.pattern(block))
            expected += Self.pattern(block)
        }
        return expected
    }

    // MARK: Journal

    static func journalChecksum(_ bytes: Data) -> UInt32 {
        var sum: UInt32 = 0
        for byte in bytes { sum = (sum << 8) ^ (sum &+ UInt32(byte)) }
        return ~sum
    }

    /// One journal transaction for `journalTransactions`.
    struct JournalTransaction {
        var blocks: [(Int64, Data)]
        /// Buffer offset of the block list header; nil places it right after the previous one.
        var position: Int? = nil
        /// Sequence number in `binfo[0]`; nil numbers transactions 1, 2, 3...
        var sequence: UInt32? = nil
        /// Sets BLHDR_CHECK_CHECKSUMS and fills per-block checksums, as macOS does.
        var checksums = true
        /// Index of a block whose checksum is written wrong.
        var corruptBlock: Int? = nil
    }

    /// Writes a journal whose buffer holds `transactions`, each a list of (sector number, bytes).
    /// `dirty` leaves `start != end` as an unreplayed journal would.
    mutating func journal(_ transactions: [[(Int64, Data)]], bigEndian: Bool = false, dirty: Bool = false) {
        journalTransactions(transactions.map { JournalTransaction(blocks: $0) }, bigEndian: bigEndian, dirty: dirty)
    }

    /// Writes transactions at chosen buffer positions (data wraps past the buffer's end to just
    /// after the journal header) and sets `end` (default: where the last transaction ends).
    mutating func journalTransactions(_ transactions: [JournalTransaction], end: Int? = nil, bigEndian: Bool = false, dirty: Bool = false) {
        hasJournal = true
        let info = Self.journalInfoBlock * Self.blockSize
        let base = Self.journalBlock * Self.blockSize, size = Self.journalBlocks * Self.blockSize
        data.putBigEndian(info, 1, 4); data.putBigEndian(info + 36, UInt64(base), 8); data.putBigEndian(info + 44, UInt64(size), 8)
        func put(_ offset: Int, _ value: UInt64, _ width: Int) {
            if bigEndian { data.putBigEndian(offset, value, width) } else { data.put(offset, value, width) }
        }
        let blhdrSize = 4096, sectorSize = 512
        func ring(_ position: Int) -> Int { position >= size ? sectorSize + (position - size) : position }
        var position = sectorSize
        for (index, transaction) in transactions.enumerated() {
            position = transaction.position ?? position
            let blocks = transaction.blocks
            let header = base + position
            data.replaceSubrange(header..<header + blhdrSize, with: Data(repeating: 0, count: blhdrSize))
            put(header, UInt64(blhdrSize / 16 - 1), 2); put(header + 2, UInt64(blocks.count + 1), 2)
            put(header + 4, UInt64(blhdrSize + blocks.reduce(0) { $0 + $1.1.count }), 4)
            put(header + 12, transaction.checksums ? 3 : 2, 4)
            put(header + 16 + 12, UInt64(transaction.sequence ?? UInt32(index + 1)), 4)
            var cursor = ring(position + blhdrSize)
            for (number, block) in blocks.enumerated() {
                put(header + 16 + (number + 1) * 16, UInt64(bitPattern: block.0), 8)
                put(header + 16 + (number + 1) * 16 + 8, UInt64(block.1.count), 4)
                if transaction.checksums {
                    let checksum = Self.journalChecksum(block.1) ^ (transaction.corruptBlock == number ? 1 : 0)
                    put(header + 16 + (number + 1) * 16 + 12, UInt64(checksum), 4)
                }
                for (offset, byte) in block.1.enumerated() { data[base + ring(cursor + offset)] = byte }
                cursor = ring(cursor + block.1.count)
            }
            let checksum = Self.journalChecksum(data.subdata(in: header..<header + 32))
            put(header + 8, UInt64(checksum), 4)
            position = cursor
        }
        let endPosition = end ?? position
        put(base, 0x4A4E_4C78, 4); put(base + 4, 0x1234_5678, 4)
        put(base + 8, UInt64(dirty ? sectorSize : endPosition), 8); put(base + 16, UInt64(endPosition), 8)
        put(base + 24, UInt64(size), 8); put(base + 32, UInt64(blhdrSize), 4); put(base + 36, 0, 4); put(base + 40, UInt64(sectorSize), 4)
        put(base + 44, UInt64(transactions.count), 4)
        put(base + 36, UInt64(Self.journalChecksum(data.subdata(in: base..<base + 44))), 4)
    }
    /// Sector number of catalog node `node`, as a journal block list names it.
    static func catalogSector(_ node: Int) -> Int64 { Int64((catalogBlock + node) * blockSize / 512) }
}

/// Runs `HFSPlusVolume` directly so tests can lower limits and read its counters.
func runHFS(_ reader: any BlockReader, limits: HFSPlusLimits = HFSPlusLimits()) async
    -> (files: [RecoveredFile], error: (any Error)?, volume: HFSPlusVolume) {
    let collector = FileCollector()
    let volume = HFSPlusVolume(reader: reader, extent: VolumeExtent(offset: 0, length: reader.sizeBytes, format: .hfsPlus)) {
        await collector.add($0)
    }
    await volume.setLimits(limits)
    var failure: (any Error)? = nil
    do { try await volume.scan() } catch { failure = error }
    return (await collector.files, failure, volume)
}
func runHFS(_ image: HFSImage, limits: HFSPlusLimits = HFSPlusLimits()) async
    -> (files: [RecoveredFile], error: (any Error)?, volume: HFSPlusVolume) {
    await runHFS(ImageReader(data: image.image), limits: limits)
}

/// Throws an injected error for any read that overlaps one of `faults`.
private struct FaultyReader: BlockReader {
    let data: Data
    let faults: [Range<Int64>]
    var error: ScanError = .io("injected fault")
    var sizeBytes: Int64 { Int64(data.count) }
    func read(at offset: Int64, count: Int) async throws -> Data {
        guard offset >= 0, Int64(count) <= sizeBytes - offset else { throw ScanError.io("Out of bounds") }
        if faults.contains(where: { $0.overlaps(offset..<offset + Int64(count)) }) { throw error }
        return data.subdata(in: Int(offset)..<Int(offset) + count)
    }
}

private func found(_ events: [ScanEvent]) -> [RecoveredFile] {
    events.compactMap { if case .found(let file) = $0 { file } else { nil } }
}
private func readBack(_ file: RecoveredFile?, from image: Data) async throws -> Data {
    guard let file else { throw ScanError.malformed("missing file") }
    return try await FileContentReader(reader: ImageReader(data: image), chunkSize: 512).prefix(of: file, limit: .max)
}
private func hfsDate(_ seconds: UInt64) -> Date { Date(timeIntervalSince1970: Double(seconds) - 2_082_844_800) }

/// Volume with /hello.txt (block 70), /docs/inner/nested.txt (blocks 71-72), stale-free.
private func basicImage() -> (image: HFSImage, hello: Data, nested: Data) {
    var image = HFSImage()
    let hello = image.fill([70]).prefix(9)
    let nested = image.fill([71, 72]).prefix(4096 + 100)
    image.catalog([HFSImage.root() + [
        HFSImage.key(2, "docs") + HFSImage.folder(20),
        image.file(2, "hello.txt", id: 21, size: 9, extents: [(70, 1)], mtime: 3_800_000_000),
        HFSImage.key(20, "") + HFSImage.thread(file: false, parent: 2, name: "docs"),
        HFSImage.key(20, "inner") + HFSImage.folder(22),
        HFSImage.key(21, "") + HFSImage.thread(file: true, parent: 2, name: "hello.txt"),
        HFSImage.key(22, "") + HFSImage.thread(file: false, parent: 20, name: "inner"),
        image.file(22, "nested.txt", id: 23, size: 4096 + 100, extents: [(71, 2)]),
        HFSImage.key(23, "") + HFSImage.thread(file: true, parent: 22, name: "nested.txt"),
    ]])
    return (image, Data(hello), Data(nested))
}

@Suite("HFS+ scanning")
struct HFSPlusVolumeTests {
    @Test func liveFilesWithNestedPathsSizesTimesAndContent() async throws {
        let (image, hello, nested) = basicImage()
        let bytes = image.image
        let events = await scan(bytes)
        #expect(events.last == .completed)
        let files = found(events)
        #expect(files.map(\.path) == ["/hello.txt", "/docs/inner/nested.txt"])
        #expect(files.map(\.sizeBytes) == [9, 4096 + 100])
        #expect(files[0].modified == hfsDate(3_800_000_000))
        #expect(files.allSatisfy { !$0.isDeleted && $0.sourceMetadata.filesystem == .hfsPlus && $0.sourceMetadata.contiguous })
        #expect(files[0].sourceMetadata.allocationStart == 21)
        #expect(files[0].content == .runs([DataRun(deviceOffset: 70 * 4096, length: 9)]))
        #expect(files[1].content == .runs([DataRun(deviceOffset: 71 * 4096, length: 4096 + 100)]))
        #expect(try await readBack(files[0], from: bytes) == hello)
        #expect(try await readBack(files[1], from: bytes) == nested)
        // The record offset points at the key of hello.txt inside catalog node 1.
        let node = Int64((HFSImage.catalogBlock + 1) * HFSImage.blockSize)
        #expect(files[0].sourceMetadata.recordOffset > node && files[0].sourceMetadata.recordOffset < node + 4096)
        let expectedRecordLength = 8 + 2 * "hello.txt".utf16.count + 248
        #expect(files[0].sourceMetadata.rawRecord.count == expectedRecordLength)
    }

    @Test func hfsxAndPartitionedVolumesRouteThroughDiscovery() async throws {
        var (image, hello, _) = basicImage()
        image.signature = 0x4858; image.version = 5
        let volume = image.image
        #expect(found(await scan(volume)).map(\.path) == ["/hello.txt", "/docs/inner/nested.txt"])
        var disk = Data(repeating: 0, count: 512) + volume
        disk.put(446 + 4, 0xAF, 1); disk.put(446 + 8, 1, 4); disk.put(446 + 12, UInt64(volume.count / 512), 4); disk.put(510, 0xaa55, 2)
        let events = await scan(disk)
        #expect(events.last == .completed)
        let files = found(events)
        #expect(files.map(\.path) == ["/hello.txt", "/docs/inner/nested.txt"])
        #expect(files.allSatisfy { $0.sourceMetadata.volumeOffset == 512 })
        #expect(files[0].content == .runs([DataRun(deviceOffset: 512 + 70 * 4096, length: 9)]))
        #expect(try await readBack(files[0], from: disk) == hello)
    }

    @Test func hfsWrapperIsUnsupported() async {
        var image = basicImage().image
        image.signature = 0x4244
        let direct = await runHFS(image)
        #expect(direct.error as? ScanError == .unsupportedFilesystem)
        #expect(direct.files.isEmpty)
    }

    @Test func badHeadersAreMalformed() async {
        var badBlockSize = basicImage().image.image; badBlockSize.putBigEndian(1024 + 40, 3000, 4)
        var tooManyBlocks = basicImage().image.image; tooManyBlocks.putBigEndian(1024 + 44, 100_000, 4)
        var badVersion = basicImage().image.image; badVersion.putBigEndian(1024 + 2, 7, 2)
        var catalogOutside = basicImage().image.image; catalogOutside.putBigEndian(1024 + 272 + 16, 250, 4)
        var noSignature = basicImage().image.image; noSignature.putBigEndian(1024, 0, 2)
        var hugeOverflowCount = basicImage().image.image; hugeOverflowCount.putBigEndian(1024 + 272, 1 << 40, 8)
        for image in [badBlockSize, tooManyBlocks, badVersion, catalogOutside, hugeOverflowCount] {
            let result = await runHFS(ImageReader(data: image))
            #expect(isMalformed(result.error))
            #expect(result.files.isEmpty)
        }
        // Without a signature discovery never routes here; the parser itself still refuses.
        #expect(isMalformed(await runHFS(ImageReader(data: noSignature)).error))
    }

    @Test func leafChainCyclesAndBadNodesAreMalformed() async {
        var cycle = basicImage().image
        let leaf = cycle.image.subdata(in: (HFSImage.catalogBlock + 1) * 4096..<(HFSImage.catalogBlock + 2) * 4096)
        var looped = leaf; looped.putBigEndian(0, 1, 4)
        cycle.writeNode(tree: HFSImage.catalogBlock, 1, looped)
        var danglingLink = basicImage().image
        var dangling = leaf; dangling.putBigEndian(0, 9, 4)
        danglingLink.writeNode(tree: HFSImage.catalogBlock, 1, dangling)
        var nonLeaf = basicImage().image
        var index = leaf; index[8] = 0
        nonLeaf.writeNode(tree: HFSImage.catalogBlock, 1, index)
        var disorderedOffsets = basicImage().image
        var disordered = leaf; disordered.putBigEndian(4096 - 4, 14, 2)
        disorderedOffsets.writeNode(tree: HFSImage.catalogBlock, 1, disordered)
        var oversizedNodes = basicImage().image
        var header = oversizedNodes.image.subdata(in: HFSImage.catalogBlock * 4096..<(HFSImage.catalogBlock + 1) * 4096)
        header.putBigEndian(32, 65536, 2)
        oversizedNodes.writeNode(tree: HFSImage.catalogBlock, 0, header)
        var tooManyNodes = basicImage().image
        var count = header; count.putBigEndian(32, 4096, 2); count.putBigEndian(36, 1000, 4)
        tooManyNodes.writeNode(tree: HFSImage.catalogBlock, 0, count)
        var recordCountOverflow = basicImage().image
        var crowded = leaf; crowded.putBigEndian(10, 3000, 2)
        recordCountOverflow.writeNode(tree: HFSImage.catalogBlock, 1, crowded)
        for image in [cycle, danglingLink, nonLeaf, disorderedOffsets, oversizedNodes, tooManyNodes, recordCountOverflow] {
            let events = await scan(image.image)
            #expect(events.contains { if case .error(.malformed) = $0 { true } else { false } })
            #expect(!events.contains(.completed))
        }
    }

    @Test func moreThanEightExtentsResolveThroughTheOverflowTree() async throws {
        var image = HFSImage()
        let extents = (0..<10).map { (80 + 2 * $0, 1) }
        let expected = image.fill(extents.map(\.0)).prefix(9 * 4096 + 17)
        image.catalog([HFSImage.root() + [
            image.file(2, "frag.bin", id: 30, size: 9 * 4096 + 17, extents: extents),
            HFSImage.key(30, "") + HFSImage.thread(file: true, parent: 2, name: "frag.bin"),
        ]])
        var missing = image
        image.overflow([(30, 8, [(96, 1), (98, 1)])])
        let bytes = image.image
        let result = await runHFS(ImageReader(data: bytes))
        #expect(result.error == nil)
        #expect(result.files.map(\.path) == ["/frag.bin"])
        #expect(result.files.first?.sourceMetadata.contiguous == false)
        if case .runs(let runs) = result.files.first?.content { #expect(runs.count == 10) } else { Issue.record("no runs") }
        #expect(try await readBack(result.files.first, from: bytes) == expected)
        // The record names ten blocks but only eight are present and no overflow record exists.
        #expect(isMalformed(await runHFS(missing).error))
        // An overflow record for a different start block does not fill the gap either.
        missing.overflow([(30, 9, [(96, 1), (98, 1)])])
        #expect(isMalformed(await runHFS(missing).error))
    }

    @Test func hardLinksResolveAndNonRegularEntriesAreSkipped() async throws {
        var image = HFSImage()
        let payload = image.fill([70]).prefix(9)
        let privateName = HFSImage.key(2, [0, 0, 0, 0] + Array("HFS+ Private Data".utf16))
        image.catalog([HFSImage.root() + [
            privateName + HFSImage.folder(18),
            HFSImage.key(2, "alias") + HFSImage.file(40, size: 0, extents: [], mode: 0o100644, special: 7, fdType: "fdrp", fdCreator: "MACS"),
            HFSImage.key(2, "link.txt") + HFSImage.file(41, size: 0, extents: [], mtime: 1, mode: 0o100444, special: 22, fdType: "hlnk", fdCreator: "hfs+"),
            HFSImage.key(2, "orphan.txt") + HFSImage.file(44, size: 0, extents: [], mode: 0o100444, special: 99, fdType: "hlnk", fdCreator: "hfs+"),
            HFSImage.key(2, "symlink") + HFSImage.file(42, size: 9, extents: [(71, 1)], mode: 0o120755, fdType: "slnk", fdCreator: "rhap"),
            HFSImage.key(2, ".journal") + HFSImage.file(16, size: 4096, extents: [(72, 1)], mode: 0o100000, fdType: "jrnl", fdCreator: "hfs+"),
            HFSImage.key(2, "device") + HFSImage.file(43, size: 0, extents: [], mode: 0o020644),
            HFSImage.key(18, "") + HFSImage.thread(file: false, parent: 2, name: "x"),
            image.file(18, "iNode22", id: 22, size: 9, extents: [(70, 1)], mtime: 3_700_000_000),
        ]])
        let bytes = image.image
        let result = await runHFS(ImageReader(data: bytes))
        #expect(result.error == nil)
        #expect(result.files.map(\.path) == ["/link.txt"])
        #expect(result.files.first?.sizeBytes == 9)
        #expect(result.files.first?.modified == hfsDate(3_700_000_000))
        #expect(result.files.first?.sourceMetadata.allocationStart == 22)
        #expect(try await readBack(result.files.first, from: bytes) == payload)
        #expect(await result.volume.stats.unresolvedHardLinks == 1)
    }

    @Test func compressedFilesAreUnmappedWithTheirDecmpfsSize() async {
        var image = HFSImage()
        image.catalog([HFSImage.root() + [
            image.file(2, "comp.txt", id: 30, size: 0, extents: [], ownerFlags: 0x20),
            image.file(2, "unknown.txt", id: 31, size: 0, extents: [], ownerFlags: 0x20),
            HFSImage.key(30, "") + HFSImage.thread(file: true, parent: 2, name: "comp.txt"),
        ]])
        var withoutAttributes = image
        image.decmpfs([(30, 20001)])
        let result = await runHFS(image)
        #expect(result.error == nil)
        #expect(result.files.map(\.sizeBytes) == [20001, 0])
        #expect(result.files.allSatisfy { $0.content == .unmapped })
        #expect(await result.volume.stats.compressedFiles == 2)
        // Without an attributes tree the flag alone still keeps the contents unmapped.
        withoutAttributes.hasAttributes = false
        let bare = await runHFS(withoutAttributes)
        #expect(bare.error == nil)
        #expect(bare.files.map(\.content) == [.unmapped, .unmapped])
    }

    @Test func emptyFileHasNoRunsAndShortExtentsAreMalformed() async {
        var image = HFSImage()
        image.catalog([HFSImage.root() + [image.file(2, "empty", id: 30, size: 0, extents: [])]])
        let result = await runHFS(image)
        #expect(result.error == nil)
        #expect(result.files.map(\.content) == [.runs([])])
        var short = HFSImage()
        short.catalog([HFSImage.root() + [short.file(2, "short", id: 30, size: 5000, extents: [(70, 1)])]])
        #expect(isMalformed(await runHFS(short).error))
        var outside = HFSImage()
        outside.catalog([HFSImage.root() + [HFSImage.key(2, "out") + HFSImage.file(30, size: 10, extents: [(255, 2)])]])
        #expect(isMalformed(await runHFS(outside).error))
    }

    @Test func namesAreValidatedAndPrecomposed() async {
        var image = HFSImage()
        // "café.txt" stored decomposed (e + U+0301); "a/b" is how the catalog stores the POSIX
        // name "a:b" (also inside a folder, so the path separator is never confused with it);
        // a literal catalog ":" can't come from POSIX and is kept.
        let decomposed: [UInt16] = Array("caf".utf16) + [0x65, 0x0301] + Array(".txt".utf16)
        image.catalog([HFSImage.root() + [
            HFSImage.key(2, decomposed) + HFSImage.file(30, size: 0, extents: []),
            HFSImage.key(2, "a/b") + HFSImage.file(31, size: 0, extents: []),
            HFSImage.key(2, "c:d") + HFSImage.file(32, size: 0, extents: []),
            HFSImage.key(2, "12/00") + HFSImage.folder(20),
            HFSImage.key(20, "x/y.log") + HFSImage.file(33, size: 0, extents: []),
        ]])
        let result = await runHFS(image)
        #expect(result.error == nil)
        #expect(result.files.map(\.name) == ["café.txt", "a:b", "c:d", "x:y.log"])
        #expect(result.files.map(\.path) == ["/café.txt", "/a:b", "/c:d", "/12:00/x:y.log"])
        var nul = HFSImage()
        nul.catalog([HFSImage.root() + [HFSImage.key(2, [0x41, 0, 0x42]) + HFSImage.file(30, size: 0, extents: [])]])
        #expect(isMalformed(await runHFS(nul).error))
        var surrogate = HFSImage()
        surrogate.catalog([HFSImage.root() + [HFSImage.key(2, [0xD800, 0x41]) + HFSImage.file(30, size: 0, extents: [])]])
        #expect(isMalformed(await runHFS(surrogate).error))
        var orphan = HFSImage()
        orphan.catalog([HFSImage.root() + [HFSImage.key(77, "lost") + HFSImage.file(30, size: 0, extents: [])]])
        #expect(isMalformed(await runHFS(orphan).error))
    }

    @Test func folderCyclesAndDepthAreBounded() async {
        var cycle = HFSImage()
        cycle.catalog([HFSImage.root() + [
            HFSImage.key(2, "a") + HFSImage.folder(20), HFSImage.key(20, "b") + HFSImage.folder(21),
            HFSImage.key(21, "c") + HFSImage.folder(20), HFSImage.key(21, "f") + HFSImage.file(30, size: 0, extents: []),
        ]])
        // Folder 20 is listed twice (under root and under 21): a duplicate CNID, hence malformed.
        #expect(isMalformed(await runHFS(cycle).error))
        var loop = HFSImage()
        loop.catalog([HFSImage.root() + [
            HFSImage.key(21, "a") + HFSImage.folder(20), HFSImage.key(20, "b") + HFSImage.folder(21),
            HFSImage.key(21, "f") + HFSImage.file(30, size: 0, extents: []),
        ]])
        var limits = HFSPlusLimits(); limits.maxPathDepth = 50
        let result = await runHFS(loop, limits: limits)
        #expect(isMalformed(result.error))
        #expect(result.files.isEmpty)
    }

    // MARK: Deleted files

    /// Root holds live.txt (block 70). gone.txt (id 31, block 90) exists only as a stale record.
    func staleRecord(id: UInt32 = 31, name: String = "gone.txt", parent: UInt32 = 2, size: UInt64 = 600, extents: [(Int, Int)] = [(90, 1)],
                     mtime: UInt64 = 3_850_000_000) -> Data {
        HFSImage.key(parent, name) + HFSImage.file(id, size: size, extents: extents, mtime: mtime)
    }
    func liveRecords(_ image: inout HFSImage) -> [Data] {
        HFSImage.root() + [image.file(2, "live.txt", id: 30, size: 4, extents: [(70, 1)]),
                           HFSImage.key(30, "") + HFSImage.thread(file: true, parent: 2, name: "live.txt")]
    }

    @Test func staleRecordInNodeSlackIsRecoveredWhenItsBlocksAreFree() async throws {
        var image = HFSImage()
        let gone = image.fill([90]).prefix(600)
        let live = liveRecords(&image)
        image.catalog([live])
        image.writeNode(tree: HFSImage.catalogBlock, 1, HFSImage.leafNode(live, slack: Data(repeating: 0xAB, count: 6) + staleRecord()))
        let bytes = image.image
        let events = await scan(bytes)
        #expect(events.last == .completed)
        let files = found(events)
        #expect(files.map(\.path) == ["/live.txt", "/gone.txt"])
        #expect(files.map(\.isDeleted) == [false, true])
        #expect(files[1].sizeBytes == 600 && files[1].modified == hfsDate(3_850_000_000))
        #expect(files[1].sourceMetadata.allocationStart == 31)
        #expect(files[1].content == .runs([DataRun(deviceOffset: 90 * 4096, length: 600)]))
        #expect(try await readBack(files[1], from: bytes) == gone)
    }

    @Test func unlinkedLeafNodesYieldDeletedFilesAndStaleFolderPaths() async throws {
        var image = HFSImage()
        let inside = image.fill([91]).prefix(2000)
        image.catalog([liveRecords(&image)])
        // Node 3 is not on the leaf chain: a freed leaf still holding a deleted folder and its file.
        image.writeNode(tree: HFSImage.catalogBlock, 3, HFSImage.leafNode([
            HFSImage.key(2, "doomed") + HFSImage.folder(40),
            staleRecord(id: 41, name: "inside.bin", parent: 40, size: 2000, extents: [(91, 1)]),
        ]))
        let bytes = image.image
        let result = await runHFS(ImageReader(data: bytes))
        #expect(result.error == nil)
        #expect(result.files.map(\.path) == ["/live.txt", "/doomed/inside.bin"])
        #expect(result.files[1].isDeleted)
        #expect(try await readBack(result.files[1], from: bytes) == inside)
        #expect(await result.volume.stats.staleNodesExamined == HFSImage.catalogNodes - 2)
    }

    @Test func journalTransactionsYieldDeletedFiles() async throws {
        for bigEndian in [false, true] {
            var image = HFSImage()
            let gone = image.fill([90]).prefix(600)
            let live = liveRecords(&image)
            image.catalog([live])
            // An older copy of node 1 (as journaled before the deletion) still lists gone.txt.
            let older = HFSImage.leafNode(live + [staleRecord()])
            var bitmap = Data(repeating: 0, count: 4096); bitmap[0] = 0xFF
            image.journal([[(HFSImage.catalogSector(1), older), (Int64(1 * 4096 / 512), bitmap)],
                           [(2, Data(repeating: 0, count: 512))]], bigEndian: bigEndian)
            let bytes = image.image
            let result = await runHFS(ImageReader(data: bytes))
            #expect(result.error == nil)
            #expect(result.files.map(\.path) == ["/live.txt", "/gone.txt"])
            #expect(result.files[1].isDeleted)
            #expect(try await readBack(result.files[1], from: bytes) == gone)
            #expect(await result.volume.stats.journalTransactions == 2)
            #expect(await result.volume.stats.journal == "scanned")
            // The record offset points into the journal buffer, not the live catalog.
            let journalStart = Int64(HFSImage.journalBlock * 4096), journalEnd = journalStart + Int64(HFSImage.journalBlocks * 4096)
            #expect(result.files[1].sourceMetadata.recordOffset > journalStart && result.files[1].sourceMetadata.recordOffset < journalEnd)
        }
    }

    @Test func journalProblemsAreNotedAndUnreplayedJournalsDisableRecovery() async {
        var absent = HFSImage()
        absent.catalog([liveRecords(&absent)])
        let plain = await runHFS(absent)
        #expect(plain.error == nil)
        #expect(await plain.volume.stats.journal == "absent")
        var dirty = HFSImage()
        let live = liveRecords(&dirty)
        dirty.catalog([live])
        dirty.writeNode(tree: HFSImage.catalogBlock, 1, HFSImage.leafNode(live, slack: staleRecord()))
        dirty.journal([[(HFSImage.catalogSector(1), HFSImage.leafNode(live + [staleRecord()]))]], dirty: true)
        let unreplayed = await runHFS(dirty)
        #expect(unreplayed.error == nil)
        #expect(unreplayed.files.map(\.path) == ["/live.txt"])
        #expect(await unreplayed.volume.stats.deletedRecoveryDisabled != nil)
        var corrupt = HFSImage()
        corrupt.catalog([liveRecords(&corrupt)])
        corrupt.journal([[(HFSImage.catalogSector(1), HFSImage.leafNode(live + [staleRecord()]))]])
        corrupt.data.put(HFSImage.journalBlock * 4096 + 4, 0xDEADBEEF, 4)
        let bad = await runHFS(corrupt)
        #expect(bad.error == nil)
        #expect(bad.files.map(\.path) == ["/live.txt"])
        #expect((await bad.volume.stats.journal).hasPrefix("unreadable"))
        var reused = HFSImage()
        reused.catalog([liveRecords(&reused)])
        reused.writeNode(tree: HFSImage.catalogBlock, 1, HFSImage.leafNode(live, slack: staleRecord()))
        reused.attributes |= 1 << 12
        let wrapped = await runHFS(reused)
        #expect(wrapped.files.map(\.path) == ["/live.txt"])
        #expect((await wrapped.volume.stats.deletedRecoveryDisabled)?.contains("wrapped") == true)
    }

    @Test func untrustworthyCandidatesAreSkipped() async {
        func slackImage(_ stale: [Data], prepare: (inout HFSImage) -> Void = { _ in }) -> HFSImage {
            var image = HFSImage()
            let live = liveRecords(&image)
            image.catalog([live])
            image.writeNode(tree: HFSImage.catalogBlock, 1, HFSImage.leafNode(live, slack: stale.reduce(Data(), +)))
            prepare(&image)
            return image
        }
        // Blocks reused by something else.
        let reused = slackImage([staleRecord()]) { $0.mark(block: 90) }
        // The record's file ID is live (the stale copy is an older version of live.txt).
        let liveID = slackImage([staleRecord(id: 30)])
        // Extents outside the volume, needing overflow records, or oversized.
        let outside = slackImage([staleRecord(extents: [(300, 1)])])
        let overflowing = slackImage([HFSImage.key(2, "big") + HFSImage.file(31, size: 40_000, extents: [(90, 1)], totalBlocks: 10)])
        let shortMapping = slackImage([staleRecord(size: 5000)])
        // Two deleted files claiming the same block.
        let overlapping = slackImage([staleRecord(), staleRecord(id: 32, name: "other.bin", extents: [(90, 1)])])
        // Same file, same time, different contents: ambiguous.
        let ambiguous = slackImage([staleRecord(), staleRecord(extents: [(91, 1)])])
        // Compressed, hard-linked and symlinked candidates cannot be mapped.
        let compressed = slackImage([HFSImage.key(2, "c") + HFSImage.file(31, size: 600, extents: [(90, 1)], ownerFlags: 0x20)])
        let linked = slackImage([HFSImage.key(2, "l") + HFSImage.file(31, size: 600, extents: [(90, 1)], fdType: "hlnk", fdCreator: "hfs+")])
        // A parent folder nobody knows, or an ID past the catalog's next ID.
        let orphan = slackImage([staleRecord(parent: 77)])
        let future = slackImage([staleRecord(id: 500)])
        for image in [reused, liveID, outside, overflowing, shortMapping, overlapping, ambiguous, compressed, linked, orphan, future] {
            let events = await scan(image.image)
            #expect(events.last == .completed)
            #expect(found(events).map(\.path) == ["/live.txt"])
        }
        // Distinct blocks: both deleted files come back.
        let distinct = slackImage([staleRecord(), staleRecord(id: 32, name: "other.bin", extents: [(91, 1)])])
        #expect(found(await scan(distinct.image)).map(\.path) == ["/live.txt", "/gone.txt", "/other.bin"])
        // Several versions of one file: the newest wins.
        let versions = slackImage([staleRecord(extents: [(91, 1)], mtime: 1), staleRecord(mtime: 2)])
        let newest = found(await scan(versions.image))
        #expect(newest.last?.content == .runs([DataRun(deviceOffset: 90 * 4096, length: 600)]))
        #expect(newest.last?.modified == hfsDate(2))
    }

    @Test func deletedWorkBudgetAndCandidateCapsBound() async {
        var image = HFSImage()
        let live = liveRecords(&image)
        image.catalog([live])
        image.writeNode(tree: HFSImage.catalogBlock, 1, HFSImage.leafNode(live, slack: staleRecord() + staleRecord(id: 32, name: "b", extents: [(91, 1)])))
        let full = await runHFS(image)
        #expect(full.files.map(\.path) == ["/live.txt", "/gone.txt", "/b"])
        let spent = await full.volume.stats.deletedWorkSpent
        #expect(await full.volume.deletedWorkRemaining + spent == 4 * 256 + 1_000_000)
        var limits = HFSPlusLimits(); limits.deletedWorkBudget = 1
        let starved = await runHFS(image, limits: limits)
        #expect(starved.error == nil)
        #expect(starved.files.map(\.path) == ["/live.txt"])
        #expect(await starved.volume.stats.deletedBudgetExhausted)
        var capped = HFSPlusLimits(); capped.maxCandidates = 1
        let one = await runHFS(image, limits: capped)
        #expect(one.files.count == 2)
        #expect(await one.volume.stats.candidatesDropped == 1)
        #expect(HFSPlusLimits().maxCandidates == 100_000 && HFSPlusLimits().maxPathDepth == 2048)
    }

    @Test func overlapDetectionFlagsAcceptedRangesOverlappingAnotherOwner() {
        func claim(_ start: UInt64, _ end: UInt64, _ owner: UInt32) -> HFSPlusClaim { HFSPlusClaim(start: start, end: end, owner: owner) }
        let evidence = [claim(0, 10, 0), claim(2, 3, 1), claim(5, 20, 2), claim(20, 21, 3),
                        claim(30, 31, 4), claim(30, 32, 4), claim(40, 50, 5), claim(41, 45, 6), claim(46, 47, 5),
                        claim(105, 106, 12), claim(100, 110, 11)]
        // 0 overlaps 1 and 2; 3 only touches 2; 4's versions share blocks; 5's accepted range
        // overlaps only its own older version; 6 sits inside 5's older version; 11 contains 12.
        let accepted = [claim(0, 10, 0), claim(20, 21, 3), claim(30, 32, 4), claim(46, 47, 5), claim(41, 45, 6), claim(100, 110, 11)]
        #expect(HFSPlusVolume.overlappingOwners(accepted: accepted, evidence: evidence) == [0, 6, 11])
        // Owner 7's reach hides owner 8's shorter one; both overlaps are still found.
        let nested = [claim(0, 10, 7), claim(1, 3, 8), claim(2, 4, 7)]
        #expect(HFSPlusVolume.overlappingOwners(accepted: [claim(2, 4, 7), claim(1, 3, 8)], evidence: nested) == [7, 8])
        let adjacent = [claim(0, 1, 9), claim(1, 2, 10)]
        #expect(HFSPlusVolume.overlappingOwners(accepted: adjacent, evidence: adjacent).isEmpty)
    }

    @Test func helpersMatchTheSpecification() {
        #expect(HFSPlus.date(0) == nil)
        #expect(HFSPlus.date(2_082_844_800) == Date(timeIntervalSince1970: 0))
        #expect(HFSPlus.indirectNodeNumber(Array("iNode22".utf16)) == 22)
        #expect(HFSPlus.indirectNodeNumber(Array("iNode".utf16)) == nil)
        #expect(HFSPlus.indirectNodeNumber(Array("iNodex".utf16)) == nil)
        #expect(HFSPlus.name([0xD800]) == nil)
        #expect(HFSPlus.name(Array("a/b".utf16)) == "a:b")
        #expect(HFSPlus.name(Array("a:b".utf16)) == "a:b")
        #expect(HFSPlus.name([0x61, 0]) == nil)
        #expect(HFSPlus.name(HFSPlus.privateDataFolderName) != nil)
        // TN1150's block list checksum, as the inspected real journal confirmed.
        #expect(HFSPlusJournal.checksum(Data()) == 0xFFFF_FFFF)
    }
    // MARK: Deleted-file work is best effort

    /// live.txt; gone.txt in node 1's slack (block 90); other.bin in a journal copy of node 1
    /// (block 91); stale.bin in freed catalog node 5 (block 92).
    func threeSourceImage() -> HFSImage {
        var image = HFSImage()
        image.fill([90, 91, 92])
        let live = liveRecords(&image)
        image.catalog([live])
        image.writeNode(tree: HFSImage.catalogBlock, 1, HFSImage.leafNode(live, slack: staleRecord()))
        image.writeNode(tree: HFSImage.catalogBlock, 5, HFSImage.leafNode([staleRecord(id: 33, name: "stale.bin", extents: [(92, 1)])]))
        image.journal([[(HFSImage.catalogSector(1), HFSImage.leafNode(live + [staleRecord(id: 32, name: "other.bin", extents: [(91, 1)])]))]])
        return image
    }
    func blocks(_ range: Range<Int>) -> Range<Int64> { Int64(range.lowerBound * 4096)..<Int64(range.upperBound * 4096) }

    @Test func readErrorsInDeletedFileSourcesNeverBlockLiveFiles() async throws {
        let bytes = threeSourceImage().image
        let healthy = await runHFS(ImageReader(data: bytes))
        #expect(healthy.error == nil)
        #expect(healthy.files.map(\.path) == ["/live.txt", "/gone.txt", "/other.bin", "/stale.bin"])
        // The journal's transactions are unreadable but its header reads: only the journal is skipped.
        let journalBuffer = blocks(HFSImage.journalBlock..<HFSImage.journalBlock + HFSImage.journalBlocks)
        let transactions = await runHFS(FaultyReader(data: bytes, faults: [journalBuffer.lowerBound + 512..<journalBuffer.upperBound]))
        #expect(transactions.error == nil)
        #expect(transactions.files.map(\.path) == ["/live.txt", "/gone.txt", "/stale.bin"])
        #expect(await transactions.volume.stats.notes.contains { $0.contains("journal") })
        // The whole buffer is unreadable, header included: unreplayed transactions can't be ruled
        // out, so deleted recovery is off, yet every live file is still emitted.
        let wholeJournal = await runHFS(FaultyReader(data: bytes, faults: [journalBuffer]))
        #expect(wholeJournal.error == nil)
        #expect(wholeJournal.files.map(\.path) == ["/live.txt"])
        #expect(await wholeJournal.volume.stats.deletedRecoveryDisabled != nil)
        // Freed catalog nodes unreadable: the other sources still work.
        let staleNodes = await runHFS(FaultyReader(data: bytes, faults: [blocks(HFSImage.catalogBlock + 5..<HFSImage.catalogBlock + 6)]))
        #expect(staleNodes.error == nil)
        #expect(staleNodes.files.map(\.path) == ["/live.txt", "/gone.txt", "/other.bin"])
        // The allocation bitmap unreadable: nothing deleted can be confirmed free, the scan completes.
        let bitmap = await runHFS(FaultyReader(data: bytes, faults: [blocks(1..<2)]))
        #expect(bitmap.error == nil)
        #expect(bitmap.files.map(\.path) == ["/live.txt"])
        #expect(await bitmap.volume.stats.notes.contains { $0.contains("bitmap") })
        // Other errors (here: a vanished device) still end the scan.
        let gone = await runHFS(FaultyReader(data: bytes, faults: [blocks(1..<2)], error: .deviceChanged))
        #expect(gone.error as? ScanError == .deviceChanged)
    }

    // MARK: Block reuse evidence

    @Test func blocksNamedByRejectedRecordsAreNotRecovered() async {
        // X (gone.txt) freed block 90; Y then took 90-91 and was deleted; live Z reuses 91. Y is
        // rejected (block 91 is used) but still proves block 90 was overwritten after X.
        var image = HFSImage()
        let live = liveRecords(&image) + [image.file(2, "z.bin", id: 34, size: 100, extents: [(91, 1)])]
        image.catalog([live])
        image.writeNode(tree: HFSImage.catalogBlock, 1, HFSImage.leafNode(live, slack:
            staleRecord() + staleRecord(id: 32, name: "y.bin", size: 8000, extents: [(90, 2)], mtime: 3_860_000_000)))
        let result = await runHFS(image)
        #expect(result.error == nil)
        #expect(result.files.map(\.path) == ["/live.txt", "/z.bin"])
        // A deleted record whose parent can't be resolved is evidence too.
        var orphan = HFSImage()
        let records = liveRecords(&orphan)
        orphan.catalog([records])
        orphan.writeNode(tree: HFSImage.catalogBlock, 1, HFSImage.leafNode(records, slack:
            staleRecord() + staleRecord(id: 32, name: "lost.bin", parent: 77, extents: [(90, 1)])))
        #expect((await runHFS(orphan)).files.map(\.path) == ["/live.txt"])
        // So is an older version of a live file.
        var older = HFSImage()
        let current = liveRecords(&older)
        older.catalog([current])
        older.writeNode(tree: HFSImage.catalogBlock, 1, HFSImage.leafNode(current, slack:
            staleRecord() + staleRecord(id: 30, name: "live.txt", extents: [(90, 1)])))
        #expect((await runHFS(older)).files.map(\.path) == ["/live.txt"])
    }

    @Test func supersededVersionsStillClaimTheirBlocks() async {
        // W once lived at block 90 and now (newer) at 95; deleted X also names block 90. Either
        // order of discovery: the superseded copy is evidence, the newest copy is still emitted.
        let older = staleRecord(id: 32, name: "w.bin", extents: [(90, 1)], mtime: 1)
        let newer = staleRecord(id: 32, name: "w.bin", extents: [(95, 1)], mtime: 2)
        for versions in [older + newer, newer + older] {
            var image = HFSImage()
            let live = liveRecords(&image)
            image.catalog([live])
            image.writeNode(tree: HFSImage.catalogBlock, 1, HFSImage.leafNode(live, slack: staleRecord() + versions))
            let result = await runHFS(image)
            #expect(result.error == nil)
            #expect(result.files.map(\.path) == ["/live.txt", "/w.bin"])
            #expect(result.files.last?.content == .runs([DataRun(deviceOffset: 95 * 4096, length: 600)]))
        }
    }

    // MARK: Journal transactions

    @Test func journalTransactionsThatWrapAroundTheBufferAreHarvested() async throws {
        var image = HFSImage()
        let gone = image.fill([90]).prefix(600)
        let live = liveRecords(&image)
        image.catalog([live])
        // The block list header fills the buffer's last 4 KiB, so the node copy wraps to offset 512.
        let size = HFSImage.journalBlocks * 4096
        image.journalTransactions([.init(blocks: [(HFSImage.catalogSector(1), HFSImage.leafNode(live + [staleRecord()]))],
                                         position: size - 4096)], end: 512 + 4096)
        let bytes = image.image
        let result = await runHFS(ImageReader(data: bytes))
        #expect(result.error == nil)
        #expect(result.files.map(\.path) == ["/live.txt", "/gone.txt"])
        #expect(try await readBack(result.files.last, from: bytes) == gone)
        #expect(await result.volume.stats.journalTransactions == 1)
    }

    @Test func tornWrappedJournalTransactionIsIgnored() async {
        var image = HFSImage()
        image.fill([90])
        let live = liveRecords(&image)
        image.catalog([live])
        // `end` falls inside the wrapped part: newer transactions were overwriting this one.
        let size = HFSImage.journalBlocks * 4096
        image.journalTransactions([.init(blocks: [(HFSImage.catalogSector(1), HFSImage.leafNode(live + [staleRecord()]))],
                                         position: size - 4096)], end: 2560)
        let result = await runHFS(image)
        #expect(result.error == nil)
        #expect(result.files.map(\.path) == ["/live.txt"])
        #expect(await result.volume.stats.journalTornTransactions == 1)
    }

    @Test func staleTransactionsPastTheJournalEndAreHarvested() async {
        var image = HFSImage()
        image.fill([90])
        let live = liveRecords(&image)
        image.catalog([live])
        // The current lap ends right after the first transaction; an older lap's transaction
        // further on still holds gone.txt.
        image.journalTransactions([
            .init(blocks: [(2, Data(repeating: 0, count: 512))], position: 512, sequence: 7),
            .init(blocks: [(HFSImage.catalogSector(1), HFSImage.leafNode(live + [staleRecord()]))], position: 65536, sequence: 3),
        ], end: 512 + 4096 + 512)
        let result = await runHFS(image)
        #expect(result.error == nil)
        #expect(result.files.map(\.path) == ["/live.txt", "/gone.txt"])
        #expect(await result.volume.stats.journalTransactions == 2)
    }

    @Test func laterJournalTransactionsWinOverEarlierCopies() async {
        // gone.txt was renamed (same modification time) before being deleted: the copy from the
        // later transaction names it, even though it sits earlier in the buffer.
        var image = HFSImage()
        image.fill([90])
        let live = liveRecords(&image)
        image.catalog([live])
        image.journalTransactions([
            .init(blocks: [(HFSImage.catalogSector(1), HFSImage.leafNode(live + [staleRecord(name: "new.txt")]))], position: 512, sequence: 10),
            .init(blocks: [(HFSImage.catalogSector(1), HFSImage.leafNode(live + [staleRecord(name: "old.txt")]))], position: 65536, sequence: 9),
        ], end: 512 + 8192)
        let result = await runHFS(image)
        #expect(result.files.map(\.path) == ["/live.txt", "/new.txt"])
    }

    @Test func journalBlocksWithBadChecksumsAreIgnored() async {
        var image = HFSImage()
        image.fill([90])
        let live = liveRecords(&image)
        image.catalog([live])
        image.journalTransactions([.init(blocks: [(HFSImage.catalogSector(1), HFSImage.leafNode(live + [staleRecord()]))], corruptBlock: 0)])
        let result = await runHFS(image)
        #expect(result.error == nil)
        #expect(result.files.map(\.path) == ["/live.txt"])
        #expect(await result.volume.stats.journalChecksumFailures == 1)
        // Without BLHDR_CHECK_CHECKSUMS the per-block slots aren't checked.
        var unchecked = HFSImage()
        unchecked.fill([90])
        let records = liveRecords(&unchecked)
        unchecked.catalog([records])
        unchecked.journalTransactions([.init(blocks: [(HFSImage.catalogSector(1), HFSImage.leafNode(records + [staleRecord()]))], checksums: false)])
        #expect((await runHFS(unchecked)).files.map(\.path) == ["/live.txt", "/gone.txt"])
    }

    @Test func onlyCatalogNodesOfAMultiNodeJournalBlockAreHarvested() async {
        var image = HFSImage()
        image.fill([90])
        let live = liveRecords(&image)
        image.catalog([live])
        // Catalog node 7 is the catalog's last; the block's second node is the attributes file's
        // first block, so a leaf there is not a catalog node.
        image.journal([[(HFSImage.catalogSector(7), HFSImage.leafNode(live) + HFSImage.leafNode([staleRecord()]))]])
        let outside = await runHFS(image)
        #expect(outside.error == nil)
        #expect(outside.files.map(\.path) == ["/live.txt"])
        // Nodes 2 and 3 are both catalog nodes: the second one is harvested.
        var inside = HFSImage()
        inside.fill([90])
        let records = liveRecords(&inside)
        inside.catalog([records])
        inside.journal([[(HFSImage.catalogSector(2), HFSImage.leafNode([]) + HFSImage.leafNode([staleRecord()]))]])
        #expect((await runHFS(inside)).files.map(\.path) == ["/live.txt", "/gone.txt"])
    }

    // MARK: Volume state

    @Test func uncleanVolumesAndUnusableJournalsDisableDeletedRecovery() async {
        func slackImage(_ prepare: (inout HFSImage) -> Void = { _ in }) -> HFSImage {
            var image = HFSImage()
            image.fill([90])
            let live = liveRecords(&image)
            image.catalog([live])
            image.writeNode(tree: HFSImage.catalogBlock, 1, HFSImage.leafNode(live, slack: staleRecord()))
            prepare(&image)
            return image
        }
        func journaled(_ image: inout HFSImage) { image.journal([[(2, Data(repeating: 0, count: 512))]]) }
        let info = HFSImage.journalInfoBlock * 4096, journalBase = HFSImage.journalBlock * 4096
        // Sanity: both a clean plain volume and a clean journaled one recover gone.txt; a
        // journaled volume relies on its journal, not on the unmounted bit.
        for image in [slackImage(), slackImage { journaled(&$0) }, slackImage { journaled(&$0); $0.attributes = 0 }] {
            #expect((await runHFS(image)).files.map(\.path) == ["/live.txt", "/gone.txt"])
        }
        let cases: [(String, Data)] = [
            ("not cleanly unmounted", slackImage { $0.attributes = 0 }.image),
            ("inconsistent", slackImage { $0.attributes = 1 << 8 | 1 << 11 }.image),
            ("external", slackImage { journaled(&$0); $0.data.putBigEndian(info, 0, 4) }.image),
            ("outside volume", slackImage { journaled(&$0); $0.data.putBigEndian(info + 36, 1 << 40, 8) }.image),
            ("bad header checksum", slackImage { journaled(&$0); $0.data[journalBase + 36] ^= 1 }.image),
            ("bad magic", slackImage { journaled(&$0); $0.data[journalBase] ^= 1 }.image),
            ("info block outside volume", { var bytes = slackImage { journaled(&$0) }.image; bytes.putBigEndian(1024 + 12, 0, 4); return bytes }()),
        ]
        for (reason, bytes) in cases {
            let result = await runHFS(ImageReader(data: bytes))
            #expect(result.error == nil, "\(reason)")
            #expect(result.files.map(\.path) == ["/live.txt"], "\(reason)")
            let disabled = await result.volume.stats.deletedRecoveryDisabled
            #expect(disabled != nil, "\(reason)")
            let note = (disabled ?? "") + " " + (await result.volume.stats.journal)
            #expect(note.contains(reason), "\(reason): \(note)")
        }
    }

    // MARK: Stale folders

    @Test func staleFolderCopiesResolveToTheLatestAndTiesAreUnresolvable() async throws {
        func renamed(first: UInt64, second: UInt64, secondName: String = "new") -> HFSImage {
            var image = HFSImage()
            image.fill([91])
            image.catalog([liveRecords(&image)])
            // Two freed leaves: the older copy of folder 40 is seen first.
            image.writeNode(tree: HFSImage.catalogBlock, 3, HFSImage.leafNode([
                HFSImage.key(2, "old") + HFSImage.folder(40, contentModDate: 50, attributeModDate: first),
                staleRecord(id: 41, name: "inside.bin", parent: 40, size: 2000, extents: [(91, 1)]),
            ]))
            image.writeNode(tree: HFSImage.catalogBlock, 4, HFSImage.leafNode([
                HFSImage.key(2, secondName) + HFSImage.folder(40, contentModDate: 50, attributeModDate: second),
            ]))
            return image
        }
        #expect((await runHFS(renamed(first: 100, second: 200))).files.map(\.path) == ["/live.txt", "/new/inside.bin"])
        #expect((await runHFS(renamed(first: 200, second: 100))).files.map(\.path) == ["/live.txt", "/old/inside.bin"])
        // Same date, different names: the folder can't be placed, so its file is skipped.
        #expect((await runHFS(renamed(first: 100, second: 100))).files.map(\.path) == ["/live.txt"])
        // Same date and same name and parent: identical copies agree.
        #expect((await runHFS(renamed(first: 100, second: 100, secondName: "old"))).files.map(\.path) == ["/live.txt", "/old/inside.bin"])
    }

    /// The shape behind the flaky real-image test: `rm -r doomed` moves the still-open folder into
    /// the private data folder as "temp<CNID>" before it is freed, and a journal flush in between
    /// keeps that copy, with the same date as the original one.
    @Test func aRemovedFolderParkedInThePrivateDataFolderKeepsItsOriginalPath() async throws {
        func parked(tempDate: UInt64, privateFolderIsLive: Bool = true) -> (HFSImage, Data) {
            var image = HFSImage()
            let inside = Data(image.fill([91]).prefix(2000))
            let privateName = HFSImage.key(2, [0, 0, 0, 0] + Array("HFS+ Private Data".utf16))
            image.catalog([liveRecords(&image) + (privateFolderIsLive ? [privateName + HFSImage.folder(18)] : [])])
            // Older freed leaf: the folder where it was, with its file.
            image.writeNode(tree: HFSImage.catalogBlock, 3, HFSImage.leafNode([
                HFSImage.key(2, "doomed") + HFSImage.folder(40, contentModDate: 50, attributeModDate: 100),
                staleRecord(id: 41, name: "inside.bin", parent: 40, size: 2000, extents: [(91, 1)]),
            ]))
            // Interim copy: parked under the private data folder (CNID 18) as temp40.
            image.writeNode(tree: HFSImage.catalogBlock, 4, HFSImage.leafNode([
                HFSImage.key(18, "temp40") + HFSImage.folder(40, contentModDate: 50, attributeModDate: tempDate),
                staleRecord(id: 41, name: "inside.bin", parent: 40, size: 2000, extents: [(91, 1)]),
            ]))
            return (image, inside)
        }
        // Same date (the usual case, one-second resolution): not ambiguous, the real path wins.
        let (tie, inside) = parked(tempDate: 100)
        let tieBytes = tie.image
        let result = await runHFS(ImageReader(data: tieBytes))
        #expect(result.error == nil)
        #expect(result.files.map(\.path) == ["/live.txt", "/doomed/inside.bin"])
        #expect(try await readBack(result.files.last, from: tieBytes) == inside)
        // A later interim copy must not move the file under the hidden private folder.
        #expect((await runHFS(parked(tempDate: 200).0)).files.map(\.path) == ["/live.txt", "/doomed/inside.bin"])
        // Before the private folder is known, the interim name alone gives the copy away.
        #expect((await runHFS(parked(tempDate: 100, privateFolderIsLive: false).0)).files.map(\.path)
            == ["/live.txt", "/doomed/inside.bin"])
    }

    // MARK: Memory bounds

    @Test func hugeTotalNodesDoesNotAllocateProportionally() async {
        // A catalog claiming 2^31 nodes (8 TiB) on a sparse device; only one leaf is real.
        let (image, _, _) = basicImage()
        var bytes = image.image
        let totalNodes: UInt64 = 1 << 31, allocationBlocks: UInt64 = 1 << 17
        let totalBlocks = totalNodes + (1 << 18)
        let h = 1024
        bytes.putBigEndian(h + 44, totalBlocks, 4)
        bytes.putBigEndian(h + 112, allocationBlocks * 4096, 8); bytes.putBigEndian(h + 112 + 12, allocationBlocks, 4)
        bytes.putBigEndian(h + 112 + 16, totalBlocks - allocationBlocks, 4); bytes.putBigEndian(h + 112 + 20, allocationBlocks, 4)
        bytes.putBigEndian(h + 272, totalNodes * 4096, 8); bytes.putBigEndian(h + 272 + 12, totalNodes, 4)
        bytes.putBigEndian(h + 272 + 20, totalNodes, 4)
        let catalogHeader = HFSImage.catalogBlock * 4096
        bytes.putBigEndian(catalogHeader + 36, totalNodes, 4); bytes.putBigEndian(catalogHeader + 40, totalNodes - 2, 4)
        var limits = HFSPlusLimits(); limits.deletedWorkBudget = 600
        let result = await runHFS(SparseReader(sizeBytes: Int64(totalBlocks) * 4096, regions: [(0, bytes)]), limits: limits)
        #expect(result.error == nil)
        #expect(result.files.map(\.path) == ["/hello.txt", "/docs/inner/nested.txt"])
        // The visited set holds the one leaf read, not a bit per node the header claims.
        #expect(await result.volume.stats.largestNodeSet == 1)
        #expect(await result.volume.stats.deletedBudgetExhausted)
    }

    @Test func overflowExtentsAreFoundThroughIndexNodes() async throws {
        var image = HFSImage()
        image.extentsTree = (block: 50, blocks: 4)
        let a = (0..<10).map { (80 + 2 * $0, 1) }, b = (0..<9).map { (101 + 2 * $0, 1) }
        let expectedA = image.fill(a.map(\.0)).prefix(9 * 4096 + 1)
        let expectedB = image.fill(b.map(\.0)).prefix(9 * 4096)
        image.catalog([HFSImage.root() + [
            image.file(2, "a.bin", id: 30, size: 9 * 4096 + 1, extents: a),
            image.file(2, "b.bin", id: 31, size: 9 * 4096, extents: b),
        ]])
        // Root index node 1 (height 2) points to leaf 2 (file 30) and leaf 3 (file 31).
        image.writeNode(tree: 50, 0, HFSImage.headerNode(totalNodes: 4, root: 1, firstLeaf: 2, lastLeaf: 3, depth: 2))
        image.writeNode(tree: 50, 1, HFSImage.extentsIndexNode([(1, 0, 2), (31, 0, 3)]))
        image.writeNode(tree: 50, 2, HFSImage.leafNode([HFSImage.overflowRecord(30, 8, [(96, 1), (98, 1)])], fLink: 3))
        image.writeNode(tree: 50, 3, HFSImage.leafNode([HFSImage.overflowRecord(31, 8, [(117, 1)])], bLink: 2))
        let bytes = image.image
        let result = await runHFS(ImageReader(data: bytes))
        #expect(result.error == nil)
        #expect(result.files.map(\.path) == ["/a.bin", "/b.bin"])
        #expect(try await readBack(result.files.first, from: bytes) == expectedA)
        #expect(try await readBack(result.files.last, from: bytes) == expectedB)
    }

}

// MARK: - Real images built with hdiutil

/// Builds real HFS+ volumes with `hdiutil` in a temporary directory. The image is attached only
/// while `populate` runs and always detached afterwards; everything is removed at the end.
enum HDIUtil {
    static let path = "/usr/bin/hdiutil"

    /// Why hdiutil can't create and attach an image here (the real-image tests then skip), or
    /// nil when it can.
    static let unavailableReason: String? = {
        guard FileManager.default.isExecutableFile(atPath: path) else { return "\(path) is not executable" }
        do {
            _ = try image(sizeMiB: 4, journaled: false) { _ in }
            return nil
        } catch {
            return "hdiutil could not create and attach a test image: \(error)"
        }
    }()
    static var available: Bool { unavailableReason == nil }

    @discardableResult
    static func run(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output; process.standardError = output
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ScanError.io("hdiutil \(arguments.first ?? "") failed: \(text)") }
        return text
    }

    /// Creates a fresh HFS+ (or journaled HFS+) image, runs `populate` on the mounted volume and
    /// returns the detached image bytes.
    static func image(sizeMiB: Int, journaled: Bool, populate: (URL) throws -> Void) throws -> Data {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("salvage-hfs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = directory.appendingPathComponent("volume.dmg")
        let mount = directory.appendingPathComponent("mnt")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        try run(["create", "-size", "\(sizeMiB)m", "-fs", journaled ? "HFS+J" : "HFS+", "-volname", "SALVAGE", "-layout", "NONE",
                 "-quiet", image.path])
        try run(["attach", "-nobrowse", "-noverify", "-noautofsck", "-mountpoint", mount.path, image.path])
        var populateError: (any Error)? = nil
        do { try populate(mount) } catch { populateError = error }
        try run(["detach", mount.path, "-force"])
        if let populateError { throw populateError }
        return try Data(contentsOf: image)
    }

    static func write(_ bytes: Data, to url: URL) throws { try bytes.write(to: url) }

    /// Copies `source` to `destination` with `ditto --hfsCompression` (decmpfs-compressed).
    static func dittoCompressed(_ source: URL, to destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["--hfsCompression", source.path, destination.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ScanError.io("ditto --hfsCompression failed") }
    }
    static func random(_ count: Int) -> Data { Data((0..<count).map { _ in UInt8.random(in: 0...255) }) }
    static func modificationDate(_ url: URL) throws -> Date? {
        try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    }
}

@Suite("HFS+ real-image availability")
struct HFSPlusRealImageAvailabilityTests {
    /// Says explicitly when the real-image suite below is skipped, and fails the run instead when
    /// SALVAGE_REQUIRE_HDIUTIL=1 (as on a machine that must exercise it).
    @Test func realImageSuiteReportsWhyItIsSkipped() {
        guard let reason = HDIUtil.unavailableReason else { return }
        print("HFS+ real-image tests skipped: \(reason)")
        if ProcessInfo.processInfo.environment["SALVAGE_REQUIRE_HDIUTIL"] == "1" {
            Issue.record("SALVAGE_REQUIRE_HDIUTIL=1 but the HFS+ real-image tests can't run: \(reason)")
        }
    }
}

@Suite("HFS+ scanning of real hdiutil images", .enabled(if: HDIUtil.available, "hdiutil can't create and attach images here"), .serialized)
struct HFSPlusRealImageTests {
    @Test func colonInANameIsShownAsAColon() async throws {
        let log = Data("lunch".utf8), inner = Data("inner".utf8)
        let image = try HDIUtil.image(sizeMiB: 8, journaled: false) { root in
            try HDIUtil.write(log, to: root.appendingPathComponent("12:30.log"))
            try FileManager.default.createDirectory(at: root.appendingPathComponent("a:b"), withIntermediateDirectories: true)
            try HDIUtil.write(inner, to: root.appendingPathComponent("a:b/c:d.txt"))
        }
        // The catalog stores the POSIX ":" as "/".
        #expect(image.range(of: Data("12/30.log".utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] })) != nil)
        let result = await runHFS(ImageReader(data: image))
        #expect(result.error == nil)
        let files = result.files.filter { !$0.name.hasPrefix(".") }
        #expect(Set(files.map(\.path)) == ["/12:30.log", "/a:b/c:d.txt"])
        #expect(files.first { $0.path == "/12:30.log" }?.name == "12:30.log")
        #expect(try await readBack(files.first { $0.path == "/12:30.log" }, from: image) == log)
        #expect(try await readBack(files.first { $0.path == "/a:b/c:d.txt" }, from: image) == inner)
    }

    @Test func decmpfsCompressedFileIsUnmappedWithItsRealSize() async throws {
        let text = Data(String(repeating: "salvage compresses well. ", count: 8000).utf8)
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("salvage-ditto-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let source = scratch.appendingPathComponent("source.txt")
        try HDIUtil.write(text, to: source)
        var compressed = false
        let image = try HDIUtil.image(sizeMiB: 8, journaled: true) { root in
            let destination = root.appendingPathComponent("comp.txt")
            try HDIUtil.dittoCompressed(source, to: destination)
            let values = try destination.resourceValues(forKeys: [.fileAllocatedSizeKey])
            compressed = (values.fileAllocatedSize ?? Int.max) < text.count
            try HDIUtil.write(Data("plain".utf8), to: root.appendingPathComponent("plain.txt"))
        }
        #expect(compressed, "ditto did not compress the file")
        let result = await runHFS(ImageReader(data: image))
        #expect(result.error == nil)
        let file = result.files.first { $0.path == "/comp.txt" }
        #expect(file?.sizeBytes == Int64(text.count))
        #expect(file?.content == .unmapped)
        #expect(await result.volume.stats.compressedFiles >= 1)
        #expect(try await readBack(result.files.first { $0.path == "/plain.txt" }, from: image) == Data("plain".utf8))
    }

    @Test func liveFilesReadBackByteIdentical() async throws {
        let hello = Data("hello hfs".utf8), nested = HDIUtil.random(5000)
        var mtime: Date? = nil
        let image = try HDIUtil.image(sizeMiB: 16, journaled: false) { root in
            try HDIUtil.write(hello, to: root.appendingPathComponent("hello.txt"))
            let inner = root.appendingPathComponent("docs/inner")
            try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
            try HDIUtil.write(nested, to: inner.appendingPathComponent("nested.bin"))
            try FileManager.default.linkItem(at: root.appendingPathComponent("hello.txt"), to: root.appendingPathComponent("docs/link.txt"))
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("sym"), withDestinationURL: URL(fileURLWithPath: "hello.txt"))
            mtime = try HDIUtil.modificationDate(inner.appendingPathComponent("nested.bin"))
        }
        let events = await scan(image)
        #expect(events.last == .completed)
        let files = found(events).filter { !$0.name.hasPrefix(".") }
        #expect(Set(files.map(\.path)) == ["/hello.txt", "/docs/inner/nested.bin", "/docs/link.txt"])
        let big = files.first { $0.path == "/docs/inner/nested.bin" }
        #expect(big?.sizeBytes == 5000)
        #expect(try await readBack(big, from: image) == nested)
        #expect(try await readBack(files.first { $0.path == "/hello.txt" }, from: image) == hello)
        #expect(try await readBack(files.first { $0.path == "/docs/link.txt" }, from: image) == hello)
        if let mtime, let modified = big?.modified {
            #expect(abs(modified.timeIntervalSince(mtime)) < 1)
        } else { Issue.record("missing modification time") }
        #expect(files.allSatisfy { !$0.isDeleted && $0.sourceMetadata.filesystem == .hfsPlus })
    }

    @Test func fragmentedFileWithMoreThanEightExtentsReadsBack() async throws {
        // Fill the volume with 1 MiB files separated by single blocks, free the single blocks, and
        // write a 12-block file into the holes: eight extents in the catalog, four in overflow.
        let frag = HDIUtil.random(12 * 4096)
        let image = try HDIUtil.image(sizeMiB: 16, journaled: true) { root in
            let big = Data(repeating: 0x5A, count: 256 * 4096), small = Data(repeating: 0xA5, count: 4096)
            for index in 0..<12 {
                try HDIUtil.write(big, to: root.appendingPathComponent("big\(index).bin"))
                try HDIUtil.write(small, to: root.appendingPathComponent("small\(index).bin"))
            }
            // Consume the remaining contiguous space (this write stops at ENOSPC).
            let filler = FileHandle(forWritingAtPath: {
                let path = root.appendingPathComponent("filler.bin").path
                FileManager.default.createFile(atPath: path, contents: nil)
                return path
            }())
            let chunk = Data(repeating: 0x33, count: 64 * 1024)
            while let filler, (try? filler.write(contentsOf: chunk)) != nil {}
            try? filler?.close()
            for index in 0..<12 { try FileManager.default.removeItem(at: root.appendingPathComponent("small\(index).bin")) }
            try HDIUtil.write(frag, to: root.appendingPathComponent("frag.bin"))
        }
        let result = await runHFS(ImageReader(data: image))
        #expect(result.error == nil)
        let file = result.files.first { $0.path == "/frag.bin" }
        #expect(file?.sizeBytes == Int64(frag.count))
        #expect(file?.sourceMetadata.contiguous == false)
        if case .runs(let runs)? = file?.content { #expect(runs.count > 8) } else { Issue.record("frag.bin has no runs") }
        #expect(try await readBack(file, from: image) == frag)
    }

    @Test func deletedFilesAreRecoveredFromTheJournalUnlessTheirBlocksWereReused() async throws {
        let last = HDIUtil.random(5000), gone = HDIUtil.random(3000), inside = HDIUtil.random(2000), reused = HDIUtil.random(8 * 4096)
        let image = try HDIUtil.image(sizeMiB: 16, journaled: true) { root in
            try FileManager.default.createDirectory(at: root.appendingPathComponent("docs"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("doomed"), withIntermediateDirectories: true)
            try HDIUtil.write(Data("keep".utf8), to: root.appendingPathComponent("keep.txt"))
            try HDIUtil.write(last, to: root.appendingPathComponent("zz_last.bin"))
            try HDIUtil.write(gone, to: root.appendingPathComponent("docs/gone.bin"))
            try HDIUtil.write(inside, to: root.appendingPathComponent("doomed/inside.bin"))
            try HDIUtil.write(reused, to: root.appendingPathComponent("reused.bin"))
            try FileManager.default.removeItem(at: root.appendingPathComponent("reused.bin"))
            // Fill every free block so reused.bin's blocks now belong to filler.bin.
            let path = root.appendingPathComponent("filler.bin").path
            FileManager.default.createFile(atPath: path, contents: nil)
            let filler = FileHandle(forWritingAtPath: path)
            let chunk = Data(repeating: 0x77, count: 64 * 1024)
            while let filler, (try? filler.write(contentsOf: chunk)) != nil {}
            try? filler?.close()
            try FileManager.default.removeItem(at: root.appendingPathComponent("zz_last.bin"))
            try FileManager.default.removeItem(at: root.appendingPathComponent("docs/gone.bin"))
            try FileManager.default.removeItem(at: root.appendingPathComponent("doomed"))
            // Removing the still-open folder parks it in the private data folder as "temp<CNID>"
            // first. Without a flush here, whether the journal keeps that copy depends on timing
            // (it made this test flaky under load); with one, it always does, so the test always
            // covers that shape.
            sync()
        }
        let result = await runHFS(ImageReader(data: image))
        #expect(result.error == nil)
        #expect(await result.volume.stats.journal == "scanned")
        let deleted = result.files.filter(\.isDeleted)
        #expect(Set(deleted.map(\.path)) == ["/zz_last.bin", "/docs/gone.bin", "/doomed/inside.bin"])
        #expect(try await readBack(deleted.first { $0.name == "zz_last.bin" }, from: image) == last)
        #expect(try await readBack(deleted.first { $0.name == "gone.bin" }, from: image) == gone)
        #expect(try await readBack(deleted.first { $0.name == "inside.bin" }, from: image) == inside)
        #expect(!result.files.contains { $0.name == "reused.bin" })
        #expect(result.files.contains { $0.path == "/keep.txt" && !$0.isDeleted })
        #expect(result.files.contains { $0.path == "/filler.bin" && !$0.isDeleted })
    }
}
