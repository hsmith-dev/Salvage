import Darwin
import DiskArbitration
import Foundation
import IOKit
import SalvageCore

struct RawDeviceIdentity: Sendable, Equatable {
    let registryID: UInt64
    let sizeBytes: Int64
    let blockSize: Int
    let deviceNumber: dev_t
}

/// Injectable preparation operations keep safety and all failure paths testable without disks.
protocol RawDeviceOperations: Sendable {
    func protectedDisks() async throws -> Set<String>
    func identity(_ name: String) async throws -> RawDeviceIdentity
    func mountSources() async throws -> [String]
    func unmount(_ name: String) async throws
    func openReadOnly(_ name: String, expected: RawDeviceIdentity) async throws -> Int32
    func closeDescriptor(_ descriptor: Int32) async
}

public actor DeviceReadReservations {
    public static let shared = DeviceReadReservations()
    private var devices: Set<String> = []
    public init() {}
    func acquire(_ name: String) throws {
        guard devices.insert(name).inserted else { throw ScanError.deviceInUse }
    }
    func release(_ name: String) { devices.remove(name) }
    public func isReserved(_ name: String) -> Bool { devices.contains(name) }
}

public actor RawBlockReader: BlockReader {
    public nonisolated let sizeBytes: Int64
    public nonisolated let logicalBlockSize: Int
    private var descriptor: Int32?
    private let name: String
    private let reservations: DeviceReadReservations
    private let operations: any RawDeviceOperations

    private init(descriptor: Int32, name: String, identity: RawDeviceIdentity,
                 reservations: DeviceReadReservations, operations: any RawDeviceOperations) {
        self.descriptor = descriptor; self.name = name; self.sizeBytes = identity.sizeBytes
        self.logicalBlockSize = identity.blockSize; self.reservations = reservations; self.operations = operations
    }

    public static func prepare(device: BlockDevice) async throws -> RawBlockReader {
        try await prepare(device: device, operations: NativeRawDeviceOperations(), reservations: .shared)
    }

    static func prepare(device: BlockDevice, operations: any RawDeviceOperations,
                        reservations: DeviceReadReservations) async throws -> RawBlockReader {
        let name = device.bsdName
        // Same strict rule the privileged helper re-applies (HelperShared/BSDDeviceNames.swift).
        guard isWholeDiskBSDName(name) else { throw ScanError.unsafeTarget(notWholeDriveReason) }
        guard !device.isBootVolume else { throw ScanError.unsafeTarget(bootDriveReason) }
        guard device.mediaIdentity != nil else { throw ScanError.deviceChanged }
        try await reservations.acquire(name)
        do {
            try Task.checkCancellation()
            let first = try await operations.identity(name)
            guard device.mediaIdentity == first.registryID else { throw ScanError.deviceChanged }
            guard first.sizeBytes == device.sizeBytes, first.sizeBytes > 0,
                  [512, 1024, 2048, 4096].contains(first.blockSize) else { throw ScanError.deviceChanged }
            guard first.blockSize == 512 else { throw ScanError.unsafeTarget("Only devices with 512-byte logical sectors are supported in this version.") }
            try await checkProtection(name, operations: operations)
            // Revalidate after the asynchronous boot-resolution work and before unmounting.
            guard try await operations.identity(name) == first else { throw ScanError.deviceChanged }
            try Task.checkCancellation()
            // The native unmount is bounded by a timeout and honors cancellation; either throws
            // here and the catch below releases the reservation.
            try await operations.unmount(name)
            try Task.checkCancellation()
            guard try await operations.identity(name) == first else { throw ScanError.deviceChanged }
            try await checkProtection(name, operations: operations)
            try Task.checkCancellation()
            try ensureUnmounted(name, sources: await operations.mountSources())
            try Task.checkCancellation()
            let descriptor = try await operations.openReadOnly(name, expected: first)
            do {
                try Task.checkCancellation()
                guard try await operations.identity(name) == first else { throw ScanError.deviceChanged }
                return RawBlockReader(descriptor: descriptor, name: name, identity: first,
                                      reservations: reservations, operations: operations)
            } catch {
                await operations.closeDescriptor(descriptor)
                throw error
            }
        } catch {
            await reservations.release(name)
            throw error
        }
    }
    private static func checkProtection(_ name: String, operations: any RawDeviceOperations) async throws {
        let protected = try await operations.protectedDisks()
        guard !protected.isEmpty else { throw ScanError.unsafeTarget(bootUnresolvedReason) }
        guard !protected.contains(name) else { throw ScanError.unsafeTarget(bootDriveReason) }
    }
    static let bootDriveReason = "Your boot drive can't be scanned while macOS is running from it."
    static let notWholeDriveReason = "This device can't be scanned because its system name isn't a whole drive."
    static let bootUnresolvedReason = "Couldn't identify your startup drive safely. The scan was refused."

    /// Cleanup is explicit and awaited before the app starts another session.
    public func close() async {
        guard let descriptor else { return }
        self.descriptor = nil
        await operations.closeDescriptor(descriptor)
        await reservations.release(name)
    }

    deinit {
        if let descriptor {
            let operations = operations, reservations = reservations, name = name
            Task {
                await operations.closeDescriptor(descriptor)
                await reservations.release(name)
            }
        }
    }

    public func read(at offset: Int64, count: Int) async throws -> Data {
        try Task.checkCancellation()
        guard let descriptor else { throw ScanError.io("The read session is closed.") }
        guard offset >= 0, count >= 0, count <= 4 * 1024 * 1024,
              offset <= sizeBytes, Int64(count) <= sizeBytes - offset else {
            throw ScanError.io("Read outside device or supported read size.")
        }
        if count == 0 { return Data() }
        let alignment = Int64(logicalBlockSize)
        let alignedOffset = offset / alignment * alignment
        let prefix = Int(offset - alignedOffset)
        let alignedCount = (prefix + count + logicalBlockSize - 1) / logicalBlockSize * logicalBlockSize
        guard Int64(alignedCount) <= sizeBytes - alignedOffset else { throw ScanError.io("Truncated device sector.") }
        var buffer: UnsafeMutableRawPointer?
        guard posix_memalign(&buffer, logicalBlockSize, alignedCount) == 0, let buffer else { throw ScanError.io("Couldn't allocate a read buffer.") }
        defer { free(buffer) }
        var consumed = 0
        while consumed < alignedCount {
            try Task.checkCancellation()
            let result = pread(descriptor, buffer.advanced(by: consumed), alignedCount - consumed, alignedOffset + Int64(consumed))
            if result < 0 {
                if errno == EINTR { continue }
                if errno == EPERM || errno == EACCES { throw ScanError.permissionDenied }
                if errno == ENXIO || errno == ENODEV { throw ScanError.deviceChanged }
                throw ScanError.io(String(cString: strerror(errno)))
            }
            guard result > 0, result % logicalBlockSize == 0 else { throw ScanError.io("Short raw-device read.") }
            consumed += result
        }
        try Task.checkCancellation()
        return Data(bytes: buffer.advanced(by: prefix), count: count)
    }
}

