import Darwin
import Foundation
import SalvageCore
import Testing
@testable import SalvageDiskIO

private let scanDevice = BlockDevice(bsdName: "disk42", displayName: "Test", sizeBytes: 65536,
                                     isInternal: false, isBootVolume: false, mediaIdentity: 7)

actor PreparationFake: RawDeviceOperations {
    enum Failure: Sendable { case none, protection, unmount, permission, changed, bootAfterUnmount, postOpenChange, hangingUnmount }
    let failure: Failure
    let suspendUnmount: Bool
    let blockSize: Int
    let mounts: [String]
    var unmountWaiter: CheckedContinuation<Void, Never>?
    var unmounted = false
    var unmountStarted = false
    var opened = 0
    var closed = 0
    init(_ failure: Failure = .none, suspendUnmount: Bool = false, blockSize: Int = 512, mounts: [String] = []) {
        self.failure = failure; self.suspendUnmount = suspendUnmount; self.blockSize = blockSize; self.mounts = mounts
    }
    func protectedDisks() async throws -> Set<String> {
        if failure == .protection { throw ScanError.unsafeTarget("Unknown startup disk") }
        if failure == .bootAfterUnmount && unmounted { return ["disk42"] }
        return ["disk0"]
    }
    func identity(_ name: String) async throws -> RawDeviceIdentity {
        let changed = (failure == .changed && unmounted) || (failure == .postOpenChange && opened > 0)
        return RawDeviceIdentity(registryID: changed ? 8 : 7, sizeBytes: 65536, blockSize: blockSize, deviceNumber: 42)
    }
    func mountSources() async throws -> [String] { mounts }
    func unmount(_ name: String) async throws {
        if failure == .unmount { throw ScanError.io("Busy") }
        if failure == .hangingUnmount { unmountStarted = true; try await Task.sleep(for: .seconds(600)) }
        if suspendUnmount { await withCheckedContinuation { unmountWaiter = $0 } }
        unmounted = true
    }
    func finishUnmount() { unmountWaiter?.resume(); unmountWaiter = nil }
    func isWaiting() -> Bool { unmountWaiter != nil }
    func openReadOnly(_ name: String, expected: RawDeviceIdentity) async throws -> Int32 {
        if failure == .permission { throw ScanError.permissionDenied }
        opened += 1; return 123
    }
    func closeDescriptor(_ descriptor: Int32) async { closed += 1 }
    func counts() -> (Int, Int) { (opened, closed) }
    func didUnmount() -> Bool { unmounted }
    func didStartUnmount() -> Bool { unmountStarted }
}

