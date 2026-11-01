import Darwin
import DiskArbitration
import Foundation
import IOKit
import SalvageCore

// spec-tech-batch-7 §A: scanning a disk image *file* from the app.
//
// A raw image (.img/.dd/.bin/.iso/.raw, or anything that isn't UDIF or sparse) is read directly
// through `ImageFileReader` (O_RDONLY + pread). A UDIF .dmg or a sparse image is attached by
// `hdiutil` read-only and unmounted (`-readonly -nomount -noverify -noautofsck`), scanned through
// `RawBlockReader` like any device, and detached when the session ends. The image file is never
// opened for writing and nothing is ever mounted.

/// How a disk image file is read.
public enum DiskImageFormat: Sendable, Equatable {
    /// The file's bytes are the disk's bytes: read with `ImageFileReader`.
    case raw
    /// UDIF (a "koly" trailer) or a sparse image/bundle: attached read-only and unmounted.
    case attachable
}

/// Why an image can't be opened, worded for the app (EXPERIENCE.md voice).
public enum DiskImageOpenError: Error, Equatable, Sendable, CustomStringConvertible {
    case unreadable(name: String)
    case isDevice(name: String)
    case notAnImage(name: String)
    case empty(name: String)
    case attachFailed(name: String, reason: String)

    public var description: String {
        switch self {
        case .unreadable(let name): "Salvage couldn't read “\(name)”. Check that the file is still there and that you can open it."
        case .isDevice(let name): "“\(name)” is a drive, not an image file. Choose it from the list of drives instead."
        case .notAnImage(let name): "“\(name)” isn't a disk image file."
        case .empty(let name): "“\(name)” is empty, so there's nothing to scan."
        case .attachFailed(let name, let reason): "macOS couldn't open “\(name)” as a disk image. \(reason)"
        }
    }
}

/// What `DiskImageFile.inspect` found out about an image, without keeping anything open.
public struct DiskImageInfo: Sendable, Equatable {
    public let url: URL
    public let format: DiskImageFormat
    /// The disk's size for a raw image; the file (or bundle) size for an attachable one.
    public let sizeBytes: Int64
    public let identity: FileIdentity
}

public enum DiskImageFile {
    /// Classifies an image and checks it can be read (a raw one is opened read-only and closed
    /// again). Devices, links to devices, folders (other than a `.sparsebundle`) and empty files
    /// are refused.
    public static func inspect(_ url: URL) throws -> DiskImageInfo {
        let name = url.lastPathComponent
        let path = url.resolvingSymlinksInPath().path
        var info = stat()
        guard stat(path, &info) == 0 else { throw DiskImageOpenError.unreadable(name: name) }
        let kind = info.st_mode & S_IFMT
        guard kind != S_IFCHR, kind != S_IFBLK else { throw DiskImageOpenError.isDevice(name: name) }
        let identity = FileIdentity(device: Int64(info.st_dev), inode: UInt64(info.st_ino))
        if kind == S_IFDIR {
            guard url.pathExtension.lowercased() == "sparsebundle",
                  FileManager.default.fileExists(atPath: path + "/Info.plist") else { throw DiskImageOpenError.notAnImage(name: name) }
            return DiskImageInfo(url: URL(fileURLWithPath: path), format: .attachable, sizeBytes: bundleSize(path), identity: identity)
        }
        guard kind == S_IFREG else { throw DiskImageOpenError.notAnImage(name: name) }
        guard info.st_size > 0 else { throw DiskImageOpenError.empty(name: name) }
        let format = try format(ofFileAt: path, size: Int64(info.st_size), name: name)
        switch format {
        case .attachable:
            return DiskImageInfo(url: URL(fileURLWithPath: path), format: .attachable, sizeBytes: Int64(info.st_size), identity: identity)
        case .raw:
            do {
                let reader = try ImageFileReader(path: path)
                defer { reader.close() }
                return DiskImageInfo(url: URL(fileURLWithPath: path), format: .raw, sizeBytes: reader.sizeBytes, identity: identity)
            } catch ImageOpenError.deviceNode { throw DiskImageOpenError.isDevice(name: name)
            } catch ImageOpenError.empty { throw DiskImageOpenError.empty(name: name)
            } catch { throw DiskImageOpenError.unreadable(name: name) }
        }
    }

