import Foundation
import Testing
@testable import SalvageCore

/// Builds tiny ext2/3/4 images (1 KiB blocks by default). Block 1 (or 0 for larger blocks) holds
/// the superblock, the next block the group descriptors, blocks 3-7 the bitmaps, 8 onward the
/// inode tables and data starts at 32.
struct EXTImage {
    let blockSize: Int
    var data: Data
    let inodeSize: Int, inodesPerGroup: Int, blocksPerGroup: Int, groups: Int, descriptorSize: Int
    let firstDataBlock: Int
    var incompat: UInt64
    var roCompat: UInt64 = 0

    init(ext4: Bool = false, wide: Bool = false, inodeSize: Int? = nil, blockSize: Int = 1024, inodesPerGroup: Int = 16) {
        self.blockSize = blockSize
        self.inodeSize = inodeSize ?? (ext4 ? 256 : 128)
        self.inodesPerGroup = inodesPerGroup
        firstDataBlock = blockSize == 1024 ? 1 : 0
        groups = wide ? 2 : 1
        blocksPerGroup = wide ? 256 : 8192
        let blocks = wide ? 513 : 512
        descriptorSize = wide ? 64 : 32
        incompat = 0x2 | (ext4 ? 0x40 : 0) | (wide ? 0x80 : 0)
        data = Data(repeating: 0, count: blocks * blockSize)
        let sb = 1024
        data.put(sb, UInt64(inodesPerGroup * groups), 4); data.put(sb + 4, UInt64(blocks), 4)
        data.put(sb + 20, UInt64(firstDataBlock), 4); data.put(sb + 24, UInt64((blockSize / 1024).trailingZeroBitCount), 4)
        data.put(sb + 32, UInt64(blocksPerGroup), 4)
        data.put(sb + 40, UInt64(inodesPerGroup), 4); data.put(sb + 56, 0xef53, 2); data.put(sb + 76, 1, 4)
        data.put(sb + 84, 11, 4); data.put(sb + 88, UInt64(self.inodeSize), 2)
        if wide { data.put(sb + 254, 64, 2) }
        for group in 0..<groups {
            let d = (firstDataBlock + 1) * blockSize + group * descriptorSize
            data.put(d, UInt64(3 + group), 4); data.put(d + 4, UInt64(5 + group), 4)
            data.put(d + 8, UInt64(inodeTable(group)), 4)
        }
        for block in firstDataBlock..<32 { mark(block: block) }
        for inode in 1...11 { mark(inode: inode) }
    }
    func inodeTable(_ group: Int) -> Int { 8 + group * ((inodesPerGroup * inodeSize + blockSize - 1) / blockSize) }
    func inodeOffset(_ n: Int) -> Int {
        let group = (n - 1) / inodesPerGroup
        return inodeTable(group) * blockSize + (n - 1) % inodesPerGroup * inodeSize
    }
    var image: Data {
        var result = data
        result.put(1024 + 96, incompat, 4); result.put(1024 + 100, roCompat, 4)
        if roCompat & 0x400 != 0 {
            result[1024 + 373] = 1
            result.put(1024 + 1020, UInt64(crc32cUpdate(0xffffffff, result.subdata(in: 1024..<2044))), 4)
        }
        return result
    }
    mutating func mark(block: Int, used: Bool = true) {
        let relative = block - firstDataBlock, group = relative / blocksPerGroup, bit = relative % blocksPerGroup
        let byte = (3 + group) * blockSize + bit / 8
        if used { data[byte] |= 1 << (bit % 8) } else { data[byte] &= ~(1 << (bit % 8)) }
    }
    mutating func mark(inode: Int, used: Bool = true) {
        let group = (inode - 1) / inodesPerGroup, bit = (inode - 1) % inodesPerGroup
        let byte = (5 + group) * blockSize + bit / 8
        if used { data[byte] |= 1 << (bit % 8) } else { data[byte] &= ~(1 << (bit % 8)) }
    }
    /// Writes an inode; live inodes and their blocks are marked used in the bitmaps.
    mutating func inode(_ n: Int, directory: Bool = false, size: Int, mtime: UInt32 = 1_700_000_000,
                        links: Int = 1, dtime: UInt32 = 0, flags: UInt32 = 0, blocks: Data, used: [Int] = [],
                        mtimeExtra: UInt32? = nil) {
        let o = inodeOffset(n)
        data.put(o, directory ? 0x41ed : 0x81a4, 2); data.put(o + 4, UInt64(size & 0xffffffff), 4)
        data.put(o + 108, UInt64(size >> 32), 4)
        data.put(o + 16, UInt64(mtime), 4); data.put(o + 20, UInt64(dtime), 4)
        data.put(o + 26, UInt64(links), 2); data.put(o + 32, UInt64(flags), 4)
        data.replaceSubrange(o + 40..<o + 100, with: blocks)
        if inodeSize > 128 { data.put(o + 128, 32, 2); data.put(o + 136, UInt64(mtimeExtra ?? 0), 4) }
        let live = links > 0 && dtime == 0
        mark(inode: n, used: live)
        for block in used { mark(block: block, used: live) }
    }
    static func blockMap(_ direct: [Int], indirect: Int = 0, double: Int = 0) -> Data {
        var area = Data(repeating: 0, count: 60)
        for (index, block) in direct.enumerated() { area.put(index * 4, UInt64(block), 4) }
        area.put(48, UInt64(indirect), 4); area.put(52, UInt64(double), 4)
        return area
    }
    static func extentNode(_ extents: [(UInt32, UInt16, Int)], size: Int = 60) -> Data {
        var node = Data(repeating: 0, count: size)
        node.put(0, 0xf30a, 2); node.put(2, UInt64(extents.count), 2); node.put(4, UInt64((size - 12) / 12), 2)
        for (index, (logical, length, start)) in extents.enumerated() {
            let p = 12 + index * 12
            node.put(p, UInt64(logical), 4); node.put(p + 4, UInt64(length), 2)
            node.put(p + 6, UInt64(start >> 32), 2); node.put(p + 8, UInt64(start & 0xffffffff), 4)
        }
        return node
    }
    static func extentIndex(_ children: [(UInt32, Int)], depth: Int, size: Int = 60) -> Data {
        var node = Data(repeating: 0, count: size)
        node.put(0, 0xf30a, 2); node.put(2, UInt64(children.count), 2); node.put(4, UInt64((size - 12) / 12), 2)
        node.put(6, UInt64(depth), 2)
        for (index, (logical, child)) in children.enumerated() {
            let p = 12 + index * 12
            node.put(p, UInt64(logical), 4); node.put(p + 4, UInt64(child & 0xffffffff), 4); node.put(p + 8, UInt64(child >> 32), 2)
        }
        return node
    }
    /// Writes one dirent; returns the offset just past its real length.
    @discardableResult
    mutating func dirent(at offset: Int, inode: Int, recordLength: Int, name: String, type: UInt8) -> Int {
        dirent(at: offset, inode: inode, recordLength: recordLength, nameBytes: Data(name.utf8), type: type)
    }
    @discardableResult
    mutating func dirent(at offset: Int, inode: Int, recordLength: Int, nameBytes: Data, type: UInt8) -> Int {
        data.put(offset, UInt64(inode), 4); data.put(offset + 4, UInt64(recordLength), 2)
        data.put(offset + 6, UInt64(nameBytes.count), 1); data.put(offset + 7, UInt64(type), 1)
        data.replaceSubrange(offset + 8..<offset + 8 + nameBytes.count, with: nameBytes)
        return offset + (8 + nameBytes.count + 3) / 4 * 4
    }
    /// Writes ".", ".." and the given entries; the last entry's record spans the block.
    mutating func directory(_ block: Int, this: Int, parent: Int, _ entries: [(Int, String, UInt8)]) {
        var p = block * blockSize
        let all = [(this, ".", UInt8(2)), (parent, "..", UInt8(2))] + entries
        for (index, (inode, name, type)) in all.enumerated() {
            let real = (8 + name.utf8.count + 3) / 4 * 4
            let length = index == all.count - 1 ? (block + 1) * blockSize - p : real
            dirent(at: p, inode: inode, recordLength: length, name: name, type: type)
            p += length
        }
    }
    mutating func content(_ block: Int, _ text: String) { data.text(block * blockSize, text) }
    /// Sets a group descriptor's bg_flags.
    mutating func groupFlags(_ group: Int, _ flags: UInt16) {
        data.put((firstDataBlock + 1) * blockSize + group * descriptorSize + 18, UInt64(flags), 2)
    }
}

