import Darwin
import Foundation
import SalvageCore
import Testing
@testable import SalvageDiskIO

// spec-tech-authopen. Nothing here launches /usr/libexec/authopen or anything else that can show
// a password dialog: descriptor passing is exercised over in-process socketpairs (the sender on
// its own thread), and the Process launcher only runs /usr/bin/false, /usr/bin/true, /bin/sh and
// /bin/sleep, which ignore or reject authopen's arguments.

// MARK: - Helpers

private func controlSpace(_ count: Int) -> (header: Int, total: Int) {
    let align = { (n: Int) in (n + 3) & ~3 }
    let header = align(MemoryLayout<cmsghdr>.size)
    return (header, header + align(count * MemoryLayout<Int32>.size))
}

/// Sends `descriptors` as one SCM_RIGHTS message carrying one data byte.
@discardableResult
private func sendDescriptors(_ descriptors: [Int32], over socket: Int32) -> Bool {
    let (header, total) = controlSpace(descriptors.count)
    let control = UnsafeMutableRawPointer.allocate(byteCount: total, alignment: MemoryLayout<cmsghdr>.alignment)
    defer { control.deallocate() }
    control.initializeMemory(as: UInt8.self, repeating: 0, count: total)
    control.storeBytes(of: cmsghdr(cmsg_len: socklen_t(header + descriptors.count * 4), cmsg_level: SOL_SOCKET, cmsg_type: SCM_RIGHTS),
                       as: cmsghdr.self)
    for (index, descriptor) in descriptors.enumerated() {
        control.storeBytes(of: descriptor, toByteOffset: header + index * 4, as: Int32.self)
    }
    var byte: UInt8 = 0x2A
    return withUnsafeMutablePointer(to: &byte) { bytePointer in
        var vector = iovec(iov_base: UnsafeMutableRawPointer(bytePointer), iov_len: 1)
        return withUnsafeMutablePointer(to: &vector) { vectorPointer in
            var message = msghdr(msg_name: nil, msg_namelen: 0, msg_iov: vectorPointer, msg_iovlen: 1,
                                 msg_control: control, msg_controllen: socklen_t(total), msg_flags: 0)
            return sendmsg(socket, &message, 0) == 1
        }
    }
}

private func socketPair() throws -> (Int32, Int32) {
    var pair: [Int32] = [-1, -1]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw ScanError.io("socketpair") }
    return (pair[0], pair[1])
}

private func devNullIdentity() -> RawDeviceIdentity {
    var node = stat()
    _ = stat("/dev/null", &node)
    return RawDeviceIdentity(registryID: 77, sizeBytes: 65536, blockSize: 512, deviceNumber: node.st_rdev)
}

/// A pipe whose read end is handed out; writing to the kept write end fails with EPIPE exactly
/// when every copy of the read end was closed (robust against descriptor-number reuse).
private final class ClosureProbe: @unchecked Sendable {
    let readEnd: Int32, writeEnd: Int32
    init() throws {
        var ends: [Int32] = [-1, -1]
        guard pipe(&ends) == 0 else { throw ScanError.io("pipe") }
        readEnd = ends[0]; writeEnd = ends[1]
        _ = fcntl(writeEnd, F_SETNOSIGPIPE, 1)
    }
    /// Polls briefly: while another test's socket is closed with rights still in flight, the
    /// kernel's unix-socket garbage collection can hold an in-flight file for a moment after
    /// every descriptor to it was closed. A real leak never turns into EPIPE.
    var allReadEndsClosed: Bool {
        var byte: UInt8 = 0
        for _ in 0..<200 {
            if write(writeEnd, &byte, 1) == -1 && errno == EPIPE { return true }
            usleep(10_000)
        }
        return false
    }
    deinit { close(writeEnd) }
}

private func isOpen(_ fd: Int32) -> Bool { fcntl(fd, F_GETFD) != -1 }

private func processExists(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 || errno != ESRCH }

