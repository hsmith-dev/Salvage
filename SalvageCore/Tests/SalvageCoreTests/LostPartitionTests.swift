import Foundation
import Testing
@testable import SalvageCore

private let mib = 1 << 20

/// A zero-filled device with volumes placed at byte offsets. `mbr` writes type-7 entries (start and
/// length in sectors) and the boot signature; `signature` alone writes a valid MBR with no entries.
private func device(size: Int, _ placements: [(Int, Data)], mbr: [(start: Int, sectors: Int)] = [],
                    signature: Bool = false) -> Data {
    var image = Data(repeating: 0, count: size)
    for (offset, volume) in placements { image.replaceSubrange(offset..<offset + volume.count, with: volume) }
    if signature || !mbr.isEmpty { image.put(510, 0xaa55, 2) }
    for (n, entry) in mbr.enumerated() {
        let p = 446 + n * 16
        image.put(p + 4, 7, 1); image.put(p + 8, UInt64(entry.start), 4); image.put(p + 12, UInt64(entry.sectors), 4)
    }
    return image
}
private func found(_ events: [ScanEvent]) -> [RecoveredFile] {
    events.compactMap { if case .found(let file) = $0 { file } else { nil } }
}
private func lost(_ events: [ScanEvent]) -> [LostPartitionCandidate] {
    events.compactMap { if case .lostPartitionFound(let candidate) = $0 { candidate } else { nil } }
}
private func discover(_ image: Data) async throws -> [VolumeExtent] {
    try await VolumeDiscovery(reader: ImageReader(data: image)).discover().extents
}
private func scan(_ reader: any BlockReader) async -> [ScanEvent] {
    let (stream, events) = AsyncStream<ScanEvent>.makeStream()
    await ScanSession(reader: reader).run(events: events)
    var result: [ScanEvent] = []
    for await event in stream { result.append(event) }
    return result
}
private func index(of candidate: Int64, in events: [ScanEvent]) -> Int? {
    events.firstIndex { if case .lostPartitionFound(let c) = $0 { c.offset == candidate } else { false } }
}
private func ntfsHeader(totalSectors: UInt64) -> Data {
    var boot = Data(repeating: 0, count: 512)
    boot.text(3, "NTFS    "); boot.put(11, 512, 2); boot.put(13, 8, 1); boot.put(0x28, totalSectors, 8); boot.put(510, 0xaa55, 2)
    return boot
}

@Suite("Lost partitions: discovery in unallocated space (FR-9) and read-only recovery (FR-10)")
struct LostPartitionTests {
    @Test func volumeWithoutAPartitionTableIsFoundScannedThenAnnounced() async {
        let volume = exfatImage()
        let image = device(size: 2 * mib, [(mib, volume)]), original = image
        let events = await scan(image)
        let candidates = lost(events)
        #expect(candidates.map(\.offset) == [Int64(mib)])
        #expect(candidates.map(\.sizeBytes) == [Int64(volume.count)])
        #expect(candidates.map(\.formatName) == ["exFAT"])
        let files = found(events)
        #expect(files.map(\.path) == ["/file.txt"])
        #expect(files.allSatisfy { $0.sourceMetadata.volumeOffset == Int64(mib) })
        #expect(events.last == .completed)
        // Announced once its parser has finished (after its files), so the name can say whether the
        // parser got through; this one did, so it carries no "(damaged)" suffix.
        let firstLost = events.firstIndex { if case .lostPartitionFound = $0 { true } else { false } } ?? .min
        let lastFound = events.lastIndex { if case .found = $0 { true } else { false } } ?? .max
        #expect(firstLost > lastFound)
        // Only the volume is scanned and swept, never the empty space around it.
        #expect(events.contains(.progress(bytesScanned: Int64(volume.count), totalBytes: Int64(volume.count))))
        #expect(image == original)
    }

