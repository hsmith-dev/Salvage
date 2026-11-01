import Foundation
import SalvageCore
import SalvageDiskIO
import Testing
@testable import Salvage

/// spec-tech-batch-7 §A: scanning disk image files. Every image is written into a fresh temporary
/// folder (deleted afterwards) from the UI-test fixture's synthetic exFAT volume; the .dmg test
/// attaches it read-only and unmounted and checks nothing of it stays attached.
@MainActor @Suite("Disk image sources", .serialized)
struct ImageSourceTests {
    private let expectedNames = Set(UITestFixture.files().map { ($0.path as NSString).lastPathComponent })

    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SalvageImageSource-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func fixtureImage(in dir: URL, name: String = "card.img") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try ExFATFixtureImage.build(files: UITestFixture.files(), sizeBytes: 8 * 1024 * 1024).write(to: url)
        return url
    }

    private static let refuseDrives: ScanViewModel.Runner = { _, _ in throw ScanError.io("not an image") }

    private func scan(_ image: OpenedDiskImage, registry: DiskImageRegistry) async -> ScanViewModel {
        let model = ScanViewModel(runner: DiskImageLibrary.runner(registry: registry, otherwise: Self.refuseDrives))
        model.start(image.device)
        while model.isActive { await Task.yield() }
        return model
    }

    @Test func aRawImageScansFromTheFileAndIsNotChanged() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = try fixtureImage(in: dir)
        let before = try Data(contentsOf: url)
        let registry = DiskImageRegistry()
        let library = DiskImageLibrary(registry: registry, detachOnQuit: false)
        let image = try #require(library.open(url))
        #expect(image.format == .raw)
        #expect(image.sizeBytes == 8 * 1024 * 1024)

        let model = await scan(image, registry: registry)
        #expect(model.state == .completed)
        #expect(Set(model.files.map(\.name)) == expectedNames)
        let source = try #require(model.source)
        let readme = try #require(model.files.first { $0.name == "readme.txt" })
        let bytes = try await source.content.prefix(of: readme, limit: readme.sizeBytes)
        #expect(bytes == UITestFixture.files().first { $0.path == "/readme.txt" }?.contents)
        await source.close()
        #expect(try Data(contentsOf: url) == before, "The image file is never written")
    }

    @Test func aDmgIsAttachedReadOnlyScannedAndDetachedWhenTheSessionCloses() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let raw = try fixtureImage(in: dir, name: "fixture.img")
        let dmg = dir.appendingPathComponent("backup.dmg")
        let convert = Process()
        convert.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        convert.arguments = ["convert", raw.path, "-format", "UDZO", "-o", dmg.path, "-quiet"]
        try convert.run(); convert.waitUntilExit()
        try #require(convert.terminationStatus == 0)
        let before = try Data(contentsOf: dmg)

        let registry = DiskImageRegistry()
        let library = DiskImageLibrary(registry: registry, detachOnQuit: false)
        let image = try #require(library.open(dmg))
        #expect(image.format == .attachable)
        #expect(DiskImageAttacher.live.attachedDisks(imagePath: dmg.path) == [], "Opening alone attaches nothing")

        let model = await scan(image, registry: registry)
        let source = model.source
        defer { for attachment in registry.attached.values { DiskImageAttacher.live.detach(attachment) } }
        #expect(model.state == .completed)
        #expect(Set(model.files.map(\.name)) == expectedNames)
        let attached = try #require(registry.attached[image.id])
        #expect(DiskImageAttacher.live.attachedDisks(imagePath: dmg.path)?.contains(attached.wholeDisk) == true,
                "Attached while its results are open")
        #expect(!attached.allWholeDisks.contains(where: isMounted), "Never mounted")

        await source?.close()
        #expect(registry.attached.isEmpty)
        #expect(DiskImageAttacher.live.attachedDisks(imagePath: dmg.path) == [], "Nothing stays attached")
        #expect(try Data(contentsOf: dmg) == before, "The image file is never written")
    }

    @Test func recoveryRefusesADestinationOnTheDriveHoldingTheImage() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = try fixtureImage(in: dir)
        let registry = DiskImageRegistry()
        let image = try #require(DiskImageLibrary(registry: registry, detachOnQuit: false).open(url))
        let check = try #require(DiskImageLibrary.destinationCheck(for: image.device, registry: registry))
        let beside = dir.appendingPathComponent("Recovered", isDirectory: true)
        try FileManager.default.createDirectory(at: beside, withIntermediateDirectories: true)
        #expect(!check(beside).verdict.isSafe)

        // A drive keeps its own check; an image Salvage no longer knows is refused outright.
        let drive = BlockDevice(bsdName: "disk42", displayName: "Drive", sizeBytes: 1, isInternal: false, isBootVolume: false)
        #expect(DiskImageLibrary.destinationCheck(for: drive, registry: registry) == nil)
        let unknown = BlockDevice(bsdName: "image-gone", displayName: "Gone", sizeBytes: 1, isInternal: false, isBootVolume: false)
        #expect(DiskImageLibrary.destinationCheck(for: unknown, registry: registry)?(beside).verdict == .undetermined)
    }

    @Test func libraryListsEachImageOnceAndExplainsRefusals() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = try fixtureImage(in: dir)
        let library = DiskImageLibrary(registry: DiskImageRegistry(), detachOnQuit: false)
        let first = try #require(library.open(url))
        #expect(library.open(dir.appendingPathComponent("./card.img")) == first)
        #expect(library.images.count == 1)
        #expect(first.name == "card.img")
        #expect(!first.device.bsdName.hasPrefix("disk"), "The stand-in device is never a BSD name")

        #expect(library.open(URL(fileURLWithPath: "/dev/null")) == nil)
        #expect(library.openError?.contains("is a drive, not an image file") == true)
        #expect(library.images.count == 1)

        library.remove(first.id)
        #expect(library.images.isEmpty)
    }

    @Test func drivesStillGoToTheDriveRunner() async {
        let drive = BlockDevice(bsdName: "disk42", displayName: "Drive", sizeBytes: 1024, isInternal: false, isBootVolume: false,
                                mediaIdentity: 1)
        let model = ScanViewModel(runner: DiskImageLibrary.runner(registry: DiskImageRegistry()) { _, events in
            try await events.send(.progress(bytesScanned: 1024, totalBytes: 1024))
            try await events.send(.completed)
        })
        model.start(drive)
        while model.isActive { await Task.yield() }
        #expect(model.state == .completed)
    }

    /// True when any mounted volume comes from `whole` or one of its slices.
    private func isMounted(_ whole: String) -> Bool {
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) ?? []
        return volumes.contains { volume in
            guard let source = mountSourceName(ofPath: volume.path) else { return false }
            return source == "/dev/\(whole)" || source.hasPrefix("/dev/\(whole)s")
        }
    }
}
