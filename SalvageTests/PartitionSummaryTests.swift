import CryptoKit
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
        // What a default run copies, then what the checkbox adds.
        #expect(photos.countsText == "2 files, of which 1 deleted (+1 reconstructed)")

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
        // Its display name already starts with its format: not "APFS container (APFS)".
        #expect(PartitionGrouping.name(forVolumeAt: 1_048_576, formatName: "APFS", partitions: apfs).name == "APFS container")
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
        // A finished scan of disk6 offers its partitions only; a container's volume is its own
        // target (its files carry its name and UUID), the container itself too.
        model.finishedScanDevice = stick
        #expect(model.recoverAllTarget(for: tree[1]) == tree[1])
        #expect(model.recoverAllTarget(for: container.children[0]) == container.children[0])
        #expect(model.recoverAllTarget(for: container) == container)
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

    // MARK: APFS volumes sharing a container

    @Test func apfsVolumesSharingAContainerAreSeparateGroupsThatRecoverOnlyTheirOwnFiles() async throws {
        let mine = apfs("/Documents/report.txt", volume: "Personal", id: personalID, record: 10_000, data: "mine")
        let mineGone = apfs("/Documents/old.txt", volume: "Personal", id: personalID, record: 11_000, data: "old", deleted: true)
        let theirs = apfs("/Documents/report.txt", volume: "Work", id: workID, record: 20_000, data: "theirs")
        let rebuilt = carved("jpeg-9.jpg", extent: containerOffset, start: containerOffset + 50_000)
        let model = ResultsViewModel(files: [mine, theirs, mineGone, rebuilt])
        let cache = PartitionSectionCache()
        let rows = model.partitionSummaries(devicePartitions: apfsTree, cache: cache)
        #expect(rows.map(\.key) == [.volume(containerOffset, volumeID: personalID), .volume(containerOffset, volumeID: workID),
                                    .volume(containerOffset)])
        #expect(rows.map(\.name) == ["Personal (APFS)", "Work (APFS)", "APFS container"])
        #expect(rows.map(\.recoverableCount) == [2, 1, 1] && rows[0].deletedCount == 1)
        #expect(!rows.contains { $0.name.contains("(APFS) (APFS)") || $0.name.hasSuffix("container (APFS)") })

        let personal = model.recoverAllPlan(for: rows[0], devicePartitions: apfsTree, cache: cache)
        let work = model.recoverAllPlan(for: rows[1], devicePartitions: apfsTree, cache: cache)
        #expect(personal.name == "Personal (APFS)" && personal.files.map(\.id) == [mine.id, mineGone.id] && personal.reconstructed.isEmpty)
        #expect(work.name == "Work (APFS)" && work.files.map(\.id) == [theirs.id])

        // The sidebar: a volume recovers only itself; the container recovers all of it.
        let container = apfsTree[0]
        #expect(model.recoverAllPlan(for: container.children[0], devicePartitions: apfsTree, cache: cache) == personal)
        #expect(model.recoverAllPlan(for: container.children[1], devicePartitions: apfsTree, cache: cache) == work)
        let whole = model.recoverAllPlan(for: container, devicePartitions: apfsTree, cache: cache)
        #expect(whole.name == "APFS container" && Set(whole.files.map(\.id)) == [mine.id, theirs.id, mineGone.id])
        #expect(whole.reconstructed.map(\.id) == [rebuilt.id])
        // Two volumes of one name are ambiguous: the container, never a guess.
        let twins = [DevicePartition(bsdName: "disk6s2", displayName: "APFS container", sizeBytes: 500_000_000, formatName: "APFS",
                                     children: [DevicePartition(bsdName: "disk7s1", displayName: "Personal", sizeBytes: nil, formatName: "APFS"),
                                                DevicePartition(bsdName: "disk7s2", displayName: "Work", sizeBytes: nil, formatName: "APFS")],
                                     offsetBytes: containerOffset)]
        let twinModel = ResultsViewModel(files: [mine, apfs("/x.txt", volume: "Personal", id: workID, record: 30_000, data: "x")])
        let fallback = twinModel.recoverAllPlan(for: twins[0].children[0], devicePartitions: twins, cache: PartitionSectionCache())
        #expect(fallback.name == "APFS container" && fallback.files.count == 2)

        // Each volume's recovery has its own folder tree: the shared path never becomes "report (2).txt".
        let destination = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: destination) }
        for plan in [personal, work] {
            let coordinator = RecoveryCoordinator(files: plan.files, content: FileContentReader(reader: EmptyReader()), deviceName: "Mac",
                                                  rootName: plan.name, reconstructedFiles: plan.reconstructed, sourceLabel: plan.name,
                                                  destinationCheck: safeCheck)
            await coordinator.chooseDestination(destination)
            coordinator.start()
            await coordinator.waitUntilFinished()
            guard case .finished(let summary) = coordinator.phase else { Issue.record("recovery didn't finish"); return }
            #expect(summary.failed.isEmpty && summary.written.count == plan.files.count)
            #expect(!regularFiles(under: summary.root).contains { $0.contains(" (2)") })
            let expected = plan.name == "Work (APFS)" ? "theirs" : "mine"
            #expect(try String(contentsOf: summary.root.appendingPathComponent("Documents/report.txt"), encoding: .utf8) == expected)
        }
    }

    // MARK: Carved-only areas

    @Test func aCarvedOnlyAreaRecoversItsReconstructedFilesByDefaultAndSaysSo() async throws {
        let bytes = Data((0..<16_384).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        let first = carved("jpeg-1.jpg", extent: 0, start: 4096), second = carved("png-1.png", extent: 0, start: 8192, size: 300)
        let model = ResultsViewModel(files: [first, second])
        let cache = PartitionSectionCache()
        let area = try #require(model.partitionSummaries(devicePartitions: [], cache: cache).first)
        #expect(area.key == .unpartitioned && area.canRecoverAll)
        // The count is what a default run copies.
        #expect(area.countsText == "2 reconstructed files")
        let plan = model.recoverAllPlan(for: area, devicePartitions: [], cache: cache)
        #expect(plan.files.isEmpty && plan.reconstructed.map(\.id) == [first.id, second.id])

        let destination = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: destination) }
        let coordinator = RecoveryCoordinator(files: plan.files, content: FileContentReader(reader: DataReader(bytes: bytes)),
                                              deviceName: "Drive", rootName: plan.name, reconstructedFiles: plan.reconstructed,
                                              sourceLabel: plan.name, destinationCheck: safeCheck)
        #expect(coordinator.includeReconstructed && coordinator.files.count == 2 && coordinator.totalBytes == 400)
        #expect(coordinator.contentsNote?.hasPrefix("This area only has reconstructed files") == true)
        await coordinator.chooseDestination(destination)
        #expect(coordinator.canRecover)
        coordinator.start()
        await coordinator.waitUntilFinished()
        guard case .finished(let summary) = coordinator.phase else { Issue.record("recovery didn't finish"); return }
        #expect(summary.written.count == 2 && summary.failed.isEmpty)
        #expect(try Data(contentsOf: summary.root.appendingPathComponent("Reconstructed/Pictures/png-1.png")) == bytes.subdata(in: 8192..<8492))
    }

    @Test func countsTextMatchesWhatADefaultRunCopies() {
        var summary = PartitionSummary(key: .volume(0), kind: .mapped, name: "X", sizeBytes: nil)
        summary.recoverableCount = 12; summary.deletedCount = 3; summary.reconstructedCount = 2
        #expect(summary.countsText == "10 files, of which 3 deleted (+2 reconstructed)")
        summary.reconstructedCount = 0
        #expect(summary.countsText == "12 files, of which 3 deleted")
        summary.recoverableCount = 1; summary.deletedCount = 0; summary.reconstructedCount = 1
        #expect(summary.countsText == "1 reconstructed file")
    }

    // MARK: Unknown offsets and skipped volumes

    @Test func aPartitionWithAnUnknownOffsetIsMatchedByFormatAndSize() {
        let f = Fixture()
        let unplaced = [DevicePartition(bsdName: "disk6s1", displayName: "EFI", sizeBytes: 209_715_200, formatName: "EFI"),
                        DevicePartition(bsdName: "disk6s2", displayName: "Photos", sizeBytes: 63_790_000_000, formatName: "exFAT"),
                        DevicePartition(bsdName: "disk6s3", displayName: "Backup", sizeBytes: 4_000_000_000, formatName: "exFAT")]
        let other = found("/b/x.bin", volume: 80_000_000_000)
        let context = PartitionScanContext(extents: [.init(offset: photosOffset, length: 63_790_000_000),
                                                     .init(offset: 80_000_000_000, length: 4_000_000_000)])
        let model = ResultsViewModel(files: [f.live, f.deleted, other])
        let cache = PartitionSectionCache()
        let rows = model.partitionSummaries(devicePartitions: unplaced, context: context, cache: cache)
        #expect(rows.map(\.name) == ["Photos (exFAT)", "Backup (exFAT)"])
        let photos = model.recoverAllPlan(for: unplaced[1], devicePartitions: unplaced, context: context, cache: cache)
        #expect(photos.name == "Photos (exFAT)" && photos.files.map(\.id) == [f.live.id, f.deleted.id])
        let backup = model.recoverAllPlan(for: unplaced[2], devicePartitions: unplaced, context: context, cache: cache)
        #expect(backup.files.map(\.id) == [other.id])
        #expect(model.recoverAllPlan(for: unplaced[0], devicePartitions: unplaced, context: context, cache: cache).files.isEmpty)

        // Without the scan's extents (sizes unknown), the only exFAT partition is still its match...
        let single = [unplaced[1]]
        let lone = ResultsViewModel(files: [f.live, f.deleted])
        #expect(lone.recoverAllPlan(for: single[0], devicePartitions: single, cache: PartitionSectionCache()).files.count == 2)
        // ...but two exFAT partitions of unknown size and offset are ambiguous: nothing is guessed.
        let ambiguous = model.recoverAllPlan(for: unplaced[1], devicePartitions: unplaced, cache: PartitionSectionCache())
        #expect(ambiguous.files.isEmpty && ambiguous.name == "Photos (exFAT)")
    }

    @Test func carvesFromASkippedVolumeBelongToIt() {
        let skippedOffset: Int64 = 5_242_880
        let fromSweep = carved("jpeg-5.jpg", extent: skippedOffset, start: skippedOffset + 4096)
        let fromRawSweep = carved("jpeg-6.jpg", extent: 0, start: skippedOffset + 8192)
        let outside = carved("jpeg-7.jpg", extent: 0, start: 512)
        let rows = [fromSweep, fromRawSweep, outside].map(ResultsViewModel.Row.init)
        // Without the scan's notices, the skipped volume is unknown: its carves look unpartitioned.
        #expect(PartitionGrouping.keys(for: rows, partitions: [], lostPartitions: []) == [.unpartitioned, .unpartitioned, .unpartitioned])
        let context = PartitionScanContext(
            notices: [.volumeSkipped(formatName: "NTFS", offset: skippedOffset, reason: "damaged"), .carvingLimitReached(count: 9)],
            extents: [.init(offset: 0, length: 1_048_576), .init(offset: skippedOffset, length: 1_000_000)], isIncomplete: false)
        let keys = PartitionGrouping.keys(for: rows, partitions: [], lostPartitions: [], context: context)
        // The whole-device extent at 0 is not a volume, so its carve outside the skipped one stays unpartitioned.
        #expect(keys == [.volume(skippedOffset), .volume(skippedOffset), .unpartitioned])
        let summaries = PartitionGrouping.summaries(rows: rows, keys: keys, partitions: [], lostPartitions: [],
                                                    includingSystemFiles: false, context: context)
        #expect(summaries.first?.name == "NTFS volume at \(ByteCountFormatter.string(fromByteCount: skippedOffset, countStyle: .file))")
        #expect(summaries.first?.sizeBytes == 1_000_000 && summaries.first?.reconstructedCount == 2)
        #expect(summaries.first?.countsText == "2 reconstructed files")
    }

    @Test func theScanContextComesFromItsNoticesCheckpointAndEnd() async throws {
        let device = BlockDevice(bsdName: "disk6", displayName: "SanDisk", sizeBytes: 4096, isInternal: false,
                                 isBootVolume: false, mediaIdentity: 6, partitions: tree)
        let checkpoint = ScanCheckpoint(deviceSizeBytes: 4096, totalBytes: 4096, extents: [.init(offset: 1024, length: 2048)],
                                        sweepVolumeIndex: 0, sweepOffset: 0, bytesScanned: 0)
        let scan = ScanViewModel(runner: { run, events in
            run.notices.yield(.volumeSkipped(formatName: "exFAT", offset: 1024, reason: "damaged"))
            run.checkpoints.yield(checkpoint)
            events.yield(.found(carved("jpeg-1.jpg", extent: 1024, start: 2048)))
            events.yield(.error(.io("unplugged")))
            await run.keepSource(SourceSession(device: run.device, reader: EmptyReader(), close: {}))
        })
        scan.start(device)
        for _ in 0..<300 where scan.isActive || scan.source == nil { try await Task.sleep(for: .milliseconds(10)) }
        guard case .failed = scan.state else { Issue.record("expected a failed scan, got \(scan.state)"); return }
        let context = scan.partitionScanContext
        #expect(context.isIncomplete)
        #expect(context.skippedVolumes == [.init(offset: 1024, formatName: "exFAT")])
        #expect(context.extents == [.init(offset: 1024, length: 2048)])
    }

    // MARK: Naming at the drive's first byte, unfinished scans

    @Test func aWholeDriveFilesystemIsNamedAsSuch() {
        #expect(PartitionGrouping.name(forVolumeAt: 0, formatName: "exFAT", partitions: []).name == "exFAT volume (whole drive)")
        let model = ResultsViewModel(files: [found("/a.txt", volume: 0)])
        #expect(model.partitionSummaries(devicePartitions: [], cache: PartitionSectionCache()).map(\.name) == ["exFAT volume (whole drive)"])
    }

    @Test func anUnfinishedScanOffersTheFilesFoundSoFar() {
        let f = Fixture()
        let model = ResultsViewModel(files: f.files, lostPartitions: [f.lost])
        let done = model.partitionSummaries(devicePartitions: tree, cache: PartitionSectionCache())
        #expect(done.allSatisfy { $0.recoverAllTitle == "Recover all files…" && !$0.isScanIncomplete })
        let cache = PartitionSectionCache()
        let cut = model.partitionSummaries(devicePartitions: tree, context: PartitionScanContext(isIncomplete: true), cache: cache)
        #expect(cut.allSatisfy { $0.recoverAllTitle == "Recover all files found so far…" })
        #expect(cut[1].recoverAllAccessibilityLabel == "Recover all files found so far from Photos (exFAT)")
        let plan = model.recoverAllPlan(for: cut[1], devicePartitions: tree, context: PartitionScanContext(isIncomplete: true), cache: cache)
        #expect(plan.scanIncomplete)
        let sidebar = model.recoverAllPlan(for: tree[1], devicePartitions: tree, context: PartitionScanContext(isIncomplete: true), cache: cache)
        #expect(sidebar.scanIncomplete && sidebar.files.count == 2)
    }

    // MARK: End to end on a real exFAT image

    /// Real-image runs fail rather than silently pass when they can't run, unless
    /// SALVAGE_SKIP_HDIUTIL is set; with SALVAGE_REQUIRE_HDIUTIL=1 (CI) even that is an issue.
    @Test func realImageTestReportsWhyItIsSkipped() {
        guard let reason = ExFATImage.skipReason else { return }
        print("Partition E2E real-image test skipped: \(reason)")
        if ProcessInfo.processInfo.environment["SALVAGE_REQUIRE_HDIUTIL"] == "1" {
            Issue.record("SALVAGE_REQUIRE_HDIUTIL=1 but the partition E2E real-image test can't run: \(reason)")
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SALVAGE_SKIP_HDIUTIL"] == nil))
    func endToEndRecoversAWholeRealExFATPartitionByteForByte() async throws {
        guard ExFATImage.hdiutilExists, let image = ExFATImage() else {
            Issue.record("Couldn't create or attach an exFAT disk image here (set SALVAGE_SKIP_HDIUTIL=1 to skip).")
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
        let digestBefore = try sha256(of: image.imageURL)

        // Scan the image file itself (never a device node) through a read-only file descriptor,
        // exactly as the app scans a drive through its reader.
        let reader = try FileReader(url: image.imageURL)
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

        // The real destination check: the image, attached read-only and unmounted, is the source drive.
        let sourceDisk = try #require(image.attachReadOnly(), "couldn't attach the image read-only")
        let source = BlockDevice(bsdName: sourceDisk, displayName: "Disk Image", sizeBytes: reader.sizeBytes,
                                 isInternal: false, isBootVolume: false)
        let destination = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: destination) }
        #expect(DestinationSafety.live.check(destination: destination, source: source) == .safe)
        // And it blocks a destination on the drive being recovered (here, the temp folder's own drive).
        if let mounted = mountSourceName(ofPath: destination.resolvingSymlinksInPath().path), let whole = wholeDisk(of: mounted) {
            let host = BlockDevice(bsdName: whole, displayName: "Host", sizeBytes: 1, isInternal: true, isBootVolume: false)
            let blocked = RecoveryCoordinator(files: plan.files, content: FileContentReader(reader: reader), deviceName: "Host",
                                              rootName: plan.name, sourceLabel: plan.name,
                                              destinationCheck: { DestinationSafety.live.assess(destination: $0, source: host) })
            await blocked.chooseDestination(destination)
            #expect(blocked.destinationStatus == .blocked && !blocked.canRecover)
        }

        let coordinator = RecoveryCoordinator(
            files: plan.files, content: FileContentReader(reader: reader), deviceName: "Disk Image", rootName: plan.name,
            reconstructedFiles: plan.reconstructed, sourceLabel: plan.name, now: { Date(timeIntervalSince1970: 0) },
            destinationCheck: { DestinationSafety.live.assess(destination: $0, source: source) })
        await coordinator.chooseDestination(destination)
        #expect(coordinator.destinationStatus == .safe)
        coordinator.start()
        await coordinator.waitUntilFinished()
        image.detach()
        guard case .finished(let summary) = coordinator.phase else { Issue.record("recovery didn't finish: \(coordinator.phase)"); return }
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
        #expect(try sha256(of: image.imageURL) == digestBefore, "the source image changed")
    }
}

