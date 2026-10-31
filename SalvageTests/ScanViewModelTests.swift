import Foundation
import SalvageCore
import Testing
@testable import Salvage

@MainActor @Suite("Scan progress states")
struct ScanViewModelTests {
    let device = BlockDevice(bsdName: "disk42", displayName: "Fixture", sizeBytes: 1024, isInternal: false, isBootVolume: false)
    @Test func streamsDiscoveriesAndRetainsThemOnError() async {
        let file = RecoveredFile(name: "a.txt", path: "/a.txt", sizeBytes: 1,
                                 sourceMetadata: SourceMetadata(filesystem: .fat32, volumeOffset: 0,
                                    directoryEntryOffset: 512, firstCluster: 2, contiguous: false, directoryEntries: Data()))
        let model = ScanViewModel { _, events in
            try await events.send(.progress(bytesScanned: 100, totalBytes: 1024))
            try await events.send(.found(file))
            try await events.send(.error(.deviceChanged))
        }
        model.start(device)
        while model.isActive { await Task.yield() }
        #expect(model.state == .failed(.deviceChanged))
        #expect(model.files == [file])
        #expect(model.bytesScanned == 100)
        #expect(model.endedAt != nil)
    }
    @Test func completionAndUnknownETA() async {
        let model = ScanViewModel { _, events in
            try await events.send(.progress(bytesScanned: 1024, totalBytes: 1024))
            try await events.send(.completed)
        }
        #expect(model.estimatedRemaining(at: .now) == nil)
        model.start(device)
        #expect(model.state == .preparing)
        while model.isActive { await Task.yield() }
        #expect(model.state == .completed)
        #expect(model.elapsed(at: .now) >= 0)
        #expect(model.estimatedRemaining(at: .now) == nil)
    }
    @Test func cancelPreparationEndsAfterRunnerCleanup() async {
        let probe = CleanupProbe()
        let model = ScanViewModel { _, _ in
            do { try await Task.sleep(for: .seconds(60)) }
            catch { await probe.cleaned(); throw error }
        }
        model.start(device); model.cancel()
        while model.isActive { await Task.yield() }
        #expect(model.state == .cancelled)
        #expect(await probe.didClean)
    }
    @Test func deliveredErrorSurvivesRacingCancel() async {
        let model = ScanViewModel { _, events in
            try await events.send(.progress(bytesScanned: 100, totalBytes: 1024))
            try await events.send(.error(.deviceChanged))
            try await Task.sleep(for: .seconds(60))
        }
        model.start(device)
        while model.state != .failed(.deviceChanged) { await Task.yield() }
        model.cancel()
        while model.isActive { await Task.yield() }
        #expect(model.state == .failed(.deviceChanged))
    }
    @Test func ETAUsesMeasuredRateAfterEnoughScanTime() async {
        let start = Date(timeIntervalSince1970: 1000)
        let model = ScanViewModel(runner: { _, events in
            try await events.send(.progress(bytesScanned: 512, totalBytes: 1024))
            try await Task.sleep(for: .seconds(60))
        }, now: { start })
        model.start(device)
        while model.state != .running { await Task.yield() }
        #expect(model.estimatedRemaining(at: start.addingTimeInterval(2)) == nil)
        #expect(model.estimatedRemaining(at: start.addingTimeInterval(10)) == 10)
        #expect(model.elapsed(at: start.addingTimeInterval(10)) == 10)
        model.cancel()
        while model.isActive { await Task.yield() }
    }
    @Test func duplicatePathsReceiveStableVolumeLabels() {
        func file(_ volume: Int64) -> RecoveredFile {
            RecoveredFile(name: "same.txt", path: "/same.txt", sizeBytes: 1,
                sourceMetadata: SourceMetadata(filesystem: .fat32, volumeOffset: volume,
                    directoryEntryOffset: volume + 512, firstCluster: 2, contiguous: false, directoryEntries: Data()))
        }
        #expect(ScanViewModel.volumeLabels(for: [file(512)]).isEmpty)
        #expect(ScanViewModel.volumeLabels(for: [file(1024), file(512)]) == [512: "Volume 1", 1024: "Volume 2"])
        #expect(ScanViewModel.volumeLabels(for: [file(512), file(1024), file(512)]) == [512: "Volume 1", 1024: "Volume 2"])
    }
    @Test func permissionRefusalCanRetry() async {
        let attempts = AttemptProbe()
        let model = ScanViewModel { _, events in
            if await attempts.next() == 1 { throw ScanError.permissionDenied }
            try await events.send(.completed)
        }
        model.start(device)
        while model.isActive { await Task.yield() }
        #expect(model.state == .failed(.permissionDenied))
        model.start(device)
        while model.isActive { await Task.yield() }
        #expect(model.state == .completed)
    }
}

