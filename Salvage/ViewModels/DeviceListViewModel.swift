import Foundation
import Observation
import SalvageCore
import SalvageDiskIO

/// One row of the Device Picker's Disk Utility-style tree: a drive (the only kind of row that can
/// be selected, and so the only scan target) or one of its partitions/volumes, which are shown
/// for information only.
public struct DeviceTreeNode: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case drive(BlockDevice)
        /// `drive` is the display name of the drive it belongs to; `container` the display name
        /// of the APFS container a volume sits in, if any.
        case partition(DevicePartition, drive: String, container: String?)
    }

    public let kind: Kind
    public let children: [DeviceTreeNode]

    /// A drive's id is its `BlockDevice.id`, so `List` selection tags stay drive ids. Partition
    /// ids are their BSD names, which never collide with a whole-disk name.
    public var id: String {
        switch kind {
        case .drive(let device): return device.id
        case .partition(let partition, _, _): return partition.id
        }
    }

    /// Only drives are scan targets; partitions are informational.
    public var isSelectableDrive: Bool {
        if case .drive = kind { return true }
        return false
    }

    /// Drives and their partitions start expanded; macOS's own support containers (system,
    /// recovery) start collapsed, as Disk Utility hides them by default.
    public var startsExpanded: Bool {
        guard case .partition(let partition, _, _) = kind else { return true }
        return !DeviceTreeLabel.supportContainers.contains(partition.displayName)
    }

    static func tree(for devices: [BlockDevice]) -> [DeviceTreeNode] {
        devices.map { device in
            DeviceTreeNode(kind: .drive(device),
                           children: partitionNodes(device.partitions, drive: device.displayName, container: nil))
        }
    }

    private static func partitionNodes(_ partitions: [DevicePartition], drive: String, container: String?) -> [DeviceTreeNode] {
        partitions.map { partition in
            DeviceTreeNode(kind: .partition(partition, drive: drive, container: container),
                           children: partitionNodes(partition.children, drive: drive, container: partition.displayName))
        }
    }
}

/// Drives the Device Picker (`DeviceListView`): consumes `DeviceWatcher.watch()`'s live device
/// stream and exposes the current `[BlockDevice]`, any watcher-level error state, and the user's
/// current selection. This story's scope ends at capturing which device is selected -- starting
/// a scan from that selection is Story 1.4's (spec Intent, "Scope boundary with Story 1.4").
@MainActor
@Observable
public final class DeviceListViewModel {
    /// The current device set, in the order `DeviceWatcher` reports it. Internal and external
    /// devices are intermixed here deliberately -- the view renders one unified list (FR-1),
    /// never separate sections.
    public private(set) var devices: [BlockDevice] = []

    /// Startup failure, including inability to safely identify the boot disk. The view renders
    /// a clear error rather than exposing devices with unknown protection status.
    public private(set) var watchError: DeviceWatcherError?

    /// The currently-selected device's id, if any. Never set to a boot volume's id -- see
    /// `selectDevice(_:)`.
    public private(set) var selectedDeviceID: BlockDevice.ID?

    /// `false` until the watcher's stream has emitted at least once. The view uses this to show
    /// a neutral loading state rather than momentarily flashing "No storage devices found." on
    /// every launch, before the first emission (which, in practice, always includes at least the
    /// boot volume) has had a chance to arrive.
    public private(set) var hasReceivedDevices = false

    /// The device set as a tree (Disk Utility style): each drive with its partitions, APFS
    /// containers and volumes beneath it. Selection still targets drives only.
    public var tree: [DeviceTreeNode] { DeviceTreeNode.tree(for: devices) }

    /// The watcher delivered a snapshot with no devices at all. Since the startup disk always
    /// enumerates, this is an anomaly the view reports as such, distinct from loading or error.
    public var seesNoDrives: Bool { watchError == nil && hasReceivedDevices && devices.isEmpty }

    private let watcher: any DeviceWatching
    private var watchTask: Task<Void, Never>?

    public init(watcher: any DeviceWatching = DeviceWatcher()) {
        self.watcher = watcher
    }

