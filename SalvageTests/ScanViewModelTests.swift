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
                                    recordOffset: 512, allocationStart: 2, contiguous: false, rawRecord: Data()))
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
                    recordOffset: volume + 512, allocationStart: 2, contiguous: false, rawRecord: Data()))
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
    @Test func noticesAreCollectedInOrderAndResetPerScan() async {
        let attempts = AttemptProbe()
        let model = ScanViewModel { run, events in
            if await attempts.next() == 1 {
                run.notices.yield(.partitionTableIgnored(reason: "Invalid GPT header."))
                run.notices.yield(.unreadableAreasSkipped(count: 3))
                run.notices.yield(.unreadableAreasSkipped(count: 3))   // a repeat is shown once
            }
            try await events.send(.completed)
        }
        model.start(device)
        while model.isActive { await Task.yield() }
        #expect(model.state == .completed)
        #expect(model.notices == [.partitionTableIgnored(reason: "Invalid GPT header."), .unreadableAreasSkipped(count: 3)])
        #expect(model.noticeLines == model.notices.map(\.text))
        #expect(model.noticeLines.last == "Part of this drive couldn't be read, so 3 areas were skipped.")
        model.start(device)
        while model.isActive { await Task.yield() }
        #expect(model.notices.isEmpty && model.noticeLines.isEmpty)
    }
    @Test func noticesArriveBesideAnErrorWithoutReplacingIt() async {
        let model = ScanViewModel { run, events in
            run.notices.yield(.signaturesSkipped(["broken.json"]))
            try await events.send(.error(.deviceChanged))
        }
        model.start(device)
        while model.isActive { await Task.yield() }
        #expect(model.state == .failed(.deviceChanged))
        #expect(model.notices == [.signaturesSkipped(["broken.json"])])
    }
    @Test func dashboardWordingCoversReconstructedFiles() {
        #expect(ResultsDashboardView.closingNote(reconstructed: 0, fromMetadata: 4)
                == "Files listed here have been indexed from intact metadata. No files have been copied or recovered.")
        #expect(ResultsDashboardView.closingNote(reconstructed: 2, fromMetadata: 4).contains("or reconstructed from their contents"))
        let carvedOnly = ResultsDashboardView.closingNote(reconstructed: 2, fromMetadata: 0)
        #expect(carvedOnly.contains("reconstructed") && !carvedOnly.contains("metadata"))
        let bucket = ResultsViewModel.Bucket(category: .pictures, count: 3, totalBytes: 2000, reconstructedCount: 2)
        #expect(ResultsDashboardView.tileAccessibilityLabel(bucket) == "Pictures, 3 files, 2 KB, 2 reconstructed")
        let plain = ResultsViewModel.Bucket(category: .pictures, count: 1, totalBytes: 0)
        #expect(!ResultsDashboardView.tileAccessibilityLabel(plain).contains("reconstructed"))
    }
}