/// Serves a huge virtual device that is zero except for the given regions.
struct SparseReader: BlockReader {
    let sizeBytes: Int64
    let regions: [(offset: Int64, bytes: Data)]
    func read(at offset: Int64, count: Int) async throws -> Data {
        guard offset >= 0, count >= 0, Int64(count) <= sizeBytes - offset else { throw ScanError.io("Out of bounds") }
        var out = Data(repeating: 0, count: count)
        for region in regions {
            let low = max(region.offset, offset), high = min(region.offset + Int64(region.bytes.count), offset + Int64(count))
            if low < high {
                out.replaceSubrange(Int(low - offset)..<Int(high - offset),
                                    with: region.bytes.subdata(in: Int(low - region.offset)..<Int(high - region.offset)))
            }
        }
        return out
    }
}

actor FileCollector {
    var files: [RecoveredFile] = []
    func add(_ file: RecoveredFile) { files.append(file) }
}

/// Runs `EXTVolume` directly so tests can lower limits and read its counters.
func runEXT(_ reader: any BlockReader, limits: EXTLimits = EXTLimits()) async
    -> (files: [RecoveredFile], error: (any Error)?, volume: EXTVolume) {
    let collector = FileCollector()
    let volume = EXTVolume(reader: reader, extent: VolumeExtent(offset: 0, length: reader.sizeBytes, format: .ext)) {
        await collector.add($0)
    }
    await volume.setLimits(limits)
    var failure: (any Error)? = nil
    do { try await volume.scan() } catch { failure = error }
    return (await collector.files, failure, volume)
}
func runEXT(_ image: EXTImage, limits: EXTLimits = EXTLimits()) async
    -> (files: [RecoveredFile], error: (any Error)?, volume: EXTVolume) {
    await runEXT(ImageReader(data: image.image), limits: limits)
}
func isMalformed(_ error: (any Error)?) -> Bool {
    if case .malformed? = error as? ScanError { true } else { false }
}

/// ext2 volume: /hello.txt (1 block) and /docs/big.bin (12 direct blocks plus an indirect block).
func ext2Image() -> EXTImage {
    var image = EXTImage()
    image.inode(2, directory: true, size: 1024, links: 3, blocks: EXTImage.blockMap([32]), used: [32])
    image.directory(32, this: 2, parent: 2, [(12, "hello.txt", 1), (13, "docs", 2)])
    image.inode(12, size: 5, mtime: 1_600_000_000, blocks: EXTImage.blockMap([40]), used: [40])
    image.content(40, "hello")
    image.inode(13, directory: true, size: 1024, links: 2, blocks: EXTImage.blockMap([33]), used: [33])
    image.directory(33, this: 13, parent: 2, [(14, "big.bin", 1)])
    let direct = Array(50..<62)
    image.inode(14, size: 13 * 1024 + 10, blocks: EXTImage.blockMap(direct, indirect: 62),
                used: direct + [62, 63, 64])
    image.data.put(62 * 1024, 63, 4); image.data.put(62 * 1024 + 4, 64, 4)
    return image
}

private func files(_ events: [ScanEvent]) -> [RecoveredFile] {
    events.compactMap { if case .found(let file) = $0 { file } else { nil } }
}

@Suite("EXT2/3/4 scanning")
struct EXTVolumeTests {
    @Test func ext2LiveFilesWithIndirectBlockMap() async {
        let image = ext2Image()
        let events = await scan(image.image)
        #expect(events.last == .completed)
        let found = files(events)
        #expect(found.map(\.path) == ["/hello.txt", "/docs/big.bin"])
        #expect(found.map(\.sizeBytes) == [5, 13 * 1024 + 10])
        #expect(found[0].modified == Date(timeIntervalSince1970: 1_600_000_000))
        #expect(found.allSatisfy { !$0.isDeleted && $0.sourceMetadata.filesystem == .ext })
        #expect(found[0].sourceMetadata.allocationStart == 12)
        #expect(found[0].sourceMetadata.recordOffset == Int64(image.inodeOffset(12)))
        #expect(found[0].sourceMetadata.rawRecord.count == 128 + 8 + "hello.txt".utf8.count)
        #expect(found[0].sourceMetadata.contiguous)
        #expect(!found[1].sourceMetadata.contiguous)
    }

    @Test func ext4ExtentsDepthZeroAndOneWithNanosecondTimes() async {
        var image = EXTImage(ext4: true)
        image.inode(2, directory: true, size: 1024, links: 2, flags: 0x80000,
                    blocks: EXTImage.extentNode([(0, 1, 32)]), used: [32])
        image.directory(32, this: 2, parent: 2, [(12, "flat.txt", 1), (13, "tree.bin", 1)])
        // Epoch bits 1 add 2^32 seconds; 500 ns in the upper 30 bits.
        image.inode(12, size: 2000, mtime: 10, flags: 0x80000, blocks: EXTImage.extentNode([(0, 2, 60)]),
                    used: [60, 61], mtimeExtra: 1 | 500 << 2)
        image.inode(13, size: 3 * 1024, flags: 0x80000, blocks: EXTImage.extentIndex([(0, 70)], depth: 1),
                    used: [70, 71, 80, 81])
        image.data.replaceSubrange(70 * 1024..<71 * 1024, with: EXTImage.extentNode([(0, 1, 71), (1, 2, 80)], size: 1024))
        let events = await scan(image.image)
        #expect(events.last == .completed)
        let found = files(events)
        #expect(found.map(\.path) == ["/flat.txt", "/tree.bin"])
        #expect(found.map(\.sizeBytes) == [2000, 3072])
        #expect(found[0].sourceMetadata.contiguous && !found[1].sourceMetadata.contiguous)
        let expected = Double(Int64(1) << 32 + 10) + 500e-9
        #expect(abs((found[0].modified?.timeIntervalSince1970 ?? 0) - expected) < 1e-5)
    }

