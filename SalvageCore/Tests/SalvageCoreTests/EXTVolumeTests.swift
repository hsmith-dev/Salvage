import Foundation
import Testing
@testable import SalvageCore

/// Builds tiny ext2/3/4 images with 1 KiB blocks. Block 1 holds the superblock, block 2 the
/// group descriptors, blocks 3-7 the bitmaps, 8-23 the inode tables and data starts at 32.
struct EXTImage {
    static let blockSize = 1024
    var data: Data
    let inodeSize: Int, inodesPerGroup = 16, blocksPerGroup: Int, groups: Int, descriptorSize: Int
    var incompat: UInt64
    var roCompat: UInt64 = 0

    init(ext4: Bool = false, wide: Bool = false, inodeSize: Int? = nil) {
        self.inodeSize = inodeSize ?? (ext4 ? 256 : 128)
        groups = wide ? 2 : 1
        blocksPerGroup = wide ? 256 : 8192
        let blocks = wide ? 513 : 512
        descriptorSize = wide ? 64 : 32
        incompat = 0x2 | (ext4 ? 0x40 : 0) | (wide ? 0x80 : 0)
        data = Data(repeating: 0, count: blocks * Self.blockSize)
        let sb = 1024
        data.put(sb, UInt64(inodesPerGroup * groups), 4); data.put(sb + 4, UInt64(blocks), 4)
        data.put(sb + 20, 1, 4); data.put(sb + 24, 0, 4); data.put(sb + 32, UInt64(blocksPerGroup), 4)
        data.put(sb + 40, UInt64(inodesPerGroup), 4); data.put(sb + 56, 0xef53, 2); data.put(sb + 76, 1, 4)
        data.put(sb + 84, 11, 4); data.put(sb + 88, UInt64(self.inodeSize), 2)
        if wide { data.put(sb + 254, 64, 2) }
        for group in 0..<groups {
            let d = 2048 + group * descriptorSize
            data.put(d, UInt64(3 + group), 4); data.put(d + 4, UInt64(5 + group), 4)
            data.put(d + 8, UInt64(inodeTable(group)), 4)
        }
        for block in 1..<32 { mark(block: block) }
        for inode in 1...11 { mark(inode: inode) }
    }
    func inodeTable(_ group: Int) -> Int { 8 + group * (inodesPerGroup * inodeSize / Self.blockSize) }
    func inodeOffset(_ n: Int) -> Int {
        let group = (n - 1) / inodesPerGroup
        return inodeTable(group) * Self.blockSize + (n - 1) % inodesPerGroup * inodeSize
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
        let relative = block - 1, group = relative / blocksPerGroup, bit = relative % blocksPerGroup
        let byte = (3 + group) * Self.blockSize + bit / 8
        if used { data[byte] |= 1 << (bit % 8) } else { data[byte] &= ~(1 << (bit % 8)) }
    }
    mutating func mark(inode: Int, used: Bool = true) {
        let group = (inode - 1) / inodesPerGroup, bit = (inode - 1) % inodesPerGroup
        let byte = (5 + group) * Self.blockSize + bit / 8
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
        data.put(offset, UInt64(inode), 4); data.put(offset + 4, UInt64(recordLength), 2)
        data.put(offset + 6, UInt64(name.utf8.count), 1); data.put(offset + 7, UInt64(type), 1)
        data.text(offset + 8, name)
        return offset + (8 + name.utf8.count + 3) / 4 * 4
    }
    /// Writes ".", ".." and the given entries; the last entry's record spans the block.
    mutating func directory(_ block: Int, this: Int, parent: Int, _ entries: [(Int, String, UInt8)]) {
        var p = block * Self.blockSize
        let all = [(this, ".", UInt8(2)), (parent, "..", UInt8(2))] + entries
        for (index, (inode, name, type)) in all.enumerated() {
            let real = (8 + name.utf8.count + 3) / 4 * 4
            let length = index == all.count - 1 ? (block + 1) * Self.blockSize - p : real
            dirent(at: p, inode: inode, recordLength: length, name: name, type: type)
            p += length
        }
    }
    mutating func content(_ block: Int, _ text: String) { data.text(block * Self.blockSize, text) }
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

func files(_ events: [ScanEvent]) -> [RecoveredFile] {
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
    func deletedImage(ext4: Bool = false) -> EXTImage {
        var image = EXTImage(ext4: ext4)
        let rootFlags: UInt32 = ext4 ? 0x80000 : 0
        image.inode(2, directory: true, size: 1024, links: 2, flags: rootFlags,
                    blocks: ext4 ? EXTImage.extentNode([(0, 1, 32)]) : EXTImage.blockMap([32]), used: [32])
        var p = 32 * 1024
        p = image.dirent(at: p, inode: 2, recordLength: 12, name: ".", type: 2)
        p = image.dirent(at: p, inode: 2, recordLength: 12, name: "..", type: 2)
        let gap = image.dirent(at: p, inode: 12, recordLength: 33 * 1024 - p, name: "live.txt", type: 1)
        image.dirent(at: gap, inode: 13, recordLength: 33 * 1024 - gap, name: "gone.txt", type: 1)
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
}
