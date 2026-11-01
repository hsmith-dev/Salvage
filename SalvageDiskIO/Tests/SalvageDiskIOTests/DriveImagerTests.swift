import CryptoKit
import Foundation
import SalvageCore
import Testing
@testable import SalvageDiskIO

/// spec-tech-image-drive: the copy loop, against an in-memory source that can fail, hang or vanish
/// at chosen blocks, and an in-memory sink. No device is opened.
@Suite("Drive imaging copy loop")
struct DriveImagerTests {
    static let mib = 1024 * 1024

    @Test func copiesEveryByteIncludingAShortLastChunkAndHashesTheImage() async throws {
        let source = FakeSource(size: 10 * Self.mib + 1536)
        let sink = MemorySink()
        let result = await DriveImager().run(reader: source, sink: sink)
        #expect(result.outcome == .completed)
        #expect(result.badRanges.isEmpty)
        #expect(result.progress.bytesDone == source.sizeBytes)
        #expect(sink.bytes == source.bytes)
        #expect(sink.synced)
        #expect(result.sha256 == SHA256.hash(data: source.bytes).map { String(format: "%02x", $0) }.joined())
        #expect(source.largestRead <= 4 * Self.mib)
    }

    @Test func unreadableBlocksBecomeZerosAndMergedRangesWhileTheirNeighboursAreKept() async throws {
        let bad: Set<Int64> = [3, 4, 9000, 20479]
        let source = FakeSource(size: 10 * Self.mib, bad: bad)
        let sink = MemorySink()
        let result = await DriveImager().run(reader: source, sink: sink)
        #expect(result.outcome == .completed)
        #expect(result.badRanges == [ImagingBadRange(offset: 3 * 512, length: 1024),
                                     ImagingBadRange(offset: 9000 * 512, length: 512),
                                     ImagingBadRange(offset: 20479 * 512, length: 512)])
        #expect(result.progress.unreadableBytes == 2048)
        #expect(result.progress.badRangeCount == 3)
        var expected = source.bytes
        for block in bad { expected.replaceSubrange(Int(block) * 512..<Int(block + 1) * 512, with: Data(count: 512)) }
        #expect(sink.bytes == expected)
        #expect(result.sha256 == SHA256.hash(data: expected).map { String(format: "%02x", $0) }.joined())
    }

    @Test func aSolidlyBadChunkIsMarkedInAFewReadsNotOnePerSector() async throws {
        let source = FakeSource(size: 8 * Self.mib, bad: Set(0..<8192))  // the whole first 4 MiB
        let sink = MemorySink()
        let result = await DriveImager().run(reader: source, sink: sink)
        #expect(result.outcome == .completed)
        #expect(result.badRanges == [ImagingBadRange(offset: 0, length: Int64(4 * Self.mib))])
        // The 4 MiB read, then its 64 KiB pieces once each; the good second chunk is one read.
        #expect(source.readCount == 1 + 64 + 1)
        #expect(sink.bytes.prefix(4 * Self.mib) == Data(count: 4 * Self.mib))
        #expect(sink.bytes.suffix(4 * Self.mib) == source.bytes.suffix(4 * Self.mib))
    }

    @Test func aReadThatNeverReturnsStopsTheCopyInsteadOfHanging() async throws {
        let source = FakeSource(size: 8 * Self.mib, hang: 9000)
        let sink = MemorySink()
        var imager = DriveImager()
        imager.readTimeout = .milliseconds(200)
        let started = ContinuousClock.now
        let result = await imager.run(reader: source, sink: sink)
        guard case .stopped(let reason) = result.outcome else { Issue.record("expected stopped, got \(result.outcome)"); return }
        #expect(reason.contains("stopped responding"))
        #expect(result.progress.bytesDone == Int64(4 * Self.mib), "the first chunk is kept")
        #expect(sink.bytes.count == 4 * Self.mib)
        #expect(result.sha256 == nil)
        #expect(ContinuousClock.now - started < .seconds(10))
        source.releaseHungReads()
    }

    @Test func cancelLeavesTheChunksAlreadyWritten() async throws {
        let source = FakeSource(size: 16 * Self.mib)
        let sink = MemorySink()
        let handle = TaskBox()
        sink.onWrite = { writes in if writes == 2 { handle.cancel() } }
        let task = Task { await DriveImager().run(reader: source, sink: sink) }
        handle.set(task)
        let result = await task.value
        #expect(result.outcome == .cancelled)
        #expect(result.progress.bytesDone == Int64(8 * Self.mib))
        #expect(sink.bytes == source.bytes.prefix(8 * Self.mib))
        #expect(result.sha256 == nil)
        #expect(!sink.synced)
    }

    @Test func aDriveThatGoesAwayStopsTheCopyAndIsNotCountedAsBadBlocks() async throws {
        let source = FakeSource(size: 12 * Self.mib, gone: 9000)
        let sink = MemorySink()
        let result = await DriveImager().run(reader: source, sink: sink)
        #expect(result.outcome == .stopped(ScanError.deviceChanged.description))
        #expect(result.badRanges.isEmpty)
        #expect(result.progress.bytesDone == Int64(4 * Self.mib))
    }

    @Test func aWriteFailureStopsTheCopy() async throws {
        let source = FakeSource(size: 8 * Self.mib)
        let sink = MemorySink()
        sink.failAfter = 1
        let result = await DriveImager().run(reader: source, sink: sink)
        guard case .stopped(let reason) = result.outcome else { Issue.record("expected stopped"); return }
        #expect(reason.contains("Couldn't write the image"))
        #expect(result.progress.bytesDone == Int64(4 * Self.mib))
    }

    @Test func progressReachesTheTotal() async throws {
        let source = FakeSource(size: 9 * Self.mib, bad: [100])
        let seen = Collected()
        var imager = DriveImager()
        imager.progressInterval = .zero
        _ = await imager.run(reader: source, sink: MemorySink()) { seen.add($0) }
        let last = try #require(seen.values.last)
        #expect(last.bytesDone == source.sizeBytes && last.totalBytes == source.sizeBytes)
        #expect(last.badRangeCount == 1 && last.unreadableBytes == 512)
        #expect(seen.values.map(\.bytesDone) == seen.values.map(\.bytesDone).sorted())
    }
}

