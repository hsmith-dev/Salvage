import Foundation
import SalvageCore
import SalvageDiskIO
import Testing
@testable import Salvage

// Recover all files from a partition (spec-tech-recover-whole-partition): grouping, naming,
// selection, the sidebar's context-menu gate, and an end-to-end run on a real exFAT disk image
// this suite creates (and detaches) in its own temp directory.

private let photosOffset: Int64 = 209_735_680
private let lostOffset: Int64 = 70_000_000_000
private let tree = [
    DevicePartition(bsdName: "disk6s1", displayName: "EFI", sizeBytes: 209_715_200, formatName: "EFI", offsetBytes: 20_480),
    DevicePartition(bsdName: "disk6s2", displayName: "Photos", sizeBytes: 63_790_000_000, formatName: "exFAT",
                    offsetBytes: photosOffset),
]

private func found(_ path: String, volume: Int64, filesystem: SourceMetadata.Filesystem = .exfat, deleted: Bool = false,
                   size: Int64 = 100, content: FileContent? = nil) -> RecoveredFile {
    RecoveredFile(name: (path as NSString).lastPathComponent, path: path, sizeBytes: size, isDeleted: deleted,
                  sourceMetadata: SourceMetadata(filesystem: filesystem, volumeOffset: volume, recordOffset: volume + 4096,
                                                 allocationStart: 2, contiguous: true, rawRecord: Data()),
                  content: content ?? .runs([DataRun(deviceOffset: volume + 8192, length: size)]))
}

private func carved(_ name: String, extent: Int64, start: Int64, size: Int64 = 100) -> RecoveredFile {
    RecoveredFile(name: name, path: "/Reconstructed/Pictures/\(name)", sizeBytes: size,
                  sourceMetadata: SourceMetadata(filesystem: .carved, volumeOffset: extent, recordOffset: start,
                                                 allocationStart: UInt64(start), contiguous: true, rawRecord: Data()),
                  content: .runs([DataRun(deviceOffset: start, length: size)]), recoveryMethod: .carved,
                  isPartial: true, overwriteConfidence: 0.6)
}

private struct Fixture {
    let live = found("/DCIM/a.jpg", volume: photosOffset)
    let deleted = found("/DCIM/b.jpg", volume: photosOffset, deleted: true)
    let unmapped = found("/DCIM/c.jpg", volume: photosOffset, content: .unmapped)
    let system = found("/DCIM/._a.jpg", volume: photosOffset)
    let carvedInPhotos = carved("jpeg-1.jpg", extent: photosOffset, start: photosOffset + 1_000_000)
    let lostFile = found("/old/doc.txt", volume: lostOffset, filesystem: .fat32)
    let carvedInLost = carved("jpeg-2.jpg", extent: 0, start: lostOffset + 512)
    let carvedOutside = carved("jpeg-3.jpg", extent: 0, start: 4096)
    let unknownVolume = found("/Users/x.doc", volume: 5_000_000, filesystem: .ntfs)
    let lost = LostPartitionCandidate(offset: lostOffset, sizeBytes: 1_000_000_000, formatName: "FAT32")

    var files: [RecoveredFile] {
        [live, deleted, unmapped, system, carvedInPhotos, lostFile, carvedInLost, carvedOutside, unknownVolume]
    }
}

@MainActor @Suite("Recover all files from a partition")
struct PartitionSummaryTests {
    // MARK: Grouping

    @Test func filesAreGroupedByPartitionWithCarvesByContainmentAndAnUnpartitionedBucket() {
        let f = Fixture()
        let model = ResultsViewModel(files: f.files, lostPartitions: [f.lost])
        let cache = PartitionSectionCache()
        let rows = model.partitionSummaries(devicePartitions: tree, cache: cache)
        #expect(rows.map(\.key) == [.volume(5_000_000), .volume(photosOffset), .volume(lostOffset), .unpartitioned])
        #expect(rows.map(\.kind) == [.mapped, .mapped, .lost, .unpartitioned])

        let photos = rows[1]
        #expect(photos.name == "Photos (exFAT)")
        #expect(photos.title == "Photos (exFAT), \(ByteCountFormatter.string(fromByteCount: 63_790_000_000, countStyle: .file))")
        // live + deleted + carved; the unmapped file and the hidden system file aren't counted.
        #expect(photos.recoverableCount == 3 && photos.deletedCount == 1 && photos.reconstructedCount == 1)
        #expect(photos.countsText == "3 files, of which 1 deleted and 1 reconstructed")

        let lost = rows[2]
        #expect(lost.name == "Lost partition — FAT32" && lost.sizeBytes == 1_000_000_000)
        #expect(lost.recoverableCount == 2 && lost.reconstructedCount == 1)
        #expect(rows[3].name == "Unpartitioned space" && rows[3].recoverableCount == 1 && rows[3].reconstructedCount == 1)

        // Showing system files counts them too; the grouping itself is computed once.
        model.showSystemFiles = true
        #expect(model.partitionSummaries(devicePartitions: tree, cache: cache)[1].recoverableCount == 4)
        #expect(cache.groupings == 1)
    }

