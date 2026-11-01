import DiskArbitration
import Foundation
import IOKit
import SalvageCore

/// Error surfaced during startup by `DeviceWatcher.watch()` itself, kept out of the
/// `AsyncStream<[BlockDevice]>` element type so that stream's contract stays exactly "the full
/// current device set, re-emitted in full on every appear/disappear change" (this story's Design
/// Notes) -- no case is folded in for "watching never started at all." The I/O matrix's
/// "DiskArbitration session fails to register" row needs a signal distinct from "zero devices
/// are attached right now"; throwing gives `DeviceListViewModel` exactly that distinction, so it
/// can render a clear error state instead of a silently empty list.
public enum DeviceWatcherError: Error, Sendable, Equatable, CustomStringConvertible {
    case sessionRegistrationFailed
    case bootDiskResolutionFailed

    /// Plain-language only -- never names an internal mechanism like "DiskArbitration," matching
    /// the plain-language bar `EXPERIENCE.md`'s Voice and Tone table sets for this app's copy.
    public var description: String {
        switch self {
        case .bootDiskResolutionFailed:
            return "Couldn’t identify your startup drive safely. Try reopening the app."
        case .sessionRegistrationFailed:
            return "Try reopening the app."
        }
    }
}

/// Abstraction over `DeviceWatcher` so `DeviceListViewModel` (and other consumers) can be
/// constructed with a fake in tests, without needing a real DiskArbitration session.
public protocol DeviceWatching: Sendable {
    @MainActor func watch() async throws -> AsyncStream<[BlockDevice]>
}

/// Live-updating macOS block-device watcher -- the exclusive DiskArbitration owner in this
/// codebase (Architecture AD-1, CI-enforced by AD-9; `scripts/check-core-boundary.sh`). Nothing
/// outside `SalvageDiskIO` is permitted to import DiskArbitration.
///
/// Registers `DARegisterDiskAppearedCallback`/`DARegisterDiskDisappearedCallback` (and, for
/// Story 2.4's lock state, `DARegisterDiskDescriptionChangedCallback`) on a `DASession`
/// scheduled on the app's main run loop (DiskArbitration callbacks require a run
/// loop or dispatch queue to actually fire), and converts every currently-attached whole disk
/// into a `BlockDevice` using Story 1.2's ported BSD-name-parsing (`BSDDeviceNames.swift`) and
/// boot-disk-resolution (`BootDiskSafety.swift`) logic -- the one-shot enumeration this builds on
/// is adapted from that story's spike (`DeviceEnumeration.swift`'s `listDevices()`), producing
/// `BlockDevice` values instead of printing to stdout, and additionally filtering to whole disks
/// only (`BlockDevice` models whole disks, never partitions/volumes, per this story's Boundaries).
public final class DeviceWatcher: DeviceWatching, Sendable {
    /// Story 2.4: annotates the devices whose APFS container holds only locked (FileVault)
    /// volumes with that volume (`BlockDevice.requiringUnlock`), so the Device Picker can show
    /// "Locked" and offer the unlock sheet before any scan. Read-only metadata query.
    typealias LockStateResolver = @Sendable ([BlockDevice]) async -> [BlockDevice]

    private let bootDiskResolver: @Sendable () async throws -> Set<String>
    private let lockStateResolver: LockStateResolver

    public init() {
        bootDiskResolver = Self.resolveProtectedDisks
        lockStateResolver = Self.annotateLockedDevices
    }

    init(bootDiskResolver: @escaping @Sendable () async throws -> Set<String>,
         lockStateResolver: @escaping LockStateResolver = { $0 }) {
        self.bootDiskResolver = bootDiskResolver
        self.lockStateResolver = lockStateResolver
    }

