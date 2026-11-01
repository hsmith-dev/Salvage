import Foundation
import SalvageCore

/// What one scan produced.
struct ScanOutcome {
    var files: [RecoveredFile] = []
    var notices: [ScanNotice] = []
    var lostPartitions: [LostPartitionCandidate] = []
    var lockedVolumes: [String] = []
    var completed = false
    var error: ScanError?
    var cancelled = false
    /// The caller asked the scan to stop early (`--limit`).
    var stoppedEarly = false
}

/// Progress on stderr: one redrawn line on a terminal, otherwise a line per 10%.
final class ProgressLine: @unchecked Sendable {
    private let output: CLIOutput
    private let label: String
    private let enabled: Bool
    private let lock = NSLock()
    private var lastDraw = ContinuousClock.now - .seconds(1)
    private var lastDecile = -1
    private var drawn = false

    init(output: CLIOutput, label: String, enabled: Bool) {
        self.output = output; self.label = label; self.enabled = enabled
    }

    func update(done: Int64, total: Int64, detail: String? = nil) {
        guard enabled, total > 0 else { return }
        let percent = Int(min(100, max(0, Double(done) / Double(total) * 100)))
        let text = "\(label): \(percent)% (\(Self.bytes(done)) of \(Self.bytes(total)))" + (detail.map { " \($0)" } ?? "")
        lock.withLock {
            if output.stderrIsTerminal {
                let now = ContinuousClock.now
                guard now - lastDraw >= .milliseconds(200) || done >= total else { return }
                lastDraw = now
                // Clear the line, then draw; a long name is cut so the line never wraps much.
                output.stderr("\r\u{1B}[2K" + String(text.prefix(110)))
                drawn = true
            } else {
                let decile = percent / 10
                guard decile > lastDecile else { return }
                lastDecile = decile
                output.message(text)
            }
        }
    }

    /// Ends a redrawn line so the next message starts on its own line.
    func finish() {
        lock.withLock {
            if drawn { output.stderr("\n"); drawn = false }
        }
    }

    static func bytes(_ count: Int64) -> String { ByteCountFormatter.string(fromByteCount: count, countStyle: .file) }
}

enum ScanRunner {
    /// Runs one `ScanSession` over `source`. `onFile` sees every found file in order and returns
    /// false to stop the scan early. Notices are delivered once the scan has ended.
    static func run(_ source: OpenedSource, progress: ProgressLine,
                    onFile: (RecoveredFile) -> Bool,
                    onLostPartition: (LostPartitionCandidate) -> Void = { _ in }) async -> ScanOutcome {
        var outcome = ScanOutcome()
        let (events, eventsContinuation) = AsyncStream<ScanEvent>.makeStream(bufferingPolicy: .bufferingOldest(1024))
        let (notices, noticesContinuation) = AsyncStream<ScanNotice>.makeStream(bufferingPolicy: .unbounded)
        let session = ScanSession(reader: source.reader)
        let device = source.device
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await session.run(events: eventsContinuation, notices: noticesContinuation, device: device)
            }
            var stopping = false
            for await event in events {
                if stopping { continue }
                switch event {
                case .progress(let done, let total):
                    progress.update(done: done, total: total)
                case .found(let file):
                    outcome.files.append(file)
                    if !onFile(file) {
                        outcome.stoppedEarly = true
                        stopping = true
                        group.cancelAll()
                    }
                case .lostPartitionFound(let partition):
                    outcome.lostPartitions.append(partition)
                    onLostPartition(partition)
                case .unlockRequired(let device):
                    outcome.lockedVolumes.append(device.encryptedVolumeName ?? device.encryptedVolumeUUID ?? "an encrypted volume")
                case .error(let error):
                    outcome.error = error
                case .completed:
                    outcome.completed = true
                }
            }
            await group.waitForAll()
        }
        for await notice in notices { outcome.notices.append(notice) }
        progress.finish()
        outcome.cancelled = Task.isCancelled && !outcome.completed
        return outcome
    }
}
