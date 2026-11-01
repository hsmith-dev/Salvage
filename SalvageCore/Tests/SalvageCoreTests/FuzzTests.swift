import Darwin
import Foundation
import Testing
@testable import SalvageCore

// Parser fuzzing (spec-tech-batch-6 §A). A deterministic, seedable mutation fuzzer that runs a full
// `ScanSession` over damaged copies of small valid images, through an in-memory `BlockReader`.
//
// Opt-in: `SALVAGE_FUZZ=1 swift test --package-path SalvageCore --filter FuzzTests/fuzzParsers`
// (or `scripts/fuzz-parsers.sh`). The driver test never scans in its own process: it re-invokes this
// test binary filtered to `fuzzWorker` for each batch, so a trap is reported with its seed and
// iteration instead of killing the runner, and a scan that outlives its wall-clock budget is killed
// and reported as a hang. Every crashing or hanging input is saved with a reproducer command.
//
// Environment:
//   SALVAGE_FUZZ=1                 enables the driver
//   SALVAGE_FUZZ_ITERATIONS        iterations per format (default 500)
//   SALVAGE_FUZZ_SEED              run seed, decimal or 0x-hex (default 1)
//   SALVAGE_FUZZ_FORMATS           comma list (default: all of FuzzFormat)
//   SALVAGE_FUZZ_JOBS              parallel child processes (default min(8, cores / 2))
//   SALVAGE_FUZZ_BATCH             iterations per child process (default 250)
//   SALVAGE_FUZZ_DIR               output: seeds/, crashes/, logs/, summary.json (default a temp dir)
//   SALVAGE_FUZZ_REAL_IMAGES=0     skip the hdiutil seed images
//   SALVAGE_FUZZ_HANG_BASE / _HANG_PER_MIB   hang budget in seconds: base + per MiB of input (30 / 2)
//   SALVAGE_FUZZ_MINIMISE=0        skip crash minimisation
//   SALVAGE_FUZZ_ALLOW             comma list of crash/hang signature substrings that are reported
//                                  but don't fail the run (for known bugs owned elsewhere)

// MARK: - Configuration

enum FuzzConfig {
    static var env: [String: String] { ProcessInfo.processInfo.environment }
    static var enabled: Bool { env["SALVAGE_FUZZ"] == "1" && !isWorker }
    static var isWorker: Bool { env["SALVAGE_FUZZ_WORKER"] == "1" }
    static var reproPath: String? { env["SALVAGE_FUZZ_REPRO"] }
    static var iterations: Int { Int(env["SALVAGE_FUZZ_ITERATIONS"] ?? "") ?? 500 }
    static var seed: UInt64 { parse(env["SALVAGE_FUZZ_SEED"]) ?? 1 }
    static var jobs: Int { Int(env["SALVAGE_FUZZ_JOBS"] ?? "") ?? max(1, min(8, ProcessInfo.processInfo.activeProcessorCount / 2)) }
    static var batch: Int { max(1, Int(env["SALVAGE_FUZZ_BATCH"] ?? "") ?? 250) }
    static var hangBase: Double { Double(env["SALVAGE_FUZZ_HANG_BASE"] ?? "") ?? 30 }
    static var hangPerMiB: Double { Double(env["SALVAGE_FUZZ_HANG_PER_MIB"] ?? "") ?? 2 }
    static var minimise: Bool { env["SALVAGE_FUZZ_MINIMISE"] != "0" }
    static var allowed: [String] { (env["SALVAGE_FUZZ_ALLOW"] ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty } }
    static var realImages: Bool {
        env["SALVAGE_FUZZ_REAL_IMAGES"] != "0" && env["SALVAGE_SKIP_HDIUTIL"] == nil
            && FileManager.default.isExecutableFile(atPath: "/usr/bin/hdiutil")
    }
    static var formats: [FuzzFormat] {
        guard let list = env["SALVAGE_FUZZ_FORMATS"], !list.isEmpty else { return FuzzFormat.allCases }
        return list.split(separator: ",").compactMap { FuzzFormat(rawValue: String($0)) }
    }
    static var directory: URL {
        if let path = env["SALVAGE_FUZZ_DIR"], !path.isEmpty { return URL(fileURLWithPath: path) }
        return FileManager.default.temporaryDirectory.appendingPathComponent("salvage-fuzz-\(String(seed, radix: 16))")
    }
    static func parse(_ text: String?) -> UInt64? {
        guard let text else { return nil }
        if text.hasPrefix("0x") { return UInt64(text.dropFirst(2), radix: 16) }
        return UInt64(text)
    }
}

// MARK: - Formats and seed images

enum FuzzFormat: String, CaseIterable, Sendable {
    case fat32, exfat, ntfs, ext2, ext4, hfsplus, apfs, mbr, gpt

    /// Header fields worth hitting with boundary values: (offset, width, big-endian). Offsets fit the
    /// synthetic seeds; on real images they land near, not on, the same fields.
    var fields: [(Int, Int, Bool)] {
        switch self {
        case .fat32:
            var fields = [(11, 2), (13, 1), (14, 2), (16, 1), (19, 2), (22, 2), (32, 4), (36, 4), (44, 4), (48, 2), (50, 2)]
            fields += (0..<8).map { (32 * 512 + $0 * 4, 4) }
            for entry in 0..<4 { fields += [(552 * 512 + entry * 32 + 20, 2), (552 * 512 + entry * 32 + 26, 2), (552 * 512 + entry * 32 + 28, 4)] }
            return fields.map { ($0.0, $0.1, false) }
        case .exfat: return Self.exfatFields(at: 0)
        case .ntfs:
            var fields = [(11, 2), (13, 1), (0x28, 8), (0x30, 8), (0x38, 8), (0x40, 1), (0x44, 1)]
            for record in [0, 5, 6, 16, 17, 18, 19, 25, 26] {
                let r = 16 * 512 + record * 1024
                fields += [(r + 4, 2), (r + 6, 2), (r + 0x14, 2), (r + 0x18, 4), (r + 0x1c, 4)]
                for attribute in [0x38, 0x38 + 0x60, 0x38 + 0x60 + 0x68] {
                    fields += [(r + attribute + 4, 4), (r + attribute + 9, 1), (r + attribute + 10, 2), (r + attribute + 0x10, 4),
                               (r + attribute + 0x14, 2), (r + attribute + 0x18, 8), (r + attribute + 0x20, 2), (r + attribute + 0x28, 8),
                               (r + attribute + 0x30, 8), (r + attribute + 0x38, 8), (r + attribute + 0x40, 1)]
                }
            }
            return fields.map { ($0.0, $0.1, false) }
        case .ext2, .ext4: return Self.extFields(at: 0, inodeSize: self == .ext4 ? 256 : 128)
        case .hfsplus: return Self.hfsFields(at: 0)
        case .apfs:
            let fields = [(24, 4), (28, 4), (36, 4), (40, 8), (0x68, 4), (0x6c, 4), (0x70, 8), (0x78, 8), (0x80, 4), (0x84, 4),
                          (0x88, 4), (0x8c, 4), (0x90, 4), (0x94, 4), (0x98, 8), (0xa0, 8), (0xa8, 8), (0xb0, 8), (0xb4, 4), (0xb8, 8)]
            return fields.map { ($0.0, $0.1, false) }
        case .mbr:
            var fields: [(Int, Int, Bool)] = []
            for slot in 0..<4 { fields += [(446 + slot * 16 + 4, 1, false), (446 + slot * 16 + 8, 4, false), (446 + slot * 16 + 12, 4, false)] }
            return fields + Self.exfatFields(at: 64 * 512) + Self.extFields(at: 256 * 512, inodeSize: 128)
        case .gpt:
            var fields: [(Int, Int, Bool)] = [(450, 1, false), (454, 4, false), (458, 4, false)]
            fields += [(512 + 12, 4), (512 + 24, 8), (512 + 32, 8), (512 + 40, 8), (512 + 48, 8), (512 + 72, 8), (512 + 80, 4), (512 + 84, 4)]
                .map { ($0.0, $0.1, false) }
            for entry in 0..<2 { fields += [(1024 + entry * 128 + 32, 8, false), (1024 + entry * 128 + 40, 8, false)] }
            return fields + Self.exfatFields(at: 64 * 512) + Self.hfsFields(at: 256 * 512)
        }
    }
    static func exfatFields(at base: Int) -> [(Int, Int, Bool)] {
        let root = base + 25 * 512
        return [(72, 8), (80, 4), (84, 4), (88, 4), (92, 4), (96, 4), (104, 2), (106, 2), (108, 1), (109, 1), (110, 1), (111, 1)]
            .map { (base + $0.0, $0.1, false) }
            + [(1, 1), (35, 1), (40, 8), (52, 4), (56, 8), (97, 1), (116, 4), (120, 8), (129, 1), (163, 1), (180, 4), (184, 8)]
            .map { (root + $0.0, $0.1, false) }
    }
    static func extFields(at base: Int, inodeSize: Int) -> [(Int, Int, Bool)] {
        let sb = base + 1024
        var fields = [0, 4, 20, 24, 28, 32, 36, 40, 76, 84, 96, 100].map { (sb + $0, 4) } + [(sb + 56, 2), (sb + 88, 2), (sb + 254, 2)]
        fields += [(base + 2048, 4), (base + 2052, 4), (base + 2056, 4), (base + 2048 + 12, 2), (base + 2048 + 18, 2)]
        for inode in [2, 12, 13, 14] {
            let o = base + 8 * 1024 + (inode - 1) * inodeSize
            fields += [(o, 2), (o + 4, 4), (o + 20, 4), (o + 26, 2), (o + 32, 4), (o + 108, 4)]
            fields += stride(from: 40, to: 100, by: 4).map { (o + $0, 4) } + [(o + 42, 2), (o + 44, 2), (o + 46, 2)]
        }
        for block in [32, 33] { fields += [(base + block * 1024 + 4, 2), (base + block * 1024 + 6, 1), (base + block * 1024 + 16, 2)] }
        return fields.map { ($0.0, $0.1, false) }
    }
    static func hfsFields(at base: Int) -> [(Int, Int, Bool)] {
        let h = base + 1024
        var fields = [(0, 2), (2, 2), (4, 4), (12, 4), (40, 4), (44, 4), (64, 4)].map { (h + $0.0, $0.1) }
        for fork in [112, 192, 272, 352] { fields += [(h + fork, 8), (h + fork + 12, 4), (h + fork + 16, 4), (h + fork + 20, 4), (h + fork + 24, 4)] }
        for tree in [2, 4, 12] {
            let node = base + tree * 4096
            fields += [(node + 8, 1), (node + 9, 1), (node + 10, 2)] + [0, 2, 6, 10, 14, 18, 20, 22, 26].map { (node + 14 + $0, $0 == 18 || $0 == 20 || $0 == 0 ? 2 : 4) }
        }
        for leaf in 5...7 {
            let node = base + leaf * 4096
            fields += [(node, 4), (node + 4, 4), (node + 8, 1), (node + 9, 1), (node + 10, 2)] + (1...8).map { (node + 4096 - $0 * 2, 2) }
            fields += [(node + 14, 2), (node + 16, 4), (node + 20, 2)]
        }
        let journal = base + 16 * 4096
        fields += [(journal, 4), (journal + 36, 8), (journal + 44, 8)]
        return fields.map { ($0.0, $0.1, true) }
    }
}

