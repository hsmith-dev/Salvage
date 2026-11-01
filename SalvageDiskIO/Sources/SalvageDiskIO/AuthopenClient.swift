import Darwin
import Dispatch
import Foundation
import SalvageCore

// spec-tech-authopen / AD-13: the password fallback for physical drives. When the privileged
// helper isn't enabled (any unsigned or development build, or a signed one the user hasn't
// approved), Salvage asks macOS's own `/usr/libexec/authopen` to open the whole disk read-only.
// authopen shows the standard administrator-password dialog, opens the node itself, and passes
// the descriptor back over its stdout socket with SCM_RIGHTS. It is the only program this file
// launches in production, with a fixed argv and no shell. The descriptor it returns is still
// checked by `validateRawDescriptor` (O_RDONLY, expected character device) in `openRawDevice`.

enum AuthopenInvocation {
    /// Hard-coded: production never launches anything else from this path.
    static let executablePath = "/usr/libexec/authopen"

    /// How long the password dialog may stay unanswered before authopen is stopped.
    static let timeout: Duration = .seconds(180)

    /// The exact arguments, or nil for anything that isn't a whole-disk BSD name.
    ///
    /// - `-stdoutpipe`: send the open descriptor back over stdout (a socket) with SCM_RIGHTS,
    ///   instead of copying the file's bytes to stdout.
    /// - `-o 0`: the numeric open(2) flags, `O_RDONLY`. With no write flag authopen asks for the
    ///   `sys.openfile.readonly./dev/rdiskN` right, which (authopen(1)) only allows read-only
    ///   descriptors.
    ///
    /// Never `-w` (read/write, truncate), `-a`, `-c`, `-x`, `-m` or `-extauth`.
    static func arguments(forWholeDisk name: String) -> [String]? {
        guard isWholeDiskBSDName(name) else { return nil }
        return ["-stdoutpipe", "-o", String(O_RDONLY), "/dev/r\(name)"]
    }
}

/// What a descriptor-passing child left behind once it ended.
struct DescriptorPassingResult: Sendable, Equatable {
    enum Termination: Sendable, Equatable {
        case exited(Int32)
        /// Killed by a signal it didn't raise at our request.
        case signaled
        /// Still running at the deadline; it was stopped.
        case timedOut
    }
    let termination: Termination
    /// Every descriptor received, in order; the caller owns (and must close) all of them.
    let descriptors: [Int32]
    /// The kernel reported truncated ancillary data (more rights than the buffer held).
    let truncated: Bool
}

/// Runs a program whose stdout is one end of an AF_UNIX stream socketpair and collects the
/// descriptors it sends back. Injectable: tests use fakes and harmless executables, so nothing
/// that can show a password dialog ever runs under test.
protocol DescriptorPassingLauncher: Sendable {
    /// Throws `CancellationError` if the calling task is cancelled; the child is stopped first.
    func run(executable: String, arguments: [String], timeout: Duration) async throws -> DescriptorPassingResult
}

struct AuthopenClient: PrivilegedOpening {
    let launcher: any DescriptorPassingLauncher
    let executablePath: String
    let timeout: Duration

    static let live = AuthopenClient(launcher: ProcessDescriptorLauncher(),
                                     executablePath: AuthopenInvocation.executablePath,
                                     timeout: AuthopenInvocation.timeout)

    static let handoffFailedError = ScanError.io("macOS didn't hand the drive to Salvage. Try again.")

    func openWholeDiskReadOnly(_ request: PrivilegedOpenRequest) async throws -> Int32 {
        guard let arguments = AuthopenInvocation.arguments(forWholeDisk: request.bsdName) else {
            throw ScanError.unsafeTarget(RawBlockReader.notWholeDriveReason)
        }
        try Task.checkCancellation()
        let result = try await launcher.run(executable: executablePath, arguments: arguments, timeout: timeout)
        return try Self.descriptor(from: result)
    }

    /// Exactly one descriptor from a clean exit is accepted. Anything else closes every
    /// descriptor received: no descriptor from a failed run means the password wasn't given
    /// (cancelled, or the dialog left unanswered), the rest is an unexpected handoff.
    static func descriptor(from result: DescriptorPassingResult) throws -> Int32 {
        if result.termination == .exited(0), result.descriptors.count == 1, !result.truncated {
            return result.descriptors[0]
        }
        for descriptor in result.descriptors { Darwin.close(descriptor) }
        if result.descriptors.isEmpty, !result.truncated, result.termination != .exited(0) {
            throw ScanError.administratorPasswordNeeded
        }
        throw handoffFailedError
    }
}

/// `Process`-based launcher: absolute executable path, fixed argv, no shell; stdin and stderr
/// are /dev/null and Foundation passes the child only fds 0-2. On timeout or cancellation the
/// child gets SIGTERM, then SIGKILL a second later, and is reaped before this returns.
struct ProcessDescriptorLauncher: DescriptorPassingLauncher {
    /// Tests only: observes the child's pid once it is running.
    var onLaunch: (@Sendable (pid_t) -> Void)?

    static let launchFailedError = ScanError.io("macOS's administrator password prompt couldn't be started.")

