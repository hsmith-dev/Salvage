import Foundation
import Testing
@testable import SalvageCore

// Builders here layer deleted metadata onto the shared `fatImage`/`exfatImage` fixtures from
// ScanSessionTests.swift. FAT32 fixture: 512-byte clusters, root = cluster 2 at sector 552,
// HELLO.TXT on cluster 3, FOLDER on cluster 4, NESTED.TXT on cluster 5; clusters 6+ are free.
// exFAT fixture: root at sector 25 (cluster 2), file.txt on cluster 3, bitmap on cluster 100
// (sector 123) with every bit of its first 13 bytes set.

private let fatRoot = 552 * 512
private let fatTable = 32 * 512
private let exRoot = 25 * 512
private let exBitmap = 123 * 512

private func found(_ events: [ScanEvent]) -> [RecoveredFile] {
    events.compactMap { if case .found(let file) = $0 { file } else { nil } }
}
private func hasError(_ events: [ScanEvent]) -> Bool {
    events.contains { if case .error = $0 { true } else { false } }
}

private func dosDate(_ year: Int, _ month: Int, _ day: Int) -> UInt64 { UInt64((year - 1980) << 9 | month << 5 | day) }
private func dosTime(_ hour: Int, _ minute: Int, _ second: Int) -> UInt64 { UInt64(hour << 11 | minute << 5 | second / 2) }
private func localDate(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .current
    return calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
}
private func utcDate(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
}

// MARK: FAT32 builders

private func shortEntry(_ name: String, cluster: UInt32, size: UInt32, deleted: Bool = true,
                        date: UInt64 = 0, time: UInt64 = 0, attributes: UInt8 = 0x20) -> Data {
    var entry = Data(repeating: 0, count: 32)
    entry.text(0, name); entry[11] = attributes
    entry.put(20, UInt64(cluster >> 16), 2); entry.put(26, UInt64(cluster & 0xffff), 2); entry.put(28, UInt64(size), 4)
    entry.put(22, time, 2); entry.put(24, date, 2)
    if deleted { entry[0] = 0xe5 }
    return entry
}
private func shortChecksum(_ name: String) -> UInt8 {
    var sum: UInt8 = 0
    for byte in Array(name.utf8).prefix(11) { sum = ((sum & 1) << 7) &+ (sum >> 1) &+ byte }
    return sum
}
/// LFN slots in on-disk order (last name part first); deleted slots have their ordinal overwritten.
private func lfnSlots(_ name: String, checksum: UInt8, deleted: Bool = true) -> [Data] {
    var units = Array(name.utf16)
    if units.count % 13 != 0 { units.append(0) }
    while units.count % 13 != 0 { units.append(0xffff) }
    let count = units.count / 13
    let offsets = [1,3,5,7,9,14,16,18,20,22,24,28,30]
    return (1...count).reversed().map { ordinal in
        var slot = Data(repeating: 0, count: 32)
        slot[0] = deleted ? 0xe5 : UInt8(ordinal) | (ordinal == count ? 0x40 : 0)
        slot[11] = 0x0f; slot[13] = checksum
        for (index, unit) in units[(ordinal - 1) * 13..<ordinal * 13].enumerated() { slot.put(offsets[index], UInt64(unit), 2) }
        return slot
    }
}
private func place(_ image: inout Data, _ slots: [Data], at offset: Int) {
    for (index, slot) in slots.enumerated() { image.replaceSubrange(offset + index*32..<offset + (index+1)*32, with: slot) }
}

// MARK: exFAT builders

