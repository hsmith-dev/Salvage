import CryptoKit
import Darwin
import Foundation
import SalvageCore
import SalvageDiskIO

// DUPLICATED CODE -- spec-tech-batch-6 §C.
//
// Everything below the "BEGIN VERBATIM COPY" line is a byte-for-byte copy of the app's recovery
// engine: the "Results", "Path safety" and "Engine" sections of
// Salvage/ViewModels/RecoveryCoordinator.swift (everything above its "// MARK: - Coordinator").
// That engine lives in the app target, which a SwiftPM executable can't depend on, and moving it
// into a shared module was out of this change's scope (the app's files belong to other work). So
// the CLI recovers with exactly the same code: no-overwrite publishing, O_NOFOLLOW directory
// walks, the root-containment check, the fstatfs re-check of the opened destination, durable
// sync, per-file SHA-256.
//
// SalvageCLITests/EngineCopyDriftTests fails if the two ever differ. To update: re-run the copy
// (see docs/CLI.md, "Maintenance"), never edit the copy by hand.
//
// BEGIN VERBATIM COPY
// MARK: - Results

/// One file that reached the destination intact.
struct RecoveredCopy: Sendable, Equatable {
    let sourcePath: String
    let url: URL
    let bytes: Int64
    /// Lowercase hex SHA-256 of exactly the bytes written, computed while streaming.
    let sha256: String
    /// The `RecoveredFile.id` this copy came from (pairs copies with files, e.g. in the report).
    var fileID: UUID? = nil
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
    /// Extra files written into the root after the copies (the recovery report), in order.
    var attachments: [URL] = []
    /// Why an extra file couldn't be written; nil when all were (or none was asked for).
    var attachmentFailure: String? = nil
    var bytesWritten: Int64 { written.reduce(0) { $0 + $1.bytes } }
}

