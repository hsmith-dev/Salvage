import Darwin
import Foundation
import SalvageCore
import SalvageDiskIO
import Testing
@testable import SalvageCLIKit

/// Captures what a command writes to stdout and stderr.
final class Capture: @unchecked Sendable {
    private let lock = NSLock()
    private var out = ""
    private var err = ""
    var stdout: String { lock.withLock { out } }
    var stderr: String { lock.withLock { err } }
    var stdoutLines: [String] { stdout.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) }
    var output: CLIOutput {
        CLIOutput(stdout: { text in self.lock.withLock { self.out += text } },
                  stderr: { text in self.lock.withLock { self.err += text } },
                  stderrIsTerminal: false)
    }
}

/// Records calls the safety rules must prevent.
final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func append(_ entry: String) { lock.withLock { stored.append(entry) } }
    var entries: [String] { lock.withLock { stored } }
}

struct TempDir {
    let url: URL
    init(_ label: String = "SalvageCLITests") throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    func remove() { try? FileManager.default.removeItem(at: url) }
    /// Every regular file under the folder, as paths relative to it.
    func allFiles() -> [String] {
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var result: [String] = []
        for case let file as URL in walker where (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            result.append(String(file.resolvingSymlinksInPath().path.dropFirst(url.resolvingSymlinksInPath().path.count + 1)))
        }
        return result.sorted()
    }
}

/// An environment that never touches a device: listing and opening are injected, and every
/// device open is logged so a test can prove a refusal happened before it.
func fakeEnvironment(devices: [BlockDevice] = [], log: CallLog = CallLog(),
                     openDevice: (@Sendable (BlockDevice) async throws -> OpenedSource)? = nil,
                     deviceVerdict: DestinationVerdict = .safe,
                     imageVerdict: DestinationVerdict? = nil) -> CLIEnvironment {
    CLIEnvironment(
        listDevices: { _ in devices },
        openDevice: { device in
            log.append("open \(device.bsdName)")
            guard let openDevice else { throw ScanError.io("no device in tests") }
            return try await openDevice(device)
        },
        openImage: { path in try CLIEnvironment.openImageFile(path) },
        deviceDestination: { url, device in
            log.append("check \(device.bsdName)")
            return DestinationAssessment(verdict: deviceVerdict, mountSource: mountSourceName(ofPath: url.path))
        },
        imageDestination: { url, image in
            guard let imageVerdict else { return ImageFileDestinationSafety.live.assess(destination: url, imageFile: image) }
            return DestinationAssessment(verdict: imageVerdict, mountSource: mountSourceName(ofPath: url.path))
        },
        now: { Date(timeIntervalSince1970: 1_800_000_000) })
}

/// Tests that need `hdiutil` fail (never silently pass) when it can't make images here, unless
/// SALVAGE_SKIP_HDIUTIL is set.
let hdiutilSkipped = ProcessInfo.processInfo.environment["SALVAGE_SKIP_HDIUTIL"] != nil

/// A small exFAT image built by the test in its own temporary folder: created, attached
/// (-nobrowse, private mount point) only while it is populated or while a test needs it mounted,
/// always detached, and deleted afterwards. The scans read the detached image *file*.
final class ExFATImage: @unchecked Sendable {
    let base: URL
    let image: URL
    let mountPoint: URL
    /// Path inside the volume -> bytes, for the files left in place.
    private(set) var live: [String: Data] = [:]
    /// Path -> bytes of the file deleted after the volume was populated.
    private(set) var deleted: [String: Data] = [:]
    private var attached = false

