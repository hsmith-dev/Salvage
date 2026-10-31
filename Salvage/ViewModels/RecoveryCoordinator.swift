import CryptoKit
import Darwin
import Foundation
import Observation
import SalvageCore
import SalvageDiskIO

// MARK: - Results

/// One file that reached the destination intact.
struct RecoveredCopy: Sendable, Equatable {
    let sourcePath: String
    let url: URL
    let bytes: Int64
    /// Lowercase hex SHA-256 of exactly the bytes written, computed while streaming.
    let sha256: String
}

/// One file that couldn't be recovered, and why.
struct RecoveryFailureRecord: Sendable, Equatable, Identifiable {
    let id: UUID
    let name: String
    let sourcePath: String
    let reason: String
}

struct RecoverySummary: Sendable, Equatable {
    /// The "Salvage Recovery <device> <date>" folder everything was written under.
    let root: URL
    let selectedCount: Int
    let written: [RecoveredCopy]
    let failed: [RecoveryFailureRecord]
    /// Files never finished because the user cancelled (including the one in progress).
    let notAttempted: Int
    let cancelled: Bool
    var bytesWritten: Int64 { written.reduce(0) { $0 + $1.bytes } }
}

struct RecoveryProgress: Sendable, Equatable {
    var filesFinished: Int
    var bytesDone: Int64
    var currentName: String?
}

enum RecoveryStartError: Error, Sendable, Equatable {
    case destinationUnsafe
    case destinationUnavailable(String)
}

// MARK: - Path safety

enum RecoveryPaths {
    /// Bytes of UTF-8 a sanitized component may use, leaving room under NAME_MAX (255) for a
    /// collision suffix and the temporary `.partial` name.
    static let maxComponentBytes = 200

    /// Makes one name or path component safe to create: removes NUL, `/`, `:` and other C0
    /// control characters, strips leading dots, and maps an empty, `.` or `..` result to `_`.
    static func sanitize(_ component: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in component.unicodeScalars where scalar != "/" && scalar != ":" && scalar.value >= 0x20 && scalar.value != 0x7F {
            scalars.append(scalar)
        }
        var name = String(scalars)
        while name.hasPrefix(".") { name.removeFirst() }
        if name.isEmpty || name == "." || name == ".." { return "_" }
        return truncate(name, keepingExtension: true)
    }

    /// The sanitized folder components of `file.path` (the file's own name excluded).
    static func folderComponents(of file: RecoveredFile) -> [String] {
        var parts = file.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if parts.last == file.name || (!parts.isEmpty && parts.last.map(sanitize) == sanitize(file.name)) {
            parts.removeLast()
        }
        return parts.map(sanitize)
    }

    /// `name` for attempt 1, then "stem (2).ext", "stem (3).ext", ... for files; directories get
    /// the suffix appended to the whole name.
    static func candidate(_ name: String, attempt: Int, isDirectory: Bool) -> String {
        guard attempt > 1 else { return name }
        let ns = name as NSString
        let ext = isDirectory ? "" : ns.pathExtension
        let stem = ext.isEmpty ? name : ns.deletingPathExtension
        return ext.isEmpty ? "\(stem) (\(attempt))" : "\(stem) (\(attempt)).\(ext)"
    }

    private static func truncate(_ name: String, keepingExtension: Bool) -> String {
        guard name.utf8.count > maxComponentBytes else { return name }
        let ns = name as NSString
        let ext = ns.pathExtension
        let keepExt = keepingExtension && !ext.isEmpty && ext.utf8.count <= 20
        var stem = keepExt ? ns.deletingPathExtension : name
        let budget = maxComponentBytes - (keepExt ? ext.utf8.count + 1 : 0)
        while stem.utf8.count > budget { stem.removeLast() }
        if stem.isEmpty { stem = "_" }
        return keepExt ? "\(stem).\(ext)" : stem
    }
}

// MARK: - Engine

/// Copies files from the source into a fresh root folder under the destination, one at a time.
/// Every directory and file is created relative to an open directory descriptor with
/// `O_NOFOLLOW`, so no component can redirect a write through a symlink, and each target folder's
/// real path is confirmed to sit inside the root before anything is written there.
struct RecoveryEngine: Sendable {
    let content: FileContentReader

