import Foundation
import SalvageCore
import Testing
@testable import SalvageDiskIO

@Suite("Device watcher startup safety")
@MainActor
struct DeviceWatcherTests {
    @Test("Unresolved boot disks fail before device publication")
    func resolutionFailure() async {
        let watcher = DeviceWatcher(bootDiskResolver: {
            throw DeviceWatcherError.bootDiskResolutionFailed
        })
        await #expect(throws: DeviceWatcherError.bootDiskResolutionFailed) {
            _ = try await watcher.watch()
        }
    }

    @Test("An empty protected set is rejected")
    func emptyProtectedSet() async {
        let watcher = DeviceWatcher(bootDiskResolver: { [] })
        await #expect(throws: DeviceWatcherError.bootDiskResolutionFailed) {
            _ = try await watcher.watch()
        }
    }
}

// MARK: - Story 2.4: lock-state annotation flow, without DiskArbitration

/// A lock-state resolver whose answers the test releases by hand, so the ordering of device
/// changes and resolver completions is exactly what the test says, not what the scheduler does.
private actor HeldResolver {
    private(set) var inputs: [[BlockDevice]] = []
    private var pending: [CheckedContinuation<[BlockDevice], Never>] = []
    private nonisolated let calls = CountSignal()

    func resolve(_ devices: [BlockDevice]) async -> [BlockDevice] {
        inputs.append(devices)
        return await withCheckedContinuation { continuation in
            pending.append(continuation)
            calls.increment()
        }
    }

    /// Returns once the resolver has been called (and is holding) `count` times in total.
    nonisolated func waitForCalls(_ count: Int) async { await calls.wait(atLeast: count) }

    /// Answers the oldest still-pending call.
    func release(_ answer: [BlockDevice]) {
        pending.removeFirst().resume(returning: answer)
    }

    var pendingCount: Int { pending.count }
}

/// Collects what the publisher sent to the stream and lets a test await the next send.
@MainActor
private final class Published {
    private(set) var sets: [[BlockDevice]] = []
    private let received = CountSignal()

    func receive(_ set: [BlockDevice]) {
        sets.append(set)
        received.increment()
    }

    /// Returns once `count` sets in total have been published.
    func waitForCount(_ count: Int) async { await received.wait(atLeast: count) }
}

