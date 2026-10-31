import CryptoKit
import Foundation
import SalvageCore
import SalvageDiskIO
import Testing
@testable import Salvage

/// In-memory device. Reads at `failAt` throw; reads at `blockAt` wait until the task is cancelled.
private struct MemoryReader: BlockReader {
    let bytes: Data
    var failAt: Int64? = nil
    var blockAt: Int64? = nil
    var sizeBytes: Int64 { Int64(bytes.count) }
    func read(at offset: Int64, count: Int) async throws -> Data {
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
    func allFiles() -> [String] {
        let base = url.resolvingSymlinksInPath().path
        let enumerator = FileManager.default.enumerator(atPath: base)
        var out: [String] = []
        while let item = enumerator?.nextObject() as? String { out.append(item) }
        return out.sorted()
    }
}

private func deviceBytes(_ count: Int) -> Data { Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }) }

@MainActor
private func recover(_ files: [RecoveredFile], reader: MemoryReader, into dir: TempDir, chunk: Int = 512,
                     verdict: DestinationVerdict = .safe) async -> RecoveryCoordinator {
    let coordinator = RecoveryCoordinator(files: files, content: FileContentReader(reader: reader, chunkSize: chunk),
                                          deviceName: "Fixture", now: { Date(timeIntervalSince1970: 0) },
                                          destinationCheck: { _ in verdict })
    await coordinator.chooseDestination(dir.url)
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
        let root = result.root.path
        for copy in result.written { #expect(copy.url.path.hasPrefix(root + "/")) }
        // Nothing was created beside the root folder.
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.url.path) == [result.root.lastPathComponent])
        let names = Set(dir.allFiles().map { String($0.dropFirst(result.root.lastPathComponent.count + 1)) })
        #expect(names.isSuperset(of: ["_/_/_/escape.txt", "a/_/_/b/_/c.txt", "dir/evil", "xy/namez", "hidden/profile", "_"]))
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
                                              deviceName: "Fixture", destinationCheck: { _ in .safe })
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
                                                  deviceName: "Fixture", destinationCheck: { _ in verdict })
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
                                              destinationCheck: { _ in calls.next() == 1 ? .safe : .sameDevice })
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
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { value += 1; return value } }
}