    func run(files: [RecoveredFile], rootName: String, in destination: URL,
             progress: @Sendable (RecoveryProgress) -> Void) async -> Result<RecoverySummary, RecoveryStartError> {
        let destinationPath = destination.resolvingSymlinksInPath().path
        let destinationFD = open(destinationPath, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard destinationFD >= 0 else { return .failure(.destinationUnavailable(Self.describe(errno: errno))) }
        defer { close(destinationFD) }

        let rootFD: Int32
        switch Self.makeDirectory(in: destinationFD, named: RecoveryPaths.sanitize(rootName), reuseExisting: false) {
        case .success(let made): rootFD = made.0
        case .failure(let error): return .failure(.destinationUnavailable(Self.describe(errno: error.code)))
        }
        defer { close(rootFD) }
        guard let rootReal = Self.realPath(of: rootFD) else {
            return .failure(.destinationUnavailable("Couldn't open the recovery folder."))
        }
        let rootURL = URL(fileURLWithPath: rootReal, isDirectory: true)

        var directoryNames: [String: String] = [:]  // logical relative folder path -> actual name
        var written: [RecoveredCopy] = []
        var failed: [RecoveryFailureRecord] = []
        var state = RecoveryProgress(filesFinished: 0, bytesDone: 0, currentName: nil)
        var cancelled = false

        for file in files {
            if Task.isCancelled { cancelled = true; break }
            state.currentName = file.name
            progress(state)
            let baseBytes = state.bytesDone
            let outcome = await copy(file, rootFD: rootFD, rootReal: rootReal, directoryNames: &directoryNames) { done in
                var update = state
                update.bytesDone = baseBytes + done
                progress(update)
            }
            switch outcome {
            case .success(let copy):
                written.append(copy)
                state.bytesDone = baseBytes + copy.bytes
            case .failure(.cancelled):
                state.bytesDone = baseBytes
                cancelled = true
            case .failure(let failure):
                state.bytesDone = baseBytes
                failed.append(RecoveryFailureRecord(id: file.id, name: file.name, sourcePath: file.path, reason: failure.reason))
            }
            if cancelled { break }
            state.filesFinished += 1
            progress(state)
        }
        state.currentName = nil
        progress(state)
        let notAttempted = files.count - written.count - failed.count
        return .success(RecoverySummary(root: rootURL, selectedCount: files.count, written: written, failed: failed,
                                        notAttempted: notAttempted, cancelled: cancelled))
    }

    // MARK: One file

    enum CopyFailure: Error, Equatable {
        case cancelled
        case unmapped
        case damagedMapping
        case sourceRead
        case shortSource
        case outsideRoot
        case destination(Int32)

        var reason: String {
            switch self {
            case .cancelled: "Cancelled."
            case .unmapped: "Salvage couldn't locate this file's contents on the drive."
            case .damagedMapping: "This file's location on the drive is incomplete or damaged."
            case .sourceRead: "Couldn't read this file from the drive."
            case .shortSource: "The drive returned less data than the file's size."
            case .outsideRoot: "Its folder path points outside the recovery folder, so it was skipped."
            case .destination(let code): RecoveryEngine.describe(errno: code)
            }
        }
    }

    private func copy(_ file: RecoveredFile, rootFD: Int32, rootReal: String, directoryNames: inout [String: String],
                      progress: (Int64) -> Void) async -> Result<RecoveredCopy, CopyFailure> {
        do { try content.validate(file) } catch let error as FileContentError {
            return .failure(error == .unmapped ? .unmapped : .damagedMapping)
        } catch { return .failure(.damagedMapping) }

        // Open (creating as needed) each folder level below the root.
        var dirFD = dup(rootFD)
        guard dirFD >= 0 else { return .failure(.destination(errno)) }
        defer { close(dirFD) }
        var logical = ""
        for component in RecoveryPaths.folderComponents(of: file) {
            logical += "/" + component
            let made: Result<(Int32, String), Errno>
            if let known = directoryNames[logical] {
                made = Self.makeDirectory(in: dirFD, named: known, reuseExisting: true, fixedName: true)
            } else {
                made = Self.makeDirectory(in: dirFD, named: component, reuseExisting: true)
            }
            switch made {
            case .success(let (fd, actual)):
                close(dirFD); dirFD = fd
                directoryNames[logical] = actual
            case .failure(let error): return .failure(.destination(error.code))
            }
        }
        guard let dirReal = Self.realPath(of: dirFD), dirReal == rootReal || dirReal.hasPrefix(rootReal + "/") else {
            return .failure(.outsideRoot)
        }

        let finalName = RecoveryPaths.sanitize(file.name)
        let partialName = "\(finalName.prefix(40)).\(UUID().uuidString.prefix(8)).partial"
        let fd = openat(dirFD, partialName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return .failure(.destination(errno)) }
        var fdOpen = true
        func discard() {
            if fdOpen { close(fd); fdOpen = false }
            _ = unlinkat(dirFD, partialName, 0)
        }

        var hasher = SHA256()
        var total: Int64 = 0
        do {
            for try await chunk in content.chunks(of: file) {
                if Task.isCancelled { throw CancellationError() }
                if let code = Self.writeAll(chunk, to: fd) { discard(); return .failure(.destination(code)) }
                hasher.update(data: chunk)
                total += Int64(chunk.count)
                progress(total)
            }
        } catch is CancellationError {
            discard(); return .failure(.cancelled)
        } catch let error as FileContentError {
            discard(); return .failure(error == .unmapped ? .unmapped : .damagedMapping)
        } catch {
            discard(); return .failure(Task.isCancelled ? .cancelled : .sourceRead)
        }
        if Task.isCancelled { discard(); return .failure(.cancelled) }
        guard total == file.sizeBytes else { discard(); return .failure(.shortSource) }

        if let modified = file.modified {
            let seconds = modified.timeIntervalSince1970.rounded(.down)
            let nanos = Int((modified.timeIntervalSince1970 - seconds) * 1_000_000_000)
            var times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)),
                         timespec(tv_sec: Int(seconds), tv_nsec: max(0, min(nanos, 999_999_999)))]
            if futimens(fd, &times) != 0 { let code = errno; discard(); return .failure(.destination(code)) }
        }
        if fsync(fd) != 0 { let code = errno; discard(); return .failure(.destination(code)) }
        close(fd); fdOpen = false

        // Atomic, never-overwriting publish: RENAME_EXCL fails with EEXIST instead of replacing.
        var attempt = 1
        while true {
            let name = RecoveryPaths.candidate(finalName, attempt: attempt, isDirectory: false)
            if renameatx_np(dirFD, partialName, dirFD, name, UInt32(RENAME_EXCL)) == 0 {
                _ = fsync(dirFD)
                let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                let url = URL(fileURLWithPath: dirReal, isDirectory: true).appendingPathComponent(name, isDirectory: false)
                return .success(RecoveredCopy(sourcePath: file.path, url: url, bytes: total, sha256: digest))
            }
            let code = errno
            guard code == EEXIST, attempt < 10_000 else { discard(); return .failure(.destination(code)) }
            attempt += 1
        }
    }

    // MARK: POSIX helpers

    struct Errno: Error, Equatable { let code: Int32 }

    /// Creates (or, with `reuseExisting`, opens an existing real directory) under `parent`,
    /// adding " (2)"-style suffixes when the name is taken by something else. Never follows a
    /// symlink. Returns the open descriptor and the actual name used.
    static func makeDirectory(in parent: Int32, named name: String, reuseExisting: Bool,
                              fixedName: Bool = false) -> Result<(Int32, String), Errno> {
        var attempt = 1
        while attempt <= 10_000 {
            let candidate = fixedName ? name : RecoveryPaths.candidate(name, attempt: attempt, isDirectory: true)
            let made = mkdirat(parent, candidate, 0o755) == 0
            if !made {
                let code = errno
                guard code == EEXIST else { return .failure(Errno(code: code)) }
                if !reuseExisting { if fixedName { return .failure(Errno(code: code)) }; attempt += 1; continue }
            }
            let fd = openat(parent, candidate, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if fd >= 0 { return .success((fd, candidate)) }
            let code = errno
            // Taken by a file or a symlink: try the next suffix rather than writing through it.
            guard !fixedName, code == ENOTDIR || code == ELOOP else { return .failure(Errno(code: code)) }
            attempt += 1
        }
        return .failure(Errno(code: EEXIST))
    }

    static func realPath(of fd: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &buffer) != -1 else { return nil }
        let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return path.isEmpty ? nil : path
    }

    /// Writes every byte, retrying short writes and EINTR. Returns the errno on failure.
    static func writeAll(_ data: Data, to fd: Int32) -> Int32? {
        data.withUnsafeBytes { raw -> Int32? in
            guard var pointer = raw.baseAddress else { return nil }
            var remaining = raw.count
            while remaining > 0 {
                let n = write(fd, pointer, remaining)
                if n < 0 { if errno == EINTR { continue }; return errno }
                if n == 0 { return EIO }
                remaining -= n; pointer += n
            }
            return nil
        }
    }

    static func describe(errno code: Int32) -> String {
        switch code {
        case ENOSPC, EDQUOT: "The destination is full."
        case EACCES, EPERM: "Salvage doesn't have permission to write to the destination."
        case EROFS: "The destination is read-only."
        case ENAMETOOLONG: "The file's name or folder path is too long for the destination."
        case ENOENT, ENXIO, ENODEV: "The destination is no longer available."
        default: "Couldn't write to the destination (\(String(cString: strerror(code))))."
        }
    }
}