private let boot = BlockDevice(bsdName: "disk0", displayName: "Macintosh HD", sizeBytes: 1, isInternal: true, isBootVolume: true, mediaIdentity: 1)
private let vault = BlockDevice(bsdName: "disk7", displayName: "Vault SSD", sizeBytes: 2, isInternal: false, isBootVolume: false, mediaIdentity: 7)
private let stick = BlockDevice(bsdName: "disk9", displayName: "USB stick", sizeBytes: 3, isInternal: false, isBootVolume: false, mediaIdentity: 9)
private let vaultLocked = vault.requiringUnlock(volumeUUID: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE", volumeName: "Vault")

/// The enumeration the publisher sees; a test changes `devices` to simulate a disk event.
@MainActor
private final class FakeEnumeration {
    var devices: [BlockDevice]
    init(_ devices: [BlockDevice]) { self.devices = devices }
}

@MainActor
private func makePublisher(_ enumeration: FakeEnumeration, _ resolver: HeldResolver, _ published: Published) -> DeviceSetPublisher {
    DeviceSetPublisher(enumerate: { enumeration.devices },
                       lockStateResolver: { await resolver.resolve($0) },
                       publish: { published.receive($0) })
}

@Suite("Device watcher lock state", .timeLimit(.minutes(1)))
@MainActor
struct DeviceWatcherLockStateTests {
    @Test("The plain set goes out at once; the injected resolver's annotation follows")
    func injectedResolverAnnotates() async {
        let enumeration = FakeEnumeration([boot, vault]), resolver = HeldResolver(), published = Published()
        let publisher = makePublisher(enumeration, resolver, published)
        publisher.deviceSetChanged()
        #expect(published.sets == [[boot, vault]])
        await resolver.waitForCalls(1)
        #expect(await resolver.inputs == [[boot, vault]])
        await resolver.release([boot, vaultLocked])
        await published.waitForCount(2)
        #expect(published.sets == [[boot, vault], [boot, vaultLocked]])
    }

    @Test("A boot-only set never spawns the resolver")
    func bootOnlySkipsResolver() async {
        let enumeration = FakeEnumeration([boot]), resolver = HeldResolver(), published = Published()
        let publisher = makePublisher(enumeration, resolver, published)
        publisher.deviceSetChanged()
        await Task.yield()
        #expect(published.sets == [[boot]])
        #expect(await resolver.inputs.isEmpty)
    }

    /// Item 4: a later change (mount, unmount, lock, unlock) re-resolves the lock state, and an
    /// annotation that differs from what was last **published** is sent even when it equals the
    /// plain set -- that is exactly the "volume got unlocked" case, which must clear "Locked".
    @Test("A second emission re-resolves and clears a stale Locked state")
    func secondEmissionRefreshesLockState() async {
        let enumeration = FakeEnumeration([boot, vault]), resolver = HeldResolver(), published = Published()
        let publisher = makePublisher(enumeration, resolver, published)
        publisher.deviceSetChanged()
        await resolver.waitForCalls(1)
        await resolver.release([boot, vaultLocked])
        await published.waitForCount(2)
        #expect(published.sets.last == [boot, vaultLocked])

        // The user unlocked the volume outside Salvage; DiskArbitration reports a description
        // change on the same set of disks. No plain re-publish (nothing structural changed) ...
        publisher.deviceSetChanged()
        #expect(published.sets.count == 2)
        await resolver.waitForCalls(2)
        #expect(await resolver.inputs[1] == [boot, vault]) // ... the resolver always gets the plain set ...
        await resolver.release([boot, vault])
        await published.waitForCount(3)
        // ... and the now-unlocked state replaces the stale "Locked" row.
        #expect(published.sets == [[boot, vault], [boot, vaultLocked], [boot, vault]])

        // Locked again later: the annotation comes back.
        publisher.deviceSetChanged()
        await resolver.waitForCalls(3)
        await resolver.release([boot, vaultLocked])
        await published.waitForCount(4)
        #expect(published.sets.last == [boot, vaultLocked])
    }

    /// Item 8: a resolver answer for an older device set is dropped; the change that arrived while
    /// it ran is resolved once more, on the current set.
    @Test("A stale generation's annotation is dropped and the current set is re-resolved")
    func staleGenerationIsDropped() async {
        let enumeration = FakeEnumeration([boot, vault]), resolver = HeldResolver(), published = Published()
        let publisher = makePublisher(enumeration, resolver, published)
        publisher.deviceSetChanged()
        await resolver.waitForCalls(1)
        #expect(publisher.generation == 1)

        // A stick appears while the first listing is still running.
        enumeration.devices = [boot, vault, stick]
        publisher.deviceSetChanged()
        #expect(publisher.generation == 2)
        #expect(published.sets == [[boot, vault], [boot, vault, stick]])
        // Only one resolver run at a time: the second change queued a re-run instead of a second subprocess.
        #expect(await resolver.inputs.count == 1)

        // The first (stale) answer arrives: not published; the queued re-run starts on the new set.
        await resolver.release([boot, vaultLocked])
        await resolver.waitForCalls(2)
        #expect(published.sets == [[boot, vault], [boot, vault, stick]])
        #expect(await resolver.inputs[1] == [boot, vault, stick])
        await resolver.release([boot, vaultLocked, stick])
        await published.waitForCount(3)
        #expect(published.sets.last == [boot, vaultLocked, stick])
        #expect(await resolver.pendingCount == 0)

        // Stopped: a late answer goes nowhere.
        publisher.deviceSetChanged()
        await resolver.waitForCalls(3)
        publisher.stop()
        await resolver.release([boot, vault, stick])
        await Task.yield()
        #expect(published.sets.count == 3)
    }

    /// Item 6: the live annotation's blocking `diskutil` listing runs on a GCD global queue, not on
    /// the main thread and not on a cooperative-pool thread.
    @Test("The live listing runs off the main actor and off the cooperative pool")
    func listingRunsOnAGlobalQueue() async {
        let seen = Observed()
        let containers = [APFSListedContainer(reference: "disk8", physicalStoreWholeDisks: ["disk7"],
                                              volumes: [APFSListedVolume(uuid: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE", bsdName: "disk8s1",
                                                                         name: "Vault", isEncrypted: true, isLocked: true)])]
        let annotated = await DeviceWatcher.annotateLockedDevices([boot, vault], listing: {
            seen.record(label: String(cString: __dispatch_queue_get_label(nil)), isMain: Thread.isMainThread)
            return containers
        })
        #expect(annotated == [boot, vaultLocked])
        let (label, isMain) = seen.value
        #expect(!isMain)
        #expect(label.hasPrefix("com.apple.root."), "\(label)")
        #expect(!label.contains("cooperative"), "\(label)")
        // A failed listing leaves the set untouched.
        #expect(await DeviceWatcher.annotateLockedDevices([boot, vault], listing: { nil }) == [boot, vault])
    }
}

private final class Observed: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: (String, Bool) = ("", true)
    func record(label: String, isMain: Bool) { lock.withLock { stored = (label, isMain) } }
    var value: (String, Bool) { lock.withLock { stored } }
}