/// Plays authopen without running it: a socketpair whose "child" end sends `descriptors` from
/// another thread, then the real `receivePassedDescriptors`. The descriptors are the fake's to
/// send; it closes its own copies after sending, as authopen does by exiting.
private actor SendingLauncher: DescriptorPassingLauncher {
    let makeDescriptors: @Sendable () -> [Int32]
    let status: Int32
    private(set) var runs: [(executable: String, arguments: [String])] = []
    init(status: Int32 = 0, _ makeDescriptors: @escaping @Sendable () -> [Int32]) {
        self.status = status; self.makeDescriptors = makeDescriptors
    }
    func run(executable: String, arguments: [String], timeout: Duration) async throws -> DescriptorPassingResult {
        runs.append((executable, arguments))
        let (parent, child) = try socketPair()
        defer { close(parent) }
        let descriptors = makeDescriptors()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            Thread {
                if !descriptors.isEmpty { sendDescriptors(descriptors, over: child) }
                for descriptor in descriptors { close(descriptor) }
                close(child)
                done.resume()
            }.start()
        }
        let received = receivePassedDescriptors(from: parent)
        return DescriptorPassingResult(termination: .exited(status), descriptors: received.descriptors, truncated: received.truncated)
    }
}

/// Returns a fixed result (the descriptors in it are handed to the client).
private actor ResultLauncher: DescriptorPassingLauncher {
    let result: DescriptorPassingResult
    private(set) var runs = 0
    init(_ result: DescriptorPassingResult) { self.result = result }
    func run(executable: String, arguments: [String], timeout: Duration) async throws -> DescriptorPassingResult {
        runs += 1; return result
    }
}

private actor CallLog {
    private(set) var entries: [String] = []
    func add(_ entry: String) { entries.append(entry) }
}

private struct LoggingOpener: PrivilegedOpening {
    let name: String, log: CallLog, inner: any PrivilegedOpening
    func openWholeDiskReadOnly(_ request: PrivilegedOpenRequest) async throws -> Int32 {
        await log.add(name)
        return try await inner.openWholeDiskReadOnly(request)
    }
}

private struct FailingOpener: PrivilegedOpening {
    let error: ScanError
    func openWholeDiskReadOnly(_ request: PrivilegedOpenRequest) async throws -> Int32 { throw error }
}

private func client(_ launcher: any DescriptorPassingLauncher) -> AuthopenClient {
    AuthopenClient(launcher: launcher, executablePath: "/nonexistent/fake-authopen", timeout: .seconds(5))
}

private let request = PrivilegedOpenRequest(bsdName: "disk42", registryID: 77, deviceNumber: devNullIdentity().deviceNumber)

// MARK: - Invocation

@Suite("authopen invocation")
struct AuthopenInvocationTests {
    @Test func productionPathAndArgumentsAreFixed() {
        #expect(AuthopenInvocation.executablePath == "/usr/libexec/authopen")
        #expect(AuthopenClient.live.executablePath == "/usr/libexec/authopen")
        #expect(AuthopenInvocation.arguments(forWholeDisk: "disk4") == ["-stdoutpipe", "-o", "0", "/dev/rdisk4"])
        #expect(O_RDONLY == 0)
    }

    @Test func neverAsksForWriteOrCreate() throws {
        let arguments = try #require(AuthopenInvocation.arguments(forWholeDisk: "disk12"))
        for flag in ["-w", "-a", "-c", "-x", "-m", "-extauth"] { #expect(!arguments.contains(flag)) }
        let flags = try #require(Int32(arguments[arguments.firstIndex(of: "-o")! + 1]))
        #expect(flags & O_ACCMODE == O_RDONLY)
        #expect(flags & (O_CREAT | O_TRUNC | O_APPEND) == 0)
    }

    @Test(arguments: ["", "disk", "disk01", "disk4s1", "rdisk4", "/dev/rdisk4", "disk4 ", "disk4;rm", "../disk4"])
    func nonWholeDiskNamesHaveNoInvocation(_ name: String) {
        #expect(AuthopenInvocation.arguments(forWholeDisk: name) == nil)
    }

    @Test func nonWholeDiskNameNeverLaunches() async {
        let launcher = ResultLauncher(DescriptorPassingResult(termination: .exited(0), descriptors: [], truncated: false))
        await #expect(throws: ScanError.unsafeTarget(RawBlockReader.notWholeDriveReason)) {
            _ = try await client(launcher).openWholeDiskReadOnly(PrivilegedOpenRequest(bsdName: "disk4s1", registryID: 1, deviceNumber: 1))
        }
        #expect(await launcher.runs == 0)
    }
}

// MARK: - Descriptor passing