    @Test func zeroedMBREntryStillFindsTheVolumeBesideMappedOnes() async {
        // A valid MBR with every entry zeroed: the whole device is unallocated.
        let alone = await scan(device(size: 2 * mib, [(mib, exfatImage())], signature: true))
        #expect(lost(alone).map(\.offset) == [Int64(mib)])
        #expect(found(alone).map(\.path) == ["/file.txt"])
        #expect(alone.last == .completed)
        // One entry zeroed, one intact: the mapped partition is scanned as before and the lost one beside it.
        let volume = exfatImage()
        let image = device(size: 4 * mib, [(mib, volume), (2 * mib, volume)], mbr: [(2 * mib / 512, volume.count / 512)])
        let events = await scan(image)
        #expect(lost(events).map(\.offset) == [Int64(mib)])
        #expect(found(events).map(\.sourceMetadata.volumeOffset) == [Int64(mib), Int64(2 * mib)])
        #expect(events.last == .completed)
        #expect(events.contains(.progress(bytesScanned: Int64(2 * volume.count), totalBytes: Int64(2 * volume.count))))
    }

    @Test func gapBetweenPartitionsIsSearchedAndItsVolumeScanned() async throws {
        // Two mapped exFAT partitions with an ext2 volume in the gap between them.
        let fat = exfatImage(), ext = ext2Image().image
        let image = device(size: 4 * mib, [(mib, fat), (2 * mib, ext), (3 * mib, fat)],
                           mbr: [(mib / 512, fat.count / 512), (3 * mib / 512, fat.count / 512)])
        let extents = try await discover(image)
        #expect(extents.map(\.offset) == [Int64(mib), Int64(2 * mib), Int64(3 * mib)])
        #expect(extents.map(\.isLost) == [false, true, false])
        #expect(extents[1].format == .ext && extents[1].length == Int64(ext.count))
        let events = await scan(image)
        #expect(lost(events).map(\.formatName) == ["EXT2/3/4"])
        #expect(found(events).map(\.path) == ["/file.txt", "/hello.txt", "/docs/big.bin", "/file.txt"])
        #expect(found(events).filter { $0.sourceMetadata.volumeOffset == Int64(2 * mib) }.count == 2)
        #expect(events.last == .completed)
        let total = Int64(2 * fat.count + ext.count)
        #expect(events.contains(.progress(bytesScanned: total, totalBytes: total)))
    }

    @Test func ntfsHeaderInAGapIsFoundWithItsOwnLength() async throws {
        let image = device(size: 4 * mib, [(mib, ntfsHeader(totalSectors: 2047))])
        let extents = try await discover(image)
        #expect(extents.count == 1)
        #expect(extents.first?.offset == Int64(mib) && extents.first?.length == Int64(mib))
        #expect(extents.first?.format == .ntfs && extents.first?.isLost == true)
        // A bare header has no MFT: the parser's failure stays inside the lost partition.
        let events = await scan(image)
        #expect(lost(events).map(\.formatName) == ["NTFS (damaged)"])
        #expect(found(events).isEmpty)
        #expect(events.last == .completed)
    }

    @Test func overlappingCandidatesKeepTheEarlierOne() async throws {
        // The second header sits inside the first volume's declared span.
        let volume = exfatImage()
        let image = device(size: 2 * mib, [(mib, volume), (mib + 32 * 1024, volume)])
        let extents = try await discover(image)
        #expect(extents.map(\.offset) == [Int64(mib)])
        #expect(extents.map(\.length) == [Int64(volume.count)])
        #expect(extents.allSatisfy { $0.isLost })
    }

    @Test func candidateRunningIntoAKnownExtentIsDropped() async throws {
        // A stale exFAT header at 512 KiB claims 1 MiB, crossing into the mapped partition at 1 MiB.
        var stale = exfatImage(); stale.put(72, UInt64(mib / 512), 8)
        let known = exfatImage()
        let image = device(size: 2 * mib, [(512 * 1024, stale), (mib, known)], mbr: [(mib / 512, known.count / 512)])
        let extents = try await discover(image)
        #expect(extents.map(\.offset) == [Int64(mib)])
        #expect(extents.allSatisfy { !$0.isLost })
        let events = await scan(image)
        #expect(lost(events).isEmpty)
        #expect(found(events).allSatisfy { $0.sourceMetadata.volumeOffset == Int64(mib) })
        #expect(events.last == .completed)
    }

