import Foundation
import Testing
@testable import SalvageCore

// Content mapping for FAT32 and exFAT, read back through `FileContentReader`. Fixtures are the
// shared `fatImage`/`exfatImage` from ScanSessionTests.swift. FAT32: 512-byte clusters, heap (and
// root, cluster 2) at sector 552, FAT at sector 32, clusters 6+ free. exFAT: 512-byte clusters,
// heap (and root, cluster 2) at sector 25, FAT at sector 24, bitmap on cluster 100 with every
// cluster marked allocated, root entries 0-3 used (file.txt and the bitmap).

private let fatHeap = 552 * 512
private let fatTable = 32 * 512
private let exHeap = 25 * 512
private let exTable = 24 * 512
private let exBitmap = 123 * 512

private actor Collected {
    var files: [RecoveredFile] = []
    func add(_ file: RecoveredFile) { files.append(file) }
}
/// Scans the volume at `offset` inside `image` directly, so device-absolute offsets can be checked.
private func files(_ image: Data, volumeAt offset: Int64 = 0) async throws -> [RecoveredFile] {
    let reader = ImageReader(data: image), collected = Collected()
    try await FATVolume(reader: reader, extent: VolumeExtent(offset: offset, length: reader.sizeBytes - offset),
                        localTimeZone: TimeZone(identifier: "UTC")!, emit: { await collected.add($0) }).scan()
    return await collected.files
}
private func readBack(_ image: Data, _ file: RecoveredFile) async throws -> Data {
    try await FileContentReader(reader: ImageReader(data: image), chunkSize: 512).prefix(of: file, limit: .max)
}
private func pattern(_ count: Int, seed: UInt8) -> Data {
    Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) })
}
private func named(_ files: [RecoveredFile], _ name: String) throws -> RecoveredFile {
    try #require(files.first { $0.name == name })
}

// MARK: FAT32 builders

private func fatCluster(_ cluster: Int) -> Int { fatHeap + (cluster - 2) * 512 }
/// Chains `clusters` in the FAT (last one end-of-chain) and writes `bytes` across them in order.
private func fatFile(_ image: inout Data, entryAt slot: Int, name: String, clusters: [Int], bytes: Data,
                     deleted: Bool = false) {
    var entry = Data(repeating: 0, count: 32)
    entry.text(0, name); entry[11] = 0x20
    let first = UInt32(clusters.first ?? 0)
    entry.put(20, UInt64(first >> 16), 2); entry.put(26, UInt64(first & 0xffff), 2); entry.put(28, UInt64(bytes.count), 4)
    if deleted { entry[0] = 0xe5 }
    image.replaceSubrange(fatHeap + slot * 32..<fatHeap + (slot + 1) * 32, with: entry)
    for (index, cluster) in clusters.enumerated() {
        if !deleted {
            let next = index + 1 < clusters.count ? UInt64(clusters[index + 1]) : 0x0fffffff
            image.put(fatTable + cluster * 4, next, 4)
        }
        let piece = bytes.dropFirst(index * 512).prefix(512)
        image.replaceSubrange(fatCluster(cluster)..<fatCluster(cluster) + piece.count, with: piece)
    }
}

// MARK: exFAT builders

private func exCluster(_ cluster: Int) -> Int { exHeap + (cluster - 2) * 512 }
/// A live or deleted 3-entry file set in root slot `slot` (4, 7, 10 or 13), with its data written
/// across `clusters` and, when FAT-chained, the chain recorded in the FAT.
private func exfatFile(_ image: inout Data, slot: Int, name: String, clusters: [Int], bytes: Data,
                       valid: Int? = nil, noFatChain: Bool, deleted: Bool = false) {
    var set = Data(repeating: 0, count: 96)
    set[0] = 0x85; set[1] = 2; set.put(4, 0x20, 2)
    set[32] = 0xc0; set[33] = noFatChain ? 3 : 1; set[35] = UInt8(name.utf16.count)
    set.put(40, UInt64(valid ?? bytes.count), 8); set.put(52, UInt64(clusters.first ?? 0), 4); set.put(56, UInt64(bytes.count), 8)
    set[64] = 0xc1
    for (index, unit) in name.utf16.enumerated() { set.put(66 + index * 2, UInt64(unit), 2) }
    var sum: UInt16 = 0
    for index in 0..<96 where index != 2 && index != 3 { sum = ((sum & 1) << 15) &+ (sum >> 1) &+ UInt16(set[index]) }
    set.put(2, UInt64(sum), 2)
    if deleted { for offset in [0, 32, 64] { set[offset] &= 0x7f } }
    image.replaceSubrange(exHeap + slot * 32..<exHeap + slot * 32 + 96, with: set)
    for (index, cluster) in clusters.enumerated() {
        if !noFatChain && !deleted {
            let next = index + 1 < clusters.count ? UInt64(clusters[index + 1]) : 0xffffffff
            image.put(exTable + cluster * 4, next, 4)
        }
        if deleted { image[exBitmap + (cluster - 2) / 8] &= ~(UInt8(1) << UInt8((cluster - 2) % 8)) }
        let piece = bytes.dropFirst(index * 512).prefix(512)
        image.replaceSubrange(exCluster(cluster)..<exCluster(cluster) + piece.count, with: piece)
    }
}