private func setChecksum(_ set: inout Data) {
    var sum: UInt16 = 0
    for index in 0..<set.count where index != 2 && index != 3 { sum = ((sum & 1) << 15) &+ (sum >> 1) &+ UInt16(set[index]) }
    set.put(2, UInt64(sum), 2)
}
/// A 3-entry file set (primary, stream, one name entry), checksummed while live, then optionally
/// marked deleted by clearing each entry's in-use bit.
private func exfatSet(_ name: String, cluster: UInt32, size: UInt64, noFatChain: Bool = true, deleted: Bool = true,
                      stamp: UInt32 = 0, tenMs: UInt8 = 0, utcOffset: UInt8 = 0) -> Data {
    var set = Data(repeating: 0, count: 96)
    set[0] = 0x85; set[1] = 2; set.put(4, 0x20, 2)
    set.put(12, UInt64(stamp), 4); set[21] = tenMs; set[23] = utcOffset
    set[32] = 0xc0; set[33] = noFatChain ? 3 : 1; set[35] = UInt8(name.utf16.count)
    set.put(40, size, 8); set.put(52, UInt64(cluster), 4); set.put(56, size, 8)
    set[64] = 0xc1
    for (index, unit) in name.utf16.enumerated() { set.put(66 + index*2, UInt64(unit), 2) }
    setChecksum(&set)
    if deleted { for offset in [0, 32, 64] { set[offset] &= 0x7f } }
    return set
}
private func freeBitmap(_ image: inout Data, clusters: ClosedRange<Int>) {
    for cluster in clusters { image[exBitmap + (cluster - 2) / 8] &= ~(UInt8(1) << UInt8((cluster - 2) % 8)) }
}
private func exStamp(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int) -> UInt32 {
    UInt32(dosDate(y, mo, d) << 16 | dosTime(h, mi, s))
}

@Suite("Deleted-file recovery via intact metadata")
struct DeletedFileTests {
    // MARK: Timestamps

    @Test func liveFAT32FileCarriesItsWriteTimestamp() async {
        var image = fatImage(nested: false)
        image.put(fatRoot+24, dosDate(2024, 6, 15), 2); image.put(fatRoot+22, dosTime(13, 45, 30), 2)
        let events = await scan(image)
        #expect(events.last == .completed)
        let file = found(events).first
        #expect(file?.name == "HELLO.TXT" && file?.isDeleted == false)
        #expect(file?.modified == localDate(2024, 6, 15, 13, 45, 30))
    }
    @Test(arguments: [(0, 0), (dosDate(2023, 2, 29), 0), (dosDate(2024, 13, 1), 0),
                      (dosDate(2024, 1, 1), 24 << 11), (dosDate(2024, 1, 1), 60 << 5),
                      (dosDate(2024, 1, 1), 30)] as [(UInt64, UInt64)])
    func invalidFAT32TimestampIsNil(_ fields: (UInt64, UInt64)) async {
        var image = fatImage(nested: false)
        image.put(fatRoot+24, fields.0, 2); image.put(fatRoot+22, fields.1, 2)
        let events = await scan(image)
        #expect(events.last == .completed)
        #expect(found(events).first.map { $0.modified == nil } == true)
    }
    @Test func FAT32LeapDayIsValid() async {
        var image = fatImage(nested: false)
        image.put(fatRoot+24, dosDate(2024, 2, 29), 2)
        #expect(found(await scan(image)).first?.modified == localDate(2024, 2, 29, 0, 0, 0))
    }
    @Test func liveExFATFileUsesTenMillisecondIncrementAndUTCOffset() async {
        var image = exfatImage()
        // UTC+02:00 is 8 quarter-hours: OffsetValid (0x80) | 8.
        image.put(exRoot+12, UInt64(exStamp(2025, 3, 9, 10, 20, 40)), 4); image[exRoot+21] = 150; image[exRoot+23] = 0x88
        var set = image.subdata(in: exRoot..<exRoot+96); setChecksum(&set)
        image.replaceSubrange(exRoot..<exRoot+96, with: set)
        let events = await scan(image)
        #expect(events.last == .completed)
        #expect(found(events).first?.modified == utcDate(2025, 3, 9, 8, 20, 40).addingTimeInterval(1.5))
    }
    @Test func exFATNegativeOffsetAndLocalFallback() async {
        // UTC-05:00 is -20 quarter-hours, stored as a 7-bit two's complement value.
        let negative = FATVolume.exfatTimestamp(exStamp(2025, 1, 2, 3, 4, 6), tenMs: 0, utcOffset: 0x80 | UInt8(128 - 20))
        #expect(negative == utcDate(2025, 1, 2, 8, 4, 6))
        let local = FATVolume.exfatTimestamp(exStamp(2025, 1, 2, 3, 4, 6), tenMs: 0, utcOffset: 0x08)
        #expect(local == localDate(2025, 1, 2, 3, 4, 6))
        #expect(FATVolume.exfatTimestamp(exStamp(2025, 1, 2, 3, 4, 6), tenMs: 200, utcOffset: 0) == nil)
        #expect(FATVolume.exfatTimestamp(0, tenMs: 0, utcOffset: 0) == nil)
    }

