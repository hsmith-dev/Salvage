import Foundation

/// The resumable pause gate of AD-11. The scan awaits `wait()` between units of work; pausing never
/// cancels the scan's `Task`, so the same `Task` continues on `resume()`. A gated wait responds to
/// `Task` cancellation immediately, so Cancel still terminates a paused scan.
///
/// State is held under a lock rather than in an `actor` so that `pause()`/`resume()` are
/// synchronous from the main actor (no ordering races between hops) and the cancellation handler
/// can release a waiter without spawning an unstructured `Task`.
public final class ScanPauseGate: @unchecked Sendable {
    private let lock = NSLock()
    private var paused = false
    private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]

    public init() {}

    public var isPaused: Bool { lock.withLock { paused } }

    /// Number of scan loops currently parked at the gate. Public so tests in other modules can
    /// prove a scan is actually blocked before acting, rather than relying on timing.
    public var waiterCount: Int { lock.withLock { waiters.count } }

    public func pause() { lock.withLock { paused = true } }

    public func resume() {
        let released = lock.withLock {
            paused = false
            defer { waiters = [:] }
            return Array(waiters.values)
        }
        for waiter in released { waiter.resume() }
    }

    /// Returns at once when not paused; otherwise suspends until `resume()` or cancellation.
    public func wait() async throws {
        while true {
            try Task.checkCancellation()
            guard isPaused else { return }
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    enum Outcome { case cancelled, proceed, parked }
                    // `Task.isCancelled` is set before the cancellation handler runs, so checking it
                    // under the same lock the handler takes closes the register/cancel race.
                    let outcome: Outcome = lock.withLock {
                        if Task.isCancelled { return .cancelled }
                        if !paused { return .proceed }
                        waiters[id] = continuation
                        return .parked
                    }
                    switch outcome {
                    case .cancelled: continuation.resume(throwing: CancellationError())
                    case .proceed: continuation.resume()
                    case .parked: break
                    }
                }
            } onCancel: {
                let waiter = lock.withLock { waiters.removeValue(forKey: id) }
                waiter?.resume(throwing: CancellationError())
            }
        }
    }
}