// MARK: - Helpers

private let containerOffset: Int64 = 1_048_576
private let personalID = "11111111-2222-3333-4444-555555555555"
private let workID = "66666666-7777-8888-9999-AAAAAAAAAAAA"
private let apfsTree = [
    DevicePartition(bsdName: "disk6s2", displayName: "APFS container", sizeBytes: 500_000_000, formatName: "APFS",
                    children: [DevicePartition(bsdName: "disk7s1", displayName: "Personal", sizeBytes: nil, formatName: "APFS"),
                               DevicePartition(bsdName: "disk7s2", displayName: "Work", sizeBytes: nil, formatName: "APFS")],
                    offsetBytes: containerOffset),
]

/// A file of one volume inside the synthetic two-volume APFS container, as `APFSContainer` emits it.
private func apfs(_ path: String, volume: String, id: String, record: Int64, data: String, deleted: Bool = false) -> RecoveredFile {
    RecoveredFile(name: (path as NSString).lastPathComponent, path: path, sizeBytes: Int64(data.utf8.count), isDeleted: deleted,
                  sourceMetadata: SourceMetadata(filesystem: .apfs, volumeOffset: containerOffset, recordOffset: containerOffset + record,
                                                 allocationStart: 18, contiguous: true, rawRecord: Data(),
                                                 volumeName: volume, volumeID: id),
                  content: .resident(Data(data.utf8)))
}

