import Foundation
import SalvageCore
import SalvageDiskIO
import Testing
@testable import Salvage

/// spec-tech-image-drive: the "Image This Drive…" run, with an in-memory drive and a temporary
/// destination folder (deleted afterwards). No device is opened.
@MainActor @Suite("Image This Drive")
struct DriveImagingTests {
    private let device = BlockDevice(bsdName: "disk42", displayName: "Card: Reader/1", sizeBytes: 6 * 1024 * 1024,
                                     isInternal: false, isBootVolume: false, mediaIdentity: 42)

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SalvageImaging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func environment(_ reader: MemoryDrive, verdict: DestinationVerdict = .safe, free: Int64? = .max,
                             fsType: String = "apfs", opened: OpenCounter = OpenCounter(),
                             openError: (any Error)? = nil) -> DriveImagingEnvironment {
        DriveImagingEnvironment(
            openSource: { _, _ in
                opened.increment()
                if let openError { throw openError }
                return .init(reader: reader, close: { opened.close() })
            },
            assess: { folder, _ in DestinationAssessment(verdict: verdict, mountSource: mountSourceName(ofPath: folder.path)) },
            freeSpace: { _ in free },
            filesystemType: { _ in fsType },
            imager: DriveImager(chunkSize: 1024 * 1024, progressInterval: .zero))
    }

    private func run(_ environment: DriveImagingEnvironment, to url: URL, replacing: Bool = false,
                     cancelAfterStart: Bool = false) async -> DriveImagingModel {
        let model = DriveImagingModel(device: device, destination: url, replacingConfirmed: replacing, environment: environment)
        model.start()
        if cancelAfterStart { model.cancel() }
        await model.waitUntilFinished()
        return model
    }

    @Test func aDestinationOnTheDriveBeingImagedIsBlockedAndNothingIsOpenedOrWritten() async throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let opened = OpenCounter()
        let url = dir.appendingPathComponent("card.img")
        let model = await run(environment(MemoryDrive(size: device.sizeBytes), verdict: .sameDevice, opened: opened), to: url)
        #expect(model.phase == .blocked(DriveImagingModel.sameDriveMessage))
        #expect(opened.opens == 0)
        #expect(!FileManager.default.fileExists(atPath: url.path))