    /// Starts consuming the live device stream. Safe to call more than once -- any prior watch
    /// is cancelled first, so a SwiftUI `.task` re-running on view re-appearance never
    /// double-registers DiskArbitration callbacks.
    public func startWatching() {
        watchTask?.cancel()
        watchError = nil
        hasReceivedDevices = false

        devices = []
        selectedDeviceID = nil
        watchTask = Task { [weak self, watcher] in
            do {
                let stream = try await watcher.watch()
                for await currentDevices in stream {
                    if Task.isCancelled { return }
                    self?.apply(currentDevices)
                }
            } catch {
                guard !Task.isCancelled else { return }
                self?.watchError = (error as? DeviceWatcherError) ?? .sessionRegistrationFailed
            }
        }
    }

    /// Stops consuming the live device stream (e.g. the Device Picker is no longer on screen).
    public func stopWatching() {
        watchTask?.cancel()
        watchTask = nil
    }

    /// Selecting a device captures selection state only -- it never starts a scan (Scope
    /// boundary with Story 1.4). A no-op, not a crash, when the target is the boot volume or is
    /// no longer in the current device set (I/O matrix: "Attempting to select it is a no-op").
    ///
    /// Re-derives boot status from the canonical entry in `devices`, deliberately ignoring
    /// whatever `device.isBootVolume` the caller happened to pass in -- that field is just
    /// caller-supplied data, not something this method can trust as the real safety boundary.
    public func selectDevice(_ device: BlockDevice) {
        guard let canonical = devices.first(where: { $0.id == device.id }), !canonical.isBootVolume else { return }
        selectedDeviceID = canonical.id
    }

    /// Clears the current selection (e.g. the user deselects by clicking empty list space or
    /// pressing Escape).
    public func clearSelection() {
        selectedDeviceID = nil
    }

    private func apply(_ currentDevices: [BlockDevice]) {
        devices = currentDevices
        hasReceivedDevices = true
        if let selectedDeviceID, !currentDevices.contains(where: { $0.id == selectedDeviceID && !$0.isBootVolume }) {
            self.selectedDeviceID = nil
        }
    }

    // MARK: Recover all files (spec-tech-recover-whole-partition)

    /// The drive whose scan has finished with results open, set by the composition root from
    /// `ScanViewModel.deviceWithFinishedResults`. Its partition rows offer "Recover all files…".
    public var finishedScanDevice: BlockDevice?

    /// The partition "Recover all files…" acts on for a sidebar row, or nil when the row offers no
    /// such action: only partitions of the drive whose scan has finished (matched by BSD name and
    /// attachment identity, so a drive re-attached under the same name doesn't qualify). A volume
    /// inside an APFS container is its own target: its files carry its name and UUID, so it
    /// recovers only that volume (`PartitionGrouping.groups(for:…)` falls back to the container
    /// when its name is ambiguous).
    public func recoverAllTarget(for partition: DevicePartition) -> DevicePartition? {
        guard let finished = finishedScanDevice,
              let drive = devices.first(where: { $0.id == finished.id }),
              drive.mediaIdentity == finished.mediaIdentity else { return nil }
        for top in drive.partitions {
            if top.id == partition.id { return top }
            if let volume = top.children.first(where: { $0.id == partition.id }) { return volume }
        }
        return nil
    }

    /// VoiceOver label for a partition row: "Partition Photos, exFAT, 63.8 gigabytes, on SanDisk
    /// Ultra USB"; a volume inside an APFS container says so ("Volume Data, APFS, in APFS
    /// container, on ...") and has no size of its own.
    nonisolated public static func accessibilityLabel(for partition: DevicePartition, drive: String,
                                                      container: String?) -> String {
        var parts = ["\(container == nil ? "Partition" : "Volume") \(partition.displayName)", partition.formatName]
        if let size = partition.sizeBytes { parts.append(spokenSize(size)) }
        if let container { parts.append("in \(container)") }
        parts.append("on \(drive)")
        return parts.joined(separator: ", ")
    }

    /// A byte count in words, for VoiceOver ("63.8 gigabytes", not "63.8 GB").
    nonisolated public static func spokenSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let text = formatter.string(fromByteCount: bytes)
        let units = [" KB": " kilobytes", " MB": " megabytes", " GB": " gigabytes", " TB": " terabytes", " PB": " petabytes"]
        for (abbreviation, word) in units where text.hasSuffix(abbreviation) {
            let number = String(text.dropLast(abbreviation.count))
            return number + (number == "1" ? String(word.dropLast()) : word)
        }
        return text
    }
}