// MARK: - Coordinator

/// Drives one recovery: destination choice and safety check, the copy run, progress, cancel, and
/// the final summary. The destination is checked when chosen and again just before writing.
@MainActor @Observable
final class RecoveryCoordinator {
    enum Phase: Equatable {
        case ready, running
        case finished(RecoverySummary)
        case failedToStart(String)
    }
    enum DestinationStatus: Equatable { case none, checking, safe, blocked }

    static let blockedMessage = "This folder is on the drive you're recovering from. Choose a folder on a different drive."

    let files: [RecoveredFile]
    let totalBytes: Int64
    private(set) var phase: Phase = .ready
    private(set) var destination: URL?
    private(set) var destinationStatus: DestinationStatus = .none
    private(set) var progress = RecoveryProgress(filesFinished: 0, bytesDone: 0, currentName: nil)

    private let engine: RecoveryEngine
    private let deviceName: String
    private let now: @Sendable () -> Date
    private let destinationCheck: @Sendable (URL) -> DestinationVerdict
    private var task: Task<Void, Never>?
    private var checkGeneration = 0

    init(files: [RecoveredFile], content: FileContentReader, deviceName: String,
         now: @escaping @Sendable () -> Date = { Date() },
         destinationCheck: @escaping @Sendable (URL) -> DestinationVerdict) {
        self.files = files
        self.totalBytes = files.reduce(0) { $0 + max(0, $1.sizeBytes) }
        self.engine = RecoveryEngine(content: content)
        self.deviceName = deviceName
        self.now = now
        self.destinationCheck = destinationCheck
    }

