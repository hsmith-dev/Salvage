import Foundation
import Testing
@testable import SalvageCore

private let mib = 1 << 20

/// A zero-filled device with volumes placed at byte offsets and type-7 MBR entries (start and
/// length in sectors).
private func device(size: Int, _ placements: [(Int, Data)], mbr: [(start: Int, sectors: Int)] = []) -> Data {
    var image = Data(repeating: 0, count: size)
    for (offset, volume) in placements { image.replaceSubrange(offset..<offset + volume.count, with: volume) }
    if !mbr.isEmpty { image.put(510, 0xaa55, 2) }
    for (n, entry) in mbr.enumerated() {
        let p = 446 + n * 16
        image.put(p + 4, 7, 1); image.put(p + 8, UInt64(entry.start), 4); image.put(p + 12, UInt64(entry.sectors), 4)
    }
    return image
}

/// Reads fail with `.io` wherever `fails(offset, count)` says.
private struct SpottyReader: BlockReader {
    let data: Data
    let fails: @Sendable (Int64, Int) -> Bool
    var sizeBytes: Int64 { Int64(data.count) }
    func read(at offset: Int64, count: Int) async throws -> Data {
        if fails(offset, count) { throw ScanError.io("Injected read error") }
        return try await ImageReader(data: data).read(at: offset, count: count)
    }
}

private struct Outcome {
    var events: [ScanEvent] = []
    var notices: [ScanNotice] = []
    var checkpoints: [ScanCheckpoint] = []
    var files: [RecoveredFile] { events.compactMap { if case .found(let file) = $0 { file } else { nil } } }
    var errors: [ScanError] { events.compactMap { if case .error(let error) = $0 { error } else { nil } } }
}

private func run(_ session: ScanSession, resumingFrom checkpoint: ScanCheckpoint? = nil) async -> Outcome {
    let (stream, events) = AsyncStream<ScanEvent>.makeStream()
    let (noticeStream, notices) = AsyncStream<ScanNotice>.makeStream()
    let (pointStream, points) = AsyncStream<ScanCheckpoint>.makeStream()
    await session.run(events: events, checkpoints: points, notices: notices, resumingFrom: checkpoint)
    var outcome = Outcome()
    for await event in stream { outcome.events.append(event) }
    for await notice in noticeStream { outcome.notices.append(notice) }
    for await point in pointStream { outcome.checkpoints.append(point) }
    return outcome
}
private func run(_ reader: any BlockReader) async -> Outcome { await run(ScanSession(reader: reader)) }
private func run(_ image: Data) async -> Outcome { await run(ImageReader(data: image)) }

private func damagedExFAT() -> Data {
    var damaged = exfatImage(); damaged[25 * 512 + 66] ^= 1   // corrupt entry-set checksum
    return damaged
}

@Suite("Scan notices: what a scan could not do")
struct ScanNoticeTests {
    // MARK: Per-volume isolation

    @Test func corruptFirstMappedVolumeIsSkippedAndTheSecondStillScanned() async {
        let damaged = damagedExFAT(), intact = exfatImage()
        let image = device(size: 4 * mib, [(mib, damaged), (2 * mib, intact)],
                           mbr: [(mib / 512, damaged.count / 512), (2 * mib / 512, intact.count / 512)])
        let outcome = await run(image)
        #expect(outcome.files.map(\.sourceMetadata.volumeOffset) == [Int64(2 * mib)])
        #expect(outcome.files.map(\.path) == ["/file.txt"])
        #expect(outcome.errors.isEmpty)
        #expect(outcome.events.last == .completed)
        let skipped = outcome.notices.filter { if case .volumeSkipped = $0 { true } else { false } }
        #expect(skipped.count == 1)
        guard case .volumeSkipped(let name, let offset, let reason) = skipped.first else { return }
        #expect(name == "FAT32/exFAT" && offset == Int64(mib))
        #expect(reason.hasPrefix("The filesystem metadata is damaged"))
        // The skipped volume is still swept: progress covers both volumes.
        let total = Int64(damaged.count + intact.count)
        #expect(outcome.events.contains(.progress(bytesScanned: total, totalBytes: total)))
    }

    @Test func singleVolumeFailureStillReportsTheErrorWithoutANotice() async {
        let damaged = damagedExFAT()
        let outcome = await run(device(size: 4 * mib, [(2 * mib, damaged)], mbr: [(2 * mib / 512, damaged.count / 512)]))
        #expect(!outcome.events.contains(.completed))
        #expect(outcome.errors.contains { if case .malformed = $0 { true } else { false } })
        // Notices never duplicate an `.error`.
        #expect(!outcome.notices.contains { if case .volumeSkipped = $0 { true } else { false } })
    }

    @Test func ioErrorOnAMappedVolumeAmongSeveralStillEndsTheScan() async {
        let volume = exfatImage()
        let image = device(size: 4 * mib, [(mib, volume), (2 * mib, volume)],
                           mbr: [(mib / 512, volume.count / 512), (2 * mib / 512, volume.count / 512)])
        let root = Int64(mib + 25 * 512)
        let outcome = await run(SpottyReader(data: image) { offset, count in offset <= root && root < offset + Int64(count) })
        #expect(outcome.errors.contains { if case .io = $0 { true } else { false } })
        #expect(!outcome.events.contains(.completed))
        #expect(outcome.notices.isEmpty)
    }