    @Test func garbageDeviceSweepsOneRawExtentAndCompletesHonestly() async throws {
        var image = Data(repeating: 0, count: 2 * mib), seed: UInt64 = 0x9e3779b97f4a7c15
        for offset in stride(from: 0, to: image.count, by: 8) {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            image.put(offset, seed, 8)
        }
        let extents = try await discover(image)
        #expect(extents.count == 1)
        #expect(extents.first?.format == .raw && extents.first?.isLost == false)
        #expect(extents.first?.offset == 0 && extents.first?.length == Int64(image.count))
        let events = await scan(image)
        #expect(lost(events).isEmpty && found(events).isEmpty)
        #expect(events.last == .completed)
        #expect(events.contains(.progress(bytesScanned: Int64(image.count), totalBytes: Int64(image.count))))
    }

    @Test func headerGeometryGivesEachFormatsLength() async throws {
        func length(_ format: VolumeFormat, _ stamp: (inout Data) -> Void) async throws -> Int64? {
            var image = Data(repeating: 0, count: 8192); stamp(&image)
            let discovery = VolumeDiscovery(reader: ImageReader(data: image))
            let detected = try await discovery.format(at: 0, length: 8192)
            #expect(detected == format)
            return try await discovery.volumeLength(format: format, at: 0)
        }
        let apfs = try await length(.apfs) { $0.text(32, "NXSB"); $0.put(36, 4096, 4); $0.put(40, 1000, 8) }
        #expect(apfs == Int64(4_096_000))
        // A bare APFS volume superblock carries no container size.
        let bare = try await length(.apfs) { $0.text(32, "APSB"); $0.put(36, 4096, 4); $0.put(40, 1000, 8) }
        #expect(bare == nil)
        let hfs = try await length(.hfsPlus) {
            $0[1024] = 0x48; $0[1025] = 0x2B
            $0.replaceSubrange(1024 + 40..<1024 + 48, with: [0, 0, 0x10, 0, 0, 0, 0x01, 0xF4])   // 4096-byte blocks × 500
        }
        #expect(hfs == Int64(2_048_000))
        let ntfs = try await length(.ntfs) { $0.replaceSubrange(0..<512, with: ntfsHeader(totalSectors: 2047)) }
        #expect(ntfs == Int64(mib))
        let ext = try await length(.ext) {
            $0.put(1024 + 56, 0xef53, 2); $0.put(1024 + 24, 2, 4); $0.put(1024 + 76, 1, 4)
            $0.put(1024 + 96, 0x80, 4); $0.put(1024 + 4, 16, 4); $0.put(1024 + 336, 1, 4)   // 64-bit: (1 << 32 | 16) blocks of 4 KiB
        }
        #expect(ext == ((Int64(1) << 32) | 16) * 4096)
        let exfat = try await length(.fat) { $0.replaceSubrange(0..<512, with: exfatImage().prefix(512)) }
        #expect(exfat == Int64(65_536))
        let fat32 = try await length(.fat) {
            $0.put(0, 0xeb, 1); $0.put(11, 512, 2); $0.put(13, 1, 1); $0.put(14, 32, 2); $0.put(32, 66560, 4); $0.put(36, 520, 4)
        }
        #expect(fat32 == Int64(66_560 * 512))
        // Implausible geometry drops the candidate: a zero-length volume leaves nothing but the raw fallback.
        var empty = exfatImage(); empty.put(72, 0, 8)
        let extents = try await discover(device(size: 2 * mib, [(mib, empty)]))
        #expect(extents.map(\.format) == [.raw])
        // A header running past the device end is clamped to it rather than dropped.
        var long = exfatImage(); long.put(72, UInt64(8 * mib / 512), 8)
        let clamped = try await discover(device(size: 2 * mib, [(mib, long)]))
        #expect(clamped.map(\.offset) == [Int64(mib)] && clamped.map(\.length) == [Int64(mib)])
    }