    @Test func sixtyFourBitDescriptorsLocateSecondGroup() async {
        var image = EXTImage(ext4: true, wide: true)
        image.inode(2, directory: true, size: 1024, links: 2, flags: 0x80000,
                    blocks: EXTImage.extentNode([(0, 1, 32)]), used: [32])
        image.directory(32, this: 2, parent: 2, [(17, "far.txt", 1)])
        // Inode 17 is the first inode of group 1, found only through the 64-byte descriptor.
        image.inode(17, size: 4, flags: 0x80000, blocks: EXTImage.extentNode([(0, 1, 300)]), used: [300])
        let events = await scan(image.image)
        #expect(events.last == .completed)
        #expect(files(events).map(\.path) == ["/far.txt"])
        #expect(files(events).first?.sourceMetadata.recordOffset == Int64(image.inodeOffset(17)))
    }

    /// Root holds live.txt whose record spans the block; a removed gone.txt survives in the gap.
    func deletedImage(ext4: Bool = false, stale: [(Int, String)] = [(13, "gone.txt")]) -> EXTImage {
        var image = EXTImage(ext4: ext4)
        let rootFlags: UInt32 = ext4 ? 0x80000 : 0
        image.inode(2, directory: true, size: 1024, links: 2, flags: rootFlags,
                    blocks: ext4 ? EXTImage.extentNode([(0, 1, 32)]) : EXTImage.blockMap([32]), used: [32])
        var p = 32 * 1024
        p = image.dirent(at: p, inode: 2, recordLength: 12, name: ".", type: 2)
        p = image.dirent(at: p, inode: 2, recordLength: 12, name: "..", type: 2)
        var gap = image.dirent(at: p, inode: 12, recordLength: 33 * 1024 - p, name: "live.txt", type: 1)
        for (index, (inode, name)) in stale.enumerated() {
            let real = (8 + name.utf8.count + 3) / 4 * 4
            gap = image.dirent(at: gap, inode: inode, recordLength: index == stale.count - 1 ? 33 * 1024 - gap : real,
                               name: name, type: 1)
        }
        image.inode(12, size: 4, flags: rootFlags, blocks: ext4 ? EXTImage.extentNode([(0, 1, 40)]) : EXTImage.blockMap([40]),
                    used: [40])
        image.inode(13, size: 600, mtime: 1_650_000_000, links: 0, dtime: 1_700_000_000,
                    blocks: EXTImage.blockMap([90]), used: [90])
        image.content(90, "recover me")
        return image
    }

    @Test func deletedEntryWithIntactPointersIsRecovered() async {
        let image = deletedImage()
        let events = await scan(image.image)
        #expect(events.last == .completed)
        let found = files(events)
        #expect(found.map(\.path) == ["/live.txt", "/gone.txt"])
        let gone = found[1]
        #expect(gone.isDeleted && !found[0].isDeleted)
        #expect(gone.name == "gone.txt" && gone.sizeBytes == 600)
        #expect(gone.modified == Date(timeIntervalSince1970: 1_650_000_000))
        #expect(gone.sourceMetadata.allocationStart == 13)
    }

    @Test func deletedCandidatesThatCannotBeTrustedAreSkipped() async {
        // ext4 typical: the extent header is emptied on delete.
        var zeroed = deletedImage(ext4: true)
        zeroed.inode(13, size: 600, links: 0, dtime: 1, flags: 0x80000, blocks: EXTImage.extentNode([]))
        // Pointers intact, but the block has since been reallocated.
        var reallocated = deletedImage(); reallocated.mark(block: 90)
        // The inode was reused by a live file elsewhere.
        var reused = deletedImage()
        reused.inode(13, size: 10, blocks: EXTImage.blockMap([90]), used: [90])
        // Size zero, and a pointer outside the volume.
        var empty = deletedImage(); empty.inode(13, size: 0, links: 0, dtime: 1, blocks: EXTImage.blockMap([90]))
        var outside = deletedImage(); outside.inode(13, size: 600, links: 0, dtime: 1, blocks: EXTImage.blockMap([9999]))
        for image in [zeroed, reallocated, reused, empty, outside] {
            let events = await scan(image.image)
            #expect(events.last == .completed)
            #expect(files(events).allSatisfy { !$0.isDeleted })
            #expect(files(events).contains { $0.path == "/live.txt" })
        }
    }

    @Test(arguments: [UInt64(0x8000), 0x10000, 0x20000, 0x10, 0x8])
    func unsupportedIncompatFeaturesAreRefused(_ feature: UInt64) async {
        var image = ext2Image(); image.incompat |= feature
        let events = await scan(image.image)
        #expect(events.contains(.error(.unsupportedFilesystem)))
        #expect(files(events).isEmpty && !events.contains(.completed))
    }

    @Test func needsRecoveryIsScannedReadOnly() async {
        var image = ext2Image(); image.incompat |= 0x4
        #expect((await scan(image.image)).last == .completed)
    }

    @Test func metadataChecksumIsVerified() async {
        var image = ext2Image(); image.roCompat |= 0x400
        #expect((await scan(image.image)).last == .completed)
        var corrupt = image.image; corrupt[1024 + 1020] ^= 1
        let events = await scan(corrupt)
        #expect(events.contains { if case .error(.malformed(let reason)) = $0 { reason.contains("checksum") } else { false } })
        #expect(files(events).isEmpty)
    }

    @Test func crc32cMatchesStandardCheckValue() {
        #expect(crc32c(Data("123456789".utf8)) == 0xe3069283)
    }

    @Test func blockMapCycleTerminatesAsMalformed() async {
        var image = ext2Image()
        // A double-indirect block that points at itself.
        image.inode(12, size: 5, blocks: EXTImage.blockMap([40], double: 100), used: [40, 100])
        image.data.put(100 * 1024, 100, 4)
        let events = await scan(image.image)
        #expect(events.contains { if case .error(.malformed) = $0 { true } else { false } })
        #expect(!events.contains(.completed))
    }

    @Test func extentCyclesAndOutOfRangeBlocksAreMalformed() async {
        func base() -> EXTImage {
            var image = EXTImage(ext4: true)
            image.inode(2, directory: true, size: 1024, links: 2, flags: 0x80000,
                        blocks: EXTImage.extentNode([(0, 1, 32)]), used: [32])
            image.directory(32, this: 2, parent: 2, [(12, "file", 1)])
            return image
        }
        var cycle = base()
        cycle.inode(12, size: 1024, flags: 0x80000, blocks: EXTImage.extentIndex([(0, 70)], depth: 2), used: [70])
        cycle.data.replaceSubrange(70 * 1024..<71 * 1024, with: EXTImage.extentIndex([(0, 70)], depth: 1, size: 1024))
        var outside = base()
        outside.inode(12, size: 1024, flags: 0x80000, blocks: EXTImage.extentNode([(0, 4, 510)]))
        var badMagic = base()
        badMagic.inode(12, size: 1024, flags: 0x80000, blocks: Data(repeating: 0, count: 60))
        var disordered = base()
        disordered.inode(12, size: 1024, flags: 0x80000, blocks: EXTImage.extentNode([(5, 1, 60), (2, 1, 61)]))
        for image in [cycle, outside, badMagic, disordered] {
            let events = await scan(image.image)
            #expect(events.contains { if case .error(.malformed) = $0 { true } else { false } })
            #expect(!events.contains(.completed))
        }
    }