    /// UDIF when the last 512 bytes start with "koly", sparse when the file starts with "sprs";
    /// anything else is read as raw.
    static func format(ofFileAt path: String, size: Int64, name: String) throws -> DiskImageFormat {
        let fd = Darwin.open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw DiskImageOpenError.unreadable(name: name) }
        defer { Darwin.close(fd) }
        return format(head: read(fd, at: 0, count: 4), trailer: size >= 1024 ? read(fd, at: size - 512, count: 4) : nil)
    }

    static func format(head: Data?, trailer: Data?) -> DiskImageFormat {
        if trailer == Data("koly".utf8) || head == Data("sprs".utf8) { return .attachable }
        return .raw
    }

    private static func read(_ fd: Int32, at offset: Int64, count: Int) -> Data? {
        var data = Data(count: count)
        let n = data.withUnsafeMutableBytes { Darwin.pread(fd, $0.baseAddress, count, offset) }
        return n == count ? data : nil
    }

    private static func bundleSize(_ path: String) -> Int64 {
        guard let items = FileManager.default.enumerator(at: URL(fileURLWithPath: path),
                                                         includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let item as URL in items {
            total += Int64((try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}

// MARK: - Attaching

/// A disk image attached read-only and unmounted by `DiskImageAttacher`.
public struct AttachedDiskImage: Sendable, Equatable {
    /// The image's own whole disk (e.g. `disk7`), the scan target.
    public let wholeDisk: String
    /// Every whole disk the attach produced (the image's, plus e.g. a synthesized APFS
    /// container), all of which go away when it is detached.
    public let allWholeDisks: Set<String>
    /// The image file as `hdiutil` reports it.
    public let imagePath: String
}

/// Attaches and detaches disk images with `/usr/bin/hdiutil`. Every attach is
/// `-readonly -nomount -noverify -noautofsck`: macOS never mounts, checks or writes the image.
/// Detach acts only on a disk that `hdiutil info` still shows as this same image file, so a
/// reused disk number can't make Salvage detach something else.
public struct DiskImageAttacher: Sendable {
    public typealias Runner = @Sendable (_ arguments: [String], _ timeout: TimeInterval) -> (status: Int32, output: Data)?

    private let run: Runner

    public init(run: @escaping Runner) { self.run = run }

    public static let live = DiskImageAttacher { arguments, timeout in
        runBoundedProcess(executable: URL(fileURLWithPath: "/usr/bin/hdiutil"), arguments: arguments, timeout: timeout)
            .map { ($0.status, $0.standardOutput) }
    }

    /// The exact arguments of every attach.
    public static func attachArguments(imagePath: String) -> [String] {
        ["attach", "-readonly", "-nomount", "-noverify", "-noautofsck", "-plist", imagePath]
    }

    public func attach(_ url: URL) throws -> AttachedDiskImage {
        let name = url.lastPathComponent
        let path = url.resolvingSymlinksInPath().path
        guard let result = run(Self.attachArguments(imagePath: path), 120) else {
            throw DiskImageOpenError.attachFailed(name: name, reason: "It took too long to open.")
        }
        guard result.status == 0,
              let plist = (try? PropertyListSerialization.propertyList(from: result.output, format: nil)) as? [String: Any],
              let attached = Self.parseAttach(plist, imagePath: path) else {
            throw DiskImageOpenError.attachFailed(name: name, reason: "It may be damaged, or need a password Salvage can't supply.")
        }
        return attached
    }

    /// The whole disks in `hdiutil attach -plist` output; the first entity's is the image's own.
    static func parseAttach(_ plist: [String: Any], imagePath: String) -> AttachedDiskImage? {
        guard let entities = plist["system-entities"] as? [[String: Any]] else { return nil }
        let wholes = entities.compactMap { ($0["dev-entry"] as? String).flatMap(wholeDiskBSDName(fromDevicePath:)) }
        guard let first = wholes.first, isWholeDiskBSDName(first) else { return nil }
        return AttachedDiskImage(wholeDisk: first, allWholeDisks: Set(wholes), imagePath: imagePath)
    }

    /// Whole disks `hdiutil info` currently shows for `imagePath`; nil when it can't be asked.
    public func attachedDisks(imagePath: String) -> Set<String>? {
        guard let result = run(["info", "-plist"], 20), result.status == 0,
              let plist = (try? PropertyListSerialization.propertyList(from: result.output, format: nil)) as? [String: Any]
        else { return nil }
        return Self.disks(inInfo: plist, imagePath: imagePath)
    }

    static func disks(inInfo plist: [String: Any], imagePath: String) -> Set<String> {
        let target = URL(fileURLWithPath: imagePath).resolvingSymlinksInPath().path
        var disks: Set<String> = []
        for image in (plist["images"] as? [[String: Any]]) ?? [] {
            guard let path = image["image-path"] as? String,
                  URL(fileURLWithPath: path).resolvingSymlinksInPath().path == target else { continue }
            for entity in (image["system-entities"] as? [[String: Any]]) ?? [] {
                if let whole = (entity["dev-entry"] as? String).flatMap(wholeDiskBSDName(fromDevicePath:)) { disks.insert(whole) }
            }
        }
        return disks
    }

    /// Detaches the image if it is still attached as `image.wholeDisk`; retries once with
    /// `-force` (this is Salvage's own unmounted, read-only attachment). True when it is gone.
    @discardableResult
    public func detach(_ image: AttachedDiskImage) -> Bool {
        guard let current = attachedDisks(imagePath: image.imagePath) else { return false }
        guard current.contains(image.wholeDisk) else { return true }
        let device = "/dev/\(image.wholeDisk)"
        if run(["detach", device], 60)?.status == 0 { return true }
        if run(["detach", device, "-force"], 60)?.status == 0 { return true }
        return attachedDisks(imagePath: image.imagePath).map { !$0.contains(image.wholeDisk) } ?? false
    }

    /// The `BlockDevice` for an attached image's whole disk, for `RawBlockReader.prepare`.
    public static func device(for image: AttachedDiskImage, displayName: String) -> BlockDevice? {
        guard let identity = liveMediaIdentity(ofBSDName: image.wholeDisk),
              let size = liveMediaSize(ofBSDName: image.wholeDisk) else { return nil }
        return BlockDevice(bsdName: image.wholeDisk, displayName: displayName, sizeBytes: size,
                           isInternal: false, isBootVolume: false, mediaIdentity: identity)
    }
}

private func liveMediaSize(ofBSDName name: String) -> Int64? {
    guard let session = DASessionCreate(kCFAllocatorDefault),
          let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, name),
          let description = DADiskCopyDescription(disk) as? [String: Any],
          let size = description[kDADiskDescriptionMediaSizeKey as String] as? NSNumber else { return nil }
    return size.int64Value
}

// MARK: - Destination safety

/// Destination safety (FR-15, AD-8) for a source that is a disk image file opened in the app.
///
/// A destination is refused when it is on the drive that holds the image file: the image's host
/// volume is reduced to its whole disk and checked with `DestinationSafety`, and when that host is
/// itself an attached image the drive holding *that* file is checked too (up to
/// `DestinationSafety.maxVirtualDepth` hops). It is also refused when it is on a volume backed by
/// the image itself (`ImageFileDestinationSafety`). Any step that can't be answered positively
/// gives `.undetermined`, which callers treat as `.sameDevice`.
public struct DiskImageDestinationSafety: Sendable {
    private let mountSource: DestinationSafety.MountSourceResolver
    private let backing: DestinationSafety.DiskBackingResolver
    private let devices: DestinationSafety
    private let imageFile: ImageFileDestinationSafety

    public init(mountSource: @escaping DestinationSafety.MountSourceResolver,
                backing: @escaping DestinationSafety.DiskBackingResolver,
                devices: DestinationSafety, imageFile: ImageFileDestinationSafety) {
        self.mountSource = mountSource; self.backing = backing; self.devices = devices; self.imageFile = imageFile
    }

    public static let live = DiskImageDestinationSafety(
        mountSource: { mountSourceName(ofPath: $0) },
        backing: { liveDiskBacking(of: $0) },
        devices: .live, imageFile: .live)

    public func assess(destination: URL, imageFile file: URL) -> DestinationAssessment {
        guard let hosts = hostDisks(of: file.resolvingSymlinksInPath().path, depth: 0), !hosts.isEmpty else {
            return DestinationAssessment(verdict: .undetermined, mountSource: nil)
        }
        var assessments = hosts.map { host in
            devices.assess(destination: destination,
                           source: BlockDevice(bsdName: host, displayName: host, sizeBytes: 0, isInternal: false, isBootVolume: false))
        }
        assessments.append(imageFile.assess(destination: destination, imageFile: file))
        let verdicts = assessments.map(\.verdict)
        let verdict: DestinationVerdict = verdicts.contains(.sameDevice) ? .sameDevice
            : verdicts.allSatisfy(\.isSafe) ? .safe : .undetermined
        let mounts = Set(assessments.map(\.mountSource))
        // Every check stats the same destination; a disagreement means it changed underneath.
        guard mounts.count == 1, let mount = mounts.first ?? nil else {
            return DestinationAssessment(verdict: verdict == .sameDevice ? .sameDevice : .undetermined, mountSource: nil)
        }
        return DestinationAssessment(verdict: verdict, mountSource: mount)
    }

    /// The whole disk holding `path`, then (if that disk is an attached image) the whole disk
    /// holding its image file, and so on. Nil when any hop can't be resolved.
    private func hostDisks(of path: String, depth: Int) -> [String]? {
        guard depth <= DestinationSafety.maxVirtualDepth, let mount = mountSource(path),
              mount.utf8.starts(with: "/dev/".utf8), let whole = wholeDiskBSDName(fromDevicePath: mount) else { return nil }
        switch backing(whole) {
        case .physical?:
            return [whole]
        case .diskImage(let imagePath)?:
            guard !imagePath.isEmpty,
                  let further = hostDisks(of: URL(fileURLWithPath: imagePath).resolvingSymlinksInPath().path, depth: depth + 1)
            else { return nil }
            return [whole] + further
        case .unknownVirtual?, nil:
            return nil
        }
    }
}
