import CryptoKit
import Foundation
import SalvageCore
import SalvageDiskIO
import Testing
@testable import Salvage

/// In-memory device. Reads at `failAt` throw; reads at `blockAt` wait until the task is cancelled;
/// `onRead` runs before every read (tests use it to change the destination mid-run).
private struct MemoryReader: BlockReader {
    let bytes: Data
    var failAt: Int64? = nil
    var blockAt: Int64? = nil
    var onRead: (@Sendable (Int64) -> Void)? = nil
    var sizeBytes: Int64 { Int64(bytes.count) }
    func read(at offset: Int64, count: Int) async throws -> Data {
        onRead?(offset)
        if offset == failAt { throw ScanError.io("injected") }
        if offset == blockAt {
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            throw CancellationError()
        }
        return bytes.subdata(in: Int(offset)..<Int(offset) + count)
    }
}

private let metadata = SourceMetadata(filesystem: .fat32, volumeOffset: 0, recordOffset: 0,
                                      allocationStart: 2, contiguous: false, rawRecord: Data())

private func file(_ path: String, name: String? = nil, size: Int64, content: FileContent, modified: Date? = nil) -> RecoveredFile {
    RecoveredFile(name: name ?? (path as NSString).lastPathComponent, path: path, sizeBytes: size,
                  modified: modified, sourceMetadata: metadata, content: content)
}

/// A fresh directory under the system temporary directory; tests never write anywhere else.
private final class TempDir {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SalvageRecoveryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
    /// Relative paths of the regular files (not folders or links) under this directory.
    func regularFiles() -> [String] { Self.regularFiles(under: url) }
    static func regularFiles(under url: URL) -> [String] {
        let base = url.resolvingSymlinksInPath()
        let enumerator = FileManager.default.enumerator(atPath: base.path)
        var all: [String] = []
        while let item = enumerator?.nextObject() as? String { all.append(item) }
        return all.sorted().filter { relative in
            var info = stat()
            return lstat(base.appendingPathComponent(relative).path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
        }
    }
    func allFiles() -> [String] {
        let base = url.resolvingSymlinksInPath().path
        let enumerator = FileManager.default.enumerator(atPath: base)
        var out: [String] = []
        while let item = enumerator?.nextObject() as? String { out.append(item) }
        return out.sorted()
    }
}

private func deviceBytes(_ count: Int) -> Data { Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }) }

/// A destination check with a fixed verdict, reporting the real volume of the checked path (so the
/// engine's `fstatfs` confirmation of the opened folder passes).
private func checked(_ verdict: DestinationVerdict) -> @Sendable (URL) -> DestinationAssessment {
    { url in DestinationAssessment(verdict: verdict, mountSource: mountSourceName(ofPath: url.resolvingSymlinksInPath().path)) }
}

@MainActor
private func recover(_ files: [RecoveredFile], reader: MemoryReader, into dir: TempDir, chunk: Int = 512,
                     verdict: DestinationVerdict = .safe) async -> RecoveryCoordinator {
    await recover(files, reader: reader, into: dir.url, chunk: chunk, verdict: verdict)
}

@MainActor
private func recover(_ files: [RecoveredFile], reader: MemoryReader, into url: URL, chunk: Int = 512,
                     verdict: DestinationVerdict = .safe,
                     sync: (@Sendable (Int32) -> Int32?)? = nil) async -> RecoveryCoordinator {
    let coordinator = RecoveryCoordinator(files: files, content: FileContentReader(reader: reader, chunkSize: chunk),
                                          deviceName: "Fixture", now: { Date(timeIntervalSince1970: 0) },
                                          sync: sync, destinationCheck: checked(verdict))
    coordinator.setSaveReport(false)  // these tests check exact folder contents; RecoveryReportTests covers the report
    await coordinator.chooseDestination(url)
    coordinator.start()
    await coordinator.waitUntilFinished()
    return coordinator
}

@MainActor private func summary(_ coordinator: RecoveryCoordinator) -> RecoverySummary? {
    if case .finished(let summary) = coordinator.phase { return summary }
    return nil
}

@MainActor @Suite("Recovery to a safe destination")
struct RecoveryCoordinatorTests {
    @Test func writesByteIdenticalCopiesWithHashAndModificationDate() async throws {
        let dir = try TempDir()
        let device = deviceBytes(8192)
        let modified = Date(timeIntervalSince1970: 1_600_000_000)
        let fragmented = file("/DCIM/100/photo.jpg", size: 2500, content: .runs([
            DataRun(deviceOffset: 4096, length: 1024), DataRun(deviceOffset: nil, length: 512),
            DataRun(deviceOffset: 1024, length: 2048)]), modified: modified)
        let resident = file("/notes.txt", size: 5, content: .resident(Data("hello world".utf8)))
        let coordinator = await recover([fragmented, resident], reader: MemoryReader(bytes: device), into: dir)
        let result = try #require(summary(coordinator))

        #expect(result.written.count == 2 && result.failed.isEmpty && !result.cancelled)
        #expect(result.bytesWritten == 2505)
        #expect(result.root.lastPathComponent == RecoveryCoordinator.rootFolderName(device: "Fixture", date: Date(timeIntervalSince1970: 0)))
        #expect(result.root.lastPathComponent.hasPrefix("Salvage Recovery Fixture "))
        var expected = device.subdata(in: 4096..<5120)
        expected.append(Data(count: 512))
        expected.append(device.subdata(in: 1024..<1988))
        let photo = result.root.appendingPathComponent("DCIM/100/photo.jpg")
        #expect(try Data(contentsOf: photo) == expected)
        #expect(result.written[0].sha256 == SHA256.hash(data: expected).map { String(format: "%02x", $0) }.joined())
        #expect(try Data(contentsOf: result.root.appendingPathComponent("notes.txt")) == Data("hello".utf8))
        let attributes = try FileManager.default.attributesOfItem(atPath: photo.path)
        #expect((attributes[.modificationDate] as? Date) == modified)
        #expect(!dir.allFiles().contains { $0.hasSuffix(".partial") })
    }

