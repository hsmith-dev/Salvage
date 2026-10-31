import Observation
import SalvageCore
import SalvageDiskIO

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
}
