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
                         name: String = "", flags: Int = 0) -> Data {
    let nameData = attributeName(name)
    let runsOffset = align8(0x40 + nameData.count)
    var a = Data(count: align8(runsOffset + runs.count))
    a.put(0, UInt64(type), 4); a.put(4, UInt64(a.count), 4); a.put(8, 1, 1)
    a.put(9, UInt64(name.utf16.count), 1); a.put(10, 0x40, 2); a.put(12, UInt64(flags), 2)
    a.replaceSubrange(0x40..<0x40 + nameData.count, with: nameData)
    a.put(0x10, 0, 8); a.put(0x18, UInt64(bitPattern: Int64(clusters - 1)), 8); a.put(0x20, UInt64(runsOffset), 2)
    a.put(0x28, UInt64(allocated ?? clusters * sector), 8); a.put(0x30, UInt64(size), 8); a.put(0x38, UInt64(size), 8)
    a.replaceSubrange(runsOffset..<runsOffset + runs.count, with: runs)
    return a
}

private func nonResident(_ type: UInt32, _ runs: [Run], size: Int, allocated: Int? = nil, flags: Int = 0) -> Data {
    let clusters = runs.reduce(0) { total, run in
        switch run { case .at(_, let length), .sparse(let length): total + length }
    }
    return nonResident(type, runs: runList(runs), clusters: clusters, size: size, allocated: allocated, flags: flags)
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
    /// Clusters marked allocated in `$Bitmap` beyond the system area.
    var used: Set<Int> = [150, 151, 170]

    static func standard() -> NTFSImage {
        var image = NTFSImage()
        image.records[5] = record(sequence: 5, flags: 3, [standardInformation(), fileName(".", parent: 5, sequence: 5, namespace: 3),
                                                         resident(0x90, Data(count: 16), name: "$I30")])
        image.records[6] = record(sequence: 6, flags: 1, [fileName("$Bitmap", parent: 5, sequence: 5, namespace: 3),
                                                         nonResident(0x80, [.at(90, 1)], size: 32)])
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
        var image = Data(count: 256 * sector)
        image.text(3, "NTFS    "); image.put(11, UInt64(sector), 2); image.put(13, 1, 1)
        image.put(0x28, 255, 8); image.put(0x30, UInt64(mftRuns[0].lcn), 8); image.put(0x38, 2, 8)
        image.put(0x40, 0xf6, 1); image.put(0x44, 0xf4, 1); image.put(510, 0xaa55, 2)
        var all = records
        all[0] = record(sequence: 1, flags: 1, [
            standardInformation(), fileName("$MFT", parent: 5, sequence: 5, namespace: 3),
            nonResident(0x80, mftRuns.map { .at($0.lcn, $0.length) }, size: recordCount * recordSize)])
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
        let bitmap = 90 * sector
        for cluster in Array(0..<91) + used { image[bitmap + cluster / 8] |= UInt8(1) << (cluster % 8) }
        return image
    }
}

private func files(_ events: [ScanEvent]) -> [RecoveredFile] {
    events.compactMap { if case .found(let file) = $0 { file } else { nil } }
}
private func isMalformed(_ events: [ScanEvent]) -> Bool {
    events.contains { if case .error(.malformed) = $0 { true } else { false } } && !events.contains(.completed)
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
}