/// Outcome of the unprivileged `open(2)` attempt.
enum DirectOpenResult: Sendable, Equatable { case opened(Int32), failed(errno: Int32) }

/// AD-13 fallback: open the raw node directly first, which is all a user-owned device (an
/// attached disk image, a test fixture) needs. Only EACCES/EPERM -- the `root:operator 0640`
/// ownership of physical drives -- goes to the privileged helper. Either way the descriptor is
/// then checked with `validateRawDescriptor`, so a helper fd is never trusted blindly.
func openRawDevice(_ name: String, expected: RawDeviceIdentity, directOpen: (String) -> DirectOpenResult,
                   helper: any PrivilegedOpening) async throws -> Int32 {
    guard isWholeDiskBSDName(name) else { throw ScanError.unsafeTarget(RawBlockReader.notWholeDriveReason) }
    let descriptor: Int32
    switch directOpen("/dev/r\(name)") {
    case .opened(let fd):
        descriptor = fd
    case .failed(let code) where code == EACCES || code == EPERM:
        descriptor = try await helper.openWholeDiskReadOnly(
            PrivilegedOpenRequest(bsdName: name, registryID: expected.registryID, deviceNumber: expected.deviceNumber))
    case .failed(let code):
        throw ScanError.io(String(cString: strerror(code)))
    }
    try validateRawDescriptor(descriptor, expected: expected)
    return descriptor
}

/// The fd must be a character device with the expected device number; it is then switched to
/// uncached reads. On any mismatch the fd is closed and the device treated as changed.
func validateRawDescriptor(_ descriptor: Int32, expected: RawDeviceIdentity) throws {
    var node = stat()
    guard fstat(descriptor, &node) == 0,
          isExpectedCharacterDevice(mode: node.st_mode, rdev: node.st_rdev, expected: expected.deviceNumber),
          fcntl(descriptor, F_NOCACHE, 1) == 0 else {
        Darwin.close(descriptor); throw ScanError.deviceChanged
    }
}