    /// Starts watching. Throws `DeviceWatcherError.sessionRegistrationFailed` if a `DASession`
    /// itself cannot be created -- see that error's doc comment for why this is a thrown error
    /// rather than a stream element. The returned stream's first emission is the device set as
    /// of the moment watching starts; it continues emitting the full current set on every
    /// subsequent appear/disappear event, and finishes only when its continuation is torn down
    /// (the consuming `Task` is cancelled).
    @MainActor public func watch() async throws -> AsyncStream<[BlockDevice]> {
        let bootDisks = try await bootDiskResolver()
        guard !bootDisks.isEmpty else { throw DeviceWatcherError.bootDiskResolutionFailed }
        try Task.checkCancellation()
        guard let session = DASessionCreate(kCFAllocatorDefault) else {
            throw DeviceWatcherError.sessionRegistrationFailed
        }

        let lockStateResolver = lockStateResolver
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let registration = DiskWatchRegistration(session: session, continuation: continuation, bootDisks: bootDisks,
                                                     lockStateResolver: lockStateResolver)
            registration.start()
            continuation.onTermination = { _ in
                registration.stop()
            }
        }
    }

    /// Resolve before publishing any selectable devices; subprocess work stays off the UI actor.
    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated private static func resolveProtectedDisks() async throws -> Set<String> {
        guard case .success(let disks) = resolveBootDisks(), !disks.isEmpty else {
            throw DeviceWatcherError.bootDiskResolutionFailed
        }
        return disks
    }

    /// `diskutil apfs list -plist`, off the UI actor. A failed listing changes nothing: no device
    /// is marked locked, none is claimed unlocked.
    nonisolated private static func annotateLockedDevices(_ devices: [BlockDevice]) async -> [BlockDevice] {
        await annotateLockedDevices(devices, listing: liveAPFSContainers)
    }

    /// The listing is a blocking subprocess (tens to hundreds of milliseconds), so it runs on a GCD
    /// queue through the same hop `FileVaultUnlocker` uses: never on the main actor, never on a
    /// cooperative-pool thread (where it would hold one of the few threads Swift concurrency has
    /// for the whole wait). `listing` is injectable so a test can observe where it runs.
    nonisolated static func annotateLockedDevices(_ devices: [BlockDevice],
                                                  listing: @escaping @Sendable () -> [APFSListedContainer]?) async -> [BlockDevice] {
        guard let containers = await offCooperativePool(listing) else { return devices }
        return annotateLocked(devices, containers: containers)
    }
}

/// Publishes device sets to the watcher's stream. Each device change publishes the plain set at
/// once (the enumeration is cheap) and then, once the lock state resolver (a subprocess) has
/// answered, the annotated set -- but only when that differs from what was **last published**,
/// so a volume that was locked and is now unlocked (or the reverse) always reaches the picker:
/// comparing against the plain set instead would silently keep a stale "Locked" row.
///
/// Confined to the main actor (DiskArbitration delivers on the main run loop). Separated from the
/// DiskArbitration registration so this flow has unit coverage with an injected enumeration and
/// resolver, without a `DASession`.
@MainActor
final class DeviceSetPublisher {
    typealias Enumerate = @MainActor () -> [BlockDevice]
    typealias Publish = @MainActor ([BlockDevice]) -> Void

    private let enumerate: Enumerate
    private let resolveLockState: DeviceWatcher.LockStateResolver
    private let publish: Publish
    private var isActive = true
    /// Counts device changes, so an annotation that finishes after the device set changed again
    /// is dropped instead of overwriting the newer set.
    private(set) var generation = 0
    /// The plain (unannotated) set as last enumerated.
    private var devices: [BlockDevice] = []
    private var lastPublished: [BlockDevice]?
    /// One resolver run at a time: a change that arrives while one is in flight queues a single
    /// re-run on the then-current set instead of spawning a subprocess per DiskArbitration event.
    private var annotationInFlight = false
    private var annotationQueued = false

    init(enumerate: @escaping Enumerate, lockStateResolver: @escaping DeviceWatcher.LockStateResolver,
         publish: @escaping Publish) {
        self.enumerate = enumerate
        self.resolveLockState = lockStateResolver
        self.publish = publish
    }