    @Test func uninitializedExtentsAreAccepted() async {
        var image = EXTImage(ext4: true)
        image.inode(2, directory: true, size: 1024, links: 2, flags: 0x80000,
                    blocks: EXTImage.extentNode([(0, 1, 32)]), used: [32])
        image.directory(32, this: 2, parent: 2, [(12, "prealloc", 1)])
        image.inode(12, size: 2048, flags: 0x80000, blocks: EXTImage.extentNode([(0, 32768 + 2, 60)]), used: [60, 61])
        let events = await scan(image.image)
        #expect(events.last == .completed)
        #expect(files(events).map(\.sizeBytes) == [2048])
    }

    @Test func htreeDirectoryIsReadLinearlyWithoutMiningIndexData() async {
        var image = EXTImage()
        image.inode(2, directory: true, size: 2048, links: 2, flags: 0x1000, blocks: EXTImage.blockMap([32, 33]),
                    used: [32, 33])
        // dx_root: "." then ".." spanning the block, followed by dx_root_info and dx entries.
        let root = 32 * 1024
        image.dirent(at: root, inode: 2, recordLength: 12, name: ".", type: 2)
        image.dirent(at: root + 12, inode: 2, recordLength: 1012, name: "..", type: 2)
        image.data.put(root + 24, 0, 4); image.data[root + 28] = 1; image.data[root + 29] = 8
        image.data.put(root + 32, 1, 2); image.data.put(root + 34, 1, 2); image.data.put(root + 36, 1, 4)
        // Bytes inside the index area that would look like a recoverable removed entry.
        image.dirent(at: root + 64, inode: 13, recordLength: 16, name: "ghost", type: 1)
        image.inode(13, size: 10, links: 0, dtime: 1, blocks: EXTImage.blockMap([90]))
        image.directory(33, this: 2, parent: 2, [(12, "leaf.txt", 1)])
        // The leaf block's "." and ".." are ordinary entries here; only the root block is dx_root.
        image.inode(12, size: 3, blocks: EXTImage.blockMap([40]), used: [40])
        let events = await scan(image.image)
        #expect(events.last == .completed)
        #expect(files(events).map(\.path) == ["/leaf.txt"])
    }

    @Test func extPartitionRoutesThroughUnifiedScan() async {
        let volume = ext2Image().image
        var image = Data(repeating: 0, count: 512) + volume
        image.put(446 + 4, 0x83, 1); image.put(446 + 8, 1, 4); image.put(446 + 12, UInt64(volume.count / 512), 4)
        image.put(510, 0xaa55, 2)
        let events = await scan(image)
        #expect(events.last == .completed)
        let found = files(events)
        #expect(found.map(\.path) == ["/hello.txt", "/docs/big.bin"])
        #expect(found.allSatisfy { $0.sourceMetadata.volumeOffset == 512 })
        #expect(found.first?.sourceMetadata.recordOffset == Int64(512 + ext2Image().inodeOffset(12)))
        #expect(events.contains(.progress(bytesScanned: Int64(volume.count), totalBytes: Int64(volume.count))))
    }

    @Test func corruptLiveMetadataIsFailClosed() async {
        var badEntry = ext2Image(); badEntry.data.put(32 * 1024 + 4, 6, 2)
        var badGeometry = ext2Image(); badGeometry.data.put(1024 + 40, 17, 4)
        var hugeVolume = ext2Image(); hugeVolume.data.put(1024 + 4, 100_000, 4)
        var tableOutside = ext2Image(); tableOutside.data.put(2048 + 8, 600, 4)
        for image in [badEntry, badGeometry, hugeVolume, tableOutside] {
            let events = await scan(image.image)
            #expect(events.contains { if case .error(.malformed) = $0 { true } else { false } })
            #expect(!events.contains(.completed))
        }
    }

    // MARK: P1 — stale names, reuse after the entry went stale, live reuse

    @Test func staleEntriesThatDisagreeOnNameAreSkipped() async {
        // mv old.txt gone.txt, then rm gone.txt: both names survive in the slack for inode 13.
        let image = deletedImage(stale: [(13, "old.txt"), (13, "gone.txt")])
        let events = await scan(image.image)
        #expect(events.last == .completed)
        #expect(files(events).map(\.path) == ["/live.txt"])
        // Two copies of the same name agree, so the file is still recovered.
        let agreeing = deletedImage(stale: [(13, "gone.txt"), (13, "gone.txt")])
        #expect(files(await scan(agreeing.image)).map(\.path) == ["/live.txt", "/gone.txt"])
    }

    @Test func staleEntriesThatDisagreeOnPathAreSkipped() async {
        var image = deletedImage()
        // A subdirectory whose slack also names inode 13 as gone.txt.
        // Root becomes ".", "..", live.txt, sub, with gone.txt still in sub's slack.
        image.data.put(32 * 1024 + 24 + 4, 16, 2)
        image.dirent(at: 32 * 1024 + 40, inode: 14, recordLength: 1024 - 40, name: "sub", type: 2)
        image.dirent(at: 32 * 1024 + 52, inode: 13, recordLength: 1024 - 52, name: "gone.txt", type: 1)
        image.inode(14, directory: true, size: 1024, links: 2, blocks: EXTImage.blockMap([34]), used: [34])
        var p = 34 * 1024
        p = image.dirent(at: p, inode: 14, recordLength: 12, name: ".", type: 2)
        p = image.dirent(at: p, inode: 2, recordLength: 1024 - 12, name: "..", type: 2)
        image.dirent(at: p, inode: 13, recordLength: 35 * 1024 - p, name: "gone.txt", type: 1)
        let events = await scan(image.image)
        #expect(events.last == .completed)
        #expect(files(events).allSatisfy { !$0.isDeleted })
    }

    @Test func deletionLaterThanTheDirectoryChangeIsSkipped() async {
        // Root mtime is 1_700_000_000; a later dtime means inode 13 was reused after this entry
        // went stale and then deleted again.
        var image = deletedImage()
        image.inode(13, size: 600, links: 0, dtime: 1_700_000_001, blocks: EXTImage.blockMap([90]), used: [90])
        let events = await scan(image.image)
        #expect(events.last == .completed)
        #expect(files(events).map(\.path) == ["/live.txt"])
    }

    @Test func liveEntryOnAnInodeMarkedFreeIsNeverAlsoDeleted() async {
        // live.txt now references inode 13, whose bitmap bit says free; gone.txt names it too.
        var image = deletedImage()
        image.data.put(32 * 1024 + 24, 13, 4)
        let events = await scan(image.image)
        #expect(events.last == .completed)
        let found = files(events)
        #expect(found.map(\.path) == ["/live.txt"])
        #expect(found.allSatisfy { !$0.isDeleted })
    }

    // MARK: P2 — needs_recovery

