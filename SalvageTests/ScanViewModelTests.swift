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
private actor CleanupProbe {
    var didClean = false
    func cleaned() { didClean = true }
}
private actor AttemptProbe {
    var count = 0
    func next() -> Int { count += 1; return count }
}
