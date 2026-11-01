import Darwin
import Foundation
import SalvageCore

/// The identity of a file on its volume: `(st_dev, st_ino)`.
public struct FileIdentity: Sendable, Hashable {
    public let device: Int64
    public let inode: UInt64
    public init(device: Int64, inode: UInt64) { self.device = device; self.inode = inode }
}

/// Destination safety (FR-15, AD-8) for a source that is a disk image *file* read directly
/// (spec-tech-batch-6 §C, the `salvage` command-line tool), rather than an attached device.
///
/// The rule mirrors `DestinationSafety` for an attached image: the source is the image itself, so
/// a destination is "on the source" when the volume it lives on is backed -- directly or through
/// further disk images, up to `DestinationSafety.maxVirtualDepth` levels -- by that same image
/// file (compared by `(st_dev, st_ino)`, so a second path or a symlink to it can't hide it). A
/// folder elsewhere on the volume that merely stores the image file is a different device, as it
/// is for an attached image in the app (writing other files there never changes the image's
/// bytes). Every step that can't be answered positively -- an unknown mount, a network share, a
/// virtual disk that isn't an identifiable image, an image path that can't be stat'ed -- yields
/// `.undetermined`, which every caller treats exactly like `.sameDevice` (fail closed).
public struct ImageFileDestinationSafety: Sendable {
    public typealias FileIdentityResolver = @Sendable (String) -> FileIdentity?

    private let mountSource: DestinationSafety.MountSourceResolver
    private let physicalDisks: DestinationSafety.PhysicalDiskResolver
    private let backing: DestinationSafety.DiskBackingResolver
    private let fileIdentity: FileIdentityResolver

    public init(mountSource: @escaping DestinationSafety.MountSourceResolver,
                physicalDisks: @escaping DestinationSafety.PhysicalDiskResolver,
                backing: @escaping DestinationSafety.DiskBackingResolver,
                fileIdentity: @escaping FileIdentityResolver) {
        self.mountSource = mountSource
        self.physicalDisks = physicalDisks
        self.backing = backing
        self.fileIdentity = fileIdentity
    }

    /// The same live resolvers as `DestinationSafety.live` (`statfs`, `diskutil info -plist`,
    /// `hdiutil info -plist`, metadata only and bounded), plus `stat(2)`. May block for a few
    /// seconds; call it off the main thread.
    public static let live = ImageFileDestinationSafety(
        mountSource: { path in mountSourceName(ofPath: path) },
        physicalDisks: { bsdName in physicalWholeDisks(backing: bsdName) },
        backing: { bsdName in liveDiskBacking(of: bsdName) },
        fileIdentity: { path in liveFileIdentity(ofPath: path) }
    )

    public func assess(destination: URL, imageFile: URL) -> DestinationAssessment {
        let undetermined = DestinationAssessment(verdict: .undetermined, mountSource: nil)
        guard destination.isFileURL, imageFile.isFileURL,
              let source = fileIdentity(imageFile.resolvingSymlinksInPath().path) else { return undetermined }
        let path = destination.resolvingSymlinksInPath().path
        guard !path.isEmpty, let mountFrom = mountSource(path) else { return undetermined }
        return DestinationAssessment(verdict: verdict(mountFrom: mountFrom, source: source, depth: 0), mountSource: mountFrom)
    }

    private func verdict(mountFrom: String, source: FileIdentity, depth: Int) -> DestinationVerdict {
        // Only a local device node counts, compared on bytes (as in `DestinationSafety`).
        guard depth <= DestinationSafety.maxVirtualDepth,
              mountFrom.utf8.starts(with: "/dev/".utf8),
              let whole = wholeDiskBSDName(fromDevicePath: mountFrom),
              let physical = physicalDisks(whole) else { return .undetermined }
        for disk in physical.union([whole]).sorted() {
            switch backing(disk) {
            case .physical?:
                continue
            case .diskImage(let imagePath)?:
                guard !imagePath.isEmpty else { return .undetermined }
                let resolved = URL(fileURLWithPath: imagePath).resolvingSymlinksInPath().path
                guard let identity = fileIdentity(resolved) else { return .undetermined }
                if identity == source { return .sameDevice }
                guard let hostMount = mountSource(resolved) else { return .undetermined }
                let host = verdict(mountFrom: hostMount, source: source, depth: depth + 1)
                guard host == .safe else { return host }
            case .unknownVirtual?, nil:
                return .undetermined
            }
        }
        return .safe
    }
}

/// `stat(path)`'s `(st_dev, st_ino)`, or nil when it fails.
public func liveFileIdentity(ofPath path: String) -> FileIdentity? {
    var info = stat()
    guard stat(path, &info) == 0 else { return nil }
    return FileIdentity(device: Int64(info.st_dev), inode: UInt64(info.st_ino))
}