struct FuzzSeed: Sendable {
    let name: String
    let bytes: [UInt8]
    /// 512-byte blocks holding any non-zero byte: where structure lives.
    let hot: [Int]
    /// 4 KiB blocks whose APFS Fletcher-64 checksum verifies in the seed.
    let apfsBlocks: [Int]
    /// Offsets of exFAT boot sectors.
    let exfatBoots: [Int]
    /// Offsets of 32-byte exFAT entry sets (primary 0x85 or 0x05) in the seed.
    let exfatSets: [Int]
    let hasGPT: Bool

    init(name: String, bytes: [UInt8]) {
        self.name = name; self.bytes = bytes
        var hot: [Int] = [], apfs: [Int] = [], boots: [Int] = [], sets: [Int] = []
        bytes.withUnsafeBufferPointer { buffer in
            let blocks = buffer.count / 512
            for block in 0..<blocks {
                let base = block * 512
                var nonZero = false
                for index in base..<base + 512 where buffer[index] != 0 { nonZero = true; break }
                guard nonZero else { continue }
                hot.append(block)
                if buffer[base + 3] == 0x45, Array(buffer[base + 3..<base + 11]) == Array("EXFAT   ".utf8) { boots.append(base) }
            }
            for block in hot {
                for entry in stride(from: block * 512, to: block * 512 + 512, by: 32) where buffer[entry] & 0x7f == 0x05 {
                    let count = Int(buffer[entry + 1])
                    if (2...17).contains(count), entry + (count + 1) * 32 <= buffer.count, buffer[entry + 32] & 0x7f == 0x40 { sets.append(entry) }
                }
            }
            for block in Set(hot.map { $0 / 8 }).sorted() where (block + 1) * 4096 <= buffer.count {
                if apfsChecksumIsValid(Data(buffer[block * 4096..<(block + 1) * 4096])) { apfs.append(block) }
            }
        }
        if hot.isEmpty { hot = [0] }
        self.hot = hot; apfsBlocks = apfs; exfatBoots = boots; exfatSets = sets
        hasGPT = bytes.count >= 1024 && Array(bytes[512..<520]) == Array("EFI PART".utf8)
    }
}

enum FuzzSeeds {
    /// The deterministic synthetic seeds for `format`, from the existing test builders.
    static func synthetic(_ format: FuzzFormat) -> [(String, Data)] {
        switch format {
        case .fat32:
            var deleted = fatImage(nested: true)
            let root = 552 * 512
            deleted.text(root + 64, "\u{05}ELETED TXT"); deleted[root + 64] = 0xe5
            deleted.put(root + 64 + 11, 0x20, 1); deleted.put(root + 64 + 26, 6, 2); deleted.put(root + 64 + 28, 10, 4)
            deleted.text((552 + 4) * 512, "gone bytes")
            return [("synthetic-nested", fatImage(nested: true)), ("synthetic-deleted", deleted)]
        case .exfat: return [("synthetic", exfatImage()), ("synthetic-deleted", exfatDeleted())]
        case .ntfs: return [("synthetic", FuzzNTFS.standard()), ("synthetic-bare", FuzzNTFS.bare())]
        case .ext2:
            return [("synthetic", ext2Image().image), ("synthetic-deleted", EXTVolumeTests().deletedImage().image)]
        case .ext4:
            var image = EXTImage(ext4: true)
            image.inode(2, directory: true, size: 1024, links: 2, flags: 0x80000, blocks: EXTImage.extentNode([(0, 1, 32)]), used: [32])
            image.directory(32, this: 2, parent: 2, [(12, "flat.txt", 1), (13, "tree.bin", 1)])
            image.inode(12, size: 2000, mtime: 10, flags: 0x80000, blocks: EXTImage.extentNode([(0, 2, 60)]), used: [60, 61], mtimeExtra: 1 | 500 << 2)
            image.inode(13, size: 3 * 1024, flags: 0x80000, blocks: EXTImage.extentIndex([(0, 70)], depth: 1), used: [70, 71, 80, 81])
            image.data.replaceSubrange(70 * 1024..<71 * 1024, with: EXTImage.extentNode([(0, 1, 71), (1, 2, 80)], size: 1024))
            var wide = EXTImage(ext4: true, wide: true)
            wide.inode(2, directory: true, size: 1024, links: 2, flags: 0x80000, blocks: EXTImage.extentNode([(0, 1, 32)]), used: [32])
            wide.directory(32, this: 2, parent: 2, [(17, "far.txt", 1)])
            wide.inode(17, size: 4, flags: 0x80000, blocks: EXTImage.extentNode([(0, 1, 300)]), used: [300])
            return [("synthetic-extents", image.image), ("synthetic-wide", wide.image),
                    ("synthetic-deleted", EXTVolumeTests().deletedImage(ext4: true).image)]
        case .hfsplus:
            let basic = hfsBasic()
            var journaled = basic
            let leaf = journaled.data.subdata(in: (HFSImage.catalogBlock + 1) * 4096..<(HFSImage.catalogBlock + 2) * 4096)
            journaled.journal([[(HFSImage.catalogSector(1), leaf)]])
            var stale = basic
            let records = HFSImage.root() + [stale.file(2, "kept.txt", id: 30, size: 9, extents: [(70, 1)])]
            let gone = HFSImage.key(2, "gone.txt") + HFSImage.file(31, size: 100, extents: [(80, 1)])
            stale.writeNode(tree: HFSImage.catalogBlock, 1, HFSImage.leafNode(records, slack: gone))
            return [("synthetic-basic", basic.image), ("synthetic-journal", journaled.image), ("synthetic-stale", stale.image)]
        case .apfs:
            // The synthetic APFS builder is private to APFSVolumeTests; real hdiutil images are the
            // APFS seeds. This stub (a container superblock signature only) keeps the format covered
            // without hdiutil.
            var stub = Data(repeating: 0, count: 64 * 1024); stub.text(32, "NXSB"); stub.put(36, 4096, 4); stub.put(40, 16, 8)
            stub.put(0, apfsFletcher64(stub.prefix(4096)), 8)
            return [("synthetic-stub", stub)]
        case .mbr:
            var image = Data(repeating: 0, count: 2048 * 512)
            image.replaceSubrange(64 * 512..<192 * 512, with: exfatImage())
            image.replaceSubrange(256 * 512..<1280 * 512, with: ext2Image().image)
            image.replaceSubrange(1408 * 512..<1664 * 512, with: FuzzNTFS.standard())   // unlisted: a lost partition
            image.put(446 + 4, 0x07, 1); image.put(446 + 8, 64, 4); image.put(446 + 12, 128, 4)
            image.put(462 + 4, 0x83, 1); image.put(462 + 8, 256, 4); image.put(462 + 12, 1024, 4)
            image.put(510, 0xaa55, 2)
            return [("synthetic", image)]
        case .gpt:
            var image = Data(repeating: 0, count: 2400 * 512)
            image.replaceSubrange(64 * 512..<192 * 512, with: exfatImage())
            image.replaceSubrange(256 * 512..<2304 * 512, with: hfsBasic(blocks: 256).image)
            image.put(510, 0xaa55, 2); image.put(450, 0xee, 1); image.put(454, 1, 4); image.put(458, 2399, 4)
            var table = Data(repeating: 0, count: 256)
            table.put(0, 1, 1); table.put(16, 1, 1); table.put(32, 64, 8); table.put(40, 191, 8)
            table.put(128, 2, 1); table.put(144, 2, 1); table.put(160, 256, 8); table.put(168, 2303, 8)
            image.replaceSubrange(1024..<1280, with: table)
            var header = Data(repeating: 0, count: 512)
            header.text(0, "EFI PART"); header.put(8, 0x10000, 4); header.put(12, 92, 4)
            header.put(24, 1, 8); header.put(32, 2399, 8); header.put(40, 34, 8); header.put(48, 2365, 8)
            header.put(72, 2, 8); header.put(80, 2, 4); header.put(84, 128, 4)
            header.put(88, UInt64(crc32(table)), 4)
            header.put(16, UInt64(crc32(header.subdata(in: 0..<92))), 4)
            image.replaceSubrange(512..<1024, with: header)
            return [("synthetic", image)]
        }
    }