    // MARK: FAT32 deleted entries

    @Test func FAT32DeletedFileWithLongNameIsRecovered() async {
        var image = fatImage(nested: false)
        let short = "ARATHE~1TXT"
        let slots = lfnSlots("A rather long deleted name.txt", checksum: shortChecksum(short))
        let entry = shortEntry(short, cluster: 6, size: 600, date: dosDate(2022, 11, 5), time: dosTime(8, 9, 10))
        place(&image, slots + [entry], at: fatRoot+32)
        let original = image
        let events = await scan(image)
        #expect(events.last == .completed)
        let files = found(events)
        #expect(files.map(\.name) == ["HELLO.TXT", "A rather long deleted name.txt"])
        let deleted = files[1]
        #expect(deleted.isDeleted && deleted.path == "/A rather long deleted name.txt" && deleted.sizeBytes == 600)
        #expect(deleted.modified == localDate(2022, 11, 5, 8, 9, 10))
        #expect(deleted.sourceMetadata.rawRecord == slots.reduce(Data(), +) + entry)
        #expect(deleted.sourceMetadata.allocationStart == 6 && deleted.sourceMetadata.contiguous)
        #expect(deleted.sourceMetadata.recordOffset == Int64(fatRoot + 32 + slots.count * 32))
        #expect(!files[0].isDeleted)
        #expect(image == original)
    }
    @Test func FAT32DeletedFileInSubdirectoryKeepsParentPath() async {
        var image = fatImage()
        let directory = fatRoot + 1024, short = "OLD     DAT"
        place(&image, lfnSlots("old.dat", checksum: shortChecksum(short)) + [shortEntry(short, cluster: 9, size: 10)], at: directory+32)
        let events = await scan(image)
        #expect(events.last == .completed)
        #expect(found(events).contains { $0.path == "/FOLDER/old.dat" && $0.isDeleted })
    }
    @Test func FAT32DeletedShortNameOnlyUsesUnderscore() async {
        var image = fatImage(nested: false)
        place(&image, [shortEntry("GONE    TXT", cluster: 6, size: 5)], at: fatRoot+32)
        let events = await scan(image)
        #expect(events.last == .completed)
        #expect(found(events).contains { $0.name == "_ONE.TXT" && $0.path == "/_ONE.TXT" && $0.isDeleted })
    }
    @Test func FAT32MismatchedLongNameChecksumFallsBackToShortName() async {
        var image = fatImage(nested: false)
        let short = "GONE    TXT"
        place(&image, lfnSlots("wrong.txt", checksum: shortChecksum(short) &+ 1) + [shortEntry(short, cluster: 6, size: 5)], at: fatRoot+32)
        let deleted = found(await scan(image)).filter(\.isDeleted)
        #expect(deleted.map(\.name) == ["_ONE.TXT"])
        #expect(deleted.first?.sourceMetadata.rawRecord.count == 32)
    }
    @Test func FAT32LongNameMustAgreeWithTheLostShortNameFirstByte() async {
        // The checksum can't be checked against 0xE5, so the lost byte is derived from the long
        // name: its uppercased first character, or `_` when that character isn't valid in 8.3.
        for (long, short, expected) in [("+plus.txt", "_PLUS   TXT", "+plus.txt"),
                                        ("Été.txt", "_T~1    TXT", "Été.txt"),
                                        ("other.txt", "GONE    TXT", "_ONE.TXT")] {
            var image = fatImage(nested: false)
            place(&image, lfnSlots(long, checksum: shortChecksum(short)) + [shortEntry(short, cluster: 6, size: 5)], at: fatRoot+32)
            #expect(found(await scan(image)).filter(\.isDeleted).map(\.name) == [expected])
        }
    }
    @Test func FAT32StaleSlotsBeforeTheRunAreIgnored() async {
        var image = fatImage(nested: false)
        let short = "FOURTE~1   ", checksum = shortChecksum(short)
        // An older deleted file's slot with the same checksum sits before the real run.
        let stale = lfnSlots("stale", checksum: checksum)
        let slots = lfnSlots("Fourteen chars", checksum: checksum)
        place(&image, stale + slots + [shortEntry(short, cluster: 6, size: 5)], at: fatRoot+32)
        let deleted = found(await scan(image)).filter(\.isDeleted)
        #expect(deleted.map(\.name) == ["Fourteen chars"])
        #expect(deleted.first?.sourceMetadata.rawRecord.count == (slots.count + 1) * 32)
    }
    @Test func FAT32OverwrittenDeletedFileIsSkipped() async {
        var image = fatImage(nested: false)
        // Cluster 7 (second of the assumed contiguous run) now belongs to some chain.
        image.put(fatTable + 7*4, 0xfffffff, 4)
        place(&image, [shortEntry("GONE    TXT", cluster: 6, size: 600)], at: fatRoot+32)
        let events = await scan(image)
        #expect(events.last == .completed)
        #expect(!hasError(events))
        #expect(found(events).map(\.name) == ["HELLO.TXT"])
    }
    @Test(arguments: [(UInt32(0), UInt32(5)), (UInt32(1), UInt32(5)), (UInt32(0x0ffffff0), UInt32(5)),
                      (UInt32(66000), UInt32(512 * 40)), (UInt32(6), UInt32.max)])
    func FAT32ImplausibleDeletedEntryIsSkipped(_ fields: (UInt32, UInt32)) async {
        var image = fatImage(nested: false)
        place(&image, [shortEntry("GONE    TXT", cluster: fields.0, size: fields.1)], at: fatRoot+32)
        let events = await scan(image)
        #expect(events.last == .completed)
        #expect(!hasError(events))
        #expect(found(events).map(\.name) == ["HELLO.TXT"])
    }
    @Test func FAT32DeletedDirectoriesAndLabelsAreNotReported() async {
        var image = fatImage(nested: false)
        place(&image, [shortEntry("OLDDIR     ", cluster: 6, size: 0, attributes: 0x10),
                       shortEntry("LABEL      ", cluster: 0, size: 0, attributes: 0x08)], at: fatRoot+32)
        let events = await scan(image)
        #expect(events.last == .completed)
        #expect(found(events).map(\.name) == ["HELLO.TXT"])
    }
    @Test func FAT32DeletedDataSharingALiveClusterDoesNotCrossLink() async {
        var image = fatImage()
        // Both deleted entries point into live allocations: HELLO.TXT (3) and FOLDER (4).
        place(&image, [shortEntry("GONE    TXT", cluster: 3, size: 5), shortEntry("GONE2   TXT", cluster: 4, size: 5)], at: fatRoot+64)
        let events = await scan(image)
        #expect(events.last == .completed)
        #expect(!hasError(events))
        #expect(found(events).map(\.path) == ["/HELLO.TXT", "/FOLDER/NESTED.TXT"])
    }
    @Test func FAT32DeletedEntriesPointingAtTheSameFreeClustersAreBothReported() async {
        var image = fatImage(nested: false)
        place(&image, [shortEntry("ONE     TXT", cluster: 6, size: 5), shortEntry("TWO     TXT", cluster: 6, size: 5)], at: fatRoot+32)
        let events = await scan(image)
        #expect(events.last == .completed)
        #expect(found(events).filter(\.isDeleted).map(\.name) == ["_NE.TXT", "_WO.TXT"])
    }
    @Test func FAT32LiveFileAfterDeletedRunIsUnaffected() async {
        var image = fatImage(nested: false)
        let live = image.subdata(in: fatRoot..<fatRoot+32)
        let short = "GONE    TXT"
        // Deleted LFN slots, then a live short entry: the deleted run must not name the live file
        // nor be treated as an orphaned live run.
        place(&image, lfnSlots("not mine.txt", checksum: shortChecksum(short)) + [live], at: fatRoot)
        let events = await scan(image)
        #expect(events.last == .completed)
        #expect(found(events).map(\.name) == ["HELLO.TXT"])
    }
    @Test func garbageDeletedEntriesNeverAbortTheScan() async {
        var image = fatImage(nested: false)
        var seed: UInt64 = 0x2545f4914f6cdd1d
        for slot in stride(from: fatRoot+32, to: fatRoot+512, by: 32) {
            for index in 0..<32 {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                image[slot+index] = UInt8(truncatingIfNeeded: seed >> 33)
            }
            image[slot] = 0xe5
            if slot % 64 == 0 { image[slot+11] = 0x0f }
        }
        let events = await scan(image)
        #expect(events.last == .completed)
        #expect(!hasError(events))
        #expect(found(events).contains { $0.name == "HELLO.TXT" && !$0.isDeleted })
    }

