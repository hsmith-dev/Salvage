import Foundation
import SalvageCore
import Testing
@testable import Salvage

/// spec-tech-batch-7 §B: saving and reopening a scan.
@MainActor @Suite("Saved scans")
struct ScanArchiveTests {
    static let identity: UInt64 = 0x1_0000_0A2B
    static let imageSize = 4 * 1024 * 1024
    /// A whole-disk exFAT volume.
    static let image = ExFATFixtureImage.build(files: [("/a.txt", Data("alpha".utf8)), ("/b/c.txt", Data("charlie".utf8))],
                                               sizeBytes: imageSize)
    /// The same size, re-partitioned: one exFAT partition starting at 4 KiB.
    static let repartitioned: Data = {
        var image = Data(repeating: 0, count: 4096) + ExFATFixtureImage.build(files: [("/a.txt", Data("alpha".utf8))],
                                                                             sizeBytes: imageSize - 4096)
        image[446 + 4] = 7
        put(&image, 446 + 8, 8, 4); put(&image, 446 + 12, UInt64((imageSize - 4096) / 512), 4)
        put(&image, 510, 0xaa55, 2)
        return image
    }()
    static func put(_ data: inout Data, _ offset: Int, _ value: UInt64, _ width: Int) {
        for index in 0..<width { data[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8)) }
    }

    let device = BlockDevice(bsdName: "disk7", displayName: "Backup Drive", sizeBytes: Int64(imageSize), isInternal: false,
                             isBootVolume: false, mediaIdentity: identity,
                             partitions: [DevicePartition(bsdName: "disk7s1", displayName: "BACKUP", sizeBytes: Int64(imageSize),
                                                          formatName: "exFAT", offsetBytes: 0)])

    // MARK: Round trip

    @Test func roundTripsOneHundredThousandFiles() throws {
        let files = (0..<100_000).map(Self.sampleFile)
        let archive = ScanArchive(device: device, files: files,
                                  lostPartitions: [LostPartitionCandidate(offset: 1 << 20, sizeBytes: 1 << 30, formatName: "NTFS (damaged)")],
                                  notices: [.carvingLimitReached(count: 50_000), .damagedItemsSkipped(count: 2, examples: ["/x", "/y"]),
                                            .volumeSkipped(formatName: "HFS+", offset: 4096, reason: "Bad header."), .resumedCarvingPartial],
                                  checkpoint: ScanCheckpoint(deviceSizeBytes: Int64(Self.imageSize), totalBytes: 1024,
                                                             extents: [.init(offset: 0, length: 1024)], sweepVolumeIndex: 0,
                                                             sweepOffset: 1024, bytesScanned: 1024),
                                  outcome: .failed(.unlockFailed(.wrongPassword)), bytesScanned: 1024, totalBytes: 1024,
                                  startedAt: Date(timeIntervalSinceReferenceDate: 812_345_678.123_456),
                                  endedAt: Date(timeIntervalSinceReferenceDate: 812_349_999.987_654), savedAt: Date())
        let url = try temporaryPackage()
        try archive.write(to: url)
        let read = try ScanArchive.read(from: url)
        #expect(read.files.count == 100_000)
        #expect(read == archive)
        // Saving again over the same package replaces it.
        try archive.write(to: url)
        #expect(try ScanArchive.read(from: url) == archive)
    }

    @Test func everyOutcomeAndNoticeRoundTrips() throws {
        let notices: [ScanNotice] = [.partitionTableIgnored(reason: "Bad CRC."), .lostPartitionSearchLimited(searchedBytes: 5, deviceBytes: 9),
                                     .unreadableAreasSkipped(count: 3), .signaturesSkipped(["jpeg.json"])]
        let outcomes: [ScanArchive.Outcome] = [.completed, .cancelled, .failed(.io("Gone.")), .failed(.permissionDenied),
                                               .failed(.malformed("m")), .failed(.deviceChanged)]
        for outcome in outcomes {
            let archive = ScanArchive(device: device, files: [Self.sampleFile(1)], lostPartitions: [], notices: notices,
                                      checkpoint: nil, outcome: outcome, bytesScanned: 0, totalBytes: 0,
                                      startedAt: nil, endedAt: nil, savedAt: Date())
            let url = try temporaryPackage()
            try archive.write(to: url)
            #expect(try ScanArchive.read(from: url) == archive)
        }
    }

    // MARK: Version and damage

    @Test func rejectsUnknownVersionsPlainly() throws {
        let url = try savedPackage()
        let infoURL = url.appending(path: ScanArchive.infoFileName)
        var info = try JSONSerialization.jsonObject(with: Data(contentsOf: infoURL)) as! [String: Any]
        info["formatVersion"] = 99
        try JSONSerialization.data(withJSONObject: info).write(to: infoURL)
        #expect(throws: ScanArchiveError.unsupportedVersion(99)) { try ScanArchive.read(from: url) }
        #expect(ScanArchiveError.unsupportedVersion(99).description
                == "This saved scan was made by a different version of Salvage and can't be opened here.")

        // The binary list carries the version too.
        let other = try savedPackage()
        let filesURL = other.appending(path: ScanArchive.filesFileName)
        var bytes = try Data(contentsOf: filesURL)
        bytes[8] = 2
        try bytes.write(to: filesURL)
        #expect(throws: ScanArchiveError.self) { try ScanArchive.read(from: other) }
        #expect(throws: ScanArchiveError.unsupportedVersion(2)) { try FileListCodec.decode(bytes) }
    }

    @Test func rejectsDamagedOrForeignPackages() throws {
        let url = try savedPackage()
        let filesURL = url.appending(path: ScanArchive.filesFileName)
        var bytes = try Data(contentsOf: filesURL)
        bytes[bytes.count - 1] ^= 0xff
        try bytes.write(to: filesURL)
        #expect(throws: ScanArchiveError.damaged) { try ScanArchive.read(from: url) }

        let folder = try temporaryPackage()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #expect(throws: ScanArchiveError.notAScan) { try ScanArchive.read(from: folder) }
        try Data("{\"hello\": 1}".utf8).write(to: folder.appending(path: ScanArchive.infoFileName))
        #expect(throws: ScanArchiveError.notAScan) { try ScanArchive.read(from: folder) }

        // Truncated or hostile lists never crash and never over-allocate.
        let good = FileListCodec.encode([Self.sampleFile(3), Self.sampleFile(4)])
        for cut in stride(from: 0, to: good.count, by: 7) {
            #expect(throws: ScanArchiveError.self) { try FileListCodec.decode(good.prefix(cut)) }
        }
        var huge = good.prefix(12)
        huge.append(contentsOf: [UInt8](repeating: 0xff, count: 8))
        #expect(throws: ScanArchiveError.damaged) { try FileListCodec.decode(huge) }
    }

    // MARK: No key material

    @Test func archiveHoldsNoCredentialsOrKeys() async throws {
        let password = "correct horse battery staple 7Q"
        let recoveryKey = "ABCD-EFGH-IJKL-MNOP-QRST-UVWX"
        let volumeKey: [UInt8] = (0..<32).map { UInt8(truncatingIfNeeded: 0xA0 + $0 * 7) }
        let volumeUUID = "5A1A6E00-F1C7-4E5A-9C0D-0000000000F1"
        let encrypted = RecoveredFile(name: "secret plan.pages", path: "/Users/me/secret plan.pages", sizeBytes: 4096,
                                      sourceMetadata: SourceMetadata(filesystem: .apfs, volumeOffset: 4096, recordOffset: 8192,
                                                                     allocationStart: 77, contiguous: true, rawRecord: Data([1, 2, 3]),
                                                                     volumeName: "Vault", volumeID: volumeUUID),
                                      content: .encryptedRuns([DataRun(deviceOffset: 65536, length: 4096, firstDataUnit: 128)],
                                                              keyID: volumeUUID))
        let credentials = [volumeUUID: VolumeCredential(kind: .password, secret: password),
                           "OTHER": VolumeCredential(kind: .recoveryKey, secret: recoveryKey)]
        let model = ScanViewModel { run, events in
            #expect(run.credentials.count == 2)
            try await events.send(.progress(bytesScanned: 1024, totalBytes: 1024))
            try await events.send(.found(encrypted))
            try await events.send(.completed)
            await run.keepSource(SourceSession(device: run.device, reader: MemoryReader(data: Data(count: 1024)),
                                               decryptors: [volumeUUID: KeyedDecryptor(key: volumeKey)], close: {}))
        }
        model.start(device, credentials: credentials)
        while model.isActive { await Task.yield() }
        try await waitUntil { model.source != nil }
        #expect(model.source?.decryptors.isEmpty == false, "The live session holds the volume key")

        let archive = try #require(model.makeArchive())
        #expect(archive.hasEncryptedFiles)
        let url = try temporaryPackage()
        try archive.write(to: url)
        var bytes = Data()
        for name in try FileManager.default.contentsOfDirectory(atPath: url.path).sorted() {
            bytes += try Data(contentsOf: url.appending(path: name))
        }
        #expect(bytes.range(of: Data("secret plan.pages".utf8)) != nil, "The file list is in the archive (sanity check)")
        let key = Data(volumeKey)
        let forbidden: [(String, Data)] = [
            ("password", Data(password.utf8)), ("password UTF-16", password.data(using: .utf16LittleEndian)!),
            ("password base64", Data(Data(password.utf8).base64EncodedString().utf8)),
            ("recovery key", Data(recoveryKey.utf8)), ("recovery key, no hyphens", Data(recoveryKey.replacingOccurrences(of: "-", with: "").utf8)),
            ("volume key", key), ("volume key, first half", key.prefix(16)), ("volume key, second half", key.suffix(16)),
            ("volume key hex", Data(volumeKey.map { String(format: "%02x", $0) }.joined().utf8)),
            ("volume key HEX", Data(volumeKey.map { String(format: "%02X", $0) }.joined().utf8)),
            ("volume key base64", Data(key.base64EncodedString().utf8)),
        ]
        for (label, needle) in forbidden {
            #expect(bytes.range(of: needle) == nil, "The archive contains the \(label)")
        }
        // Reopened, the encrypted file has its runs and volume UUID but no way to decrypt them.
        let read = try ScanArchive.read(from: url)
        #expect(read.files == [encrypted])
    }

    // MARK: Reopen and reconnect

    @Test func reopenedScanShowsResultsWithNoSource() throws {
        let model = ScanViewModel { _, _ in }
        let archive = ScanArchive(device: device, files: [Self.sampleFile(0), Self.sampleFile(1)], lostPartitions: [],
                                  notices: [.unreadableAreasSkipped(count: 1)], checkpoint: try checkpoint(for: Self.image),
                                  outcome: .completed, bytesScanned: 10, totalBytes: 10, startedAt: nil,
                                  endedAt: Date(timeIntervalSinceReferenceDate: 1), savedAt: Date())
        model.openArchive(archive)
        #expect(model.state == .completed)
        #expect(model.files == archive.files)
        #expect(model.source == nil)
        #expect(model.deviceWithFinishedResults == nil, "No partition offers Recover all files… without a source")
        #expect(model.reopened?.status == .waiting)
        #expect(model.noticeLines == ["Part of this drive couldn't be read, so 1 area was skipped."])
        #expect(model.partitionScanContext.extents == archive.checkpoint?.extents)
        #expect(ResultsViewModel.showsResults(state: model.state, isActive: model.isActive, fileCount: model.files.count))
        #expect(SavedScanBanner.message(.waiting, device: "Backup Drive", openFailed: false)
                == "Reconnect Backup Drive to preview or recover these files.")
        // Saving a reopened scan again keeps it whole.
        #expect(model.makeArchive(savedAt: archive.savedAt) == archive)
    }

    @Test func reconnectsTheSameDevice() async throws {
        let model = ScanViewModel { _, _ in }
        model.openArchive(try archive(fingerprintOf: Self.image))
        let opener = Opener(data: Self.image)
        #expect(await model.reconnect(device, open: opener.open) == .connected)
        #expect(model.source != nil && model.reopened?.status == .connected)
        #expect(opener.opened == 1 && opener.closed == 0)
        #expect(model.deviceWithFinishedResults == device)
    }

    @Test func refusesADeviceWithAnotherIdentityOrSizeWithoutOpeningIt() async throws {
        let model = ScanViewModel { _, _ in }
        model.openArchive(try archive(fingerprintOf: Self.image))
        let opener = Opener(data: Self.image)
        let others = [
            BlockDevice(bsdName: "disk7", displayName: "Backup Drive", sizeBytes: device.sizeBytes, isInternal: false,
                        isBootVolume: false, mediaIdentity: Self.identity + 1),
            BlockDevice(bsdName: "disk7", displayName: "Backup Drive", sizeBytes: device.sizeBytes, isInternal: false,
                        isBootVolume: false, mediaIdentity: nil),
            BlockDevice(bsdName: "disk7", displayName: "Backup Drive", sizeBytes: device.sizeBytes + 512, isInternal: false,
                        isBootVolume: false, mediaIdentity: Self.identity),
            BlockDevice(bsdName: "disk7", displayName: "Backup Drive", sizeBytes: device.sizeBytes, isInternal: true,
                        isBootVolume: true, mediaIdentity: Self.identity),
        ]
        for other in others {
            #expect(await model.reconnect(other, open: opener.open) == .notThisDevice)
        }
        #expect(opener.opened == 0, "A device that doesn't match is never opened")
        #expect(model.source == nil && model.reopened?.status == .waiting)
    }

    @Test func refusesTheSameDeviceWithAChangedLayout() async throws {
        let model = ScanViewModel { _, _ in }
        model.openArchive(try archive(fingerprintOf: Self.image))
        let opener = Opener(data: Self.repartitioned)
        #expect(await model.reconnect(device, open: opener.open) == .changed)
        #expect(model.source == nil, "A changed device never becomes the source")
        #expect(opener.opened == 1 && opener.closed == 1, "Its session is closed at once")
        #expect(model.reopened?.status == .changed)
        #expect(SavedScanBanner.message(.changed, device: "Backup Drive", openFailed: false).hasPrefix(
            "Backup Drive has changed since this scan was saved, so Salvage won't read from it."))
    }

    @Test func aScanSavedBeforeMappingIsNeverReconnected() async throws {
        let model = ScanViewModel { _, _ in }
        model.openArchive(ScanArchive(device: device, files: [Self.sampleFile(0)], lostPartitions: [], notices: [],
                                      checkpoint: nil, outcome: .cancelled, bytesScanned: 0, totalBytes: 0,
                                      startedAt: nil, endedAt: nil, savedAt: Date()))
        let opener = Opener(data: Self.image)
        #expect(await model.reconnect(device, open: opener.open) == .unverifiable)
        #expect(opener.opened == 0 && model.source == nil && model.reopened?.status == .unverifiable)
    }

    @Test func aFailedOpenLeavesTheScanWaiting() async throws {
        let model = ScanViewModel { _, _ in }
        model.openArchive(try archive(fingerprintOf: Self.image))
        #expect(await model.reconnect(device, open: { _ in throw ScanError.deviceInUse }) == .unavailable)
        #expect(model.source == nil && model.reopened?.status == .waiting)
    }

    /// The fingerprint a real scan records is the one a reconnect reads, end to end.
    @Test func aRealScanSavedAndReopenedReconnectsToItsDevice() async throws {
        let reader = MemoryReader(data: Self.image)
        let model = ScanViewModel { run, events in
            await ScanSession(reader: reader).run(events: events, pauseGate: run.pauseGate, checkpoints: run.checkpoints,
                                                  notices: run.notices, device: run.device)
            await run.keepSource(SourceSession(device: run.device, reader: reader, close: {}))
        }
        model.start(device)
        while model.isActive { await Task.yield() }
        #expect(model.state == .completed)
        let archive = try #require(model.makeArchive())
        #expect(archive.fingerprint == [.init(offset: 0, length: Int64(Self.imageSize))])
        let url = try temporaryPackage()
        try archive.write(to: url)

        let reopened = ScanViewModel { _, _ in }
        reopened.openArchive(try ScanArchive.read(from: url))
        #expect(reopened.files.map(\.path).sorted() == model.files.map(\.path).sorted())
        #expect(await reopened.reconnect(device, open: Opener(data: Self.repartitioned).open) == .changed)
        let fresh = ScanViewModel { _, _ in }
        fresh.openArchive(try ScanArchive.read(from: url))
        #expect(await fresh.reconnect(device, open: Opener(data: Self.image).open) == .connected)
    }

    @Test func aNewScanOrAnotherArchiveSupersedesAReconnect() async throws {
        let model = ScanViewModel { _, _ in }
        model.openArchive(try archive(fingerprintOf: Self.image))
        let opener = Opener(data: Self.image, beforeReturning: { @MainActor in model.openArchive(try! archive(fingerprintOf: Self.image)) })
        #expect(await model.reconnect(device, open: opener.open) == .superseded)
        #expect(model.source == nil && opener.closed == 1)
        #expect(model.reopened?.status == .waiting)

        // Starting a scan clears the reopened state.
        let scanning = ScanViewModel { _, events in try await events.send(.completed) }
        scanning.openArchive(try archive(fingerprintOf: Self.image))
        scanning.start(device)
        #expect(scanning.reopened == nil)
        while scanning.isActive { await Task.yield() }
    }

    @Test func privacyWarningIsThePlainSentence() {
        #expect(ScanArchive.privacyNotice == "This file lists the names of the files Salvage found.")
    }

    // MARK: Helpers

    func checkpoint(for image: Data) throws -> ScanCheckpoint {
        ScanCheckpoint(deviceSizeBytes: Int64(image.count), totalBytes: Int64(image.count),
                       extents: [.init(offset: 0, length: Int64(image.count))], sweepVolumeIndex: 0,
                       sweepOffset: Int64(image.count), bytesScanned: Int64(image.count))
    }

    func archive(fingerprintOf image: Data) throws -> ScanArchive {
        ScanArchive(device: device, files: [Self.sampleFile(0)], lostPartitions: [], notices: [],
                    checkpoint: try checkpoint(for: image), outcome: .completed, bytesScanned: 1, totalBytes: 1,
                    startedAt: nil, endedAt: nil, savedAt: Date())
    }

    func temporaryPackage() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "ScanArchiveTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appending(path: "Scan.salvagescan", directoryHint: .isDirectory)
    }

    func savedPackage() throws -> URL {
        let url = try temporaryPackage()
        try archive(fingerprintOf: Self.image).write(to: url)
        return url
    }

    /// Every content kind, flag and optional field, varied by index.
    nonisolated static func sampleFile(_ index: Int) -> RecoveredFile {
        let content: FileContent = switch index % 4 {
        case 0: .unmapped
        case 1: .resident(Data("resident \(index)".utf8))
        case 2: .runs([DataRun(deviceOffset: Int64(index) * 4096, length: 4096), DataRun(deviceOffset: nil, length: 512),
                       DataRun(deviceOffset: Int64.max / 2, length: 1)])
        default: .encryptedRuns([DataRun(deviceOffset: Int64(index) * 512, length: 1024, firstDataUnit: UInt64(index) << 40)],
                                keyID: "VOL-\(index % 3)")
        }
        let filesystems: [SourceMetadata.Filesystem] = [.fat32, .exfat, .ntfs, .ext, .apfs, .hfsPlus, .carved]
        return RecoveredFile(
            name: index % 7 == 0 ? "фото \(index) 📷.jpg" : "file\(index).txt",
            path: "/Folder \(index % 50)/file\(index).txt", sizeBytes: Int64(index) * 37,
            modified: index % 3 == 0 ? nil : Date(timeIntervalSinceReferenceDate: Double(index) * 1.000_001 - 5),
            isDeleted: index % 2 == 0,
            sourceMetadata: SourceMetadata(filesystem: filesystems[index % filesystems.count], volumeOffset: Int64(index % 3) * 1_048_576,
                                           recordOffset: Int64(index) * 32, allocationStart: UInt64(index) &* 0x9E37_79B9_7F4A_7C15,
                                           contiguous: index % 5 == 0, rawRecord: Data((0..<(index % 40)).map { UInt8(truncatingIfNeeded: $0 &+ index) }),
                                           volumeName: index % 4 == 0 ? "Data" : nil, volumeID: index % 6 == 0 ? "UUID-\(index % 2)" : nil),
            content: content, recoveryMethod: index % 9 == 0 ? .carved : .metadata, isPartial: index % 11 == 0,
            overwriteConfidence: Double(index % 100) / 99)
    }
}

