import Foundation
import Testing
@testable import SalvageCore

@Suite("Pause, resume, cancel and checkpoints")
struct ScanPauseTests {
    @Test func pausedScanIssuesNoReadsAndResumeCompletes() async throws {
        let reader = RecordingReader(data: fatImage())
        let gate = ScanPauseGate()
        gate.pause()
        let (stream, events) = AsyncStream<ScanEvent>.makeStream()
        let task = Task { await ScanSession(reader: reader).run(events: events, pauseGate: gate) }
        try await waitUntil { gate.waiterCount == 1 }
        let readsWhilePaused = reader.reads.count
        try await Task.sleep(for: .milliseconds(150))
        #expect(reader.reads.count == readsWhilePaused)
        #expect(gate.isPaused)
        gate.resume()
        await task.value
        var collected: [ScanEvent] = []
        for await event in stream { collected.append(event) }
        #expect(collected.last == .completed)
        #expect(collected.contains(.progress(bytesScanned: reader.sizeBytes, totalBytes: reader.sizeBytes)))
    }

    @Test func midSweepPauseResumesFromTheSamePoint() async throws {
        let gate = ScanPauseGate()
        let reader = RecordingReader(data: fatImage()) { reads in
            if reads.filter({ $0.count == 1024 * 1024 }).count == 5 { gate.pause() }
        }
        let (stream, events) = AsyncStream<ScanEvent>.makeStream()
        let task = Task { await ScanSession(reader: reader).run(events: events, pauseGate: gate) }
        try await waitUntil { gate.waiterCount == 1 }
        let readsWhilePaused = reader.reads.count
        try await Task.sleep(for: .milliseconds(150))
        #expect(reader.reads.count == readsWhilePaused)
        gate.resume()
        await task.value
        var collected: [ScanEvent] = []
        for await event in stream { collected.append(event) }
        #expect(collected.last == .completed)
        let sweep = reader.reads.filter { $0.count == 1024 * 1024 }.map(\.offset)
        // Full 1 MiB sweep chunks: each issued exactly once, in order, with none repeated after resume.
        #expect(sweep == Array(stride(from: Int64(0), to: reader.sizeBytes - 1024 * 1024 + 1, by: 1024 * 1024)))
    }

    @Test func cancelWhilePausedEndsPromptlyWithoutCompleting() async throws {
        let reader = RecordingReader(data: fatImage())
        let gate = ScanPauseGate()
        gate.pause()
        let (stream, events) = AsyncStream<ScanEvent>.makeStream()
        let task = Task { await ScanSession(reader: reader).run(events: events, pauseGate: gate) }
        try await waitUntil { gate.waiterCount == 1 }
        let readsWhilePaused = reader.reads.count
        let clock = ContinuousClock()
        let started = clock.now
        task.cancel()
        await task.value
        #expect(clock.now - started < .seconds(2))
        var collected: [ScanEvent] = []
        for await event in stream { collected.append(event) }
        #expect(!collected.contains(.completed))
        #expect(!collected.contains { if case .error = $0 { true } else { false } })
        #expect(reader.reads.count == readsWhilePaused)
        #expect(gate.waiterCount == 0)
    }

    @Test func checkpointsAdvanceMonotonically() async {
        let image = fatImage()
        let (_, checkpoints) = await scanCollectingCheckpoints(image)
        #expect(checkpoints.count == (image.count + 1024 * 1024 - 1) / (1024 * 1024))
        for (previous, next) in zip(checkpoints, checkpoints.dropFirst()) {
            #expect((previous.sweepVolumeIndex, previous.sweepOffset) < (next.sweepVolumeIndex, next.sweepOffset))
            #expect(previous.bytesScanned <= next.bytesScanned)
        }
        #expect(checkpoints.allSatisfy { $0.isWellFormed && $0.totalBytes == Int64(image.count) && $0.deviceSizeBytes == Int64(image.count) })
        #expect(checkpoints.last?.sweepOffset == Int64(image.count))
        #expect(checkpoints.last?.bytesScanned == Int64(image.count))
    }

