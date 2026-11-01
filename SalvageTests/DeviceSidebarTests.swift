import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Salvage
import SalvageCore
import SalvageDiskIO

// The Device Picker's Disk Utility-style sections, and a DEBUG-only render of the sidebar with
// fixture devices shaped like a real Mac (no real device is read: the watcher is a fake).

/// Devices shaped like a Mac with an internal boot SSD, an SD card reader, two USB drives,
/// eight simulator/system images macOS attached, and one image the user attached.
enum SidebarFixture {
    static let gb: Int64 = 1_000_000_000

    static let bootSSD = BlockDevice(
        bsdName: "disk0", displayName: "APPLE SSD AP2048Z", sizeBytes: 2_001_111_162_880, isInternal: true,
        isBootVolume: true, mediaIdentity: 1,
        partitions: [
            DevicePartition(bsdName: "disk0s1", displayName: DeviceTreeLabel.systemContainer, sizeBytes: 576_716_800,
                            formatName: "APFS", children: ["iSCPreboot", "xART", "Hardware", "Recovery"].enumerated().map {
                                DevicePartition(bsdName: "disk2s\($0.offset + 1)", displayName: $0.element, sizeBytes: nil, formatName: "APFS")
                            }),
            DevicePartition(bsdName: "disk0s2", displayName: DeviceTreeLabel.apfsContainer, sizeBytes: 1_995_165_736_960,
                            formatName: "APFS", children: ["Macintosh HD", "Preboot", "Recovery", "Update", "Data", "VM"].enumerated().map {
                                DevicePartition(bsdName: "disk3s\($0.offset + 1)", displayName: $0.element, sizeBytes: nil, formatName: "APFS")
                            }),
            DevicePartition(bsdName: "disk0s3", displayName: DeviceTreeLabel.recoveryContainer, sizeBytes: 5_368_664_064,
                            formatName: "APFS"),
        ])

    static let sdReader = BlockDevice(
        bsdName: "disk6", displayName: "Built In SDXC Reader", sizeBytes: 1_000_727_379_968, isInternal: true,
        isBootVolume: false, mediaIdentity: 6,
        partitions: [DevicePartition(bsdName: "disk6s1", displayName: "Transcend", sizeBytes: 1_000_660_271_104, formatName: "exFAT")])

    static let usbHardDrive = BlockDevice(
        bsdName: "disk17", displayName: "MK3252GSX", sizeBytes: 320_072_933_376, isInternal: false, isBootVolume: false,
        mediaIdentity: 17,
        partitions: [
            DevicePartition(bsdName: "disk17s1", displayName: "Untitled", sizeBytes: 306_018_516_992, formatName: "NTFS"),
            DevicePartition(bsdName: "disk17s2", displayName: "RECOVERY", sizeBytes: 14_049_869_824, formatName: "NTFS"),
        ])

    static let usbStick = BlockDevice(
        bsdName: "disk18", displayName: "SanDisk 3.2Gen1", sizeBytes: 250_047_627_264, isInternal: false, isBootVolume: false,
        mediaIdentity: 18,
        partitions: [DevicePartition(bsdName: "disk18s1", displayName: "Untitled", sizeBytes: 250_046_578_688, formatName: "HFS+")])

    static let userImage = BlockDevice(
        bsdName: "disk13", displayName: "Salvage-1.0.0.dmg", sizeBytes: 21_491_200, isInternal: false, isBootVolume: false,
        mediaIdentity: 13,
        partitions: [DevicePartition(bsdName: "disk13s1", displayName: "Salvage 1.0.0", sizeBytes: 21_450_752, formatName: "HFS+")],
        isDiskImage: true, diskImagePath: "/Users/me/Desktop/Salvage-1.0.0.dmg")

    static let systemImages: [BlockDevice] = [
        ("iOS 27.0 Simulator", 18_559_829_504), ("WatchOS 27.0 Simulator", 9_332_360_704),
        ("WatchOS 26.5 Simulator", 9_112_159_744), ("iOS 26.5 Simulator", 18_083_776_000),
        ("MetalToolchainCryptex", 3_298_854_400), ("tvOS 26.5 Simulator", 8_700_000_000),
        ("visionOS 26.5 Simulator", 12_400_000_000), ("iOS 26.0 Simulator", 17_900_000_000),
    ].enumerated().map { index, image in
        let whole = 40 + index * 2
        return BlockDevice(
            bsdName: "disk\(whole)", displayName: "094-5603\(index)-099.dmg", sizeBytes: Int64(image.1), isInternal: false,
            isBootVolume: false, mediaIdentity: UInt64(whole),
            partitions: [DevicePartition(bsdName: "disk\(whole)s1", displayName: DeviceTreeLabel.apfsContainer,
                                         sizeBytes: Int64(image.1) - 34_304, formatName: "APFS",
                                         children: [DevicePartition(bsdName: "disk\(whole + 1)s1", displayName: image.0,
                                                                    sizeBytes: nil, formatName: "APFS")])],
            isDiskImage: true,
            diskImagePath: "/System/Library/AssetsV2/com_apple_MobileAsset_iOSSimulatorRuntime/x.asset/AssetData/Restore/094-5603\(index)-099.dmg",
            isSystemImage: true)
    }