private struct MemoryReader: BlockReader {
    let data: Data
    var sizeBytes: Int64 { Int64(data.count) }
    func read(at offset: Int64, count: Int) async throws -> Data {
        guard offset >= 0, count >= 0, Int64(count) <= sizeBytes - offset else { throw ScanError.io("Out of range.") }
        return data.subdata(in: Int(offset)..<Int(offset) + count)
    }
}

private struct KeyedDecryptor: ContentDecryptor {
    let key: [UInt8]
    func decrypt(_ ciphertext: Data, firstDataUnit: UInt64) throws -> Data { ciphertext }
}

/// Opens an in-memory device and counts sessions opened and closed.
private final class Opener: @unchecked Sendable {
    let data: Data
    let beforeReturning: (@MainActor @Sendable () -> Void)?
    private let lock = NSLock()
    private var counts = (opened: 0, closed: 0)
    var opened: Int { lock.withLock { counts.opened } }
    var closed: Int { lock.withLock { counts.closed } }

    init(data: Data, beforeReturning: (@MainActor @Sendable () -> Void)? = nil) {
        self.data = data; self.beforeReturning = beforeReturning
    }

    var open: @Sendable (BlockDevice) async throws -> SourceSession {
        { [self] device in
            lock.withLock { counts.opened += 1 }
            if let beforeReturning { await beforeReturning() }
            return SourceSession(device: device, reader: MemoryReader(data: data), close: { [self] in
                lock.withLock { counts.closed += 1 }
            })
        }
    }
}

@MainActor private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(30)
    while !condition() {
        guard ContinuousClock.now < deadline else { throw CancellationError() }
        try await Task.sleep(for: .milliseconds(5))
    }
}