    /// A disk appeared, disappeared, or changed its description (mounted, unmounted, locked,
    /// unlocked). Re-enumerates; publishes the plain set at once if the set of disks changed; then
    /// re-resolves the lock state and publishes the result if it differs from what is showing.
    func deviceSetChanged() {
        guard isActive else { return }
        generation += 1
        let current = enumerate()
        if current != devices || lastPublished == nil {
            devices = current
            send(current)
        }
        scheduleAnnotation()
    }

    func stop() { isActive = false }

    private func scheduleAnnotation() {
        guard devices.contains(where: { !$0.isBootVolume }) else { return }
        guard !annotationInFlight else { annotationQueued = true; return }
        annotationInFlight = true
        annotationQueued = false
        let resolver = resolveLockState, snapshot = devices, started = generation
        Task { [weak self] in
            let annotated = await resolver(snapshot)
            self?.annotationFinished(annotated, generation: started)
        }
    }

    private func annotationFinished(_ annotated: [BlockDevice], generation started: Int) {
        annotationInFlight = false
        guard isActive else { return }
        if started == generation { send(annotated) }
        // A change arrived while the resolver ran: its answer is for an older set, so run once more.
        if annotationQueued { scheduleAnnotation() }
    }

    private func send(_ set: [BlockDevice]) {
        guard set != lastPublished else { return }
        lastPublished = set
        publish(set)
    }
}

/// Pure: marks each non-boot device whose containers hold only locked volumes with the first such
/// volume. Everything else is returned unchanged.
func annotateLocked(_ devices: [BlockDevice], containers: [APFSListedContainer]) -> [BlockDevice] {
    devices.map { device in
        guard !device.isBootVolume, device.encryptedVolumeUUID == nil,
              let locked = lockedVolume(onWholeDisk: device.bsdName, containers: containers) else { return device }
        return device.requiringUnlock(volumeUUID: locked.uuid, volumeName: locked.name)
    }
}

// MARK: - Live registration

// Non-capturing trampolines, held as stable top-level values so the exact same function pointer
// can be passed to both DARegisterDisk*Callback (to register) and DAUnregisterCallback (to
// unregister) -- DiskArbitration identifies a registration by that pointer. DiskArbitration's
// callback typealiases are `@convention(c)`, so these closures may not capture any state; they
// recover the registration instance from the `context` pointer DiskArbitration hands back.
private let diskAppearedTrampoline: DADiskAppearedCallback = { _, context in
    DiskWatchRegistration.handleChange(context: context)
}

private let diskDisappearedTrampoline: DADiskDisappearedCallback = { _, context in
    DiskWatchRegistration.handleChange(context: context)
}

/// Story 2.4: a disk's description changed -- a volume was mounted or unmounted, which is also
/// what locking and unlocking a FileVault volume do -- so the picker's "Locked" state is
/// re-resolved instead of staying as it was when the disk appeared.
private let diskDescriptionChangedTrampoline: DADiskDescriptionChangedCallback = { _, _, context in
    DiskWatchRegistration.handleChange(context: context)
}

/// Holds the live DiskArbitration registration state for one `DeviceWatcher.watch()` call. A
/// class, not a struct, because its identity is handed to the C callbacks above as an
/// `UnsafeMutableRawPointer` context.
///
/// Mutable state is confined to the main run loop: watch() starts on MainActor, callbacks
/// run there, and stop() retains the registration until cleanup on that same run loop.
private final class DiskWatchRegistration: @unchecked Sendable {
    private let session: DASession
    private let continuation: AsyncStream<[BlockDevice]>.Continuation
    private let publisher: DeviceSetPublisher
    private var isActive = false

    @MainActor
    init(session: DASession, continuation: AsyncStream<[BlockDevice]>.Continuation, bootDisks: Set<String>,
         lockStateResolver: @escaping DeviceWatcher.LockStateResolver) {
        self.session = session
        self.continuation = continuation
        publisher = DeviceSetPublisher(enumerate: { Self.enumerateDevices(session: session, bootDisks: bootDisks) },
                                       lockStateResolver: lockStateResolver,
                                       publish: { continuation.yield($0) })
    }

