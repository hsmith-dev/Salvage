import Foundation
import Testing
@testable import SalvageCore

// Synthetic NTFS images: 512-byte sectors and clusters, 1 KiB MFT records (encoded as -10), 256
// sectors total. Records are built field by field from the on-disk layout, then fixed up.

private let sector = 512, recordSize = 1024
/// 2024-01-02 00:00:00 UTC as FILETIME.
private let modifiedFiletime: UInt64 = (1_704_153_600 + 11_644_473_600) * 10_000_000

private enum Run { case at(Int, Int), sparse(Int) }

private func runList(_ runs: [Run]) -> Data {
    func minimal(_ value: Int64, signed: Bool) -> [UInt8] {
        var bytes: [UInt8] = []
        var v = value
        repeat {
            bytes.append(UInt8(truncatingIfNeeded: v)); v >>= 8
        } while signed ? !((v == 0 && bytes.last! & 0x80 == 0) || (v == -1 && bytes.last! & 0x80 != 0)) : v != 0
        return bytes
    }
    var data = Data(), previous: Int64 = 0
    for run in runs {
        switch run {
        case .at(let lcn, let length):
            let l = minimal(Int64(length), signed: false), o = minimal(Int64(lcn) - previous, signed: true)
            data.append(UInt8(o.count << 4 | l.count)); data.append(contentsOf: l + o); previous = Int64(lcn)
        case .sparse(let length):
            let l = minimal(Int64(length), signed: false)
            data.append(UInt8(l.count)); data.append(contentsOf: l)
        }
    }
    data.append(0)
    return data
}

private func align8(_ value: Int) -> Int { (value + 7) & ~7 }

private func attributeName(_ name: String) -> Data {
    var data = Data(); for unit in name.utf16 { data.append(UInt8(unit & 0xff)); data.append(UInt8(unit >> 8)) }
    return data
}

private func resident(_ type: UInt32, _ value: Data, name: String = "") -> Data {
    let nameData = attributeName(name)
    let valueOffset = align8(0x18 + nameData.count)
    var a = Data(count: align8(valueOffset + value.count))
    a.put(0, UInt64(type), 4); a.put(4, UInt64(a.count), 4); a.put(8, 0, 1)
    a.put(9, UInt64(name.utf16.count), 1); a.put(10, 0x18, 2)
    a.replaceSubrange(0x18..<0x18 + nameData.count, with: nameData)
    a.put(0x10, UInt64(value.count), 4); a.put(0x14, UInt64(valueOffset), 2)
    a.replaceSubrange(valueOffset..<valueOffset + value.count, with: value)
    return a
}

private func nonResident(_ type: UInt32, runs: Data, clusters: Int, size: Int, allocated: Int? = nil,
                         initialized: Int? = nil, name: String = "", flags: Int = 0) -> Data {
    let nameData = attributeName(name)
    let runsOffset = align8(0x40 + nameData.count)
    var a = Data(count: align8(runsOffset + runs.count))
    a.put(0, UInt64(type), 4); a.put(4, UInt64(a.count), 4); a.put(8, 1, 1)
    a.put(9, UInt64(name.utf16.count), 1); a.put(10, 0x40, 2); a.put(12, UInt64(flags), 2)
    a.replaceSubrange(0x40..<0x40 + nameData.count, with: nameData)
    a.put(0x10, 0, 8); a.put(0x18, UInt64(bitPattern: Int64(clusters - 1)), 8); a.put(0x20, UInt64(runsOffset), 2)
    a.put(0x28, UInt64(allocated ?? clusters * sector), 8); a.put(0x30, UInt64(size), 8)
    a.put(0x38, UInt64(initialized ?? size), 8)
    a.replaceSubrange(runsOffset..<runsOffset + runs.count, with: runs)
    return a
}

private func nonResident(_ type: UInt32, _ runs: [Run], size: Int, allocated: Int? = nil, initialized: Int? = nil,
                         flags: Int = 0) -> Data {
    let clusters = runs.reduce(0) { total, run in
        switch run { case .at(_, let length), .sparse(let length): total + length }
    }
    return nonResident(type, runs: runList(runs), clusters: clusters, size: size, allocated: allocated,
                       initialized: initialized, flags: flags)
}

private func standardInformation(_ modified: UInt64 = modifiedFiletime) -> Data {
    var value = Data(count: 0x48); value.put(8, modified, 8)
    return resident(0x10, value)
}

private func fileName(_ name: String, parent: Int, sequence: Int, namespace: UInt8 = 1, units raw: [UInt16]? = nil) -> Data {
    let units = raw ?? Array(name.utf16)
    var value = Data(count: 0x42 + units.count * 2)
    value.put(0, UInt64(sequence) << 48 | UInt64(parent), 8)
    value.put(0x40, UInt64(units.count), 1); value.put(0x41, UInt64(namespace), 1)
    for (index, unit) in units.enumerated() { value.put(0x42 + index * 2, UInt64(unit), 2) }
    return resident(0x30, value)
}

