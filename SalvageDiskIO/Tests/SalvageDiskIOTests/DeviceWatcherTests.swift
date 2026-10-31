import Testing
@testable import SalvageDiskIO

@Suite("Device watcher startup safety")
@MainActor
struct DeviceWatcherTests {
    @Test("Unresolved boot disks fail before device publication")
    func resolutionFailure() async {
        let watcher = DeviceWatcher(bootDiskResolver: {
            throw DeviceWatcherError.bootDiskResolutionFailed
        })
        await #expect(throws: DeviceWatcherError.bootDiskResolutionFailed) {
            _ = try await watcher.watch()
        }
    }

    @Test("An empty protected set is rejected")
    func emptyProtectedSet() async {
        let watcher = DeviceWatcher(bootDiskResolver: { [] })
        await #expect(throws: DeviceWatcherError.bootDiskResolutionFailed) {
            _ = try await watcher.watch()
        }
    }
}
