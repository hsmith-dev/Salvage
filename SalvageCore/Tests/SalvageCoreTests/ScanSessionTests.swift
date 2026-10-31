import Foundation
import Testing
@testable import SalvageCore

struct ImageReader: BlockReader {
    let data: Data
    var logicalBlockSize: Int = 512
    var sizeBytes: Int64 { Int64(data.count) }
    func read(at offset: Int64, count: Int) async throws -> Data {
        try Task.checkCancellation()
        guard offset >= 0, offset <= sizeBytes, Int64(count) <= sizeBytes - offset else { throw ScanError.io("Out of bounds") }
        return data.subdata(in: Int(offset)..<Int(offset)+count)
    }
}

extension Data {
    mutating func put(_ offset: Int, _ value: UInt64, _ width: Int) {
        for index in 0..<width { self[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8)) }
    }
    mutating func text(_ offset: Int, _ text: String) { replaceSubrange(offset..<offset+text.utf8.count, with: text.utf8) }
}

func fatImage(nested: Bool = true) -> Data {
    var image = Data(repeating: 0, count: 66560 * 512)
    image.put(0, 0xeb, 1); image.put(11, 512, 2); image.put(13, 1, 1); image.put(14, 32, 2)
    image.put(16, 1, 1); image.put(32, 66560, 4); image.put(36, 520, 4); image.put(44, 2, 4)
    image.put(510, 0xaa55, 2)
    let fat = 32 * 512, root = 552 * 512
    image.put(fat, 0xffffff8, 4); image.put(fat + 4, 0xfffffff, 4)
    for c in 2...5 { image.put(fat + c*4, 0xfffffff, 4) }
    image.text(root, "HELLO   TXT"); image.put(root+26, 3, 2); image.put(root+28, 5, 4)
    image.text(root + 512, "hello")
    if nested {
        image.text(root+32, "FOLDER     "); image.put(root+43, 0x10, 1); image.put(root+58, 4, 2)
        let directory = root + 1024
        image.text(directory, "NESTED  TXT"); image.put(directory+26, 5, 2); image.put(directory+28, 3, 4)
        image.text(root+1536, "abc")
    }
    return image
}

func exfatImage() -> Data {
    var image = Data(repeating: 0, count: 128 * 512)
    image.text(3, "EXFAT   "); image.put(72, 128, 8); image.put(80, 24, 4); image.put(84, 1, 4)
    image.put(88, 25, 4); image.put(92, 100, 4); image.put(96, 2, 4); image.put(104, 0x100, 2)
    image.put(108, 9, 1); image.put(109, 0, 1); image.put(110, 1, 1); image.put(510, 0xaa55, 2)
    image.put(24*512+8, 0xffffffff, 4)
    let root = 25*512
    image.put(root, 0x85, 1); image.put(root+1, 2, 1)
    image.put(root+32, 0xc0, 1); image.put(root+33, 3, 1); image.put(root+35, 8, 1)
    image.put(root+40, 5, 8); image.put(root+52, 3, 4); image.put(root+56, 5, 8)
    image.put(root+64, 0xc1, 1)
    for (index, unit) in "file.txt".utf16.enumerated() { image.put(root+66+index*2, UInt64(unit), 2) }
    var sum: UInt16 = 0
    for index in 0..<96 where index != 2 && index != 3 { sum = ((sum & 1) << 15) &+ (sum >> 1) &+ UInt16(image[root+index]) }
    image.put(root+2, UInt64(sum), 2); image.text(26*512, "hello")
    image.put(root+96, 0x81, 1); image.put(root+116, 100, 4); image.put(root+120, 13, 8)
    image.put(24*512+100*4, 0xffffffff, 4)
    image.replaceSubrange(123*512..<123*512+13, with: Data(repeating: 0xff, count: 13))
    for index in 1...8 { image.put(512 * (index + 1) - 4, 0xaa550000, 4) }
    var bootSum: UInt32 = 0
    for index in 0..<512*11 where index != 106 && index != 107 && index != 112 {
        bootSum = ((bootSum & 1) << 31) &+ (bootSum >> 1) &+ UInt32(image[index])
    }
    for index in stride(from: 512*11, to: 512*12, by: 4) { image.put(index, UInt64(bootSum), 4) }
    return image
}

