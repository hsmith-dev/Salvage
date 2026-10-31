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
        ScanCheckpoint(version: 99, deviceSizeBytes: 66560 * 512, totalBytes: 66560 * 512, sweepVolumeIndex: 0, sweepOffset: 4 << 20, bytesScanned: 4 << 20),
        ScanCheckpoint(deviceSizeBytes: 1 << 40, totalBytes: 66560 * 512, sweepVolumeIndex: 0, sweepOffset: 4 << 20, bytesScanned: 4 << 20),
        ScanCheckpoint(deviceSizeBytes: 66560 * 512, totalBytes: 1 << 20, sweepVolumeIndex: 0, sweepOffset: 4 << 20, bytesScanned: 0),
        ScanCheckpoint(deviceSizeBytes: 66560 * 512, totalBytes: 66560 * 512, sweepVolumeIndex: 3, sweepOffset: 0, bytesScanned: 0),
        ScanCheckpoint(deviceSizeBytes: 66560 * 512, totalBytes: 66560 * 512, sweepVolumeIndex: 0, sweepOffset: 1 << 40, bytesScanned: 0),
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
        let json = try JSONEncoder().encode(ScanCheckpoint(deviceSizeBytes: 10, totalBytes: 10, sweepVolumeIndex: 0, sweepOffset: 5, bytesScanned: 5))
        let keys = try #require(JSONSerialization.jsonObject(with: json) as? [String: Any]).keys.sorted()
        #expect(keys == ["bytesScanned", "deviceSizeBytes", "sweepOffset", "sweepVolumeIndex", "totalBytes", "version"])
    }
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
    let deadline = ContinuousClock.now + .seconds(5)
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
    init(data: Data, afterRead: @escaping @Sendable ([Read]) -> Void = { _ in }) {
        self.data = data; self.afterRead = afterRead
    }
    var sizeBytes: Int64 { Int64(data.count) }
    var reads: [Read] { lock.withLock { log } }
    func read(at offset: Int64, count: Int) async throws -> Data {
        try Task.checkCancellation()
        let snapshot = lock.withLock { log.append(Read(offset: offset, count: count)); return log }
        afterRead(snapshot)
        return data.subdata(in: Int(offset)..<Int(offset) + count)
    }
}
