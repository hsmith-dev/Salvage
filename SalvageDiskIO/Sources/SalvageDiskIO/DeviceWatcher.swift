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
/// Registers `DARegisterDiskAppearedCallback`/`DARegisterDiskDisappearedCallback` on a
/// `DASession` scheduled on the app's main run loop (DiskArbitration callbacks require a run
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
    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated private static func annotateLockedDevices(_ devices: [BlockDevice]) async -> [BlockDevice] {
        guard let containers = liveAPFSContainers() else { return devices }
        return annotateLocked(devices, containers: containers)
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

/// Holds the live DiskArbitration registration state for one `DeviceWatcher.watch()` call. A
/// class, not a struct, because its identity is handed to the C callbacks above as an
/// `UnsafeMutableRawPointer` context.
///
/// Mutable state is confined to the main run loop: watch() starts on MainActor, callbacks
/// run there, and stop() retains the registration until cleanup on that same run loop.
private final class DiskWatchRegistration: @unchecked Sendable {
    private let session: DASession
    private let continuation: AsyncStream<[BlockDevice]>.Continuation
    private let bootDisks: Set<String>
    private let lockStateResolver: DeviceWatcher.LockStateResolver
    private var isActive = false
    /// Counts emissions, so a lock-state annotation that finishes after the device set changed
    /// again is dropped instead of overwriting the newer set.
    private var generation = 0

    init(session: DASession, continuation: AsyncStream<[BlockDevice]>.Continuation, bootDisks: Set<String>,
         lockStateResolver: @escaping DeviceWatcher.LockStateResolver) {
        self.bootDisks = bootDisks
        self.session = session
        self.continuation = continuation
        self.lockStateResolver = lockStateResolver
    }

    func start() {
        guard !isActive else { return }
        isActive = true

        DASessionScheduleWithRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        let context = Unmanaged.passUnretained(self).toOpaque()
        DARegisterDiskAppearedCallback(session, nil, diskAppearedTrampoline, context)
        DARegisterDiskDisappearedCallback(session, nil, diskDisappearedTrampoline, context)

        emitCurrentDevices()
    }

    func stop() {
        // `AsyncStream.Continuation.onTermination` (this method's only caller) can fire from an
        // arbitrary thread -- hop onto the main queue so every mutation here still honors this
        // type's "main-thread only" invariant (see the doc comment on this class).
        DispatchQueue.main.async { [self] in
            guard self.isActive else { return }
            self.isActive = false
            let context = Unmanaged.passUnretained(self).toOpaque()
            DAUnregisterCallback(self.session, unsafeBitCast(diskAppearedTrampoline, to: UnsafeMutableRawPointer.self), context)
            DAUnregisterCallback(self.session, unsafeBitCast(diskDisappearedTrampoline, to: UnsafeMutableRawPointer.self), context)
            DASessionUnscheduleFromRunLoop(self.session, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            self.continuation.finish()
        }
    }

    fileprivate static func handleChange(context: UnsafeMutableRawPointer?) {
        guard let context else { return }
        let registration = Unmanaged<DiskWatchRegistration>.fromOpaque(context).takeUnretainedValue()
        registration.emitCurrentDevices()
    }

    private func emitCurrentDevices() {
        guard isActive else { return }
        generation += 1
        let current = generation
        let devices = Self.enumerateDevices(session: session, bootDisks: bootDisks)
        continuation.yield(devices)
        // Story 2.4: the lock state needs a subprocess, so the plain set goes out at once and the
        // annotated full set follows (same contract: a full current set) only if anything is locked.
        guard devices.contains(where: { !$0.isBootVolume }) else { return }
        let resolver = lockStateResolver
        Task.detached { [weak self] in
            let annotated = await resolver(devices)
            guard annotated != devices else { return }
            await MainActor.run { self?.applyLockStates(annotated, generation: current) }
        }
    }

    @MainActor private func applyLockStates(_ devices: [BlockDevice], generation: Int) {
        guard isActive, generation == self.generation else { return }
        continuation.yield(devices)
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