    static func hfsBasic(blocks: Int = 256) -> HFSImage {
        var image = HFSImage(blocks: blocks)
        image.fill([70, 71, 72])
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
        return image
    }

    /// `exfatImage()` plus a deleted, contiguous `gone.txt` whose cluster is free in the bitmap.
    static func exfatDeleted() -> Data {
        var image = exfatImage()
        let root = 25 * 512, set = root + 128
        var entries = image.subdata(in: root..<root + 96)
        entries[0] = 0x05; entries[32] = 0x40; entries[64] = 0x41
        entries.put(32 + 20, 6, 4); entries.put(32 + 24, 5, 8); entries.put(32 + 8, 5, 8)
        for (index, unit) in "gone.txt".utf16.enumerated() { entries.put(66 + index * 2, UInt64(unit), 2) }
        var sum: UInt16 = 0
        for index in 0..<96 where index != 2 && index != 3 { sum = ((sum & 1) << 15) &+ (sum >> 1) &+ UInt16(entries[index]) }
        entries.put(2, UInt64(sum), 2)
        image.replaceSubrange(set..<set + 96, with: entries)
        image[123 * 512] &= ~UInt8(1 << 4)
        image.text((25 + 4) * 512, "gone!")
        return image
    }

    /// Real images made with hdiutil in a temp dir: attached only while populated (private mount
    /// point, -nobrowse), always detached, and deleted afterwards.
    static func real(_ format: FuzzFormat) throws -> [(String, Data)] {
        switch format {
        case .fat32: return [("real-fat32", try hdiutilImage(fs: "MS-DOS FAT32", sizeMiB: 33, layout: "NONE"))]
        case .exfat: return [("real-exfat", try hdiutilImage(fs: "ExFAT", sizeMiB: 1, layout: "NONE"))]
        case .hfsplus:
            return [("real-hfs", try hdiutilImage(fs: "HFS+", sizeMiB: 1, layout: "NONE")),
                    ("real-hfsj", try hdiutilImage(fs: "HFS+J", sizeMiB: 1, layout: "NONE"))]
        case .apfs: return [("real-apfs", try hdiutilImage(fs: "APFS", sizeMiB: 2, layout: "NONE"))]
        case .mbr: return [("real-mbr-exfat", try hdiutilImage(fs: "ExFAT", sizeMiB: 2, layout: "MBRSPUD"))]
        case .gpt: return [("real-gpt-hfsj", try hdiutilImage(fs: "HFS+J", sizeMiB: 2, layout: "GPTSPUD"))]
        case .ntfs, .ext2, .ext4: return []
        }
    }

    static func hdiutilImage(fs: String, sizeMiB: Int, layout: String) throws -> Data {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("salvage-fuzz-seed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = directory.appendingPathComponent("seed.dmg"), mount = directory.appendingPathComponent("mnt")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        try HDIUtil.run(["create", "-quiet", "-size", "\(sizeMiB)m", "-fs", fs, "-volname", "FUZZ", "-layout", layout, image.path])
        try HDIUtil.run(["attach", "-nobrowse", "-noverify", "-noautofsck", "-mountpoint", mount.path, image.path])
        var failure: (any Error)?
        do {
            let docs = mount.appendingPathComponent("docs/nested")
            try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
            try Data("hello fuzz\n".utf8).write(to: mount.appendingPathComponent("hello.txt"))
            try Data((0..<20_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }).write(to: docs.appendingPathComponent("pattern.bin"))
            try Data(repeating: 0x41, count: 5000).write(to: mount.appendingPathComponent("docs/a.txt"))
            let gone = mount.appendingPathComponent("docs/gone.txt")
            try Data((0..<9000).map { UInt8(truncatingIfNeeded: $0 &* 13) }).write(to: gone)
            sync()
            try FileManager.default.removeItem(at: gone)
            sync()
        } catch { failure = error }
        try HDIUtil.run(["detach", mount.path, "-force"])
        if let failure { throw failure }
        return try Data(contentsOf: image)
    }
}

/// Synthetic NTFS seeds: a compact port of `NTFSImage` in NTFSVolumeTests (private there). 512-byte
/// sectors and clusters, 1 KiB MFT records, 256 sectors.
enum FuzzNTFS {
    static let sector = 512, recordSize = 1024
    static let modified: UInt64 = (1_704_153_600 + 11_644_473_600) * 10_000_000

