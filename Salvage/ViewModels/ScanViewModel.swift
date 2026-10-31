import Foundation
import Observation
import SalvageCore

@MainActor @Observable
final class ScanViewModel {
    enum State: Equatable { case idle, preparing, running, completed, cancelled, failed(ScanError) }
    typealias Runner = @Sendable (BlockDevice, AsyncStream<ScanEvent>.Continuation) async throws -> Void
    private(set) var state: State = .idle
    private(set) var device: BlockDevice?
    private(set) var files: [RecoveredFile] = []
    private(set) var bytesScanned: Int64 = 0
    private(set) var totalBytes: Int64 = 0
    private(set) var startedAt: Date?
    private(set) var endedAt: Date?
    private(set) var isActive = false
    private var task: Task<Void, Never>?
    private var scanningStartedAt: Date?
    private let runner: Runner
    private let now: () -> Date

    init(runner: @escaping Runner, now: @escaping () -> Date = { Date() }) {
        self.runner = runner; self.now = now
    }

    func start(_ device: BlockDevice) {
        guard !isActive, !device.isBootVolume else { return }
        self.device = device; files = []; bytesScanned = 0; totalBytes = 0
        startedAt = now(); scanningStartedAt = nil; endedAt = nil; state = .preparing; isActive = true
        task = Task { [runner] in
            let (stream, continuation) = AsyncStream<ScanEvent>.makeStream(bufferingPolicy: .bufferingOldest(64))
            var completed = false
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    do { try await runner(device, continuation) }
                    catch is CancellationError { }
                    catch { if !Task.isCancelled { try? await continuation.send(.error((error as? ScanError) ?? .io(error.localizedDescription))) } }
                    continuation.finish()
                }
                for await event in stream {
                    switch event {
                    case .progress(let bytes, let total):
                        if scanningStartedAt == nil { scanningStartedAt = now() }
                        state = .running; bytesScanned = bytes; totalBytes = total
                    case .found(let file): files.append(file)
                    case .error(let error): state = .failed(error)
                    case .completed: completed = true
                    case .lostPartitionFound, .unlockRequired: break
                    }
                }
                if Task.isCancelled { group.cancelAll() }
                await group.waitForAll()
            }
            endedAt = now(); isActive = false
            // A real error already delivered (e.g. device removed) wins over a racing Cancel.
            if case .failed = state { }
            else if Task.isCancelled { state = .cancelled }
            else if completed { state = .completed }
            else { state = .failed(.io("The scan ended before completion.")) }
            task = nil
        }
    }
    var sourceVolumeLabels: [Int64: String] { Self.volumeLabels(for: files) }
    static func volumeLabels(for files: [RecoveredFile]) -> [Int64: String] {
        let volumes = Set(files.map { $0.sourceMetadata.volumeOffset }).sorted()
        guard volumes.count > 1 else { return [:] }
        return Dictionary(uniqueKeysWithValues: volumes.enumerated().map { ($0.element, "Volume \($0.offset + 1)") })
    }
    func cancel() { task?.cancel() }
    func elapsed(at now: Date) -> TimeInterval {
        guard let startedAt else { return 0 }
        return max(0, (endedAt ?? now).timeIntervalSince(startedAt))
    }
    func estimatedRemaining(at now: Date) -> TimeInterval? {
        guard let scanningStartedAt else { return nil }
        let elapsed = max(0, now.timeIntervalSince(scanningStartedAt))
        guard state == .running, elapsed >= 3, bytesScanned > 0, totalBytes > bytesScanned else { return nil }
        return elapsed * Double(totalBytes - bytesScanned) / Double(bytesScanned)
    }
}