private func record(sequence: Int, flags: Int, base: UInt64 = 0, _ attributes: [Data]) -> Data {
    var r = Data(count: recordSize)
    r.text(0, "FILE"); r.put(4, 0x30, 2); r.put(6, UInt64(recordSize / 512 + 1), 2)
    r.put(0x10, UInt64(sequence), 2); r.put(0x12, 1, 2); r.put(0x14, 0x38, 2); r.put(0x16, UInt64(flags), 2)
    var offset = 0x38
    for attribute in attributes { r.replaceSubrange(offset..<offset + attribute.count, with: attribute); offset += attribute.count }
    r.put(offset, 0xffff_ffff, 4); offset += 8
    r.put(0x18, UInt64(offset), 4); r.put(0x1c, UInt64(recordSize), 4); r.put(0x20, base, 8)
    let usn: UInt64 = 0x4b1d
    r.put(0x30, usn, 2)
    for stride in 1...recordSize / 512 {
        let tail = stride * 512 - 2
        r.put(0x30 + stride * 2, UInt64(r[tail]) | UInt64(r[tail + 1]) << 8, 2); r.put(tail, usn, 2)
    }
    return r
}

private func file(_ name: String, parent: Int = 5, parentSequence: Int? = nil, sequence: Int = 1, deleted: Bool = false,
                  data: Data) -> Data {
    record(sequence: sequence, flags: deleted ? 0 : 1,
           [standardInformation(), fileName(name, parent: parent, sequence: parentSequence ?? (parent == 5 ? 5 : 1)), data])
}

private func directory(_ name: String, parent: Int = 5, parentSequence: Int? = nil, sequence: Int = 1, deleted: Bool = false) -> Data {
    record(sequence: sequence, flags: deleted ? 2 : 3,
           [standardInformation(), fileName(name, parent: parent, sequence: parentSequence ?? (parent == 5 ? 5 : 1))])
}

private struct NTFSImage {
    var mftRuns: [(lcn: Int, length: Int)] = [(16, 64)]
    var recordCount = 32
    var records: [Int: Data] = [:]
    /// Clusters marked allocated in `$Bitmap` beyond the system area (0..<91, the MFT and `$Bitmap`).
    var used: Set<Int> = [150, 151, 170]
    /// The boot sector's total sectors (one sector per cluster); the image holds one more sector.
    var clusterCount = 255
    /// Where a non-resident `$Bitmap` (record 6, unless a test supplies its own) lives.
    var bitmapRuns: [(lcn: Int, length: Int)] = [(90, 1)]
    var residentBitmap = false
    /// `$Bitmap`'s initialized size when smaller than its real size. Bits past it are still set in the image.
    var bitmapInitialized: Int?

    /// Just the root directory and `$Bitmap`.
    static func bare() -> NTFSImage {
        var image = NTFSImage()
        image.used = []
        image.records[5] = record(sequence: 5, flags: 3, [standardInformation(), fileName(".", parent: 5, sequence: 5, namespace: 3),
                                                         resident(0x90, Data(count: 16), name: "$I30")])
        return image
    }

    static func standard() -> NTFSImage {
        var image = bare()
        image.used = [150, 151, 170]
        image.records[16] = directory("Documents")
        image.records[17] = file("hello.txt", data: resident(0x80, Data("hello".utf8)))
        image.records[18] = file("report.txt", parent: 16, data: nonResident(0x80, [.at(150, 2)], size: 700))
        image.records[19] = file("deleted.txt", parent: 16, sequence: 2, deleted: true, data: nonResident(0x80, [.at(160, 1)], size: 100))
        // The deleted file's parent record now holds a different directory (sequence 3, not 1).
        image.records[20] = file("reused.txt", parent: 21, parentSequence: 1, sequence: 2, deleted: true,
                                 data: resident(0x80, Data("r".utf8)))
        image.records[21] = directory("Other", sequence: 3)
        image.records[22] = file("overwritten.txt", sequence: 2, deleted: true, data: nonResident(0x80, [.at(170, 1)], size: 50))
        image.records[23] = record(sequence: 1, flags: 1, [
            standardInformation(), fileName("LONGFI~1.TXT", parent: 5, sequence: 5, namespace: 2),
            fileName("Long file name.txt", parent: 5, sequence: 5, namespace: 1),
            resident(0x80, Data("x".utf8)), resident(0x80, Data(repeating: 7, count: 20), name: "Zone.Identifier")])
        image.records[24] = file("$Secret", data: resident(0x80, Data("s".utf8)))
        // A deleted directory's sequence was bumped on deletion; its deleted child still holds the old one.
        image.records[25] = directory("OldDir", sequence: 3, deleted: true)
        image.records[26] = file("old.txt", parent: 25, parentSequence: 2, sequence: 2, deleted: true,
                                 data: nonResident(0x80, [.at(180, 1), .at(185, 2)], size: 1200))
        return image
    }

