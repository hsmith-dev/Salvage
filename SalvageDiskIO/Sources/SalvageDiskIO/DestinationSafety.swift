import Foundation
import SalvageCore

/// Whether a recovery destination is safe to write to (FR-15, AD-8).
public enum DestinationVerdict: Sendable, Equatable {
    /// The destination lives on a different physical device from the source.
    case safe
    /// The destination lives on the same physical device as the source.
    case sameDevice
    /// The destination's device couldn't be positively determined; treated exactly like
    /// `.sameDevice` by every caller (fail closed).
    case undetermined

    public var isSafe: Bool { self == .safe }
}

/// Decides whether a destination folder lives on the same physical device as the source.
///
/// The destination's volume is found with `statfs` (`f_mntfromname`), reduced to its whole disk,
/// and expanded to the physical disk(s) backing it (APFS physical stores), reusing the boot-disk
/// helpers. The source device is expanded the same way, so a synthesized APFS container and the
/// physical disk carrying it are recognised as one device in either direction. Any step that
/// can't be answered positively yields `.undetermined`, never `.safe`.
public struct DestinationSafety: Sendable {
    /// Returns the mount source (`f_mntfromname`, e.g. `/dev/disk7s1`) of the volume holding the
    /// given path, or `nil` if it can't be determined.
    public typealias MountSourceResolver = @Sendable (String) -> String?
    /// Returns the physical whole disk(s) backing a whole-disk BSD name, or `nil` on failure.
    public typealias PhysicalDiskResolver = @Sendable (String) -> Set<String>?

    private let mountSource: MountSourceResolver
    private let physicalDisks: PhysicalDiskResolver

    public init(mountSource: @escaping MountSourceResolver, physicalDisks: @escaping PhysicalDiskResolver) {
        self.mountSource = mountSource
        self.physicalDisks = physicalDisks
    }

    /// The real resolver: `statfs` plus `diskutil info -plist` (metadata only, bounded by a timeout).
    /// It may block for a few seconds, so call it off the main thread.
    public static let live = DestinationSafety(
        mountSource: { path in mountSourceName(ofPath: path) },
        physicalDisks: { bsdName in physicalWholeDisks(backing: bsdName) }
    )

    public func check(destination: URL, source: BlockDevice) -> DestinationVerdict {
        guard destination.isFileURL else { return .undetermined }
        let path = destination.resolvingSymlinksInPath().path
        guard !path.isEmpty,
              let mountFrom = mountSource(path),
              // Only a local device node counts; a network share named e.g. "//host/disk3" must
              // never be read as a local disk.
              mountFrom.hasPrefix("/dev/"),
              let destinationWhole = wholeDiskBSDName(fromDevicePath: mountFrom),
              let sourceWhole = wholeDiskBSDName(fromDevicePath: source.bsdName),
              let destinationPhysical = physicalDisks(destinationWhole),
              let sourcePhysical = physicalDisks(sourceWhole)
        else { return .undetermined }
        let destinationSet = destinationPhysical.union([destinationWhole])
        let sourceSet = sourcePhysical.union([sourceWhole])
        return destinationSet.isDisjoint(with: sourceSet) ? .safe : .sameDevice
    }
}

/// `statfs(path).f_mntfromname`, decoded with a bounded NUL search; `nil` if `statfs` fails.
func mountSourceName(ofPath path: String) -> String? {
    var stat = statfs()
    guard statfs(path, &stat) == 0 else { return nil }
    let tuple = stat.f_mntfromname
    let capacity = MemoryLayout.size(ofValue: tuple)
    return withUnsafePointer(to: tuple) { ptr in
        ptr.withMemoryRebound(to: CChar.self, capacity: capacity) { chars in
            let buffer = UnsafeBufferPointer(start: chars, count: capacity)
            let length = buffer.firstIndex(of: 0) ?? capacity
            return String(decoding: buffer[0..<length].map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
    }
}