    static func runList(_ runs: [(Int, Int)]) -> Data {
        func minimal(_ value: Int64, signed: Bool) -> [UInt8] {
            var bytes: [UInt8] = [], v = value
            repeat { bytes.append(UInt8(truncatingIfNeeded: v)); v >>= 8 }
            while signed ? !((v == 0 && bytes.last! & 0x80 == 0) || (v == -1 && bytes.last! & 0x80 != 0)) : v != 0
            return bytes
        }
        var data = Data(), previous: Int64 = 0
        for (lcn, length) in runs {
            let l = minimal(Int64(length), signed: false), o = minimal(Int64(lcn) - previous, signed: true)
            data.append(UInt8(o.count << 4 | l.count)); data.append(contentsOf: l + o); previous = Int64(lcn)
        }
        data.append(0)
        return data
    }
    static func align8(_ value: Int) -> Int { (value + 7) & ~7 }
    static func resident(_ type: UInt32, _ value: Data, name: String = "") -> Data {
        var nameData = Data(); for unit in name.utf16 { nameData.append(UInt8(unit & 0xff)); nameData.append(UInt8(unit >> 8)) }
        let valueOffset = align8(0x18 + nameData.count)
        var a = Data(count: align8(valueOffset + value.count))
        a.put(0, UInt64(type), 4); a.put(4, UInt64(a.count), 4); a.put(9, UInt64(name.utf16.count), 1); a.put(10, 0x18, 2)
        a.replaceSubrange(0x18..<0x18 + nameData.count, with: nameData)
        a.put(0x10, UInt64(value.count), 4); a.put(0x14, UInt64(valueOffset), 2)
        a.replaceSubrange(valueOffset..<valueOffset + value.count, with: value)
        return a
    }
    static func nonResident(_ type: UInt32, _ runs: [(Int, Int)], size: Int) -> Data {
        let list = runList(runs), clusters = runs.reduce(0) { $0 + $1.1 }
        var a = Data(count: align8(0x40 + list.count))
        a.put(0, UInt64(type), 4); a.put(4, UInt64(a.count), 4); a.put(8, 1, 1); a.put(10, 0x40, 2)
        a.put(0x18, UInt64(bitPattern: Int64(clusters - 1)), 8); a.put(0x20, 0x40, 2)
        a.put(0x28, UInt64(clusters * sector), 8); a.put(0x30, UInt64(size), 8); a.put(0x38, UInt64(size), 8)
        a.replaceSubrange(0x40..<0x40 + list.count, with: list)
        return a
    }
    static func standardInformation() -> Data { var value = Data(count: 0x48); value.put(8, modified, 8); return resident(0x10, value) }
    static func fileName(_ name: String, parent: Int, sequence: Int, namespace: UInt8 = 1) -> Data {
        let units = Array(name.utf16)
        var value = Data(count: 0x42 + units.count * 2)
        value.put(0, UInt64(sequence) << 48 | UInt64(parent), 8)
        value.put(0x40, UInt64(units.count), 1); value.put(0x41, UInt64(namespace), 1)
        for (index, unit) in units.enumerated() { value.put(0x42 + index * 2, UInt64(unit), 2) }
        return resident(0x30, value)
    }
    static func record(sequence: Int, flags: Int, _ attributes: [Data]) -> Data {
        var r = Data(count: recordSize)
        r.text(0, "FILE"); r.put(4, 0x30, 2); r.put(6, UInt64(recordSize / 512 + 1), 2)
        r.put(0x10, UInt64(sequence), 2); r.put(0x12, 1, 2); r.put(0x14, 0x38, 2); r.put(0x16, UInt64(flags), 2)
        var offset = 0x38
        for attribute in attributes { r.replaceSubrange(offset..<offset + attribute.count, with: attribute); offset += attribute.count }
        r.put(offset, 0xffff_ffff, 4); offset += 8
        r.put(0x18, UInt64(offset), 4); r.put(0x1c, UInt64(recordSize), 4)
        let usn: UInt64 = 0x4b1d
        r.put(0x30, usn, 2)
        for stride in 1...recordSize / 512 {
            let tail = stride * 512 - 2
            r.put(0x30 + stride * 2, UInt64(r[tail]) | UInt64(r[tail + 1]) << 8, 2); r.put(tail, usn, 2)
        }
        return r
    }
    static func file(_ name: String, parent: Int = 5, parentSequence: Int? = nil, sequence: Int = 1, deleted: Bool = false, data: Data) -> Data {
        record(sequence: sequence, flags: deleted ? 0 : 1,
               [standardInformation(), fileName(name, parent: parent, sequence: parentSequence ?? (parent == 5 ? 5 : 1)), data])
    }
    static func directory(_ name: String, parent: Int = 5, sequence: Int = 1, deleted: Bool = false) -> Data {
        record(sequence: sequence, flags: deleted ? 2 : 3, [standardInformation(), fileName(name, parent: parent, sequence: parent == 5 ? 5 : 1)])
    }
    static func bare() -> Data { build(records: [:], used: []) }
    static func standard() -> Data {
        build(records: [
            16: directory("Documents"),
            17: file("hello.txt", data: resident(0x80, Data("hello".utf8))),
            18: file("report.txt", parent: 16, data: nonResident(0x80, [(150, 2)], size: 700)),
            19: file("deleted.txt", parent: 16, sequence: 2, deleted: true, data: nonResident(0x80, [(160, 1)], size: 100)),
            21: directory("Other", sequence: 3),
            22: file("overwritten.txt", sequence: 2, deleted: true, data: nonResident(0x80, [(170, 1)], size: 50)),
            23: record(sequence: 1, flags: 1, [standardInformation(), fileName("LONGFI~1.TXT", parent: 5, sequence: 5, namespace: 2),
                                               fileName("Long file name.txt", parent: 5, sequence: 5, namespace: 1),
                                               resident(0x80, Data("x".utf8)), resident(0x80, Data(repeating: 7, count: 20), name: "Zone.Identifier")]),
            25: directory("OldDir", sequence: 3, deleted: true),
            26: file("old.txt", parent: 25, parentSequence: 2, sequence: 2, deleted: true, data: nonResident(0x80, [(180, 1), (185, 2)], size: 1200)),
        ], used: [150, 151, 170])
    }
    static func build(records: [Int: Data], used: Set<Int>, clusterCount: Int = 255) -> Data {
        let mft = (lcn: 16, length: 64), bitmapRun = (lcn: 90, length: 1), recordCount = 32
        var image = Data(count: (clusterCount + 1) * sector)
        image.text(3, "NTFS    "); image.put(11, UInt64(sector), 2); image.put(13, 1, 1)
        image.put(0x28, UInt64(clusterCount), 8); image.put(0x30, UInt64(mft.lcn), 8); image.put(0x38, 2, 8)
        image.put(0x40, 0xf6, 1); image.put(0x44, 0xf4, 1); image.put(510, 0xaa55, 2)
        var bitmap = Data(count: (clusterCount + 7) / 8)
        for cluster in Set(0..<91).union(used).union(mft.lcn..<mft.lcn + mft.length) where cluster < clusterCount {
            bitmap[cluster / 8] |= UInt8(1) << (cluster % 8)
        }
        var all = records
        all[5] = record(sequence: 5, flags: 3, [standardInformation(), fileName(".", parent: 5, sequence: 5, namespace: 3),
                                                resident(0x90, Data(count: 16), name: "$I30")])
        all[0] = record(sequence: 1, flags: 1, [standardInformation(), fileName("$MFT", parent: 5, sequence: 5, namespace: 3),
                                                nonResident(0x80, [(mft.lcn, mft.length)], size: recordCount * recordSize)])
        all[6] = record(sequence: 6, flags: 1, [fileName("$Bitmap", parent: 5, sequence: 5, namespace: 3),
                                                nonResident(0x80, [(bitmapRun.lcn, bitmapRun.length)], size: bitmap.count)])
        for (number, bytes) in all {
            let start = mft.lcn * sector + number * recordSize
            image.replaceSubrange(start..<start + recordSize, with: bytes)
        }
        image.replaceSubrange(bitmapRun.lcn * sector..<bitmapRun.lcn * sector + bitmap.count, with: bitmap)
        return image
    }
}

// MARK: - Mutation

/// SplitMix64: tiny, fast, and fully determined by its state.
struct FuzzRNG: RandomNumberGenerator {
    var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9e37_79b9_7f4a_7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        return z ^ (z >> 31)
    }
    mutating func below(_ bound: Int) -> Int { bound <= 1 ? 0 : Int(next() % UInt64(bound)) }
    mutating func chance(_ percent: Int) -> Bool { below(100) < percent }
}

struct FuzzCase {
    let seedIndex: Int
    var bytes: [UInt8]
    var steps: [String]
}

struct FuzzMutator {
    let format: FuzzFormat
    let seeds: [FuzzSeed]
    /// Splice sources: small seeds of every format.
    let donors: [FuzzSeed]
    let runSeed: UInt64

    static let boundaries: [UInt64] = [0, 1, 2, 3, 4, 7, 8, 15, 16, 0x20, 0x3f, 0x40, 0x7f, 0x80, 0xff, 0x100, 0x200, 0x1000, 0x7fff, 0x8000,
                                       0xfffe, 0xffff, 0x10000, 0x7fff_ffff, 0x8000_0000, 0xffff_fffe, 0xffff_ffff, 0x1_0000_0000,
                                       0x7fff_ffff_ffff_ffff, 0x8000_0000_0000_0000, 0xffff_ffff_ffff_fffe, 0xffff_ffff_ffff_ffff]

