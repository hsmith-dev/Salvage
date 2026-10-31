import Foundation
import Observation
import SalvageCore

/// Everything a runner needs to drive one scan: the device, the pause gate the scan awaits
/// between units of work, where to publish checkpoints, and the checkpoint to resume from.
struct ScanRun: Sendable {
    let device: BlockDevice
    let pauseGate: ScanPauseGate
    let checkpoints: AsyncStream<ScanCheckpoint>.Continuation
    let resumeFrom: ScanCheckpoint?
}

@MainActor @Observable
final class ScanViewModel {
    /// `resumable`: an interrupted scan of the selected device left a checkpoint; Resume or Start over.
    enum State: Equatable { case idle, preparing, running, paused, resumable, completed, cancelled, failed(ScanError) }
    typealias Runner = @Sendable (ScanRun, AsyncStream<ScanEvent>.Continuation) async throws -> Void
    private struct FileKey: Hashable { let volumeOffset: Int64; let recordOffset: Int64 }
    /// Checkpoints arrive per sweep unit; disk writes are throttled to this interval (and on pause).
    static let checkpointSaveInterval: TimeInterval = 1

    private(set) var state: State = .idle
    private(set) var device: BlockDevice?
    private(set) var files: [RecoveredFile] = []
    private(set) var bytesScanned: Int64 = 0
    private(set) var totalBytes: Int64 = 0
    private(set) var startedAt: Date?
    private(set) var endedAt: Date?
    private(set) var isActive = false
    /// The checkpoint found for `device` while `state == .resumable`.
    private(set) var pendingCheckpoint: ScanCheckpoint?
    private(set) var resumedFromCheckpoint = false
    private var task: Task<Void, Never>?
    private var gate: ScanPauseGate?
    private var scanningStartedAt: Date?
    private var baselineBytes: Int64 = 0
    private var pausedAt: Date?
    private var pausedTotal: TimeInterval = 0
    private var seenFiles: Set<FileKey> = []
    private var latestCheckpoint: ScanCheckpoint?
    private var lastCheckpointSave: Date?
    private let runner: Runner
    private let now: () -> Date
    private let checkpointStore: ScanCheckpointStore?

    init(runner: @escaping Runner, now: @escaping () -> Date = { Date() }, checkpointStore: ScanCheckpointStore? = nil) {
        self.runner = runner; self.now = now; self.checkpointStore = checkpointStore
    }

    /// Starts a scan, or offers to resume one when an interrupted scan of this device left a checkpoint.
    func start(_ device: BlockDevice) {
        guard !isActive, !device.isBootVolume else { return }
        if let checkpoint = checkpointStore?.load(for: device) {
            reset(for: device)
            pendingCheckpoint = checkpoint; state = .resumable
            return
        }
        begin(device, from: nil)
    }

    func resumeInterruptedScan() {
        guard state == .resumable, !isActive, let device, let checkpoint = pendingCheckpoint else { return }
        begin(device, from: checkpoint)
    }

    func startOver() {
        guard state == .resumable, !isActive, let device else { return }
        checkpointStore?.remove(for: device)
        begin(device, from: nil)
    }

    var canPause: Bool { isActive && state == .running }

    /// Suspends reads without cancelling the scan's Task; `resume()` continues the same Task.
    func pause() {
        guard canPause, let gate else { return }
        gate.pause()
        pausedAt = now(); state = .paused
        persistLatestCheckpoint()
    }

    func resume() {
        guard isActive, state == .paused, let gate else { return }
        if let pausedAt { pausedTotal += max(0, now().timeIntervalSince(pausedAt)) }
        pausedAt = nil; state = .running
        gate.resume()
    }

    /// Terminal. Also ends a paused scan; discoveries so far stay visible.
    func cancel() { task?.cancel() }

    private func reset(for device: BlockDevice) {
        self.device = device; files = []; seenFiles = []; bytesScanned = 0; totalBytes = 0
        startedAt = nil; scanningStartedAt = nil; endedAt = nil; baselineBytes = 0
        pausedAt = nil; pausedTotal = 0; latestCheckpoint = nil; lastCheckpointSave = nil
        pendingCheckpoint = nil; resumedFromCheckpoint = false
    }