private let safeCheck: @Sendable (URL) -> DestinationAssessment = { url in
    DestinationAssessment(verdict: .safe, mountSource: mountSourceName(ofPath: url.resolvingSymlinksInPath().path))
}

private func temporaryFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("SalvagePartition-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// "disk3" from "/dev/disk3s5".
private func wholeDisk(of mountSource: String) -> String? {
    guard let range = mountSource.range(of: #"disk[0-9]+"#, options: .regularExpression) else { return nil }
    return String(mountSource[range])
}

private func sha256(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

/// Reads an image file through a read-only descriptor with `pread`, like a drive's reader.
private final class FileReader: BlockReader, @unchecked Sendable {
    private let fd: Int32
    let sizeBytes: Int64
    init(url: URL) throws {
        fd = open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw ScanError.io("open failed") }
        var info = stat()
        guard fstat(fd, &info) == 0 else { close(fd); throw ScanError.io("fstat failed") }
        sizeBytes = Int64(info.st_size)
    }
    deinit { close(fd) }
    func read(at offset: Int64, count: Int) async throws -> Data {
        guard offset >= 0, count >= 0, offset + Int64(count) <= sizeBytes else { throw ScanError.io("out of range") }
        var data = Data(count: count)
        let got = data.withUnsafeMutableBytes { raw -> Int in
            var done = 0
            while done < count {
                let n = pread(fd, raw.baseAddress! + done, count - done, off_t(offset) + off_t(done))
                if n < 0 { if errno == EINTR { continue }; return -1 }
                if n == 0 { break }
                done += n
            }
            return done
        }
        guard got == count else { throw ScanError.io("short read") }
        return data
    }
}

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
    static var hdiutilExists: Bool { FileManager.default.isExecutableFile(atPath: hdiutil) }
    /// Why the real-image test can't run here, or nil when it can.
    static var skipReason: String? {
        if ProcessInfo.processInfo.environment["SALVAGE_SKIP_HDIUTIL"] != nil { return "SALVAGE_SKIP_HDIUTIL is set" }
        return hdiutilExists ? nil : "\(hdiutil) is not executable"
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

    /// Attaches the image again, read-only and unmounted, for the destination check's source
    /// drive; returns its whole disk ("disk12"). `detach()` detaches it.
    func attachReadOnly() -> String? {
        detach()
        let attach = Self.run(["attach", "-readonly", "-nomount", "-nobrowse", "-noautoopen", "-noverify", "-plist", imageURL.path])
        guard attach.status == 0,
              let plist = try? PropertyListSerialization.propertyList(from: attach.output, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]],
              let whole = entities.compactMap({ $0["dev-entry"] as? String }).min(by: { $0.count < $1.count }) else { return nil }
        wholeDisk = whole
        return (whole as NSString).lastPathComponent
    }

    func detach() {
        guard let whole = wholeDisk else { return }
        if Self.run(["detach", whole]).status != 0 { _ = Self.run(["detach", "-force", whole]) }
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