    @Test func needsRecoverySkipsDeletedRecovery() async {
        var image = deletedImage(); image.incompat |= 0x4
        let events = await scan(image.image)
        #expect(events.last == .completed)
        #expect(files(events).map(\.path) == ["/live.txt"])
    }

    @Test func freeInodeLiveEntryIsSkippedOnlyWhenJournalNeedsRecovery() async {
        var image = ext2Image(); image.data.put(image.inodeOffset(12), 0, 2)
        let clean = await scan(image.image)
        #expect(clean.contains { if case .error(.malformed) = $0 { true } else { false } })
        #expect(!clean.contains(.completed))
        image.incompat |= 0x4
        let recovering = await scan(image.image)
        #expect(recovering.last == .completed)
        #expect(files(recovering).map(\.path) == ["/docs/big.bin"])
    }

    // MARK: P3 — bounded queued state and candidate memory

    /// Root holds a chain of `depth` nested directories (names `nameLength` bytes long) ending in
    /// leaf.txt, plus `fanOut` empty sibling directories.
    func chainImage(depth: Int, nameLength: Int = 8, fanOut: Int = 0) -> (image: EXTImage, names: [String]) {
        var image = EXTImage(inodesPerGroup: 128)
        let names = (0..<depth).map { level -> String in
            let base = "d\(level)"
            return base + String(repeating: "x", count: nameLength - base.count)
        }
        let leafInode = 12 + depth + fanOut, leafBlock = 33 + depth + fanOut
        var rootEntries: [(Int, String, UInt8)] = depth > 0 ? [(12, names[0], 2)] : [(leafInode, "leaf.txt", 1)]
        for j in 0..<fanOut { rootEntries.append((12 + depth + j, "f\(j)", 2)) }
        image.inode(2, directory: true, size: 1024, links: 2, blocks: EXTImage.blockMap([32]), used: [32])
        image.directory(32, this: 2, parent: 2, rootEntries)
        for level in 0..<depth {
            let inode = 12 + level, block = 33 + level
            image.inode(inode, directory: true, size: 1024, links: 2, blocks: EXTImage.blockMap([block]), used: [block])
            let child: (Int, String, UInt8) = level + 1 < depth ? (inode + 1, names[level + 1], 2) : (leafInode, "leaf.txt", 1)
            image.directory(block, this: inode, parent: level == 0 ? 2 : inode - 1, [child])
        }
        for j in 0..<fanOut {
            let inode = 12 + depth + j, block = 33 + depth + j
            image.inode(inode, directory: true, size: 1024, links: 2, blocks: EXTImage.blockMap([block]), used: [block])
            image.directory(block, this: inode, parent: 2, [])
        }
        image.inode(leafInode, size: 4, blocks: EXTImage.blockMap([leafBlock]), used: [leafBlock])
        return (image, names)
    }

    @Test func deepChainAndWideFanOutKeepQueuedStateLinear() async {
        let depth = 40, nameLength = 100, fanOut = 30
        let (image, names) = chainImage(depth: depth, nameLength: nameLength, fanOut: fanOut)
        let result = await runEXT(image)
        #expect(result.error == nil)
        #expect(result.files.map(\.path) == ["/" + names.joined(separator: "/") + "/leaf.txt"])
        let stats = await result.volume.stats
        // Each directory's own name is stored once; full paths would cost the sum of every prefix.
        let fanBytes = (0..<fanOut).map { "f\($0)".utf8.count }.reduce(0, +)
        #expect(stats.directoryNameBytes == depth * nameLength + fanBytes)
        let fullPathBytes = (1...depth).map { $0 * (nameLength + 1) }.reduce(0, +)
        #expect(stats.directoryNameBytes * 10 < fullPathBytes)
        #expect(stats.peakPendingDirectories <= fanOut + 1)
    }

    @Test func candidateCapsBoundMemoryAndStillDetectConflicts() async {
        #expect(EXTVolume.maxCandidates == 200_000)
        #expect(EXTLimits().maxCandidateNameBytes == 16 << 20)
        // Past the count cap, a second stale name for a kept inode still blocks recovery.
        let conflicting = deletedImage(stale: [(13, "gone.txt"), (13, "old.txt")])
        var limits = EXTLimits(); limits.maxCandidates = 1
        let capped = await runEXT(conflicting, limits: limits)
        #expect(capped.error == nil)
        #expect(capped.files.map(\.path) == ["/live.txt"])
        // With a single stale name, a cap of one still keeps it.
        let single = await runEXT(deletedImage(), limits: limits)
        #expect(single.files.map(\.path) == ["/live.txt", "/gone.txt"])
        // The name-byte cap drops candidates rather than growing.
        var tiny = EXTLimits(); tiny.maxCandidateNameBytes = 4
        let dropped = await runEXT(deletedImage(), limits: tiny)
        #expect(dropped.error == nil)
        #expect(dropped.files.map(\.path) == ["/live.txt"])
        #expect(await dropped.volume.candidateNameBytes == 0)
    }

    // MARK: P4 — bounded work

    @Test func hardLinksAreMappedOnce() async {
        var image = EXTImage()
        image.inode(2, directory: true, size: 1024, links: 2, blocks: EXTImage.blockMap([32]), used: [32])
        image.directory(32, this: 2, parent: 2, [(12, "a", 1), (12, "b", 1), (12, "c", 1)])
        image.inode(12, size: 5, links: 3, blocks: EXTImage.blockMap([40]), used: [40])
        let result = await runEXT(image)
        #expect(result.error == nil)
        #expect(result.files.map(\.path) == ["/a", "/b", "/c"])
        // The root directory once, plus the shared file once.
        #expect(await result.volume.stats.mappingComputations == 2)
    }

    @Test func deletedWorkBudgetSkipsRemainingCandidates() async {
        let full = await runEXT(deletedImage())
        #expect(full.files.map(\.path) == ["/live.txt", "/gone.txt"])
        let spent = await full.volume.stats.deletedWorkSpent
        #expect(await full.volume.deletedWorkRemaining + spent == 4 * 512 + 1_000_000)
        var limits = EXTLimits(); limits.deletedWorkBudget = 1
        let starved = await runEXT(deletedImage(), limits: limits)
        #expect(starved.error == nil)
        #expect(starved.files.map(\.path) == ["/live.txt"])
        #expect(await starved.volume.stats.deletedBudgetExhausted)
    }

    @Test func deletedMappingFarLargerThanTheSizeIsSkipped() async {
        // 600 bytes needs one block, but the old map names 12 direct blocks plus 8 indirect ones.
        var image = deletedImage()
        let direct = Array(90..<102)
        image.inode(13, size: 600, links: 0, dtime: 1, blocks: EXTImage.blockMap(direct, indirect: 102))
        for k in 0..<8 { image.data.put(102 * 1024 + k * 4, UInt64(103 + k), 4) }
        let events = await scan(image.image)
        #expect(events.last == .completed)
        #expect(files(events).map(\.path) == ["/live.txt"])
    }

