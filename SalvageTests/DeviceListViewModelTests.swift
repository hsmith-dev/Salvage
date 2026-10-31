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

}
