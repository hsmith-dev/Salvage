import Foundation
import Observation
import SalvageCore

/// Everything a runner needs to drive one scan: the device, the pause gate the scan awaits
/// between units of work, where to publish checkpoints, and the checkpoint to resume from.
struct ScanRun: Sendable {
    let device: BlockDevice
    let pauseGate: ScanPauseGate
    let checkpoints: AsyncStream<ScanCheckpoint>.Continuation
    /// Where the scan reports what it could not do (`ScanNotice`); the view model finishes it.
    let notices: AsyncStream<ScanNotice>.Continuation
    let resumeFrom: ScanCheckpoint?
    /// Passwords or recovery keys (by volume UUID) for FileVault volumes the user unlocked (Story 2.5).
    var credentials: [String: VolumeCredential] = [:]
    /// Hands the still-open source reader to the view model when the scan ends, for preview and recovery.
    let keepSource: @Sendable (SourceSession) async -> Void
    /// spec-tech-authopen: called just before macOS's administrator-password dialog is requested
    /// for a physical drive, so the scan screen can say why first.
    var willAskForAdministratorPassword: @Sendable () async -> Void = {}
}

@MainActor @Observable
final class ScanViewModel {
    /// `resumable`: an interrupted scan of the selected device left a checkpoint; Resume or Start over.
    enum State: Equatable { case idle, preparing, running, paused, resumable, completed, cancelled, failed(ScanError) }
    typealias Runner = @Sendable (ScanRun, AsyncStream<ScanEvent>.Continuation) async throws -> Void
    /// ext hard links share one inode (one record offset) under several paths, so the path is part of the key.
    private struct FileKey: Hashable { let volumeOffset: Int64; let recordOffset: Int64; let path: String }
    /// Why a run was stopped before it ended on its own.
    private enum StopReason { case user, teardown }
    /// Checkpoints arrive per sweep unit; disk writes are throttled to this interval, except while
    /// paused or tearing down, when every checkpoint is written at once.
    static let checkpointSaveInterval: TimeInterval = 1

    private(set) var state: State = .idle
    private(set) var device: BlockDevice?
    private(set) var files: [RecoveredFile] = []
    /// Filesystems found in unallocated space (FR-9); their files are in `files`, keyed by volume offset.
    private(set) var lostPartitions: [LostPartitionCandidate] = []
    /// Encrypted volumes the scan could not read; each needs a password or recovery key (FR-6).
    private(set) var unlockRequests: [BlockDevice] = []
    /// What this scan could not do, in arrival order (reset per scan); shown under "About this scan".
    private(set) var notices: [ScanNotice] = []
    private(set) var bytesScanned: Int64 = 0
    private(set) var totalBytes: Int64 = 0
    private(set) var startedAt: Date?
    private(set) var endedAt: Date?
    private(set) var isActive = false
    /// The checkpoint found for `device` while `state == .resumable`.
    private(set) var pendingCheckpoint: ScanCheckpoint?
    /// spec-tech-authopen: preparation is waiting on macOS's administrator-password dialog.
    private(set) var isAwaitingAdministratorPassword = false
    /// True once the core has actually resumed from the checkpoint: the run's first progress event
    /// reports bytes already covered. A checkpoint the core rejected starts from zero and leaves this false.
    private(set) var resumedFromCheckpoint = false
    /// A run that ended in failure kept its checkpoint, so retrying offers to resume.
    private(set) var canRetryFromCheckpoint = false
    /// The newest checkpoint received from the running scan (exposed for tests).
    private(set) var latestCheckpoint: ScanCheckpoint?
    /// The scanned device's open read-only session, kept after the scan for preview and recovery.
    private(set) var source: SourceSession?
    private var task: Task<Void, Never>?
    private var gate: ScanPauseGate?
    private var scanningStartedAt: Date?
    private var baselineBytes: Int64 = 0
    private var pausedAt: Date?
    private var pausedTotal: TimeInterval = 0
    private var seenFiles: Set<FileKey> = []
    private var lastCheckpointSave: Date?
    private var requestedResume = false
    private var stopReason: StopReason?
    private let runner: Runner
    private let now: () -> Date
    private let checkpointStore: ScanCheckpointStore?
    /// spec-tech-batch-7 §B: set while the results on screen came from a saved scan (`openArchive`).
    private(set) var reopened: ReopenedScan?