    @Test func resumingFromMidSweepCheckpointCompletesWithSameDiscoveries() async throws {
        let image = fatImage()
        let (fullEvents, checkpoints) = await scanCollectingCheckpoints(image)
        let checkpoint = try #require(checkpoints.dropFirst(checkpoints.count / 2).first)
        let reader = RecordingReader(data: image)
        let (stream, events) = AsyncStream<ScanEvent>.makeStream()
        await ScanSession(reader: reader).run(events: events, resumingFrom: checkpoint)
        var resumed: [ScanEvent] = []
        for await event in stream { resumed.append(event) }
        #expect(resumed.last == .completed)
        #expect(resumed.first == .progress(bytesScanned: checkpoint.sweepOffset, totalBytes: Int64(image.count)))
        #expect(resumed.contains(.progress(bytesScanned: Int64(image.count), totalBytes: Int64(image.count))))
        #expect(paths(resumed) == paths(fullEvents))
        #expect(paths(resumed) == ["/HELLO.TXT", "/FOLDER/NESTED.TXT"])
        let sweep = reader.reads.filter { $0.count == 1024 * 1024 }.map(\.offset)
        #expect(sweep.first == checkpoint.sweepOffset)
        #expect(sweep.allSatisfy { $0 >= checkpoint.sweepOffset })
    }

    @Test func resumingFromFinalExFATCheckpointSkipsTheSweep() async throws {
        let image = exfatImage()
        let (fullEvents, checkpoints) = await scanCollectingCheckpoints(image)
        let checkpoint = try #require(checkpoints.last)
        let reader = RecordingReader(data: image)
        let (stream, events) = AsyncStream<ScanEvent>.makeStream()
        await ScanSession(reader: reader).run(events: events, resumingFrom: checkpoint)
        var resumed: [ScanEvent] = []
        for await event in stream { resumed.append(event) }
        #expect(resumed.last == .completed)
        #expect(paths(resumed) == paths(fullEvents))
        #expect(!reader.reads.contains { $0.count == image.count })
    }

    @Test(arguments: [
        ScanCheckpoint(version: 99, deviceSizeBytes: 66560 * 512, totalBytes: 66560 * 512, extents: fatExtents, sweepVolumeIndex: 0, sweepOffset: 4 << 20, bytesScanned: 4 << 20),
        ScanCheckpoint(version: 1, deviceSizeBytes: 66560 * 512, totalBytes: 66560 * 512, extents: fatExtents, sweepVolumeIndex: 0, sweepOffset: 4 << 20, bytesScanned: 4 << 20),
        ScanCheckpoint(deviceSizeBytes: 1 << 40, totalBytes: 66560 * 512, extents: fatExtents, sweepVolumeIndex: 0, sweepOffset: 4 << 20, bytesScanned: 4 << 20),
        ScanCheckpoint(deviceSizeBytes: 66560 * 512, totalBytes: 1 << 20, extents: [.init(offset: 0, length: 1 << 20)], sweepVolumeIndex: 0, sweepOffset: 4 << 20, bytesScanned: 0),
        ScanCheckpoint(deviceSizeBytes: 66560 * 512, totalBytes: 66560 * 512, extents: fatExtents, sweepVolumeIndex: 3, sweepOffset: 0, bytesScanned: 0),
        ScanCheckpoint(deviceSizeBytes: 66560 * 512, totalBytes: 66560 * 512, extents: fatExtents, sweepVolumeIndex: 0, sweepOffset: 1 << 40, bytesScanned: 0),
        // Same device size, total and volume count, but the single volume sits elsewhere.
        ScanCheckpoint(deviceSizeBytes: 66560 * 512, totalBytes: 66560 * 512, extents: [.init(offset: 512, length: 66560 * 512)], sweepVolumeIndex: 0, sweepOffset: 4 << 20, bytesScanned: 4 << 20),
    ])
    func mismatchedCheckpointIsIgnoredAndScanStartsFromZero(_ checkpoint: ScanCheckpoint) async {
        let reader = RecordingReader(data: fatImage())
        let (stream, events) = AsyncStream<ScanEvent>.makeStream()
        await ScanSession(reader: reader).run(events: events, resumingFrom: checkpoint)
        var collected: [ScanEvent] = []
        for await event in stream { collected.append(event) }
        #expect(collected.first == .progress(bytesScanned: 0, totalBytes: reader.sizeBytes))
        #expect(collected.last == .completed)
        #expect(reader.reads.first { $0.count == 1024 * 1024 }?.offset == 0)
    }