// MARK: - Output file

@Suite("Image output file")
struct ImageOutputFileTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("salvage-image-out-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func checked(_ folder: URL) -> DestinationAssessment {
        DestinationAssessment(verdict: .safe, mountSource: mountSourceName(ofPath: folder.path))
    }

    @Test func createsANewFileAndASidecarThatRoundTrips() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("card.img")
        let file = try ImageOutputFile(creating: url, replacingConfirmed: false, checked: checked(dir))
        try file.write(Data(repeating: 7, count: 1024), at: 0)
        try file.write(Data(repeating: 8, count: 512), at: 1024)
        try file.synchronize()
        file.close()
        #expect(try Data(contentsOf: url) == Data(repeating: 7, count: 1024) + Data(repeating: 8, count: 512))

        let report = ImagingReport(imageFile: "card.img", sourceName: "Card", sourceDevice: "disk9", sourceSizeBytes: 1536,
                                   blockSize: 512, status: .complete, note: nil, bytesCopied: 1536, unreadableBytes: 512,
                                   badRanges: [ImagingBadRange(offset: 1024, length: 512)], sha256: "ab",
                                   startedAt: Date(timeIntervalSince1970: 1_000), finishedAt: Date(timeIntervalSince1970: 2_000))
        try file.writeSidecar(report)
        #expect(file.sidecarURL.lastPathComponent == "card.img.badblocks.json")
        #expect(try ImagingReport.decode(Data(contentsOf: file.sidecarURL)) == report)
    }

    @Test func anExistingFileIsNeverOpenedAndIsReplacedOnlyWhenConfirmed() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("old.img")
        try Data("keep".utf8).write(to: url)
        #expect(throws: ImageOutputError.self) { try ImageOutputFile(creating: url, replacingConfirmed: false, checked: checked(dir)) }
        #expect(try Data(contentsOf: url) == Data("keep".utf8))

        let file = try ImageOutputFile(creating: url, replacingConfirmed: true, checked: checked(dir))
        file.close()
        #expect(try Data(contentsOf: url).isEmpty, "a fresh, empty file replaced it")
    }

    @Test func aSymlinkIsNeverFollowedEvenWhenReplacingIsConfirmed() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("target.bin")
        try Data("untouched".utf8).write(to: target)
        let link = dir.appendingPathComponent("link.img")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(throws: ImageOutputError.self) { try ImageOutputFile(creating: link, replacingConfirmed: true, checked: checked(dir)) }
        #expect(try Data(contentsOf: target) == Data("untouched".utf8))
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil, "the link is left alone")
    }

    @Test func aDestinationThatWasNotCheckedSafeIsRefused() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("x.img")
        for assessment in [DestinationAssessment(verdict: .sameDevice, mountSource: mountSourceName(ofPath: dir.path)),
                           DestinationAssessment(verdict: .undetermined, mountSource: nil),
                           DestinationAssessment(verdict: .safe, mountSource: "/dev/disk999s9")] {
            #expect(throws: ImageOutputError.self) { try ImageOutputFile(creating: url, replacingConfirmed: false, checked: assessment) }
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func fat32CantHoldAnImageOver4GB() {
        #expect(ImageOutputFile.maximumFileSize(filesystemType: "msdos") == 4_294_967_295)
        #expect(ImageOutputFile.maximumFileSize(filesystemType: "apfs") == nil)
        #expect(ImageOutputFile.maximumFileSize(filesystemType: "exfat") == nil)
        #expect(ImageOutputFile.filesystemType(ofPath: FileManager.default.temporaryDirectory.path) != nil)
    }
}