@Suite("Protected raw-device preparation")
struct RawBlockReaderTests {
    @Test func reservationLastsThroughExplicitClose() async throws {
        let fake = PreparationFake(), registry = DeviceReadReservations()
        let reader = try await RawBlockReader.prepare(device: scanDevice, operations: fake, reservations: registry)
        #expect(await registry.isReserved("disk42"))
        await #expect(throws: ScanError.deviceInUse) {
            _ = try await RawBlockReader.prepare(device: scanDevice, operations: fake, reservations: registry)
        }
        #expect(await registry.isReserved("disk42"))
        await reader.close(); await reader.close()
        #expect(!(await registry.isReserved("disk42")))
        let (opens, closes) = await fake.counts()
        #expect(opens == 1 && closes == 1)
    }
    @Test(arguments: [PreparationFake.Failure.protection, .unmount, .permission, .changed, .bootAfterUnmount, .postOpenChange])
    func preparationFailuresReleaseReservation(_ failure: PreparationFake.Failure) async {
        let fake = PreparationFake(failure), registry = DeviceReadReservations()
        do {
            _ = try await RawBlockReader.prepare(device: scanDevice, operations: fake, reservations: registry)
            Issue.record("Preparation should fail")
        } catch { }
        #expect(!(await registry.isReserved("disk42")))
        let (opens, closes) = await fake.counts()
        #expect(opens == closes)
    }
    @Test func cancellationWaitsForUnmountCleanupAndRejectsDuplicate() async throws {
        let fake = PreparationFake(suspendUnmount: true), registry = DeviceReadReservations()
        let task = Task { try await RawBlockReader.prepare(device: scanDevice, operations: fake, reservations: registry) }
        while !(await fake.isWaiting()) { await Task.yield() }
        task.cancel()
        #expect(await registry.isReserved("disk42"))
        await #expect(throws: ScanError.deviceInUse) {
            _ = try await RawBlockReader.prepare(device: scanDevice, operations: fake, reservations: registry)
        }
        await fake.finishUnmount()
        do { _ = try await task.value; Issue.record("Expected cancellation") } catch is CancellationError { } catch { Issue.record("Wrong error: \(error)") }
        #expect(!(await registry.isReserved("disk42")))
        let (opens, closes) = await fake.counts()
        #expect(opens == 0 && closes == 0)
    }
    @Test func missingIdentityAndUnsupportedSectorsRefuseBeforeUnmount() async {
        for missing in [true, false] {
            let fake = PreparationFake(blockSize: missing ? 512 : 4096), registry = DeviceReadReservations()
            let device = BlockDevice(bsdName: "disk42", displayName: "Test", sizeBytes: 65536,
                                     isInternal: false, isBootVolume: false, mediaIdentity: missing ? nil : 7)
            await #expect(throws: (any Error).self) { _ = try await RawBlockReader.prepare(device: device, operations: fake, reservations: registry) }
            #expect(!(await fake.didUnmount()))
            let (opens, _) = await fake.counts(); #expect(opens == 0)
            #expect(!(await registry.isReserved("disk42")))
        }
    }
    @Test(arguments: ["/dev/disk42", "/dev/disk42s1", "/dev/rdisk42s2"])
    func remountedTargetRefusesAndReleasesReservation(_ source: String) async {
        let fake = PreparationFake(mounts: [source]), registry = DeviceReadReservations()
        await #expect(throws: (any Error).self) { _ = try await RawBlockReader.prepare(device: scanDevice, operations: fake, reservations: registry) }
        let (opens, closes) = await fake.counts(); #expect(opens == 0 && closes == 0)
        #expect(!(await registry.isReserved("disk42")))
    }
    @Test func unrelatedMountedSourcesPermitPreparation() async throws {
        let fake = PreparationFake(mounts: ["/dev/disk0s1", "/dev/disk420s1", "map auto_home"]), registry = DeviceReadReservations()
        let reader = try await RawBlockReader.prepare(device: scanDevice, operations: fake, reservations: registry)
        await reader.close()
        #expect(!(await registry.isReserved("disk42")))
    }
    @Test func staleSelectionIdentityRefusesBeforeUnmount() async {
        let fake = PreparationFake(), registry = DeviceReadReservations()
        let stale = BlockDevice(bsdName: "disk42", displayName: "Stale", sizeBytes: 65536,
                                isInternal: false, isBootVolume: false, mediaIdentity: 6)
        await #expect(throws: ScanError.deviceChanged) {
            _ = try await RawBlockReader.prepare(device: stale, operations: fake, reservations: registry)
        }
        #expect(!(await registry.isReserved("disk42")))
        let (opens, _) = await fake.counts(); #expect(opens == 0)
    }
    @Test func bootTargetRefusesBeforeUnmountOrOpen() async {
        let fake = PreparationFake(), registry = DeviceReadReservations()
        let boot = BlockDevice(bsdName: "disk42", displayName: "Startup", sizeBytes: 65536, isInternal: true, isBootVolume: true)
        await #expect(throws: ScanError.unsafeTarget("Your boot drive can't be scanned while macOS is running from it.")) {
            _ = try await RawBlockReader.prepare(device: boot, operations: fake, reservations: registry)
        }
        #expect(!(await fake.didUnmount()))
        let (opens, closes) = await fake.counts(); #expect(opens == 0 && closes == 0)
    }
    @Test func alignedIOReadsExactUnalignedSliceAndRejectsClosedAndOutOfBounds() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let bytes = Data((0..<4096).map { UInt8(truncatingIfNeeded: $0) })
        try bytes.write(to: url)
        let ops = FileDescriptorOperations(url: url), registry = DeviceReadReservations()
        let device = BlockDevice(bsdName: "disk42", displayName: "File", sizeBytes: 4096, isInternal: false, isBootVolume: false, mediaIdentity: 7)
        let reader = try await RawBlockReader.prepare(device: device, operations: ops, reservations: registry)
        do {
            let result = try await reader.read(at: 13, count: 1000)
            #expect(result == bytes.subdata(in: 13..<1013))
            await #expect(throws: (any Error).self) { _ = try await reader.read(at: 4095, count: 2) }
            await #expect(throws: (any Error).self) { _ = try await reader.read(at: -1, count: 2) }
            // Truncate the temporary backing file to simulate a detached/truncated source.
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: 512); try handle.close()
            await #expect(throws: (any Error).self) { _ = try await reader.read(at: 512, count: 512) }
        } catch { await reader.close(); throw error }
        await reader.close()
        await #expect(throws: (any Error).self) { _ = try await reader.read(at: 0, count: 1) }
        #expect(!(await registry.isReserved("disk42")))
    }
    @Test func malformedWholeDiskNameRefusesRawAccess() async {
        let fake = PreparationFake(), registry = DeviceReadReservations()
        for name in ["disk42s1", "/dev/disk42", "disk42/other", "disk"] {
            let invalid = BlockDevice(bsdName: name, displayName: "Invalid", sizeBytes: 65536, isInternal: false, isBootVolume: false)
            await #expect(throws: ScanError.unsafeTarget("This device can't be scanned because its system name isn't a whole drive.")) {
                _ = try await RawBlockReader.prepare(device: invalid, operations: fake, reservations: registry)
            }
            // A malformed name is refused for its own reason, even when it is also flagged boot.
            let invalidBoot = BlockDevice(bsdName: name, displayName: "Invalid", sizeBytes: 65536, isInternal: true, isBootVolume: true)
            await #expect(throws: ScanError.unsafeTarget("This device can't be scanned because its system name isn't a whole drive.")) {
                _ = try await RawBlockReader.prepare(device: invalidBoot, operations: fake, reservations: registry)
            }
        }
        let (opens, _) = await fake.counts(); #expect(opens == 0)
    }
    @Test(arguments: [PreparationFake.Failure.protection, .unmount, .permission, .changed, .bootAfterUnmount, .postOpenChange])
    func failedPreparationLeavesDeviceReacquirable(_ failure: PreparationFake.Failure) async throws {
        let registry = DeviceReadReservations()
        await #expect(throws: (any Error).self) {
            _ = try await RawBlockReader.prepare(device: scanDevice, operations: PreparationFake(failure), reservations: registry)
        }
        let reader = try await RawBlockReader.prepare(device: scanDevice, operations: PreparationFake(), reservations: registry)
        #expect(await registry.isReserved("disk42"))
        await reader.close()
        #expect(!(await registry.isReserved("disk42")))
    }
    @Test func cancelledHangingUnmountReleasesAndDeviceIsReacquirable() async throws {
        let hanging = PreparationFake(.hangingUnmount), registry = DeviceReadReservations()
        let task = Task { try await RawBlockReader.prepare(device: scanDevice, operations: hanging, reservations: registry) }
        while !(await hanging.didStartUnmount()) { await Task.yield() }
        #expect(await registry.isReserved("disk42"))
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(!(await registry.isReserved("disk42")))
        let reader = try await RawBlockReader.prepare(device: scanDevice, operations: PreparationFake(), reservations: registry)
        await reader.close()
        #expect(!(await registry.isReserved("disk42")))
    }
}