@Suite("Descriptor passing")
struct DescriptorPassingTests {
    @Test func receivesAReadOnlyDescriptorSentFromAnotherThread() async throws {
        let path = NSTemporaryDirectory() + "salvage-authopen-\(UUID().uuidString)"
        #expect(FileManager.default.createFile(atPath: path, contents: Data("source".utf8)))
        defer { unlink(path) }
        let launcher = SendingLauncher { [open(path, O_RDONLY)] }
        let result = try await launcher.run(executable: "fake", arguments: [], timeout: .seconds(5))
        #expect(result.termination == .exited(0) && !result.truncated)
        let fd = try #require(result.descriptors.first)
        defer { close(fd) }
        #expect(result.descriptors.count == 1)
        #expect(fcntl(fd, F_GETFL) & O_ACCMODE == O_RDONLY)
        #expect(fcntl(fd, F_GETFD) & FD_CLOEXEC != 0)
        var received = stat(), original = stat()
        #expect(fstat(fd, &received) == 0 && stat(path, &original) == 0)
        #expect(received.st_ino == original.st_ino && received.st_dev == original.st_dev)
        var buffer = [UInt8](repeating: 0, count: 6)
        #expect(pread(fd, &buffer, 6, 0) == 6 && buffer == Array("source".utf8))
    }

    @Test func eofWithoutRightsYieldsNothing() throws {
        let (parent, child) = try socketPair()
        defer { close(parent) }
        _ = "data only".withCString { write(child, $0, 9) }
        close(child)
        let received = receivePassedDescriptors(from: parent)
        #expect(received.descriptors.isEmpty && !received.truncated)
    }

    @Test func neverBlocksOnAnOpenEmptySocket() throws {
        let (parent, child) = try socketPair()
        defer { close(parent); close(child) }
        #expect(receivePassedDescriptors(from: parent).descriptors.isEmpty)
    }

    @Test func multipleDescriptorsAreAllReceived() throws {
        let (parent, child) = try socketPair()
        defer { close(parent) }
        let first = try ClosureProbe(), second = try ClosureProbe()
        #expect(sendDescriptors([first.readEnd, second.readEnd], over: child))
        let null = open("/dev/null", O_RDONLY)
        #expect(sendDescriptors([null], over: child))
        close(null); close(first.readEnd); close(second.readEnd); close(child)
        let received = receivePassedDescriptors(from: parent)
        #expect(received.descriptors.count == 3)
        for fd in received.descriptors { close(fd) }
        #expect(first.allReadEndsClosed && second.allReadEndsClosed)
    }

    @Test func moreRightsThanTheBufferHoldsIsTruncated() throws {
        let (parent, child) = try socketPair()
        defer { close(parent) }
        let many = (0..<12).map { _ in open("/dev/null", O_RDONLY) }
        #expect(sendDescriptors(many, over: child))
        for fd in many { close(fd) }
        close(child)
        let received = receivePassedDescriptors(from: parent)
        #expect(received.truncated)
        for fd in received.descriptors { close(fd) }
    }
}

// MARK: - Client policy

@Suite("authopen client")
struct AuthopenClientTests {
    @Test func oneDescriptorFromACleanExitIsReturned() async throws {
        let launcher = SendingLauncher { [open("/dev/null", O_RDONLY)] }
        let fd = try await client(launcher).openWholeDiskReadOnly(request)
        defer { close(fd) }
        #expect(isOpen(fd))
        let runs = await launcher.runs
        #expect(runs.count == 1)
        #expect(runs.first?.executable == "/nonexistent/fake-authopen")
        #expect(runs.first?.arguments == ["-stdoutpipe", "-o", "0", "/dev/rdisk42"])
    }