@Suite("FAT32 and exFAT content mapping")
struct FATContentTests {
    // MARK: FAT32

    @Test func FAT32FixtureFilesReadBack() async throws {
        let image = fatImage()
        let found = try await files(image)
        #expect(try named(found, "HELLO.TXT").content == .runs([DataRun(deviceOffset: Int64(fatCluster(3)), length: 5)]))
        #expect(try await readBack(image, named(found, "HELLO.TXT")) == Data("hello".utf8))
        #expect(try await readBack(image, named(found, "NESTED.TXT")) == Data("abc".utf8))
    }
    @Test func FAT32ContiguousChainIsOneRun() async throws {
        var image = fatImage(nested: false)
        let bytes = pattern(1300, seed: 1)
        fatFile(&image, entryAt: 1, name: "BIG     BIN", clusters: [10, 11, 12], bytes: bytes)
        let file = try named(try await files(image), "BIG.BIN")
        #expect(file.content == .runs([DataRun(deviceOffset: Int64(fatCluster(10)), length: 1300)]))
        #expect(try await readBack(image, file) == bytes)
    }
    @Test func FAT32FragmentedChainKeepsFileOrderAndCoalescesNeighbours() async throws {
        var image = fatImage(nested: false)
        let bytes = pattern(2000, seed: 7)
        // 30 precedes 20 on disk but follows it in the file; 20,21 coalesce, 40 stands alone.
        fatFile(&image, entryAt: 1, name: "FRAG    BIN", clusters: [30, 20, 21, 40], bytes: bytes)
        let file = try named(try await files(image), "FRAG.BIN")
        #expect(file.content == .runs([
            DataRun(deviceOffset: Int64(fatCluster(30)), length: 512),
            DataRun(deviceOffset: Int64(fatCluster(20)), length: 1024),
            DataRun(deviceOffset: Int64(fatCluster(40)), length: 464),
        ]))
        #expect(try await readBack(image, file) == bytes)
    }
    @Test func FAT32ClustersChainedPastTheSizeAreNotMapped() async throws {
        var image = fatImage(nested: false)
        let bytes = pattern(600, seed: 3)
        fatFile(&image, entryAt: 1, name: "LONG    BIN", clusters: [50, 51], bytes: bytes)
        image.put(fatTable + 51 * 4, 60, 4); image.put(fatTable + 60 * 4, 0x0fffffff, 4)
        let file = try named(try await files(image), "LONG.BIN")
        #expect(file.content == .runs([DataRun(deviceOffset: Int64(fatCluster(50)), length: 600)]))
        #expect(try await readBack(image, file) == bytes)
    }
    @Test func FAT32EmptyFileHasNoRuns() async throws {
        var image = fatImage(nested: false)
        fatFile(&image, entryAt: 1, name: "EMPTY   TXT", clusters: [], bytes: Data())
        let file = try named(try await files(image), "EMPTY.TXT")
        #expect(file.content == .runs([]))
        #expect(try await readBack(image, file) == Data())
    }
    @Test func FAT32DeletedFileMapsItsValidatedContiguousRun() async throws {
        var image = fatImage(nested: false)
        let bytes = pattern(700, seed: 9)
        fatFile(&image, entryAt: 1, name: "GONE    BIN", clusters: [70, 71], bytes: bytes, deleted: true)
        let file = try named(try await files(image), "_ONE.BIN")
        #expect(file.isDeleted)
        #expect(file.content == .runs([DataRun(deviceOffset: Int64(fatCluster(70)), length: 700)]))
        #expect(try await readBack(image, file) == bytes)
    }
    @Test func FAT32DeletedEmptyFileHasNoRuns() async throws {
        var image = fatImage(nested: false)
        fatFile(&image, entryAt: 1, name: "NONE    TXT", clusters: [], bytes: Data(), deleted: true)
        let file = try named(try await files(image), "_ONE.TXT")
        #expect(file.isDeleted && file.content == .runs([]))
        #expect(try await readBack(image, file) == Data())
    }
    @Test func FAT32RunsAreDeviceAbsoluteInsideAPartition() async throws {
        var volume = fatImage(nested: false)
        let bytes = pattern(900, seed: 5)
        fatFile(&volume, entryAt: 1, name: "PART    BIN", clusters: [80, 82], bytes: bytes)
        let lead = 2048 * 512
        let image = Data(repeating: 0xee, count: lead) + volume
        let found = try await files(image, volumeAt: Int64(lead))
        let file = try named(found, "PART.BIN")
        #expect(file.content == .runs([
            DataRun(deviceOffset: Int64(lead + fatCluster(80)), length: 512),
            DataRun(deviceOffset: Int64(lead + fatCluster(82)), length: 388),
        ]))
        #expect(try await readBack(image, file) == bytes)
        #expect(try await readBack(image, named(found, "HELLO.TXT")) == Data("hello".utf8))
    }

    // MARK: exFAT

    @Test func exFATNoFatChainFileIsOneContiguousRun() async throws {
        var image = exfatImage()
        let bytes = pattern(1500, seed: 11)
        // The FAT is left empty for these clusters: NoFatChain must not consult it.
        exfatFile(&image, slot: 4, name: "flat.bin", clusters: [20, 21, 22], bytes: bytes, noFatChain: true)
        let found = try await files(image)
        let file = try named(found, "flat.bin")
        #expect(file.content == .runs([DataRun(deviceOffset: Int64(exCluster(20)), length: 1500)]))
        #expect(try await readBack(image, file) == bytes)
        #expect(try await readBack(image, named(found, "file.txt")) == Data("hello".utf8))
    }
    @Test func exFATFatChainedFragmentedFileFollowsTheChain() async throws {
        var image = exfatImage()
        let bytes = pattern(1400, seed: 13)
        exfatFile(&image, slot: 4, name: "frag.bin", clusters: [45, 40, 41], bytes: bytes, noFatChain: false)
        let file = try named(try await files(image), "frag.bin")
        #expect(file.content == .runs([
            DataRun(deviceOffset: Int64(exCluster(45)), length: 512),
            DataRun(deviceOffset: Int64(exCluster(40)), length: 888),
        ]))
        #expect(try await readBack(image, file) == bytes)
    }
    @Test func exFATBytesPastValidDataLengthReadAsZeros() async throws {
        var image = exfatImage()
        let bytes = pattern(1000, seed: 17)
        exfatFile(&image, slot: 4, name: "vdl.bin", clusters: [50, 51], bytes: bytes, valid: 300, noFatChain: true)
        let file = try named(try await files(image), "vdl.bin")
        #expect(file.content == .runs([
            DataRun(deviceOffset: Int64(exCluster(50)), length: 300),
            DataRun(deviceOffset: nil, length: 700),
        ]))
        #expect(try await readBack(image, file) == bytes.prefix(300) + Data(count: 700))
    }
    @Test func exFATEmptyFileHasNoRuns() async throws {
        var image = exfatImage()
        exfatFile(&image, slot: 4, name: "empty.txt", clusters: [], bytes: Data(), noFatChain: false)
        let file = try named(try await files(image), "empty.txt")
        #expect(file.content == .runs([]))
        #expect(try await readBack(image, file) == Data())
    }
    @Test func exFATDeletedFileMapsItsValidatedContiguousRun() async throws {
        var image = exfatImage()
        let bytes = pattern(1100, seed: 19)
        exfatFile(&image, slot: 4, name: "gone.bin", clusters: [60, 61, 62], bytes: bytes, noFatChain: true, deleted: true)
        let file = try named(try await files(image), "gone.bin")
        #expect(file.isDeleted)
        #expect(file.content == .runs([DataRun(deviceOffset: Int64(exCluster(60)), length: 1100)]))
        #expect(try await readBack(image, file) == bytes)
    }
    @Test func exFATDeletedFileWithShortValidDataLengthEndsInAHole() async throws {
        var image = exfatImage()
        let bytes = pattern(800, seed: 23)
        exfatFile(&image, slot: 4, name: "half.bin", clusters: [70, 71], bytes: bytes, valid: 512,
                  noFatChain: true, deleted: true)
        let file = try named(try await files(image), "half.bin")
        #expect(file.content == .runs([
            DataRun(deviceOffset: Int64(exCluster(70)), length: 512),
            DataRun(deviceOffset: nil, length: 288),
        ]))
        #expect(try await readBack(image, file) == bytes.prefix(512) + Data(count: 288))
    }
    @Test func exFATRunsAreDeviceAbsoluteInsideAPartition() async throws {
        var volume = exfatImage()
        let bytes = pattern(1024, seed: 29)
        exfatFile(&volume, slot: 4, name: "part.bin", clusters: [30, 32], bytes: bytes, noFatChain: false)
        let lead = 64 * 512
        let image = Data(repeating: 0xee, count: lead) + volume
        let file = try named(try await files(image, volumeAt: Int64(lead)), "part.bin")
        #expect(file.content == .runs([
            DataRun(deviceOffset: Int64(lead + exCluster(30)), length: 512),
            DataRun(deviceOffset: Int64(lead + exCluster(32)), length: 512),
        ]))
        #expect(try await readBack(image, file) == bytes)
    }
}