// MARK: - Fakes

/// An in-memory source with a byte pattern. Reads overlapping a `bad` block throw `ScanError.io`;
/// one overlapping `hang` never returns (until released); one overlapping `gone` throws
/// `.deviceChanged`.
final class FakeSource: BlockReader, @unchecked Sendable {
    let bytes: Data
    let sizeBytes: Int64
    let logicalBlockSize = 512
    private let bad: Set<Int64>
    private let hang: Int64?
    private let gone: Int64?
    private let lock = NSLock()
    private var reads = 0
    private var largest = 0
    private var hung: [CheckedContinuation<Void, Never>] = []

    init(size: Int, bad: Set<Int64> = [], hang: Int64? = nil, gone: Int64? = nil) {
        var data = Data(count: size)
        data.withUnsafeMutableBytes { raw in
            for index in 0..<size { raw[index] = UInt8(truncatingIfNeeded: index &* 31 &+ index >> 9) }
        }
        bytes = data; sizeBytes = Int64(size); self.bad = bad; self.hang = hang; self.gone = gone
    }

    var readCount: Int { lock.withLock { reads } }
    var largestRead: Int { lock.withLock { largest } }

    func releaseHungReads() {
        let waiting = lock.withLock { defer { hung = [] }; return hung }
        for continuation in waiting { continuation.resume() }
    }

    func read(at offset: Int64, count: Int) async throws -> Data {
        lock.withLock { reads += 1; largest = max(largest, count) }
        let blocks = (offset / 512)..<((offset + Int64(count) + 511) / 512)
        if let hang, blocks.contains(hang) {
            await withCheckedContinuation { continuation in lock.withLock { hung.append(continuation) } }
            throw ScanError.io("released")
        }
        if let gone, blocks.contains(gone) { throw ScanError.deviceChanged }
        if blocks.contains(where: bad.contains) { throw ScanError.io("Input/output error") }
        return bytes.subdata(in: Int(offset)..<Int(offset) + count)
    }
}

final class MemorySink: ImageSink, @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var writes = 0
    private var didSync = false
    var onWrite: @Sendable (Int) -> Void = { _ in }
    var failAfter: Int?

    var bytes: Data { lock.withLock { data } }
    var synced: Bool { lock.withLock { didSync } }

    func write(_ chunk: Data, at offset: Int64) throws {
        let count: Int = try lock.withLock {
            if let failAfter, writes >= failAfter { throw ImageOutputError("The destination drive is full.") }
            precondition(Int(offset) == data.count, "writes arrive in order")
            data.append(chunk)
            writes += 1
            return writes
        }
        onWrite(count)
    }

    func synchronize() throws { lock.withLock { didSync = true } }
}

final class TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<ImagingResult, Never>?
    private var cancelled = false
    func set(_ task: Task<ImagingResult, Never>) {
        let cancelNow = lock.withLock { self.task = task; return cancelled }
        if cancelNow { task.cancel() }
    }
    func cancel() {
        let task = lock.withLock { cancelled = true; return self.task }
        task?.cancel()
    }
}

final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ImagingProgress] = []
    func add(_ value: ImagingProgress) { lock.withLock { items.append(value) } }
    var values: [ImagingProgress] { lock.withLock { items } }
}