    @Test func hostileNamesStayInsideTheRecoveryFolder() async throws {
        let dir = try TempDir()
        let reader = MemoryReader(bytes: deviceBytes(1024))
        let one = FileContent.resident(Data("x".utf8))
        let files = [
            file("/../../../escape.txt", size: 1, content: one),
            file("/a/../../b/./c.txt", size: 1, content: one),
            file("/dir/evil", name: "../evil", size: 1, content: one),
            file("/x:y/na\u{0}me:z", name: "na\u{0}me:z", size: 1, content: one),
            file("/.hidden/.profile", size: 1, content: one),
            file("/..", name: "..", size: 1, content: one),
        ]
        let coordinator = await recover(files, reader: reader, into: dir)
        let result = try #require(summary(coordinator))
        #expect(result.written.count == files.count)
        // Judge by what is actually on disk, not by the URLs the engine reports.
        let rootName = result.root.lastPathComponent
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.url.path) == [rootName])
        let regular = dir.regularFiles()
        #expect(regular.count == files.count)
        #expect(regular.allSatisfy { $0.hasPrefix(rootName + "/") })
        let names = Set(regular.map { String($0.dropFirst(rootName.count + 1)) })
        // The ".." file becomes "_", which the "_" folder from the traversal path already holds.
        #expect(names == ["_/_/_/escape.txt", "a/_/_/b/_/c.txt", "dir/evil", "xy/namez", "hidden/profile", "_ (2)"])
        #expect(!dir.allFiles().contains { ($0 as NSString).lastPathComponent.hasPrefix(".") })
    }

    @Test func collisionsGetNumberedSuffixesAndNeverOverwrite() async throws {
        let dir = try TempDir()
        // An existing folder with the root's name must be left alone.
        let rootName = RecoveryCoordinator.rootFolderName(device: "Fixture", date: Date(timeIntervalSince1970: 0))
        let existing = dir.url.appendingPathComponent(rootName)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: existing.appendingPathComponent("a.txt"))

        let files = [
            file("/a.txt", size: 1, content: .resident(Data("1".utf8))),
            file("/a.txt", size: 1, content: .resident(Data("2".utf8))),
            file("/a.txt", size: 1, content: .resident(Data("3".utf8))),
            file("/b", size: 1, content: .resident(Data("f".utf8))),      // a file named b...
            file("/b/c.txt", size: 1, content: .resident(Data("d".utf8))), // ...then a folder named b
        ]
        let coordinator = await recover(files, reader: MemoryReader(bytes: Data()), into: dir)
        let result = try #require(summary(coordinator))
        #expect(result.root.lastPathComponent == rootName + " (2)")
        #expect(try Data(contentsOf: existing.appendingPathComponent("a.txt")) == Data("keep".utf8))
        let root = result.root
        #expect(try Data(contentsOf: root.appendingPathComponent("a.txt")) == Data("1".utf8))
        #expect(try Data(contentsOf: root.appendingPathComponent("a (2).txt")) == Data("2".utf8))
        #expect(try Data(contentsOf: root.appendingPathComponent("a (3).txt")) == Data("3".utf8))
        #expect(try Data(contentsOf: root.appendingPathComponent("b")) == Data("f".utf8))
        #expect(try Data(contentsOf: root.appendingPathComponent("b (2)/c.txt")) == Data("d".utf8))
    }

    @Test func partialFailureRecordsReasonsAndContinues() async throws {
        let dir = try TempDir()
        let reader = MemoryReader(bytes: deviceBytes(4096), failAt: 2048)
        let files = [
            file("/ok1.bin", size: 512, content: .runs([DataRun(deviceOffset: 0, length: 512)])),
            file("/unmapped.bin", size: 100, content: .unmapped),
            file("/unreadable.bin", size: 1024, content: .runs([DataRun(deviceOffset: 1536, length: 1024)])),
            file("/short.bin", size: 4096, content: .runs([DataRun(deviceOffset: 0, length: 100)])),
            file("/ok2.bin", size: 512, content: .runs([DataRun(deviceOffset: 512, length: 512)])),
        ]
        let coordinator = await recover(files, reader: reader, into: dir)
        let result = try #require(summary(coordinator))
        #expect(result.written.map(\.sourcePath) == ["/ok1.bin", "/ok2.bin"])
        #expect(result.bytesWritten == 1024)
        #expect(result.failed.map(\.name) == ["unmapped.bin", "unreadable.bin", "short.bin"])
        #expect(result.failed[0].reason == RecoveryEngine.CopyFailure.unmapped.reason)
        #expect(result.failed[1].reason == RecoveryEngine.CopyFailure.sourceRead.reason)
        #expect(result.failed[2].reason == RecoveryEngine.CopyFailure.damagedMapping.reason)
        #expect(result.notAttempted == 0 && !result.cancelled)
        let leftovers = dir.allFiles().map { ($0 as NSString).lastPathComponent }
        #expect(!leftovers.contains { $0.hasSuffix(".partial") || $0.hasPrefix("unreadable") || $0.hasPrefix("unmapped") })
    }

    @Test func cancellationKeepsFinishedFilesAndCleansUpTheCurrentOne() async throws {
        let dir = try TempDir()
        let reader = MemoryReader(bytes: deviceBytes(8192), blockAt: 3072)
        let files = [
            file("/done.bin", size: 1024, content: .runs([DataRun(deviceOffset: 0, length: 1024)])),
            file("/stuck.bin", size: 2048, content: .runs([DataRun(deviceOffset: 2560, length: 2048)])),
            file("/never.bin", size: 512, content: .runs([DataRun(deviceOffset: 0, length: 512)])),
        ]
        let coordinator = RecoveryCoordinator(files: files, content: FileContentReader(reader: reader, chunkSize: 512),
                                              deviceName: "Fixture", destinationCheck: checked(.safe))
        await coordinator.chooseDestination(dir.url)
        coordinator.start()
        while coordinator.progress.currentName != "stuck.bin" || coordinator.progress.bytesDone < 1536 {
            try await Task.sleep(for: .milliseconds(5))
        }
        coordinator.cancel()
        await coordinator.waitUntilFinished()
        let result = try #require(summary(coordinator))
        #expect(result.cancelled)
        #expect(result.written.map(\.sourcePath) == ["/done.bin"])
        #expect(result.failed.isEmpty && result.notAttempted == 2)
        let names = dir.allFiles().map { ($0 as NSString).lastPathComponent }
        #expect(names.contains("done.bin"))
        #expect(!names.contains { $0.hasSuffix(".partial") || $0.hasPrefix("stuck") || $0.hasPrefix("never") })
    }

    @Test func unsafeOrUnknownDestinationBlocksRecoveryAndWritesNothing() async throws {
        for verdict in [DestinationVerdict.sameDevice, .undetermined] {
            let dir = try TempDir()
            let files = [file("/a.txt", size: 1, content: .resident(Data("a".utf8)))]
            let coordinator = RecoveryCoordinator(files: files, content: FileContentReader(reader: MemoryReader(bytes: Data())),
                                                  deviceName: "Fixture", destinationCheck: checked(verdict))
            await coordinator.chooseDestination(dir.url)
            #expect(coordinator.destinationStatus == .blocked)
            #expect(!coordinator.canRecover)
            coordinator.start()
            await coordinator.waitUntilFinished()
            #expect(coordinator.phase == .ready)
            #expect(dir.allFiles().isEmpty)
        }
    }

    @Test func destinationThatBecomesUnsafeBeforeWritingIsRechecked() async throws {
        let dir = try TempDir()
        let calls = Counter()
        let files = [file("/a.txt", size: 1, content: .resident(Data("a".utf8)))]
        let coordinator = RecoveryCoordinator(files: files, content: FileContentReader(reader: MemoryReader(bytes: Data())),
                                              deviceName: "Fixture",
                                              destinationCheck: { url in checked(calls.next() == 1 ? .safe : .sameDevice)(url) })
        await coordinator.chooseDestination(dir.url)
        #expect(coordinator.canRecover)
        coordinator.start()
        await coordinator.waitUntilFinished()
        #expect(coordinator.destinationStatus == .blocked && coordinator.phase == .ready)
        #expect(dir.allFiles().isEmpty)
    }

    @Test func existingSymlinkIsNeverFollowed() throws {
        let dir = try TempDir()
        let outside = try TempDir()
        try FileManager.default.createSymbolicLink(at: dir.url.appendingPathComponent("link"), withDestinationURL: outside.url)
        let parent = open(dir.url.path, O_RDONLY | O_DIRECTORY)
        defer { close(parent) }
        guard case .success(let (fd, name)) = RecoveryEngine.makeDirectory(in: parent, named: "link", reuseExisting: true) else {
            Issue.record("expected a fresh directory"); return
        }
        close(fd)
        #expect(name == "link (2)")
        #expect(outside.allFiles().isEmpty)
    }

    @Test func sanitizesComponents() {
        #expect(RecoveryPaths.sanitize("..") == "_")
        #expect(RecoveryPaths.sanitize(".") == "_")
        #expect(RecoveryPaths.sanitize("") == "_")
        #expect(RecoveryPaths.sanitize("...") == "_")
        #expect(RecoveryPaths.sanitize("..secret") == "secret")
        #expect(RecoveryPaths.sanitize("a/b:c\u{0}d") == "abcd")
        #expect(RecoveryPaths.sanitize("tab\there") == "tabhere")
        let long = String(repeating: "é", count: 300) + ".jpeg"
        let short = RecoveryPaths.sanitize(long)
        #expect(short.utf8.count <= RecoveryPaths.maxComponentBytes && short.hasSuffix(".jpeg"))
        #expect(RecoveryPaths.candidate("a.tar.gz", attempt: 2, isDirectory: false) == "a.tar (2).gz")
        #expect(RecoveryPaths.candidate("v1.2", attempt: 3, isDirectory: true) == "v1.2 (3)")
    }

    @Test func sanitizeStripsLeadingCombiningAndInvisibleCharacters() {
        #expect(RecoveryPaths.sanitize("\u{301}x") == "x")
        #expect(RecoveryPaths.sanitize(".\u{301}hidden") == "hidden")   // a dot hidden in one grapheme
        #expect(RecoveryPaths.sanitize("\u{200B}.profile") == "profile")
        #expect(RecoveryPaths.sanitize("\u{FEFF}\u{20DD}") == "_")
        #expect(RecoveryPaths.sanitize("e\u{301}t\u{200B}e") == "e\u{301}t\u{200B}e")  // only leading ones go
        #expect(RecoveryPaths.partialName(for: String(repeating: "e\u{301}", count: 100)).utf8.count < 80)
    }

    // MARK: Start failure and retry

    @Test func startFailureAllowsChoosingAnotherDestinationAndRetrying() async throws {
        let dir = try TempDir()
        let missing = dir.url.appendingPathComponent("gone", isDirectory: true)
        let files = [file("/a.txt", size: 1, content: .resident(Data("a".utf8)))]
        let coordinator = RecoveryCoordinator(files: files, content: FileContentReader(reader: MemoryReader(bytes: Data())),
                                              deviceName: "Fixture", destinationCheck: checked(.safe))
        await coordinator.chooseDestination(missing)
        coordinator.start()
        await coordinator.waitUntilFinished()
        guard case .failedToStart(let reason) = coordinator.phase else { Issue.record("expected a start failure"); return }
        #expect(reason == RecoveryEngine.describe(errno: ENOENT))

        // Retrying the same folder once it exists works...
        try FileManager.default.createDirectory(at: missing, withIntermediateDirectories: true)
        #expect(coordinator.canRecover)
        coordinator.start()
        await coordinator.waitUntilFinished()
        #expect(summary(coordinator)?.written.count == 1)

        // ...and so does choosing a different folder after a failure, which resets to ready.
        let again = RecoveryCoordinator(files: files, content: FileContentReader(reader: MemoryReader(bytes: Data())),
                                        deviceName: "Fixture", destinationCheck: checked(.safe))
        await again.chooseDestination(dir.url.appendingPathComponent("also-gone"))
        again.start()
        await again.waitUntilFinished()
        if case .failedToStart = again.phase {} else { Issue.record("expected a start failure") }
        let other = try TempDir()
        await again.chooseDestination(other.url)
        #expect(again.phase == .ready && again.destination == other.url && again.canRecover)
        again.start()
        await again.waitUntilFinished()
        #expect(summary(again)?.written.count == 1)
    }

    // MARK: The opened folder must be on the checked volume

    @Test func openedFolderOnAnotherVolumeThanCheckedIsBlocked() async throws {
        let dir = try TempDir()
        let files = [file("/a.txt", size: 1, content: .resident(Data("a".utf8)))]
        let coordinator = RecoveryCoordinator(files: files, content: FileContentReader(reader: MemoryReader(bytes: Data())),
                                              deviceName: "Fixture",
                                              destinationCheck: { _ in DestinationAssessment(verdict: .safe, mountSource: "/dev/disk999s9") })
        await coordinator.chooseDestination(dir.url)
        #expect(coordinator.canRecover)
        coordinator.start()
        await coordinator.waitUntilFinished()
        #expect(coordinator.destinationStatus == .blocked && coordinator.phase == .ready)
        #expect(dir.allFiles().isEmpty)
    }

    // MARK: Durability

    @Test func eachFileIsFullySyncedBeforeItIsPublished() async throws {
        let dir = try TempDir()
        let log = SyncLog()
        let base = dir.url
        let files = [file("/a.txt", size: 1, content: .resident(Data("a".utf8))),
                     file("/b.txt", size: 1, content: .resident(Data("b".utf8)))]
        let coordinator = await recover(files, reader: MemoryReader(bytes: Data()), into: base, sync: { fd in
            let published = TempDir.regularFiles(under: base).filter { !$0.hasSuffix(".partial") }
            log.append(published.map { ($0 as NSString).lastPathComponent })
            return RecoveryEngine.durableSync(fd)
        })
        #expect(summary(coordinator)?.written.count == 2)
        // Both are staged (as .partial, fsynced), then one full flush, then both are published.
        #expect(log.entries == [[]])
    }

    /// Hundreds of thousands of small files: one full flush per batch, never one per file, and a
    /// file is published only after the flush that covers it.
    @Test func filesAreFlushedOncePerBatchBeforeAnyOfThemIsPublished() async throws {
        let dir = try TempDir()
        let log = SyncLog()
        let base = dir.url
        let count = RecoveryEngine.publishBatchFiles * 2 + 6
        let files = (0..<count).map { file("/many/f\($0).txt", size: 1, content: .resident(Data("x".utf8))) }
        let coordinator = await recover(files, reader: MemoryReader(bytes: Data()), into: base, sync: { fd in
            let all = TempDir.regularFiles(under: base)
            log.append(["\(all.filter { !$0.hasSuffix(".partial") }.count) published", "\(all.filter { $0.hasSuffix(".partial") }.count) staged"])
            return RecoveryEngine.durableSync(fd)
        })
        let result = try #require(summary(coordinator))
        #expect(result.written.count == count && result.failed.isEmpty)
        #expect(result.written.map(\.sourcePath) == files.map(\.path), "Written in selection order")
        let batch = RecoveryEngine.publishBatchFiles
        #expect(log.entries == [["0 published", "\(batch) staged"], ["\(batch) published", "\(batch) staged"],
                                ["\(2 * batch) published", "6 staged"]])
        #expect(!TempDir.regularFiles(under: base).contains { $0.hasSuffix(".partial") })
    }

    @Test func aFailedBatchFlushPublishesNoneOfThatBatch() async throws {
        let dir = try TempDir()
        let base = dir.url
        let calls = Counter()
        let count = RecoveryEngine.publishBatchFiles + 5
        let files = (0..<count).map { file("/b/f\($0).txt", size: 1, content: .resident(Data("y".utf8))) }
        let coordinator = await recover(files, reader: MemoryReader(bytes: Data()), into: base, sync: { fd in
            calls.next() == 2 ? EIO : RecoveryEngine.durableSync(fd)
        })
        let result = try #require(summary(coordinator))
        #expect(result.written.map(\.sourcePath) == files.prefix(RecoveryEngine.publishBatchFiles).map(\.path))
        #expect(result.failed.map(\.sourcePath) == files.suffix(5).map(\.path))
        #expect(result.failed.allSatisfy { $0.reason == RecoveryEngine.CopyFailure.destination(EIO).reason })
        let left = TempDir.regularFiles(under: base)
        #expect(left.count == RecoveryEngine.publishBatchFiles && !left.contains { $0.hasSuffix(".partial") })
    }

    @Test func fullSyncFallsBackToFsyncOnlyWhenUnsupported() {
        let plain = Counter()
        #expect(RecoveryEngine.durableSync(3, fullSync: { _ in 0 }, plainSync: { _ in _ = plain.next(); return 0 }) == nil)
        #expect(RecoveryEngine.durableSync(3, fullSync: { _ in ENOTSUP }, plainSync: { _ in _ = plain.next(); return 0 }) == nil)
        #expect(RecoveryEngine.durableSync(3, fullSync: { _ in ENOTTY }, plainSync: { _ in _ = plain.next(); return EIO }) == EIO)
        #expect(RecoveryEngine.durableSync(3, fullSync: { _ in EIO }, plainSync: { _ in _ = plain.next(); return 0 }) == EIO)
        #expect(plain.next() == 3)  // fsync ran only for the two unsupported cases
    }

    // MARK: Publishing without RENAME_EXCL (FAT32, exFAT, ...)

    @Test(arguments: [false, true]) func publishFallsBackWithoutEverOverwriting(linksUnsupported: Bool) throws {
        let dir = try TempDir()
        let fd = open(dir.url.path, O_RDONLY | O_DIRECTORY)
        defer { close(fd) }
        try Data("keep".utf8).write(to: dir.url.appendingPathComponent("a.txt"))
        try Data("new".utf8).write(to: dir.url.appendingPathComponent("a.partial"))
        var ops = RecoveryEngine.PublishOps.live
        ops.renameExclusive = { _, _, _ in ENOTSUP }
        if linksUnsupported { ops.link = { _, _, _ in ENOTSUP } }
        let published = RecoveryEngine.publish("a.partial", as: "a.txt", in: fd, ops: ops)
        #expect(published == .success("a (2).txt"))
        #expect(try Data(contentsOf: dir.url.appendingPathComponent("a.txt")) == Data("keep".utf8))
        #expect(try Data(contentsOf: dir.url.appendingPathComponent("a (2).txt")) == Data("new".utf8))
        #expect(Set(dir.allFiles()) == ["a.txt", "a (2).txt"])
    }

    @Test func placeholderIsRemovedWhenTheFinalRenameFails() throws {
        let dir = try TempDir()
        let fd = open(dir.url.path, O_RDONLY | O_DIRECTORY)
        defer { close(fd) }
        try Data("new".utf8).write(to: dir.url.appendingPathComponent("a.partial"))
        var ops = RecoveryEngine.PublishOps.live
        ops.renameExclusive = { _, _, _ in EINVAL }
        ops.link = { _, _, _ in EPERM }
        ops.rename = { _, _, _ in EIO }
        #expect(RecoveryEngine.publish("a.partial", as: "a.txt", in: fd, ops: ops) == .failure(.init(code: EIO)))
        #expect(dir.allFiles() == ["a.partial"])
    }

    /// Real FAT32 and exFAT volumes on disk images this test creates in its own temp directory.
    @Test(.enabled(if: ScratchDiskImage.isAvailable), arguments: ["MS-DOS FAT32", "ExFAT"])
    func recoversOntoFATVolumes(filesystem: String) async throws {
        guard let image = ScratchDiskImage(filesystem: filesystem) else {
            print("Skipping \(filesystem): couldn't create or attach a scratch disk image here.")
            return
        }
        defer { image.detach() }
        let device = deviceBytes(8192)
        let fragmented = file("/DCIM/100/photo.jpg", size: 2500, content: .runs([
            DataRun(deviceOffset: 4096, length: 1024), DataRun(deviceOffset: nil, length: 512),
            DataRun(deviceOffset: 1024, length: 2048)]), modified: Date(timeIntervalSince1970: 1_600_000_000))
        let files = [fragmented,
                     file("/a.txt", size: 1, content: .resident(Data("1".utf8))),
                     file("/A.TXT", size: 1, content: .resident(Data("2".utf8))),  // same name on FAT
                     file("/a.txt", size: 1, content: .resident(Data("3".utf8)))]
        let coordinator = await recover(files, reader: MemoryReader(bytes: device), into: image.mountPoint)
        let result = try #require(summary(coordinator))
        #expect(result.failed.isEmpty, "\(result.failed.map(\.reason))")
        #expect(result.written.count == 4)
        var expected = device.subdata(in: 4096..<5120)
        expected.append(Data(count: 512))
        expected.append(device.subdata(in: 1024..<1988))
        #expect(try Data(contentsOf: result.root.appendingPathComponent("DCIM/100/photo.jpg")) == expected)
        #expect(try Data(contentsOf: result.root.appendingPathComponent("a.txt")) == Data("1".utf8))
        #expect(try Data(contentsOf: result.root.appendingPathComponent("A (2).TXT")) == Data("2".utf8))
        #expect(try Data(contentsOf: result.root.appendingPathComponent("a (3).txt")) == Data("3".utf8))
        let names = try FileManager.default.contentsOfDirectory(atPath: result.root.path)
        #expect(!names.contains { $0.hasSuffix(".partial") })
        #expect(Set(names.filter { !$0.hasPrefix("._") }) == ["DCIM", "a.txt", "A (2).TXT", "a (3).txt"])
    }

    // MARK: Containment without path strings

    @Test func deepFoldersBeyondThePathLimitAreReportedAsTooLong() async throws {
        let dir = try TempDir()
        let component = String(repeating: "d", count: 200)
        let deep = "/" + Array(repeating: component, count: 8).joined(separator: "/") + "/deep.txt"
        let shallow = "/" + Array(repeating: component, count: 3).joined(separator: "/") + "/ok.txt"
        let files = [file(deep, size: 1, content: .resident(Data("x".utf8))),
                     file(shallow, size: 1, content: .resident(Data("y".utf8)))]
        let coordinator = await recover(files, reader: MemoryReader(bytes: Data()), into: dir)
        let result = try #require(summary(coordinator))
        #expect(result.failed.map(\.reason) == [RecoveryEngine.CopyFailure.destination(ENAMETOOLONG).reason])
        #expect(result.failed.first?.reason != RecoveryEngine.CopyFailure.outsideRoot.reason)
        #expect(result.written.map(\.sourcePath) == [shallow])
        #expect(try Data(contentsOf: try #require(result.written.first).url) == Data("y".utf8))
        // Refused before any folder was made: the deep chain's 4th level (still under PATH_MAX,
        // so it's observable by path) was never created beside the shallow file's folders.
        let fourth = result.root.appendingPathComponent(Array(repeating: component, count: 4).joined(separator: "/"))
        #expect(fourth.path.utf8.count < Int(PATH_MAX))
        #expect(!FileManager.default.fileExists(atPath: fourth.path))
    }

    @Test func containmentIsCheckedByIdentityNotPath() throws {
        let dir = try TempDir()
        let outside = try TempDir()
        let nested = dir.url.appendingPathComponent(Array(repeating: String(repeating: "n", count: 200), count: 6).joined(separator: "/"))
        // Build the deep chain with relative mkdirat calls (the absolute path exceeds PATH_MAX).
        var fd = open(dir.url.path, O_RDONLY | O_DIRECTORY)
        let root = try #require(RecoveryEngine.FileID(fd: fd))
        for _ in 0..<6 {
            #expect(mkdirat(fd, String(repeating: "n", count: 200), 0o755) == 0)
            let child = openat(fd, String(repeating: "n", count: 200), O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            close(fd); fd = child
        }
        defer { close(fd) }
        #expect(nested.path.utf8.count >= Int(PATH_MAX))
        #expect(RecoveryEngine.isInside(fd, root: root, maxLevels: 6))
        #expect(!RecoveryEngine.isInside(fd, root: root, maxLevels: 5))
        let other = open(outside.url.path, O_RDONLY | O_DIRECTORY)
        defer { close(other) }
        #expect(!RecoveryEngine.isInside(other, root: root, maxLevels: 64))
    }

    @Test func symlinkPlantedInsideTheRootDuringARunIsNeverFollowed() async throws {
        let dir = try TempDir()
        let outside = try TempDir()
        let base = dir.url.resolvingSymlinksInPath()
        let target = outside.url
        let planted = Counter()
        // While "/trigger.bin" is being read, swap the root's "known" folder for a symlink to
        // `outside` and plant a symlink at "fresh" too.
        let reader = MemoryReader(bytes: deviceBytes(1024), onRead: { _ in
            guard planted.next() == 1,
                  let rootName = try? FileManager.default.contentsOfDirectory(atPath: base.path).first else { return }
            let root = base.appendingPathComponent(rootName)
            try? FileManager.default.moveItem(at: root.appendingPathComponent("known"), to: root.appendingPathComponent("moved"))
            try? FileManager.default.createSymbolicLink(at: root.appendingPathComponent("known"), withDestinationURL: target)
            try? FileManager.default.createSymbolicLink(at: root.appendingPathComponent("fresh"), withDestinationURL: target)
        })
        let files = [file("/known/one.txt", size: 1, content: .resident(Data("1".utf8))),
                     file("/trigger.bin", size: 512, content: .runs([DataRun(deviceOffset: 0, length: 512)])),
                     file("/known/two.txt", size: 1, content: .resident(Data("2".utf8))),
                     file("/fresh/three.txt", size: 1, content: .resident(Data("3".utf8)))]
        let coordinator = await recover(files, reader: reader, into: dir)
        let result = try #require(summary(coordinator))
        #expect(outside.allFiles().isEmpty)
        #expect(result.written.map(\.sourcePath) == ["/known/one.txt", "/trigger.bin", "/fresh/three.txt"])
        #expect(result.failed.map(\.sourcePath) == ["/known/two.txt"])
        #expect(try Data(contentsOf: result.root.appendingPathComponent("fresh (2)/three.txt")) == Data("3".utf8))
        #expect(try Data(contentsOf: result.root.appendingPathComponent("moved/one.txt")) == Data("1".utf8))
    }
}