    private func begin(_ device: BlockDevice, from checkpoint: ScanCheckpoint?) {
        reset(for: device)
        resumedFromCheckpoint = checkpoint != nil
        startedAt = now(); state = .preparing; isActive = true
        let gate = ScanPauseGate()
        self.gate = gate
        task = Task { [runner] in
            let (stream, continuation) = AsyncStream<ScanEvent>.makeStream(bufferingPolicy: .bufferingOldest(64))
            let (checkpointStream, checkpoints) = AsyncStream<ScanCheckpoint>.makeStream(bufferingPolicy: .bufferingNewest(1))
            let run = ScanRun(device: device, pauseGate: gate, checkpoints: checkpoints, resumeFrom: checkpoint)
            var completed = false
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    do { try await runner(run, continuation) }
                    catch is CancellationError { }
                    catch { if !Task.isCancelled { try? await continuation.send(.error((error as? ScanError) ?? .io(error.localizedDescription))) } }
                    checkpoints.finish()
                    continuation.finish()
                }
                group.addTask {
                    for await point in checkpointStream { await self.record(point) }
                }
                for await event in stream {
                    switch event {
                    case .progress(let bytes, let total):
                        if scanningStartedAt == nil {
                            scanningStartedAt = now()
                            // A resumed scan starts at the checkpoint; only bytes read now measure the rate.
                            baselineBytes = resumedFromCheckpoint ? bytes : 0
                        }
                        if state == .preparing { state = .running }
                        bytesScanned = bytes; totalBytes = total
                    case .found(let file):
                        let key = FileKey(volumeOffset: file.sourceMetadata.volumeOffset,
                                          recordOffset: file.sourceMetadata.directoryEntryOffset)
                        if seenFiles.insert(key).inserted { files.append(file) }
                    case .error(let error): state = .failed(error)
                    case .completed: completed = true
                    case .lostPartitionFound, .unlockRequired: break
                    }
                }
                if Task.isCancelled { group.cancelAll() }
                await group.waitForAll()
            }
            let ended = now()
            endedAt = ended; isActive = false
            if let pausedAt { pausedTotal += max(0, ended.timeIntervalSince(pausedAt)); self.pausedAt = nil }
            // A real error already delivered (e.g. device removed) wins over a racing Cancel.
            if case .failed = state { }
            else if Task.isCancelled { state = .cancelled }
            else if completed { state = .completed }
            else { state = .failed(.io("The scan ended before completion.")) }
            // Only an interrupted run (quit or crash mid-scan) leaves a checkpoint behind.
            checkpointStore?.remove(for: device)
            self.gate = nil
            task = nil
        }
    }

    private func record(_ checkpoint: ScanCheckpoint) {
        guard isActive else { return }
        latestCheckpoint = checkpoint
        let current = now()
        if let lastCheckpointSave, current.timeIntervalSince(lastCheckpointSave) < Self.checkpointSaveInterval { return }
        persistLatestCheckpoint()
    }

    private func persistLatestCheckpoint() {
        guard isActive, let device, let latestCheckpoint, let checkpointStore else { return }
        checkpointStore.save(latestCheckpoint, for: device)
        lastCheckpointSave = now()
    }

    var sourceVolumeLabels: [Int64: String] { Self.volumeLabels(for: files) }
    static func volumeLabels(for files: [RecoveredFile]) -> [Int64: String] {
        let volumes = Set(files.map { $0.sourceMetadata.volumeOffset }).sorted()
        guard volumes.count > 1 else { return [:] }
        return Dictionary(uniqueKeysWithValues: volumes.enumerated().map { ($0.element, "Volume \($0.offset + 1)") })
    }

    private func pausedTime(at now: Date) -> TimeInterval {
        pausedTotal + (pausedAt.map { max(0, now.timeIntervalSince($0)) } ?? 0)
    }
    /// Active scan time; paused time is excluded.
    func elapsed(at now: Date) -> TimeInterval {
        guard let startedAt else { return 0 }
        let end = endedAt ?? now
        return max(0, end.timeIntervalSince(startedAt) - pausedTime(at: end))
    }
    func estimatedRemaining(at now: Date) -> TimeInterval? {
        guard let scanningStartedAt else { return nil }
        let elapsed = max(0, now.timeIntervalSince(scanningStartedAt) - pausedTime(at: now))
        let measured = bytesScanned - baselineBytes
        guard state == .running, elapsed >= 3, measured > 0, totalBytes > bytesScanned else { return nil }
        return elapsed * Double(totalBytes - bytesScanned) / Double(measured)
    }
}