@MainActor @Suite("Pause, resume, cancel and checkpoints")
struct ScanPauseResumeTests {
    let device = BlockDevice(bsdName: "disk42", displayName: "Fixture", sizeBytes: 1 << 20, isInternal: false,
                             isBootVolume: false, mediaIdentity: 7)
    var checkpoint: ScanCheckpoint { point(1 << 18) }
    func point(_ offset: Int64) -> ScanCheckpoint {
        ScanCheckpoint(deviceSizeBytes: 1 << 20, totalBytes: 1 << 20, extents: [.init(offset: 0, length: 1 << 20)],
                       sweepVolumeIndex: 0, sweepOffset: offset, bytesScanned: offset)
    }
    nonisolated static let savedAt = Date(timeIntervalSinceReferenceDate: 1_000_000)
    func makeStore(directory: URL? = nil, bootSession: String? = "boot-A",
                   now: @escaping @Sendable () -> Date = { ScanPauseResumeTests.savedAt }) -> ScanCheckpointStore {
        ScanCheckpointStore(directory: directory ?? FileManager.default.temporaryDirectory
            .appending(path: "SalvageTests-\(UUID().uuidString)", directoryHint: .isDirectory),
            bootSession: { bootSession }, now: now)
    }
    func file(_ entry: Int64, path: String = "/a.txt") -> RecoveredFile {
        RecoveredFile(name: "a.txt", path: path, sizeBytes: 1,
                      sourceMetadata: SourceMetadata(filesystem: .fat32, volumeOffset: 0, recordOffset: entry,
                                                     allocationStart: 2, contiguous: false, rawRecord: Data()))
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
        let gates = GateBox(), reads = Counter()
        let model = ScanViewModel(runner: { run, events in
            gates.set(run.pauseGate)
            try await events.send(.progress(bytesScanned: 100, totalBytes: 1 << 20))
            try await events.send(.found(found))
            run.checkpoints.yield(point)
            // Each loop is one "read"; it happens only after passing the gate.
            while true { try await run.pauseGate.wait(); reads.increment(); try await Task.sleep(for: .milliseconds(1)) }
        }, checkpointStore: store)
        model.start(device)
        try await waitUntil { model.state == .running && model.files.count == 1 }
        try await waitUntil { store.load(for: device) != nil }
        model.pause()
        // Prove the runner is parked at the gate, not merely between iterations, before cancelling.
        try await waitUntil { gates.gate?.waiterCount == 1 }
        let readsWhileBlocked = reads.value
        model.cancel()
        try await waitUntil { !model.isActive }
        #expect(reads.value == readsWhileBlocked)
        #expect(gates.gate?.waiterCount == 0)
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

    @Test(arguments: [ScanError.io("Timed out waiting for the device to unmount."), .permissionDenied, .deviceInUse])
    func failedResumeKeepsCheckpointAndStillOffersResume(_ error: ScanError) async throws {
        let store = makeStore()
        store.save(checkpoint, for: device)
        let model = ScanViewModel(runner: { _, _ in throw error }, checkpointStore: store)
        model.start(device)
        model.resumeInterruptedScan()
        try await waitUntil { !model.isActive }
        #expect(model.state == .failed(error))
        #expect(model.canRetryFromCheckpoint)
        #expect(store.load(for: device) == checkpoint)
        model.start(device)
        #expect(model.state == .resumable)
        #expect(model.pendingCheckpoint == checkpoint)
    }

    @Test func failedRunPersistsItsLatestCheckpoint() async throws {
        let store = makeStore()
        let first = point(1 << 18), latest = point(1 << 19)
        let model = ScanViewModel(runner: { run, events in
            try await events.send(.progress(bytesScanned: 0, totalBytes: 1 << 20))
            run.checkpoints.yield(first)
            while store.load(for: BlockDevice(bsdName: "disk42", displayName: "Fixture", sizeBytes: 1 << 20,
                                              isInternal: false, isBootVolume: false, mediaIdentity: 7)) == nil {
                try await Task.sleep(for: .milliseconds(1))
            }
            run.checkpoints.yield(latest)
            try await events.send(.error(.deviceChanged))
        }, now: { Self.savedAt }, checkpointStore: store)
        model.start(device)
        try await waitUntil { !model.isActive }
        #expect(model.state == .failed(.deviceChanged))
        #expect(store.load(for: device) == latest)
    }

    @Test func teardownKeepsTheLatestCheckpointWhileUserCancelRemovesIt() async throws {
        for teardown in [true, false] {
            let store = makeStore()
            let first = point(1 << 18), latest = point(1 << 19)
            let model = ScanViewModel(runner: { run, events in
                try await events.send(.progress(bytesScanned: 0, totalBytes: 1 << 20))
                run.checkpoints.yield(first)
                try await Task.sleep(for: .milliseconds(20))
                run.checkpoints.yield(latest)
                try await Task.sleep(for: .seconds(60))
            }, now: { Self.savedAt }, checkpointStore: store)
            model.start(device)
            // The clock never advances, so `latest` is throttled and only in memory.
            try await waitUntil { model.latestCheckpoint == latest }
            #expect(store.load(for: device) == first)
            if teardown {
                model.stopForTeardown()
                // Written synchronously, before the Task has even finished unwinding.
                #expect(store.load(for: device) == latest)
            } else {
                model.cancel()
            }
            try await waitUntil { !model.isActive }
            #expect(model.state == .cancelled)
            #expect(store.load(for: device) == (teardown ? latest : nil))
        }
    }

    @Test func pausePersistsImmediatelyIncludingTheCheckpointYieldedAtTheGate() async throws {
        let store = makeStore()
        let first = point(1 << 17), second = point(1 << 18), atGate = point(1 << 19)
        let model = ScanViewModel(runner: { run, events in
            try await events.send(.progress(bytesScanned: 0, totalBytes: 1 << 20))
            run.checkpoints.yield(first)
            try await Task.sleep(for: .milliseconds(20))
            run.checkpoints.yield(second)
            while !run.pauseGate.isPaused { try await Task.sleep(for: .milliseconds(1)) }
            // Like the core: the last unit's checkpoint arrives just before the scan parks.
            run.checkpoints.yield(atGate)
            try await run.pauseGate.wait()
            try await Task.sleep(for: .seconds(60))
        }, now: { Self.savedAt }, checkpointStore: store)
        model.start(device)
        try await waitUntil { model.latestCheckpoint == second }
        #expect(store.load(for: device) == first)
        model.pause()
        #expect(store.load(for: device) == second)
        try await waitUntil { model.latestCheckpoint == atGate }
        #expect(store.load(for: device) == atGate)
        model.stopForTeardown()
        try await waitUntil { !model.isActive }
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

    @Test func relaunchAfterTeardownOffersResumeAndProgressStartsAtTheCheckpoint() async throws {
        let store = makeStore()
        let point = checkpoint
        // First launch: the scan reaches the checkpoint, then the window closes.
        let first = ScanViewModel(runner: { run, events in
            try await events.send(.progress(bytesScanned: 0, totalBytes: 1 << 20))
            run.checkpoints.yield(point)
            try await Task.sleep(for: .seconds(60))
        }, checkpointStore: store)
        first.start(device)
        try await waitUntil { first.latestCheckpoint == point }
        first.stopForTeardown()
        try await waitUntil { !first.isActive }

        // Relaunch: a new model over the same store.
        let probe = ResumeProbe(), release = Counter()
        let relaunched = ScanViewModel(runner: { run, events in
            await probe.received(run.resumeFrom)
            try await events.send(.progress(bytesScanned: run.resumeFrom?.bytesScanned ?? 0, totalBytes: 1 << 20))
            while release.value == 0 { try await Task.sleep(for: .milliseconds(1)) }
            try await events.send(.progress(bytesScanned: 1 << 20, totalBytes: 1 << 20))
            try await events.send(.completed)
        }, checkpointStore: store)
        relaunched.start(device)
        #expect(relaunched.state == .resumable)
        #expect(!relaunched.isActive)
        #expect(relaunched.pendingCheckpoint == point)
        relaunched.resumeInterruptedScan()
        try await waitUntil { relaunched.state == .running }
        #expect(relaunched.bytesScanned == point.bytesScanned)
        #expect(relaunched.resumedFromCheckpoint)
        #expect(await probe.value == point)
        release.increment()
        try await waitUntil { !relaunched.isActive }
        #expect(relaunched.state == .completed)
        #expect(store.load(for: device) == nil)
    }

    @Test func deduplicationDropsExactRepeatsButKeepsHardLinks() async throws {
        let original = file(512, path: "/a.txt"), hardLink = file(512, path: "/b.txt"), other = file(1024)
        let model = ScanViewModel { _, events in
            try await events.send(.progress(bytesScanned: 0, totalBytes: 1 << 20))
            for found in [original, original, hardLink, other, hardLink] { try await events.send(.found(found)) }
            try await events.send(.completed)
        }
        model.start(device)
        try await waitUntil { !model.isActive }
        #expect(model.files == [original, hardLink, other])
    }

    @Test func rejectedCheckpointShowsNoResumedBanner() async throws {
        let store = makeStore()
        store.save(checkpoint, for: device)
        let model = ScanViewModel(runner: { _, events in
            // The core rejected the checkpoint, so its first progress starts from zero.
            try await events.send(.progress(bytesScanned: 0, totalBytes: 1 << 20))
            try await Task.sleep(for: .seconds(60))
        }, checkpointStore: store)
        model.start(device); model.resumeInterruptedScan()
        #expect(!model.resumedFromCheckpoint)
        try await waitUntil { model.state == .running }
        #expect(!model.resumedFromCheckpoint)
        model.cancel()
        try await waitUntil { !model.isActive }
    }

    @Test func deviceRemovedWhilePausedShowsErrorAndKeepsDiscoveries() async throws {
        let found = file(512), gates = GateBox()
        let model = ScanViewModel { run, events in
            gates.set(run.pauseGate)
            try await events.send(.progress(bytesScanned: 100, totalBytes: 1 << 20))
            try await events.send(.found(found))
            while !run.pauseGate.isPaused { try await Task.sleep(for: .milliseconds(1)) }
            try await run.pauseGate.wait()
            // The device disappeared while paused; the first read after resuming fails.
            throw ScanError.deviceChanged
        }
        model.start(device)
        try await waitUntil { model.state == .running && model.files.count == 1 }
        model.pause()
        try await waitUntil { gates.gate?.waiterCount == 1 }
        model.resume()
        try await waitUntil { !model.isActive }
        #expect(model.state == .failed(.deviceChanged))
        #expect(model.files == [found])
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

        let point = #"{"version":2,"deviceSizeBytes":1048576,"totalBytes":1048576,"extents":[{"offset":0,"length":1048576}],"sweepVolumeIndex":0,"sweepOffset":262144,"bytesScanned":262144}"#
        func record(format: Int = 2, identity: Int = 7, boot: String = "boot-A", checkpoint: String = point) -> String {
            #"{"formatVersion":\#(format),"mediaIdentity":\#(identity),"deviceSizeBytes":1048576,"bootSessionUUID":"\#(boot)","savedAt":1000000,"checkpoint":\#(checkpoint)}"#
        }
        try write(record(format: 1))
        #expect(store.load(for: device) == nil)
        #expect(!FileManager.default.fileExists(atPath: path.path))

        try write(record(identity: 8))
        #expect(store.load(for: device) == nil)

        try write(record(checkpoint: point.replacingOccurrences(of: #""version":2"#, with: #""version":1"#)))
        #expect(store.load(for: device) == nil)

        try write(record(checkpoint: point.replacingOccurrences(of: #""offset":0,"length":1048576"#, with: #""offset":0,"length":4096"#)))
        #expect(store.load(for: device) == nil)

        try write(record())
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

    @Test func checkpointFromAnotherBootSessionIsRejectedAndDeleted() throws {
        let before = makeStore(bootSession: "boot-A")
        before.save(checkpoint, for: device)
        let path = before.directory.appending(path: "checkpoint-7.json")
        // Same directory after a reboot: the IORegistry ID may now name a different device.
        let after = makeStore(directory: before.directory, bootSession: "boot-B")
        #expect(after.load(for: device) == nil)
        #expect(!FileManager.default.fileExists(atPath: path.path))

        let unreadable = makeStore(bootSession: nil)
        unreadable.save(checkpoint, for: device)
        #expect(!FileManager.default.fileExists(atPath: unreadable.directory.appending(path: "checkpoint-7.json").path))
    }

    @Test func checkpointsExpireAfterSevenDays() throws {
        let clock = SendableClock(Self.savedAt)
        let store = makeStore(now: { clock.date })
        let path = store.directory.appending(path: "checkpoint-7.json")
        store.save(checkpoint, for: device)
        clock.date = Self.savedAt.addingTimeInterval(ScanCheckpointStore.maxAge)
        #expect(store.load(for: device) == checkpoint)
        clock.date = Self.savedAt.addingTimeInterval(ScanCheckpointStore.maxAge + 1)
        #expect(store.load(for: device) == nil)
        #expect(!FileManager.default.fileExists(atPath: path.path))
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
/// Captures the run's pause gate so a test can see when the scan is parked at it.
private final class GateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: ScanPauseGate?
    var gate: ScanPauseGate? { lock.withLock { stored } }
    func set(_ gate: ScanPauseGate) { lock.withLock { stored = gate } }
}
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
private final class SendableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ date: Date) { current = date }
    var date: Date {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
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

@MainActor @Suite("Source session lifecycle")
struct SourceSessionLifecycleTests {
    let device = BlockDevice(bsdName: "disk42", displayName: "Fixture", sizeBytes: 1024, isInternal: false, isBootVolume: false)
    struct EmptyReader: BlockReader {
        var sizeBytes: Int64 { 1024 }
        func read(at offset: Int64, count: Int) async throws -> Data { Data(count: count) }
    }
    @Test func sourceIsKeptAfterScanAndClosedBeforeTheNextScanAndOnTeardown() async {
        let closes = CloseCounter()
        let model = ScanViewModel { run, events in
            try await events.send(.progress(bytesScanned: 1024, totalBytes: 1024))
            try await events.send(.completed)
            await run.keepSource(SourceSession(device: run.device, reader: EmptyReader(), close: { await closes.close() }))
        }
        model.start(device)
        while model.isActive { await Task.yield() }
        #expect(model.state == .completed && model.source != nil)
        #expect(await closes.count == 0)
        model.start(device)
        while model.isActive { await Task.yield() }
        #expect(await closes.count == 1 && model.source != nil)
        model.stopForTeardown()
        #expect(model.source == nil)
        while await closes.count < 2 { await Task.yield() }
        #expect(await closes.count == 2)
    }
}
private actor CloseCounter {
    var count = 0
    func close() { count += 1 }
}
