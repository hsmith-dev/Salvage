import Darwin
import Foundation
import SalvageCore
import SalvageDiskIO

/// Where the tool writes. Results go to `stdout`, progress and messages to `stderr`.
public struct CLIOutput: Sendable {
    public var stdout: @Sendable (String) -> Void
    public var stderr: @Sendable (String) -> Void
    /// Whether stderr is a terminal: progress then redraws one line instead of printing many.
    public var stderrIsTerminal: Bool

    public init(stdout: @escaping @Sendable (String) -> Void, stderr: @escaping @Sendable (String) -> Void,
                stderrIsTerminal: Bool) {
        self.stdout = stdout; self.stderr = stderr; self.stderrIsTerminal = stderrIsTerminal
    }

    public static let standard = CLIOutput(
        stdout: { text in FileHandle.standardOutput.write(Data(text.utf8)) },
        stderr: { text in FileHandle.standardError.write(Data(text.utf8)) },
        stderrIsTerminal: isatty(STDERR_FILENO) == 1)

    func line(_ text: String) { stdout(text + "\n") }
    func message(_ text: String) { stderr(text + "\n") }
}

/// A source opened for reading, and how to release it.
struct OpenedSource: Sendable {
    let reader: any BlockReader
    /// The drive's name, or the image's file name: names the recovery folder.
    let displayName: String
    /// The drive, for a device source (passed to the scan, as the app does); nil for an image.
    let device: BlockDevice?
    let close: @Sendable () async -> Void
}

/// Everything the commands do to the outside world, injectable so tests never touch a real
/// device: listing drives, opening one, and the two destination-safety checks.
struct CLIEnvironment: Sendable {
    /// The device tree, as the app's Device Picker gets it. `waitForLockState` lets the FileVault
    /// "Locked" annotation arrive (it needs a `diskutil` listing).
    var listDevices: @Sendable (_ waitForLockState: Bool) async throws -> [BlockDevice]
    /// Opens a whole drive read-only. Live: `RawBlockReader.prepare`, which refuses the startup
    /// disk, unmounts the drive's volumes, opens it O_RDONLY (falling back to the privileged
    /// helper only on a permission error) and validates the descriptor.
    var openDevice: @Sendable (BlockDevice) async throws -> OpenedSource
    var openImage: @Sendable (String) throws -> OpenedSource
    var deviceDestination: @Sendable (URL, BlockDevice) -> DestinationAssessment
    var imageDestination: @Sendable (URL, URL) -> DestinationAssessment
    var now: @Sendable () -> Date

    static let live = CLIEnvironment(
        listDevices: { wait in try await liveDevices(waitForLockState: wait) },
        openDevice: { device in
            let reader = try await RawBlockReader.prepare(device: device)
            return OpenedSource(reader: reader, displayName: device.displayName, device: device,
                                close: { await reader.close() })
        },
        openImage: { path in try openImageFile(path) },
        deviceDestination: { url, device in DestinationSafety.live.assess(destination: url, source: device) },
        imageDestination: { url, image in ImageFileDestinationSafety.live.assess(destination: url, imageFile: image) },
        now: { Date() })

    static func openImageFile(_ path: String) throws -> OpenedSource {
        let reader = try ImageFileReader(path: path)
        return OpenedSource(reader: reader, displayName: (path as NSString).lastPathComponent, device: nil,
                            close: { reader.close() })
    }

    /// The watcher publishes the current set at once; with `waitForLockState`, a second set (the
    /// lock-state annotation) is awaited for a short while.
    static func liveDevices(waitForLockState: Bool) async throws -> [BlockDevice] {
        let stream = try await DeviceWatcher().watch()
        let latest = LatestDevices()
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await set in stream {
                    if latest.store(set) >= (waitForLockState ? 2 : 1) { break }
                }
            }
            if waitForLockState {
                group.addTask {
                    // The first set is immediate; give the annotation a moment after it.
                    while latest.count == 0, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(20)) }
                    try? await Task.sleep(for: .milliseconds(1500))
                }
            }
            await group.next()
            group.cancelAll()
        }
        return latest.devices ?? []
    }
}

private final class LatestDevices: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [BlockDevice]?
    private var received = 0
    func store(_ set: [BlockDevice]) -> Int { lock.withLock { stored = set; received += 1; return received } }
    var count: Int { lock.withLock { received } }
    var devices: [BlockDevice]? { lock.withLock { stored } }
}