private actor NativeRawDeviceOperations: RawDeviceOperations {
    private let helper: any PrivilegedOpening
    init(helper: any PrivilegedOpening = PrivilegedOpenClient.live) { self.helper = helper }

    func protectedDisks() async throws -> Set<String> {
        guard case .success(let disks) = resolveBootDisks(), !disks.isEmpty else {
            throw ScanError.unsafeTarget(RawBlockReader.bootUnresolvedReason)
        }
        return disks
    }
    func identity(_ name: String) async throws -> RawDeviceIdentity {
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, name),
              let description = DADiskCopyDescription(disk) as? [String: Any],
              description[kDADiskDescriptionMediaWholeKey as String] as? Bool == true,
              let size = description[kDADiskDescriptionMediaSizeKey as String] as? NSNumber,
              let block = description[kDADiskDescriptionMediaBlockSizeKey as String] as? NSNumber else { throw ScanError.deviceChanged }
        let media = DADiskCopyIOMedia(disk)
        guard media != 0 else { throw ScanError.deviceChanged }
        defer { IOObjectRelease(media) }
        var registryID: UInt64 = 0, node = stat()
        guard IORegistryEntryGetRegistryEntryID(media, &registryID) == KERN_SUCCESS,
              lstat("/dev/r\(name)", &node) == 0, node.st_mode & S_IFMT == S_IFCHR else { throw ScanError.deviceChanged }
        return RawDeviceIdentity(registryID: registryID, sizeBytes: size.int64Value,
                                 blockSize: block.intValue, deviceNumber: node.st_rdev)
    }
    func mountSources() async throws -> [String] { try ownedMountSources() }
    func unmount(_ name: String) async throws {
        try await unmountOnMain(name)
    }
    @MainActor private func unmountOnMain(_ name: String) async throws {
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, name) else { throw ScanError.deviceChanged }
        DASessionSetDispatchQueue(session, .main)
        defer { DASessionSetDispatchQueue(session, nil) }
        let completion = OneShotCompletion()
        try await completion.wait(timeout: .seconds(30), timeoutError: ScanError.io("Unmounting the device took too long. Close files on it and retry.")) {
            // The callback owns one retain of `completion`, released when (if ever) it fires, so a
            // callback arriving after a timeout or cancellation still finds a live object; the
            // one-shot guard makes that late result a no-op.
            DADiskUnmount(disk, DADiskUnmountOptions(kDADiskUnmountOptionWhole), { _, dissenter, pointer in
                guard let pointer else { return }
                let completion = Unmanaged<OneShotCompletion>.fromOpaque(pointer).takeRetainedValue()
                if let dissenter {
                    let reason = DADissenterGetStatusString(dissenter).map { $0 as String } ?? "The device is busy. Close files on it and retry."
                    completion.finish(.failure(ScanError.io(reason)))
                } else { completion.finish(.success(())) }
            }, Unmanaged.passRetained(completion).toOpaque())
        }
    }
    func openReadOnly(_ name: String, expected: RawDeviceIdentity) async throws -> Int32 {
        // No suspension between final identity validation and the direct open on this actor.
        // The helper path does suspend; the helper re-checks registry ID, device number, boot
        // refusal and mount state itself, and `prepare` re-validates identity after the open.
        guard try await identity(name) == expected else { throw ScanError.deviceChanged }
        try ensureUnmounted(name, sources: ownedMountSources())
        return try await openRawDevice(name, expected: expected, directOpen: { path in
            let fd = Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            return fd >= 0 ? .opened(fd) : .failed(errno: errno)
        }, helper: helper)
    }
    func closeDescriptor(_ descriptor: Int32) async { Darwin.close(descriptor) }
}

/// Bridges a one-shot OS callback into async/await with a deadline and cancellation. The first
/// of callback, timeout or cancellation decides the result; the continuation resumes exactly once.
final class OneShotCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, any Error>?
    private var outcome: Result<Void, any Error>?

    /// Records the first result only; later results (e.g. a late OS callback) are ignored.
    func finish(_ result: Result<Void, any Error>) {
        let waiting: CheckedContinuation<Void, any Error>? = lock.withLock {
            guard outcome == nil else { return nil }
            outcome = result
            defer { continuation = nil }
            return continuation
        }
        waiting?.resume(with: result)
    }

    var isFinished: Bool { lock.withLock { outcome != nil } }

    /// `start` runs synchronously once the continuation is installed, unless the wait was already
    /// cancelled, in which case the operation is never started.
    func wait(timeout: Duration, timeoutError: any Error,
              isolation: isolated (any Actor)? = #isolation, start: () -> Void) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { [self] in
                do { try await Task.sleep(for: timeout) } catch { return }
                finish(.failure(timeoutError))
            }
            defer { group.cancelAll() }
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    let decided: Result<Void, any Error>? = lock.withLock {
                        if outcome == nil { self.continuation = continuation }
                        return outcome
                    }
                    if let decided { continuation.resume(with: decided) } else { start() }
                }
            } onCancel: {
                finish(.failure(CancellationError()))
            }
        }
    }
}

/// The production and injected paths share this refusal rule.
func ensureUnmounted(_ name: String, sources: [String]) throws {
    if isMounted(name, sources: sources) {
        throw ScanError.io("The device was mounted again. Close files on it and retry.")
    }
}

/// getfsstat writes caller-owned storage (see HelperShared/PrivilegedDiskQueries.swift).
private func ownedMountSources() throws -> [String] {
    guard let sources = mountSourcesSnapshot() else { throw ScanError.io("Couldn't verify the device is unmounted.") }
    return sources
}