    @Test func damagedLostPartitionStopsOnlyItsOwnParser() async {
        var damaged = exfatImage(); damaged.put(25 * 512 + 120, 14, 8)   // invalid allocation bitmap length
        let known = exfatImage()
        let events = await scan(device(size: 4 * mib, [(mib, damaged), (2 * mib, known)], mbr: [(2 * mib / 512, known.count / 512)]))
        #expect(lost(events).map(\.offset) == [Int64(mib)])
        // The card can say the partition's metadata was damaged: the candidate is named after its parser ran.
        #expect(lost(events).map(\.formatName) == ["exFAT (damaged)"])
        #expect(found(events).map(\.sourceMetadata.volumeOffset) == [Int64(2 * mib)])
        #expect(!events.contains { if case .error = $0 { true } else { false } })
        #expect(events.last == .completed)
        // Both extents are still swept in full.
        #expect(events.contains(.progress(bytesScanned: Int64(2 * known.count), totalBytes: Int64(2 * known.count))))
        // The same damage in a mapped partition still fails closed, as before.
        let mapped = await scan(device(size: 4 * mib, [(2 * mib, damaged)], mbr: [(2 * mib / 512, damaged.count / 512)]))
        #expect(!mapped.contains(.completed))
        #expect(mapped.contains { if case .error(.malformed) = $0 { true } else { false } })
    }

    @Test func probingIsBoundedInReadsAndCancellable() async throws {
        let image = device(size: 8 * mib, [(6 * mib, exfatImage())])
        // Within budget the volume is found; with a tiny budget the search ends early and falls back to raw.
        let full = try await discover(image)
        #expect(full.map(\.offset) == [Int64(6 * mib)] && full.allSatisfy { $0.isLost })
        let counting = CountingReader(data: image)
        let limited = try await VolumeDiscovery(reader: counting, maxProbes: 4).discover()
        #expect(limited.extents.map(\.format) == [.raw])
        #expect(limited.probesTruncated && limited.searchedBytes.map { $0 < Int64(6 * mib) } == true)
        #expect(limited.warnings.contains { $0.hasPrefix("The search for lost partitions was limited to the first ") })
        // The whole-device check (two header reads) plus at most two header reads per probe.
        let reads = await counting.reads
        #expect(reads <= 2 + 2 * 4)
        let task = Task {
            try? await Task.sleep(for: .seconds(10))
            return try await discover(image)
        }
        #expect(try await VolumeDiscovery(reader: ImageReader(data: image)).discover().probesTruncated == false)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func checkpointFingerprintIncludesLostExtents() async throws {
        let volume = exfatImage()
        let image = device(size: 2 * mib, [(mib, volume)])
        let (stream, events) = AsyncStream<ScanEvent>.makeStream()
        let (points, checkpoints) = AsyncStream<ScanCheckpoint>.makeStream()
        await ScanSession(reader: ImageReader(data: image)).run(events: events, checkpoints: checkpoints)
        var last: ScanCheckpoint?
        for await point in points { last = point }
        var result: [ScanEvent] = []
        for await event in stream { result.append(event) }
        #expect(result.last == .completed)
        #expect(last?.extents == [ScanCheckpoint.Extent(offset: Int64(mib), length: Int64(volume.count))])
        let extents = try await discover(image)
        #expect(ScanSession.sweepStart(last!, extents: extents, total: Int64(volume.count), deviceSize: Int64(image.count)) != nil)
    }

    // MARK: Review patch (P3)