    @Test func aRawSweepCarveInsideAKnownPartitionCountsTowardIt() {
        let inside = carved("png-1.png", extent: 0, start: photosOffset + 4096)
        let keys = PartitionGrouping.keys(for: [inside].map(ResultsViewModel.Row.init), partitions: tree, lostPartitions: [])
        #expect(keys == [.volume(photosOffset)])
    }

    // MARK: Naming

    @Test func partitionsAreNamedFromTheDeviceTreeByOffsetWithAFallback() {
        #expect(PartitionGrouping.name(forVolumeAt: photosOffset, formatName: "exFAT", partitions: tree).name == "Photos (exFAT)")
        #expect(PartitionGrouping.name(forVolumeAt: photosOffset, formatName: "exFAT", partitions: tree).size == 63_790_000_000)
        // An unnamed partition's display name is its format: not "exFAT (exFAT)".
        let unnamed = [DevicePartition(bsdName: "disk7s1", displayName: "exFAT", sizeBytes: 10, formatName: "exFAT", offsetBytes: 0)]
        #expect(PartitionGrouping.name(forVolumeAt: 0, formatName: "exFAT", partitions: unnamed).name == "exFAT")
        // An APFS container is matched by its store's offset, nested volumes have none.
        let apfs = [DevicePartition(bsdName: "disk0s2", displayName: "APFS container", sizeBytes: 500, formatName: "APFS",
                                    children: [DevicePartition(bsdName: "disk3s1", displayName: "Data", sizeBytes: nil, formatName: "APFS")],
                                    offsetBytes: 1_048_576)]
        #expect(PartitionGrouping.name(forVolumeAt: 1_048_576, formatName: "APFS", partitions: apfs).name == "APFS container (APFS)")
        // No match (unknown offsets, or a different one): format name and offset.
        let fallback = PartitionGrouping.name(forVolumeAt: 5_000_000, formatName: "NTFS", partitions: tree)
        #expect(fallback.name == "NTFS volume at \(ByteCountFormatter.string(fromByteCount: 5_000_000, countStyle: .file))")
        #expect(fallback.size == nil)
        let noOffsets = [DevicePartition(bsdName: "disk6s2", displayName: "Photos", sizeBytes: 1, formatName: "exFAT")]
        #expect(PartitionGrouping.name(forVolumeAt: photosOffset, formatName: "exFAT", partitions: noOffsets).name.hasPrefix("exFAT volume at "))
    }

    // MARK: Selection

    @Test func recoverAllSelectsExactlyThePartitionsRecoverableFiles() async throws {
        let f = Fixture()
        let model = ResultsViewModel(files: f.files, lostPartitions: [f.lost])
        let cache = PartitionSectionCache()
        let photos = try #require(model.partitionSummaries(devicePartitions: tree, cache: cache).first { $0.key == .volume(photosOffset) })
        let plan = model.recoverAllPlan(for: photos, devicePartitions: tree, cache: cache)
        #expect(plan.name == "Photos (exFAT)")
        #expect(plan.files.map(\.id) == [f.live.id, f.deleted.id])
        #expect(plan.reconstructed.map(\.id) == [f.carvedInPhotos.id])

        // The system-files setting is followed.
        model.showSystemFiles = true
        #expect(model.recoverAllPlan(for: photos, devicePartitions: tree, cache: cache).files.map(\.id) == [f.live.id, f.deleted.id, f.system.id])

        // Reconstructed files are out by default and in with the checkbox.
        let coordinator = RecoveryCoordinator(files: plan.files, content: FileContentReader(reader: EmptyReader()),
                                              deviceName: "Drive", rootName: plan.name, reconstructedFiles: plan.reconstructed,
                                              destinationCheck: { _ in DestinationAssessment(verdict: .safe, mountSource: nil) })
        #expect(!coordinator.includeReconstructed)
        #expect(coordinator.files.map(\.id) == [f.live.id, f.deleted.id])
        #expect(coordinator.totalBytes == 200)
        coordinator.setIncludeReconstructed(true)
        #expect(coordinator.files.map(\.id) == [f.live.id, f.deleted.id, f.carvedInPhotos.id])
        #expect(coordinator.totalBytes == 300)
    }