    func rng(iteration: Int) -> FuzzRNG {
        var mix = FuzzRNG(runSeed ^ UInt64(FuzzFormat.allCases.firstIndex(of: format)! + 1) &* 0xd1b5_4a32_d192_ed03)
        var rng = FuzzRNG(mix.next() ^ UInt64(iteration) &* 0x9e37_79b9_7f4a_7c15)
        _ = rng.next()
        return rng
    }

    func input(iteration: Int) -> FuzzCase {
        var rng = rng(iteration: iteration)
        let seedIndex = rng.below(seeds.count), seed = seeds[seedIndex]
        var bytes = seed.bytes
        var steps = ["seed \(seed.name)"]
        let count = rng.chance(20) ? 4 + rng.below(12) : 1 + rng.below(3)
        var truncated = false
        for _ in 0..<count {
            guard !bytes.isEmpty else { break }
            let roll = rng.below(100)
            switch roll {
            case 0..<18:
                let offset = pick(&rng, seed, bytes.count, width: 1)
                let bit = rng.below(8)
                bytes[offset] ^= UInt8(1 << bit); steps.append("flip \(offset).\(bit)")
            case 18..<36:
                let width = [1, 2, 4, 8][rng.below(4)]
                var offset = pick(&rng, seed, bytes.count, width: width)
                if rng.chance(70) { offset -= offset % width }
                let value = Self.boundaries[rng.below(Self.boundaries.count)]
                let bigEndian = format == .hfsplus ? rng.chance(80) : rng.chance(15)
                write(&bytes, offset, value, width, bigEndian); steps.append("boundary \(offset) w\(width) \(value)")
            case 36..<56:
                let fields = format.fields
                guard !fields.isEmpty else { continue }
                let (offset, width, bigEndian) = fields[rng.below(fields.count)]
                guard offset + width <= bytes.count else { continue }
                let current = read(bytes, offset, width, bigEndian)
                let value: UInt64
                switch rng.below(4) {
                case 0: value = current &+ UInt64(1 + rng.below(4))
                case 1: value = current &- UInt64(1 + rng.below(4))
                case 2: value = rng.next()
                default: value = Self.boundaries[rng.below(Self.boundaries.count)]
                }
                write(&bytes, offset, value, width, bigEndian); steps.append("field \(offset) w\(width) \(value)")
            case 56..<64:
                let length = 1 + rng.below(32), offset = pick(&rng, seed, bytes.count, width: length)
                for index in offset..<min(bytes.count, offset + length) { bytes[index] = UInt8(truncatingIfNeeded: rng.next()) }
                steps.append("random \(offset)+\(length)")
            case 64..<70:
                let width = [1, 2, 4][rng.below(3)], offset = pick(&rng, seed, bytes.count, width: width)
                let delta = UInt64(1 + rng.below(16))
                let current = read(bytes, offset, width, false)
                write(&bytes, offset, rng.chance(50) ? current &+ delta : current &- delta, width, false)
                steps.append("arith \(offset) w\(width)")
            case 70..<75:
                guard !truncated, bytes.count > 512 else { continue }
                truncated = true
                let length: Int
                switch rng.below(3) {
                case 0: length = max(512, seed.hot[rng.below(seed.hot.count)] * 512)
                case 1: length = max(512, (bytes.count - 1 - rng.below(min(bytes.count - 1, 4096))))
                default: length = max(512, rng.below(bytes.count) / 4096 * 4096)
                }
                if length < bytes.count { bytes.removeSubrange(length...) }
                steps.append("truncate \(bytes.count)")
            case 75..<83:
                let size = [512, 1024, 4096][rng.below(3)]
                let from = pick(&rng, seed, bytes.count, width: size) / size * size, to = pick(&rng, seed, bytes.count, width: size) / size * size
                guard from + size <= bytes.count, to + size <= bytes.count else { continue }
                bytes.replaceSubrange(to..<to + size, with: bytes[from..<from + size]); steps.append("duplicate \(from)->\(to)+\(size)")
            case 83..<92:
                guard !donors.isEmpty else { continue }
                let donor = donors[rng.below(donors.count)]
                let size = [32, 64, 512, 4096][rng.below(4)]
                let from = min(donor.hot[rng.below(donor.hot.count)] * 512 + (size < 512 ? rng.below(512 / size) * size : 0),
                               max(0, donor.bytes.count - size))
                let to = rng.chance(50) ? from : pick(&rng, seed, bytes.count, width: size) / min(size, 512) * min(size, 512)
                let length = min(size, donor.bytes.count - from, bytes.count - to)
                guard length > 0 else { continue }
                bytes.replaceSubrange(to..<to + length, with: donor.bytes[from..<from + length])
                steps.append("splice \(donor.name)@\(from)->\(to)+\(length)")
            default:
                let size = [512, 4096][rng.below(2)], offset = pick(&rng, seed, bytes.count, width: size) / size * size
                guard offset < bytes.count else { continue }
                for index in offset..<min(bytes.count, offset + size) { bytes[index] = rng.chance(80) ? 0 : 0xff }
                steps.append("fill \(offset)+\(size)")
            }
        }
        if rng.chance(80) { fixChecksums(&bytes, seed); steps.append("fixup") }
        return FuzzCase(seedIndex: seedIndex, bytes: bytes, steps: steps)
    }

    /// An offset in a block that holds structure in the seed (usually), else anywhere.
    func pick(_ rng: inout FuzzRNG, _ seed: FuzzSeed, _ count: Int, width: Int) -> Int {
        let limit = max(1, count - width + 1)
        if rng.chance(88) {
            let offset = seed.hot[rng.below(seed.hot.count)] * 512 + rng.below(512)
            return min(offset, limit - 1)
        }
        return rng.below(limit)
    }

    func write(_ bytes: inout [UInt8], _ offset: Int, _ value: UInt64, _ width: Int, _ bigEndian: Bool) {
        for index in 0..<width where offset + index < bytes.count {
            let shift = bigEndian ? (width - 1 - index) * 8 : index * 8
            bytes[offset + index] = UInt8(truncatingIfNeeded: value >> UInt64(shift))
        }
    }
    func read(_ bytes: [UInt8], _ offset: Int, _ width: Int, _ bigEndian: Bool) -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<width where offset + index < bytes.count {
            let shift = bigEndian ? (width - 1 - index) * 8 : index * 8
            value |= UInt64(bytes[offset + index]) << UInt64(shift)
        }
        return value
    }

    /// Re-seals the checksums the seed had valid, so mutations reach past them: APFS Fletcher-64
    /// objects, exFAT boot regions and entry sets, and the GPT header and entry array.
    func fixChecksums(_ bytes: inout [UInt8], _ seed: FuzzSeed) {
        for block in seed.apfsBlocks where (block + 1) * 4096 <= bytes.count {
            let checksum = apfsFletcher64(Data(bytes[block * 4096..<(block + 1) * 4096]))
            write(&bytes, block * 4096, checksum, 8, false)
        }
        for boot in seed.exfatBoots where boot + 12 * 512 <= bytes.count {
            var checksum: UInt32 = 0
            for index in 0..<512 * 11 where index != 106 && index != 107 && index != 112 {
                checksum = ((checksum & 1) << 31) &+ (checksum >> 1) &+ UInt32(bytes[boot + index])
            }
            for offset in stride(from: 512 * 11, to: 512 * 12, by: 4) { write(&bytes, boot + offset, UInt64(checksum), 4, false) }
        }
        for set in seed.exfatSets where set + 64 <= bytes.count {
            let length = min((Int(bytes[set + 1]) + 1) * 32, bytes.count - set)
            var checksum: UInt16 = 0
            for index in 0..<length where index != 2 && index != 3 { checksum = ((checksum & 1) << 15) &+ (checksum >> 1) &+ UInt16(bytes[set + index]) }
            write(&bytes, set + 2, UInt64(checksum), 2, false)
        }
        if seed.hasGPT, bytes.count >= 1024 {
            let entries = Int(min(read(bytes, 512 + 80, 4, false), 1024)), size = Int(min(read(bytes, 512 + 84, 4, false), 1024))
            let tableStart = Int(min(read(bytes, 512 + 72, 8, false), 1 << 20)) * 512
            if entries * size > 0, tableStart + entries * size <= bytes.count {
                write(&bytes, 512 + 88, UInt64(crc32(Data(bytes[tableStart..<tableStart + entries * size]))), 4, false)
            }
            let headerSize = Int(min(read(bytes, 512 + 12, 4, false), 512))
            if headerSize >= 20 {
                write(&bytes, 512 + 16, 0, 4, false)
                write(&bytes, 512 + 16, UInt64(crc32(Data(bytes[512..<512 + headerSize]))), 4, false)
            }
        }
    }
}

