import Testing

@testable import Salvage
import SalvageCore
import SalvageDiskIO

/// A fake `DeviceWatching` conformer so these tests drive `DeviceListViewModel` against a
/// controlled, in-memory device stream instead of a real DiskArbitration session.
private struct FakeDeviceWatcher: DeviceWatching {
    private let continuation: AsyncStream<[BlockDevice]>.Continuation
    private let stream: AsyncStream<[BlockDevice]>
    private let failure: DeviceWatcherError?

    init(failure: DeviceWatcherError? = nil) {
        self.failure = failure
        (stream, continuation) = AsyncStream.makeStream()
    }

    @MainActor func watch() async throws -> AsyncStream<[BlockDevice]> {
        if let failure { throw failure }
        return stream
    }

    func emit(_ devices: [BlockDevice]) {
        continuation.yield(devices)
    }
}

/// A handful of cooperative yields plus a short sleep -- enough, in-process, for
/// `DeviceListViewModel`'s internal `Task` to have consumed whatever `FakeDeviceWatcher.emit(_:)`
/// just produced before the test asserts on the result.
@MainActor
private func settle() async {
    for _ in 0..<10 {
        await Task.yield()
    }
    try? await Task.sleep(for: .milliseconds(20))
}

@Suite("DeviceListViewModel")
@MainActor
struct DeviceListViewModelTests {
    private static let bootVolume = BlockDevice(
        bsdName: "disk0",
        displayName: "Macintosh HD",
        sizeBytes: 500_000_000_000,
        isInternal: true,
        isBootVolume: true
    )

    private static let externalDrive = BlockDevice(
        bsdName: "disk6",
        displayName: "External SSD",
        sizeBytes: 1_000_000_000_000,
        isInternal: false,
        isBootVolume: false
    )

    @Test("selectDevice on the boot volume leaves selectedDeviceID unchanged, even if the caller claims otherwise")
    func selectDeviceNoOpsForBootVolume() async {
        let fake = FakeDeviceWatcher()
        let viewModel = DeviceListViewModel(watcher: fake)
        defer { viewModel.stopWatching() }
        viewModel.startWatching()
        fake.emit([Self.bootVolume, Self.externalDrive])
        await settle()

        // The canonical entry in `devices` says this is the boot volume -- `selectDevice` must
        // re-derive that itself, not trust a caller-supplied value that claims otherwise.
        let spoofed = BlockDevice(
            bsdName: Self.bootVolume.bsdName,
            displayName: Self.bootVolume.displayName,
            sizeBytes: Self.bootVolume.sizeBytes,
            isInternal: Self.bootVolume.isInternal,
            isBootVolume: false
        )
        viewModel.selectDevice(spoofed)

        #expect(viewModel.selectedDeviceID == nil)
    }

    @Test("apply() clears selectedDeviceID when the previously-selected device is absent from a new emission")
    func selectionClearsWhenDeviceDisappears() async {
        let fake = FakeDeviceWatcher()
        let viewModel = DeviceListViewModel(watcher: fake)
        defer { viewModel.stopWatching() }
        viewModel.startWatching()

        fake.emit([Self.externalDrive])
        await settle()
        viewModel.selectDevice(Self.externalDrive)
        #expect(viewModel.selectedDeviceID == Self.externalDrive.id)

        fake.emit([Self.bootVolume])
        await settle()
        #expect(viewModel.selectedDeviceID == nil)
    }

    /// `DeviceListView`'s List selection binding routes a nil write (clicking empty list space,
    /// pressing Escape) to `clearSelection()`. The SwiftUI List itself can't be driven from Swift
    /// Testing, so this covers the model half of that path: what the nil write must do.
    @Test("Deselecting (the List writing nil) clears the selection, keeps the devices, and allows reselecting")
    func deselectionClearsSelection() async {
        let fake = FakeDeviceWatcher()
        let viewModel = DeviceListViewModel(watcher: fake)
        defer { viewModel.stopWatching() }
        viewModel.startWatching()
        fake.emit([Self.bootVolume, Self.externalDrive])
        await settle()

        // A nil write with nothing selected is a harmless no-op.
        viewModel.clearSelection()
        #expect(viewModel.selectedDeviceID == nil)

        viewModel.selectDevice(Self.externalDrive)
        #expect(viewModel.selectedDeviceID == Self.externalDrive.id)

        viewModel.clearSelection()
        #expect(viewModel.selectedDeviceID == nil)
        #expect(viewModel.devices == [Self.bootVolume, Self.externalDrive], "deselecting never drops devices")

        // The next device snapshot, still containing the drive, must not bring the selection back.
        fake.emit([Self.bootVolume, Self.externalDrive])
        await settle()
        #expect(viewModel.selectedDeviceID == nil)

        viewModel.selectDevice(Self.externalDrive)
        #expect(viewModel.selectedDeviceID == Self.externalDrive.id, "the same device can be selected again")
    }

