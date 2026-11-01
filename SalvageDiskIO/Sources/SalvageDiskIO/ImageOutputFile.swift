import Darwin
import Foundation
import SalvageCore

/// Why the image file couldn't be created. Plain language, shown as is.
public struct ImageOutputError: Error, Sendable, Equatable, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// spec-tech-image-drive: the `.img` file a drive is copied into, and its `.badblocks.json`
/// sidecar. Plain file I/O only, relative to the destination folder's open descriptor:
///
/// - the folder must be a directory on the volume `checked` was reached for (`fstatfs` of the
///   opened folder), so a volume mounted over the path since the check can't receive the image;
/// - the file is created new with `O_CREAT | O_EXCL | O_NOFOLLOW`, never through a symlink and
///   never by opening something that exists. An existing item is removed first only when the
///   caller says the user confirmed replacing it (the save panel's own prompt), only when it is
///   a regular file, and never when it is the backing file of an attached disk image (which
///   could be the very drive being imaged): `protectedFiles`, compared by `(st_dev, st_ino)`.
///   When that set is unknown (nil), no existing file is replaced;
/// - the opened file must be a regular file.
public final class ImageOutputFile: ImageSink, @unchecked Sendable {
    public let url: URL
    private let folder: Int32
    private let name: String
    private let replacingConfirmed: Bool
    private let protectedFiles: Set<FileIdentity>?
    private let lock = NSLock()
    private var fd: Int32

    public static let sidecarSuffix = ".badblocks.json"
    public var sidecarURL: URL { url.deletingLastPathComponent().appendingPathComponent(name + Self.sidecarSuffix) }

    public init(creating url: URL, replacingConfirmed: Bool, checked: DestinationAssessment,
                protectedFiles: Set<FileIdentity>?) throws {
        let name = url.lastPathComponent
        guard url.isFileURL, !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
            throw ImageOutputError("That file name can't be used for an image.")
        }
        let folderPath = url.deletingLastPathComponent().resolvingSymlinksInPath().path
        let folder = open(folderPath, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard folder >= 0 else { throw ImageOutputError("Couldn't open the destination folder: \(Self.text(errno)).") }
        guard checked.covers(openedMountSource: mountSourceName(ofDescriptor: folder)) else {
            Darwin.close(folder)
            throw ImageOutputError("The destination drive changed after it was checked. Choose the destination again.")
        }
        let opened: Int32
        do {
            try Self.removeConfirmed(name, in: folder, confirmed: replacingConfirmed, protected: protectedFiles)
            let fd = openat(folder, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
            guard fd >= 0 else {
                throw ImageOutputError(errno == EEXIST ? "A file named “\(name)” already exists there. Choose another name."
                                                       : "Couldn't create the image file: \(Self.text(errno)).")
            }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
                Darwin.close(fd)
                throw ImageOutputError("The destination isn't a regular file.")
            }
            opened = fd
        } catch {
            Darwin.close(folder)
            throw error
        }
        self.url = url.deletingLastPathComponent().appendingPathComponent(name)
        self.folder = folder
        self.name = name
        self.replacingConfirmed = replacingConfirmed
        self.protectedFiles = protectedFiles
        self.fd = opened
    }

    deinit {
        if fd >= 0 { Darwin.close(fd) }
        Darwin.close(folder)
    }