        let undetermined = await run(environment(MemoryDrive(size: device.sizeBytes), verdict: .undetermined, opened: opened), to: url)
        #expect(undetermined.phase == .failed(DriveImagingModel.undeterminedMessage))
        #expect(opened.opens == 0)
    }

    @Test func tooLittleFreeSpaceOrAFAT32DestinationIsRefusedUpFront() async throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("card.img")
        let opened = OpenCounter()
        let short = await run(environment(MemoryDrive(size: device.sizeBytes), free: device.sizeBytes - 1, opened: opened), to: url)
        guard case .failed(let message) = short.phase else { Issue.record("expected failed"); return }
        #expect(message.contains("free space"))
        let unknown = await run(environment(MemoryDrive(size: device.sizeBytes), free: nil, opened: opened), to: url)
        guard case .failed = unknown.phase else { Issue.record("unknown free space must refuse"); return }
        #expect(opened.opens == 0)
        #expect(!FileManager.default.fileExists(atPath: url.path))

        let big = BlockDevice(bsdName: "disk43", displayName: "Big", sizeBytes: 8 * 1024 * 1024 * 1024,
                              isInternal: false, isBootVolume: false, mediaIdentity: 43)
        let model = DriveImagingModel(device: big, destination: url, replacingConfirmed: false,
                                      environment: environment(MemoryDrive(size: 512), fsType: "msdos", opened: opened))
        model.start()
        await model.waitUntilFinished()
        guard case .failed(let fat) = model.phase else { Issue.record("expected failed"); return }
        #expect(fat.contains("4 GB"))
    }

    @Test func aDriveWithBadSectorsIsImagedWithZerosAndASidecarListingThem() async throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("card.img")
        let drive = MemoryDrive(size: device.sizeBytes, bad: [10, 11, 5000])
        let opened = OpenCounter()
        let model = await run(environment(drive, opened: opened), to: url)
        guard case .finished(let summary) = model.phase else { Issue.record("expected finished, got \(model.phase)"); return }
        #expect(summary.outcome == .completed)
        #expect(summary.badRanges == [ImagingBadRange(offset: 5120, length: 1024), ImagingBadRange(offset: 5000 * 512, length: 512)])
        #expect(summary.note.contains("2 areas"))
        #expect(summary.sha256?.count == 64)
        #expect(opened.closes == 1, "the source opened for imaging is closed again")

        var expected = drive.bytes
        for block in [10, 11, 5000] { expected.replaceSubrange(block * 512..<(block + 1) * 512, with: Data(count: 512)) }
        #expect(try Data(contentsOf: url) == expected)

        let sidecar = try #require(summary.sidecarURL)
        #expect(sidecar.lastPathComponent == "card.img.badblocks.json")
        let report = try ImagingReport.decode(Data(contentsOf: sidecar))
        #expect(report.status == .complete)
        #expect(report.badRanges == summary.badRanges)
        #expect(report.bytesCopied == device.sizeBytes)
        #expect(report.sourceName == device.displayName)
        #expect(report.sha256 == summary.sha256)
    }

    @Test func cancelKeepsThePartialImageAndSaysSoInTheSidecar() async throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("card.img")
        let drive = MemoryDrive(size: device.sizeBytes, delay: .milliseconds(30))
        let model = DriveImagingModel(device: device, destination: url, replacingConfirmed: false, environment: environment(drive))
        model.start()
        while model.progress.bytesDone < 2 * 1024 * 1024 { try await Task.sleep(for: .milliseconds(5)) }
        model.cancel()
        #expect(model.isCancelling)
        await model.waitUntilFinished()
        guard case .finished(let summary) = model.phase else { Issue.record("expected finished"); return }
        #expect(summary.outcome == .cancelled)
        #expect(summary.title == "Imaging canceled")
        #expect(summary.note.contains("only the first"))
        #expect(summary.sha256 == nil)
        let written = try Data(contentsOf: url)
        #expect(Int64(written.count) == summary.bytesCopied && summary.bytesCopied < device.sizeBytes)
        #expect(written == drive.bytes.prefix(written.count))
        let report = try ImagingReport.decode(Data(contentsOf: try #require(summary.sidecarURL)))
        #expect(report.status == .cancelled)
        #expect(report.note?.contains("only the first") == true)
    }

    @Test func anExistingFileIsReplacedOnlyWhenTheSavePanelConfirmedIt() async throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("card.img")
        try Data("older".utf8).write(to: url)
        let refused = await run(environment(MemoryDrive(size: device.sizeBytes)), to: url, replacing: false)
        guard case .failed(let message) = refused.phase else { Issue.record("expected failed"); return }
        #expect(message.contains("already exists"))
        #expect(try Data(contentsOf: url) == Data("older".utf8))

        let replaced = await run(environment(MemoryDrive(size: device.sizeBytes)), to: url, replacing: true)
        guard case .finished(let summary) = replaced.phase else { Issue.record("expected finished"); return }
        #expect(summary.outcome == .completed)
        #expect(try Data(contentsOf: url).count == Int(device.sizeBytes))
    }

    @Test func aReplacedFileIsNotCountedAsFreeSpaceAndAnAttachedImagesBackingFileIsNeverReplaced() async throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("card.img")
        try Data(count: Int(device.sizeBytes)).write(to: url)
        let short = await run(environment(MemoryDrive(size: device.sizeBytes), free: device.sizeBytes - 1), to: url, replacing: true)
        guard case .failed(let message) = short.phase else { Issue.record("expected failed"); return }
        #expect(message.contains("free space"))

        let identity = try #require(liveFileIdentity(ofPath: url.path))
        var env = environment(MemoryDrive(size: device.sizeBytes))
        env.protectedFiles = { [identity] }
        let backing = await run(env, to: url, replacing: true)
        guard case .failed(let refused) = backing.phase else { Issue.record("expected failed"); return }
        #expect(refused.contains("disk image behind an attached drive"))
        env.protectedFiles = { nil }
        let unknown = await run(env, to: url, replacing: true)
        guard case .failed = unknown.phase else { Issue.record("an unknown set must not replace"); return }
        #expect(try Data(contentsOf: url) == Data(count: Int(device.sizeBytes)))
    }

    @Test func aReadStuckInTheKernelDoesNotHangTheSheetAfterATimeout() async throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("card.img")
        let drive = StuckDrive(size: device.sizeBytes, stuckAt: 2 * 1024 * 1024)
        defer { drive.release() }
        var env = environment(MemoryDrive(size: 0))
        env.openSource = { _, _ in .init(reader: drive, close: { await drive.close() }) }
        env.imager.readTimeout = .milliseconds(300)
        let model = DriveImagingModel(device: device, destination: url, replacingConfirmed: false, environment: env)
        model.start()
        guard await finishes(model, within: .seconds(10)) else { Issue.record("the sheet hung on the stuck read"); return }
        guard case .finished(let summary) = model.phase, case .stopped(let reason) = summary.outcome else {
            Issue.record("expected stopped, got \(model.phase)"); return
        }
        #expect(reason.contains("stopped responding"))
        #expect(summary.bytesCopied == 2 * 1024 * 1024)
        let report = try ImagingReport.decode(Data(contentsOf: try #require(summary.sidecarURL)))
        #expect(report.status == .stopped)
        #expect(!drive.closed, "the close waits behind the stuck read")
        drive.release()
        for _ in 0..<200 where !drive.closed { try await Task.sleep(for: .milliseconds(10)) }
        #expect(drive.closed, "and still happens once the read returns")
    }

    @Test func cancelDuringAStuckReadEndsAtOnce() async throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("card.img")
        let drive = StuckDrive(size: device.sizeBytes, stuckAt: 1024 * 1024)
        defer { drive.release() }
        var env = environment(MemoryDrive(size: 0))
        env.openSource = { _, _ in .init(reader: drive, close: { await drive.close() }) }
        let model = DriveImagingModel(device: device, destination: url, replacingConfirmed: false, environment: env)
        model.start()
        for _ in 0..<500 where !drive.isStuck { try await Task.sleep(for: .milliseconds(10)) }
        #expect(drive.isStuck)
        model.cancel()
        guard await finishes(model, within: .seconds(10)) else { Issue.record("cancel hung on the stuck read"); return }
        guard case .finished(let summary) = model.phase else { Issue.record("expected finished"); return }
        #expect(summary.outcome == .cancelled)
        #expect(summary.bytesCopied == 1024 * 1024)
        #expect(FileManager.default.fileExists(atPath: try #require(summary.sidecarURL).path))
    }

    /// Polls rather than awaiting the run, so a hang fails the test instead of hanging it.
    private func finishes(_ model: DriveImagingModel, within limit: Duration) async -> Bool {
        let deadline = ContinuousClock.now + limit
        while model.isActive, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        return !model.isActive
    }

    @Test func aDriveInUseOrRefusedIsReportedPlainly() async throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("card.img")
        let busy = await run(environment(MemoryDrive(size: device.sizeBytes), openError: ScanError.deviceInUse), to: url)
        guard case .failed(let message) = busy.phase else { Issue.record("expected failed"); return }
        #expect(message.contains("in use by a scan"))
        let boot = await run(environment(MemoryDrive(size: device.sizeBytes),
                                         openError: ScanError.unsafeTarget("Your boot drive can't be scanned while macOS is running from it.")), to: url)
        #expect(boot.phase == .failed("Your boot drive can't be scanned while macOS is running from it."))
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func aClosedScanSessionEndsTheCopyInsteadOfReadingAsBadBlocks() async throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("card.img")
        let session = SourceSession(device: device, reader: MemoryDrive(size: device.sizeBytes), close: {})
        let reader = SessionImagingReader(session: session)
        #expect(try await reader.read(at: 0, count: 512).count == 512)
        await session.close()
        var env = environment(MemoryDrive(size: device.sizeBytes))
        env.openSource = { _, _ in .init(reader: reader, close: {}) }
        let model = await run(env, to: url)
        guard case .finished(let summary) = model.phase, case .stopped(let reason) = summary.outcome else {
            Issue.record("expected stopped"); return
        }
        #expect(reason.contains("session was closed"))
        #expect(summary.badRanges.isEmpty)
    }

    @Test func onlyWholeDrivesThatAreNotTheBootDriveCanBeImaged() {
        #expect(DriveImagingCenter.canImage(device))
        #expect(!DriveImagingCenter.canImage(nil))
        #expect(!DriveImagingCenter.canImage(BlockDevice(bsdName: "disk0", displayName: "Mac", sizeBytes: 1 << 30,
                                                         isInternal: true, isBootVolume: true)))
        #expect(!DriveImagingCenter.canImage(BlockDevice(bsdName: "image-1", displayName: "a.img", sizeBytes: 1 << 20,
                                                         isInternal: false, isBootVolume: false)))
    }

    @Test func formatting() {
        #expect(DriveImagingFormat.suggestedFileName(for: device) == "Card- Reader-1.img")
        #expect(DriveImagingFormat.duration(59) == "59 s")
        #expect(DriveImagingFormat.duration(125) == "2 min 5 s")
        #expect(DriveImagingFormat.duration(3 * 3600 + 120) == "3 h 2 min")
        #expect(DriveImagingFormat.areas(1) == "1 area")
    }
}