func scan(_ image: Data, logicalBlockSize: Int = 512) async -> [ScanEvent] {
    let (stream, events) = AsyncStream<ScanEvent>.makeStream()
    await ScanSession(reader: ImageReader(data: image, logicalBlockSize: logicalBlockSize)).run(events: events)
    var result: [ScanEvent] = []
    for await event in stream { result.append(event) }
    return result
}

@Suite("Read-only filesystem scanning")
struct ScanSessionTests {
    @Test func FAT32StreamsNestedFilesAndMeasuredCompletion() async {
        let image = fatImage(), original = image
        let events = await scan(image)
        let files = events.compactMap { if case .found(let file) = $0 { file } else { nil } }
        #expect(files.map(\.path) == ["/HELLO.TXT", "/FOLDER/NESTED.TXT"])
        #expect(files.map(\.sizeBytes) == [5, 3])
        #expect(files.first?.sourceMetadata.recordOffset == Int64(552 * 512))
        #expect(events.last == .completed)
        #expect(events.contains(.progress(bytesScanned: Int64(image.count), totalBytes: Int64(image.count))))
        #expect(image == original)
    }
    @Test func validLongFilenameAndChecksumFallback() async {
        var image = fatImage(nested: false)
        let root = 552*512
        let entry = image.subdata(in: root..<root+32)
        var long = Data(repeating: 0xff, count: 32)
        long[0] = 0x41; long[11] = 0x0f; long[12] = 0; long[26] = 0; long[27] = 0
        var checksum: UInt8 = 0
        for byte in entry.prefix(11) { checksum = ((checksum & 1) << 7) &+ (checksum >> 1) &+ byte }
        long[13] = checksum
        let offsets = [1,3,5,7,9,14,16,18,20,22,24,28,30]
        for (index, unit) in "Long name.txt".utf16.enumerated() { long.put(offsets[index], UInt64(unit), 2) }
        image.replaceSubrange(root..<root+32, with: long)
        image.replaceSubrange(root+32..<root+64, with: entry)
        let events = await scan(image)
        #expect(events.contains { if case .found(let file) = $0 { file.path == "/Long name.txt" } else { false } })
        image[root+13] ^= 1
        #expect((await scan(image)).contains { if case .found(let file) = $0 { file.path == "/HELLO.TXT" } else { false } })
    }
    @Test func priorDiscoveriesSurviveLaterCorruption() async {
        var image = fatImage(nested: false)
        let root = 552*512
        image.text(root+32, "BROKEN  TXT"); image.put(root+58, 4, 2); image.put(root+60, 5, 4)
        image.put(32*512+4*4, 4, 4)
        let events = await scan(image)
        #expect(events.contains { if case .found(let file) = $0 { file.name == "HELLO.TXT" } else { false } })
        #expect(events.contains { if case .error(.malformed) = $0 { true } else { false } })
        #expect(!events.contains(.completed))
    }
    @Test func discoveryIsDeliveredWhileScanStillRuns() async {
        let (stream, events) = AsyncStream<ScanEvent>.makeStream()
        let task = Task { await ScanSession(reader: SlowSweepReader(data: fatImage(nested: false))).run(events: events) }
        var found = false, completed = false
        for await event in stream {
            if case .found = event { found = true; task.cancel() }
            if case .completed = event { completed = true }
        }
        await task.value
        #expect(found && !completed)
    }
    @Test func exFATContiguousFileDoesNotReadItsUnusedFATEntry() async {
        let events = await scan(exfatImage())
        #expect(events.last == .completed)
        #expect(events.contains { if case .found(let file) = $0 { file.path == "/file.txt" && file.sourceMetadata.contiguous } else { false } })
    }
    @Test func exFATNestedContiguousDirectory() async {
        var image = exfatImage()
        let root = 25*512
        var directory = image.subdata(in: root..<root+96)
        directory.put(4, 0x10, 2); directory.put(35, 6, 1)
        directory.put(40, 512, 8); directory.put(52, 4, 4); directory.put(56, 512, 8)
        for (index, unit) in "folder".utf16.enumerated() { directory.put(66+index*2, UInt64(unit), 2) }
        var nested = image.subdata(in: root..<root+96)
        nested.put(35, 10, 1); nested.put(52, 5, 4)
        for (index, unit) in "nested.txt".utf16.enumerated() { nested.put(66+index*2, UInt64(unit), 2) }
        for (offset, set) in [(root+128, directory), (27*512, nested)] {
            var set = set
            var checksum: UInt16 = 0
            for index in set.indices where index != 2 && index != 3 {
                checksum = ((checksum & 1) << 15) &+ (checksum >> 1) &+ UInt16(set[index])
            }
            set.put(2, UInt64(checksum), 2)
            image.replaceSubrange(offset..<offset+96, with: set)
        }
        image.text(28*512, "hello")
        let events = await scan(image)
        #expect(events.last == .completed)
        #expect(events.contains { if case .found(let file) = $0 { file.path == "/folder/nested.txt" } else { false } })
    }
    @Test func benignExFATSecondaryExtensionIsSkipped() async {
        var image = exfatImage(); let root = 25*512
        let bitmap = image.subdata(in: root+96..<root+128)
        image.replaceSubrange(root+128..<root+160, with: bitmap)
        image.replaceSubrange(root+96..<root+128, with: Data(repeating: 0, count: 32))
        image[root+96] = 0xe0; image[root+1] = 3
        updateSetChecksum(&image, offset: root, count: 128)
        let result = await scan(image)
        #expect(result.last == .completed)
        #expect(result.contains { if case .found(let file) = $0 { file.name == "file.txt" } else { false } })
    }
    @Test func activeBitmapRejectsFreeAndPartiallyAllocatedStreams() async {
        let root = 25*512
        var free = exfatImage(); free[123*512] &= ~UInt8(2)
        let result = await scan(free)
        #expect(!result.contains { if case .found = $0 { true } else { false } })
        #expect(result.contains { if case .error(.malformed) = $0 { true } else { false } })
        var partial = exfatImage()
        partial.put(root+40, 600, 8); partial.put(root+56, 600, 8)
        updateSetChecksum(&partial, offset: root, count: 96)
        partial[123*512] &= ~UInt8(4)
        #expect(!(await scan(partial)).contains(.completed))
    }
    @Test func crossLinkedFilesAndDirectoryAreRejected() async {
        var files = fatImage(nested: false); let root = 552*512
        files.text(root+32, "SECOND  TXT"); files.put(root+58, 3, 2); files.put(root+60, 5, 4)
        #expect(!(await scan(files)).contains(.completed))
        var directory = fatImage(); directory.put(root+58, 3, 2)
        #expect(!(await scan(directory)).contains(.completed))
    }
    @Test func malformedFilenameEncodingsAreNotSilentlyReplaced() async {
        let root = 552*512
        for units: [UInt16] in [[65, 0, 66], [0xd800, 65]] {
            var image = fatImage(nested: false)
            let entry = image.subdata(in: root..<root+32)
            var long = Data(repeating: 0xff, count: 32)
            long[0] = 0x41; long[11] = 0x0f; long[12] = 0; long[26] = 0; long[27] = 0
            var sum: UInt8 = 0
            for byte in entry.prefix(11) { sum = ((sum & 1) << 7) &+ (sum >> 1) &+ byte }
            long[13] = sum
            for (index, unit) in units.enumerated() { long.put(1+index*2, UInt64(unit), 2) }
            image.replaceSubrange(root..<root+32, with: long); image.replaceSubrange(root+32..<root+64, with: entry)
            #expect((await scan(image)).contains { if case .found(let file) = $0 { file.name == "HELLO.TXT" } else { false } })
        }
        var exfat = exfatImage(); exfat.put(25*512+66, 0xd800, 2)
        updateSetChecksum(&exfat, offset: 25*512, count: 96)
        #expect(!(await scan(exfat)).contains(.completed))
    }
    @Test func adjacentFATChainUsesBoundedCachedPages() async throws {
        var image = fatImage(nested: false)
        image.put(552*512+28, 1000*512, 4)
        for cluster in 3..<1002 { image.put(32*512+cluster*4, UInt64(cluster+1), 4) }
        image.put(32*512+1002*4, 0xfffffff, 4)
        let reader = CountingImageReader(data: image)
        let volume = FATVolume(reader: reader, extent: VolumeExtent(offset: 0, length: Int64(image.count)), emit: { _ in })
        try await volume.scan()
        #expect(await reader.fatReads == 1)
    }
    @Test func boundedSlowConsumerReceivesEveryDiscoveryAndTerminalEvent() async {
        var image = fatImage(nested: false); let root = 552*512
        image.replaceSubrange(root..<root+512, with: Data(repeating: 0, count: 512))
        for index in 0..<12 {
            image.text(root+index*32, String(format: "F%07dTXT", index))
            image.put(root+index*32+26, UInt64(index+3), 2); image.put(root+index*32+28, 1, 4)
            image.put(32*512+(index+3)*4, 0xfffffff, 4)
        }
        let (stream, events) = AsyncStream<ScanEvent>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let source = image
        let task = Task { await ScanSession(reader: ImageReader(data: source)).run(events: events) }
        var discoveries = 0, completed = false
        for await event in stream {
            for _ in 0..<100 { await Task.yield() }
            if case .found = event { discoveries += 1 }
            if case .completed = event { completed = true }
        }
        await task.value
        #expect(discoveries == 12 && completed)
    }
    @Test func boundedConsumerReceivesErrorAndFullQueueCancellationTerminates() async {
        var image = fatImage(nested: false); let root = 552*512
        image.text(root+32, "BROKEN  TXT"); image.put(root+58, 4, 2); image.put(root+60, 5, 4)
        image.put(32*512+4*4, 4, 4)
        let source = image
        let (stream, events) = AsyncStream<ScanEvent>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let task = Task { await ScanSession(reader: ImageReader(data: source)).run(events: events) }
        var found = false, failed = false
        for await event in stream {
            for _ in 0..<100 { await Task.yield() }
            if case .found = event { found = true }
            if case .error = event { failed = true }
        }
        await task.value
        #expect(found && failed)
        let (cancelStream, cancelEvents) = AsyncStream<ScanEvent>.makeStream(bufferingPolicy: .bufferingOldest(1))
        cancelEvents.yield(.progress(bytesScanned: 0, totalBytes: 1))
        let blocked = Task { try await cancelEvents.send(.completed) }
        for _ in 0..<100 { await Task.yield() }
        blocked.cancel()
        await #expect(throws: CancellationError.self) { try await blocked.value }
        cancelEvents.finish()
        for await event in cancelStream { #expect(event != .completed) }
    }
    @Test func measuredProgressUsesInjectedCadenceBeforeCompletion() async {
        let clock = AdvancingClock()
        let reader = AdvancingReader(data: fatImage(nested: false), clock: clock)
        let (stream, events) = AsyncStream<ScanEvent>.makeStream()
        await ScanSession(reader: reader, progressInterval: .milliseconds(500), now: { clock.now() }).run(events: events)
        var intermediate: [Int64] = []
        for await event in stream {
            if case .progress(let bytes, let total) = event, bytes > 0 && bytes < total { intermediate.append(bytes) }
        }
        #expect(intermediate.count == 7)
        #expect(intermediate.first == Int64(2 * 1024 * 1024))
        // Each extent read advances 100 ms and covers 1 MiB, so a 500 ms cadence must
        // produce exactly five MiB of new measured work between intermediate updates.
        #expect(zip(intermediate, intermediate.dropFirst()).allSatisfy { $1 - $0 == 5 * 1024 * 1024 })
    }
    @Test func corruptExFATEntryChecksumStopsScan() async {
        var image = exfatImage(); image[25*512+66] ^= 1
        let events = await scan(image)
        #expect(!events.contains(.completed))
        #expect(events.contains { if case .error(.malformed) = $0 { true } else { false } })
    }
    @Test func fileAllocationCycleStopsWithoutCompletion() async {
        var image = fatImage(nested: false); image.put(32*512+3*4, 3, 4)
        let events = await scan(image)
        #expect(!events.contains(.completed))
        #expect(events.contains { if case .error(.malformed) = $0 { true } else { false } })
    }
    @Test func unsupportedAndTruncatedImagesAreErrors() async {
        for image in [Data(repeating: 0, count: 512), Data(repeating: 0, count: 12)] {
            let events = await scan(image)
            #expect(!events.contains(.completed))
            #expect(events.contains { if case .error = $0 { true } else { false } })
        }
    }
    @Test func MBRPartitionIsBounded() async {
        let volume = exfatImage()
        var image = Data(repeating: 0, count: 512) + volume
        image.put(446+4, 7, 1); image.put(446+8, 1, 4); image.put(446+12, 128, 4); image.put(510, 0xaa55, 2)
        let events = await scan(image)
        #expect(events.last == .completed)
        #expect(events.contains { if case .found(let file) = $0 { file.sourceMetadata.volumeOffset == 512 } else { false } })
        image.put(446+12, 129, 4)
        #expect(!(await scan(image)).contains(.completed))
    }
    @Test func recognizedButUnimplementedVolumesAreSkipped() async {
        let volume = exfatImage()
        let sectors = volume.count / 512
        var ntfs = Data(repeating: 0, count: 8 * 512)
        ntfs.replaceSubrange(3..<11, with: Data("NTFS    ".utf8))
        var image = Data(repeating: 0, count: 512) + volume + ntfs
        image.put(446+4, 7, 1); image.put(446+8, 1, 4); image.put(446+12, UInt64(sectors), 4)
        image.put(446+16+4, 7, 1); image.put(446+16+8, UInt64(1 + sectors), 4); image.put(446+16+12, 8, 4)
        image.put(510, 0xaa55, 2)
        let events = await scan(image)
        #expect(events.last == .completed)
        #expect(events.contains(.progress(bytesScanned: Int64(volume.count), totalBytes: Int64(volume.count))))
        #expect(events.allSatisfy { if case .found(let file) = $0 { file.sourceMetadata.volumeOffset == 512 } else { true } })
    }
    @Test(arguments: ["ntfs"]) func wholeDiskUnimplementedFormatIsUnsupported(_ kind: String) async {
        var image = Data(repeating: 0, count: 16 * 512)
        if kind == "ntfs" { image.replaceSubrange(3..<11, with: Data("NTFS    ".utf8)) }
        else { image.put(1024 + 56, 0xef53, 2) }
        let events = await scan(image)
        #expect(events == [.error(.unsupportedFilesystem)])
    }
    @Test func cancellationNeverCompletes() async {
        let (stream, events) = AsyncStream<ScanEvent>.makeStream()
        let task = Task {
            try? await Task.sleep(for: .seconds(10))
            await ScanSession(reader: ImageReader(data: exfatImage())).run(events: events)
        }
        task.cancel(); await task.value
        var result: [ScanEvent] = []
        for await event in stream { result.append(event) }
        #expect(result.isEmpty)
    }
    @Test func GPTPartitionWithChecksumsScansWithinExtent() async {
        var image = Data(repeating: 0, count: 256*512)
        image.replaceSubrange(64*512..<192*512, with: exfatImage())
        image.put(510, 0xaa55, 2); image.put(450, 0xee, 1)
        image.put(454, 1, 4); image.put(458, 255, 4)
        var table = Data(repeating: 0, count: 128)
        table.put(0, 1, 1); table.put(16, 1, 1); table.put(32, 64, 8); table.put(40, 191, 8)
        image.replaceSubrange(1024..<1152, with: table)
        var header = Data(repeating: 0, count: 512)
        header.text(0, "EFI PART"); header.put(8, 0x10000, 4); header.put(12, 92, 4)
        header.put(24, 1, 8); header.put(32, 255, 8); header.put(40, 34, 8); header.put(48, 222, 8)
        header.put(72, 2, 8); header.put(80, 1, 4); header.put(84, 128, 4)
        header.put(88, UInt64(crc32(table)), 4)
        header.put(16, UInt64(crc32(header.subdata(in: 0..<92))), 4)
        image.replaceSubrange(512..<1024, with: header)
        let events = await scan(image)
        #expect(events.last == .completed)
        #expect(events.contains { if case .found(let file) = $0 { file.sourceMetadata.volumeOffset == 64*512 } else { false } })
        #expect(events.contains(.progress(bytesScanned: 128*512, totalBytes: 128*512)))
        image[1024] ^= 1
        #expect(!(await scan(image)).contains(.completed))
    }
    @Test func corruptBootAndTruncatedVolumeStop() async {
        var image = exfatImage(); image[120] ^= 1
        #expect(!(await scan(image)).contains(.completed))
        #expect(!(await scan(exfatImage().dropLast(512))).contains(.completed))
    }
    @Test func overflowingLengthAndUnsupportedLogicalSectorsRefuse() async {
        var image = exfatImage(); image.put(72, UInt64.max, 8)
        let overflow = await scan(image)
        #expect(!overflow.contains(.completed))
        #expect(overflow.contains { if case .error(.malformed) = $0 { true } else { false } })
        let sectors = await scan(exfatImage(), logicalBlockSize: 4096)
        #expect(!sectors.contains(.completed))
        #expect(sectors.contains { if case .error(.malformed(let reason)) = $0 { reason.contains("512-byte logical sectors") } else { false } })
    }
    @Test(arguments: ["end marker", "volume label", "dot entry", "chain exhausted"])
    func orphanedLongFilenameRunIsMalformed(_ terminator: String) async {
        var image = fatImage(nested: false); let root = 552*512
        switch terminator {
        case "end marker":
            image.replaceSubrange(root+32..<root+64, with: lfnSlot())
        case "volume label":
            image.replaceSubrange(root+32..<root+64, with: lfnSlot())
            image.text(root+64, "LABEL      "); image.put(root+75, 0x08, 1)
        case "dot entry":
            image.replaceSubrange(root+32..<root+64, with: lfnSlot())
            image.text(root+64, ".          "); image.put(root+75, 0x10, 1)
        default:
            // Every remaining slot of the single-cluster root holds LFN entries, so the chain ends mid-run.
            for slot in stride(from: root+32, to: root+512, by: 32) { image.replaceSubrange(slot..<slot+32, with: lfnSlot()) }
        }
        let events = await scan(image)
        #expect(events.contains { if case .found(let file) = $0 { file.name == "HELLO.TXT" } else { false } })
        #expect(events.contains { if case .error(.malformed(let reason)) = $0 { reason.contains("long filename") } else { false } })
        #expect(!events.contains(.completed))
    }
    @Test func deletedLongFilenameSlotsAreStillTolerated() async {
        let root = 552*512
        // Deleted LFN slots followed by their deleted short entry, then the end marker.
        var deletedSet = fatImage(nested: false)
        var deleted = lfnSlot(); deleted[0] = 0xe5
        deletedSet.replaceSubrange(root+32..<root+64, with: deleted)
        deletedSet.text(root+64, "XDELETEDTXT"); deletedSet[root+64] = 0xe5
        // A deleted LFN slot directly before the end marker.
        var deletedThenEnd = fatImage(nested: false)
        deletedThenEnd.replaceSubrange(root+32..<root+64, with: deleted)
        // A live LFN run whose short entry was deleted keeps the existing reset behavior.
        var liveThenDeleted = fatImage(nested: false)
        liveThenDeleted.replaceSubrange(root+32..<root+64, with: lfnSlot())
        liveThenDeleted.text(root+64, "XDELETEDTXT"); liveThenDeleted[root+64] = 0xe5
        for image in [deletedSet, deletedThenEnd, liveThenDeleted] {
            let events = await scan(image)
            #expect(events.last == .completed)
            #expect(events.contains { if case .found(let file) = $0 { file.name == "HELLO.TXT" } else { false } })
        }
    }
    @Test func exFATUpcaseTableIsClaimedAgainstCrossLinks() async {
        let root = 25*512
        func withUpcase(cluster: UInt32, length: UInt64) -> Data {
            var image = exfatImage()
            image.put(root+128, 0x82, 1); image.put(root+148, UInt64(cluster), 4); image.put(root+152, length, 8)
            image.put(24*512 + Int(cluster)*4, 0xffffffff, 4)
            return image
        }
        let valid = await scan(withUpcase(cluster: 10, length: 5))
        #expect(valid.last == .completed)
        #expect(valid.contains { if case .found(let file) = $0 { file.name == "file.txt" } else { false } })
        // The contiguous file occupies cluster 3; an up-case table chained there is a cross-link.
        let overlap = await scan(withUpcase(cluster: 3, length: 5))
        #expect(!overlap.contains(.completed))
        #expect(overlap.contains { if case .error(.malformed(let reason)) = $0 { reason.contains("Cross-linked") } else { false } })
        // An up-case length larger than its one-cluster chain is truncated metadata.
        let truncated = await scan(withUpcase(cluster: 10, length: 5000))
        #expect(!truncated.contains(.completed))
        #expect(truncated.contains { if case .error(.malformed) = $0 { true } else { false } })
    }
    @Test func measuredCoverageStaysExactAcrossManyDisjointReads() async throws {
        let size = 1 << 18
        let reader = MeasuredReader(base: ImageReader(data: Data(repeating: 0, count: size)),
                                    extents: [VolumeExtent(offset: 0, length: Int64(size))], total: Int64(size),
                                    emit: { _ in }, interval: .seconds(3600), now: { .zero })
        var covered = [Bool](repeating: false, count: size)
        var order = Array(0..<4096), seed: UInt64 = 0x9e3779b97f4a7c15
        for index in order.indices.reversed() {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            order.swapAt(index, Int(seed >> 33) % (index + 1))
        }
        // 4096 disjoint 8-byte reads in shuffled order, then touching and overlapping bridges.
        var reads = order.map { ($0 * 64, 8) }
        reads += (0..<512).map { ($0 * 64 + 8, 8) } + (512..<1024).map { ($0 * 64 + 4, 40) }
        for (offset, count) in reads {
            _ = try await reader.read(at: Int64(offset), count: count)
            for byte in offset..<offset+count { covered[byte] = true }
        }
        #expect(await reader.measured == Int64(covered.filter { $0 }.count))
        let ranges = await reader.ranges
        #expect(zip(ranges, ranges.dropFirst()).allSatisfy { $0.upperBound < $1.lowerBound })
        #expect(ranges.reduce(0) { $0 + $1.count } == covered.filter { $0 }.count)
        _ = try await reader.read(at: 0, count: size)
        #expect(await reader.measured == Int64(size))
        #expect(await reader.ranges == [0..<Int64(size)])
    }
    @Test func invalidGPTChecksumFails() async {
        var image = Data(repeating: 0, count: 128*512)
        image.put(510, 0xaa55, 2); image.put(450, 0xee, 1)
        image.text(512, "EFI PART"); image.put(524, 92, 4); image.put(536, 1, 8)
        let events = await scan(image)
        #expect(events.contains { if case .error(.malformed) = $0 { true } else { false } })
        #expect(!events.contains(.completed))
    }
}

private struct SlowSweepReader: BlockReader {
    let data: Data
    var sizeBytes: Int64 { Int64(data.count) }
    func read(at offset: Int64, count: Int) async throws -> Data {
        if count >= 1024*1024 { try await Task.sleep(for: .seconds(60)) }
        try Task.checkCancellation()
        return try await ImageReader(data: data).read(at: offset, count: count)
    }
}

private func lfnSlot() -> Data {
    var long = Data(repeating: 0xff, count: 32)
    long[0] = 0x41; long[11] = 0x0f; long[12] = 0; long[13] = 0; long[26] = 0; long[27] = 0
    long.put(1, UInt64(UInt8(ascii: "x")), 2); long.put(3, 0, 2)
    return long
}
private func updateSetChecksum(_ data: inout Data, offset: Int, count: Int) {
    var sum: UInt16 = 0
    for index in 0..<count where index != 2 && index != 3 {
        sum = ((sum & 1) << 15) &+ (sum >> 1) &+ UInt16(data[offset+index])
    }
    data.put(offset+2, UInt64(sum), 2)
}
private actor CountingImageReader: BlockReader {
    let data: Data
    nonisolated let sizeBytes: Int64
    var fatReads = 0
    init(data: Data) { self.data = data; self.sizeBytes = Int64(data.count) }
    func read(at offset: Int64, count: Int) async throws -> Data {
        if offset >= 32*512 && offset < 552*512 { fatReads += 1 }
        return data.subdata(in: Int(offset)..<Int(offset)+count)
    }
}
private final class AdvancingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Duration = .zero

    func advance() { lock.withLock { value += .milliseconds(100) } }
    func now() -> Duration { lock.withLock { value } }
}
private struct AdvancingReader: BlockReader {
    let data: Data
    let clock: AdvancingClock
    var sizeBytes: Int64 { Int64(data.count) }
    func read(at offset: Int64, count: Int) async throws -> Data {
        clock.advance()
        return data.subdata(in: Int(offset)..<Int(offset)+count)
    }
}