// MARK: - Running one input

enum FuzzScan {
    /// Runs a full `ScanSession` over `bytes` through an in-memory reader; returns how it ended.
    static func run(_ bytes: Data) async -> String {
        let (events, continuation) = AsyncStream<ScanEvent>.makeStream()
        let (notices, noticeContinuation) = AsyncStream<ScanNotice>.makeStream()
        async let drained: (String, Int) = {
            var outcome = "unfinished", found = 0
            for await event in events {
                switch event {
                case .completed: outcome = "completed"
                case .error(let error): outcome = "error: \(error)"
                case .found: found += 1
                default: break
                }
            }
            return (outcome, found)
        }()
        async let noticeCount: Int = { var count = 0; for await _ in notices { count += 1 }; return count }()
        await ScanSession(reader: ImageReader(data: bytes)).run(events: continuation, notices: noticeContinuation)
        let (outcome, found) = await drained
        return "\(outcome), \(found) found, \(await noticeCount) notices"
    }

    static let maxDonorBytes = 4 << 20

    static func loadSeeds(_ directory: URL, format: FuzzFormat, maxBytes: Int = .max) throws -> [FuzzSeed] {
        let folder = directory.appendingPathComponent("seeds/\(format.rawValue)")
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".img") }.sorted()
        return try names.compactMap { name in
            let url = folder.appendingPathComponent(name)
            let size = (try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
            guard size <= maxBytes else { return nil }
            return FuzzSeed(name: String(name.dropLast(4)), bytes: [UInt8](try Data(contentsOf: url)))
        }
    }

    static func mutator(_ directory: URL, format: FuzzFormat, seed: UInt64) throws -> FuzzMutator {
        let seeds = try loadSeeds(directory, format: format)
        var donors: [FuzzSeed] = []
        for other in FuzzFormat.allCases {
            donors += other == format ? seeds.filter { $0.bytes.count <= maxDonorBytes }
                : (try? loadSeeds(directory, format: other, maxBytes: maxDonorBytes)) ?? []
        }
        return FuzzMutator(format: format, seeds: seeds, donors: donors, runSeed: seed)
    }
}

// MARK: - Driver

struct FuzzFinding: Sendable {
    enum Kind: String, Sendable { case crash, hang }
    let kind: Kind
    let format: FuzzFormat
    let iteration: Int
    let signature: String
    let detail: String
    var folder: String = ""
}

actor FuzzWorkQueue {
    private var items: [(FuzzFormat, Int, Int)]
    init(_ items: [(FuzzFormat, Int, Int)]) { self.items = items.reversed() }
    func next() -> (FuzzFormat, Int, Int)? { items.popLast() }
}

/// The child process command line: this test binary, filtered to `test`.
func fuzzChildArguments(filter: String) -> [String]? {
    var arguments = CommandLine.arguments
    guard arguments.count > 1, arguments.contains("--testing-library") || arguments.contains("--test-bundle-path") else { return nil }
    if let index = arguments.firstIndex(of: "--filter"), index + 1 < arguments.count {
        arguments[index + 1] = filter
        // Drop any further filters or skips so only `filter` runs.
        var cleaned: [String] = [], skip = false
        for (position, argument) in arguments.enumerated() {
            if skip { skip = false; continue }
            if position > index + 1, argument == "--filter" || argument == "--skip" { skip = true; continue }
            cleaned.append(argument)
        }
        return cleaned
    }
    return arguments + ["--filter", filter]
}

final class FuzzFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

struct FuzzChildResult { let crashed: Bool; let hung: Bool; let lastIteration: Int?; let exit: String; let log: String }

/// Runs the worker (or reproducer) in a child process and watches it: a crash is a signal death or
/// an unfinished exit; a hang is an iteration that outlives `budget(iteration)`.
func runFuzzChild(filter: String, environment: [String: String], status: URL, log: URL,
                  budget: @Sendable (Int?) -> Double) async throws -> FuzzChildResult {
    guard let arguments = fuzzChildArguments(filter: filter) else { throw ScanError.io("can't re-invoke the test binary: \(CommandLine.arguments)") }
    try? FileManager.default.removeItem(at: status)
    FileManager.default.createFile(atPath: log.path, contents: nil)
    let handle = try FileHandle(forWritingTo: log)
    defer { try? handle.close() }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: arguments[0])
    process.arguments = Array(arguments.dropFirst())
    var env = ProcessInfo.processInfo.environment
    env["SALVAGE_FUZZ_STATUS"] = status.path
    env["SWIFT_BACKTRACE"] = "enable=yes,interactive=no,color=no,sanitize=no,threads=crashed"
    for (key, value) in environment { env[key] = value }
    process.environment = env
    process.standardOutput = handle; process.standardError = handle
    process.standardInput = FileHandle.nullDevice
    // `waitUntilExit` can block forever on a cooperative thread once the child has gone, so exit is
    // observed through the termination handler instead.
    let exited = FuzzFlag()
    process.terminationHandler = { _ in exited.set() }
    try process.run()
    var current: Int? = nil, since = Date(), hung = false
    func readStatus() -> String? {
        guard let data = try? Data(contentsOf: status) else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    while !exited.isSet {
        try? await Task.sleep(for: .milliseconds(50))
        let text = readStatus()
        let iteration = text.flatMap { Int($0) }
        if iteration != current { current = iteration; since = Date() }
        if text != "done", Date().timeIntervalSince(since) > budget(current) {
            hung = true
            kill(process.processIdentifier, SIGKILL)
            while !exited.isSet { try? await Task.sleep(for: .milliseconds(20)) }
            break
        }
    }
    let finalStatus = readStatus()
    if let value = finalStatus.flatMap({ Int($0) }) { current = value }
    let signalled = process.terminationReason == .uncaughtSignal
    let exit = signalled ? "signal \(process.terminationStatus)" : "exit \(process.terminationStatus)"
    try? handle.synchronize()
    let logText = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
    let crashed = !hung && finalStatus != "done"
    return FuzzChildResult(crashed: crashed, hung: hung, lastIteration: current, exit: exit, log: logText)
}

/// "Fatal error: … @ File.swift:line" from a child's log: the trap message and the first frame in
/// SalvageCore's sources, when the backtracer printed one.
func fuzzCrashSignature(_ log: String) -> String {
    let lines = log.split(separator: "\n").map(String.init)
    let message = lines.first { $0.contains("Fatal error") || $0.contains("Crash:") || $0.contains("Thread ") && $0.contains("crashed") }?
        .trimmingCharacters(in: .whitespaces) ?? "no trap message"
    // Backtrace frames read "N [ra] 0xADDR <function> + off in SalvageCore at /…/Sources/SalvageCore/File.swift:L:C".
    var location = "unknown location"
    for line in lines {
        guard let source = line.range(of: "/Sources/SalvageCore/") else { continue }
        var file = String(line[source.upperBound...].prefix { !$0.isWhitespace })
        if let column = file.lastIndex(of: ":"), file[file.index(after: column)...].allSatisfy(\.isNumber),
           file[..<column].contains(":") { file = String(file[..<column]) }
        var function = ""
        if let address = line.range(of: " 0x"), let end = line.range(of: " in SalvageCore at ") {
            let afterAddress = line[address.upperBound...].drop { !$0.isWhitespace }
            if afterAddress.startIndex < end.lowerBound {
                function = String(line[afterAddress.startIndex..<end.lowerBound]).trimmingCharacters(in: .whitespaces)
                if let plus = function.range(of: " + ", options: .backwards) { function = String(function[..<plus.lowerBound]) }
                if function.count > 120 { function = String(function.prefix(120)) + "…" }
            }
        }
        location = function.isEmpty ? file : "\(function) at \(file)"
        break
    }
    let shortMessage = message.components(separatedBy: "Fatal error: ").last.map { "Fatal error: " + $0 } ?? message
    return "\(shortMessage) @ \(location)"
}