    init(runner: @escaping Runner, now: @escaping () -> Date = { Date() }, checkpointStore: ScanCheckpointStore? = nil) {
        self.runner = runner; self.now = now; self.checkpointStore = checkpointStore
    }

    /// Starts a scan, or offers to resume one when an interrupted scan of this device left a checkpoint.
    /// With `credentials` (FileVault volumes just unlocked, Story 2.5) it always scans afresh, since
    /// the unlocked volumes' files are new to this device's results.
    func start(_ device: BlockDevice, credentials: [String: VolumeCredential] = [:]) {
        guard !isActive, !device.isBootVolume else { return }
        if !credentials.isEmpty { begin(device, from: nil, credentials: credentials); return }
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

    /// User cancel. Terminal; also ends a paused scan. Discoveries so far stay visible and the
    /// checkpoint is deleted.
    func cancel() {
        guard let task else { return }
        stopReason = .user
        task.cancel()
    }

    /// Window teardown. Cancels the scan's Task like `cancel()`, but writes the latest checkpoint
    /// first and keeps it, so the interrupted scan can be resumed later.
    func stopForTeardown() {
        releaseSource()
        guard let task else { return }
        if stopReason == nil { stopReason = .teardown }
        persistLatestCheckpoint()
        task.cancel()
    }

    private func reset(for device: BlockDevice) {
        self.device = device; files = []; seenFiles = []; bytesScanned = 0; totalBytes = 0
        lostPartitions = []; unlockRequests = []
        notices = []
        startedAt = nil; scanningStartedAt = nil; endedAt = nil; baselineBytes = 0
        pausedAt = nil; pausedTotal = 0; latestCheckpoint = nil; lastCheckpointSave = nil
        pendingCheckpoint = nil; resumedFromCheckpoint = false; canRetryFromCheckpoint = false
        requestedResume = false; stopReason = nil
        reopened = nil; isAwaitingAdministratorPassword = false
    }

    /// How long the explanation is on screen before the system dialog is requested.
    static let passwordExplanationLead: Duration = .milliseconds(600)

    private func explainAdministratorPassword() async {
        guard isActive, state == .preparing else { return }
        isAwaitingAdministratorPassword = true
    }

    /// Closes the kept source session (e.g. leaving results, or before scanning again).
    func releaseSource() {
        guard let source else { return }
        self.source = nil
        Task { await source.close() }
    }

    private func adopt(_ session: SourceSession) async {
        if stopReason == .teardown { await session.close(); return }
        let previous = source
        source = session
        await previous?.close()
    }

    private func begin(_ device: BlockDevice, from checkpoint: ScanCheckpoint?, credentials: [String: VolumeCredential] = [:]) {
        // The previous device session must be released before a new scan reserves a device.
        let previous = source
        source = nil
        reset(for: device)
        requestedResume = checkpoint != nil
        startedAt = now(); state = .preparing; isActive = true
        let gate = ScanPauseGate()
        self.gate = gate
        task = Task { [runner] in
            await previous?.close()
            let (stream, continuation) = AsyncStream<ScanEvent>.makeStream(bufferingPolicy: .bufferingOldest(64))
            let (checkpointStream, checkpoints) = AsyncStream<ScanCheckpoint>.makeStream(bufferingPolicy: .bufferingNewest(1))
            let (noticeStream, notices) = AsyncStream<ScanNotice>.makeStream()
            let run = ScanRun(device: device, pauseGate: gate, checkpoints: checkpoints,
                              notices: notices,
                              resumeFrom: checkpoint, credentials: credentials,
                              keepSource: { session in await self.adopt(session) },
                              willAskForAdministratorPassword: {
                                  await self.explainAdministratorPassword()
                                  // Let the explanation render before the dialog takes focus.
                                  try? await Task.sleep(for: Self.passwordExplanationLead)
                              })
            var completed = false
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    do { try await runner(run, continuation) }
                    catch is CancellationError { }
                    catch { if !Task.isCancelled { try? await continuation.send(.error((error as? ScanError) ?? .io(error.localizedDescription))) } }
                    checkpoints.finish()
                    notices.finish()
                    continuation.finish()
                }
                group.addTask {
                    for await point in checkpointStream { await self.record(point) }
                }
                group.addTask {
                    for await notice in noticeStream { await self.receive(notice) }
                }
                for await event in stream {
                    switch event {
                    case .progress(let bytes, let total):
                        if scanningStartedAt == nil {
                            scanningStartedAt = now()
                            // The core's first progress counts only bytes a checkpoint covered, so a
                            // nonzero value means it accepted the resume point. Only bytes read now
                            // measure the rate.
                            resumedFromCheckpoint = requestedResume && bytes > 0
                            baselineBytes = resumedFromCheckpoint ? bytes : 0
                        }
                        if state == .preparing { state = .running }
                        isAwaitingAdministratorPassword = false
                        bytesScanned = bytes; totalBytes = total
                    case .found(let file):
                        let key = FileKey(volumeOffset: file.sourceMetadata.volumeOffset,
                                          recordOffset: file.sourceMetadata.recordOffset, path: file.path)
                        if seenFiles.insert(key).inserted { files.append(file) }
                    case .error(let error): state = .failed(error)
                    case .completed: completed = true
                    case .lostPartitionFound(let candidate): lostPartitions.append(candidate)
                    case .unlockRequired(let device): unlockRequests.append(device)
                    }
                }
                if Task.isCancelled { group.cancelAll() }
                await group.waitForAll()
            }
            let ended = now()
            endedAt = ended; isActive = false; isAwaitingAdministratorPassword = false
            if let pausedAt { pausedTotal += max(0, ended.timeIntervalSince(pausedAt)); self.pausedAt = nil }
            // A real error already delivered (e.g. device removed) wins over a racing Cancel.
            if case .failed = state { }
            else if Task.isCancelled { state = .cancelled }
            else if completed { state = .completed }
            else { state = .failed(.io("The scan ended before completion.")) }
            // Completion and a user cancel discard the checkpoint. A failure keeps it so the user can
            // retry (e.g. a resume whose preparation failed), and a teardown keeps it for later.
            let keep: Bool
            switch state {
            case .completed: keep = false
            case .cancelled: keep = stopReason == .teardown
            default: keep = true
            }
            if keep {
                if let latestCheckpoint { save(latestCheckpoint, for: device) }
                if case .failed = state { canRetryFromCheckpoint = latestCheckpoint != nil || checkpoint != nil }
            } else {
                checkpointStore?.remove(for: device)
            }
            self.gate = nil
            task = nil
        }
    }

    private func receive(_ notice: ScanNotice) {
        guard isActive, !notices.contains(notice) else { return }
        notices.append(notice)
    }
    /// The "About this scan" lines, one per notice, in plain language.
    var noticeLines: [String] { notices.map(\.text) }

    private func record(_ checkpoint: ScanCheckpoint) {
        guard isActive else { return }
        latestCheckpoint = checkpoint
        // The core yields its last checkpoint just before parking at the gate, so a checkpoint that
        // arrives while paused or tearing down is the resume point and is written immediately.
        let urgent = state == .paused || stopReason == .teardown
        if !urgent, let lastCheckpointSave, now().timeIntervalSince(lastCheckpointSave) < Self.checkpointSaveInterval { return }
        persistLatestCheckpoint()
    }

    private func persistLatestCheckpoint() {
        guard isActive, let device, let latestCheckpoint else { return }
        save(latestCheckpoint, for: device)
    }

    private func save(_ checkpoint: ScanCheckpoint, for device: BlockDevice) {
        guard let checkpointStore else { return }
        checkpointStore.save(checkpoint, for: device)
        lastCheckpointSave = now()
    }

    // MARK: Saved scans (spec-tech-batch-7 §B)

    /// A saved scan on screen. `token` tells one opening from the next, so a reconnect that
    /// finishes after another scan or saved scan replaced it is dropped.
    struct ReopenedScan: Equatable {
        enum Status: Equatable {
            /// No source yet: "Reconnect <device> to preview or recover these files."
            case waiting
            /// Opening a matching device and reading its fingerprint.
            case checking
            /// A device with the saved identity and size has a different layout; it is never read from.
            case changed
            /// The scan was saved before the device was mapped, so no device can be verified.
            case unverifiable
            case connected
        }
        let token = UUID()
        let fingerprint: [ScanCheckpoint.Extent]?
        let hasEncryptedFiles: Bool
        var status: Status
    }

    /// Why `reconnect` did or didn't adopt a device.
    /// `needsAdministratorPassword`: macOS's password dialog was cancelled (spec-tech-authopen).
    enum ReconnectResult: Equatable { case connected, notThisDevice, changed, unverifiable, unavailable, needsAdministratorPassword, superseded }

    var canSaveArchive: Bool {
        !isActive && device != nil && ResultsViewModel.showsResults(state: state, isActive: isActive, fileCount: files.count)
    }

    /// The finished scan's results as a saved scan. It never takes anything from `source` (whose
    /// decryptors hold volume keys) or from a run's credentials.
    func makeArchive(savedAt: Date = Date()) -> ScanArchive? {
        guard canSaveArchive, let device else { return nil }
        let outcome: ScanArchive.Outcome
        switch state {
        case .completed: outcome = .completed
        case .cancelled: outcome = .cancelled
        case .failed(let error): outcome = .failed(error)
        default: return nil
        }
        return ScanArchive(device: device, files: files, lostPartitions: lostPartitions, notices: notices,
                           checkpoint: latestCheckpoint, outcome: outcome, bytesScanned: bytesScanned,
                           totalBytes: totalBytes, startedAt: startedAt, endedAt: endedAt, savedAt: savedAt)
    }

    /// Shows a saved scan's results with no source session. Preview and recovery stay off until
    /// `reconnect` adopts the same device.
    func openArchive(_ archive: ScanArchive) {
        guard !isActive else { return }
        releaseSource()
        reset(for: archive.device)
        files = archive.files
        lostPartitions = archive.lostPartitions
        notices = archive.notices
        latestCheckpoint = archive.checkpoint
        bytesScanned = archive.bytesScanned; totalBytes = archive.totalBytes
        startedAt = archive.startedAt
        endedAt = archive.endedAt ?? archive.savedAt
        switch archive.outcome {
        case .completed: state = .completed
        case .cancelled: state = .cancelled
        case .failed(let error): state = .failed(error)
        }
        reopened = ReopenedScan(fingerprint: archive.fingerprint, hasEncryptedFiles: archive.hasEncryptedFiles,
                                status: archive.fingerprint == nil ? .unverifiable : .waiting)
    }

    /// Adopts `candidate` as the reopened scan's source, only when it is the same device: its media
    /// identity and size are checked before it is opened, and its freshly read extent fingerprint
    /// must equal the saved one before the session is kept. A device that fails either check is
    /// never read from for preview or recovery.
    func reconnect(_ candidate: BlockDevice, open: @Sendable (BlockDevice) async throws -> SourceSession) async -> ReconnectResult {
        guard let reopened, source == nil, !isActive, let device else { return .superseded }
        guard ScanArchive.admits(candidate, for: device) else { return .notThisDevice }
        guard let expected = reopened.fingerprint else { return .unverifiable }
        guard reopened.status != .checking else { return .superseded }
        let token = reopened.token
        self.reopened?.status = .checking
        let session: SourceSession
        do { session = try await open(candidate) } catch {
            if self.reopened?.token == token { self.reopened?.status = .waiting }
            return error as? ScanError == .administratorPasswordNeeded ? .needsAdministratorPassword : .unavailable
        }
        guard self.reopened?.token == token else { await session.close(); return .superseded }
        let fresh = try? await ExtentFingerprint.of(session.reader)
        guard self.reopened?.token == token, source == nil, !isActive else { await session.close(); return .superseded }
        guard let fresh, fresh == expected else {
            await session.close()
            if self.reopened?.token == token { self.reopened?.status = fresh == nil ? .waiting : .changed }
            return fresh == nil ? .unavailable : .changed
        }
        source = session
        self.reopened?.status = .connected
        return .connected
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