    /// The user cancelled the dialog (authopen exits non-zero and sends nothing).
    @Test(arguments: [DescriptorPassingResult.Termination.exited(1), .exited(255), .signaled, .timedOut])
    func noDescriptorFromAFailedRunMeansNoPassword(_ termination: DescriptorPassingResult.Termination) async {
        let launcher = ResultLauncher(DescriptorPassingResult(termination: termination, descriptors: [], truncated: false))
        await #expect(throws: ScanError.administratorPasswordNeeded) {
            _ = try await client(launcher).openWholeDiskReadOnly(request)
        }
    }

    @Test func cleanExitWithoutADescriptorIsAHandoffFailure() async {
        let launcher = ResultLauncher(DescriptorPassingResult(termination: .exited(0), descriptors: [], truncated: false))
        await #expect(throws: AuthopenClient.handoffFailedError) { _ = try await client(launcher).openWholeDiskReadOnly(request) }
    }

    @Test func extraDescriptorsAreAllClosedAndRefused() async throws {
        let first = try ClosureProbe(), second = try ClosureProbe()
        let launcher = SendingLauncher { [dup(first.readEnd), dup(second.readEnd)] }
        await #expect(throws: AuthopenClient.handoffFailedError) { _ = try await client(launcher).openWholeDiskReadOnly(request) }
        close(first.readEnd); close(second.readEnd)
        #expect(first.allReadEndsClosed && second.allReadEndsClosed)
    }

    @Test func descriptorFromAFailedRunIsClosed() async throws {
        let probe = try ClosureProbe()
        let launcher = SendingLauncher(status: 1) { [dup(probe.readEnd)] }
        await #expect(throws: AuthopenClient.handoffFailedError) { _ = try await client(launcher).openWholeDiskReadOnly(request) }
        close(probe.readEnd)
        #expect(probe.allReadEndsClosed)
    }

    @Test func truncatedRightsAreRefused() async throws {
        let probe = try ClosureProbe()
        let launcher = ResultLauncher(DescriptorPassingResult(termination: .exited(0), descriptors: [dup(probe.readEnd)], truncated: true))
        await #expect(throws: AuthopenClient.handoffFailedError) { _ = try await client(launcher).openWholeDiskReadOnly(request) }
        close(probe.readEnd)
        #expect(probe.allReadEndsClosed)
    }
}

// MARK: - Fallback order in openRawDevice

@Suite("Raw open falls back to the password dialog", .serialized)
struct PasswordFallbackTests {
    private func openers(status: HelperRegistrationStatus, helper: any PrivilegedOpening, password: any PrivilegedOpening,
                         log: CallLog) -> ElevatedOpeners {
        ElevatedOpeners(helper: LoggingOpener(name: "helper", log: log, inner: helper), helperStatus: { status },
                        password: LoggingOpener(name: "password", log: log, inner: password),
                        willAskForPassword: { await log.add("explain") })
    }

    @Test(arguments: [HelperRegistrationStatus.notRegistered, .requiresApproval, .notFound])
    func withoutAnEnabledHelperThePasswordDialogIsUsed(_ status: HelperRegistrationStatus) async throws {
        let log = CallLog()
        let password = client(SendingLauncher { [open("/dev/null", O_RDONLY)] })
        let fd = try await openRawDevice("disk42", expected: devNullIdentity(), directOpen: { _ in .failed(errno: EACCES) },
                                         elevated: openers(status: status, helper: FailingOpener(error: .io("never")), password: password, log: log))
        defer { close(fd) }
        #expect(await log.entries == ["explain", "password"])
        #expect(fcntl(fd, F_GETFL) & O_ACCMODE == O_RDONLY)
    }

    @Test func directOpenNeverAsksForAPassword() async throws {
        let log = CallLog()
        let fd = try await openRawDevice("disk42", expected: devNullIdentity(), directOpen: { _ in .opened(open("/dev/null", O_RDONLY)) },
                                         elevated: openers(status: .notRegistered, helper: FailingOpener(error: .io("never")),
                                                           password: FailingOpener(error: .io("never")), log: log))
        defer { close(fd) }
        #expect(await log.entries.isEmpty)
    }