@Suite("Parser fuzzing", .serialized)
struct FuzzTests {
    /// The driver: builds the seeds, fans batches out to child processes, collects crashes and hangs,
    /// minimises each distinct crash and writes `summary.json`.
    @Test(.enabled(if: FuzzConfig.enabled, "set SALVAGE_FUZZ=1 to fuzz the parsers"), .timeLimit(.minutes(24 * 60)))
    func fuzzParsers() async throws {
        let directory = FuzzConfig.directory, seed = FuzzConfig.seed, iterations = FuzzConfig.iterations
        let fm = FileManager.default
        for sub in ["seeds", "crashes", "logs"] { try fm.createDirectory(at: directory.appendingPathComponent(sub), withIntermediateDirectories: true) }
        try? fm.removeItem(at: directory.appendingPathComponent("seeds"))
        // Seeds: synthetic builders always; real hdiutil images where available.
        var realSkipped: [String] = []
        for format in FuzzFormat.allCases {
            let folder = directory.appendingPathComponent("seeds/\(format.rawValue)")
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            var seeds = FuzzSeeds.synthetic(format)
            if FuzzConfig.realImages {
                do { seeds += try FuzzSeeds.real(format) } catch { realSkipped.append("\(format.rawValue): \(error)") }
            }
            for (index, (name, bytes)) in seeds.enumerated() {
                try bytes.write(to: folder.appendingPathComponent(String(format: "%02d-%@.img", index, name)))
            }
        }
        for line in realSkipped { print("FUZZ real seed unavailable: \(line)") }

        let formats = FuzzConfig.formats
        var mutators: [FuzzFormat: FuzzMutator] = [:]
        var largest: [FuzzFormat: Int] = [:]
        for format in formats {
            let mutator = try FuzzScan.mutator(directory, format: format, seed: seed)
            mutators[format] = mutator
            largest[format] = mutator.seeds.map(\.bytes.count).max() ?? 0
            print("FUZZ \(format.rawValue): seeds \(mutator.seeds.map { "\($0.name) (\($0.bytes.count / 1024) KiB)" }.joined(separator: ", "))")
        }
        var work: [(FuzzFormat, Int, Int)] = []
        for start in stride(from: 0, to: iterations, by: FuzzConfig.batch) {
            for format in formats { work.append((format, start, min(iterations, start + FuzzConfig.batch))) }
        }
        let queue = FuzzWorkQueue(work), sizes = largest
        let started = Date()
        let results = await withTaskGroup(of: [FuzzFinding].self) { group in
            for job in 0..<FuzzConfig.jobs {
                group.addTask {
                    var findings: [FuzzFinding] = []
                    while let (format, from, to) = await queue.next() {
                        let size = sizes[format] ?? 0
                        findings += await Self.runBatch(format: format, from: from, to: to, seed: seed, directory: directory, job: job,
                                                        budget: FuzzConfig.hangBase + FuzzConfig.hangPerMiB * Double(size) / 1_048_576)
                    }
                    return findings
                }
            }
            var all: [FuzzFinding] = []
            for await findings in group { all += findings }
            return all
        }
        let elapsed = Date().timeIntervalSince(started)

        // Save inputs, minimise one input per distinct signature, write reproducers.
        var findings = results.sorted { ($0.format.rawValue, $0.iteration) < ($1.format.rawValue, $1.iteration) }
        var minimised = Set<String>()
        for index in findings.indices {
            let finding = findings[index]
            guard let mutator = mutators[finding.format] else { continue }
            let input = mutator.input(iteration: finding.iteration)
            let folder = directory.appendingPathComponent("crashes/\(finding.kind.rawValue)-\(finding.format.rawValue)-\(finding.iteration)")
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let inputURL = folder.appendingPathComponent("input.img")
            try Data(input.bytes).write(to: inputURL)
            var notes = """
            \(finding.kind.rawValue): \(finding.signature)
            format \(finding.format.rawValue), run seed \(seed) (0x\(String(seed, radix: 16))), iteration \(finding.iteration)
            base seed: \(mutator.seeds[input.seedIndex].name)
            mutations: \(input.steps.joined(separator: "; "))
            \(finding.detail)

            Reproduce this input:
              SALVAGE_FUZZ_REPRO=\(inputURL.path) swift test --package-path SalvageCore --filter FuzzTests/fuzzReproduce
            Regenerate it from the seed (needs \(directory.path)/seeds):
              SALVAGE_FUZZ_WORKER=1 SALVAGE_FUZZ_DIR=\(directory.path) SALVAGE_FUZZ_FORMAT=\(finding.format.rawValue) \
            SALVAGE_FUZZ_SEED=\(seed) SALVAGE_FUZZ_FROM=\(finding.iteration) SALVAGE_FUZZ_TO=\(finding.iteration + 1) \
            swift test --package-path SalvageCore --filter FuzzTests/fuzzWorker

            """
            if finding.kind == .crash, FuzzConfig.minimise, minimised.insert(finding.signature).inserted {
                let (bytes, patches) = await Self.minimise(input.bytes, base: mutator.seeds[input.seedIndex].bytes,
                                                           signature: finding.signature, folder: folder)
                let minimisedURL = folder.appendingPathComponent("minimised.img")
                try Data(bytes).write(to: minimisedURL)
                if patches.isEmpty && bytes == input.bytes {
                    notes += "\nNot minimised: the saved input did not trap with the same signature when replayed on its own.\n"
                } else { notes += """

                Minimised against \(mutator.seeds[input.seedIndex].name): length \(bytes.count) (seed \(mutator.seeds[input.seedIndex].bytes.count)), \
                \(patches.count) patch(es):
                \(patches.map { "  offset \($0.0): \($0.1.map { String(format: "%02x", $0) }.joined(separator: " "))" }.joined(separator: "\n"))
                Swift: [\(patches.map { "(\($0.0), [\($0.1.map { String(format: "0x%02x", $0) }.joined(separator: ", "))])" }.joined(separator: ", "))]
                  SALVAGE_FUZZ_REPRO=\(minimisedURL.path) swift test --package-path SalvageCore --filter FuzzTests/fuzzReproduce

                """ }
            }
            try notes.write(to: folder.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
            findings[index].folder = folder.path
        }

        // Summary.
        var summary: [[String: Any]] = []
        for format in formats {
            let mine = findings.filter { $0.format == format }
            let crashes = mine.filter { $0.kind == .crash }, hangs = mine.filter { $0.kind == .hang }
            print("FUZZ-SUMMARY format=\(format.rawValue) iterations=\(iterations) crashes=\(crashes.count) hangs=\(hangs.count) " +
                  "distinct=\(Set(mine.map(\.signature)).count)")
            summary.append(["format": format.rawValue, "iterations": iterations, "crashes": crashes.count, "hangs": hangs.count,
                            "findings": mine.map { ["kind": $0.kind.rawValue, "iteration": $0.iteration, "signature": $0.signature, "folder": $0.folder] }])
        }
        print(String(format: "FUZZ-SUMMARY seed=%llu jobs=%d elapsed=%.0fs dir=%@", seed, FuzzConfig.jobs, elapsed, directory.path))
        let json = try JSONSerialization.data(withJSONObject: ["seed": seed, "iterationsPerFormat": iterations, "elapsedSeconds": elapsed,
                                                               "formats": summary], options: [.prettyPrinted, .sortedKeys])
        try json.write(to: directory.appendingPathComponent("summary.json"))
        var reported = Set<String>()
        for finding in findings where reported.insert(finding.signature).inserted {
            let line = "\(finding.kind.rawValue) in \(finding.format.rawValue) at iteration \(finding.iteration) (seed \(seed)): \(finding.signature) — \(finding.folder)"
            if FuzzConfig.allowed.contains(where: { finding.signature.contains($0) }) { print("FUZZ known (allowed): \(line)") }
            else { Issue.record("\(line)") }
        }
    }

    /// Runs iterations [from, to) of `format` in child processes, restarting after each crash or hang.
    static func runBatch(format: FuzzFormat, from: Int, to: Int, seed: UInt64, directory: URL, job: Int,
                         budget: Double) async -> [FuzzFinding] {
        var findings: [FuzzFinding] = [], next = from
        while next < to {
            let status = directory.appendingPathComponent("logs/status-\(job)")
            let log = directory.appendingPathComponent("logs/\(format.rawValue)-\(next).log")
            let result: FuzzChildResult
            do {
                result = try await runFuzzChild(filter: "FuzzTests/fuzzWorker", environment: [
                    "SALVAGE_FUZZ_WORKER": "1", "SALVAGE_FUZZ_DIR": directory.path, "SALVAGE_FUZZ_FORMAT": format.rawValue,
                    "SALVAGE_FUZZ_SEED": String(seed), "SALVAGE_FUZZ_FROM": String(next), "SALVAGE_FUZZ_TO": String(to),
                ], status: status, log: log, budget: { $0 == nil ? max(120, budget) : budget })
            } catch {
                Issue.record("fuzz worker for \(format.rawValue) at \(next) could not run: \(error)")
                return findings
            }
            if !result.crashed && !result.hung { try? FileManager.default.removeItem(at: log); break }
            guard let iteration = result.lastIteration, iteration >= next else {
                Issue.record("fuzz worker for \(format.rawValue) at \(next) failed before its first iteration (\(result.exit)): \(result.log.suffix(2000))")
                return findings
            }
            let signature = result.hung ? "hang (over \(Int(budget))s)" : fuzzCrashSignature(result.log)
            findings.append(FuzzFinding(kind: result.hung ? .hang : .crash, format: format, iteration: iteration, signature: signature,
                                        detail: "\(result.exit); log \(log.path)"))
            print("FUZZ \(result.hung ? "hang" : "crash") \(format.rawValue) iteration \(iteration): \(signature)")
            next = iteration + 1
        }
        return findings
    }

    /// Greedy minimisation: restores seed bytes run by run (then byte by byte inside short runs)
    /// while the input still crashes with the same signature. Returns the input and its patches.
    static func minimise(_ input: [UInt8], base: [UInt8], signature: String, folder: URL) async -> ([UInt8], [(Int, [UInt8])]) {
        var current = input, attempts = 0
        let candidateURL = folder.appendingPathComponent("candidate.img")
        func crashes(_ candidate: [UInt8]) async -> Bool {
            attempts += 1
            guard attempts <= 400, (try? Data(candidate).write(to: candidateURL)) != nil,
                  let result = try? await runFuzzChild(filter: "FuzzTests/fuzzReproduce", environment: ["SALVAGE_FUZZ_REPRO": candidateURL.path],
                                                       status: folder.appendingPathComponent("status"),
                                                       log: folder.appendingPathComponent("minimise.log"), budget: { _ in 300 })
            else { return false }
            return result.crashed && fuzzCrashSignature(result.log) == signature
        }
        // An input that doesn't trap on its own (e.g. state left by an earlier iteration) is kept whole.
        guard await crashes(current) else { return (current, []) }
        if current.count < base.count {
            let restored = current + base[current.count...]
            if await crashes(restored) { current = restored }
        }
        func runs(_ bytes: [UInt8]) -> [Range<Int>] {
            var result: [Range<Int>] = [], start: Int? = nil, gap = 0
            for index in 0..<min(bytes.count, base.count) {
                if bytes[index] != base[index] {
                    if start == nil { start = index }
                    gap = 0
                } else if let s = start {
                    gap += 1
                    if gap > 4 { result.append(s..<index - gap + 1); start = nil; gap = 0 }
                }
            }
            if let s = start { result.append(s..<min(bytes.count, base.count) - gap) }
            return result
        }
        for run in runs(current).reversed() {
            var candidate = current
            candidate.replaceSubrange(run, with: base[run])
            if await crashes(candidate) { current = candidate }
        }
        for run in runs(current) where run.count > 1 && run.count <= 64 {
            for index in run where current[index] != base[index] {
                var candidate = current
                candidate[index] = base[index]
                if await crashes(candidate) { current = candidate }
            }
        }
        try? FileManager.default.removeItem(at: candidateURL)
        let patches = runs(current).map { ($0.lowerBound, Array(current[$0])) }
        return (current, patches)
    }

    /// One batch in a child process: writes each iteration number to the status file before
    /// scanning it, so the parent knows which input trapped or hung.
    @Test(.enabled(if: FuzzConfig.isWorker, "child process of fuzzParsers"))
    func fuzzWorker() async throws {
        let env = FuzzConfig.env
        let directory = URL(fileURLWithPath: try #require(env["SALVAGE_FUZZ_DIR"]))
        let format = try #require(FuzzFormat(rawValue: env["SALVAGE_FUZZ_FORMAT"] ?? ""))
        let from = try #require(Int(env["SALVAGE_FUZZ_FROM"] ?? "")), to = try #require(Int(env["SALVAGE_FUZZ_TO"] ?? ""))
        let mutator = try FuzzScan.mutator(directory, format: format, seed: FuzzConfig.seed)
        let status = env["SALVAGE_FUZZ_STATUS"].map { open($0, O_WRONLY | O_CREAT | O_TRUNC, 0o644) } ?? -1
        defer { if status >= 0 { close(status) } }
        func mark(_ text: String) {
            guard status >= 0 else { return }
            let line = Array(text.utf8) + Array(repeating: UInt8(ascii: " "), count: max(0, 23 - text.utf8.count)) + [10]
            _ = line.withUnsafeBytes { pwrite(status, $0.baseAddress, $0.count, 0) }
        }
        for iteration in from..<to {
            mark(String(iteration))
            // Harness self-test: SALVAGE_FUZZ_INJECT_CRASH / _HANG=<format>:<iteration> trap or spin there.
            if env["SALVAGE_FUZZ_INJECT_CRASH"] == "\(format.rawValue):\(iteration)" { fatalError("injected fuzz crash") }
            if env["SALVAGE_FUZZ_INJECT_HANG"] == "\(format.rawValue):\(iteration)" { while true { usleep(100_000) } }
            let input = mutator.input(iteration: iteration)
            let outcome = await FuzzScan.run(Data(input.bytes))
            if env["SALVAGE_FUZZ_VERBOSE"] == "1" { print("FUZZ \(format.rawValue) \(iteration): \(outcome) [\(input.steps.joined(separator: "; "))]") }
        }
        mark("done")
    }

    /// Scans one saved input (`SALVAGE_FUZZ_REPRO=<path>`).
    @Test(.enabled(if: FuzzConfig.reproPath != nil, "set SALVAGE_FUZZ_REPRO=<input> to replay one fuzz input"))
    func fuzzReproduce() async throws {
        let path = try #require(FuzzConfig.reproPath)
        let status = FuzzConfig.env["SALVAGE_FUZZ_STATUS"]
        if let status { try "0".write(toFile: status, atomically: false, encoding: .utf8) }
        let outcome = await FuzzScan.run(try Data(contentsOf: URL(fileURLWithPath: path)))
        print("FUZZ reproduce \(path): \(outcome)")
        if let status { try "done".write(toFile: status, atomically: false, encoding: .utf8) }
    }

    /// The mutator is a pure function of (run seed, format, iteration), so a reported iteration can be
    /// regenerated exactly; and every synthetic seed scans cleanly before it is mutated.
    @Test func mutatorIsDeterministicAndSeedsScan() async throws {
        for format in FuzzFormat.allCases {
            // FAT32's 32 MiB seeds are left to the opt-in run; scanning them in a debug build takes seconds.
            let seeds = FuzzSeeds.synthetic(format).filter { $0.1.count <= FuzzScan.maxDonorBytes }
                .map { FuzzSeed(name: $0.0, bytes: [UInt8]($0.1)) }
            guard !seeds.isEmpty else { continue }
            let mutator = FuzzMutator(format: format, seeds: seeds, donors: seeds, runSeed: 7)
            for iteration in [0, 1, 99] {
                let a = mutator.input(iteration: iteration), b = mutator.input(iteration: iteration)
                #expect(a.bytes == b.bytes && a.steps == b.steps)
            }
            #expect(mutator.input(iteration: 0).steps != mutator.input(iteration: 1).steps)
            for seed in seeds {
                let outcome = await FuzzScan.run(Data(seed.bytes))
                // The APFS stub is only a signature; it must end, not complete.
                #expect(format == .apfs ? !outcome.hasPrefix("unfinished") : outcome.hasPrefix("completed"), "\(format.rawValue) \(seed.name): \(outcome)")
            }
        }
    }
}