    /// In `diskutil list` order, as the watcher reports them.
    static var devices: [BlockDevice] {
        [bootSSD] + systemImages.prefix(1) + [sdReader] + systemImages.dropFirst().prefix(4) + [userImage]
            + systemImages.dropFirst(5) + [usbHardDrive, usbStick]
    }
}

@Suite("Device sidebar sections")
struct DeviceSidebarSectionTests {
    @Test("Drives split into Internal and External; user images under Disk Images; the rest Hidden")
    func sections() {
        let sidebar = DeviceSidebar.sections(for: SidebarFixture.devices)
        #expect(sidebar.internalDrives.map(\.id) == ["disk6"])
        #expect(sidebar.externalDrives.map(\.id) == ["disk17", "disk18"])
        #expect(sidebar.diskImages.map(\.id) == ["disk13"])
        #expect(sidebar.hidden.count == 9)
        #expect(sidebar.hidden.first == HiddenDevice(device: SidebarFixture.bootSSD, reason: .startupDisk))
        #expect(sidebar.hidden.dropFirst().allSatisfy { $0.reason == .systemDiskImage })
        #expect(!sidebar.hasNoVisibleDrives)
    }

    @Test("Each device keeps its partition tree beneath it")
    func treesKept() throws {
        let sidebar = DeviceSidebar.sections(for: SidebarFixture.devices)
        let drive = try #require(sidebar.externalDrives.first)
        #expect(drive.isSelectableDrive)
        #expect(drive.children.map(\.id) == ["disk17s1", "disk17s2"])
        #expect(drive.children.allSatisfy { !$0.isSelectableDrive })
    }

    @Test("The startup disk is hidden even when it is external; a scannable internal drive is not")
    func startupDiskAlwaysHidden() {
        let externalBoot = BlockDevice(bsdName: "disk4", displayName: "Samsung T7", sizeBytes: 1, isInternal: false, isBootVolume: true)
        let internalData = BlockDevice(bsdName: "disk1", displayName: "APPLE SSD", sizeBytes: 1, isInternal: true, isBootVolume: false)
        let sidebar = DeviceSidebar.sections(for: [externalBoot, internalData])
        #expect(sidebar.externalDrives.isEmpty)
        #expect(sidebar.internalDrives.map(\.id) == ["disk1"])
        #expect(sidebar.hidden.map(\.reason) == [.startupDisk])
        #expect(!HiddenDeviceReason.startupDisk.isScannable)
        #expect(!HiddenDeviceReason.systemDiskImage.isScannable)
    }

    @Test("Images Salvage attached itself are left out entirely")
    func excludedImages() {
        let sidebar = DeviceSidebar.sections(for: SidebarFixture.devices, excluding: ["disk13", "disk40"])
        #expect(sidebar.diskImages.isEmpty)
        #expect(!sidebar.hidden.map(\.id).contains("disk40"))
    }

    @Test("Only the startup disk attached: nothing visible, the startup disk under Hidden")
    func onlyStartupDisk() {
        let sidebar = DeviceSidebar.sections(for: [SidebarFixture.bootSSD])
        #expect(sidebar.hasNoVisibleDrives)
        #expect(sidebar.hidden.count == 1)
    }

    @Test("A system image's row is named after its volumes, not its file")
    func hiddenTitles() throws {
        let sidebar = DeviceSidebar.sections(for: SidebarFixture.devices)
        #expect(sidebar.hidden.first?.title == "APPLE SSD AP2048Z")
        #expect(sidebar.hidden.dropFirst().first?.title == "iOS 27.0 Simulator")
        let bare = BlockDevice(bsdName: "disk9", displayName: "x.dmg", sizeBytes: 1, isInternal: false, isBootVolume: false,
                               isDiskImage: true, isSystemImage: true)
        #expect(HiddenDevice(device: bare, reason: .systemDiskImage).title == "x.dmg")
    }