    // MARK: exFAT deleted entry sets

    private func exfatWithDeleted(_ set: Data) -> Data {
        var image = exfatImage()
        image.replaceSubrange(exRoot+128..<exRoot+224, with: set)
        return image
    }
    @Test func exFATDeletedContiguousFileIsRecovered() async {
        let set = exfatSet("gone.txt", cluster: 10, size: 600, stamp: exStamp(2021, 7, 4, 12, 0, 0), tenMs: 10, utcOffset: 0x80)
        var image = exfatWithDeleted(set)
        freeBitmap(&image, clusters: 10...11)
        let events = await scan(image)
        #expect(events.last == .completed)
        let files = found(events)
        #expect(files.map(\.name) == ["file.txt", "gone.txt"])
        let deleted = files[1]
        #expect(deleted.isDeleted && deleted.path == "/gone.txt" && deleted.sizeBytes == 600)
        #expect(deleted.modified == utcDate(2021, 7, 4, 12, 0, 0).addingTimeInterval(0.1))
        #expect(deleted.sourceMetadata.rawRecord == set)
        #expect(deleted.sourceMetadata.recordOffset == Int64(exRoot + 128))
        #expect(deleted.sourceMetadata.filesystem == .exfat && deleted.sourceMetadata.contiguous)
    }
    @Test func exFATDeletedFileWithBadChecksumIsSkipped() async {
        var set = exfatSet("gone.txt", cluster: 10, size: 5)
        set[66] ^= 1
        var image = exfatWithDeleted(set)
        freeBitmap(&image, clusters: 10...10)
        let events = await scan(image)
        #expect(events.last == .completed)
        #expect(!hasError(events))
        #expect(found(events).map(\.name) == ["file.txt"])
    }
    @Test func exFATChecksumIsComputedWithInUseBitsRestored() async {
        // Checksumming the cleared bytes directly must not validate.
        var set = exfatSet("gone.txt", cluster: 10, size: 5)
        setChecksum(&set)
        var image = exfatWithDeleted(set)
        freeBitmap(&image, clusters: 10...10)
        #expect(found(await scan(image)).map(\.name) == ["file.txt"])
    }
    @Test func exFATDeletedFileStillAllocatedInBitmapIsSkipped() async {
        var image = exfatWithDeleted(exfatSet("gone.txt", cluster: 10, size: 600))
        freeBitmap(&image, clusters: 10...10)  // cluster 11 is still allocated
        let events = await scan(image)
        #expect(events.last == .completed)
        #expect(found(events).map(\.name) == ["file.txt"])
    }
    @Test func exFATFragmentedDeletedFileIsSkippedButSingleClusterChainIsKept() async {
        var fragmented = exfatWithDeleted(exfatSet("gone.txt", cluster: 10, size: 600, noFatChain: false))
        freeBitmap(&fragmented, clusters: 10...11)
        #expect(found(await scan(fragmented)).map(\.name) == ["file.txt"])
        var single = exfatWithDeleted(exfatSet("gone.txt", cluster: 10, size: 300, noFatChain: false))
        freeBitmap(&single, clusters: 10...10)
        #expect(found(await scan(single)).map(\.name) == ["file.txt", "gone.txt"])
    }
    @Test func exFATDeletedDataOverlappingLiveFileDoesNotCrossLink() async {
        // Overlaps the live file (cluster 3) and the bitmap (cluster 100); both are allocated.
        for cluster: UInt32 in [3, 100] {
            let events = await scan(exfatWithDeleted(exfatSet("gone.txt", cluster: cluster, size: 5)))
            #expect(events.last == .completed)
            #expect(!hasError(events))
            #expect(found(events).map(\.name) == ["file.txt"])
        }
    }
    @Test func exFATImplausibleDeletedEntryIsSkipped() async {
        for (cluster, size) in [(UInt32(0), UInt64(5)), (UInt32(200), UInt64(5)), (UInt32(10), UInt64(512 * 200)), (UInt32(10), UInt64.max)] {
            var image = exfatWithDeleted(exfatSet("gone.txt", cluster: cluster, size: size))
            freeBitmap(&image, clusters: 10...12)
            let events = await scan(image)
            #expect(events.last == .completed)
            #expect(found(events).map(\.name) == ["file.txt"])
        }
    }
    @Test func exFATDeletedDirectoryIsNotReported() async {
        var set = exfatSet("olddir", cluster: 10, size: 512, deleted: false)
        set.put(4, 0x10, 2); setChecksum(&set)
        for offset in [0, 32, 64] { set[offset] &= 0x7f }
        var image = exfatWithDeleted(set)
        freeBitmap(&image, clusters: 10...10)
        let events = await scan(image)
        #expect(events.last == .completed)
        #expect(found(events).map(\.name) == ["file.txt"])
    }
    @Test func exFATPartlyOverwrittenDeletedSetDoesNotSwallowLiveEntries() async {
        // A deleted primary claims two secondaries, but a live file set now follows it directly.
        var image = exfatImage()
        let live = image.subdata(in: exRoot..<exRoot+96), bitmap = image.subdata(in: exRoot+96..<exRoot+128)
        var primary = exfatSet("gone.txt", cluster: 10, size: 5).prefix(32)
        primary[1] = 2
        image.replaceSubrange(exRoot..<exRoot+160, with: primary + live + bitmap)
        let events = await scan(image)
        #expect(events.last == .completed)
        #expect(found(events).map(\.name) == ["file.txt"])
    }
    @Test func exFATDeletedSetsBackToBackAreBothRecovered() async {
        var image = exfatImage()
        let first = exfatSet("one.txt", cluster: 10, size: 5), second = exfatSet("two.txt", cluster: 11, size: 5)
        image.replaceSubrange(exRoot+128..<exRoot+320, with: first + second)
        freeBitmap(&image, clusters: 10...11)
        let events = await scan(image)
        #expect(events.last == .completed)
        #expect(found(events).map(\.name) == ["file.txt", "one.txt", "two.txt"])
        #expect(found(events).filter(\.isDeleted).count == 2)
    }
}