/// An in-memory drive; reads overlapping a `bad` block throw `ScanError.io`.
final class MemoryDrive: BlockReader, @unchecked Sendable {
    let bytes: Data
    let sizeBytes: Int64
    private let bad: Set<Int>
    private let delay: Duration?

    init(size: Int64, bad: Set<Int> = [], delay: Duration? = nil) {
        var data = Data(count: Int(size))
        data.withUnsafeMutableBytes { raw in for index in 0..<raw.count { raw[index] = UInt8(truncatingIfNeeded: index &* 7 &+ index >> 10) } }
        bytes = data; sizeBytes = size; self.bad = bad; self.delay = delay
    }

    func read(at offset: Int64, count: Int) async throws -> Data {
        if let delay { try await Task.sleep(for: delay) }
        let first = Int(offset / 512), last = Int((offset + Int64(count) - 1) / 512)
        if (first...last).contains(where: bad.contains) { throw ScanError.io("Input/output error") }
        return bytes.subdata(in: Int(offset)..<Int(offset) + count)
    }
}

/// Like `RawBlockReader`: an actor whose read at or past `stuckAt` blocks its thread in a
/// synchronous call (as `pread` does on a failing drive), so every later call on the actor --
/// `close()` included -- waits behind it until `release()`.
actor StuckDrive: BlockReader {
    nonisolated let sizeBytes: Int64
    nonisolated let logicalBlockSize = 512
    private nonisolated let stuckAt: Int64
    private nonisolated let gate = DispatchSemaphore(value: 0)
    private nonisolated let state = LockedFlags()

    init(size: Int64, stuckAt: Int64) { sizeBytes = size; self.stuckAt = stuckAt }

    nonisolated var isStuck: Bool { state.get(\.stuck) }
    nonisolated var closed: Bool { state.get(\.closed) }
    nonisolated func release() { if state.set(\.released) { for _ in 0..<64 { gate.signal() } } }

    func read(at offset: Int64, count: Int) async throws -> Data {
        if offset + Int64(count) > stuckAt, !state.get(\.released) {
            _ = state.set(\.stuck)
            blockThread()
        }
        return Data(repeating: 1, count: count)
    }

    func close() { _ = state.set(\.closed) }

    /// A synchronous wait, holding the actor's thread like a stuck `pread`.
    private nonisolated func blockThread() { gate.wait() }
}

final class LockedFlags: @unchecked Sendable {
    struct Flags { var stuck = false, closed = false, released = false }
    private let lock = NSLock()
    private var flags = Flags()
    func get(_ key: KeyPath<Flags, Bool>) -> Bool { lock.withLock { flags[keyPath: key] } }
    /// Sets the flag; true when it wasn't set before.
    func set(_ key: WritableKeyPath<Flags, Bool>) -> Bool {
        lock.withLock { defer { flags[keyPath: key] = true }; return !flags[keyPath: key] }
    }
}

final class OpenCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var openCount = 0, closeCount = 0
    func increment() { lock.withLock { openCount += 1 } }
    func close() { lock.withLock { closeCount += 1 } }
    var opens: Int { lock.withLock { openCount } }
    var closes: Int { lock.withLock { closeCount } }
}