    @Test func overflowingLostHeaderLengthIsDroppedNotTrapped() async throws {
        // exFAT VolumeLength 0x003FFFFFFFFFFFFF sectors: the byte length (2^63 - 512) fits Int64, but
        // offset + length does not. The candidate is dropped instead of trapping on the addition.
        var huge = exfatImage(); huge.put(72, 0x003F_FFFF_FFFF_FFFF, 8)
        let extents = try await discover(device(size: 2 * mib, [(mib, huge)]))
        #expect(extents.map(\.format) == [.raw])
        #expect(extents.allSatisfy { !$0.isLost })
        // Beside it, an intact lost volume is still found.
        let both = try await discover(device(size: 4 * mib, [(mib, huge), (2 * mib, exfatImage())]))
        #expect(both.map(\.offset) == [Int64(2 * mib)] && both.allSatisfy { $0.isLost })
    }

    @Test func unreadableGapIsSkippedAndTheMappedVolumeStillScanned() async throws {
        let volume = exfatImage()
        let layout = device(size: 4 * mib, [(mib, volume)], mbr: [(mib / 512, volume.count / 512)])
        // A few unreadable sectors in the gap after the partition: each failed probe is skipped and counted.
        let spotty = FaultyDevice(data: layout) { offset, _ in (3 * mib..<3 * mib + 16 * 1024).contains(Int(offset)) }
        let result = try await VolumeDiscovery(reader: spotty).discover()
        #expect(result.extents.map(\.offset) == [Int64(mib)])
        #expect(result.failedProbes == 4 && !result.probesTruncated)
        let events = await scan(spotty)
        #expect(found(events).map(\.path) == ["/file.txt"])
        #expect(events.last == .completed)
        // A wholly unreadable gap: probing stops after the consecutive-failure limit and says so.
        let dead = FaultyDevice(data: layout) { offset, _ in offset >= Int64(2 * mib) }
        let stopped = try await VolumeDiscovery(reader: dead, maxConsecutiveProbeFailures: 8).discover()
        #expect(stopped.failedProbes == 8 && stopped.probesTruncated)
        #expect(stopped.warnings.contains { $0.contains("8 consecutive reads failed") })
        #expect((await scan(dead)).last == .completed)
        // Mapped volumes keep today's semantics: an unreadable mapped partition still fails the scan.
        let mapped = FaultyDevice(data: layout) { offset, count in count >= volume.count && offset == Int64(mib) }
        let failed = await scan(mapped)
        #expect(failed.contains { if case .error(.io) = $0 { true } else { false } })
        #expect(!failed.contains(.completed))
    }

    @Test func unreadableLostExtentStopsOnlyItselfAndTheScanCompletes() async {
        // Lost exFAT at 1 MiB, mapped exFAT at 2 MiB, lost exFAT at 3 MiB.
        let volume = exfatImage()
        let layout = device(size: 4 * mib, [(mib, volume), (2 * mib, volume), (3 * mib, volume)],
                            mbr: [(2 * mib / 512, volume.count / 512)])
        // The first lost volume's root directory can't be read: its parser and its sweep both stop.
        let root = Int64(mib + 25 * 512)
        let parserFails = FaultyDevice(data: layout) { offset, count in offset <= root && root < offset + Int64(count) }
        let events = await scan(parserFails)
        #expect(lost(events).map(\.offset) == [Int64(mib), Int64(3 * mib)])
        #expect(lost(events).map(\.formatName) == ["exFAT (damaged)", "exFAT"])
        #expect(found(events).map(\.sourceMetadata.volumeOffset) == [Int64(2 * mib), Int64(3 * mib)])
        #expect(!events.contains { if case .error = $0 { true } else { false } })
        #expect(events.last == .completed)
        // Only the sweep read of the first lost volume fails: its files stay, the rest is swept.
        let sweepFails = FaultyDevice(data: layout) { offset, count in offset == Int64(mib) && count == volume.count }
        let swept = await scan(sweepFails)
        #expect(lost(swept).map(\.formatName) == ["exFAT", "exFAT"])
        #expect(found(swept).map(\.sourceMetadata.volumeOffset) == [Int64(mib), Int64(2 * mib), Int64(3 * mib)])
        #expect(swept.last == .completed)
    }