    @Test func aSidebarPartitionIsMatchedByOffsetAndAnUnmatchedOneIsEmpty() {
        let f = Fixture()
        let model = ResultsViewModel(files: f.files, lostPartitions: [f.lost])
        let cache = PartitionSectionCache()
        let plan = model.recoverAllPlan(for: tree[1], devicePartitions: tree, cache: cache)
        #expect(plan.name == "Photos (exFAT)" && plan.files.map(\.id) == [f.live.id, f.deleted.id])
        let efi = model.recoverAllPlan(for: tree[0], devicePartitions: tree, cache: cache)
        #expect(efi.name == "EFI" && efi.files.isEmpty && efi.reconstructed.isEmpty)
    }

    // MARK: Sidebar

    @Test func contextMenuActionIsOnlyAvailableAfterAScanOfThatDrive() async {
        let container = DevicePartition(bsdName: "disk6s3", displayName: "APFS container", sizeBytes: 9, formatName: "APFS",
                                        children: [DevicePartition(bsdName: "disk9s1", displayName: "Data", sizeBytes: nil,
                                                                   formatName: "APFS")], offsetBytes: 64_000_000_000)
        let stick = BlockDevice(bsdName: "disk6", displayName: "SanDisk", sizeBytes: 64_000_000_000, isInternal: false,
                                isBootVolume: false, mediaIdentity: 6, partitions: tree + [container])
        let other = BlockDevice(bsdName: "disk7", displayName: "Other", sizeBytes: 1, isInternal: false, isBootVolume: false,
                                mediaIdentity: 7, partitions: [DevicePartition(bsdName: "disk7s1", displayName: "X", sizeBytes: 1,
                                                                               formatName: "exFAT", offsetBytes: 0)])
        let watcher = StaticWatcher(devices: [stick, other])
        let model = DeviceListViewModel(watcher: watcher)
        model.startWatching()
        for _ in 0..<50 where model.devices.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(model.devices.count == 2)

        // No finished scan: nothing offered.
        #expect(model.recoverAllTarget(for: tree[1]) == nil)
        // A finished scan of disk6 offers its partitions only; a container volume resolves to its container.
        model.finishedScanDevice = stick
        #expect(model.recoverAllTarget(for: tree[1]) == tree[1])
        #expect(model.recoverAllTarget(for: container.children[0]) == container)
        #expect(model.recoverAllTarget(for: other.partitions[0]) == nil)
        // The same name re-attached as a different drive doesn't qualify.
        model.finishedScanDevice = BlockDevice(bsdName: "disk6", displayName: "SanDisk", sizeBytes: 1, isInternal: false,
                                               isBootVolume: false, mediaIdentity: 99)
        #expect(model.recoverAllTarget(for: tree[1]) == nil)
        model.stopWatching()
    }

    @Test func finishedResultsDeviceComesFromTheScanOnlyOnceItEnded() async throws {
        let device = BlockDevice(bsdName: "disk6", displayName: "SanDisk", sizeBytes: 4096, isInternal: false,
                                 isBootVolume: false, mediaIdentity: 6, partitions: tree)
        let gate = Gate()
        let scan = ScanViewModel(runner: { run, events in
            await gate.wait()
            events.yield(.completed)
            await run.keepSource(SourceSession(device: run.device, reader: EmptyReader(), close: {}))
        })
        scan.start(device)
        #expect(scan.deviceWithFinishedResults == nil)
        await gate.open()
        for _ in 0..<200 where scan.isActive || scan.source == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(scan.state == .completed)
        #expect(scan.deviceWithFinishedResults == device)
    }

    // MARK: End to end on a real exFAT image

