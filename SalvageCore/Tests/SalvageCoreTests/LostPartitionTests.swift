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
    try await VolumeDiscovery(reader: ImageReader(data: image)).discover()
}
private func ntfsHeader(totalSectors: UInt64) -> Data {
    var boot = Data(repeating: 0, count: 512)
    boot.text(3, "NTFS    "); boot.put(11, 512, 2); boot.put(13, 8, 1); boot.put(0x28, totalSectors, 8); boot.put(510, 0xaa55, 2)
    return boot
}

@Suite("Lost partitions: discovery in unallocated space (FR-9) and read-only recovery (FR-10)")
struct LostPartitionTests {
    @Test func volumeWithoutAPartitionTableIsFoundAnnouncedFirstAndScanned() async {
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
        // Announced before any file, so the app can show the card while files stream in.
        let firstLost = events.firstIndex { if case .lostPartitionFound = $0 { true } else { false } } ?? .max
        let firstFound = events.firstIndex { if case .found = $0 { true } else { false } } ?? .min
        #expect(firstLost < firstFound)
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
        #expect(lost(events).map(\.formatName) == ["NTFS"])
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
        var damaged = exfatImage(); damaged[25 * 512 + 66] ^= 1   // corrupt entry-set checksum
        let known = exfatImage()
        let events = await scan(device(size: 4 * mib, [(mib, damaged), (2 * mib, known)], mbr: [(2 * mib / 512, known.count / 512)]))
        #expect(lost(events).map(\.offset) == [Int64(mib)])
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
        #expect(limited.map(\.format) == [.raw])
        // The whole-device check (two header reads) plus at most two header reads per probe.
        let reads = await counting.reads
        #expect(reads <= 2 + 2 * 4)
        let task = Task {
            try? await Task.sleep(for: .seconds(10))
            return try await discover(image)
        }
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