    /// Removes an existing *regular file* the user agreed to replace; refuses anything else,
    /// and refuses any attached disk image's backing file whether or not replacing was confirmed.
    private static func removeConfirmed(_ name: String, in folder: Int32, confirmed: Bool,
                                        protected: Set<FileIdentity>?) throws {
        var info = stat()
        guard fstatat(folder, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return }
            throw ImageOutputError("Couldn't check the destination: \(text(errno)).")
        }
        let identity = FileIdentity(device: Int64(info.st_dev), inode: UInt64(info.st_ino))
        if protected?.contains(identity) == true {
            throw ImageOutputError("“\(name)” is the disk image behind an attached drive, so it can't be replaced. Choose another name.")
        }
        guard confirmed else { throw ImageOutputError("A file named “\(name)” already exists there. Choose another name.") }
        guard info.st_mode & S_IFMT == S_IFREG else {
            throw ImageOutputError("“\(name)” already exists there and isn't a regular file, so it can't be replaced.")
        }
        guard protected != nil else {
            throw ImageOutputError("Salvage couldn't check whether “\(name)” is the disk image behind an attached drive, so it wasn't replaced. Choose another name.")
        }
        guard unlinkat(folder, name, 0) == 0 else { throw ImageOutputError("Couldn't replace “\(name)”: \(text(errno)).") }
    }

    public func write(_ data: Data, at offset: Int64) throws {
        let fd = lock.withLock { self.fd }
        guard fd >= 0 else { throw ImageOutputError("The image file is closed.") }
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var written = 0
            while written < raw.count {
                let result = pwrite(fd, base.advanced(by: written), raw.count - written, offset + Int64(written))
                if result < 0 {
                    if errno == EINTR { continue }
                    throw ImageOutputError(errno == ENOSPC ? "The destination drive is full." : Self.text(errno))
                }
                guard result > 0 else { throw ImageOutputError("The destination accepted no more bytes.") }
                written += result
            }
        }
    }

    public func synchronize() throws {
        let fd = lock.withLock { self.fd }
        guard fd >= 0 else { return }
        try Self.fullSync(fd)
    }

    /// F_FULLFSYNC asks the drive to flush its own cache too. Only a filesystem that doesn't
    /// support it (ENOTSUP, EINVAL) falls back to fsync; any other failure is a real error.
    static func fullSync(_ fd: Int32) throws {
        if fcntl(fd, F_FULLFSYNC) == 0 { return }
        let code = errno
        guard code == ENOTSUP || code == EINVAL else { throw ImageOutputError("Couldn't flush the image to disk: \(text(code)).") }
        guard fsync(fd) == 0 else { throw ImageOutputError("Couldn't flush the image to disk: \(text(errno)).") }
    }

    public func close() {
        let fd: Int32 = lock.withLock { defer { self.fd = -1 }; return self.fd }
        if fd >= 0 { Darwin.close(fd) }
    }

    /// Writes the sidecar next to the image, created new like the image. A stale sidecar is
    /// replaced only when replacing the image itself was confirmed.
    public func writeSidecar(_ report: ImagingReport) throws {
        let data = try report.encoded()
        let sidecar = name + Self.sidecarSuffix
        try Self.removeConfirmed(sidecar, in: folder, confirmed: replacingConfirmed, protected: protectedFiles)
        let fd = openat(folder, sidecar, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw ImageOutputError("Couldn't save the bad-block list: \(Self.text(errno)).") }
        do {
            try data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var written = 0
                while written < raw.count {
                    let result = Darwin.write(fd, base.advanced(by: written), raw.count - written)
                    if result < 0 { if errno == EINTR { continue }; throw ImageOutputError(Self.text(errno)) }
                    guard result > 0 else { throw ImageOutputError("The destination accepted no more bytes.") }
                    written += result
                }
            }
            try Self.fullSync(fd)
        } catch {
            Darwin.close(fd)
            throw error
        }
        guard Darwin.close(fd) == 0 else { throw ImageOutputError("Couldn't save the bad-block list: \(Self.text(errno)).") }
    }

    /// The backing files of every attached disk image (`hdiutil info -plist`, metadata only,
    /// bounded), by `(st_dev, st_ino)`; nil when they can't be listed. Paths that can't be
    /// stat'ed are left out (they can't be compared with a file that can).
    public static func attachedImageBackingFiles() -> Set<FileIdentity>? {
        guard let info = plistFromProcess(executable: URL(fileURLWithPath: "/usr/bin/hdiutil"), arguments: ["info", "-plist"]) else {
            return nil
        }
        return backingFiles(fromHdiutilInfo: info, identity: liveFileIdentity(ofPath:))
    }

    static func backingFiles(fromHdiutilInfo info: [String: Any], identity: (String) -> FileIdentity?) -> Set<FileIdentity>? {
        guard let images = info["images"] as? [[String: Any]] else { return info.isEmpty ? nil : [] }
        return Set(images.compactMap { ($0["image-path"] as? String).flatMap { identity(URL(fileURLWithPath: $0).resolvingSymlinksInPath().path) } })
    }

    static func text(_ code: Int32) -> String { String(cString: strerror(code)) }

    /// The largest file a volume's filesystem holds, when it is smaller than any drive: FAT32
    /// ("msdos") stops at 4 GiB − 1. Nil means no limit that matters here.
    public static func maximumFileSize(filesystemType: String) -> Int64? {
        filesystemType.lowercased() == "msdos" ? 4 * 1024 * 1024 * 1024 - 1 : nil
    }

    /// `statfs(path).f_fstypename`, e.g. "apfs", "msdos", "exfat".
    public static func filesystemType(ofPath path: String) -> String? {
        var info = statfs()
        guard statfs(path, &info) == 0 else { return nil }
        return withUnsafeBytes(of: info.f_fstypename) { raw in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
    }
}

/// The sidecar `<image>.badblocks.json`: what the image holds and which ranges of it are zeros
/// standing in for unreadable sectors. Metadata only, never any of the drive's bytes.
public struct ImagingReport: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable { case complete, cancelled, stopped }

    public var formatVersion = 1
    public var imageFile: String
    public var sourceName: String
    public var sourceDevice: String
    public var sourceSizeBytes: Int64
    public var blockSize: Int
    public var status: Status
    /// Plain-language note: why a copy is incomplete, and what that means for the image.
    public var note: String?
    /// The image holds bytes `[0, bytesCopied)` of the source.
    public var bytesCopied: Int64
    public var unreadableBytes: Int64
    /// Byte ranges of the source (and of the image) that couldn't be read; zeros in the image.
    public var badRanges: [ImagingBadRange]
    public var sha256: String?
    public var startedAt: Date
    public var finishedAt: Date

    public init(imageFile: String, sourceName: String, sourceDevice: String, sourceSizeBytes: Int64, blockSize: Int,
                status: Status, note: String?, bytesCopied: Int64, unreadableBytes: Int64, badRanges: [ImagingBadRange],
                sha256: String?, startedAt: Date, finishedAt: Date) {
        self.imageFile = imageFile; self.sourceName = sourceName; self.sourceDevice = sourceDevice
        self.sourceSizeBytes = sourceSizeBytes; self.blockSize = blockSize; self.status = status; self.note = note
        self.bytesCopied = bytesCopied; self.unreadableBytes = unreadableBytes; self.badRanges = badRanges
        self.sha256 = sha256; self.startedAt = startedAt; self.finishedAt = finishedAt
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> ImagingReport {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ImagingReport.self, from: data)
    }
}