    // MARK: Discovery producers

    @Test func ignoredPartitionTableIsANotice() async {
        // An MBR entry that runs past the device end: the table is ignored and the device searched.
        let volume = exfatImage()
        let outcome = await run(device(size: 2 * mib, [(mib, volume)], mbr: [(mib / 512, 4 * mib / 512)]))
        #expect(outcome.events.last == .completed)
        #expect(outcome.notices == [.partitionTableIgnored(reason: "Partition outside device.")])
    }

    @Test func limitedLostPartitionSearchIsANotice() async throws {
        let image = device(size: 8 * mib, [(6 * mib, exfatImage())])
        let limited = try await VolumeDiscovery(reader: ImageReader(data: image), maxProbes: 4).discover()
        let notices = ScanSession.discoveryNotices(limited, deviceBytes: Int64(image.count))
        guard case .lostPartitionSearchLimited(let searched, let total)? = notices.first else {
            Issue.record("no search-limited notice in \(notices)"); return
        }
        #expect(searched == limited.searchedBytes && searched < Int64(6 * mib) && total == Int64(8 * mib))
        // A full search says nothing.
        let full = try await VolumeDiscovery(reader: ImageReader(data: image)).discover()
        #expect(ScanSession.discoveryNotices(full, deviceBytes: Int64(image.count)).isEmpty)
    }

    @Test func unreadableProbesAreANotice() async {
        let volume = exfatImage()
        let layout = device(size: 4 * mib, [(mib, volume)], mbr: [(mib / 512, volume.count / 512)])
        let spotty = SpottyReader(data: layout) { offset, _ in (3 * mib..<3 * mib + 16 * 1024).contains(Int(offset)) }
        let outcome = await run(spotty)
        #expect(outcome.events.last == .completed)
        #expect(outcome.notices == [.unreadableAreasSkipped(count: 4)])
    }

    // MARK: Carving producers

    @Test func carvingLimitIsANotice() async {
        var image = fatImage()
        let jpeg = jpegBytes()
        image.replaceSubrange(600 * 512..<600 * 512 + jpeg.count, with: jpeg)
        image.replaceSubrange(700 * 512..<700 * 512 + jpeg.count, with: jpeg)
        var session = ScanSession(reader: ImageReader(data: image))
        session.carverLimits.maxCarvedFiles = 1
        let outcome = await run(session)
        #expect(outcome.events.last == .completed)
        #expect(outcome.files.filter { $0.recoveryMethod == .carved }.count == 1)
        #expect(outcome.notices == [.carvingLimitReached(count: 1)])
        // Under the cap, nothing to say.
        #expect(await run(image).notices.isEmpty)
    }

    @Test func skippedSignaturesAreANotice() async {
        var session = ScanSession(reader: ImageReader(data: fatImage()))
        session.signatureLibrary = SignatureLibrary(signatures: SignatureLibrary.bundled.signatures,
                                                    skipped: [.init(file: "broken.json", reason: "bad hex")])
        let outcome = await run(session)
        #expect(outcome.events.last == .completed)
        #expect(outcome.notices == [.signaturesSkipped(["broken.json"])])
    }

    @Test func resumedScanSaysCarvingWasPartial() async throws {
        let image = fatImage()
        let first = await run(image)
        #expect(first.notices.isEmpty)
        let checkpoint = try #require(first.checkpoints.first)
        let resumed = await run(ScanSession(reader: ImageReader(data: image)), resumingFrom: checkpoint)
        #expect(resumed.events.last == .completed)
        #expect(resumed.notices == [.resumedCarvingPartial])
    }

    // MARK: Text

    @Test func textIsPlainLanguage() {
        let gb: Int64 = 1_000_000_000
        #expect(ScanNotice.lostPartitionSearchLimited(searchedBytes: 512 * gb, deviceBytes: 2000 * gb).text
                == "The search for lost partitions covered the first 512 GB of this 2 TB drive.")
        #expect(ScanNotice.unreadableAreasSkipped(count: 3).text == "Part of this drive couldn't be read, so 3 areas were skipped.")
        #expect(ScanNotice.unreadableAreasSkipped(count: 1).text == "Part of this drive couldn't be read, so 1 area was skipped.")
        let all: [ScanNotice] = [.partitionTableIgnored(reason: "x"), .lostPartitionSearchLimited(searchedBytes: 1, deviceBytes: 2),
                                 .unreadableAreasSkipped(count: 2), .carvingLimitReached(count: 250_000),
                                 .signaturesSkipped(["a.json"]), .resumedCarvingPartial,
                                 .volumeSkipped(formatName: "NTFS", offset: 1 << 20, reason: "The filesystem metadata is damaged: x.")]
        for notice in all {
            #expect(!notice.text.isEmpty && notice.text.hasSuffix(".") && !notice.text.contains("!"))
        }
        #expect(ScanNotice.carvingLimitReached(count: 250_000).text.contains("250,000"))
        #expect(ScanNotice.volumeSkipped(formatName: "NTFS", offset: 1_048_576, reason: "R.").text.contains("NTFS volume that starts 1 MB into"))
    }
}