@MainActor @Suite("Pause, resume, cancel and checkpoints")
struct ScanPauseResumeTests {
    let device = BlockDevice(bsdName: "disk42", displayName: "Fixture", sizeBytes: 1 << 20, isInternal: false,
                             isBootVolume: false, mediaIdentity: 7)
    var checkpoint: ScanCheckpoint {
        ScanCheckpoint(deviceSizeBytes: 1 << 20, totalBytes: 1 << 20, sweepVolumeIndex: 0, sweepOffset: 1 << 18, bytesScanned: 1 << 18)
    }
    func makeStore() -> ScanCheckpointStore {
        ScanCheckpointStore(directory: FileManager.default.temporaryDirectory
            .appending(path: "SalvageTests-\(UUID().uuidString)", directoryHint: .isDirectory))
    }
    func file(_ entry: Int64, path: String = "/a.txt") -> RecoveredFile {
        RecoveredFile(name: "a.txt", path: path, sizeBytes: 1,
                      sourceMetadata: SourceMetadata(filesystem: .fat32, volumeOffset: 0, directoryEntryOffset: entry,
                                                     firstCluster: 2, contiguous: false, directoryEntries: Data()))
    }

    @Test func pauseFreezesTheScanAndResumeContinuesTheSameRun() async throws {
        let model = ScanViewModel { run, events in
            try await events.send(.progress(bytesScanned: 100, totalBytes: 1024))
            while !run.pauseGate.isPaused { try await Task.sleep(for: .milliseconds(1)) }
            try await run.pauseGate.wait()
            try await events.send(.progress(bytesScanned: 1024, totalBytes: 1024))
            try await events.send(.completed)
        }
        model.start(device)
        #expect(!model.canPause)
        try await waitUntil { model.state == .running }
        #expect(model.canPause)
        model.pause()
        #expect(model.state == .paused)
        #expect(!model.canPause)
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.state == .paused)
        #expect(model.bytesScanned == 100)
        #expect(model.isActive)
        model.resume()
        #expect(model.state == .running)
        try await waitUntil { !model.isActive }
        #expect(model.state == .completed)
        #expect(model.bytesScanned == 1024)
    }

    @Test func cancelWhilePausedKeepsDiscoveriesAndDeletesCheckpoint() async throws {
        let store = makeStore()
        let found = file(512), point = checkpoint
        let model = ScanViewModel(runner: { run, events in
            try await events.send(.progress(bytesScanned: 100, totalBytes: 1 << 20))
            try await events.send(.found(found))
            run.checkpoints.yield(point)
            while true { try await run.pauseGate.wait(); try await Task.sleep(for: .milliseconds(1)) }
        }, checkpointStore: store)
        model.start(device)
        try await waitUntil { model.state == .running && model.files.count == 1 }
        try await waitUntil { store.load(for: device) != nil }
        model.pause()
        model.cancel()
        try await waitUntil { !model.isActive }
        #expect(model.state == .cancelled)
        #expect(model.files == [found])
        #expect(store.load(for: device) == nil)
    }

    @Test func completionDeletesCheckpoint() async throws {
        let store = makeStore()
        let point = checkpoint, device = device
        let model = ScanViewModel(runner: { run, events in
            try await events.send(.progress(bytesScanned: 0, totalBytes: 1 << 20))
            run.checkpoints.yield(point)
            while store.load(for: device) == nil { try await Task.sleep(for: .milliseconds(1)) }
            try await events.send(.progress(bytesScanned: 1 << 20, totalBytes: 1 << 20))
            try await events.send(.completed)
        }, checkpointStore: store)
        model.start(device)
        try await waitUntil { !model.isActive }
        #expect(model.state == .completed)
        #expect(store.load(for: device) == nil)
    }

    @Test func ETAAndElapsedExcludePausedTime() async throws {
        let clock = TestClock()
        let model = ScanViewModel(runner: { run, events in
            try await events.send(.progress(bytesScanned: 256, totalBytes: 1024))
            try await Task.sleep(for: .seconds(60))
        }, now: { clock.date })
        model.start(device)
        try await waitUntil { model.state == .running }
        let start = clock.date
        clock.date = start.addingTimeInterval(2)
        model.pause()
        #expect(model.estimatedRemaining(at: start.addingTimeInterval(50)) == nil)
        #expect(model.elapsed(at: start.addingTimeInterval(50)) == 2)
        clock.date = start.addingTimeInterval(102)
        model.resume()
        #expect(model.elapsed(at: start.addingTimeInterval(104)) == 4)
        #expect(model.estimatedRemaining(at: start.addingTimeInterval(104)) == 12)
        model.cancel()
        try await waitUntil { !model.isActive }
    }

    @Test func relaunchOffersResumeFromCheckpointWithoutDuplicates() async throws {
        let store = makeStore()
        store.save(checkpoint, for: device)
        let probe = ResumeProbe()
        let duplicate = file(512), other = file(1024)
        let model = ScanViewModel(runner: { run, events in
            await probe.received(run.resumeFrom)
            let start = run.resumeFrom?.bytesScanned ?? 0
            try await events.send(.progress(bytesScanned: start, totalBytes: 1 << 20))
            try await events.send(.found(duplicate))
            try await events.send(.found(duplicate))
            try await events.send(.found(other))
            try await events.send(.progress(bytesScanned: 1 << 20, totalBytes: 1 << 20))
            try await events.send(.completed)
        }, checkpointStore: store)
        model.start(device)
        #expect(model.state == .resumable)
        #expect(!model.isActive)
        #expect(model.pendingCheckpoint == checkpoint)
        model.resumeInterruptedScan()
        #expect(model.resumedFromCheckpoint)
        try await waitUntil { !model.isActive }
        #expect(model.state == .completed)
        #expect(await probe.value == checkpoint)
        #expect(model.files == [duplicate, other])
        #expect(store.load(for: device) == nil)
    }

    @Test func resumedScanMeasuresRateFromCheckpoint() async throws {
        let store = makeStore()
        store.save(checkpoint, for: device)
        let clock = TestClock()
        let model = ScanViewModel(runner: { run, events in
            try await events.send(.progress(bytesScanned: 1 << 18, totalBytes: 1 << 20))
            try await events.send(.progress(bytesScanned: 1 << 19, totalBytes: 1 << 20))
            try await Task.sleep(for: .seconds(60))
        }, now: { clock.date }, checkpointStore: store)
        model.start(device); model.resumeInterruptedScan()
        try await waitUntil { model.bytesScanned == 1 << 19 }
        // 256 KiB read in 4 s since resuming; 512 KiB remain.
        #expect(model.estimatedRemaining(at: clock.date.addingTimeInterval(4)) == 8)
        model.cancel()
        try await waitUntil { !model.isActive }
    }

    @Test func startOverDiscardsCheckpointAndScansFromZero() async throws {
        let store = makeStore()
        store.save(checkpoint, for: device)
        let probe = ResumeProbe()
        let model = ScanViewModel(runner: { run, events in
            await probe.received(run.resumeFrom)
            try await events.send(.completed)
        }, checkpointStore: store)
        model.start(device)
        #expect(model.state == .resumable)
        model.startOver()
        #expect(store.load(for: device) == nil)
        try await waitUntil { !model.isActive }
        #expect(model.state == .completed)
        #expect(await probe.called)
        #expect(await probe.value == nil)
    }

    @Test func staleCheckpointsAreDiscarded() throws {
        let store = makeStore()
        let path = store.directory.appending(path: "checkpoint-7.json")
        func write(_ text: String) throws {
            try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: path)
        }
        try write("{not json")
        #expect(store.load(for: device) == nil)
        #expect(!FileManager.default.fileExists(atPath: path.path))

        let point = #"{"version":1,"deviceSizeBytes":1048576,"totalBytes":1048576,"sweepVolumeIndex":0,"sweepOffset":262144,"bytesScanned":262144}"#
        try write(#"{"formatVersion":99,"mediaIdentity":7,"deviceSizeBytes":1048576,"checkpoint":\#(point)}"#)
        #expect(store.load(for: device) == nil)
        #expect(!FileManager.default.fileExists(atPath: path.path))

        try write(#"{"formatVersion":1,"mediaIdentity":8,"deviceSizeBytes":1048576,"checkpoint":\#(point)}"#)
        #expect(store.load(for: device) == nil)

        try write(#"{"formatVersion":1,"mediaIdentity":7,"deviceSizeBytes":1048576,"checkpoint":\#(point.replacingOccurrences(of: #""version":1"#, with: #""version":2"#))}"#)
        #expect(store.load(for: device) == nil)

        try write(#"{"formatVersion":1,"mediaIdentity":7,"deviceSizeBytes":1048576,"checkpoint":\#(point)}"#)
        #expect(store.load(for: device) == checkpoint)

        store.save(checkpoint, for: device)
        let resized = BlockDevice(bsdName: "disk42", displayName: "Fixture", sizeBytes: 2 << 20, isInternal: false,
                                  isBootVolume: false, mediaIdentity: 7)
        #expect(store.load(for: resized) == nil)
        #expect(store.load(for: device) == nil)

        let anonymous = BlockDevice(bsdName: "disk43", displayName: "No identity", sizeBytes: 1 << 20, isInternal: false, isBootVolume: false)
        store.save(checkpoint, for: anonymous)
        #expect(store.load(for: anonymous) == nil)
    }

    @Test func checkpointFileHoldsNoNamesOrPaths() throws {
        let store = makeStore()
        store.save(checkpoint, for: device)
        let text = try String(contentsOf: store.directory.appending(path: "checkpoint-7.json"), encoding: .utf8)
        #expect(!text.contains("/") && !text.contains("Fixture") && !text.contains("disk42"))
    }

    @Test func staleCheckpointStartsAFreshScan() async throws {
        let store = makeStore()
        store.save(checkpoint, for: BlockDevice(bsdName: "disk42", displayName: "Fixture", sizeBytes: 3 << 20,
                                                isInternal: false, isBootVolume: false, mediaIdentity: 7))
        let probe = ResumeProbe()
        let model = ScanViewModel(runner: { run, events in
            await probe.received(run.resumeFrom)
            try await events.send(.completed)
        }, checkpointStore: store)
        model.start(device)
        #expect(model.state == .preparing)
        try await waitUntil { !model.isActive }
        #expect(await probe.called)
        #expect(await probe.value == nil)
    }
}

private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while await !condition() {
        guard ContinuousClock.now < deadline else { throw ScanError.io("Timed out") }
        try await Task.sleep(for: .milliseconds(1))
    }
}
@MainActor private final class TestClock {
    var date = Date(timeIntervalSince1970: 1000)
}
private actor ResumeProbe {
    var called = false
    var value: ScanCheckpoint?
    func received(_ checkpoint: ScanCheckpoint?) { called = true; value = checkpoint }
}
private actor CleanupProbe {
    var didClean = false
    func cleaned() { didClean = true }
}
private actor AttemptProbe {
    var count = 0
    func next() -> Int { count += 1; return count }
}