    @Test("The view model never selects the startup disk or a system disk image; it does select a drive")
    @MainActor func selection() async throws {
        let model = DeviceListViewModel(watcher: StaticDeviceWatcher(devices: SidebarFixture.devices))
        model.startWatching()
        for _ in 0..<50 where !model.hasReceivedDevices { try await Task.sleep(for: .milliseconds(10)) }
        model.selectDevice(SidebarFixture.bootSSD)
        #expect(model.selectedDeviceID == nil)
        model.selectDevice(SidebarFixture.systemImages[0])
        #expect(model.selectedDeviceID == nil)
        model.selectDevice(SidebarFixture.usbStick)
        #expect(model.selectedDeviceID == "disk18")
    }
}

/// Emits one fixed device set.
struct StaticDeviceWatcher: DeviceWatching {
    let devices: [BlockDevice]
    @MainActor func watch() async throws -> AsyncStream<[BlockDevice]> {
        let (stream, continuation) = AsyncStream<[BlockDevice]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuation.yield(devices)
        return stream
    }
}

#if DEBUG
/// Renders the sidebar to PNGs in light and dark mode, with "Hidden" collapsed and expanded, for
/// reviewing the layout without the UI-test runner. Writes to `$SALVAGE_SIDEBAR_SNAPSHOT_DIR`
/// (pass it to `xcodebuild` as `TEST_RUNNER_SALVAGE_SIDEBAR_SNAPSHOT_DIR`), else the temporary
/// folder. Checks only that each image was produced and isn't blank.
@Suite("Device sidebar snapshots", .serialized)
@MainActor
struct DeviceSidebarSnapshotTests {
    @Test("Light and dark, Hidden collapsed and expanded", arguments: [false, true])
    func render(hiddenExpanded: Bool) async throws {
        try await render(devices: SidebarFixture.devices, hiddenExpanded: hiddenExpanded,
                         suffix: hiddenExpanded ? "-hidden-open" : "", height: hiddenExpanded ? 1240 : 860)
    }

    /// The same Mac as if its internal SSD weren't the startup disk, to check how an APFS drive
    /// (containers and volumes) lays out under "Internal".
    @Test("An internal APFS drive's containers and volumes")
    func renderAPFS() async throws {
        let ssd = SidebarFixture.bootSSD
        let scannable = BlockDevice(bsdName: ssd.bsdName, displayName: ssd.displayName, sizeBytes: ssd.sizeBytes,
                                    isInternal: true, isBootVolume: false, mediaIdentity: 1, partitions: ssd.partitions)
        try await render(devices: [scannable, SidebarFixture.sdReader], hiddenExpanded: false, suffix: "-apfs", height: 640)
    }

    private func render(devices: [BlockDevice], hiddenExpanded: Bool, suffix: String, height: CGFloat) async throws {
        let directory = ProcessInfo.processInfo.environment["SALVAGE_SIDEBAR_SNAPSHOT_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.temporaryDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // An image file opened in Salvage (a raw image: read only to learn its size).
        let imageFolder = FileManager.default.temporaryDirectory.appendingPathComponent("sidebar-snapshot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: imageFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: imageFolder) }
        let imageFile = imageFolder.appendingPathComponent("Card Backup.img")
        try Data(count: 8 * 1024 * 1024).write(to: imageFile)
        let library = DiskImageLibrary(registry: DiskImageRegistry(), detachOnQuit: false)
        #expect(library.open(imageFile) != nil)

        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: DeviceListSection.hiddenExpandedKey)
        defaults.set(hiddenExpanded, forKey: DeviceListSection.hiddenExpandedKey)
        defer { defaults.set(previous, forKey: DeviceListSection.hiddenExpandedKey) }

        for (appearance, name) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            let view = DeviceListView(watcher: StaticDeviceWatcher(devices: devices), images: library)
            // The sidebar column's ideal width (`ContentView`).
            let size = NSSize(width: 280, height: height)
            let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
            host.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            window.contentView = host
            window.orderBack(nil)
            defer { window.orderOut(nil) }
            // Let the watcher's first emission land and the list lay out.
            for _ in 0..<15 {
                try await Task.sleep(for: .milliseconds(100))
                host.layoutSubtreeIfNeeded()
            }
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let png = try #require(rep.representation(using: .png, properties: [:]))
            let file = directory.appendingPathComponent("sidebar-\(name)\(suffix).png")
            try png.write(to: file)
            #expect(png.count > 10_000, "\(file.path) looks blank")
        }
    }
}
#endif
