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
        Self.fork(&result, at: h + 192, size: 2 * UInt64(Self.blockSize), extents: [(Self.extentsBlock, 2)])
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
        let leaf = records.map { fileID, startBlock, extents -> Data in
            var record = Data(repeating: 0, count: 12 + 64)
            record.putBigEndian(0, 10, 2); record.putBigEndian(4, UInt64(fileID), 4); record.putBigEndian(8, UInt64(startBlock), 4)
            for (index, extent) in extents.enumerated() {
                record.putBigEndian(12 + index * 8, UInt64(extent.0), 4); record.putBigEndian(16 + index * 8, UInt64(extent.1), 4)
            }
            return record
        }
        writeNode(tree: Self.extentsBlock, 1, Self.leafNode(leaf))
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
    static func folder(_ id: UInt32) -> Data {
        var record = Data(repeating: 0, count: 88)
        record.putBigEndian(0, 1, 2); record.putBigEndian(8, UInt64(id), 4); record.putBigEndian(42, 0o40755, 2)
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

    /// Writes a journal whose buffer holds `transactions`, each a list of (sector number, bytes).
    /// `dirty` leaves `start != end` as an unreplayed journal would.
    mutating func journal(_ transactions: [[(Int64, Data)]], bigEndian: Bool = false, dirty: Bool = false) {
        hasJournal = true
        let info = Self.journalInfoBlock * Self.blockSize
        let base = Self.journalBlock * Self.blockSize, size = Self.journalBlocks * Self.blockSize
        data.putBigEndian(info, 1, 4); data.putBigEndian(info + 36, UInt64(base), 8); data.putBigEndian(info + 44, UInt64(size), 8)
        func put(_ offset: Int, _ value: UInt64, _ width: Int) {
            if bigEndian { data.putBigEndian(offset, value, width) } else { data.put(offset, value, width) }
        }
        let blhdrSize = 4096, sectorSize = 512
        var position = sectorSize
        for (sequence, blocks) in transactions.enumerated() {
            let header = base + position
            put(header, UInt64(blhdrSize / 16 - 1), 2); put(header + 2, UInt64(blocks.count + 1), 2)
            put(header + 4, UInt64(blhdrSize + blocks.reduce(0) { $0 + $1.1.count }), 4)
            put(header + 16 + 12, UInt64(sequence + 1), 4)
            var cursor = header + blhdrSize
            for (index, block) in blocks.enumerated() {
                put(header + 16 + (index + 1) * 16, UInt64(bitPattern: block.0), 8)
                put(header + 16 + (index + 1) * 16 + 8, UInt64(block.1.count), 4)
                data.replaceSubrange(cursor..<cursor + block.1.count, with: block.1)
                cursor += block.1.count
            }
            let checksum = Self.journalChecksum(data.subdata(in: header..<header + 32))
            put(header + 8, UInt64(checksum), 4)
            position = cursor - base
        }
        put(base, 0x4A4E_4C78, 4); put(base + 4, 0x1234_5678, 4)
        put(base + 8, UInt64(dirty ? sectorSize : position), 8); put(base + 16, UInt64(position), 8)
        put(base + 24, UInt64(size), 8); put(base + 32, UInt64(blhdrSize), 4); put(base + 40, UInt64(sectorSize), 4)
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
        // "café.txt" stored decomposed (e + U+0301), and a name keeping its catalog colon.
        let decomposed: [UInt16] = Array("caf".utf16) + [0x65, 0x0301] + Array(".txt".utf16)
        image.catalog([HFSImage.root() + [
            HFSImage.key(2, decomposed) + HFSImage.file(30, size: 0, extents: []),
            HFSImage.key(2, "a:b") + HFSImage.file(31, size: 0, extents: []),
        ]])
        let result = await runHFS(image)
        #expect(result.error == nil)
        #expect(result.files.map(\.name) == ["café.txt", "a:b"])
        #expect(result.files.map(\.path) == ["/café.txt", "/a:b"])
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

    @Test func overlapDetectionFlagsEveryOverlappingOwner() {
        let claims = [HFSPlusClaim(start: 0, end: 10, owner: 0), HFSPlusClaim(start: 2, end: 3, owner: 1),
                      HFSPlusClaim(start: 5, end: 20, owner: 2), HFSPlusClaim(start: 20, end: 21, owner: 3),
                      HFSPlusClaim(start: 30, end: 31, owner: 4), HFSPlusClaim(start: 30, end: 32, owner: 4)]
        #expect(HFSPlusVolume.overlappingOwners(claims, owners: 5) == [true, true, true, false, true])
    }

    @Test func helpersMatchTheSpecification() {
        #expect(HFSPlus.date(0) == nil)
        #expect(HFSPlus.date(2_082_844_800) == Date(timeIntervalSince1970: 0))
        #expect(HFSPlus.indirectNodeNumber(Array("iNode22".utf16)) == 22)
        #expect(HFSPlus.indirectNodeNumber(Array("iNode".utf16)) == nil)
        #expect(HFSPlus.indirectNodeNumber(Array("iNodex".utf16)) == nil)
        #expect(HFSPlus.name([0xD800]) == nil)
        #expect(HFSPlus.name(Array("a/b".utf16)) == nil)
        // TN1150's block list checksum, as the inspected real journal confirmed.
        #expect(HFSPlusJournal.checksum(Data()) == 0xFFFF_FFFF)
    }
}

// MARK: - Real images built with hdiutil

/// Builds real HFS+ volumes with `hdiutil` in a temporary directory. The image is attached only
/// while `populate` runs and always detached afterwards; everything is removed at the end.
enum HDIUtil {
    static let path = "/usr/bin/hdiutil"

    /// True when hdiutil can create and attach an image here; otherwise the real-image tests skip.
    static let available: Bool = {
        guard FileManager.default.isExecutableFile(atPath: path) else { return false }
        return (try? image(sizeMiB: 4, journaled: false) { _ in }) != nil
    }()

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
    static func random(_ count: Int) -> Data { Data((0..<count).map { _ in UInt8.random(in: 0...255) }) }
    static func modificationDate(_ url: URL) throws -> Date? {
        try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    }
}

@Suite("HFS+ scanning of real hdiutil images", .enabled(if: HDIUtil.available), .serialized)
struct HFSPlusRealImageTests {
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