    convenience init(files: [RecoveredFile], source: SourceSession) {
        let device = source.device
        self.init(files: files, content: source.content, deviceName: device.displayName,
                  destinationCheck: { DestinationSafety.live.check(destination: $0, source: device) })
    }

    var canRecover: Bool { phase == .ready && destinationStatus == .safe && !files.isEmpty }

    /// Records the chosen folder and checks it off the main thread.
    func chooseDestination(_ url: URL) async {
        guard phase == .ready else { return }
        checkGeneration += 1
        let generation = checkGeneration
        destination = url
        destinationStatus = .checking
        let check = destinationCheck
        let verdict = await Task.detached { check(url) }.value
        guard generation == checkGeneration else { return }
        destinationStatus = verdict.isSafe ? .safe : .blocked
    }

    func start() {
        guard canRecover, let destination else { return }
        phase = .running
        let files = self.files, engine = self.engine, check = self.destinationCheck
        let rootName = Self.rootFolderName(device: deviceName, date: now())
        task = Task { [weak self] in
            // Re-check right before writing: the volume under the chosen path may have changed.
            let verdict = await Task.detached { check(destination) }.value
            if Task.isCancelled { self?.phase = .ready; return }
            guard verdict.isSafe else {
                self?.destinationStatus = .blocked
                self?.phase = .ready
                return
            }
            let (stream, continuation) = AsyncStream<RecoveryProgress>.makeStream(bufferingPolicy: .bufferingNewest(1))
            async let result = Self.runEngine(engine, files: files, rootName: rootName, destination: destination,
                                              continuation: continuation)
            for await update in stream { self?.progress = update }
            switch await result {
            case .success(let summary): self?.phase = .finished(summary)
            case .failure(.destinationUnsafe): self?.phase = .failedToStart(Self.blockedMessage)
            case .failure(.destinationUnavailable(let reason)): self?.phase = .failedToStart(reason)
            }
        }
    }

    func cancel() { task?.cancel() }

    /// Waits for the current run to end (tests).
    func waitUntilFinished() async { await task?.value }

    nonisolated private static func runEngine(_ engine: RecoveryEngine, files: [RecoveredFile], rootName: String,
                                              destination: URL, continuation: AsyncStream<RecoveryProgress>.Continuation)
        async -> Result<RecoverySummary, RecoveryStartError> {
        defer { continuation.finish() }
        return await engine.run(files: files, rootName: rootName, in: destination) { continuation.yield($0) }
    }

    nonisolated static func rootFolderName(device: String, date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let label = device.trimmingCharacters(in: .whitespacesAndNewlines)
        return "Salvage Recovery \(label.isEmpty ? "Drive" : label) \(formatter.string(from: date))"
    }
}
