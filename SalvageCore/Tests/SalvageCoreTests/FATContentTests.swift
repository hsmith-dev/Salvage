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
/// The entry goes in slot `slot` of the directory whose first byte is at `directory` (the root by
/// default); a directory entry (`attributes` 0x10) records size 0.
private func fatFile(_ image: inout Data, entryAt slot: Int, name: String, clusters: [Int], bytes: Data,
                     deleted: Bool = false, attributes: UInt8 = 0x20, directory: Int = fatHeap) {
    var entry = Data(repeating: 0, count: 32)
    entry.text(0, name); entry[11] = attributes
    let first = UInt32(clusters.first ?? 0)
    entry.put(20, UInt64(first >> 16), 2); entry.put(26, UInt64(first & 0xffff), 2)
    entry.put(28, attributes & 0x10 != 0 ? 0 : UInt64(bytes.count), 4)
    if deleted { entry[0] = 0xe5 }
    image.replaceSubrange(directory + slot * 32..<directory + (slot + 1) * 32, with: entry)
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
/// across `clusters` and, when FAT-chained, the chain recorded in the FAT. `directory` places the
/// set in another directory's cluster instead; `attributes` 0x10 makes it a directory entry.
private func exfatFile(_ image: inout Data, slot: Int, name: String, clusters: [Int], bytes: Data,
                       valid: Int? = nil, noFatChain: Bool, deleted: Bool = false,
                       attributes: UInt64 = 0x20, directory: Int = exHeap) {
    var set = Data(repeating: 0, count: 96)
    set[0] = 0x85; set[1] = 2; set.put(4, attributes, 2)
    set[32] = 0xc0; set[33] = noFatChain ? 3 : 1; set[35] = UInt8(name.utf16.count)
    set.put(40, UInt64(valid ?? bytes.count), 8); set.put(52, UInt64(clusters.first ?? 0), 4); set.put(56, UInt64(bytes.count), 8)
    set[64] = 0xc1
    for (index, unit) in name.utf16.enumerated() { set.put(66 + index * 2, UInt64(unit), 2) }
    var sum: UInt16 = 0
    for index in 0..<96 where index != 2 && index != 3 { sum = ((sum & 1) << 15) &+ (sum >> 1) &+ UInt16(set[index]) }
    set.put(2, UInt64(sum), 2)
    if deleted { for offset in [0, 32, 64] { set[offset] &= 0x7f } }
    image.replaceSubrange(directory + slot * 32..<directory + slot * 32 + 96, with: set)
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

    // MARK: FAT32 per-file damage

    @Test func FAT32ChainRunningPastItsSizeIntoAnotherFileKeepsBoth() async throws {
        var image = fatImage(nested: false)
        // TAIL.BIN's chain runs past its size into HELLO.TXT (found earlier); LEAD.BIN's runs past its
        // size into LATE.BIN (found later). Each file's own bytes are intact, so all four are kept and
        // the file whose clusters were run into, or whose chain ran on, is flagged suspect.
        let tail = pattern(300, seed: 41), lead = pattern(400, seed: 43), late = pattern(100, seed: 47)
        fatFile(&image, entryAt: 1, name: "TAIL    BIN", clusters: [10], bytes: tail)
        image.put(fatTable + 10 * 4, 3, 4)
        fatFile(&image, entryAt: 2, name: "LEAD    BIN", clusters: [20], bytes: lead)
        fatFile(&image, entryAt: 3, name: "LATE    BIN", clusters: [30], bytes: late)
        image.put(fatTable + 20 * 4, 30, 4)
        let result = await scanFATVolume(image)
        #expect(result.error == nil)
        #expect(result.names == ["HELLO.TXT", "TAIL.BIN", "LEAD.BIN", "LATE.BIN"])
        for (name, bytes) in [("HELLO.TXT", Data("hello".utf8)), ("TAIL.BIN", tail), ("LEAD.BIN", lead), ("LATE.BIN", late)] {
            #expect(try await readBack(image, named(result.files, name)) == bytes)
        }
        #expect(try named(result.files, "TAIL.BIN").content == .runs([DataRun(deviceOffset: Int64(fatCluster(10)), length: 300)]))
        #expect(result.skippedCount == 2)
        #expect(result.skipped("/HELLO.TXT", "(/TAIL.BIN) runs past its size into this file's clusters"))
        #expect(result.skipped("/LEAD.BIN", "runs past its size into /LATE.BIN"))
        #expect((await scan(image)).last == .completed)
    }
    @Test func FAT32DamagedFileAmongGoodSiblingsIsSkipped() async throws {
        var image = fatImage(nested: false)
        let after = pattern(200, seed: 53)
        // LOOP.BIN needs three clusters but its chain loops after two.
        fatFile(&image, entryAt: 1, name: "LOOP    BIN", clusters: [10, 11], bytes: pattern(1500, seed: 51))
        image.put(fatHeap + 32 + 28, 1500, 4); image.put(fatTable + 11 * 4, 10, 4)
        fatFile(&image, entryAt: 2, name: "AFTER   BIN", clusters: [20], bytes: after)
        // SHORT.BIN's chain ends a cluster early; ZERO.BIN has a size but no first cluster.
        fatFile(&image, entryAt: 3, name: "SHORT   BIN", clusters: [30, 31], bytes: pattern(1000, seed: 55))
        image.put(fatTable + 30 * 4, 0x0fffffff, 4)
        fatFile(&image, entryAt: 4, name: "ZERO    BIN", clusters: [], bytes: Data())
        image.put(fatHeap + 4 * 32 + 28, 10, 4)
        // SHARE.BIN claims AFTER.BIN's cluster: the later owner is skipped.
        fatFile(&image, entryAt: 5, name: "SHARE   BIN", clusters: [20], bytes: Data())
        image.put(fatHeap + 5 * 32 + 28, 50, 4)
        let result = await scanFATVolume(image)
        #expect(result.error == nil && result.names == ["HELLO.TXT", "AFTER.BIN"])
        #expect(try await readBack(image, named(result.files, "AFTER.BIN")) == after)
        #expect(result.skipped("/LOOP.BIN", "Allocation cycle"))
        #expect(result.skipped("/SHORT.BIN", "Truncated file allocation"))
        #expect(result.skipped("/ZERO.BIN", "Invalid cluster"))
        #expect(result.skipped("/SHARE.BIN", "Cross-linked allocations with /AFTER.BIN"))
        #expect(result.skipped("/AFTER.BIN", "cross-link with /SHARE.BIN"))
        #expect(result.skippedCount == 5)
        #expect((await scan(image)).last == .completed)
    }
    @Test func FAT32BrokenSubdirectoryIsSkippedWithItsSubtree() async throws {
        var image = fatImage()   // HELLO.TXT, FOLDER/NESTED.TXT
        // BROKEN's chain loops on itself; its file must not be found.
        fatFile(&image, entryAt: 2, name: "BROKEN     ", clusters: [30], bytes: Data(), attributes: 0x10)
        image.put(fatTable + 30 * 4, 30, 4)
        fatFile(&image, entryAt: 0, name: "LOST    TXT", clusters: [31], bytes: Data("lost".utf8), directory: fatCluster(30))
        // SHARED points back at the root directory.
        fatFile(&image, entryAt: 3, name: "SHARED     ", clusters: [], bytes: Data(), attributes: 0x10)
        image.put(fatHeap + 3 * 32 + 26, 2, 2)
        // GOOD, a later sibling, is read in full.
        fatFile(&image, entryAt: 4, name: "GOOD       ", clusters: [40], bytes: Data(), attributes: 0x10)
        fatFile(&image, entryAt: 0, name: "INNER   TXT", clusters: [41], bytes: Data("inner".utf8), directory: fatCluster(40))
        let result = await scanFATVolume(image)
        #expect(result.error == nil)
        #expect(Set(result.files.map(\.path)) == ["/HELLO.TXT", "/FOLDER/NESTED.TXT", "/GOOD/INNER.TXT"])
        #expect(try await readBack(image, named(result.files, "INNER.TXT")) == Data("inner".utf8))
        #expect(result.skipped("/BROKEN", "Directory skipped with its contents: Allocation cycle"))
        #expect(result.skipped("/SHARED", "Directory skipped with its contents: Directory cycle or shared directory"))
        #expect(result.skippedCount == 2)
        #expect((await scan(image)).last == .completed)
    }

    // MARK: exFAT per-file damage

    @Test func exFATChainRunningPastItsSizeIntoAnotherFileKeepsBoth() async throws {
        var image = exfatImage()
        let tail = pattern(300, seed: 61), lead = pattern(400, seed: 63), late = pattern(100, seed: 67)
        // tail.bin's chain runs past its size into file.txt's contiguous cluster 3.
        exfatFile(&image, slot: 4, name: "tail.bin", clusters: [10], bytes: tail, noFatChain: false)
        image.put(exTable + 10 * 4, 3, 4)
        exfatFile(&image, slot: 7, name: "lead.bin", clusters: [20], bytes: lead, noFatChain: false)
        exfatFile(&image, slot: 10, name: "late.bin", clusters: [30], bytes: late, noFatChain: false)
        image.put(exTable + 20 * 4, 30, 4)
        let result = await scanFATVolume(image)
        #expect(result.error == nil)
        #expect(result.names == ["file.txt", "tail.bin", "lead.bin", "late.bin"])
        for (name, bytes) in [("file.txt", Data("hello".utf8)), ("tail.bin", tail), ("lead.bin", lead), ("late.bin", late)] {
            #expect(try await readBack(image, named(result.files, name)) == bytes)
        }
        #expect(result.skippedCount == 2)
        #expect(result.skipped("/file.txt", "(/tail.bin) runs past its size into this file's clusters"))
        #expect(result.skipped("/lead.bin", "runs past its size into /late.bin"))
        #expect((await scan(image)).last == .completed)
    }
    @Test func exFATDamagedFileAmongGoodSiblingsIsSkipped() async throws {
        var image = exfatImage()
        let after = pattern(200, seed: 73)
        // over.bin (contiguous, later) overlaps after.bin's cluster 20. Write it first so after.bin's
        // bytes are what cluster 20 holds.
        exfatFile(&image, slot: 10, name: "over.bin", clusters: [20, 21], bytes: pattern(1000, seed: 75), noFatChain: true)
        exfatFile(&image, slot: 4, name: "loop.bin", clusters: [10, 11], bytes: pattern(1500, seed: 71), noFatChain: false)
        image.put(exTable + 11 * 4, 10, 4)
        exfatFile(&image, slot: 7, name: "after.bin", clusters: [20], bytes: after, noFatChain: false)
        let result = await scanFATVolume(image)
        #expect(result.error == nil && result.names == ["file.txt", "after.bin"])
        #expect(try await readBack(image, named(result.files, "after.bin")) == after)
        #expect(result.skipped("/loop.bin", "Allocation cycle"))
        #expect(result.skipped("/over.bin", "Cross-linked allocations with /after.bin"))
        #expect(result.skipped("/after.bin", "cross-link with /over.bin"))
        #expect(result.skippedCount == 3)
        #expect((await scan(image)).last == .completed)
    }
    @Test func exFATBrokenSubdirectoryIsSkippedWithItsSubtree() async throws {
        var image = exfatImage()
        // broken needs three clusters but its chain loops after two; its file must not be found.
        exfatFile(&image, slot: 4, name: "broken", clusters: [30, 31], bytes: Data(count: 1536), noFatChain: false, attributes: 0x10)
        image.put(exTable + 31 * 4, 30, 4)
        exfatFile(&image, slot: 0, name: "lost.txt", clusters: [32], bytes: Data("lost".utf8), noFatChain: true, directory: exCluster(30))
        // good, a later sibling, is read in full.
        exfatFile(&image, slot: 7, name: "good", clusters: [40], bytes: Data(count: 512), noFatChain: true, attributes: 0x10)
        exfatFile(&image, slot: 0, name: "inner.txt", clusters: [41], bytes: Data("inner".utf8), noFatChain: false, directory: exCluster(40))
        // badsize's entry set is valid but its size is not a whole number of clusters.
        exfatFile(&image, slot: 10, name: "badsize", clusters: [50], bytes: Data(count: 100), noFatChain: true, attributes: 0x10)
        let result = await scanFATVolume(image)
        #expect(result.error == nil)
        #expect(Set(result.files.map(\.path)) == ["/file.txt", "/good/inner.txt"])
        #expect(try await readBack(image, named(result.files, "inner.txt")) == Data("inner".utf8))
        #expect(result.skipped("/broken", "Directory skipped with its contents: Allocation cycle"))
        #expect(result.skipped("/badsize", "Directory skipped with its contents: Invalid exFAT directory size"))
        #expect(result.skippedCount == 2)
        #expect((await scan(image)).last == .completed)
    }
    @Test func skipRecordsAreCappedButAllCounted() async {
        let volume = FATVolume(reader: ImageReader(data: Data()), extent: VolumeExtent(offset: 0, length: 0), emit: { _ in })
        for index in 0..<(FATVolume.maxSkippedRecords + 5) { await volume.record("/f\(index)", "Allocation cycle.") }
        #expect(await volume.skipped.count == FATVolume.maxSkippedRecords)
        #expect(await volume.skippedCount == FATVolume.maxSkippedRecords + 5)
        #expect(await volume.skipped.last?.path == "/f\(FATVolume.maxSkippedRecords - 1)")
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