    @Test("a fake watcher's watch() throwing sets watchError, not a silent empty devices list")
    func throwingWatcherSetsWatchError() async {
        let fake = FakeDeviceWatcher(failure: .sessionRegistrationFailed)
        let viewModel = DeviceListViewModel(watcher: fake)
        defer { viewModel.stopWatching() }
        viewModel.startWatching()
        await settle()

        #expect(viewModel.watchError == .sessionRegistrationFailed)
        #expect(viewModel.devices.isEmpty)
        #expect(!viewModel.hasReceivedDevices)
    }

    @Test("A device becoming protected clears an existing selection")
    func selectionClearsWhenBootStatusChanges() async {
        let fake = FakeDeviceWatcher()
        let viewModel = DeviceListViewModel(watcher: fake)
        defer { viewModel.stopWatching() }
        viewModel.startWatching()
        fake.emit([Self.externalDrive])
        await settle()
        viewModel.selectDevice(Self.externalDrive)
        #expect(viewModel.selectedDeviceID == Self.externalDrive.id)

        let protected = BlockDevice(
            bsdName: Self.externalDrive.bsdName,
            displayName: Self.externalDrive.displayName,
            sizeBytes: Self.externalDrive.sizeBytes,
            isInternal: false,
            isBootVolume: true
        )
        fake.emit([protected])
        await settle()
        #expect(viewModel.selectedDeviceID == nil)
    }

    @Test("Boot resolution failure surfaces a safety error without selectable devices")
    func bootResolutionFailure() async {
        let viewModel = DeviceListViewModel(watcher: FakeDeviceWatcher(failure: .bootDiskResolutionFailed))
        defer { viewModel.stopWatching() }
        viewModel.startWatching()
        await settle()
        #expect(viewModel.watchError == .bootDiskResolutionFailed)
        #expect(viewModel.devices.isEmpty)
        #expect(viewModel.selectedDeviceID == nil)
    }

    @Test("An empty delivered snapshot is reported as anomalous, not as loading or a normal list")
    func emptySnapshotIsAnomalous() async {
        let fake = FakeDeviceWatcher()
        let viewModel = DeviceListViewModel(watcher: fake)
        defer { viewModel.stopWatching() }
        viewModel.startWatching()
        #expect(!viewModel.seesNoDrives)  // still loading
        fake.emit([])
        await settle()
        #expect(viewModel.seesNoDrives)
        fake.emit([Self.bootVolume])
        await settle()
        #expect(!viewModel.seesNoDrives)
        #expect(!DeviceListCopy.noDrivesDetail.contains("Connect a drive"))
        #expect(DeviceListCopy.noDrivesDetail.contains("startup disk"))
    }

    @Test("A watcher error is not also reported as an empty-drive anomaly")
    func watchErrorIsNotEmptyAnomaly() async {
        let viewModel = DeviceListViewModel(watcher: FakeDeviceWatcher(failure: .sessionRegistrationFailed))
        defer { viewModel.stopWatching() }
        viewModel.startWatching()
        await settle()
        #expect(!viewModel.seesNoDrives)
    }

    @Test("Restart clears stale devices and selection until a fresh snapshot arrives")
    func restartClearsStaleState() async {
        let fake = FakeDeviceWatcher()
        let viewModel = DeviceListViewModel(watcher: fake)
        defer { viewModel.stopWatching() }
        viewModel.startWatching()
        fake.emit([Self.externalDrive])
        await settle()
        viewModel.selectDevice(Self.externalDrive)
        viewModel.startWatching()
        #expect(viewModel.devices.isEmpty)
        #expect(viewModel.selectedDeviceID == nil)
        #expect(!viewModel.hasReceivedDevices)
    }

    // MARK: - Device tree (drives with their partitions nested beneath)

    private static let stick = BlockDevice(
        bsdName: "disk6", displayName: "SanDisk Ultra USB", sizeBytes: 64_000_000_000, isInternal: false,
        isBootVolume: false,
        partitions: [
            DevicePartition(bsdName: "disk6s1", displayName: "EFI", sizeBytes: 209_715_200, formatName: "EFI"),
            DevicePartition(bsdName: "disk6s2", displayName: "Photos", sizeBytes: 63_800_000_000, formatName: "exFAT"),
        ]
    )

