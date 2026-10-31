import DiskArbitration
import Foundation

enum UnmountOutcome {
    case success
    case failure(String)
}

/// Holds the result handed back from the C callback. A plain class passed through `Unmanaged`,
/// since `DADiskUnmountCallback` is a non-capturing `@convention(c)` function pointer and
/// cannot close over Swift state directly.
final class UnmountContext {
    var result: UnmountOutcome?
}

func unmountCallback(disk: DADisk, dissenter: DADissenter?, contextPtr: UnsafeMutableRawPointer?) {
    guard let contextPtr else { return }
    // Balances the `passRetained` in `unmountWholeDisk` below: this is the only place that
    // releases that extra reference, so the context object is guaranteed to stay alive from the
    // moment DADiskUnmount is called until this callback actually runs, no matter how long
    // DiskArbitration takes to deliver it (including after our own polling loop has given up).
    let context = Unmanaged<UnmountContext>.fromOpaque(contextPtr).takeRetainedValue()
    if let dissenter {
        let status = DADissenterGetStatus(dissenter)
        let reasonCF = DADissenterGetStatusString(dissenter)
        let reason = reasonCF.map { $0 as String } ?? "unmount dissented, status \(status)"
        context.result = .failure(reason)
    } else {
        context.result = .success
    }
}

/// Unmounts `disk` whole-disk, per AD-4 ("DADiskUnmount, whole-disk") before any raw read.
/// DiskArbitration callbacks only fire while the session is scheduled on a run loop that is
/// actually running, so this pumps the current run loop until the callback fires or a timeout
/// elapses.
///
/// Lifetime/cancellation note: if the callback is still pending when the ~20s timeout below is
/// reached, two things prevent a use-after-free or a stray late callback from corrupting state:
///   1. `Unmanaged.passRetained` keeps `context` alive independent of this function's local
///      scope, so a callback that fires after this function returns still has a valid object to
///      write into (and `takeRetainedValue()` above releases that extra reference exactly once,
///      when -- if ever -- the callback actually runs).
///   2. `DASessionUnscheduleFromRunLoop` is called unconditionally before returning, which stops
///      any further callback delivery for this session on this run loop. We are never inside a
///      callback at the point we call it (we only reach it after `CFRunLoopRunInMode` has
///      returned control to us), so there is no race with an in-flight callback.
/// If the callback never fires at all, the single retained `UnmountContext` is never released --
/// an acceptable, bounded leak for a short-lived CLI process that exits shortly after anyway.
func unmountWholeDisk(_ disk: DADisk, session: DASession) -> UnmountOutcome {
    let context = UnmountContext()
    let contextPtr = Unmanaged.passRetained(context).toOpaque()

    DASessionScheduleWithRunLoop(session, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

    DADiskUnmount(disk, DADiskUnmountOptions(kDADiskUnmountOptionWhole), unmountCallback, contextPtr)

    let deadline = Date().addingTimeInterval(20)
    while context.result == nil && Date() < deadline {
        CFRunLoopRunInMode(.defaultMode, 0.1, true)
    }

    DASessionUnscheduleFromRunLoop(session, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

    return context.result ?? .failure("timed out waiting for DADiskUnmount to complete")
}