    @Test func overlappingDeletedCandidatesAreAllSkipped() async {
        var image = deletedImage(stale: [(13, "gone.txt"), (14, "other.txt")])
        image.inode(14, size: 100, links: 0, dtime: 1, blocks: EXTImage.blockMap([90]))
        let events = await scan(image.image)
        #expect(events.last == .completed)
        #expect(files(events).map(\.path) == ["/live.txt"])
        // Distinct blocks: both are recovered.
        image.inode(14, size: 100, links: 0, dtime: 1, blocks: EXTImage.blockMap([91]))
        #expect(files(await scan(image.image)).map(\.path) == ["/live.txt", "/gone.txt", "/other.txt"])
    }

    @Test func overlapDetectionFlagsEveryOverlappingOwner() {
        let claims = [EXTClaim(start: 0, end: 10, owner: 0), EXTClaim(start: 2, end: 3, owner: 1),
                      EXTClaim(start: 5, end: 20, owner: 2), EXTClaim(start: 20, end: 21, owner: 3),
                      EXTClaim(start: 30, end: 31, owner: 4), EXTClaim(start: 30, end: 32, owner: 4)]
        #expect(EXTVolume.overlappingOwners(claims, owners: 5) == [true, true, true, false, true])
    }

    // MARK: P5 — bigalloc

    @Test func bigallocIsRefused() async {
        var image = ext2Image(); image.roCompat |= 0x200
        let events = await scan(image.image)
        #expect(events.contains(.error(.unsupportedFilesystem)))
        #expect(files(events).isEmpty && !events.contains(.completed))
    }

    // MARK: P7 — coverage

    @Test func sixtyFourBitHighHalvesAreRead() async {
        // 64 KiB blocks and a block count above 2^32: every descriptor field and the block count
        // have non-zero high halves, so reading the wrong offset (or ignoring it) fails.
        let blockSize: Int64 = 65536, high: Int64 = 1 << 32, groupCount = 8193
        func at(_ k: Int64) -> Int64 { (high + k) * blockSize }
        var superblock = Data(repeating: 0, count: 2048)
        let s = 1024
        superblock.put(s, UInt64(groupCount * 16), 4); superblock.put(s + 4, 16, 4); superblock.put(s + 336, 1, 4)
        superblock.put(s + 24, 6, 4); superblock.put(s + 32, 524_288, 4); superblock.put(s + 40, 16, 4)
        superblock.put(s + 56, 0xef53, 2); superblock.put(s + 76, 1, 4); superblock.put(s + 84, 11, 4)
        superblock.put(s + 88, 256, 2); superblock.put(s + 96, 0x2 | 0x40 | 0x80, 4); superblock.put(s + 254, 64, 2)
        var table = Data(repeating: 0, count: groupCount * 64)
        for g in 0..<groupCount {
            let d = g * 64
            table.put(d, 1, 4); table.put(d + 0x20, 1, 4)
            table.put(d + 4, 2, 4); table.put(d + 0x24, 1, 4)
            table.put(d + 8, 3, 4); table.put(d + 0x28, 1, 4)
        }
        var inodes = Data(repeating: 0, count: 4096)
        for (n, mode, size, start) in [(2, UInt64(0x41ed), UInt64(65536), high + 4), (12, 0x81a4, 4, high + 5)] {
            let o = (n - 1) * 256
            inodes.put(o, mode, 2); inodes.put(o + 4, size, 4); inodes.put(o + 16, 1_600_000_000, 4)
            inodes.put(o + 26, 1, 2); inodes.put(o + 32, 0x80000, 4)
            inodes.replaceSubrange(o + 40..<o + 100, with: EXTImage.extentNode([(0, 1, Int(start))]))
        }
        var directory = Data(repeating: 0, count: 65536)
        for (p, inode, length, name, type) in [(0, 2, 12, ".", 2), (12, 2, 12, "..", 2), (24, 12, 65536 - 24, "far.txt", 1)] {
            directory.put(p, UInt64(inode), 4); directory.put(p + 4, UInt64(length), 2)
            directory.put(p + 6, UInt64(name.utf8.count), 1); directory.put(p + 7, UInt64(type), 1)
            directory.text(p + 8, name)
        }
        let reader = SparseReader(sizeBytes: (high + 16) * blockSize,
                                  regions: [(0, superblock), (blockSize, table), (at(3), inodes), (at(4), directory),
                                            (at(5), Data("data".utf8))])
        let result = await runEXT(reader)
        #expect(result.error == nil)
        #expect(result.files.map(\.path) == ["/far.txt"])
        #expect(result.files.first?.sourceMetadata.recordOffset == at(3) + 11 * 256)
        #expect(result.files.first?.sizeBytes == 4)
    }

    @Test func crc32cMatchesIndependentVectors() {
        // RFC 3720 appendix B.4 vectors.
        #expect(crc32c(Data(repeating: 0, count: 32)) == 0x8A91_36AA)
        #expect(crc32c(Data(repeating: 0xff, count: 32)) == 0x62A8_AB43)
        #expect(crc32c(Data(0..<32)) == 0x46DD_794E)
    }

    @Test func superblockChecksumMatchesAnIndependentlyComputedValue() async {
        // 0x979B67C8 is the raw CRC32C register (seed ~0, no final inversion) over bytes 0..<1020
        // of this fixed superblock, computed with a separate table-driven CRC32C implementation
        // that reproduces the RFC 3720 vectors; it is not derived from the parser's function.
        var image = ext2Image(); image.roCompat |= 0x400
        var bytes = image.image
        bytes.put(1024 + 1020, 0x979B_67C8, 4)
        #expect((await scan(bytes)).last == .completed)
        bytes.put(1024 + 1020, 0x979B_67C9, 4)
        #expect(!(await scan(bytes)).contains(.completed))
    }

    @Test func fourKiBBlocksWithFirstDataBlockZero() async {
        var image = EXTImage(blockSize: 4096)
        image.inode(2, directory: true, size: 4096, links: 2, blocks: EXTImage.blockMap([32]), used: [32])
        let b = 32 * 4096
        image.dirent(at: b, inode: 2, recordLength: 12, name: ".", type: 2)
        image.dirent(at: b + 12, inode: 2, recordLength: 4064 - 12, name: "..", type: 2)
        image.dirent(at: b + 24, inode: 13, recordLength: 4064 - 24, name: "gone.txt", type: 1)
        // The last live entry sits right at the block end.
        image.dirent(at: b + 4064, inode: 12, recordLength: 32, name: "z.txt", type: 1)
        image.inode(12, size: 5000, blocks: EXTImage.blockMap([40, 41]), used: [40, 41])
        image.inode(13, size: 100, links: 0, dtime: 1_700_000_000, blocks: EXTImage.blockMap([90]), used: [90])
        let events = await scan(image.image)
        #expect(events.last == .completed)
        let found = files(events)
        #expect(found.map(\.path) == ["/z.txt", "/gone.txt"])
        #expect(found.map(\.sizeBytes) == [5000, 100])
        #expect(found.map(\.isDeleted) == [false, true])
        #expect(found.first?.sourceMetadata.recordOffset == Int64(8 * 4096 + 11 * 128))
    }