    @Test func lostAPFSAndHFSPlusAreAnnouncedContainedAndSwept() async {
        // Signature-only stubs in unallocated space beside a mapped exFAT: both parsers reject them as
        // damaged; the scan carries on, names them damaged, and still sweeps (carves) their bytes.
        var hfs = Data(repeating: 0, count: 64 * 1024)
        hfs[1024] = 0x48; hfs[1025] = 0x2B
        hfs.replaceSubrange(1024 + 40..<1024 + 48, with: [0, 0, 0x10, 0, 0, 0, 0, 16])     // 16 × 4 KiB
        var apfs = Data(repeating: 0, count: 64 * 1024)
        apfs.text(32, "NXSB"); apfs.put(36, 4096, 4); apfs.put(40, 16, 8)
        let volume = exfatImage()
        let image = device(size: 4 * mib, [(mib, hfs), (2 * mib, volume), (3 * mib, apfs)], mbr: [(2 * mib / 512, volume.count / 512)])
        let events = await scan(image)
        #expect(lost(events).map(\.offset) == [Int64(mib), Int64(3 * mib)])
        #expect(lost(events).map(\.formatName) == ["HFS+ (damaged)", "APFS (damaged)"])
        #expect(lost(events).map(\.sizeBytes) == [65536, 65536])
        #expect(found(events).allSatisfy { $0.sourceMetadata.volumeOffset == Int64(2 * mib) })
        #expect(events.last == .completed)
        let total = Int64(3 * 65536)
        #expect(events.contains(.progress(bytesScanned: total, totalBytes: total)))
        // Each candidate follows its own parser: the HFS+ one is announced before the mapped volume's files.
        let firstFile = events.firstIndex { if case .found = $0 { true } else { false } } ?? .min
        #expect((index(of: Int64(mib), in: events) ?? .max) < firstFile)
        #expect((index(of: Int64(3 * mib), in: events) ?? .min) > firstFile)
    }

    @Test func fineRegionIsProbedInFullBeforeTheCoarseWalk() async throws {
        // A 64 GiB device: a 1 MiB walk alone would spend more than the old three-quarter budget.
        // A volume on a 4 KiB (not 1 MiB) boundary near the end of the first 64 MiB is still found.
        let at = 63 * mib + 4096
        let reader = FaultyDevice(size: 64 << 30, regions: [(Int64(at), exfatImage())])
        let result = try await VolumeDiscovery(reader: reader, maxProbes: 16384 + 2048).discover()
        #expect(result.extents.map(\.offset) == [Int64(at)] && result.extents.allSatisfy { $0.isLost })
        #expect(result.probesTruncated)
        // The default budget walks the whole 64 GiB at 1 MiB without truncating.
        let full = try await VolumeDiscovery(reader: reader).discover()
        #expect(full.extents.map(\.offset) == [Int64(at)] && !full.probesTruncated && full.warnings.isEmpty)
    }

    @Test func aTwoTerabyteDeviceIsWalkedEndToEnd() async throws {
        // 1 MiB steps to 64 GiB, 8 MiB beyond: a volume at 2 TB - 16 MiB (8 MiB aligned) is reached.
        let size: Int64 = 2_000_000_000_000 / (8 << 20) * (8 << 20)
        let at = size - (16 << 20)
        let reader = FaultyDevice(size: size, regions: [(at, exfatImage())])
        let result = try await VolumeDiscovery(reader: reader).discover()
        #expect(result.extents.map(\.offset) == [at])
        #expect(!result.probesTruncated)
        #expect(VolumeDiscovery.nextCandidate(after: 64 << 30, fineUntil: 0, pass: .coarse) == (64 << 30) + (8 << 20))
        #expect(VolumeDiscovery.nextCandidate(after: 1 << 30, fineUntil: 0, pass: .coarse) == (1 << 30) + (1 << 20))
    }