/// A file written into the recovery root once the copies are done (the recovery report), with
/// the same no-overwrite publishing and containment rules as a recovered file.
struct RootAttachment: Sendable, Equatable {
    let name: String
    let data: Data
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
        let name = clean(component)
        return name == "_" ? name : truncate(name, keepingExtension: true)
    }

    /// `sanitize` without the length limit.
    static func clean(_ component: String) -> String {
        var scalars: [Unicode.Scalar] = component.unicodeScalars.filter {
            $0 != "/" && $0 != ":" && $0.value >= 0x20 && $0.value != 0x7F
        }
        while let first = scalars.first, first == "." || isInvisibleLeader(first) { scalars.removeFirst() }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        let name = String(view)
        if name.isEmpty || name == "." || name == ".." { return "_" }
        return name
    }

    /// Like `sanitize`, for a folder name: no part of it is an extension, so a long name is cut
    /// at its end without trying to keep a ".suffix".
    static func sanitizeFolderName(_ component: String) -> String {
        let cleaned = clean(component)
        return cleaned == "_" ? cleaned : truncate(cleaned, keepingExtension: false)
    }

    /// `name` cut (on a character boundary) to at most `bytes` UTF-8 bytes.
    static func prefix(_ name: String, maxBytes bytes: Int) -> String {
        var result = name
        while result.utf8.count > bytes { result.removeLast() }
        return result
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
    /// Flushes the destination drive's write cache (and the given file) to stable storage before
    /// files are published; returns an errno on failure. Called once per batch of staged files.
    var sync: @Sendable (Int32) -> Int32? = { RecoveryEngine.durableSync($0) }
    /// Pushes one staged file's bytes to the device (`fsync`), so the batch's `sync` covers it.
    var stageSync: @Sendable (Int32) -> Int32? = { fsync($0) == 0 ? nil : errno }
    var publishOps = PublishOps.live

    /// Files are copied in batches of at most this many files (or `publishBatchBytes`): each is
    /// written under its `.partial` name and `fsync`ed, then one `F_FULLFSYNC` makes the whole
    /// batch durable, and only then is each file published under its final name, in order. That
    /// is the two-phase pattern fcntl(2) documents ("data that had been fsync'd on the same device
    /// before is guaranteed to be persisted" once `F_FULLFSYNC` returns), so a final name still
    /// never refers to bytes that could be lost. A full flush per file made recovering hundreds
    /// of thousands of small files flush-bound: about 150 files a second on an internal SSD.
    static let publishBatchFiles = 32
    static let publishBatchBytes: Int64 = 64 * 1024 * 1024

    /// `attachments`, when given, is called with the finished summary (also after a cancel) and
    /// its files are written into the root folder last; see `writeAttachment`.
    func run(files: [RecoveredFile], rootName: String, in destination: URL, checked: DestinationAssessment,
             attachments: (@Sendable (RecoverySummary) -> [RootAttachment])? = nil,
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
        switch Self.makeDirectory(in: destinationFD, named: RecoveryPaths.sanitizeFolderName(rootName), reuseExisting: false) {
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
        // Results by position in `files`, so both lists keep the selection's order.
        var written: [(Int, RecoveredCopy)] = []
        var failed: [(Int, RecoveryFailureRecord)] = []
        var state = RecoveryProgress(filesFinished: 0, bytesDone: 0, currentName: nil)
        var cancelled = false
        var batch: [Staged] = []
        var batchBytes: Int64 = 0
        // Logical folders (as in `directoryNames`) that hold staged files.
        var stagedFolders: Set<String> = []
        func failure(_ file: RecoveredFile, _ reason: CopyFailure) -> RecoveryFailureRecord {
            RecoveryFailureRecord(id: file.id, name: file.name, sourcePath: file.path, reason: reason.reason)
        }
        // Makes the staged files durable and publishes them. Also runs after a cancel: every
        // staged file is complete, so it is kept like any file finished before the cancel.
        func commitBatch() {
            for (staged, outcome) in commit(batch) {
                switch outcome {
                case .success(let copy): written.append((staged.index, copy))
                case .failure(let reason):
                    state.bytesDone -= staged.bytes
                    failed.append((staged.index, failure(staged.file, reason)))
                }
            }
            batch = []; batchBytes = 0; stagedFolders = []
        }

        for (index, file) in files.enumerated() {
            if Task.isCancelled { cancelled = true; break }
            state.currentName = file.name
            progress(state)
            let baseBytes = state.bytesDone
            // A folder resolved now inside a folder that holds staged files could take the name
            // one of them is about to be published under (or push it to " (2)"). Publish them
            // first, so every name comes out as if each file were published as soon as written.
            var logical = ""
            for component in RecoveryPaths.folderComponents(of: file) {
                let parent = logical
                logical += "/" + component
                if directoryNames[logical] == nil, stagedFolders.contains(parent) { commitBatch(); break }
            }
            let root = Root(fd: rootFD, id: rootID, path: rootPath)
            let outcome = await stage(file, index: index, root: root, directoryNames: &directoryNames) { done in
                var update = state
                update.bytesDone = baseBytes + done
                progress(update)
            }
            switch outcome {
            case .success(let staged):
                batch.append(staged); batchBytes += staged.bytes
                stagedFolders.insert(RecoveryPaths.folderComponents(of: file).reduce("") { $0 + "/" + $1 })
                state.bytesDone = baseBytes + staged.bytes
            case .failure(.cancelled):
                state.bytesDone = baseBytes
                cancelled = true
            case .failure(let reason):
                state.bytesDone = baseBytes
                failed.append((index, failure(file, reason)))
            }
            if cancelled { break }
            if batch.count >= Self.publishBatchFiles || batchBytes >= Self.publishBatchBytes { commitBatch() }
            state.filesFinished += 1
            progress(state)
        }
        commitBatch()
        state.currentName = nil
        progress(state)
        let notAttempted = files.count - written.count - failed.count
        var summary = RecoverySummary(root: rootURL, selectedCount: files.count,
                                      written: written.sorted { $0.0 < $1.0 }.map(\.1),
                                      failed: failed.sorted { $0.0 < $1.0 }.map(\.1),
                                      notAttempted: notAttempted, cancelled: cancelled)
        for attachment in attachments?(summary) ?? [] {
            switch Self.writeAttachment(attachment, root: Root(fd: rootFD, id: rootID, path: rootPath), sync: sync, ops: publishOps) {
            case .success(let url): summary.attachments.append(url)
            case .failure(let error): summary.attachmentFailure = summary.attachmentFailure ?? Self.describe(errno: error.code)
            }
        }
        return .success(summary)
    }

    /// Writes one attachment directly into the root folder: sanitized name, `O_EXCL | O_NOFOLLOW`
    /// temporary file, durable sync, then `publish` (never replaces an existing file; a recovered
    /// file that already took the name pushes the attachment to "name (2).ext"). The root is
    /// confirmed by identity first, exactly like a recovered file's folder. Ignores cancellation:
    /// a cancelled run still gets its record.
    static func writeAttachment(_ attachment: RootAttachment, root: Root, sync: (Int32) -> Int32?,
                                ops: PublishOps) -> Result<URL, Errno> {
        let finalName = RecoveryPaths.sanitize(attachment.name)
        guard RecoveryPaths.fitsPathLimit(RecoveryPaths.join(root.path, [finalName])) else {
            return .failure(Errno(code: ENAMETOOLONG))
        }
        guard isInside(root.fd, root: root.id, maxLevels: 0) else { return .failure(Errno(code: EACCES)) }
        let partialName = RecoveryPaths.partialName(for: finalName)
        let fd = openat(root.fd, partialName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return .failure(Errno(code: errno)) }
        if let code = writeAll(attachment.data, to: fd) ?? sync(fd) {
            close(fd); _ = unlinkat(root.fd, partialName, 0)
            return .failure(Errno(code: code))
        }
        close(fd)
        switch publish(partialName, as: finalName, in: root.fd, ops: ops,
                       fits: { RecoveryPaths.fitsPathLimit(RecoveryPaths.join(root.path, [$0])) }) {
        case .success(let name):
            _ = fsync(root.fd)
            return .success(URL(fileURLWithPath: root.path, isDirectory: true).appendingPathComponent(name, isDirectory: false))
        case .failure(let error):
            _ = unlinkat(root.fd, partialName, 0)
            return .failure(error)
        }
    }

    // MARK: One file

    enum CopyFailure: Error, Equatable {
        case cancelled
        case unmapped
        case damagedMapping
        case sourceRead
        /// A reopened scan's small NTFS file whose record no longer holds it (spec-tech-batch-7 §B).
        case needsRescan
        case shortSource
        case outsideRoot
        case destination(Int32)

        var reason: String {
            switch self {
            case .cancelled: "Cancelled."
            case .unmapped: "Salvage couldn't locate this file's contents on the drive."
            case .damagedMapping: "This file's location on the drive is incomplete or damaged."
            case .sourceRead: "Couldn't read this file from the drive."
            case .needsRescan: "Rescan to recover this file."
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

    /// A file written in full under its `.partial` name and `fsync`ed, waiting for its batch's
    /// full flush before it is published. Owns `fd` and `dirFD` until `commit` closes them.
    struct Staged {
        let index: Int
        let file: RecoveredFile
        let fd: Int32
        let dirFD: Int32
        let dirPath: String
        let partialName: String
        let finalName: String
        let bytes: Int64
        let sha256: String
    }

    /// One full flush for the whole batch (every staged file was `fsync`ed first), then each file
    /// is published in order. When the flush fails, no file of the batch is published: each
    /// partial is removed and the file fails with that error.
    private func commit(_ batch: [Staged]) -> [(Staged, Result<RecoveredCopy, CopyFailure>)] {
        guard let newest = batch.last else { return [] }
        let flushed = sync(newest.fd)
        return batch.map { staged in
            close(staged.fd)
            defer { close(staged.dirFD) }
            if let code = flushed {
                _ = unlinkat(staged.dirFD, staged.partialName, 0)
                return (staged, .failure(.destination(code)))
            }
            switch Self.publish(staged.partialName, as: staged.finalName, in: staged.dirFD, ops: publishOps,
                                fits: { RecoveryPaths.fitsPathLimit(RecoveryPaths.join(staged.dirPath, [$0])) }) {
            case .success(let name):
                _ = fsync(staged.dirFD)
                let url = URL(fileURLWithPath: staged.dirPath, isDirectory: true).appendingPathComponent(name, isDirectory: false)
                return (staged, .success(RecoveredCopy(sourcePath: staged.file.path, url: url, bytes: staged.bytes,
                                                       sha256: staged.sha256, fileID: staged.file.id)))
            case .failure(let error):
                _ = unlinkat(staged.dirFD, staged.partialName, 0)
                return (staged, .failure(.destination(error.code)))
            }
        }
    }

    /// Writes `file` under a `.partial` name in its folder and `fsync`s it; `commit` publishes it.
    private func stage(_ file: RecoveredFile, index: Int, root: Root, directoryNames: inout [String: String],
                       progress: (Int64) -> Void) async -> Result<Staged, CopyFailure> {
        do { try content.validate(file) } catch let error as FileContentError {
            return .failure(error == .unmapped ? .unmapped : .damagedMapping)
        } catch { return .failure(.damagedMapping) }

        let components = RecoveryPaths.folderComponents(of: file)
        let finalName = RecoveryPaths.sanitize(file.name)
        // Refuse up front (before creating any folder) a path the OS can't name as a whole.
        guard RecoveryPaths.fitsPathLimit(RecoveryPaths.join(root.path, components + [finalName])) else {
            return .failure(.destination(ENAMETOOLONG))
        }

        // Open (creating as needed) each folder level below the root. On success the folder's
        // descriptor goes to the staged file; otherwise it is closed here.
        var dirFD = dup(root.fd)
        guard dirFD >= 0 else { return .failure(.destination(errno)) }
        var keepDirFD = false
        defer { if !keepDirFD { close(dirFD) } }
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
        } catch let error as ScanError where error == .io(CopyFailure.needsRescan.reason) {
            discard(); return .failure(.needsRescan)
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
        if let code = stageSync(fd) { discard(); return .failure(.destination(code)) }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        keepDirFD = true
        return .success(Staged(index: index, file: file, fd: fd, dirFD: dirFD, dirPath: dirPath, partialName: partialName,
                               finalName: finalName, bytes: total, sha256: digest))
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