    func build() -> Data {
        var image = Data(count: (clusterCount + 1) * sector)
        image.text(3, "NTFS    "); image.put(11, UInt64(sector), 2); image.put(13, 1, 1)
        image.put(0x28, UInt64(clusterCount), 8); image.put(0x30, UInt64(mftRuns[0].lcn), 8); image.put(0x38, 2, 8)
        image.put(0x40, 0xf6, 1); image.put(0x44, 0xf4, 1); image.put(510, 0xaa55, 2)
        var bitmap = Data(count: (clusterCount + 7) / 8)
        var marked = Set(0..<91).union(used)
        for run in mftRuns + (residentBitmap ? [] : bitmapRuns) { marked.formUnion(run.lcn..<run.lcn + run.length) }
        for cluster in marked where cluster < clusterCount { bitmap[cluster / 8] |= UInt8(1) << (cluster % 8) }
        var all = records
        all[0] = all[0] ?? record(sequence: 1, flags: 1, [
            standardInformation(), fileName("$MFT", parent: 5, sequence: 5, namespace: 3),
            nonResident(0x80, mftRuns.map { .at($0.lcn, $0.length) }, size: recordCount * recordSize)])
        all[6] = all[6] ?? record(sequence: 6, flags: 1, [
            fileName("$Bitmap", parent: 5, sequence: 5, namespace: 3),
            residentBitmap ? resident(0x80, bitmap)
                : nonResident(0x80, bitmapRuns.map { .at($0.lcn, $0.length) }, size: bitmap.count, initialized: bitmapInitialized)])
        for (number, bytes) in all {
            for index in 0..<recordSize {
                let mftByte = number * recordSize + index
                var cluster = mftByte / sector, located: Int?
                for run in mftRuns {
                    if cluster < run.length { located = run.lcn + cluster; break }
                    cluster -= run.length
                }
                image[located! * sector + mftByte % sector] = bytes[index]
            }
        }
        if !residentBitmap {
            for (index, byte) in bitmap.enumerated() {
                var cluster = index / sector, located: Int?
                for run in bitmapRuns {
                    if cluster < run.length { located = run.lcn + cluster; break }
                    cluster -= run.length
                }
                image[located! * sector + index % sector] = byte
            }
        }
        return image
    }
}

private func files(_ events: [ScanEvent]) -> [RecoveredFile] {
    events.compactMap { if case .found(let file) = $0 { file } else { nil } }
}
private func isMalformed(_ events: [ScanEvent]) -> Bool {
    events.contains { if case .error(.malformed) = $0 { true } else { false } } && !events.contains(.completed)
}
/// Drives `NTFSVolume` directly (no discovery or session) so tests can read its work counters.
private actor Collected {
    var files: [RecoveredFile] = []
    func add(_ file: RecoveredFile) { files.append(file) }
}
private func scanVolume(_ image: Data, budget: Int64? = nil) async -> (files: [RecoveredFile], error: ScanError?, checks: Int) {
    let collected = Collected()
    let volume = NTFSVolume(reader: ImageReader(data: image), extent: VolumeExtent(offset: 0, length: Int64(image.count), format: .ntfs),
                            emit: { await collected.add($0) })
    if let budget { await volume.limitDeletedChecks(to: budget) }
    var failure: ScanError?
    do { try await volume.scan() } catch { failure = error as? ScanError ?? .malformed("\(error)") }
    return (await collected.files, failure, await volume.bitmapChecks)
}
/// A volume of 73,728 clusters: past 64K, with an 18-page `$Bitmap` split across two runs.
private func largeImage() -> NTFSImage {
    var image = NTFSImage.bare()
    image.clusterCount = 72 * 1024
    image.bitmapRuns = [(500, 10), (600, 8)]
    return image
}
private func deletedFile(_ name: String, _ runs: [Run], size: Int? = nil) -> Data {
    let clusters = runs.reduce(0) { total, run in
        switch run { case .at(_, let length), .sparse(let length): total + length }
    }
    return file(name, sequence: 2, deleted: true, data: nonResident(0x80, runs, size: size ?? clusters * sector))
}
private func geometry(_ image: Data) throws -> NTFSGeometry {
    try NTFSGeometry(boot: image.prefix(512), volumeLength: Int64(image.count))
}

private extension Data {
    /// Location of MFT record `number` in an image with the default contiguous MFT at cluster 16.
    static func recordOffset(_ number: Int) -> Int { 16 * sector + number * recordSize }
}