    init() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("SalvageCLIImage-\(UUID().uuidString)", isDirectory: true)
        image = base.appendingPathComponent("card.dmg")
        mountPoint = base.appendingPathComponent("mnt", isDirectory: true)
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        do {
            try Self.hdiutil(["create", "-size", "16m", "-type", "UDIF", "-fs", "ExFAT", "-volname", "CARD",
                              "-layout", "GPTSPUD", "-quiet", image.path])
            try attach()
            let files: [(String, Data)] = [
                ("/DCIM/IMG_0001.JPG", Self.bytes(300_000, seed: 1)),
                ("/DCIM/IMG_0002.JPG", Self.bytes(70_000, seed: 2)),
                ("/Docs/notes.txt", Data("hello salvage\n".utf8)),
                ("/Docs/Deep/report.pdf", Self.bytes(150_001, seed: 3)),
            ]
            for (path, data) in files {
                let url = mountPoint.appendingPathComponent(String(path.dropFirst()))
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url)
            }
            // Delete one file: its clusters stay as they were, so it is recoverable byte for byte.
            try FileManager.default.removeItem(at: mountPoint.appendingPathComponent("DCIM/IMG_0002.JPG"))
            for (path, data) in files {
                if path == "/DCIM/IMG_0002.JPG" { deleted[path] = data } else { live[path] = data }
            }
            try detach()
        } catch {
            try? detach()
            remove()
            throw error
        }
    }

    /// One image shared by the tests that only read it (never attached again), built on first use
    /// and deleted when the test process exits. A test that mounts an image builds its own.
    static func shared() throws -> ExFATImage {
        try sharedLock.withLock {
            if let sharedImage { return sharedImage }
            let image = try ExFATImage()
            sharedImage = image
            atexit { ExFATImage.sharedLock.withLock { ExFATImage.sharedImage?.remove() } }
            return image
        }
    }
    nonisolated(unsafe) private static var sharedImage: ExFATImage?
    private static let sharedLock = NSLock()

    func attach() throws {
        try Self.hdiutil(["attach", "-nobrowse", "-noautoopen", "-noverify", "-mountpoint", mountPoint.path, image.path])
        attached = true
    }

    func detach() throws {
        guard attached else { return }
        do { try Self.hdiutil(["detach", mountPoint.path]) } catch { try Self.hdiutil(["detach", mountPoint.path, "-force"]) }
        attached = false
    }

    func remove() {
        try? detach()
        try? FileManager.default.removeItem(at: base)
    }

    static func bytes(_ count: Int, seed: UInt64) -> Data {
        var state = seed &* 0x9E3779B97F4A7C15 | 1
        return Data((0..<count).map { _ in
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return UInt8(truncatingIfNeeded: state)
        })
    }

    static func hdiutil(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ScanError.io("hdiutil \(arguments.first ?? "") failed: \(text)") }
    }
}

/// The repository root, from this file's location.
let repositoryRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()

/// The built `salvage` executable beside the test bundle.
func salvageExecutable() -> URL? {
    var candidates: [URL] = []
    for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
        candidates.append(bundle.bundleURL.deletingLastPathComponent().appendingPathComponent("salvage"))
    }
    let build = repositoryRoot.appendingPathComponent("SalvageCLI/.build")
    candidates.append(build.appendingPathComponent("debug/salvage"))
    candidates.append(build.appendingPathComponent("release/salvage"))
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
}

/// Runs the real `salvage` binary (synchronously; call from a synchronous test).
func runSalvage(_ executable: URL, _ arguments: [String]) throws -> (status: Int32, stdout: String, stderr: String) {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    let out = Pipe(), err = Pipe()
    process.standardOutput = out; process.standardError = err
    try process.run()
    // Drain stderr on its own thread so neither pipe can fill up and stall the child.
    let group = DispatchGroup()
    let errData = LockedData()
    group.enter()
    DispatchQueue.global().async { errData.set(err.fileHandleForReading.readDataToEndOfFile()); group.leave() }
    let outData = out.fileHandleForReading.readDataToEndOfFile()
    group.wait()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: outData, as: UTF8.self), String(decoding: errData.get(), as: UTF8.self))
}

private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func set(_ new: Data) { lock.withLock { data = new } }
    func get() -> Data { lock.withLock { data } }
}