    @Test func candidatesAreCappedAndTooSmallVolumesDropped() async throws {
        // A header claiming under 64 KiB is not a plausible volume.
        var small = exfatImage(); small.put(72, 64, 8)                       // 32 KiB
        #expect(try await discover(device(size: 2 * mib, [(mib, small)])).map(\.format) == [.raw])
        // 300 abutting 64 KiB exFAT headers: the first 256 are kept, in device order, and the cap is reported.
        let boot = exfatImage().prefix(512)
        let headers = (0..<300).map { (mib + $0 * 65536, Data(boot)) }
        let result = try await VolumeDiscovery(reader: ImageReader(data: device(size: mib + 300 * 65536 + mib, headers))).discover()
        #expect(result.extents.count == 256)
        #expect(result.extents.map(\.offset) == (0..<256).map { Int64(mib + $0 * 65536) })
        #expect(result.probesTruncated && result.warnings.contains { $0.contains("after 256 candidates") })
    }

    @Test func damagedPartitionTableIsIgnoredAndTheDeviceSearched() async throws {
        // An MBR entry that runs past the device end used to stop discovery; now it is reported and
        // the volume it pointed at is found by signature.
        let volume = exfatImage()
        let image = device(size: 2 * mib, [(mib, volume)], mbr: [(mib / 512, 4 * mib / 512)])
        let result = try await VolumeDiscovery(reader: ImageReader(data: image)).discover()
        #expect(result.extents.map(\.offset) == [Int64(mib)] && result.extents.allSatisfy { $0.isLost })
        #expect(result.warnings.contains { $0.hasPrefix("The partition table is damaged and was ignored") })
        let events = await scan(image)
        #expect(found(events).map(\.path) == ["/file.txt"])
        #expect(events.last == .completed)
    }

    @Test func blockReaderPortHasNoWriteRequirement() {
        // A conformer with nothing but `read` compiles: the Core port can't be used to write a partition table.
        struct ReadOnly: BlockReader {
            let sizeBytes: Int64 = 512
            func read(at offset: Int64, count: Int) async throws -> Data { Data(count: count) }
        }
        #expect(ReadOnly().logicalBlockSize == 512)
    }
}

private actor CountingReader: BlockReader {
    let data: Data
    nonisolated let sizeBytes: Int64
    var reads = 0
    init(data: Data) { self.data = data; self.sizeBytes = Int64(data.count) }
    func read(at offset: Int64, count: Int) async throws -> Data {
        reads += 1
        return try await ImageReader(data: data).read(at: offset, count: count)
    }
}

/// A device of `size` zero bytes with `regions` laid over it, whose reads fail with `.io` wherever
/// `fails(offset, count)` says. Large sizes cost nothing: only the requested bytes are built.
private struct FaultyDevice: BlockReader {
    let sizeBytes: Int64
    let regions: [(Int64, Data)]
    let fails: @Sendable (Int64, Int) -> Bool
    init(size: Int64, regions: [(Int64, Data)] = [], fails: @escaping @Sendable (Int64, Int) -> Bool = { _, _ in false }) {
        sizeBytes = size; self.regions = regions; self.fails = fails
    }
    init(data: Data, fails: @escaping @Sendable (Int64, Int) -> Bool) {
        self.init(size: Int64(data.count), regions: [(0, data)], fails: fails)
    }
    func read(at offset: Int64, count: Int) async throws -> Data {
        try Task.checkCancellation()
        guard offset >= 0, Int64(count) <= sizeBytes - offset else { throw ScanError.io("Out of bounds") }
        if fails(offset, count) { throw ScanError.io("Injected read error") }
        var data = Data(count: count)
        let end = offset + Int64(count)
        for (start, bytes) in regions where start < end && offset < start + Int64(bytes.count) {
            let from = max(start, offset), to = min(start + Int64(bytes.count), end)
            data.replaceSubrange(Int(from - offset)..<Int(to - offset), with: bytes[Int(from - start)..<Int(to - start)])
        }
        return data
    }
}