    @Test func checkpointHoldsNoNamesOrPaths() throws {
        let json = try JSONEncoder().encode(ScanCheckpoint(deviceSizeBytes: 10, totalBytes: 10, extents: [.init(offset: 0, length: 10)], sweepVolumeIndex: 0, sweepOffset: 5, bytesScanned: 5))
        let keys = try #require(JSONSerialization.jsonObject(with: json) as? [String: Any]).keys.sorted()
        #expect(keys == ["bytesScanned", "deviceSizeBytes", "extents", "sweepOffset", "sweepVolumeIndex", "totalBytes", "version"])
    }

    @Test func checkpointFingerprintsTheDiscoveredLayout() async {
        let image = multiVolumeImage()
        let (_, checkpoints) = await scanCollectingCheckpoints(image)
        #expect(checkpoints.allSatisfy { $0.extents == [.init(offset: 512, length: 128 * 512),
                                                         .init(offset: 129 * 512, length: 66560 * 512)] })
    }

    @Test func checkpointFromADifferentLayoutStartsAFreshScan() async throws {
        // Same device size, total bytes and volume count; only the volume's position differs.
        let volume = exfatImage(), padding = Data(repeating: 0, count: 8 * 512)
        func layout(volumeFirst: Bool) -> Data {
            var image = Data(repeating: 0, count: 512) + (volumeFirst ? volume + padding : padding + volume)
            image.put(446+4, 7, 1); image.put(446+8, volumeFirst ? 1 : 9, 4); image.put(446+12, 128, 4)
            image.put(510, 0xaa55, 2)
            return image
        }
        let original = layout(volumeFirst: true), moved = layout(volumeFirst: false)
        #expect(original.count == moved.count)
        let (_, checkpoints) = await scanCollectingCheckpoints(original)
        let checkpoint = try #require(checkpoints.last)
        #expect(checkpoint.totalBytes == Int64(volume.count) && checkpoint.extents.count == 1)
        let reader = RecordingReader(data: moved)
        let (stream, events) = AsyncStream<ScanEvent>.makeStream()
        await ScanSession(reader: reader).run(events: events, resumingFrom: checkpoint)
        var collected: [ScanEvent] = []
        for await event in stream { collected.append(event) }
        #expect(collected.first == .progress(bytesScanned: 0, totalBytes: Int64(volume.count)))
        #expect(collected.last == .completed)
        // The whole volume is swept again rather than counted as already covered.
        #expect(reader.reads.contains { $0.offset == 9 * 512 && $0.count == volume.count })
    }

    @Test func multiVolumeResumeCountsEarlierVolumesAndContinuesMidVolume() async throws {
        let image = multiVolumeImage()
        let first = Int64(128 * 512), second = Int64(66560 * 512), total = first + second
        let (fullEvents, checkpoints) = await scanCollectingCheckpoints(image)
        let inSecond = checkpoints.filter { $0.sweepVolumeIndex == 1 }
        let checkpoint = try #require(inSecond.dropFirst(inSecond.count / 2).first)
        #expect(checkpoint.sweepOffset > 0 && checkpoint.sweepOffset < second)
        let reader = RecordingReader(data: image)
        let (stream, events) = AsyncStream<ScanEvent>.makeStream()
        await ScanSession(reader: reader).run(events: events, resumingFrom: checkpoint)
        var resumed: [ScanEvent] = []
        for await event in stream { resumed.append(event) }
        #expect(resumed.last == .completed)
        // Volume 0 is fully covered, volume 1 up to the checkpoint offset.
        #expect(resumed.first == .progress(bytesScanned: first + checkpoint.sweepOffset, totalBytes: total))
        #expect(resumed.contains(.progress(bytesScanned: total, totalBytes: total)))
        #expect(!resumed.contains { if case .progress(let bytes, let all) = $0 { bytes > all || all != total } else { false } })
        #expect(Set(paths(resumed)) == Set(paths(fullEvents)))
        #expect(paths(resumed).count == 3)
        // No sweep of volume 0, and volume 1's sweep restarts exactly at the checkpoint.
        #expect(!reader.reads.contains { $0.offset == 512 && $0.count == Int(first) })
        let sweep = reader.reads.filter { $0.count == 1024 * 1024 }.map(\.offset)
        #expect(sweep.first == 129 * 512 + checkpoint.sweepOffset)
        #expect(sweep.allSatisfy { $0 >= 129 * 512 + checkpoint.sweepOffset })
    }

    @Test func deviceRemovedWhilePausedFailsOnResumeAndKeepsDiscoveries() async throws {
        let gate = ScanPauseGate()
        let removed = Flag()
        let reader = RecordingReader(data: fatImage(), afterRead: { reads in
            if reads.filter({ $0.count == 1024 * 1024 }).count == 3 { gate.pause() }
        }, failure: { removed.isSet ? ScanError.deviceChanged : nil })
        let (stream, events) = AsyncStream<ScanEvent>.makeStream()
        let task = Task { await ScanSession(reader: reader).run(events: events, pauseGate: gate) }
        try await waitUntil { gate.waiterCount == 1 }
        removed.set()
        gate.resume()
        await task.value
        var collected: [ScanEvent] = []
        for await event in stream { collected.append(event) }
        #expect(collected.last == .error(.deviceChanged))
        #expect(!collected.contains(.completed))
        #expect(paths(collected) == ["/HELLO.TXT", "/FOLDER/NESTED.TXT"])
    }
}