    @Test func otherOpenErrorsNeverAskForAPassword() async {
        let log = CallLog()
        await #expect(throws: ScanError.io(String(cString: strerror(EBUSY)))) {
            _ = try await openRawDevice("disk42", expected: devNullIdentity(), directOpen: { _ in .failed(errno: EBUSY) },
                                        elevated: openers(status: .notRegistered, helper: FailingOpener(error: .io("never")),
                                                          password: FailingOpener(error: .io("never")), log: log))
        }
        #expect(await log.entries.isEmpty)
    }

    @Test func enabledHelperIsPreferredAndNoPasswordIsAsked() async throws {
        let log = CallLog()
        let fd = try await openRawDevice("disk42", expected: devNullIdentity(), directOpen: { _ in .failed(errno: EPERM) },
                                         elevated: openers(status: .enabled, helper: HelperFake(.devNull),
                                                           password: FailingOpener(error: .io("never")), log: log))
        defer { close(fd) }
        #expect(await log.entries == ["helper"])
    }

    static let helperRefusals: [ScanError] = [
        .unsafeTarget(RawBlockReader.bootDriveReason), .unsafeTarget(RawBlockReader.bootUnresolvedReason),
        .unsafeTarget(PrivilegedOpenClient.otherUsersDeviceReason), .deviceChanged,
        .io("The device was mounted again. Close files on it and retry."), .permissionDenied,
    ]

    @Test(arguments: helperRefusals)
    func helperSafetyRefusalsNeverFallThrough(_ refusal: ScanError) async {
        let log = CallLog()
        await #expect(throws: refusal) {
            _ = try await openRawDevice("disk42", expected: devNullIdentity(), directOpen: { _ in .failed(errno: EACCES) },
                                        elevated: openers(status: .enabled, helper: FailingOpener(error: refusal),
                                                          password: FailingOpener(error: .io("never")), log: log))
        }
        #expect(await log.entries == ["helper"])
    }

    @Test(arguments: [PrivilegedHelperApproval.unavailableError, PrivilegedHelperApproval.approvalRequiredError, PrivilegedHelperApproval.missingError])
    func unreachableHelperFallsBackToThePassword(_ error: ScanError) async throws {
        let log = CallLog()
        let password = client(SendingLauncher { [open("/dev/null", O_RDONLY)] })
        let fd = try await openRawDevice("disk42", expected: devNullIdentity(), directOpen: { _ in .failed(errno: EACCES) },
                                         elevated: openers(status: .enabled, helper: FailingOpener(error: error), password: password, log: log))
        defer { close(fd) }
        #expect(await log.entries == ["helper", "explain", "password"])
    }

    @Test func writableDescriptorFromThePasswordPathIsClosedAndRefused() async throws {
        let log = CallLog()
        let held = open("/dev/null", O_RDWR | O_NONBLOCK)
        defer { close(held) }
        let password = client(SendingLauncher { [dup(held)] })
        await #expect(throws: ScanError.unsafeTarget(RawBlockReader.writableDescriptorReason)) {
            _ = try await openRawDevice("disk42", expected: devNullIdentity(), directOpen: { _ in .failed(errno: EACCES) },
                                        elevated: openers(status: .notRegistered, helper: FailingOpener(error: .io("never")), password: password, log: log))
        }
    }

    @Test func wrongNodeFromThePasswordPathIsClosedAndRefused() async throws {
        let log = CallLog()
        let probe = try ClosureProbe()
        let password = client(SendingLauncher { [dup(probe.readEnd)] })
        await #expect(throws: ScanError.deviceChanged) {
            _ = try await openRawDevice("disk42", expected: devNullIdentity(), directOpen: { _ in .failed(errno: EACCES) },
                                        elevated: openers(status: .notRegistered, helper: FailingOpener(error: .io("never")), password: password, log: log))
        }
        close(probe.readEnd)
        #expect(probe.allReadEndsClosed)
    }

    @Test func cancelledPasswordIsReportedPlainly() async {
        let log = CallLog()
        let password = client(ResultLauncher(DescriptorPassingResult(termination: .exited(1), descriptors: [], truncated: false)))
        await #expect(throws: ScanError.administratorPasswordNeeded) {
            _ = try await openRawDevice("disk42", expected: devNullIdentity(), directOpen: { _ in .failed(errno: EACCES) },
                                        elevated: openers(status: .notRegistered, helper: FailingOpener(error: .io("never")), password: password, log: log))
        }
    }

    @Test func nonWholeDiskNameNeverReachesThePasswordPath() async {
        let log = CallLog()
        await #expect(throws: ScanError.unsafeTarget(RawBlockReader.notWholeDriveReason)) {
            _ = try await openRawDevice("disk42s1", expected: devNullIdentity(), directOpen: { _ in .failed(errno: EACCES) },
                                        elevated: openers(status: .notRegistered, helper: FailingOpener(error: .io("never")),
                                                          password: FailingOpener(error: .io("never")), log: log))
        }
        #expect(await log.entries.isEmpty)
    }
}

// MARK: - Process launcher (harmless executables only)

@Suite("Descriptor-passing process launcher")
struct ProcessDescriptorLauncherTests {
    @Test func nonZeroExitWithoutDescriptorIsAPasswordRefusal() async throws {
        let result = try await ProcessDescriptorLauncher().run(executable: "/usr/bin/false", arguments: [], timeout: .seconds(10))
        #expect(result == DescriptorPassingResult(termination: .exited(1), descriptors: [], truncated: false))
        // `false` ignores authopen's arguments, so the whole client path can run it.
        let client = AuthopenClient(launcher: ProcessDescriptorLauncher(), executablePath: "/usr/bin/false", timeout: .seconds(10))
        await #expect(throws: ScanError.administratorPasswordNeeded) { _ = try await client.openWholeDiskReadOnly(request) }
    }

