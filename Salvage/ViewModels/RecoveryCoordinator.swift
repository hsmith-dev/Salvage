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
    /// UTF-8 bytes of the file name kept in its temporary `.partial` name.
    static let partialStemBytes = 40

    /// Makes one name or path component safe to create: removes NUL, `/`, `:` and other C0
    /// control characters, strips leading dots together with any leading combining marks and
    /// invisible (format / default-ignorable) characters -- working on Unicode scalars, so a dot
    /// followed by a combining mark can't hide from the check -- and maps an empty result to `_`.
    static func sanitize(_ component: String) -> String {
        var scalars: [Unicode.Scalar] = component.unicodeScalars.filter {
            $0 != "/" && $0 != ":" && $0.value >= 0x20 && $0.value != 0x7F
        }
        while let first = scalars.first, first == "." || isInvisibleLeader(first) { scalars.removeFirst() }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        let name = String(view)
        if name.isEmpty || name == "." || name == ".." { return "_" }
        return truncate(name, keepingExtension: true)
    }

    private static func isInvisibleLeader(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark, .format: return true
        default: return scalar.properties.isDefaultIgnorableCodePoint
        }
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

    /// The temporary name a file is streamed into: at most `partialStemBytes` of its name (cut on
    /// a scalar boundary), a random tag and `.partial`.
    static func partialName(for finalName: String) -> String {
        var stem = String.UnicodeScalarView()
        var bytes = 0
        for scalar in finalName.unicodeScalars {
            let size = String(scalar).utf8.count
            guard bytes + size <= partialStemBytes else { break }
            stem.append(scalar); bytes += size
        }
        return "\(String(stem)).\(UUID().uuidString.prefix(8)).partial"
    }

    /// Whether an absolute path stays under the OS path limit (PATH_MAX bytes including the NUL).
    static func fitsPathLimit(_ path: String) -> Bool { path.utf8.count < Int(PATH_MAX) }

    /// `base` + "/" + each component, without touching the file system.
    static func join(_ base: String, _ components: [String]) -> String {
        components.reduce(base) { $0.utf8.last == UInt8(ascii: "/") ? $0 + $1 : $0 + "/" + $1 }
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
/// `O_NOFOLLOW`, so no component can redirect a write through a symlink, and each target folder
/// is confirmed to sit inside the root -- by walking its `..` chain and comparing
/// `(st_dev, st_ino)` with the root's, which needs no path strings -- before anything is written.
struct RecoveryEngine: Sendable {
    let content: FileContentReader
    /// Flushes a file to stable storage before it is published; returns an errno on failure.
    var sync: @Sendable (Int32) -> Int32? = { RecoveryEngine.durableSync($0) }
    var publishOps = PublishOps.live

    func run(files: [RecoveredFile], rootName: String, in destination: URL, checked: DestinationAssessment,
             progress: @Sendable (RecoveryProgress) -> Void) async -> Result<RecoverySummary, RecoveryStartError> {
        let destinationPath = destination.resolvingSymlinksInPath().path
        let destinationFD = open(destinationPath, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard destinationFD >= 0 else { return .failure(.destinationUnavailable(Self.describe(errno: errno))) }
        defer { close(destinationFD) }
        // The folder actually opened must be on the volume that was checked; a volume mounted
        // over the path (or a swapped symlink) since the check means the verdict doesn't apply.
        guard checked.covers(openedMountSource: mountSourceName(ofDescriptor: destinationFD)) else {
            return .failure(.destinationUnsafe)
        }

        let rootFD: Int32, rootActual: String
        switch Self.makeDirectory(in: destinationFD, named: RecoveryPaths.sanitize(rootName), reuseExisting: false) {
        case .success(let made): (rootFD, rootActual) = made
        case .failure(let error): return .failure(.destinationUnavailable(Self.describe(errno: error.code)))
        }
        defer { close(rootFD) }
        guard let rootID = FileID(fd: rootFD) else {
            return .failure(.destinationUnavailable("Couldn't open the recovery folder."))
        }
        let rootPath = RecoveryPaths.join(destinationPath, [rootActual])
        let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)

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
            let root = Root(fd: rootFD, id: rootID, path: rootPath)
            let outcome = await copy(file, root: root, directoryNames: &directoryNames) { done in
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

    struct Root {
        let fd: Int32
        let id: FileID
        let path: String
    }

    private func copy(_ file: RecoveredFile, root: Root, directoryNames: inout [String: String],
                      progress: (Int64) -> Void) async -> Result<RecoveredCopy, CopyFailure> {
        do { try content.validate(file) } catch let error as FileContentError {
            return .failure(error == .unmapped ? .unmapped : .damagedMapping)
        } catch { return .failure(.damagedMapping) }

        let components = RecoveryPaths.folderComponents(of: file)
        let finalName = RecoveryPaths.sanitize(file.name)
        // Refuse up front (before creating any folder) a path the OS can't name as a whole.
        guard RecoveryPaths.fitsPathLimit(RecoveryPaths.join(root.path, components + [finalName])) else {
            return .failure(.destination(ENAMETOOLONG))
        }

        // Open (creating as needed) each folder level below the root.
        var dirFD = dup(root.fd)
        guard dirFD >= 0 else { return .failure(.destination(errno)) }
        defer { close(dirFD) }
        var logical = ""
        var actualComponents: [String] = []
        for component in components {
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
                actualComponents.append(actual)
            case .failure(let error): return .failure(.destination(error.code))
            }
        }
        guard Self.isInside(dirFD, root: root.id, maxLevels: components.count) else { return .failure(.outsideRoot) }
        let dirPath = RecoveryPaths.join(root.path, actualComponents)

        let partialName = RecoveryPaths.partialName(for: finalName)
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
        if let code = sync(fd) { discard(); return .failure(.destination(code)) }
        close(fd); fdOpen = false

        switch Self.publish(partialName, as: finalName, in: dirFD, ops: publishOps,
                            fits: { RecoveryPaths.fitsPathLimit(RecoveryPaths.join(dirPath, [$0])) }) {
        case .success(let name):
            _ = fsync(dirFD)
            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            let url = URL(fileURLWithPath: dirPath, isDirectory: true).appendingPathComponent(name, isDirectory: false)
            return .success(RecoveredCopy(sourcePath: file.path, url: url, bytes: total, sha256: digest))
        case .failure(let error):
            discard(); return .failure(.destination(error.code))
        }
    }

    // MARK: Publishing

    /// The directory-entry primitives `publish` uses; injectable so each fallback can be tested
    /// on any file system. Each returns 0 or an errno.
    struct PublishOps: Sendable {
        var renameExclusive: @Sendable (Int32, String, String) -> Int32
        var link: @Sendable (Int32, String, String) -> Int32
        var createExclusive: @Sendable (Int32, String) -> Int32
        var rename: @Sendable (Int32, String, String) -> Int32

        static let live = PublishOps(
            renameExclusive: { dir, from, to in renameatx_np(dir, from, dir, to, UInt32(RENAME_EXCL)) == 0 ? 0 : errno },
            link: { dir, from, to in linkat(dir, from, dir, to, 0) == 0 ? 0 : errno },
            createExclusive: { dir, name in
                let fd = openat(dir, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
                guard fd >= 0 else { return errno }
                close(fd); return 0
            },
            rename: { dir, from, to in renameat(dir, from, dir, to) == 0 ? 0 : errno }
        )
    }

    /// Gives the finished `.partial` file its final name without ever replacing an existing file,
    /// trying " (2)"-style names on `EEXIST`. Strategies, in order of preference:
    ///
    /// 1. `renameatx_np(RENAME_EXCL)`: atomic and no-overwrite (APFS, HFS+, most local volumes).
    /// 2. If that's unsupported (`ENOTSUP`/`EINVAL`), `linkat(partial -> final)` -- also atomic
    ///    and no-overwrite, since a link never replaces an existing name -- then `unlinkat(partial)`.
    /// 3. If hard links are unsupported too (FAT32, exFAT: both calls return `ENOTSUP`), create the
    ///    final name as an empty placeholder with `O_CREAT | O_EXCL | O_NOFOLLOW`, then
    ///    `renameat(partial, final)`. The exclusive create proves the name was free, so the rename
    ///    replaces only the placeholder this run just made. Chosen over copying the bytes a second
    ///    time: it costs no extra I/O, and the only residual race (another process deleting our
    ///    placeholder and creating its own file at that name in the instant before the rename) is
    ///    acceptable on these permission-less volumes. If the rename fails the placeholder is removed.
    ///
    /// Returns the name used, or the errno that stopped it.
    static func publish(_ partial: String, as finalName: String, in dirFD: Int32, ops: PublishOps,
                        fits: (String) -> Bool = { _ in true }) -> Result<String, Errno> {
        enum Strategy { case renameExclusive, link, placeholder }
        var strategy = Strategy.renameExclusive
        var attempt = 1
        while attempt <= 10_000 {
            let name = RecoveryPaths.candidate(finalName, attempt: attempt, isDirectory: false)
            guard fits(name) else { return .failure(Errno(code: ENAMETOOLONG)) }
            let code: Int32
            switch strategy {
            case .renameExclusive:
                code = ops.renameExclusive(dirFD, partial, name)
                if code == ENOTSUP || code == EOPNOTSUPP || code == EINVAL { strategy = .link; continue }
            case .link:
                code = ops.link(dirFD, partial, name)
                if code == 0 { _ = unlinkat(dirFD, partial, 0) }
                if [ENOTSUP, EOPNOTSUPP, EPERM, EINVAL, EMLINK].contains(code) { strategy = .placeholder; continue }
            case .placeholder:
                let created = ops.createExclusive(dirFD, name)
                if created == 0 {
                    let renamed = ops.rename(dirFD, partial, name)
                    if renamed != 0 { _ = unlinkat(dirFD, name, 0) }
                    code = renamed
                } else {
                    code = created
                }
            }
            if code == 0 { return .success(name) }
            guard code == EEXIST else { return .failure(Errno(code: code)) }
            attempt += 1
        }
        return .failure(Errno(code: EEXIST))
    }

    // MARK: POSIX helpers

    struct Errno: Error, Equatable { let code: Int32 }

    /// A file's identity on its volume.
    struct FileID: Equatable {
        let device: dev_t
        let inode: ino_t
        init?(fd: Int32) {
            var info = stat()
            guard fstat(fd, &info) == 0 else { return nil }
            device = info.st_dev; inode = info.st_ino
        }
    }

    /// Whether the directory open as `fd` is the root or sits at most `maxLevels` folders below
    /// it: walks `..` with `O_NOFOLLOW` relative opens and compares `(st_dev, st_ino)`, so it
    /// needs no path strings and works at any depth. Reaching the file system's top (or any
    /// error) without meeting the root means outside.
    static func isInside(_ fd: Int32, root: FileID, maxLevels: Int) -> Bool {
        var current = dup(fd)
        guard current >= 0 else { return false }
        defer { close(current) }
        for _ in 0...max(0, maxLevels) {
            guard let id = FileID(fd: current) else { return false }
            if id == root { return true }
            let parent = openat(current, "..", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard parent >= 0 else { return false }
            close(current); current = parent
            if FileID(fd: parent) == id { return false }  // "/" is its own parent
        }
        return false
    }

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

    /// `F_FULLFSYNC` (flushes the drive's own write cache, which plain `fsync` doesn't on macOS),
    /// falling back to `fsync` where the file system or device doesn't support it. Returns an
    /// errno on failure.
    static func durableSync(_ fd: Int32,
                            fullSync: (Int32) -> Int32 = { fcntl($0, F_FULLFSYNC) == -1 ? errno : 0 },
                            plainSync: (Int32) -> Int32 = { fsync($0) == 0 ? 0 : errno }) -> Int32? {
        let full = fullSync(fd)
        if full == 0 { return nil }
        guard [ENOTSUP, EOPNOTSUPP, ENOTTY, EINVAL].contains(full) else { return full }
        let plain = plainSync(fd)
        return plain == 0 ? nil : plain
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
    private let destinationCheck: @Sendable (URL) -> DestinationAssessment
    private var task: Task<Void, Never>?
    private var checkGeneration = 0

    init(files: [RecoveredFile], content: FileContentReader, deviceName: String,
         now: @escaping @Sendable () -> Date = { Date() },
         sync: (@Sendable (Int32) -> Int32?)? = nil,
         destinationCheck: @escaping @Sendable (URL) -> DestinationAssessment) {
        self.files = files
        self.totalBytes = files.reduce(0) { $0 + max(0, $1.sizeBytes) }
        var engine = RecoveryEngine(content: content)
        if let sync { engine.sync = sync }
        self.engine = engine
        self.deviceName = deviceName
        self.now = now
        self.destinationCheck = destinationCheck
    }

    convenience init(files: [RecoveredFile], source: SourceSession) {
        let device = source.device
        self.init(files: files, content: source.content, deviceName: device.displayName,
                  destinationCheck: { DestinationSafety.live.assess(destination: $0, source: device) })
    }

    /// Whether the confirmation is showing: before a run, or after one failed to start (the user
    /// may then pick another folder or retry).
    var isConfirming: Bool {
        switch phase {
        case .ready, .failedToStart: true
        case .running, .finished: false
        }
    }

    var canRecover: Bool { isConfirming && destinationStatus == .safe && !files.isEmpty }

    /// Records the chosen folder and checks it off the main thread. Choosing again after a failed
    /// start clears the failure and returns to the ready state.
    func chooseDestination(_ url: URL) async {
        guard isConfirming else { return }
        phase = .ready
        checkGeneration += 1
        let generation = checkGeneration
        destination = url
        destinationStatus = .checking
        let check = destinationCheck
        let verdict = await Task.detached { check(url).verdict }.value
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
            let assessment = await Task.detached { check(destination) }.value
            if Task.isCancelled { self?.phase = .ready; return }
            guard assessment.verdict.isSafe else {
                self?.destinationStatus = .blocked
                self?.phase = .ready
                return
            }
            let (stream, continuation) = AsyncStream<RecoveryProgress>.makeStream(bufferingPolicy: .bufferingNewest(1))
            async let result = Self.runEngine(engine, files: files, rootName: rootName, destination: destination,
                                              checked: assessment, continuation: continuation)
            for await update in stream { self?.progress = update }
            switch await result {
            case .success(let summary): self?.phase = .finished(summary)
            case .failure(.destinationUnsafe):
                // The folder opened wasn't on the checked volume: block, exactly like a bad verdict.
                self?.destinationStatus = .blocked
                self?.phase = .ready
            case .failure(.destinationUnavailable(let reason)): self?.phase = .failedToStart(reason)
            }
        }
    }

    func cancel() { task?.cancel() }

    /// Waits for the current run to end (tests).
    func waitUntilFinished() async { await task?.value }

    nonisolated private static func runEngine(_ engine: RecoveryEngine, files: [RecoveredFile], rootName: String,
                                              destination: URL, checked: DestinationAssessment,
                                              continuation: AsyncStream<RecoveryProgress>.Continuation)
        async -> Result<RecoverySummary, RecoveryStartError> {
        defer { continuation.finish() }
        return await engine.run(files: files, rootName: rootName, in: destination, checked: checked) { continuation.yield($0) }
    }

    nonisolated static func rootFolderName(device: String, date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let label = device.trimmingCharacters(in: .whitespacesAndNewlines)
        return "Salvage Recovery \(label.isEmpty ? "Drive" : label) \(formatter.string(from: date))"
    }
}