private let fatExtents = [ScanCheckpoint.Extent(offset: 0, length: 66560 * 512)]

/// MBR with an exFAT volume (sectors 1-128) followed by a FAT32 volume (sectors 129-66688).
private func multiVolumeImage() -> Data {
    var image = Data(repeating: 0, count: 512) + exfatImage() + fatImage()
    image.put(446+4, 7, 1); image.put(446+8, 1, 4); image.put(446+12, 128, 4)
    image.put(446+16+4, 0x0c, 1); image.put(446+16+8, 129, 4); image.put(446+16+12, 66560, 4)
    image.put(510, 0xaa55, 2)
    return image
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

private func paths(_ events: [ScanEvent]) -> [String] {
    events.compactMap { if case .found(let file) = $0 { file.path } else { nil } }
}

private func scanCollectingCheckpoints(_ image: Data) async -> ([ScanEvent], [ScanCheckpoint]) {
    let (stream, events) = AsyncStream<ScanEvent>.makeStream()
    let (checkpointStream, checkpoints) = AsyncStream<ScanCheckpoint>.makeStream()
    await ScanSession(reader: ImageReader(data: image)).run(events: events, checkpoints: checkpoints)
    var collected: [ScanEvent] = [], points: [ScanCheckpoint] = []
    for await event in stream { collected.append(event) }
    for await point in checkpointStream { points.append(point) }
    return (collected, points)
}

private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(60)
    while !condition() {
        guard ContinuousClock.now < deadline else { throw ScanError.io("Timed out waiting for the scan.") }
        try await Task.sleep(for: .milliseconds(5))
    }
}

/// Records every read issued to the source, so tests can prove no read happens while paused.
private final class RecordingReader: BlockReader, @unchecked Sendable {
    struct Read { let offset: Int64; let count: Int }
    private let data: Data
    private let lock = NSLock()
    private var log: [Read] = []
    private let afterRead: @Sendable ([Read]) -> Void
    private let failure: @Sendable () -> (any Error)?
    init(data: Data, afterRead: @escaping @Sendable ([Read]) -> Void = { _ in },
         failure: @escaping @Sendable () -> (any Error)? = { nil }) {
        self.data = data; self.failure = failure; self.afterRead = afterRead
    }
    var sizeBytes: Int64 { Int64(data.count) }
    var reads: [Read] { lock.withLock { log } }
    func read(at offset: Int64, count: Int) async throws -> Data {
        try Task.checkCancellation()
        if let error = failure() { throw error }
        let snapshot = lock.withLock { log.append(Read(offset: offset, count: count)); return log }
        afterRead(snapshot)
        return data.subdata(in: Int(offset)..<Int(offset) + count)
    }
}