    @Test(.enabled(if: ExFATImage.isAvailable))
    func endToEndRecoversAWholeRealExFATPartitionByteForByte() async throws {
        guard let image = ExFATImage() else {
            print("Skipping: couldn't create or attach an exFAT disk image here.")
            return
        }
        defer { image.destroy() }
        var generator = SystemRandomNumberGenerator()
        func random(_ count: Int) -> Data { Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) }) }
        let live: [String: Data] = [
            "top.txt": Data("top level\n".utf8),
            "DCIM/100APPLE/IMG_0001.JPG": random(300_000),
            "DCIM/100APPLE/IMG_0002.JPG": random(70_001),
            "Documents/notes.txt": Data("nested notes\n".utf8),
            "Documents/Taxes/2025/return.pdf": random(150_000),
            "Documents/empty.txt": Data(),
        ]
        let doomed: [String: Data] = ["Documents/Taxes/old-return.pdf": random(40_000)]
        try image.populate(live: live, deleted: doomed)
        let bytes = try Data(contentsOf: image.imageURL)

        // Scan the image file (never a device node), exactly as the app scans a drive.
        let reader = DataReader(bytes: bytes)
        let (stream, continuation) = AsyncStream<ScanEvent>.makeStream()
        await ScanSession(reader: reader).run(events: continuation)
        var files: [RecoveredFile] = [], lost: [LostPartitionCandidate] = [], completed = false
        for await event in stream {
            switch event {
            case .found(let file): files.append(file)
            case .lostPartitionFound(let candidate): lost.append(candidate)
            case .completed: completed = true
            default: break
            }
        }
        #expect(completed)

        // The partition as the live device tree names it (its Base is read by `ioMediaBaseOffset`,
        // checked on a real image in SalvageDiskIO's tests).
        let partition = DevicePartition(bsdName: "disk99s1", displayName: "Photos", sizeBytes: image.partitionSize,
                                        formatName: "exFAT", offsetBytes: ExFATImage.partitionOffset)
        let model = ResultsViewModel(files: files, lostPartitions: lost)
        let cache = PartitionSectionCache()
        let summaries = model.partitionSummaries(devicePartitions: [partition], cache: cache)
        let photos = try #require(summaries.first { $0.key == .volume(ExFATImage.partitionOffset) })
        #expect(photos.name == "Photos (exFAT)" && photos.kind == .mapped)
        #expect(photos.deletedCount == 1)
        let plan = model.recoverAllPlan(for: photos, devicePartitions: [partition], cache: cache)

        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("SalvageE2E-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: destination) }
        let coordinator = RecoveryCoordinator(
            files: plan.files, content: FileContentReader(reader: reader), deviceName: "Disk Image", rootName: plan.name,
            reconstructedFiles: plan.reconstructed, sourceLabel: plan.name, now: { Date(timeIntervalSince1970: 0) },
            destinationCheck: { url in DestinationAssessment(verdict: .safe, mountSource: mountSourceName(ofPath: url.resolvingSymlinksInPath().path)) })
        await coordinator.chooseDestination(destination)
        coordinator.start()
        await coordinator.waitUntilFinished()
        guard case .finished(let summary) = coordinator.phase else { Issue.record("recovery didn't finish"); return }
        #expect(summary.failed.isEmpty, "\(summary.failed.map(\.reason))")
        #expect(summary.root.lastPathComponent == RecoveryCoordinator.rootFolderName(partition: "Photos (exFAT)", date: Date(timeIntervalSince1970: 0)))
        #expect(RecoverySummaryView.headline(summary, sourceName: coordinator.sourceLabel)
            .hasPrefix("Recovered \(live.count + doomed.count) of \(live.count + doomed.count) files from Photos (exFAT)"))

        print("E2E: \(RecoverySummaryView.headline(summary, sourceName: coordinator.sourceLabel)) into \(summary.root.lastPathComponent)")
        // Same folders, same files (live and deleted), byte for byte.
        let expected = live.merging(doomed) { first, _ in first }
        let recovered = regularFiles(under: summary.root).filter { !ResultsViewModel.isSystemFile(found("/" + $0, volume: 0)) }
        #expect(Set(recovered) == Set(expected.keys))
        for (path, data) in expected {
            #expect(try Data(contentsOf: summary.root.appendingPathComponent(path)) == data, "\(path) differs")
        }
        #expect(bytes == (try Data(contentsOf: image.imageURL)), "the source image changed")
    }
}