/// A counter a test can await reaching a value: a signal, not a polling loop. Cancellation-aware,
/// so a suite's `.timeLimit` turns a regression into a failure instead of a hang.
private final class CountSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var nextID = 0
    private var waiters: [Int: (threshold: Int, continuation: CheckedContinuation<Void, Never>)] = [:]

    var value: Int { lock.withLock { count } }

    func increment() {
        let ready: [CheckedContinuation<Void, Never>] = lock.withLock {
            count += 1
            let due = waiters.filter { $0.value.threshold <= count }
            due.keys.forEach { waiters[$0] = nil }
            return due.values.map(\.continuation)
        }
        ready.forEach { $0.resume() }
    }

    /// Returns once the count is at least `threshold`, or the waiting task is cancelled.
    func wait(atLeast threshold: Int) async {
        let id = lock.withLock { nextID += 1; return nextID }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow = lock.withLock {
                    if count >= threshold || Task.isCancelled { return true }
                    waiters[id] = (threshold, continuation)
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        } onCancel: {
            lock.withLock { waiters.removeValue(forKey: id) }?.continuation.resume()
        }
    }
}

// MARK: - DiskWatchRegistration start/stop, without a DASession

/// Records every DiskArbitration call `DiskWatchRegistration` makes through its registrar, in
/// order, so a test can compare what was registered with what was unregistered.
@MainActor
private final class RecordingRegistrar {
    struct Pair: Equatable { let callback: UnsafeMutableRawPointer; let context: UnsafeMutableRawPointer }
    enum Call: Equatable { case schedule, unschedule, register(Pair), unregister(Pair) }

    private(set) var calls: [Call] = []
    var registered: [Pair] { calls.compactMap { if case .register(let pair) = $0 { pair } else { nil } } }
    var unregistered: [Pair] { calls.compactMap { if case .unregister(let pair) = $0 { pair } else { nil } } }

    /// `DiskWatchRegistration` calls these on the main actor only (start() is main-actor
    /// isolated; stop() hops to the main queue first), which `assumeIsolated` also checks.
    var registrar: DiskArbitrationRegistrar {
        func record(_ call: Call) { MainActor.assumeIsolated { self.calls.append(call) } }
        return DiskArbitrationRegistrar(
            schedule: { record(.schedule) },
            unschedule: { record(.unschedule) },
            registerDiskAppeared: { record(.register(Pair(callback: unsafeBitCast($0, to: UnsafeMutableRawPointer.self), context: $1))) },
            registerDiskDisappeared: { record(.register(Pair(callback: unsafeBitCast($0, to: UnsafeMutableRawPointer.self), context: $1))) },
            registerDiskDescriptionChanged: { record(.register(Pair(callback: unsafeBitCast($0, to: UnsafeMutableRawPointer.self), context: $1))) },
            unregister: { record(.unregister(Pair(callback: $0, context: $1))) }
        )
    }
}