@Suite("One-shot OS callback bridging")
struct OneShotCompletionTests {
    @Test func callbackResultIsDelivered() async throws {
        let completion = OneShotCompletion()
        try await completion.wait(timeout: .seconds(30), timeoutError: ScanError.io("timeout")) {
            completion.finish(.success(()))
        }
        await #expect(throws: ScanError.deviceChanged) {
            let failing = OneShotCompletion()
            try await failing.wait(timeout: .seconds(30), timeoutError: ScanError.io("timeout")) {
                failing.finish(.failure(ScanError.deviceChanged))
            }
        }
    }
    @Test func missingCallbackTimesOutAndLateCallbackIsIgnored() async {
        let completion = OneShotCompletion(), started = ContinuousClock.now
        await #expect(throws: ScanError.io("timeout")) {
            try await completion.wait(timeout: .milliseconds(50), timeoutError: ScanError.io("timeout")) { }
        }
        #expect(started.duration(to: .now) < .seconds(10))
        // A late OS callback after the timeout must not resume the continuation a second time.
        completion.finish(.success(()))
        completion.finish(.failure(ScanError.deviceChanged))
        #expect(completion.isFinished)
    }
    @Test func cancellationResumesWithoutCallback() async {
        let completion = OneShotCompletion(), probe = StartProbe()
        let task = Task { try await completion.wait(timeout: .seconds(600), timeoutError: ScanError.io("timeout")) { probe.mark() } }
        // Cancel only once the operation has started and the continuation is suspended.
        while !probe.started { await Task.yield() }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        completion.finish(.success(()))
    }
    @Test func alreadyCancelledWaitNeverStartsOperation() async {
        let completion = OneShotCompletion(), probe = StartProbe()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await completion.wait(timeout: .seconds(600), timeoutError: ScanError.io("timeout")) { probe.mark() }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!probe.started)
    }
}

private final class StartProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func mark() { lock.withLock { value = true } }
    var started: Bool { lock.withLock { value } }
}

private actor FileDescriptorOperations: RawDeviceOperations {
    let url: URL
    init(url: URL) { self.url = url }
    func protectedDisks() async throws -> Set<String> { ["disk0"] }
    func identity(_ name: String) async throws -> RawDeviceIdentity {
        RawDeviceIdentity(registryID: 7, sizeBytes: 4096, blockSize: 512, deviceNumber: 42)
    }
    func mountSources() async throws -> [String] { [] }
    func unmount(_ name: String) async throws { }
    func openReadOnly(_ name: String, expected: RawDeviceIdentity) async throws -> Int32 {
        let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw ScanError.io("Could not open test fixture") }
        return fd
    }
    func closeDescriptor(_ descriptor: Int32) async { Darwin.close(descriptor) }
}