    private static let bootWithContainer = BlockDevice(
        bsdName: "disk0", displayName: "Macintosh HD", sizeBytes: 2_000_000_000_000, isInternal: true,
        isBootVolume: true,
        partitions: [
            DevicePartition(bsdName: "disk0s2", displayName: "APFS container", sizeBytes: 2_000_000_000_000,
                            formatName: "APFS", children: [
                                DevicePartition(bsdName: "disk3s1", displayName: "Macintosh HD", sizeBytes: nil, formatName: "APFS"),
                                DevicePartition(bsdName: "disk3s5", displayName: "Data", sizeBytes: nil, formatName: "APFS"),
                            ]),
        ]
    )

    @Test("The tree has one top-level node per drive, with partitions and container volumes nested")
    func treeNestsPartitionsUnderDrives() async {
        let fake = FakeDeviceWatcher()
        let viewModel = DeviceListViewModel(watcher: fake)
        defer { viewModel.stopWatching() }
        viewModel.startWatching()
        fake.emit([Self.bootWithContainer, Self.stick])
        await settle()

        let tree = viewModel.tree
        #expect(tree.map(\.id) == ["disk0", "disk6"])
        #expect(tree.allSatisfy { $0.isSelectableDrive })
        #expect(tree[1].children.map(\.id) == ["disk6s1", "disk6s2"])
        #expect(tree[1].children.allSatisfy { !$0.isSelectableDrive })
        let container = tree[0].children[0]
        #expect(container.id == "disk0s2")
        #expect(container.children.map(\.id) == ["disk3s1", "disk3s5"])
        #expect(container.children[1].kind == .partition(Self.bootWithContainer.partitions[0].children[1],
                                                          drive: "Macintosh HD", container: "APFS container"))
    }

    @Test("Selecting a partition is a no-op; selection still targets only drives")
    func partitionsAreNotSelectable() async {
        let fake = FakeDeviceWatcher()
        let viewModel = DeviceListViewModel(watcher: fake)
        defer { viewModel.stopWatching() }
        viewModel.startWatching()
        fake.emit([Self.bootWithContainer, Self.stick])
        await settle()

        // A caller passing a partition dressed up as a device (same id) is refused: it isn't in `devices`.
        let partitionAsDevice = BlockDevice(bsdName: "disk6s2", displayName: "Photos", sizeBytes: 1,
                                            isInternal: false, isBootVolume: false)
        viewModel.selectDevice(partitionAsDevice)
        #expect(viewModel.selectedDeviceID == nil)

        // Volumes of the boot drive's container are not a way around the boot-volume refusal.
        viewModel.selectDevice(BlockDevice(bsdName: "disk3s5", displayName: "Data", sizeBytes: 1,
                                           isInternal: true, isBootVolume: false))
        #expect(viewModel.selectedDeviceID == nil)

        viewModel.selectDevice(Self.stick)
        #expect(viewModel.selectedDeviceID == "disk6")
    }

    @Test("A drive whose tree couldn't be read is still a selectable drive, with no children")
    func driveWithoutTree() async {
        let fake = FakeDeviceWatcher()
        let viewModel = DeviceListViewModel(watcher: fake)
        defer { viewModel.stopWatching() }
        viewModel.startWatching()
        fake.emit([Self.externalDrive])
        await settle()
        #expect(viewModel.tree.map(\.id) == ["disk6"])
        #expect(viewModel.tree[0].children.isEmpty)
        viewModel.selectDevice(Self.externalDrive)
        #expect(viewModel.selectedDeviceID == "disk6")
    }

    @Test("Drives and their partitions start expanded; macOS support containers start collapsed")
    func defaultExpansion() {
        let system = DevicePartition(bsdName: "disk0s1", displayName: DeviceTreeLabel.systemContainer,
                                     sizeBytes: 1, formatName: "APFS")
        let drive = BlockDevice(bsdName: "disk0", displayName: "SSD", sizeBytes: 1, isInternal: true, isBootVolume: true,
                                partitions: [system] + Self.bootWithContainer.partitions)
        let node = DeviceTreeNode.tree(for: [drive])[0]
        #expect(node.startsExpanded)
        #expect(node.children.map(\.startsExpanded) == [false, true])
    }

    @Test("VoiceOver reads partitions in words, with the drive they're on")
    func partitionAccessibilityLabels() {
        let photos = Self.stick.partitions[1]
        #expect(DeviceListViewModel.accessibilityLabel(for: photos, drive: "SanDisk Ultra USB", container: nil)
            == "Partition Photos, exFAT, 63.8 gigabytes, on SanDisk Ultra USB")
        let data = Self.bootWithContainer.partitions[0].children[1]
        #expect(DeviceListViewModel.accessibilityLabel(for: data, drive: "Macintosh HD", container: "APFS container")
            == "Volume Data, APFS, in APFS container, on Macintosh HD")
        #expect(DeviceListViewModel.spokenSize(209_715_200) == "209.7 megabytes")
        #expect(DeviceListViewModel.spokenSize(1_000_000_000_000) == "1 terabyte")
    }
}