    @Test func cleanExitWithoutDescriptorIsAHandoffFailure() async {
        let client = AuthopenClient(launcher: ProcessDescriptorLauncher(), executablePath: "/usr/bin/true", timeout: .seconds(10))
        await #expect(throws: AuthopenClient.handoffFailedError) { _ = try await client.openWholeDiskReadOnly(request) }
    }

    @Test func plainDataOnStdoutIsDiscarded() async throws {
        let result = try await ProcessDescriptorLauncher().run(executable: "/bin/sh", arguments: ["-c", "echo not-a-descriptor"], timeout: .seconds(10))
        #expect(result == DescriptorPassingResult(termination: .exited(0), descriptors: [], truncated: false))
    }

    @Test func missingExecutableFailsToLaunch() async {
        await #expect(throws: ProcessDescriptorLauncher.launchFailedError) {
            _ = try await ProcessDescriptorLauncher().run(executable: "/nonexistent/authopen", arguments: [], timeout: .seconds(1))
        }
    }

    @Test func timeoutStopsAndReapsTheChild() async throws {
        let pids = PidBox()
        let launcher = ProcessDescriptorLauncher(onLaunch: { pids.set($0) })
        let clock = ContinuousClock(), started = clock.now
        let result = try await launcher.run(executable: "/bin/sleep", arguments: ["30"], timeout: .milliseconds(300))
        #expect(result.termination == .timedOut && result.descriptors.isEmpty)
        #expect(clock.now - started < .seconds(5))
        let pid = try #require(pids.value)
        #expect(!processExists(pid))
    }

    @Test func timeoutThroughTheClientIsAPasswordRefusal() async {
        // `sleep` rejects authopen's arguments and exits at once; the timeout case is above. This
        // checks the client maps a timed-out run (no descriptor) to the same retryable error.
        let launcher = ResultLauncher(DescriptorPassingResult(termination: .timedOut, descriptors: [], truncated: false))
        await #expect(throws: ScanError.administratorPasswordNeeded) { _ = try await client(launcher).openWholeDiskReadOnly(request) }
    }

    @Test func cancellingTheTaskStopsAndReapsTheChild() async throws {
        let pids = PidBox()
        let launcher = ProcessDescriptorLauncher(onLaunch: { pids.set($0) })
        let task = Task { try await launcher.run(executable: "/bin/sleep", arguments: ["30"], timeout: .seconds(60)) }
        let clock = ContinuousClock(), deadline = clock.now + .seconds(10)
        while pids.value == nil, clock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let pid = try #require(pids.value)
        #expect(processExists(pid))
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(!processExists(pid))
    }

    @Test func alreadyCancelledTaskNeverLaunches() async {
        let pids = PidBox()
        let launcher = ProcessDescriptorLauncher(onLaunch: { pids.set($0) })
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await launcher.run(executable: "/bin/sleep", arguments: ["30"], timeout: .seconds(60))
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(pids.value == nil)
    }
}

private final class PidBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: pid_t?
    func set(_ pid: pid_t) { lock.withLock { stored = pid } }
    var value: pid_t? { lock.withLock { stored } }
}

// MARK: - The optional helper offer

@Suite("Skip-the-password offer")
struct HelperOfferTests {
    @Test func unsignedOrAdHocBuildsNeverOfferTheHelper() {
        for status in [HelperRegistrationStatus.enabled, .requiresApproval, .notRegistered, .notFound] {
            #expect(PrivilegedHelperApproval.offer(teamID: nil, status: status) == .unavailable)
            #expect(PrivilegedHelperApproval.offer(teamID: "", status: status) == .unavailable)
        }
    }

    @Test func signedBuildsOfferWhatTheStatusAllows() {
        #expect(PrivilegedHelperApproval.offer(teamID: "AB12CD34EF", status: .notFound) == .unavailable)
        #expect(PrivilegedHelperApproval.offer(teamID: "AB12CD34EF", status: .notRegistered) == .canRegister)
        #expect(PrivilegedHelperApproval.offer(teamID: "AB12CD34EF", status: .requiresApproval) == .awaitingApproval)
        #expect(PrivilegedHelperApproval.offer(teamID: "AB12CD34EF", status: .enabled) == .enabled)
    }
}