/// Device enumeration that counts how often the registration asks for the current set.
@MainActor
private final class CountingEnumeration {
    var devices: [BlockDevice]
    private(set) var calls = 0
    init(_ devices: [BlockDevice]) { self.devices = devices }
    func enumerate() -> [BlockDevice] { calls += 1; return devices }
}

@Suite("DiskWatchRegistration start/stop", .timeLimit(.minutes(1)))
@MainActor
struct DiskWatchRegistrationTests {
    @MainActor
    private final class Harness {
        let recorder = RecordingRegistrar()
        let stream: AsyncStream<[BlockDevice]>
        let registration: DiskWatchRegistration
        private let source: CountingEnumeration
        var enumerations: Int { source.calls }
        var devices: [BlockDevice] {
            get { source.devices }
            set { source.devices = newValue }
        }

        init() {
            let (stream, continuation) = AsyncStream<[BlockDevice]>.makeStream(bufferingPolicy: .unbounded)
            let source = CountingEnumeration([boot])
            self.stream = stream
            self.source = source
            registration = DiskWatchRegistration(registrar: recorder.registrar, continuation: continuation,
                                                 enumerate: { source.enumerate() }, lockStateResolver: { $0 })
        }

        /// Everything the stream delivered, once stop() has finished it.
        func drain() async -> [[BlockDevice]] {
            var sets: [[BlockDevice]] = []
            for await set in stream { sets.append(set) }
            return sets
        }
    }

    @Test("stop() unregisters exactly the callback/context pairs start() registered")
    func unregisterMatchesRegister() async {
        let harness = Harness()
        harness.registration.start()
        let registered = harness.recorder.registered
        let context = Unmanaged.passUnretained(harness.registration).toOpaque()
        #expect(registered.count == 3)
        #expect(Set(registered.map(\.callback)).count == 3, "each event kind gets its own callback")
        #expect(registered.allSatisfy { $0.context == context }, "the context is the registration itself")
        #expect(harness.recorder.calls.first == .schedule, "scheduled before any callback can be registered")

        harness.registration.stop()
        _ = await harness.drain()

        #expect(harness.recorder.unregistered == registered, "same pairs, same order")
        #expect(harness.recorder.calls.last == .unschedule, "unscheduled only after every callback is unregistered")
        #expect(harness.recorder.calls.filter { $0 == .schedule }.count == 1)
        #expect(harness.recorder.calls.filter { $0 == .unschedule }.count == 1)
    }

    @Test("start() twice registers once, and stop() twice unregisters once")
    func startAndStopAreIdempotent() async {
        let harness = Harness()
        harness.registration.start()
        harness.registration.start()
        #expect(harness.recorder.registered.count == 3)
        harness.registration.stop()
        harness.registration.stop()
        _ = await harness.drain()
        // Let the second stop()'s main-queue hop run too.
        try? await Task.sleep(for: .milliseconds(20))
        #expect(harness.recorder.unregistered.count == 3)
        #expect(harness.recorder.calls.filter { $0 == .unschedule }.count == 1)
    }

    @Test("A DiskArbitration callback delivered after stop() publishes nothing")
    func noCallbackFiresAfterStop() async throws {
        let harness = Harness()
        harness.registration.start()
        let context = try #require(harness.recorder.registered.first?.context)
        #expect(harness.enumerations == 1, "start() publishes the initial set")

        // While active, a callback re-enumerates and publishes a changed set.
        harness.devices = [boot, stick]
        DiskWatchRegistration.handleChange(context: context)
        #expect(harness.enumerations == 2)

        harness.registration.stop()
        let published = await harness.drain()
        #expect(published == [[boot], [boot, stick]])

        // A callback DiskArbitration had already queued before the unregister lands now: it must
        // neither enumerate nor publish.
        harness.devices = [boot]
        DiskWatchRegistration.handleChange(context: context)
        DiskWatchRegistration.handleChange(context: nil)
        #expect(harness.enumerations == 2)
    }
}