    @Test func doubleIndirectBlockMapResolves() async throws {
        var image = ext2Image()
        // Logical block 268 is the first one reached through the double-indirect pointer.
        image.inode(12, size: 269 * 1024, blocks: EXTImage.blockMap([40], double: 100), used: [40, 100, 101, 102])
        image.data.put(100 * 1024, 101, 4); image.data.put(101 * 1024, 102, 4)
        let result = await runEXT(image)
        #expect(result.error == nil)
        #expect(result.files.first { $0.name == "hello.txt" }?.sizeBytes == Int64(269 * 1024))
        let raw = try await result.volume.inode(12).data
        let map = try await result.volume.mapping(EXTInode(raw, inodeSize: 128), limit: 512)
        #expect(map.runs == [EXTRun(logical: 0, physical: 40, count: 1, initialized: true),
                             EXTRun(logical: 268, physical: 102, count: 1, initialized: true)])
        #expect(map.metadata == [100, 101])
    }

    @Test func directoryCyclesAndHardLinkedDirectoriesTerminate() async {
        var cycle = ext2Image()
        cycle.directory(33, this: 13, parent: 2, [(14, "big.bin", 1), (2, "loop", 2)])
        var linked = ext2Image()
        linked.directory(32, this: 2, parent: 2, [(12, "hello.txt", 1), (13, "docs", 2), (13, "again", 2)])
        for image in [cycle, linked] {
            let events = await scan(image.image)
            #expect(events.contains { if case .error(.malformed(let reason)) = $0 { reason.contains("cycle") } else { false } })
            #expect(!events.contains(.completed))
        }
    }

    @Test func directoryDepthIsCapped() async {
        #expect(EXTLimits().maxDirectoryDepth == 2048)
        var limits = EXTLimits(); limits.maxDirectoryDepth = 3
        let allowed = await runEXT(chainImage(depth: 3).image, limits: limits)
        #expect(allowed.error == nil)
        #expect(allowed.files.count == 1)
        let tooDeep = await runEXT(chainImage(depth: 4).image, limits: limits)
        #expect(isMalformed(tooDeep.error))
        #expect(tooDeep.files.isEmpty)
    }

    @Test func uninitializedGroupBitmapsSkipDeletedCandidates() async {
        var image = deletedImage(); image.roCompat |= 0x10
        #expect(files(await scan(image.image)).map(\.path) == ["/live.txt", "/gone.txt"])
        for flag: UInt16 in [0x1, 0x2] {
            var uninit = image; uninit.groupFlags(0, flag)
            let events = await scan(uninit.image)
            #expect(events.last == .completed)
            #expect(files(events).map(\.path) == ["/live.txt"])
        }
    }

    @Test func nonUTF8LiveNameIsEscaped() async {
        var image = EXTImage()
        image.inode(2, directory: true, size: 1024, links: 2, blocks: EXTImage.blockMap([32]), used: [32])
        var p = 32 * 1024
        p = image.dirent(at: p, inode: 2, recordLength: 12, name: ".", type: 2)
        p = image.dirent(at: p, inode: 2, recordLength: 12, name: "..", type: 2)
        let nameBytes = Data("caf".utf8) + Data([0xe9]) + Data(".txt".utf8)
        image.dirent(at: p, inode: 12, recordLength: 33 * 1024 - p, nameBytes: nameBytes, type: 1)
        image.inode(12, size: 3, blocks: EXTImage.blockMap([40]), used: [40])
        let events = await scan(image.image)
        #expect(events.last == .completed)
        let found = files(events)
        #expect(found.map(\.name) == ["caf\\xE9.txt"])
        #expect(found.map(\.path) == ["/caf\\xE9.txt"])
        #expect(found.first?.sourceMetadata.rawRecord.suffix(nameBytes.count) == nameBytes)
    }

    // MARK: Content mapping

    /// Reads a file back exactly as preview and recovery will.
    func readBack(_ file: RecoveredFile?, from image: Data) async throws -> Data {
        guard let file else { throw ScanError.malformed("missing file") }
        return try await FileContentReader(reader: ImageReader(data: image), chunkSize: 512).prefix(of: file, limit: .max)
    }
    /// Distinct bytes for one block, so a block read from the wrong place never compares equal.
    func pattern(_ block: Int, _ blockSize: Int = 1024) -> Data {
        Data((0..<blockSize).map { UInt8(truncatingIfNeeded: block &* 31 &+ $0 &* 7 &+ 1) })
    }
    @discardableResult
    func fill(_ image: inout EXTImage, _ blocks: [Int]) -> Data {
        var expected = Data()
        for block in blocks {
            image.data.replaceSubrange(block * image.blockSize..<(block + 1) * image.blockSize, with: pattern(block, image.blockSize))
            expected += pattern(block, image.blockSize)
        }
        return expected
    }
    func ext4Root(_ entries: [(Int, String, UInt8)]) -> EXTImage {
        var image = EXTImage(ext4: true)
        image.inode(2, directory: true, size: 1024, links: 2, flags: 0x80000,
                    blocks: EXTImage.extentNode([(0, 1, 32)]), used: [32])
        image.directory(32, this: 2, parent: 2, entries)
        return image
    }

    @Test func fragmentedBlockMapFileReadsBackThroughCoalescedRuns() async throws {
        var image = ext2Image()
        let hello = Data("hello".utf8)
        // big.bin: 12 direct blocks, then 63 and 64 through the indirect block 62.
        let expected = fill(&image, Array(50..<62) + [63, 64]).prefix(13 * 1024 + 10)
        let bytes = image.image
        let found = await runEXT(ImageReader(data: bytes))
        #expect(found.error == nil)
        let big = found.files.first { $0.name == "big.bin" }
        #expect(big?.content == .runs([DataRun(deviceOffset: 50 * 1024, length: 12 * 1024),
                                       DataRun(deviceOffset: 63 * 1024, length: 2 * 1024)]))
        #expect(try await readBack(big, from: bytes) == expected)
        let small = found.files.first { $0.name == "hello.txt" }
        #expect(small?.content == .runs([DataRun(deviceOffset: 40 * 1024, length: 1024)]))
        #expect(try await readBack(small, from: bytes) == hello)
    }

    @Test func contiguousAndTreeExtentFilesReadBack() async throws {
        var image = ext4Root([(12, "flat.txt", 1), (13, "tree.bin", 1)])
        image.inode(12, size: 2000, flags: 0x80000, blocks: EXTImage.extentNode([(0, 2, 60)]), used: [60, 61])
        image.inode(13, size: 3 * 1024, flags: 0x80000, blocks: EXTImage.extentIndex([(0, 70)], depth: 1),
                    used: [70, 71, 80, 81])
        image.data.replaceSubrange(70 * 1024..<71 * 1024, with: EXTImage.extentNode([(0, 1, 71), (1, 2, 80)], size: 1024))
        let flat = fill(&image, [60, 61]).prefix(2000)
        let tree = fill(&image, [71, 80, 81])
        let bytes = image.image
        let found = await runEXT(ImageReader(data: bytes))
        #expect(found.error == nil)
        #expect(found.files[0].content == .runs([DataRun(deviceOffset: 60 * 1024, length: 2048)]))
        #expect(found.files[1].content == .runs([DataRun(deviceOffset: 71 * 1024, length: 1024),
                                                DataRun(deviceOffset: 80 * 1024, length: 2048)]))
        #expect(try await readBack(found.files[0], from: bytes) == flat)
        #expect(try await readBack(found.files[1], from: bytes) == tree)
    }

    @Test func emptyFileHasNoRuns() async throws {
        var image = ext4Root([(12, "empty", 1), (13, "empty-mapped", 1)])
        image.inode(12, size: 0, flags: 0x80000, blocks: EXTImage.extentNode([]))
        // Blocks past EOF (preallocation) are never part of the content.
        image.inode(13, size: 0, flags: 0x80000, blocks: EXTImage.extentNode([(0, 1, 60)]), used: [60])
        let bytes = image.image
        let found = await runEXT(ImageReader(data: bytes))
        #expect(found.error == nil)
        #expect(found.files.map(\.content) == [.runs([]), .runs([])])
        #expect(try await readBack(found.files[0], from: bytes).isEmpty)
    }

    @Test func blocksPastTheSizeAreClipped() async throws {
        var image = ext4Root([(12, "prealloc", 1)])
        image.inode(12, size: 1500, flags: 0x80000, blocks: EXTImage.extentNode([(0, 4, 60)]), used: [60, 61, 62, 63])
        let expected = fill(&image, [60, 61, 62, 63]).prefix(1500)
        let bytes = image.image
        let found = await runEXT(ImageReader(data: bytes))
        #expect(found.files.first?.content == .runs([DataRun(deviceOffset: 60 * 1024, length: 2048)]))
        #expect(try await readBack(found.files.first, from: bytes) == expected)
    }

    @Test func sparseBlocksAndMissingTailAreHoles() async throws {
        var image = EXTImage()
        image.inode(2, directory: true, size: 1024, links: 2, blocks: EXTImage.blockMap([32]), used: [32])
        image.directory(32, this: 2, parent: 2, [(12, "middle", 1), (13, "tail", 1)])
        // Logical block 1 is unmapped; logical blocks 1-4 of "tail" are never written.
        image.inode(12, size: 3 * 1024, blocks: EXTImage.blockMap([40, 0, 42]), used: [40, 42])
        image.inode(13, size: 4 * 1024 + 100, blocks: EXTImage.blockMap([50]), used: [50])
        let first = fill(&image, [40]), last = fill(&image, [42]), tail = fill(&image, [50])
        fill(&image, [41])  // Physically between 40 and 42 but not part of the file.
        let bytes = image.image
        let found = await runEXT(ImageReader(data: bytes))
        #expect(found.error == nil)
        #expect(found.files[0].content == .runs([DataRun(deviceOffset: 40 * 1024, length: 1024),
                                                DataRun(deviceOffset: nil, length: 1024),
                                                DataRun(deviceOffset: 42 * 1024, length: 1024)]))
        #expect(try await readBack(found.files[0], from: bytes) == first + Data(count: 1024) + last)
        #expect(found.files[1].content == .runs([DataRun(deviceOffset: 50 * 1024, length: 1024),
                                                DataRun(deviceOffset: nil, length: 3 * 1024 + 100)]))
        #expect(try await readBack(found.files[1], from: bytes) == tail + Data(count: 3 * 1024 + 100))
    }

    @Test func uninitializedExtentsReadAsZerosAndAreNotCoalescedWithData() async throws {
        var image = ext4Root([(12, "mixed", 1), (13, "unwritten", 1)])
        // Physically adjacent blocks 60-62, but block 61 is an uninitialized extent.
        image.inode(12, size: 3 * 1024, flags: 0x80000,
                    blocks: EXTImage.extentNode([(0, 1, 60), (1, 32768 + 1, 61), (2, 1, 62)]), used: [60, 61, 62])
        image.inode(13, size: 2048, flags: 0x80000, blocks: EXTImage.extentNode([(0, 32768 + 2, 70)]), used: [70, 71])
        let a = fill(&image, [60]); fill(&image, [61, 70, 71]); let c = fill(&image, [62])
        let bytes = image.image
        let found = await runEXT(ImageReader(data: bytes))
        #expect(found.error == nil)
        #expect(found.files[0].content == .runs([DataRun(deviceOffset: 60 * 1024, length: 1024),
                                                DataRun(deviceOffset: nil, length: 1024),
                                                DataRun(deviceOffset: 62 * 1024, length: 1024)]))
        #expect(try await readBack(found.files[0], from: bytes) == a + Data(count: 1024) + c)
        #expect(found.files[1].content == .runs([DataRun(deviceOffset: nil, length: 2048)]))
        #expect(try await readBack(found.files[1], from: bytes) == Data(count: 2048))
    }

    @Test func deletedFilesReadBackFromTheirValidatedMapping() async throws {
        var image = deletedImage(stale: [(13, "gone.txt"), (14, "frag.bin")])
        image.inode(13, size: 600, links: 0, dtime: 1, blocks: EXTImage.blockMap([90]))
        image.inode(14, size: 2 * 1024 + 7, links: 0, dtime: 1, blocks: EXTImage.blockMap([95, 97, 98]))
        let gone = fill(&image, [90]).prefix(600)
        let frag = fill(&image, [95, 97, 98]).prefix(2 * 1024 + 7)
        let bytes = image.image
        let found = await runEXT(ImageReader(data: bytes))
        #expect(found.files.map(\.path) == ["/live.txt", "/gone.txt", "/frag.bin"])
        #expect(found.files[1].isDeleted && found.files[2].isDeleted)
        #expect(found.files[1].content == .runs([DataRun(deviceOffset: 90 * 1024, length: 1024)]))
        #expect(found.files[2].content == .runs([DataRun(deviceOffset: 95 * 1024, length: 1024),
                                                DataRun(deviceOffset: 97 * 1024, length: 2048)]))
        #expect(try await readBack(found.files[1], from: bytes) == gone)
        #expect(try await readBack(found.files[2], from: bytes) == frag)
    }

    @Test func runsAreDeviceAbsoluteInsideAPartition() async throws {
        var volume = ext2Image()
        let expected = fill(&volume, Array(50..<62) + [63, 64]).prefix(13 * 1024 + 10)
        var image = Data(repeating: 0, count: 512) + volume.image
        image.put(446 + 4, 0x83, 1); image.put(446 + 8, 1, 4); image.put(446 + 12, UInt64(volume.image.count / 512), 4)
        image.put(510, 0xaa55, 2)
        let found = files(await scan(image))
        let big = found.first { $0.name == "big.bin" }
        #expect(big?.content == .runs([DataRun(deviceOffset: 512 + 50 * 1024, length: 12 * 1024),
                                       DataRun(deviceOffset: 512 + 63 * 1024, length: 2 * 1024)]))
        #expect(try await readBack(big, from: image) == expected)
        #expect(try await readBack(found.first { $0.name == "hello.txt" }, from: image) == Data("hello".utf8))
    }

    @Test func encryptedInodeContentIsUnmapped() async {
        var image = ext4Root([(12, "secret", 1)])
        image.inode(12, size: 10, flags: 0x80000 | 0x800, blocks: EXTImage.extentNode([(0, 1, 60)]), used: [60])
        let found = await runEXT(image)
        #expect(found.error == nil)
        #expect(found.files.first?.content == .unmapped)
    }
}