@Suite("NTFS scanning")
struct NTFSVolumeTests {
    @Test func liveAndDeletedFilesStreamWithPathsSizesAndTimes() async {
        let image = NTFSImage.standard().build(), original = image
        let events = await scan(image)
        #expect(events.last == .completed)
        let found = files(events)
        #expect(found.map(\.path) == ["/hello.txt", "/Documents/report.txt", "/Documents/deleted.txt",
                                      "/Orphaned Files/reused.txt", "/Long file name.txt", "/OldDir/old.txt"])
        #expect(found.map(\.sizeBytes) == [5, 700, 100, 1, 1, 1200])
        #expect(found.map(\.isDeleted) == [false, false, true, true, false, true])
        #expect(found.allSatisfy { $0.modified == Date(timeIntervalSince1970: 1_704_153_600) })
        let report = found[1].sourceMetadata
        #expect(report.filesystem == .ntfs && report.volumeOffset == 0)
        #expect(report.recordOffset == Int64(Data.recordOffset(18)) && report.allocationStart == 18)
        #expect(report.contiguous && report.rawRecord.count == recordSize)
        // The raw record is fixed up: stride tails hold the original bytes, not the sequence number.
        #expect(report.rawRecord[510] == 0 && report.rawRecord[511] == 0)
        #expect(!found[0].sourceMetadata.contiguous && !found[5].sourceMetadata.contiguous)
        #expect(image == original)
    }

    @Test func deletedFileWhoseClustersWereReusedIsNotEmitted() async {
        let events = await scan(NTFSImage.standard().build())
        #expect(!files(events).contains { $0.name == "overwritten.txt" })
        var free = NTFSImage.standard(); free.used.remove(170)
        #expect(files(await scan(free.build())).contains { $0.path == "/overwritten.txt" && $0.isDeleted })
        // One reused cluster in a multi-run file is enough to skip it.
        var partial = NTFSImage.standard(); partial.used.insert(186)
        #expect(!files(await scan(partial.build())).contains { $0.name == "old.txt" })
    }

    @Test func fragmentedMFTKeepsEveryRecordReachable() async {
        var image = NTFSImage.standard()
        // 21 clusters then 43: record 10 straddles the two runs, records 16+ live in the second.
        image.mftRuns = [(16, 21), (100, 43)]
        let events = await scan(image.build())
        #expect(events.last == .completed)
        let found = files(events)
        #expect(found.count == 6)
        #expect(found.first { $0.name == "report.txt" }?.sourceMetadata.recordOffset == Int64(115 * sector))
    }

    @Test func damagedInUseRecordFailsAfterEarlierDiscoveries() async {
        var model = NTFSImage.standard()
        model.records[30] = file("late.txt", data: resident(0x80, Data("l".utf8)))
        var image = model.build()
        image[Data.recordOffset(30) + 1022] ^= 0xff
        let events = await scan(image)
        #expect(isMalformed(events))
        #expect(files(events).count == 6)
        // The same damage on a deleted record is skipped silently.
        var deleted = NTFSImage.standard().build()
        deleted[Data.recordOffset(19) + 510] ^= 0xff
        let skipped = await scan(deleted)
        #expect(skipped.last == .completed)
        #expect(!files(skipped).contains { $0.name == "deleted.txt" })
    }

    @Test func damagedInUseDirectoryStopsItsChildrenRatherThanOrphaningThem() async {
        // The child precedes its damaged parent in MFT order, so pass 2 meets it via the parent chain.
        var model = NTFSImage.standard()
        model.records[27] = file("child.txt", parent: 28, data: resident(0x80, Data("c".utf8)))
        model.records[28] = directory("Late")
        var image = model.build()
        image[Data.recordOffset(28) + 1022] ^= 0xff
        let events = await scan(image)
        #expect(isMalformed(events))
        #expect(files(events).count == 6)
        #expect(!files(events).contains { $0.name == "child.txt" })
    }

    @Test(arguments: ["signature", "bytes per sector", "sectors per cluster", "total sectors", "mft cluster",
                      "record size", "record size exponent", "mft record"])
    func corruptBootSectorOrMFTIsAnExplicitError(_ damage: String) async {
        var image = NTFSImage.standard().build()
        switch damage {
        case "signature": image.put(510, 0, 2)
        case "bytes per sector": image.put(11, 768, 2)
        case "sectors per cluster": image.put(13, 3, 1)
        case "total sectors": image.put(0x28, 10_000, 8)
        case "mft cluster": image.put(0x30, 255, 8)
        case "record size": image.put(0x40, 0, 1)
        case "record size exponent": image.put(0x40, 0xe0, 1)
        default: image.text(Data.recordOffset(0), "BAAD")
        }
        #expect(isMalformed(await scan(image)))
    }

    @Test func boundaryEncodingsAreDecoded() throws {
        func boot(_ configure: (inout Data) -> Void) -> Data {
            var b = Data(count: 512)
            b.text(3, "NTFS    "); b.put(11, 512, 2); b.put(13, 8, 1); b.put(0x28, 1 << 20, 8)
            b.put(0x30, 4, 8); b.put(0x40, 0xf6, 1); b.put(510, 0xaa55, 2)
            configure(&b); return b
        }
        let length: Int64 = 1 << 40
        // 0xF8 encodes 2^8 sectors per cluster: 128 KiB clusters, beyond the direct-count range.
        let large = try NTFSGeometry(boot: boot { $0.put(13, 0xf8, 1) }, volumeLength: length)
        #expect(large.clusterBytes == 128 * 1024 && large.clusterCount == (1 << 20) / 256)
        #expect(try NTFSGeometry(boot: boot { _ in }, volumeLength: length).recordBytes == 1024)
        #expect(try NTFSGeometry(boot: boot { $0.put(0x40, 1, 1) }, volumeLength: length).recordBytes == 4096)
        #expect(try NTFSGeometry(boot: boot { $0.put(11, 4096, 2); $0.put(13, 1, 1) }, volumeLength: length).clusterBytes == 4096)
        for bad in [boot { $0.put(13, 0xf3, 1) }, boot { $0.put(13, 0, 1) }, boot { $0.put(11, 8192, 2) },
                    boot { $0.put(0x40, 0x7f, 1) }, boot { $0.text(3, "NTFX    ") }] {
            #expect(throws: ScanError.self) { try NTFSGeometry(boot: bad, volumeLength: length) }
        }
        #expect(throws: ScanError.self) { try NTFSGeometry(boot: boot { _ in }, volumeLength: 512) }
    }

    @Test(arguments: ["outside volume", "overflowing length", "vcn mismatch", "overlapping runs", "directory cycle"])
    func runListAndParentChainDamageTerminates(_ damage: String) async {
        var image = NTFSImage.standard()
        switch damage {
        case "outside volume":
            image.records[18] = file("report.txt", parent: 16, data: nonResident(0x80, [.at(250, 10)], size: 700))
        case "overflowing length":
            var runs = Data([0x18]); runs.append(contentsOf: [UInt8](repeating: 0xff, count: 7) + [0x7f, 0x01, 0x00])
            image.records[18] = file("report.txt", parent: 16, data: nonResident(0x80, runs: runs, clusters: 2, size: 700))
        case "vcn mismatch":
            image.records[18] = file("report.txt", parent: 16,
                                     data: nonResident(0x80, runs: runList([.at(150, 2)]), clusters: 3, size: 700))
        case "overlapping runs":
            image.records[18] = file("report.txt", parent: 16, data: nonResident(0x80, [.at(150, 4), .at(152, 2)], size: 700))
        default:
            image.records[27] = directory("A", parent: 28)
            image.records[28] = directory("B", parent: 27)
            image.records[29] = file("looped.txt", parent: 27, data: resident(0x80, Data("c".utf8)))
        }
        #expect(isMalformed(await scan(image.build())))
    }

    @Test func multipleStreamsSparseCompressedAndAttributeLists() async {
        var image = NTFSImage.standard()
        // A sparse, compressed file: correct metadata, not contiguous.
        image.records[27] = file("sparse.bin", data: nonResident(0x80, [.at(190, 1), .sparse(3)], size: 2000, flags: 0x8001))
        // The unnamed stream continues in an extension record listed by $ATTRIBUTE_LIST: skipped.
        image.records[28] = record(sequence: 1, flags: 1, [
            standardInformation(), resident(0x20, Data(count: 32)), fileName("split.bin", parent: 5, sequence: 5),
            nonResident(0x80, [.at(200, 2)], size: 4000, allocated: 8 * sector)])
        // An extension record is never a file by itself.
        image.records[29] = record(sequence: 1, flags: 1, base: 28, [nonResident(0x80, [.at(210, 1)], size: 10)])
        let events = await scan(image.build())
        #expect(events.last == .completed)
        let found = files(events)
        #expect(found.first { $0.name == "sparse.bin" }.map { $0.sizeBytes == 2000 && !$0.sourceMetadata.contiguous } == true)
        #expect(found.first { $0.name == "Long file name.txt" }?.sizeBytes == 1)
        #expect(!found.contains { $0.name == "split.bin" || $0.name == "LONGFI~1.TXT" || $0.name.hasPrefix("$") })
        #expect(found.count == 7)
    }

    @Test func undecodableNamesAreSkippedButAMissingNameIsDamage() async {
        var image = NTFSImage.standard()
        image.records[27] = record(sequence: 1, flags: 1, [
            standardInformation(), fileName("", parent: 5, sequence: 5, units: [0xd800, 0x41]), resident(0x80, Data("u".utf8))])
        let events = await scan(image.build())
        #expect(events.last == .completed && files(events).count == 6)
        image.records[27] = record(sequence: 1, flags: 1, [standardInformation(), resident(0x80, Data("u".utf8))])
        #expect(isMalformed(await scan(image.build())))
    }

    @Test func systemMetafilesAndTheirSubtreesAreSkipped() async {
        var image = NTFSImage.standard()
        image.records[27] = file("$Quota", parent: 11, parentSequence: 11, data: resident(0x80, Data("q".utf8)))
        image.records[28] = directory("$RECYCLE.BIN")
        image.records[29] = file("$R1.txt", parent: 28, data: resident(0x80, Data("r".utf8)))
        let found = files(await scan(image.build()))
        #expect(!found.contains { $0.name == "$Quota" || $0.name == "$Secret" })
        // Only root-level `$` names are metafiles; a user file inside $RECYCLE.BIN stays recoverable.
        #expect(found.contains { $0.path == "/$RECYCLE.BIN/$R1.txt" })
    }

    @Test func NTFSRoutesThroughDiscoveryWholeDiskAndPartitioned() async {
        let volume = NTFSImage.standard().build()
        let whole = await scan(volume)
        #expect(whole.last == .completed && files(whole).count == 6)
        var image = Data(count: 512) + volume
        image.put(446+4, 7, 1); image.put(446+8, 1, 4); image.put(446+12, UInt64(volume.count / 512), 4); image.put(510, 0xaa55, 2)
        let partitioned = await scan(image)
        #expect(partitioned.last == .completed)
        #expect(partitioned.contains(.progress(bytesScanned: Int64(volume.count), totalBytes: Int64(volume.count))))
        let found = files(partitioned)
        #expect(found.count == 6 && found.allSatisfy { $0.sourceMetadata.volumeOffset == 512 })
        #expect(found.first?.sourceMetadata.recordOffset == Int64(512 + Data.recordOffset(17)))
    }

    @Test func fixupDetectsEveryStrideAndAppliesToIndexBuffers() {
        var buffer = Data(count: 4096)
        buffer.text(0, "INDX"); buffer.put(4, 0x28, 2); buffer.put(6, 9, 2); buffer.put(0x28, 0x0102, 2)
        for stride in 1...8 { buffer.put(0x28 + stride * 2, UInt64(stride), 2); buffer.put(stride * 512 - 2, 0x0102, 2) }
        var fixed = buffer
        #expect(applyNTFSFixup(&fixed))
        #expect((1...8).allSatisfy { fixed[$0 * 512 - 2] == UInt8($0) && fixed[$0 * 512 - 1] == 0 })
        var torn = buffer; torn[7 * 512 - 1] = 0
        #expect(!applyNTFSFixup(&torn))
        var miscounted = buffer; miscounted.put(6, 4, 2)
        #expect(!applyNTFSFixup(&miscounted))
    }

    // MARK: - Review patches

    /// P1: a last VCN of Int64.max used to trap on `lastVCN + 1`. One at the cluster count is out of range too.
    @Test(arguments: [Int64.max, 255, -2])
    func outOfRangeLastVCNIsSkippedWhenDeletedAndMalformedWhenLive(_ lastVCN: Int64) async {
        func crafted(_ lcn: Int) -> Data {
            var a = nonResident(0x80, [.at(lcn, 1)], size: 100); a.put(0x18, UInt64(bitPattern: lastVCN), 8); return a
        }
        var deleted = NTFSImage.standard()
        deleted.records[19] = file("deleted.txt", parent: 16, sequence: 2, deleted: true, data: crafted(160))
        let events = await scan(deleted.build())
        #expect(events.last == .completed)
        #expect(files(events).count == 5 && !files(events).contains { $0.name == "deleted.txt" })
        var live = NTFSImage.standard()
        live.records[18] = file("report.txt", parent: 16, data: crafted(150))
        #expect(isMalformed(await scan(live.build())))
    }

    /// P2: free bits are tested a 64-bit word at a time, so a 60,000-cluster run costs ~940 lookups, not 60,000.
    @Test func deletedClusterCheckTestsWholeWordsOfTheBitmap() async {
        var image = largeImage()
        image.records[16] = deletedFile("huge.bin", [.at(1024, 60000)])
        image.records[17] = deletedFile("unaligned.bin", [.at(62001, 77)])
        image.records[18] = deletedFile("tail-used.bin", [.at(64000, 5000)])
        image.used = [68999]
        let result = await scanVolume(image.build())
        #expect(result.error == nil)
        #expect(result.files.map(\.name) == ["huge.bin", "unaligned.bin"])
        #expect(result.checks < 1100)
    }

    /// P2/P3: many deleted records claiming most of the volume finish without walking the bitmap.
    @Test func manyHugeDeletedRecordsFinishWithinBoundedWork() async {
        var image = largeImage()
        image.mftRuns = [(16, 400)]; image.recordCount = 200
        image.bitmapRuns = [(450, 18)]
        for number in 16..<200 { image.records[number] = deletedFile("huge\(number).bin", [.at(1000, 70000)]) }
        let result = await scanVolume(image.build())
        #expect(result.error == nil && result.files.isEmpty && result.checks == 0)
    }

    /// P2: once a candidate doesn't fit the remaining budget, every later deleted candidate is skipped.
    @Test func deletedCandidatesStopOnceTheCheckBudgetIsSpent() async {
        var image = NTFSImage.standard()
        image.records[27] = deletedFile("small.bin", [.at(200, 1)])
        let unlimited = await scanVolume(image.build())
        #expect(unlimited.files.contains { $0.name == "small.bin" } && unlimited.files.contains { $0.name == "old.txt" })
        // deleted.txt (1) and overwritten.txt (1) fit in 3; old.txt (3) doesn't, so small.bin (1) is skipped too.
        let limited = await scanVolume(image.build(), budget: 3)
        #expect(limited.error == nil)
        #expect(limited.files.filter(\.isDeleted).map(\.name) == ["deleted.txt", "reused.txt"])
        #expect(limited.files.filter { !$0.isDeleted }.count == 3)
    }

    /// P3: two deleted files sharing a cluster can't both own it, so neither is emitted.
    @Test func overlappingDeletedFilesAreBothSkipped() async {
        var image = NTFSImage.standard()
        image.records[27] = deletedFile("a.bin", [.at(200, 3)])
        image.records[28] = deletedFile("b.bin", [.at(210, 1), .at(202, 2)])
        image.records[29] = deletedFile("c.bin", [.at(205, 1)])
        let events = await scan(image.build())
        #expect(events.last == .completed)
        let names = files(events).map(\.name)
        #expect(!names.contains("a.bin") && !names.contains("b.bin"))
        #expect(names.contains("c.bin") && names.contains("deleted.txt") && names.contains("old.txt"))
    }

    /// P4: "." and ".." are never names. A ".." directory isn't indexed, so its child is orphaned.
    @Test func dotNamesCannotEscapeTheirPath() async {
        var image = NTFSImage.standard()
        image.records[27] = directory("..")
        image.records[28] = file("x.txt", parent: 27, data: resident(0x80, Data("x".utf8)))
        image.records[29] = file(".", data: resident(0x80, Data("d".utf8)))
        image.records[30] = file("..", sequence: 2, deleted: true, data: resident(0x80, Data("d".utf8)))
        let events = await scan(image.build())
        #expect(events.last == .completed)
        let found = files(events)
        #expect(found.contains { $0.path == "/Orphaned Files/x.txt" && !$0.isDeleted })
        #expect(!found.contains { $0.path.contains("/..") || $0.name == "." || $0.name == ".." })
        #expect(found.count == 7)
    }

    /// P5: `$Bitmap` bytes past the initialized size read as zero, whatever stale bits sit there.
    @Test func bitmapBitsPastInitializedSizeReadAsFree() async {
        var image = NTFSImage.standard()
        image.bitmapInitialized = 16
        image.used.insert(100)
        image.records[27] = deletedFile("early.bin", [.at(100, 1)])
        let found = files(await scan(image.build()))
        // Cluster 170 is in byte 21, past the 16 initialized bytes; cluster 100 (byte 12) is still used.
        #expect(found.contains { $0.path == "/overwritten.txt" && $0.isDeleted })
        #expect(!found.contains { $0.name == "early.bin" })
    }

    /// P6: NTFS skips sequence 0, so a parent freed at 0xFFFF holds 1.
    @Test func parentSequenceWrapsPastZero() async {
        let name = NTFSFileName(parent: 5, parentSequence: 5, namespace: 1, name: "d")
        #expect(NTFSVolume.Directory(sequence: 1, inUse: false, name: name).matches(0xffff))
        #expect(!NTFSVolume.Directory(sequence: 0, inUse: false, name: name).matches(0xffff))
        #expect(!NTFSVolume.Directory(sequence: 1, inUse: true, name: name).matches(0xffff))
        var image = NTFSImage.standard()
        image.records[25] = directory("OldDir", sequence: 1, deleted: true)
        image.records[26] = file("old.txt", parent: 25, parentSequence: 0xffff, sequence: 2, deleted: true,
                                 data: nonResident(0x80, [.at(180, 1), .at(185, 2)], size: 1200))
        #expect(files(await scan(image.build())).contains { $0.path == "/OldDir/old.txt" })
    }

    /// P8a: a user record whose two halves sit in different MFT runs is reassembled and fixed up.
    @Test func userRecordStraddlingMFTRunsIsEmittedIntact() async {
        var image = NTFSImage.standard()
        // 35 clusters then 29: record 17 (hello.txt) occupies the first run's last cluster and the second's first.
        image.mftRuns = [(16, 35), (100, 29)]
        let events = await scan(image.build())
        #expect(events.last == .completed && files(events).count == 6)
        let hello = files(events).first { $0.name == "hello.txt" }
        var expected = image.records[17]!
        #expect(applyNTFSFixup(&expected))
        #expect(hello?.path == "/hello.txt" && hello?.sizeBytes == 5)
        #expect(hello?.sourceMetadata.recordOffset == Int64((16 + 34) * sector))
        #expect(hello?.sourceMetadata.rawRecord == expected)
    }

    /// P8b: run lists step backwards with negative LCN deltas; a delta below cluster 0 is damage.
    @Test func negativeLCNDeltasDecode() async throws {
        let g = try geometry(NTFSImage.standard().build())
        let runs = try NTFSRecord.decodeRuns(runList([.at(200, 2), .at(100, 3), .sparse(2), .at(50, 1)]), from: 0, clusters: 8, geometry: g)
        #expect(runs == [NTFSRun(lcn: 200, length: 2), NTFSRun(lcn: 100, length: 3), NTFSRun(lcn: nil, length: 2),
                         NTFSRun(lcn: 50, length: 1)])
        #expect(throws: ScanError.self) {
            try NTFSRecord.decodeRuns(Data([0x11, 0x01, 0x0a, 0x11, 0x01, 0xec, 0x00]), from: 0, clusters: 2, geometry: g)
        }
        var image = NTFSImage.standard()
        image.records[27] = file("back.bin", data: nonResident(0x80, [.at(220, 2), .at(195, 1)], size: 1500))
        image.used.formUnion([220, 221, 195])
        image.records[28] = deletedFile("backdel.bin", [.at(240, 1), .at(230, 2)])
        let found = files(await scan(image.build()))
        #expect(found.contains { $0.path == "/back.bin" && $0.sizeBytes == 1500 && !$0.sourceMetadata.contiguous })
        #expect(found.contains { $0.path == "/backdel.bin" && $0.isDeleted })
    }

    /// P8c: pages are found across `$Bitmap` runs, past 64K clusters, revisiting earlier pages.
    @Test func bitmapPagesAcrossFragmentsAndPast64KClusters() async {
        var image = largeImage()
        image.used = [4100, 41101, 70003]
        image.records[16] = deletedFile("page1.bin", [.at(5000, 3)])
        image.records[17] = deletedFile("page16.bin", [.at(66000, 100)])
        image.records[18] = deletedFile("page17-used.bin", [.at(70000, 5)])
        image.records[19] = deletedFile("page10.bin", [.at(40960, 64)])
        image.records[20] = deletedFile("page10-used.bin", [.at(41100, 2)])
        image.records[21] = deletedFile("page1-used.bin", [.at(4096, 8)])
        let result = await scanVolume(image.build())
        #expect(result.error == nil)
        #expect(result.files.map(\.name) == ["page1.bin", "page16.bin", "page10.bin"])
    }

    @Test func residentBitmapIsHonoured() async {
        var image = NTFSImage.standard()
        image.residentBitmap = true
        let events = await scan(image.build())
        #expect(events.last == .completed)
        #expect(files(events).count == 6 && !files(events).contains { $0.name == "overwritten.txt" })
        image.used.remove(170)
        #expect(files(await scan(image.build())).contains { $0.name == "overwritten.txt" })
    }

    /// P8d: invalid `$DATA` sizes and run headers.
    @Test(arguments: ["zero-length run", "offset nibble above 8", "length nibble above 8", "initialized > real", "real > allocated"])
    func malformedDataSizesAreSkippedWhenDeletedAndFatalWhenLive(_ damage: String) async {
        func data(_ lcn: UInt8) -> Data {
            switch damage {
            case "zero-length run": return nonResident(0x80, runs: Data([0x11, 0x00, lcn, 0x00]), clusters: 1, size: 100)
            case "offset nibble above 8":
                return nonResident(0x80, runs: Data([0x91, 0x01, lcn] + [UInt8](repeating: 0, count: 8) + [0]), clusters: 1, size: 100)
            case "length nibble above 8":
                return nonResident(0x80, runs: Data([0x19] + [0x01] + [UInt8](repeating: 0, count: 8) + [lcn, 0]), clusters: 1, size: 100)
            case "initialized > real": return nonResident(0x80, [.at(Int(lcn), 1)], size: 100, initialized: 101)
            default: return nonResident(0x80, [.at(Int(lcn), 1)], size: 513, initialized: 100)
            }
        }
        var deleted = NTFSImage.standard()
        deleted.records[19] = file("deleted.txt", parent: 16, sequence: 2, deleted: true, data: data(160))
        let events = await scan(deleted.build())
        #expect(events.last == .completed && files(events).count == 5)
        var live = NTFSImage.standard()
        live.records[18] = file("report.txt", parent: 16, data: data(150))
        #expect(isMalformed(await scan(live.build())))
    }

    /// P8e: a hard-linked file is emitted once, under its first Win32 name, never duplicated per link.
    @Test func hardLinksAreEmittedOnceUnderTheFirstWin32Name() async {
        var image = NTFSImage.standard()
        image.records[27] = record(sequence: 1, flags: 1, [
            standardInformation(), fileName("first.txt", parent: 5, sequence: 5),
            fileName("second.txt", parent: 16, sequence: 1), resident(0x80, Data("h".utf8))])
        image.records[28] = record(sequence: 1, flags: 1, [
            standardInformation(), fileName("inner.txt", parent: 16, sequence: 1),
            fileName("outer.txt", parent: 5, sequence: 5), resident(0x80, Data("i".utf8))])
        let found = files(await scan(image.build()))
        #expect(found.filter { $0.sourceMetadata.allocationStart == 27 }.map(\.path) == ["/first.txt"])
        #expect(found.filter { $0.sourceMetadata.allocationStart == 28 }.map(\.path) == ["/Documents/inner.txt"])
    }

    /// P8f: an `$MFT` whose `$DATA` continues through an attribute list is reported as unsupported.
    @Test func mftNeedingAnAttributeListIsUnsupported() async {
        var image = NTFSImage.standard()
        image.records[0] = record(sequence: 1, flags: 1, [
            standardInformation(), resident(0x20, Data(count: 32)), fileName("$MFT", parent: 5, sequence: 5, namespace: 3),
            nonResident(0x80, [.at(16, 64)], size: 32 * recordSize, allocated: 128 * sector)])
        let events = await scan(image.build())
        #expect(events.contains(.error(.unsupportedFilesystem)) && files(events).isEmpty)
    }

    /// P8g: the root and `$Bitmap` are needed before anything can be emitted.
    @Test(arguments: ["root fixup", "bitmap fixup", "bitmap missing"])
    func damageToRootOrBitmapRecordFailsImmediately(_ damage: String) async {
        var image = NTFSImage.standard().build()
        switch damage {
        case "root fixup": image[Data.recordOffset(5) + 1022] ^= 0xff
        case "bitmap fixup": image[Data.recordOffset(6) + 510] ^= 0xff
        default: image.text(Data.recordOffset(6), "BAAD")
        }
        let events = await scan(image)
        #expect(isMalformed(events) && files(events).isEmpty)
    }

    /// P8h: live files whose parent is missing or reused go under /Orphaned Files, keeping the intact part.
    @Test func liveFileWithBrokenParentChainIsOrphaned() async {
        var image = NTFSImage.standard()
        image.records[27] = file("a.txt", parent: 29, data: resident(0x80, Data("a".utf8)))
        image.records[28] = file("b.txt", parent: 16, parentSequence: 7, data: resident(0x80, Data("b".utf8)))
        image.records[30] = directory("Sub", parent: 29)
        image.records[31] = file("c.txt", parent: 30, data: resident(0x80, Data("c".utf8)))
        let events = await scan(image.build())
        #expect(events.last == .completed)
        let orphans = files(events).filter { $0.path.hasPrefix("/Orphaned Files/") }
        #expect(orphans.map(\.path) == ["/Orphaned Files/reused.txt", "/Orphaned Files/a.txt", "/Orphaned Files/b.txt",
                                        "/Orphaned Files/Sub/c.txt"])
        #expect(orphans.filter { !$0.isDeleted }.count == 3)
    }

    /// P8i: the image has 256 sectors but the boot sector declares 255 clusters, so cluster 255 is outside.
    @Test func runPastClusterCountButInsideVolumeBytesIsRejected() async {
        var live = NTFSImage.standard()
        live.records[18] = file("report.txt", parent: 16, data: nonResident(0x80, [.at(255, 1)], size: 100))
        let built = live.build()
        #expect(built.count == 256 * sector)
        #expect(isMalformed(await scan(built)))
        var deleted = NTFSImage.standard()
        deleted.records[19] = file("deleted.txt", parent: 16, sequence: 2, deleted: true,
                                   data: nonResident(0x80, [.at(254, 2)], size: 100))
        let events = await scan(deleted.build())
        #expect(events.last == .completed && !files(events).contains { $0.name == "deleted.txt" })
    }
}