    func run(executable: String, arguments: [String], timeout: Duration) async throws -> DescriptorPassingResult {
        try Task.checkCancellation()
        var pair: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw Self.launchFailedError }
        let parentEnd = pair[0], childEnd = pair[1]
        defer { Darwin.close(parentEnd) }
        _ = fcntl(parentEnd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(childEnd, F_SETFD, FD_CLOEXEC)  // dup2 into the child's fd 1 clears it there

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardOutput = FileHandle(fileDescriptor: childEnd, closeOnDealloc: false)
        let exit = ChildExit()
        process.terminationHandler = { _ in exit.signal() }
        do {
            try process.run()
        } catch {
            Darwin.close(childEnd)
            throw Self.launchFailedError
        }
        // The child holds its own copy; with ours closed, the socket reads EOF once it exits.
        Darwin.close(childEnd)
        onLaunch?(process.processIdentifier)

        do {
            try await exit.completion.wait(timeout: timeout, timeoutError: ChildExit.TimedOut()) {}
        } catch {
            await Self.stop(process, exit: exit)
            for descriptor in receivePassedDescriptors(from: parentEnd).descriptors { Darwin.close(descriptor) }
            if error is ChildExit.TimedOut { return DescriptorPassingResult(termination: .timedOut, descriptors: [], truncated: false) }
            throw CancellationError()
        }
        let received = receivePassedDescriptors(from: parentEnd)
        let termination: DescriptorPassingResult.Termination =
            process.terminationReason == .exit ? .exited(process.terminationStatus) : .signaled
        return DescriptorPassingResult(termination: termination, descriptors: received.descriptors, truncated: received.truncated)
    }

    /// SIGTERM, then SIGKILL if it hasn't exited within a second; waits (off the cooperative
    /// pool, and regardless of cancellation) until it is reaped.
    private static func stop(_ process: Process, exit: ChildExit) async {
        guard !exit.hasExited else { return }
        let pid = process.processIdentifier
        process.terminate()
        if await offCooperativePool({ exit.waitForExit(seconds: 1) }) { return }
        kill(pid, SIGKILL)
        _ = await offCooperativePool { exit.waitForExit(seconds: 5) }
    }
}

/// Signalled once from `Process.terminationHandler` (after the child is reaped).
private final class ChildExit: @unchecked Sendable {
    struct TimedOut: Error {}
    let completion = OneShotCompletion()
    private let exited = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var done = false

    func signal() {
        lock.withLock { done = true }
        exited.signal()
        completion.finish(.success(()))
    }
    var hasExited: Bool { lock.withLock { done } }
    /// True once the child has exited (immediately, if it already had).
    func waitForExit(seconds: Double) -> Bool {
        if hasExited { return true }
        guard exited.wait(timeout: .now() + seconds) == .success else { return false }
        exited.signal()  // leave it signalled for any later waiter
        return true
    }
}

/// Descriptors read from `socket` until EOF, would-block or a bounded number of messages. The
/// socket is made non-blocking, so this never waits. Received descriptors are marked
/// close-on-exec. Data bytes that carry the rights are discarded.
func receivePassedDescriptors(from socket: Int32, maxMessages: Int = 64) -> (descriptors: [Int32], truncated: Bool) {
    let flags = fcntl(socket, F_GETFL)
    if flags >= 0 { _ = fcntl(socket, F_SETFL, flags | O_NONBLOCK) }
    let headerSpace = cmsgAlign(MemoryLayout<cmsghdr>.size)
    let rightsCapacity = 8
    let controlSize = headerSpace + cmsgAlign(rightsCapacity * MemoryLayout<Int32>.size)
    var descriptors: [Int32] = [], truncated = false
    let control = UnsafeMutableRawPointer.allocate(byteCount: controlSize, alignment: MemoryLayout<cmsghdr>.alignment)
    defer { control.deallocate() }
    var data = [UInt8](repeating: 0, count: 256)
    var messages = 0
    while messages < maxMessages {
        messages += 1
        control.initializeMemory(as: UInt8.self, repeating: 0, count: controlSize)
        let count: Int, messageFlags: Int32, controlLength: Int
        (count, messageFlags, controlLength) = data.withUnsafeMutableBytes { bytes in
            var vector = iovec(iov_base: bytes.baseAddress, iov_len: bytes.count)
            return withUnsafeMutablePointer(to: &vector) { vectorPointer in
                var message = msghdr(msg_name: nil, msg_namelen: 0, msg_iov: vectorPointer, msg_iovlen: 1,
                                     msg_control: control, msg_controllen: socklen_t(controlSize), msg_flags: 0)
                let result = recvmsg(socket, &message, 0)
                return (result, message.msg_flags, Int(message.msg_controllen))
            }
        }
        if count < 0 {
            if errno == EINTR { continue }
            break  // EAGAIN (nothing more) or a socket error
        }
        if messageFlags & MSG_CTRUNC != 0 { truncated = true }
        var offset = 0
        while offset + headerSpace <= controlLength {
            let header = control.load(fromByteOffset: offset, as: cmsghdr.self)
            let length = Int(header.cmsg_len)
            guard length >= headerSpace, offset + length <= controlLength else { break }
            if header.cmsg_level == SOL_SOCKET, header.cmsg_type == SCM_RIGHTS {
                let rights = (length - headerSpace) / MemoryLayout<Int32>.size
                for index in 0..<rights {
                    let descriptor = control.loadUnaligned(fromByteOffset: offset + headerSpace + index * MemoryLayout<Int32>.size,
                                                           as: Int32.self)
                    _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
                    descriptors.append(descriptor)
                }
            }
            offset += cmsgAlign(length)
        }
        if count == 0 && controlLength == 0 { break }  // EOF
    }
    return (descriptors, truncated)
}

/// Darwin's `__DARWIN_ALIGN32`, which the CMSG_* macros (not imported into Swift) use.
private func cmsgAlign(_ length: Int) -> Int {
    let alignment = MemoryLayout<UInt32>.size
    return (length + alignment - 1) & ~(alignment - 1)
}