    @MainActor func start() {
        guard !isActive else { return }
        isActive = true

        DASessionScheduleWithRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        let context = Unmanaged.passUnretained(self).toOpaque()
        DARegisterDiskAppearedCallback(session, nil, diskAppearedTrampoline, context)
        DARegisterDiskDisappearedCallback(session, nil, diskDisappearedTrampoline, context)
        // No match or watch filter: any description change on any disk re-resolves lock state.
        DARegisterDiskDescriptionChangedCallback(session, nil, nil, diskDescriptionChangedTrampoline, context)

        publisher.deviceSetChanged()
    }

    func stop() {
        // `AsyncStream.Continuation.onTermination` (this method's only caller) can fire from an
        // arbitrary thread -- hop onto the main queue so every mutation here still honors this
        // type's "main-thread only" invariant (see the doc comment on this class).
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated {
                guard self.isActive else { return }
                self.isActive = false
                self.publisher.stop()
                let context = Unmanaged.passUnretained(self).toOpaque()
                DAUnregisterCallback(self.session, unsafeBitCast(diskAppearedTrampoline, to: UnsafeMutableRawPointer.self), context)
                DAUnregisterCallback(self.session, unsafeBitCast(diskDisappearedTrampoline, to: UnsafeMutableRawPointer.self), context)
                DAUnregisterCallback(self.session, unsafeBitCast(diskDescriptionChangedTrampoline, to: UnsafeMutableRawPointer.self), context)
                DASessionUnscheduleFromRunLoop(self.session, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
                self.continuation.finish()
            }
        }
    }

    /// DiskArbitration delivers on the main run loop (where the session is scheduled), so this is
    /// on the main thread; `assumeIsolated` makes that the compiler's premise too.
    fileprivate static func handleChange(context: UnsafeMutableRawPointer?) {
        guard let context else { return }
        let registration = Unmanaged<DiskWatchRegistration>.fromOpaque(context).takeUnretainedValue()
        MainActor.assumeIsolated {
            guard registration.isActive else { return }
            registration.publisher.deviceSetChanged()
        }
    }

    /// Enumerates every currently-attached whole disk via DiskArbitration (metadata only -- no
    /// Full Disk Access required for this, confirmed by Story 1.2's spike) and converts each one
    /// to a `BlockDevice`. The `0...63` scan range and per-disk key reads are ported from the
    /// spike's `listDevices()`; filtering to `kDADiskDescriptionMediaWholeKey` is new, since
    /// `BlockDevice` (unlike the spike's printed listing) models whole disks only.
    fileprivate static func enumerateDevices(session: DASession, bootDisks: Set<String>) -> [BlockDevice] {
        var devices: [BlockDevice] = []
        for n in 0...63 {
            let name = "disk\(n)"
            guard let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, name) else { continue }
            guard let descCF = DADiskCopyDescription(disk) else { continue }
            let desc = descCF as NSDictionary

            let isWhole = (desc[kDADiskDescriptionMediaWholeKey as String] as? Bool) ?? false
            guard isWhole else { continue }

            let isInternal = (desc[kDADiskDescriptionDeviceInternalKey as String] as? Bool) ?? false
            let sizeBytes = (desc[kDADiskDescriptionMediaSizeKey as String] as? NSNumber)?.int64Value ?? 0
            let model = ((desc[kDADiskDescriptionDeviceModelKey as String] as? String) ?? "")
                .trimmingCharacters(in: .whitespaces)
            let displayName = model.isEmpty ? name : model

            let media = DADiskCopyIOMedia(disk)
            var registryID: UInt64 = 0
            guard media != 0 else { continue }
            let identityResult = IORegistryEntryGetRegistryEntryID(media, &registryID)
            IOObjectRelease(media)
            guard identityResult == KERN_SUCCESS else { continue }

            devices.append(
                BlockDevice(
                    bsdName: name,
                    displayName: displayName,
                    sizeBytes: sizeBytes,
                    isInternal: isInternal,
                    isBootVolume: isWithinBootDiskSet(name, bootDisks: bootDisks),
                    mediaIdentity: registryID
                )
            )
        }
        return devices
    }
}