private final class SyncLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [[String]] = []
    func append(_ entry: [String]) { lock.withLock { stored.append(entry) } }
    var entries: [[String]] { lock.withLock { stored } }
}

/// A small FAT32/exFAT disk image created, attached (`-nobrowse`, at a private mount point) and
/// detached by the test itself. Nothing outside its own temporary directory is touched.
/// Real-image tests run unless `SALVAGE_SKIP_HDIUTIL` is set; with it unset they fail, never
/// silently pass, when `hdiutil` can't make an image here.
private let hdiutilSkipped = ProcessInfo.processInfo.environment["SALVAGE_SKIP_HDIUTIL"] != nil

private final class ScratchDiskImage: @unchecked Sendable {
    static let hdiutil = "/usr/bin/hdiutil"
    static var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: hdiutil) }

    let base: URL
    let mountPoint: URL
    private var devices: [String] = []
    private var attached = false

    init?(filesystem: String) {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("SalvageFATTests-\(UUID().uuidString)", isDirectory: true)
        mountPoint = base.appendingPathComponent("mnt", isDirectory: true)
        let image = base.appendingPathComponent("scratch.dmg")
        do { try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true) } catch { return nil }
        // FAT32 needs more than 32 MB of clusters; 64 MB suits both formats.
        guard Self.run(["create", "-size", "64m", "-fs", filesystem, "-volname", "SALVTEST", image.path]).status == 0 else {
            cleanUp(); return nil
        }
        let attach = Self.run(["attach", "-nobrowse", "-noautoopen", "-mountpoint", mountPoint.path, "-plist", image.path])
        if let plist = try? PropertyListSerialization.propertyList(from: attach.output, format: nil) as? [String: Any],
           let entities = plist["system-entities"] as? [[String: Any]] {
            devices = entities.compactMap { $0["dev-entry"] as? String }
        }
        attached = attach.status == 0
        guard attached, mountSourceName(ofPath: mountPoint.path) != mountSourceName(ofPath: base.path) else {
            detach(); return nil
        }
    }

    func detach() {
        if attached {
            if Self.run(["detach", mountPoint.path]).status != 0 {
                // Only ever the whole disk this image was attached as.
                if let whole = devices.min(by: { $0.count < $1.count }) { _ = Self.run(["detach", "-force", whole]) }
            }
            attached = false
        }
        cleanUp()
    }

    private func cleanUp() { try? FileManager.default.removeItem(at: base) }

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