// MARK: - Helpers

private struct EmptyReader: BlockReader {
    var sizeBytes: Int64 { 0 }
    func read(at offset: Int64, count: Int) async throws -> Data { throw ScanError.io("empty") }
}

private struct DataReader: BlockReader {
    let bytes: Data
    var sizeBytes: Int64 { Int64(bytes.count) }
    func read(at offset: Int64, count: Int) async throws -> Data {
        guard offset >= 0, offset + Int64(count) <= sizeBytes else { throw ScanError.io("out of range") }
        return bytes.subdata(in: Int(offset)..<Int(offset) + count)
    }
}

private struct StaticWatcher: DeviceWatching {
    let devices: [BlockDevice]
    @MainActor func watch() async throws -> AsyncStream<[BlockDevice]> {
        AsyncStream { $0.yield(devices) }
    }
}

private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() { isOpen = true; waiters.forEach { $0.resume() }; waiters = [] }
}

private func regularFiles(under url: URL) -> [String] {
    let base = url.resolvingSymlinksInPath()
    let enumerator = FileManager.default.enumerator(atPath: base.path)
    var all: [String] = []
    while let item = enumerator?.nextObject() as? String {
        var info = stat()
        if lstat(base.appendingPathComponent(item).path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG { all.append(item) }
    }
    return all.sorted()
}

/// A GPT disk image with one exFAT partition named "Photos", created, attached (`-nobrowse`, at a
/// private mount point), populated and detached by the test itself, all inside its own temp
/// directory. The scan then reads the image file, never a device node.
private final class ExFATImage: @unchecked Sendable {
    static let hdiutil = "/usr/bin/hdiutil"
    static var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: hdiutil) && ProcessInfo.processInfo.environment["SALVAGE_SKIP_HDIUTIL"] == nil
    }
    /// hdiutil's GPTSPUD layout puts its single partition at 1 MiB.
    static let partitionOffset: Int64 = 1_048_576

    let base: URL
    let imageURL: URL
    let mountPoint: URL
    private(set) var partitionSize: Int64 = 0
    private var wholeDisk: String?

    init?() {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("SalvagePartitionE2E-\(UUID().uuidString)", isDirectory: true)
        imageURL = base.appendingPathComponent("photos.dmg")
        mountPoint = base.appendingPathComponent("mnt", isDirectory: true)
        do { try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true) } catch { return nil }
        guard Self.run(["create", "-quiet", "-size", "64m", "-fs", "ExFAT", "-volname", "Photos", "-layout", "GPTSPUD",
                        "-type", "UDIF", imageURL.path]).status == 0 else { destroy(); return nil }
        let attach = Self.run(["attach", "-nobrowse", "-noautoopen", "-mountpoint", mountPoint.path, "-plist", imageURL.path])
        if let plist = try? PropertyListSerialization.propertyList(from: attach.output, format: nil) as? [String: Any],
           let entities = plist["system-entities"] as? [[String: Any]] {
            wholeDisk = entities.compactMap { $0["dev-entry"] as? String }.min { $0.count < $1.count }
        }
        guard attach.status == 0, wholeDisk != nil else { destroy(); return nil }
    }

    /// Writes `live` and `deleted`, deletes `deleted`, and detaches so every change is on the image.
    func populate(live: [String: Data], deleted: [String: Data]) throws {
        for (path, data) in live.merging(deleted, uniquingKeysWith: { first, _ in first }) {
            let url = mountPoint.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        Self.sync()
        for path in deleted.keys { try FileManager.default.removeItem(at: mountPoint.appendingPathComponent(path)) }
        Self.sync()
        if let size = try? mountPoint.resourceValues(forKeys: [.volumeTotalCapacityKey]).volumeTotalCapacity { partitionSize = Int64(size) }
        detach()
    }

    func detach() {
        guard let whole = wholeDisk else { return }
        if Self.run(["detach", mountPoint.path]).status != 0 { _ = Self.run(["detach", "-force", whole]) }
        wholeDisk = nil
    }

    func destroy() {
        detach()
        try? FileManager.default.removeItem(at: base)
    }

    private static func sync() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sync")
        try? process.run()
        process.waitUntilExit()
    }

    private static func run(_ arguments: [String]) -> (status: Int32, output: Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: hdiutil)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return (-1, Data()) }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, output)
    }
}