private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { value += 1; return value } }
}

// MARK: - Recover all files from a partition (spec-tech-recover-whole-partition)

private func deleted(_ path: String, content: FileContent, size: Int64) -> RecoveredFile {
    RecoveredFile(name: (path as NSString).lastPathComponent, path: path, sizeBytes: size, isDeleted: true,
                  sourceMetadata: metadata, content: content)
}

@MainActor @Suite("Recover all files from a partition: coordinator")
struct PartitionRecoveryCoordinatorTests {
    private let epoch = Date(timeIntervalSince1970: 0)

    @Test func rootFolderIsNamedAfterThePartition() async throws {
        let dir = try TempDir()
        let files = [file("/DCIM/a.jpg", size: 1, content: .resident(Data("a".utf8)))]
        let coordinator = RecoveryCoordinator(files: files, content: FileContentReader(reader: MemoryReader(bytes: Data())),
                                              deviceName: "SanDisk Ultra", rootName: "Photos (exFAT)", sourceLabel: "Photos (exFAT)",
                                              now: { Date(timeIntervalSince1970: 0) }, destinationCheck: checked(.safe))
        await coordinator.chooseDestination(dir.url)
        coordinator.start()
        await coordinator.waitUntilFinished()
        let result = try #require(summary(coordinator))
        let expected = RecoveryCoordinator.rootFolderName(partition: "Photos (exFAT)", date: epoch)
        #expect(expected.hasPrefix("Photos (exFAT) (recovered ") && expected.hasSuffix(")"))
        #expect(!expected.contains(":"))
        #expect(result.root.lastPathComponent == expected)
        #expect(try Data(contentsOf: result.root.appendingPathComponent("DCIM/a.jpg")) == Data("a".utf8))
        #expect(RecoverySummaryView.headline(result, sourceName: coordinator.sourceLabel)
            == "Recovered 1 of 1 file from Photos (exFAT) (\(ByteCountFormatter.string(fromByteCount: 1, countStyle: .file)) written).")
        // Existing callers are unchanged.
        #expect(RecoveryCoordinator.rootFolderName(device: "SanDisk Ultra", date: epoch).hasPrefix("Salvage Recovery SanDisk Ultra "))
        #expect(RecoveryCoordinator.rootFolderName(partition: "  ", date: epoch).hasPrefix("Partition (recovered "))
    }

    @Test func deletedFilesShareTheFoldersWithCollisionHandlingAndNoOverwrite() async throws {
        let dir = try TempDir()
        let files = [file("/Docs/report.txt", size: 4, content: .resident(Data("live".utf8))),
                     deleted("/Docs/report.txt", content: .resident(Data("gone".utf8)), size: 4),
                     deleted("/Docs/old/draft.txt", content: .resident(Data("old".utf8)), size: 3)]
        let coordinator = RecoveryCoordinator(files: files, content: FileContentReader(reader: MemoryReader(bytes: Data())),
                                              deviceName: "Drive", rootName: "Photos (exFAT)", destinationCheck: checked(.safe))
        await coordinator.chooseDestination(dir.url)
        coordinator.start()
        await coordinator.waitUntilFinished()
        let root = try #require(summary(coordinator)).root
        #expect(try Data(contentsOf: root.appendingPathComponent("Docs/report.txt")) == Data("live".utf8))
        #expect(try Data(contentsOf: root.appendingPathComponent("Docs/report (2).txt")) == Data("gone".utf8))
        #expect(try Data(contentsOf: root.appendingPathComponent("Docs/old/draft.txt")) == Data("old".utf8))
    }

    @Test func reconstructedFilesAreOptInAndFrozenOnceRunning() async throws {
        let dir = try TempDir()
        let base = [file("/a.txt", size: 1, content: .resident(Data("a".utf8)))]
        let rebuilt = [file("/Reconstructed/Pictures/jpeg-1.jpg", size: 2, content: .resident(Data("jj".utf8)))]
        let coordinator = RecoveryCoordinator(files: base, content: FileContentReader(reader: MemoryReader(bytes: Data())),
                                              deviceName: "Drive", rootName: "P", reconstructedFiles: rebuilt,
                                              destinationCheck: checked(.safe))
        #expect(coordinator.files == base && coordinator.totalBytes == 1)
        coordinator.setIncludeReconstructed(true)
        #expect(coordinator.files == base + rebuilt && coordinator.totalBytes == 3)
        await coordinator.chooseDestination(dir.url)
        coordinator.start()
        coordinator.setIncludeReconstructed(false)  // ignored while running
        await coordinator.waitUntilFinished()
        let result = try #require(summary(coordinator))
        #expect(result.written.count == 2 && result.selectedCount == 2)

        // Without reconstructed files there is nothing to toggle.
        let plain = RecoveryCoordinator(files: base, content: FileContentReader(reader: MemoryReader(bytes: Data())),
                                        deviceName: "Drive", destinationCheck: checked(.safe))
        plain.setIncludeReconstructed(true)
        #expect(!plain.includeReconstructed && plain.files == base)
    }

    @Test func freeSpaceShortfallWarnsButStillLetsTheUserContinue() async throws {
        let dir = try TempDir()
        let files = [file("/a.bin", size: 600, content: .runs([DataRun(deviceOffset: 0, length: 600)])),
                     file("/b.bin", size: 600, content: .runs([DataRun(deviceOffset: 0, length: 600)]))]
        let reader = MemoryReader(bytes: deviceBytes(1024))
        let short = RecoveryCoordinator(files: files, content: FileContentReader(reader: reader), deviceName: "Drive",
                                        rootName: "Photos (exFAT)", freeSpace: { _ in 1000 }, destinationCheck: checked(.safe))
        #expect(short.spaceWarning == nil)  // nothing chosen yet
        await short.chooseDestination(dir.url)
        #expect(short.destinationFreeBytes == 1000)
        #expect(short.spaceShortfall == 200)
        #expect(short.spaceWarning == RecoveryCoordinator.spaceWarning(needed: 1200, available: 1000))
        #expect(short.spaceWarning?.contains("continue anyway") == true)
        #expect(short.canRecover)  // a warning, not a block
        short.start()
        await short.waitUntilFinished()
        #expect(try #require(summary(short)).written.count == 2)

        let roomy = RecoveryCoordinator(files: files, content: FileContentReader(reader: reader), deviceName: "Drive",
                                        freeSpace: { _ in 1200 }, destinationCheck: checked(.safe))
        await roomy.chooseDestination(dir.url)
        #expect(roomy.spaceShortfall == nil && roomy.spaceWarning == nil)

        let unknown = RecoveryCoordinator(files: files, content: FileContentReader(reader: reader), deviceName: "Drive",
                                          freeSpace: { _ in nil }, destinationCheck: checked(.safe))
        await unknown.chooseDestination(dir.url)
        #expect(unknown.spaceWarning == nil)

        // The live reading returns a real number for a real folder.
        #expect((RecoveryCoordinator.availableCapacity(at: dir.url) ?? -1) >= 0)
    }

    @Test func destinationOnTheSourceDriveBlocksRecoverAllAndWritesNothing() async throws {
        for verdict in [DestinationVerdict.sameDevice, .undetermined] {
            let dir = try TempDir()
            let coordinator = RecoveryCoordinator(
                files: [file("/a.txt", size: 1, content: .resident(Data("a".utf8)))],
                content: FileContentReader(reader: MemoryReader(bytes: Data())), deviceName: "Drive",
                rootName: "Photos (exFAT)",
                reconstructedFiles: [file("/Reconstructed/x.jpg", size: 1, content: .resident(Data("x".utf8)))],
                sourceLabel: "Photos (exFAT)", freeSpace: { _ in 0 }, destinationCheck: checked(verdict))
            coordinator.setIncludeReconstructed(true)
            await coordinator.chooseDestination(dir.url)
            #expect(coordinator.destinationStatus == .blocked)
            #expect(!coordinator.canRecover)
            #expect(coordinator.spaceWarning == nil)  // the block is what's shown
            coordinator.start()
            await coordinator.waitUntilFinished()
            #expect(coordinator.phase == .ready)
            #expect(dir.allFiles().isEmpty)
        }
    }

    // MARK: Review fixes

    /// FAT32 and exFAT report 0 for important-usage capacity; the fallback reads the real figure.
    @Test(.enabled(if: !hdiutilSkipped), arguments: ["ExFAT", "MS-DOS FAT32"])
    func freeSpaceOnRealFATVolumesIsKnownAndASmallSelectionDoesNotWarn(filesystem: String) async throws {
        guard ScratchDiskImage.isAvailable, let image = ScratchDiskImage(filesystem: filesystem) else {
            Issue.record("Couldn't create or attach a \(filesystem) image (set SALVAGE_SKIP_HDIUTIL=1 to skip).")
            return
        }
        defer { image.detach() }
        let free = try #require(RecoveryCoordinator.availableCapacity(at: image.mountPoint))
        #expect(free > 0 && free <= 64 * 1024 * 1024, "\(filesystem) reported \(free) bytes free")
        let coordinator = RecoveryCoordinator(files: [file("/a.txt", size: 1, content: .resident(Data("a".utf8)))],
                                              content: FileContentReader(reader: MemoryReader(bytes: Data())), deviceName: "Drive",
                                              destinationCheck: checked(.safe))
        await coordinator.chooseDestination(image.mountPoint)
        #expect(coordinator.destinationStatus == .safe)
        #expect((coordinator.destinationFreeBytes ?? 0) > 0)
        #expect(coordinator.spaceShortfall == nil && coordinator.spaceWarning == nil)
    }

    @Test func freeSpaceFallsBackFromAZeroImportantUsageFigure() {
        // Important usage when it is positive.
        #expect(RecoveryCoordinator.availableCapacity(importantUsage: 500, available: 900, statfs: { 700 }) == 500)
        // exFAT / FAT32: important usage is 0, the available capacity is the answer.
        #expect(RecoveryCoordinator.availableCapacity(importantUsage: 0, available: 900, statfs: { 700 }) == 900)
        // Neither key: statfs.
        #expect(RecoveryCoordinator.availableCapacity(importantUsage: 0, available: nil, statfs: { 700 }) == 700)
        #expect(RecoveryCoordinator.availableCapacity(importantUsage: nil, available: 0, statfs: { 700 }) == 700)
        // Unknown everywhere: nil, so no warning.
        #expect(RecoveryCoordinator.availableCapacity(importantUsage: nil, available: nil, statfs: { nil }) == nil)
        // Every source says 0: really full.
        #expect(RecoveryCoordinator.availableCapacity(importantUsage: 0, available: 0, statfs: { nil }) == 0)
    }

    @Test func filesAreStoredOnceAndRebuiltOnlyWhenTheCheckboxChanges() async throws {
        let base = (0..<200).map { file("/f\($0).txt", size: 1, content: .resident(Data("x".utf8))) }
        let rebuilt = [file("/Reconstructed/jpeg-1.jpg", size: 1, content: .resident(Data("j".utf8)))]
        let coordinator = RecoveryCoordinator(files: base, content: FileContentReader(reader: MemoryReader(bytes: Data())),
                                              deviceName: "Drive", rootName: "P", reconstructedFiles: rebuilt,
                                              destinationCheck: checked(.safe))
        #expect(coordinator.filesBuildCount == 1)
        for _ in 0..<1000 { _ = coordinator.files.count; _ = coordinator.totalBytes }  // as the sheet reads per progress update
        #expect(coordinator.filesBuildCount == 1)
        coordinator.setIncludeReconstructed(true)
        #expect(coordinator.filesBuildCount == 2 && coordinator.files.count == 201 && coordinator.totalBytes == 201)
        coordinator.setIncludeReconstructed(true)  // no change, no rebuild
        #expect(coordinator.filesBuildCount == 2)
        let dir = try TempDir()
        await coordinator.chooseDestination(dir.url)
        coordinator.start()
        await coordinator.waitUntilFinished()
        #expect(try #require(summary(coordinator)).written.count == 201)
        #expect(coordinator.filesBuildCount == 2)
    }

    @Test func onlyReconstructedFilesStartTickedAndAreExplained() async throws {
        let rebuilt = [file("/Reconstructed/Pictures/jpeg-1.jpg", size: 2, content: .resident(Data("jj".utf8)))]
        let coordinator = RecoveryCoordinator(files: [], content: FileContentReader(reader: MemoryReader(bytes: Data())),
                                              deviceName: "Drive", rootName: "Unpartitioned space", reconstructedFiles: rebuilt,
                                              sourceLabel: "Unpartitioned space", destinationCheck: checked(.safe))
        #expect(coordinator.includeReconstructed)
        #expect(coordinator.files == rebuilt && coordinator.totalBytes == 2)
        #expect(coordinator.contentsNote == RecoveryCoordinator.onlyReconstructedNote)
        #expect(coordinator.contentsNote?.hasPrefix("This area only has reconstructed files") == true)
        let dir = try TempDir()
        await coordinator.chooseDestination(dir.url)
        #expect(coordinator.canRecover)
        coordinator.start()
        await coordinator.waitUntilFinished()
        let result = try #require(summary(coordinator))
        #expect(result.written.count == 1)
        #expect(try Data(contentsOf: result.root.appendingPathComponent("Reconstructed/Pictures/jpeg-1.jpg")) == Data("jj".utf8))

        // With filesystem files too, reconstructed ones stay opt-in.
        let mixed = RecoveryCoordinator(files: [file("/a.txt", size: 1, content: .resident(Data("a".utf8)))],
                                        content: FileContentReader(reader: MemoryReader(bytes: Data())), deviceName: "Drive",
                                        rootName: "P", reconstructedFiles: rebuilt, sourceLabel: "P", destinationCheck: checked(.safe))
        #expect(!mixed.includeReconstructed && mixed.contentsNote?.hasPrefix("1 file, keeping") == true)
        // Nothing at all says so.
        let empty = RecoveryCoordinator(files: [], content: FileContentReader(reader: MemoryReader(bytes: Data())),
                                        deviceName: "Drive", rootName: "P", sourceLabel: "P", destinationCheck: checked(.safe))
        #expect(empty.contentsNote == "No recoverable files were found in this partition." && !empty.includeReconstructed)
    }

    @Test func anUnfinishedScanTitlesTheSheetFoundSoFarWithANote() {
        let files = [file("/a.txt", size: 1, content: .resident(Data("a".utf8)))]
        let coordinator = RecoveryCoordinator(files: files, content: FileContentReader(reader: MemoryReader(bytes: Data())),
                                              deviceName: "Drive", rootName: "Photos (exFAT)", sourceLabel: "Photos (exFAT)",
                                              destinationCheck: checked(.safe))
        #expect(coordinator.confirmationTitle == "Recover all files from Photos (exFAT)")
        #expect(coordinator.scanNote == nil)
        coordinator.scanIncomplete = true
        #expect(coordinator.confirmationTitle == "Recover all files found so far from Photos (exFAT)")
        #expect(coordinator.scanNote == RecoveryCoordinator.incompleteScanNote)
        #expect(coordinator.scanNote?.contains("didn't finish") == true)
        // An ordinary selection is unchanged.
        let plain = RecoveryCoordinator(files: files, content: FileContentReader(reader: MemoryReader(bytes: Data())),
                                        deviceName: "Drive", destinationCheck: checked(.safe))
        #expect(plain.confirmationTitle == "Recover 1 file" && plain.scanNote == nil && plain.contentsNote == nil)
    }

    @Test func longRootFolderNamesKeepTheirDateSuffixWhole() async throws {
        let long = String(repeating: "P", count: 250) + ".jpg"  // 254 characters, with a fake extension
        let name255 = String(repeating: "é", count: 120) + String(repeating: "x", count: 15)  // 255 UTF-8 bytes
        #expect(name255.utf8.count == 255)
        for label in [String(repeating: "a", count: 255), long, name255] {
            let folder = RecoveryCoordinator.rootFolderName(partition: label, date: epoch)
            #expect(folder.hasSuffix(" (recovered \(Self.stamp(epoch)))"), "\(folder)")
            #expect(folder.utf8.count <= RecoveryPaths.maxComponentBytes)
            #expect(folder.hasPrefix(String(label.prefix(10))))
            // The engine keeps it as is: no ".suffix" is preserved at the expense of the date.
            #expect(RecoveryPaths.sanitizeFolderName(folder) == folder)
            let device = RecoveryCoordinator.rootFolderName(device: label, date: epoch)
            #expect(device.hasPrefix("Salvage Recovery ") && device.hasSuffix(" \(Self.stamp(epoch))"))
            #expect(device.utf8.count <= RecoveryPaths.maxComponentBytes)
        }
        let dir = try TempDir()
        let label = String(repeating: "a", count: 255)
        let coordinator = RecoveryCoordinator(files: [file("/a.txt", size: 1, content: .resident(Data("a".utf8)))],
                                              content: FileContentReader(reader: MemoryReader(bytes: Data())), deviceName: "Drive",
                                              rootName: label, now: { Date(timeIntervalSince1970: 0) }, destinationCheck: checked(.safe))
        await coordinator.chooseDestination(dir.url)
        coordinator.start()
        await coordinator.waitUntilFinished()
        let root = try #require(summary(coordinator)).root.lastPathComponent
        #expect(root == RecoveryCoordinator.rootFolderName(partition: label, date: epoch))
        #expect(root.hasSuffix(")") && root.contains("(recovered "))
    }

    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter.string(from: date)
    }
}
