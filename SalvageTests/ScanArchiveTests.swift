import Foundation
import SalvageCore
import SalvageDiskIO
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
        #expect(read == Self.stored(archive))
        #expect(read.files.allSatisfy { $0.sourceMetadata.rawRecord.isEmpty }, "No metadata record bytes are saved")
        #expect(!read.files.contains { if case .resident = $0.content { true } else { false } }, "No resident data is saved")
        // Saving again over the same package replaces it.
        try archive.write(to: url)
        #expect(try ScanArchive.read(from: url) == Self.stored(archive))
    }

    @Test func everyOutcomeAndNoticeRoundTrips() throws {
        let notices: [ScanNotice] = [.partitionTableIgnored(reason: "Bad CRC."), .lostPartitionSearchLimited(searchedBytes: 5, deviceBytes: 9),
                                     .unreadableAreasSkipped(count: 3), .signaturesSkipped(["jpeg.json"])]
        let outcomes: [ScanArchive.Outcome] = [.completed, .cancelled, .failed(.io("Gone.")), .failed(.permissionDenied),
                                               .failed(.malformed("m")), .failed(.deviceChanged), .failed(.administratorPasswordNeeded)]
        for outcome in outcomes {
            let archive = ScanArchive(device: device, files: [Self.sampleFile(1)], lostPartitions: [], notices: notices,
                                      checkpoint: nil, outcome: outcome, bytesScanned: 0, totalBytes: 0,
                                      startedAt: nil, endedAt: nil, savedAt: Date())
            let url = try temporaryPackage()
            try archive.write(to: url)
            #expect(try ScanArchive.read(from: url) == Self.stored(archive))
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
        bytes[8] = 3
        try bytes.write(to: filesURL)
        #expect(throws: ScanArchiveError.self) { try ScanArchive.read(from: other) }
        #expect(throws: ScanArchiveError.unsupportedVersion(3)) { try FileListCodec.decode(bytes) }
        // A list whose version disagrees with Info.json's is damage, even when both are readable.
        let mixed = try savedPackage()
        try Self.replaceFileList(in: mixed, with: LegacyFileList.encodeVersion1([Self.sampleFile(0)]))
        #expect(throws: ScanArchiveError.damaged) { try ScanArchive.read(from: mixed) }
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
        #expect(read.files == [Self.storedFile(encrypted)])
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

    /// spec-tech-authopen: a cancelled password dialog is told apart from a missing drive, and
    /// Reconnect stays offered.
    @Test func cancelledPasswordLeavesReconnectOffered() async throws {
        let model = ScanViewModel { _, _ in }
        model.openArchive(try archive(fingerprintOf: Self.image))
        #expect(await model.reconnect(device, open: { _ in throw ScanError.administratorPasswordNeeded }) == .needsAdministratorPassword)
        #expect(model.source == nil && model.reopened?.status == .waiting)
        #expect(await model.reconnect(device, open: { _ in throw ScanError.deviceChanged }) == .unavailable)
        #expect(SavedScanBanner.message(.waiting, device: "Backup Drive", openFailed: false, password: .declined)
                == "Salvage needs your administrator password to read Backup Drive. Click Reconnect to try again.")
        #expect(SavedScanBanner.message(.checking, device: "Backup Drive", openFailed: false, password: .asking)
                == "Waiting for your administrator password\u{2026}")
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

    @Test func privacyWarningSaysWhatTheFileHolds() {
        #expect(ScanArchive.privacyNotice == "This file lists the names, folders, sizes and dates of the files Salvage found, and where each one is on the drive. It doesn't contain the files themselves.")
    }

    // MARK: Helpers

    /// What reading `archive` back gives: no metadata record bytes, and resident data either kept
    /// as runs inside its MFT record or, when it can't be located there, unmapped.
    static func stored(_ archive: ScanArchive) -> ScanArchive {
        var stored = archive
        stored.files = archive.files.map(storedFile)
        stored.residentRecords = archive.residentRecords
        for file in archive.files {
            if case .resident(let data) = file.content, FileListCodec.residentRuns(file, data) != nil {
                stored.residentRecords[file.id] = file.sourceMetadata.rawRecord.count
            }
        }
        return stored
    }

    static func storedFile(_ file: RecoveredFile) -> RecoveredFile {
        let meta = file.sourceMetadata
        var content = file.content
        if case .resident(let data) = file.content {
            content = FileListCodec.residentRuns(file, data).map(FileContent.runs) ?? .unmapped
        }
        return RecoveredFile(id: file.id, name: file.name, path: file.path, sizeBytes: file.sizeBytes, modified: file.modified,
                             isDeleted: file.isDeleted,
                             sourceMetadata: SourceMetadata(filesystem: meta.filesystem, volumeOffset: meta.volumeOffset,
                                                            recordOffset: meta.recordOffset, allocationStart: meta.allocationStart,
                                                            contiguous: meta.contiguous, rawRecord: Data(),
                                                            volumeName: meta.volumeName, volumeID: meta.volumeID),
                             content: content, recoveryMethod: file.recoveryMethod, isPartial: file.isPartial,
                             overwriteConfidence: file.overwriteConfidence)
    }

    /// Swaps a package's file list, fixing its checksum and count in Info.json.
    static func replaceFileList(in url: URL, with list: Data, count: Int? = nil, version: Int? = nil,
                                editDevice: ((inout [String: Any]) -> Void)? = nil) throws {
        try list.write(to: url.appending(path: ScanArchive.filesFileName))
        let infoURL = url.appending(path: ScanArchive.infoFileName)
        var info = try JSONSerialization.jsonObject(with: Data(contentsOf: infoURL)) as! [String: Any]
        info["fileListSHA256"] = ScanArchive.digest(list)
        if let count { info["fileCount"] = count }
        if let version { info["formatVersion"] = version }
        if let editDevice, var device = info["device"] as? [String: Any] { editDevice(&device); info["device"] = device }
        try JSONSerialization.data(withJSONObject: info).write(to: infoURL)
    }

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

// MARK: - Version 2: reconnecting after a replug, and no file contents

/// spec-tech-batch-7 §B follow-up: a stable drive identity, and an archive with no file bytes.
@MainActor @Suite("Saved scans: stable identity and privacy")
struct ScanArchiveIdentityAndPrivacyTests {
    typealias Identity = BlockDevice.StableIdentity
    static let guid = "6FC74900-00F5-4E35-855D-D8162DBD9A32"
    static let size: Int64 = 4 * 1024 * 1024

    static func drive(media: UInt64?, _ identity: Identity?, size: Int64 = size, boot: Bool = false) -> BlockDevice {
        BlockDevice(bsdName: "disk9", displayName: "Backup Drive", sizeBytes: size, isInternal: false, isBootVolume: boot,
                    mediaIdentity: media, stableIdentity: identity)
    }

    // MARK: Matching rule

    @Test func aReplugMatchesByDiskGUIDSizeAndSerial() {
        let saved = Self.drive(media: 1, Identity(diskGUID: Self.guid, sizeBytes: Self.size, model: "SSD", serial: "S1"))
        func admits(_ candidate: BlockDevice) -> Bool { ScanArchive.admits(candidate, for: saved) }
        // The same attachment, as before.
        #expect(admits(Self.drive(media: 1, nil)))
        // After a replug: a new media identity, the same GUID, size and serial.
        #expect(admits(Self.drive(media: 2, Identity(diskGUID: Self.guid.lowercased(), sizeBytes: Self.size, model: "SSD", serial: "S1"))))
        // A serial is compared only when both have one; the model isn't part of the rule.
        #expect(admits(Self.drive(media: 2, Identity(diskGUID: Self.guid, sizeBytes: Self.size, model: "Other", serial: nil))))
        #expect(!admits(Self.drive(media: 2, Identity(diskGUID: Self.guid, sizeBytes: Self.size, model: "SSD", serial: "S2"))))
        #expect(!admits(Self.drive(media: 2, Identity(diskGUID: "6FC74900-00F5-4E35-855D-D8162DBD9A33", sizeBytes: Self.size,
                                                      model: "SSD", serial: "S1"))))
        #expect(!admits(Self.drive(media: 2, Identity(diskGUID: Self.guid, sizeBytes: Self.size + 512, model: "SSD", serial: "S1"),
                                   size: Self.size + 512)))
        #expect(!admits(Self.drive(media: 2, Identity(diskGUID: Self.guid, sizeBytes: Self.size + 512, model: "SSD", serial: "S1"))))
        #expect(!admits(Self.drive(media: 2, nil)), "No stable identity: refused, as before")
        #expect(!admits(Self.drive(media: 1, nil, boot: true)))
        #expect(!admits(Self.drive(media: 2, Identity(diskGUID: nil, volumes: [.init(offsetBytes: 0, volumeUUID: "A")],
                                                      sizeBytes: Self.size, model: nil, serial: nil))))
        // IORegistry IDs restart each boot: an equal media identity doesn't override a stable identity that differs.
        #expect(!admits(Self.drive(media: 1, Identity(diskGUID: "6FC74900-00F5-4E35-855D-D8162DBD9A33", sizeBytes: Self.size,
                                                      model: "SSD", serial: "S1"))))
    }

    /// Erasing a GPT drive's volume in place keeps the disk GUID (and, for the same format, the
    /// layout), but gives the volume a new UUID: another drive.
    @Test func aGPTDriveMustAlsoKeepItsVolumeUUIDs() {
        let volume = Identity.Volume(offsetBytes: 1_048_576, volumeUUID: "65FCA101-0112-36D9-82AC-444CA787A199")
        let saved = Self.drive(media: 1, Identity(diskGUID: Self.guid, volumes: [volume], sizeBytes: Self.size, model: nil, serial: nil))
        #expect(ScanArchive.admits(Self.drive(media: 2, Identity(diskGUID: Self.guid, volumes: [volume], sizeBytes: Self.size,
                                                                 model: nil, serial: nil)), for: saved))
        for volumes in [[Identity.Volume(offsetBytes: 1_048_576, volumeUUID: "0D1E2F30-0112-36D9-82AC-444CA787A199")], [],
                        [volume, Identity.Volume(offsetBytes: 9_000_000, volumeUUID: "B")]] {
            #expect(!ScanArchive.admits(Self.drive(media: 1, Identity(diskGUID: Self.guid, volumes: volumes, sizeBytes: Self.size,
                                                                      model: nil, serial: nil)), for: saved))
        }
    }

    @Test func aMediaIdentityCountsOnlyWithinTheBootItWasSavedIn() throws {
        let device = BlockDevice(bsdName: "disk7", displayName: "Backup Drive", sizeBytes: Int64(ScanArchiveTests.imageSize),
                                 isInternal: false, isBootVolume: false, mediaIdentity: ScanArchiveTests.identity)
        let savedAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let archive = ScanArchive(device: device, files: [], lostPartitions: [], notices: [],
                                  checkpoint: try ScanArchiveTests().checkpoint(for: ScanArchiveTests.image), outcome: .completed,
                                  bytesScanned: 1, totalBytes: 1, startedAt: nil, endedAt: nil, savedAt: savedAt)
        let thisBoot = BootSession(uuid: "BOOT-A", bootTime: savedAt.addingTimeInterval(-60))
        let url = try ScanArchiveTests().temporaryPackage()
        try archive.write(to: url, boot: thisBoot)
        #expect(try ScanArchive.read(from: url, boot: thisBoot).device.mediaIdentity == ScanArchiveTests.identity)
        let restarted = BootSession(uuid: "BOOT-B", bootTime: savedAt.addingTimeInterval(60))
        let reopened = try ScanArchive.read(from: url, boot: restarted)
        #expect(reopened.device.mediaIdentity == nil, "After a restart the saved IORegistry ID means nothing")
        #expect(!ScanArchive.admits(device, for: reopened.device), "so a drive that reuses it isn't admitted")
        #expect(try ScanArchive.read(from: url, boot: BootSession(uuid: nil, bootTime: nil)).device.mediaIdentity == nil)

        // Version 1 had no session UUID: its save time must fall in this boot.
        try ScanArchiveTests.replaceFileList(in: url, with: LegacyFileList.encodeVersion1([]), version: 1,
                                             editDevice: { $0["stableIdentity"] = nil })
        #expect(try ScanArchive.read(from: url, boot: BootSession(uuid: "BOOT-B", bootTime: savedAt.addingTimeInterval(-1)))
            .device.mediaIdentity == ScanArchiveTests.identity)
        #expect(try ScanArchive.read(from: url, boot: restarted).device.mediaIdentity == nil)
    }

    @Test func driveWithoutAGPTMatchesByItsVolumeUUIDs() {
        let volumes: [Identity.Volume] = [.init(offsetBytes: 512, volumeUUID: "873EBC9F-5135-3D64-B5DA-50EEF94D9CDF")]
        let saved = Self.drive(media: 1, Identity(diskGUID: nil, volumes: volumes, sizeBytes: Self.size, model: nil, serial: nil))
        #expect(ScanArchive.admits(Self.drive(media: 7, Identity(diskGUID: nil, volumes: volumes, sizeBytes: Self.size, model: nil, serial: nil)),
                                   for: saved))
        #expect(!ScanArchive.admits(Self.drive(media: 7, Identity(diskGUID: nil, volumes: [.init(offsetBytes: 512, volumeUUID: "X")],
                                                                  sizeBytes: Self.size, model: nil, serial: nil)), for: saved))
        #expect(!ScanArchive.admits(Self.drive(media: 7, Identity(diskGUID: nil, volumes: volumes + [.init(offsetBytes: 9, volumeUUID: "Y")],
                                                                  sizeBytes: Self.size, model: nil, serial: nil)), for: saved))
        #expect(!ScanArchive.admits(Self.drive(media: 7, Identity(diskGUID: Self.guid, sizeBytes: Self.size, model: nil, serial: nil)),
                                    for: saved))
    }

    @Test func theStableIdentityRoundTripsAndAVersion1PackageFallsBackToMediaIdentity() async throws {
        let identity = Identity(diskGUID: Self.guid, sizeBytes: Int64(ScanArchiveTests.imageSize), model: "Disk Image", serial: "XYZ")
        let device = BlockDevice(bsdName: "disk7", displayName: "Backup Drive", sizeBytes: Int64(ScanArchiveTests.imageSize),
                                 isInternal: false, isBootVolume: false, mediaIdentity: ScanArchiveTests.identity, stableIdentity: identity)
        let archive = ScanArchive(device: device, files: [ScanArchiveTests.sampleFile(1), ScanArchiveTests.sampleFile(2)],
                                  lostPartitions: [], notices: [], checkpoint: try ScanArchiveTests().checkpoint(for: ScanArchiveTests.image),
                                  outcome: .completed, bytesScanned: 1, totalBytes: 1, startedAt: nil, endedAt: nil, savedAt: Date())
        let url = try ScanArchiveTests().temporaryPackage()
        try archive.write(to: url)
        let read = try ScanArchive.read(from: url)
        #expect(read.device.stableIdentity == identity)
        #expect(read == ScanArchiveTests.stored(archive))

        // The same package as version 1 wrote it: no stable identity, metadata records and resident data kept.
        try ScanArchiveTests.replaceFileList(in: url, with: LegacyFileList.encodeVersion1(archive.files), version: 1,
                                             editDevice: { $0["stableIdentity"] = nil })
        let old = try ScanArchive.read(from: url)
        #expect(old.device.stableIdentity == nil && old.files == archive.files)
        // Even a version 1 Info.json that somehow names a stable identity reconnects by media identity only.
        try ScanArchiveTests.replaceFileList(in: url, with: LegacyFileList.encodeVersion1(archive.files), version: 1,
                                             editDevice: { $0["stableIdentity"] = ["diskGUID": Self.guid, "volumes": [],
                                                                                   "sizeBytes": ScanArchiveTests.imageSize] })
        #expect(try ScanArchive.read(from: url).device.stableIdentity == nil)

        let replugged = BlockDevice(bsdName: "disk12", displayName: "Backup Drive", sizeBytes: device.sizeBytes, isInternal: false,
                                    isBootVolume: false, mediaIdentity: ScanArchiveTests.identity + 99, stableIdentity: identity)
        let model = ScanViewModel { _, _ in }
        model.openArchive(old)
        let opener = CountingOpener(data: ScanArchiveTests.image)
        #expect(await model.reconnect(replugged, open: opener.open) == .notThisDevice)
        #expect(opener.opened == 0)
        #expect(await model.reconnect(device, open: opener.open) == .connected)

        // Version 2 reconnects the replugged drive, and a changed layout still closes at once.
        let current = ScanViewModel { _, _ in }
        current.openArchive(read)
        let changed = CountingOpener(data: ScanArchiveTests.repartitioned)
        #expect(await current.reconnect(replugged, open: changed.open) == .changed)
        #expect(changed.opened == 1 && changed.closed == 1 && current.source == nil)
        let fresh = ScanViewModel { _, _ in }
        fresh.openArchive(read)
        #expect(await fresh.reconnect(replugged, open: CountingOpener(data: ScanArchiveTests.image).open) == .connected)
        #expect(fresh.source?.device.bsdName == "disk12")
        // The scan now refers to the drive as attached, so the sidebar's "Recover all files…" finds it.
        #expect(fresh.device == replugged && fresh.deviceWithFinishedResults == replugged)
    }

    // MARK: No file contents

    static let marker = "SALVAGE-PRIVATE-MARKER-7f3c91d2"

    /// An NTFS volume holding `notes.txt` (resident; its data crosses the record's first
    /// 512-byte stride, so part of it lives in the update-sequence array on disk) and, in free
    /// space, a PDF only the carver finds. Both contain `marker`.
    static func privacyImage(residentText: String? = nil) -> (image: Data, resident: Data, pdf: Data) {
        let resident = Data((residentText ?? "Dear diary. " + String(repeating: "x", count: 190) + marker + String(repeating: "y", count: 60)
                             + marker).utf8)
        let pdf = Data("%PDF-1.4\n% \(marker)\n1 0 obj << /Type /Catalog >> endobj\ntrailer << /Root 1 0 R >>\n%%EOF\n".utf8)
        var ntfs = NTFSFixture()
        ntfs.records[16] = NTFSFixture.file("notes.txt", data: NTFSFixture.resident(0x80, resident))
        var image = ntfs.build()
        image.replaceSubrange(200 * 512..<200 * 512 + pdf.count, with: pdf)
        return (image, resident, pdf)
    }

    @Test func theArchiveHoldsNoFileContentsAndResidentFilesAreReReadOnReconnect() async throws {
        let (image, resident, pdf) = Self.privacyImage()
        let device = BlockDevice(bsdName: "disk7", displayName: "Windows Drive", sizeBytes: Int64(image.count), isInternal: false,
                                 isBootVolume: false, mediaIdentity: 42,
                                 stableIdentity: Identity(diskGUID: nil, volumes: [.init(offsetBytes: 0, volumeUUID: "V")],
                                                          sizeBytes: Int64(image.count), model: nil, serial: nil))
        let reader = ArchiveMemoryReader(data: image)
        let model = ScanViewModel { run, events in
            await ScanSession(reader: reader).run(events: events, pauseGate: run.pauseGate, checkpoints: run.checkpoints,
                                                  notices: run.notices, device: run.device)
            await run.keepSource(SourceSession(device: run.device, reader: reader, close: {}))
        }
        model.start(device)
        while model.isActive { await Task.yield() }
        #expect(model.state == .completed)
        let notes = try #require(model.files.first { $0.name == "notes.txt" })
        let carved = try #require(model.files.first { $0.recoveryMethod == .carved && $0.name.hasSuffix(".pdf") })
        // Sanity: in memory, the scan holds the contents the archive must not.
        #expect(notes.content == .resident(resident))
        #expect(notes.sourceMetadata.rawRecord.range(of: Data(Self.marker.utf8)) != nil)
        #expect(carved.sourceMetadata.rawRecord.range(of: Data(Self.marker.utf8)) != nil, "The carve keeps its first bytes")

        let archive = try #require(model.makeArchive())
        let url = try ScanArchiveTests().temporaryPackage()
        try archive.write(to: url)
        var bytes = Data()
        for name in try FileManager.default.contentsOfDirectory(atPath: url.path).sorted() {
            bytes += try Data(contentsOf: url.appending(path: name))
        }
        #expect(bytes.range(of: Data("notes.txt".utf8)) != nil, "Names are listed (sanity check)")
        for (label, needle) in [("marker", Data(Self.marker.utf8)), ("marker UTF-16", Self.marker.data(using: .utf16LittleEndian)!),
                                ("marker base64", Data(Data(Self.marker.utf8).base64EncodedString().utf8)),
                                ("diary text", Data("Dear diary".utf8)), ("PDF header", Data("%PDF-1.4".utf8)),
                                ("MFT record", Data("FILE0".utf8))] {
            #expect(bytes.range(of: needle) == nil, "The archive contains the \(label)")
        }

        // Reopened, the resident file is where it lives in its record; the carve is its runs.
        let read = try ScanArchive.read(from: url)
        let reopenedNotes = try #require(read.files.first { $0.id == notes.id })
        guard case .runs(let runs) = reopenedNotes.content else { Issue.record("resident data should be runs"); return }
        #expect(runs.count == 3, "Before the stride tail, the tail's two saved bytes, after it")
        #expect(read.residentRecords == [notes.id: 1024])
        #expect(reopenedNotes.recoveryConfidence == notes.recoveryConfidence, "Confidence is unchanged by saving and reopening")
        #expect(reopenedNotes.recoveryEvidence.fragmentCount == 1)

        let reopened = ScanViewModel { _, _ in }
        reopened.openArchive(read)
        let entries = ResidentRecordGuard.entries(files: reopened.files, residentRecords: read.residentRecords)
        let device2 = ScanArchiveIdentityAndPrivacyTests.drive(media: 43, device.stableIdentity, size: device.sizeBytes)
        #expect(await reopened.reconnect(device2, open: { device in
            SourceSession(device: device, reader: ResidentRecordGuard.wrapping(ArchiveMemoryReader(data: image), entries: entries), close: {})
        }) == .connected)
        let source = try #require(reopened.source)
        #expect(try await Self.contents(of: reopenedNotes, from: source) == resident)
        // The carve ends at its last "%%EOF" (the PDF's final newline is past it).
        let carvedBytes = try await Self.contents(of: try #require(read.files.first { $0.id == carved.id }), from: source)
        #expect(carvedBytes == pdf.dropLast())

        // Saving the reopened scan again keeps the resident file located in its record.
        let again = try #require(reopened.makeArchive())
        #expect(again.residentRecords == read.residentRecords)
        let url2 = try ScanArchiveTests().temporaryPackage()
        try again.write(to: url2)
        #expect(try ScanArchive.read(from: url2).residentRecords == read.residentRecords)
    }

    @Test func aResidentFileWhoseRecordChangedIsNotRead() async throws {
        let original = Self.privacyImage()
        let model = ScanViewModel { _, _ in }
        let reader = ArchiveMemoryReader(data: original.image)
        let scanning = ScanViewModel { run, events in
            await ScanSession(reader: reader).run(events: events, pauseGate: run.pauseGate, checkpoints: run.checkpoints,
                                                  notices: run.notices, device: run.device)
        }
        let device = ScanArchiveIdentityAndPrivacyTests.drive(media: 5, nil, size: Int64(original.image.count))
        scanning.start(device)
        while scanning.isActive { await Task.yield() }
        let url = try ScanArchiveTests().temporaryPackage()
        try #require(scanning.makeArchive()).write(to: url)
        let read = try ScanArchive.read(from: url)
        model.openArchive(read)
        let notes = try #require(read.files.first { $0.name == "notes.txt" })

        // The same layout, but the record now holds other data: a different size, so not this file.
        let rewritten = Self.privacyImage(residentText: String(repeating: "z", count: original.resident.count - 9))
        #expect(rewritten.image.count == original.image.count)
        let entries = ResidentRecordGuard.entries(files: model.files, residentRecords: read.residentRecords)
        #expect(await model.reconnect(device, open: { device in
            SourceSession(device: device, reader: ResidentRecordGuard.wrapping(ArchiveMemoryReader(data: rewritten.image), entries: entries),
                          close: {})
        }) == .connected, "The layout is unchanged")
        let source = try #require(model.source)
        await #expect(throws: ScanError.io(ScanArchive.rescanToRecover)) { try await Self.contents(of: notes, from: source) }
        // Preview and recovery say so.
        #expect(try await PreviewLoader(source: source).load(notes).unavailableReason == .needsRescan)
        #expect(PreviewUnavailableReason.needsRescan.message == "Rescan to recover this file.")
        try await Self.expectRecoveryFails(notes, from: source, with: "Rescan to recover this file.")
        // Other files still read.
        let carved = try #require(read.files.first { $0.recoveryMethod == .carved })
        #expect(try await Self.contents(of: carved, from: source) == rewritten.pdf.dropLast())

        // Renamed in place (same data): refused too.
        var renamed = original.image
        let nameAt = try #require(renamed.range(of: "notes.txt".data(using: .utf16LittleEndian)!))
        renamed[nameAt.lowerBound] = UInt8(ascii: "m")
        let guardReader = ResidentRecordGuard(base: ArchiveMemoryReader(data: renamed), entries: entries)
        await #expect(throws: ScanError.io(ScanArchive.rescanToRecover)) {
            try await Self.contents(of: notes, from: SourceSession(device: device, reader: guardReader, close: {}))
        }
        // And unchanged, it reads.
        let intact = ResidentRecordGuard(base: ArchiveMemoryReader(data: original.image), entries: entries)
        #expect(try await Self.contents(of: notes, from: SourceSession(device: device, reader: intact, close: {})) == original.resident)
    }

    static func expectRecoveryFails(_ file: RecoveredFile, from source: SourceSession, with reason: String) async throws {
        let destination = FileManager.default.temporaryDirectory.appending(path: "SalvageRescan-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: destination) }
        let coordinator = RecoveryCoordinator(files: [file], content: source.content, deviceName: "Drive",
                                              destinationCheck: { url in DestinationAssessment(verdict: .safe, mountSource: mountSourceName(ofPath: url.resolvingSymlinksInPath().path)) })
        coordinator.setSaveReport(false)
        await coordinator.chooseDestination(destination)
        coordinator.start()
        await coordinator.waitUntilFinished()
        guard case .finished(let summary) = coordinator.phase else { Issue.record("Recovery didn't finish: \(coordinator.phase)"); return }
        #expect(summary.failed.map(\.reason) == [reason])
    }

    /// A 512-byte-cluster volume with 1 KiB records whose `$MFT` is in two runs, so record 16
    /// starts in the first run and ends in the second. Its resident file can't be described by
    /// runs from its record offset, so it is refused on reconnect; record 17's file reads.
    @Test func aRecordThatStraddlesMFTRunsIsRefusedAndOthersRead() async throws {
        let straddling = Data("straddles \(Self.marker)".utf8), whole = Data("whole record \(Self.marker)".utf8)
        var ntfs = NTFSFixture()
        ntfs.mftRuns = [(16, 33), (120, 31)]
        ntfs.records[16] = NTFSFixture.file("split.txt", data: NTFSFixture.resident(0x80, straddling))
        ntfs.records[17] = NTFSFixture.file("whole.txt", data: NTFSFixture.resident(0x80, whole))
        let image = ntfs.build()
        let reader = ArchiveMemoryReader(data: image)
        let device = Self.drive(media: 5, nil, size: Int64(image.count))
        let scanning = ScanViewModel { run, events in
            await ScanSession(reader: reader).run(events: events, pauseGate: run.pauseGate, checkpoints: run.checkpoints,
                                                  notices: run.notices, device: run.device)
        }
        scanning.start(device)
        while scanning.isActive { await Task.yield() }
        let split = try #require(scanning.files.first { $0.name == "split.txt" })
        let wholeFile = try #require(scanning.files.first { $0.name == "whole.txt" })
        #expect(split.content == .resident(straddling) && wholeFile.content == .resident(whole), "The scan reads both")
        #expect(split.sourceMetadata.recordOffset == 48 * 512, "Record 16 starts at the first run's last cluster")

        let url = try ScanArchiveTests().temporaryPackage()
        try #require(scanning.makeArchive()).write(to: url)
        let read = try ScanArchive.read(from: url)
        let model = ScanViewModel { _, _ in }
        model.openArchive(read)
        let entries = ResidentRecordGuard.entries(files: model.files, residentRecords: read.residentRecords)
        #expect(await model.reconnect(device, open: { device in
            SourceSession(device: device, reader: ResidentRecordGuard.wrapping(ArchiveMemoryReader(data: image), entries: entries),
                          close: {})
        }) == .connected)
        let source = try #require(model.source)
        let reopenedSplit = try #require(read.files.first { $0.id == split.id })
        let reopenedWhole = try #require(read.files.first { $0.id == wholeFile.id })
        await #expect(throws: ScanError.io(ScanArchive.rescanToRecover)) { try await Self.contents(of: reopenedSplit, from: source) }
        #expect(try await Self.contents(of: reopenedWhole, from: source) == whole)
    }

    static func contents(of file: RecoveredFile, from source: SourceSession) async throws -> Data {
        var data = Data()
        for try await chunk in source.content.chunks(of: file) { data += chunk }
        return data
    }
}

// MARK: - Real disk images

private let hdiutilSkipped = ProcessInfo.processInfo.environment["SALVAGE_SKIP_HDIUTIL"] != nil

/// A saved scan reconnects after its drive is detached and attached again (a new /dev/diskN and a
/// new media identity), using disk images this suite creates in its own temp directory and
/// attaches without mounting. Read-only: the scan and the reconnect only read the images'
/// devices, and every image is detached and deleted afterwards.
@MainActor @Suite("Saved scans reconnect after a replug", .serialized,
                  .enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/hdiutil") && !hdiutilSkipped))
struct ScanArchiveReplugTests {
    static let contents: [(String, Data)] = [
        ("hello.txt", Data("Hello from a saved scan.\n".utf8)),
        ("photo.bin", Data((0..<70_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })),
        ("notes/list.txt", Data(String(repeating: "milk, eggs, bread\n", count: 300).utf8)),
    ]

    @Test(arguments: [("GPTSPUD", "ExFAT"), ("MBRSPUD", "ExFAT")])
    func reconnectsAfterDetachAndReattachAndRefusesALookalike(layout: String, filesystem: String) async throws {
        let images = try ImageFolder()
        let image = try images.create("drive", layout: layout, filesystem: filesystem, contents: Self.contents)

        // Scan, save, and let go of the device.
        let first = try await images.attach(image)
        let original = try await Self.device(first)
        let identity = try #require(original.stableIdentity, "\(layout) image has a stable identity")
        #expect((identity.diskGUID != nil) == (layout == "GPTSPUD"))
        #expect(identity.volumes.count == 1, "Its exFAT volume's UUID is part of the identity")
        let model = ScanViewModel { run, events in
            let reader = try await RawBlockReader.prepare(device: run.device)
            await ScanSession(reader: reader).run(events: events, pauseGate: run.pauseGate, checkpoints: run.checkpoints,
                                                  notices: run.notices, device: run.device)
            await run.keepSource(SourceSession(device: run.device, reader: reader, close: { await reader.close() }))
        }
        model.start(original)
        while model.isActive { await Task.yield() }
        #expect(model.state == .completed)
        for (path, _) in Self.contents { #expect(model.files.contains { $0.path == "/" + path }, "found \(path)") }
        let archive = try #require(model.makeArchive())
        #expect(archive.device.stableIdentity == identity)
        let url = try ScanArchiveTests().temporaryPackage()
        try archive.write(to: url)
        model.releaseSource()
        try await waitFor { model.source == nil }
        try await Task.sleep(for: .milliseconds(200))
        images.detach(first)

        // Attached again: a new attachment of the same drive.
        let second = try await images.attach(image)
        let replugged = try await Self.device(second)
        #expect(replugged.mediaIdentity != original.mediaIdentity)
        #expect(replugged.stableIdentity == identity)
        let reopened = ScanViewModel { _, _ in }
        let saved = try ScanArchive.read(from: url)
        reopened.openArchive(saved)
        #expect(ScanArchive.admits(replugged, for: saved.device))
        #expect(await reopened.reconnect(replugged, open: ScanArchiveSource.open) == .connected)
        let source = try #require(reopened.source)
        for (path, data) in Self.contents {
            let file = try #require(reopened.files.first { $0.path == "/" + path })
            #expect(try await ScanArchiveIdentityAndPrivacyTests.contents(of: file, from: source) == data, "\(path) is byte-identical")
        }
        reopened.releaseSource()

        // Another image of the same size and layout, with the same files: another drive.
        let lookalike = try await images.attach(try images.create("other", layout: layout, filesystem: filesystem, contents: Self.contents))
        let other = try await Self.device(lookalike)
        #expect(other.sizeBytes == original.sizeBytes)
        #expect(other.stableIdentity != nil && other.stableIdentity != identity)
        let refused = ScanViewModel { _, _ in }
        refused.openArchive(saved)
        let opener = CountingOpener(data: Data())
        #expect(await refused.reconnect(other, open: opener.open) == .notThisDevice)
        #expect(opener.opened == 0, "A lookalike is never opened")

        // The same drive with its volume erased in place to the same format: the GPT GUID and the
        // layout stay, the volume's UUID doesn't. (Simulated on a copy of the image file by giving
        // the exFAT volume a new serial number; no device is written.)
        if layout == "GPTSPUD" {
            let erased = images.url.appending(path: "erased.dmg")
            var bytes = try Data(contentsOf: image)
            ExFATBoot.setSerial(0x1234_5678, in: &bytes, volumeAt: 1_048_576)
            try bytes.write(to: erased)
            let erasedDevice = try await Self.device(try await images.attach(erased))
            #expect(erasedDevice.stableIdentity?.diskGUID == identity.diskGUID)
            let erasedVolumes = try #require(erasedDevice.stableIdentity?.volumes)
            #expect(erasedVolumes.count == 1 && erasedVolumes[0].offsetBytes == identity.volumes[0].offsetBytes,
                    "macOS still recognizes the volume, at the same offset")
            #expect(erasedVolumes[0].volumeUUID != identity.volumes[0].volumeUUID)
            #expect(await refused.reconnect(erasedDevice, open: opener.open) == .notThisDevice)
            #expect(opener.opened == 0, "An erased drive is never opened")
        }
        try await waitFor { reopened.source == nil }
    }

    /// The attached device as the app's device watcher publishes it.
    static func device(_ bsdName: String) async throws -> BlockDevice {
        let stream = try await DeviceWatcher().watch()
        let deadline = ContinuousClock.now + .seconds(20)
        for await devices in stream {
            if let device = devices.first(where: { $0.bsdName == bsdName }), device.stableIdentity != nil { return device }
            guard ContinuousClock.now < deadline else { break }
        }
        throw ImageFailure("\(bsdName) didn't appear with a stable identity.")
    }
}

/// A temp directory of disk images, each attached without mounting; everything attached is
/// detached and the directory deleted when the value goes away.
private final class ImageFolder {
    let url: URL
    private var attached: [String] = []

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(path: "SalvageReplug-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        for disk in attached { _ = Self.hdiutil(["detach", "-force", disk]) }
        try? FileManager.default.removeItem(at: url)
    }

    func create(_ name: String, layout: String, filesystem: String, contents: [(String, Data)]) throws -> URL {
        let source = url.appending(path: "\(name)-files", directoryHint: .isDirectory)
        for (path, data) in contents {
            let file = source.appending(path: path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file)
        }
        let image = url.appending(path: "\(name).dmg")
        let result = Self.hdiutil(["create", "-quiet", "-srcfolder", source.path, "-size", "8m", "-fs", filesystem,
                                   "-volname", name.uppercased(), "-layout", layout, "-format", "UDRW", image.path])
        guard result.status == 0 else { throw ImageFailure("hdiutil couldn't create an image here (set SALVAGE_SKIP_HDIUTIL=1 to skip).") }
        return image
    }

    func attach(_ image: URL) async throws -> String {
        let result = Self.hdiutil(["attach", "-nobrowse", "-nomount", image.path])
        let nodes = result.output.split(separator: "\n").compactMap { line in
            line.split(separator: "\t").first.map { $0.trimmingCharacters(in: .whitespaces) }
        }.filter { $0.hasPrefix("/dev/disk") }
        guard result.status == 0, let whole = nodes.min(by: { $0.count < $1.count }) else {
            throw ImageFailure("hdiutil couldn't attach an image here (set SALVAGE_SKIP_HDIUTIL=1 to skip).")
        }
        let name = String(whole.dropFirst("/dev/".count))
        attached.append(name)
        return name
    }

    func detach(_ disk: String) {
        _ = Self.hdiutil(["detach", "-force", disk])
        attached.removeAll { $0 == disk }
    }

    static func hdiutil(_ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

/// Rewrites an exFAT volume's serial number in an image file, with the boot checksum and the
/// backup boot region updated to match.
private enum ExFATBoot {
    static func setSerial(_ serial: UInt32, in image: inout Data, volumeAt base: Int) {
        for index in 0..<4 { image[base + 100 + index] = UInt8(truncatingIfNeeded: serial >> (index * 8)) }
        let sector = 1 << Int(image[base + 108])
        var checksum: UInt32 = 0
        for index in 0..<(11 * sector) where index != 106 && index != 107 && index != 112 {
            checksum = (checksum & 1 != 0 ? 0x8000_0000 : 0) &+ (checksum >> 1) &+ UInt32(image[base + index])
        }
        for word in stride(from: 0, to: sector, by: 4) {
            for index in 0..<4 { image[base + 11 * sector + word + index] = UInt8(truncatingIfNeeded: checksum >> (index * 8)) }
        }
        image.replaceSubrange(base + 12 * sector..<base + 24 * sector, with: image.subdata(in: base..<base + 12 * sector))
    }
}

private struct ImageFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

@MainActor private func waitFor(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(30)
    while !condition() {
        guard ContinuousClock.now < deadline else { throw CancellationError() }
        try await Task.sleep(for: .milliseconds(5))
    }
}

// MARK: - Fixtures

private struct ArchiveMemoryReader: BlockReader {
    let data: Data
    var sizeBytes: Int64 { Int64(data.count) }
    func read(at offset: Int64, count: Int) async throws -> Data {
        guard offset >= 0, count >= 0, Int64(count) <= sizeBytes - offset else { throw ScanError.io("Out of range.") }
        return data.subdata(in: Int(offset)..<Int(offset) + count)
    }
}

/// Opens an in-memory device and counts sessions opened and closed.
private final class CountingOpener: @unchecked Sendable {
    let data: Data
    private let lock = NSLock()
    private var counts = (opened: 0, closed: 0)
    var opened: Int { lock.withLock { counts.opened } }
    var closed: Int { lock.withLock { counts.closed } }
    init(data: Data) { self.data = data }
    var open: @Sendable (BlockDevice) async throws -> SourceSession {
        { [self] device in
            lock.withLock { counts.opened += 1 }
            return SourceSession(device: device, reader: ArchiveMemoryReader(data: data), close: { [self] in
                lock.withLock { counts.closed += 1 }
            })
        }
    }
}

/// The version 1 file list, as the first saved-scan release wrote it: metadata record bytes after
/// the allocation anchor, and resident data as content kind 1.
enum LegacyFileList {
    static func encodeVersion1(_ files: [RecoveredFile]) -> Data {
        var out = [UInt8]()
        func fixed(_ value: UInt64, _ width: Int) { for index in 0..<width { out.append(UInt8(truncatingIfNeeded: value >> (index * 8))) } }
        func varint(_ value: UInt64) {
            var v = value
            while v >= 0x80 { out.append(UInt8(v & 0x7f) | 0x80); v >>= 7 }
            out.append(UInt8(v))
        }
        func signed(_ value: Int64) { varint(UInt64(bitPattern: (value << 1) ^ (value >> 63))) }
        func blob(_ data: Data) { varint(UInt64(data.count)); out += data }
        func string(_ text: String) { varint(UInt64(text.utf8.count)); out += text.utf8 }
        func runs(_ runs: [DataRun]) {
            varint(UInt64(runs.count))
            for run in runs {
                out.append((run.deviceOffset != nil ? 1 : 0) | (run.firstDataUnit != nil ? 2 : 0))
                if let offset = run.deviceOffset { signed(offset) }
                signed(run.length)
                if let unit = run.firstDataUnit { varint(unit) }
            }
        }
        out += Array("SLVGFLST".utf8)
        fixed(1, 4)
        fixed(UInt64(files.count), 8)
        for file in files {
            withUnsafeBytes(of: file.id.uuid) { out += $0 }
            let meta = file.sourceMetadata
            var flags: UInt8 = 0
            if file.isDeleted { flags |= 1 }
            if file.isPartial { flags |= 2 }
            if meta.contiguous { flags |= 4 }
            if file.recoveryMethod == .carved { flags |= 8 }
            if file.modified != nil { flags |= 16 }
            if meta.volumeName != nil { flags |= 32 }
            if meta.volumeID != nil { flags |= 64 }
            out.append(flags)
            string(file.name); string(file.path); signed(file.sizeBytes)
            if let modified = file.modified { fixed(modified.timeIntervalSinceReferenceDate.bitPattern, 8) }
            fixed(file.overwriteConfidence.bitPattern, 8)
            string(meta.filesystem.rawValue); signed(meta.volumeOffset); signed(meta.recordOffset); varint(meta.allocationStart)
            blob(meta.rawRecord)
            if let name = meta.volumeName { string(name) }
            if let id = meta.volumeID { string(id) }
            switch file.content {
            case .unmapped: out.append(0)
            case .resident(let data): out.append(1); blob(data)
            case .runs(let list): out.append(2); runs(list)
            case .encryptedRuns(let list, let keyID): out.append(3); string(keyID); runs(list)
            }
        }
        return Data(out)
    }
}

/// A small NTFS volume built field by field (as SalvageCore's NTFS tests build theirs): 512-byte
/// sectors and clusters, 1 KiB MFT records at cluster 16, `$Bitmap` at cluster 90, 255 clusters.
struct NTFSFixture {
    static let sector = 512, recordSize = 1024, clusterCount = 255
    var records: [Int: Data] = [:]
    /// `$MFT`'s runs (first cluster, cluster count); 64 clusters hold its 32 records.
    var mftRuns: [(lcn: Int, length: Int)] = [(16, 64)]

    static func put(_ data: inout Data, _ offset: Int, _ value: UInt64, _ width: Int) {
        for index in 0..<width { data[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8)) }
    }
    static func align8(_ value: Int) -> Int { (value + 7) & ~7 }

    static func resident(_ type: UInt32, _ value: Data, name: String = "") -> Data {
        let nameData = Data(name.utf16.flatMap { [UInt8($0 & 0xff), UInt8($0 >> 8)] })
        let valueOffset = align8(0x18 + nameData.count)
        var a = Data(count: align8(valueOffset + value.count))
        put(&a, 0, UInt64(type), 4); put(&a, 4, UInt64(a.count), 4)
        put(&a, 9, UInt64(name.utf16.count), 1); put(&a, 10, 0x18, 2)
        a.replaceSubrange(0x18..<0x18 + nameData.count, with: nameData)
        put(&a, 0x10, UInt64(value.count), 4); put(&a, 0x14, UInt64(valueOffset), 2)
        a.replaceSubrange(valueOffset..<valueOffset + value.count, with: value)
        return a
    }

    static func nonResident(_ type: UInt32, lcn: Int, clusters: Int, size: Int) -> Data {
        nonResident(type, runs: [(lcn, clusters)], size: size)
    }

    /// Runs of under 128 clusters starting below cluster 128, so every field is one byte.
    static func nonResident(_ type: UInt32, runs list: [(lcn: Int, length: Int)], size: Int) -> Data {
        var runs = Data(), previous = 0
        for run in list {
            runs += Data([0x11, UInt8(run.length), UInt8(bitPattern: Int8(run.lcn - previous))]); previous = run.lcn
        }
        runs.append(0)
        let clusters = list.reduce(0) { $0 + $1.length }
        var a = Data(count: align8(0x40 + runs.count))
        put(&a, 0, UInt64(type), 4); put(&a, 4, UInt64(a.count), 4); put(&a, 8, 1, 1); put(&a, 10, 0x40, 2)
        put(&a, 0x18, UInt64(clusters - 1), 8); put(&a, 0x20, 0x40, 2)
        put(&a, 0x28, UInt64(clusters * sector), 8); put(&a, 0x30, UInt64(size), 8); put(&a, 0x38, UInt64(size), 8)
        a.replaceSubrange(0x40..<0x40 + runs.count, with: runs)
        return a
    }

    /// 2024-01-02 as FILETIME.
    static func standardInformation() -> Data {
        var value = Data(count: 0x48)
        put(&value, 8, (1_704_153_600 + 11_644_473_600) * 10_000_000, 8)
        return resident(0x10, value)
    }

    static func fileName(_ name: String, parent: Int, sequence: Int, namespace: UInt8 = 1) -> Data {
        let units = Array(name.utf16)
        var value = Data(count: 0x42 + units.count * 2)
        put(&value, 0, UInt64(sequence) << 48 | UInt64(parent), 8)
        put(&value, 0x40, UInt64(units.count), 1); put(&value, 0x41, UInt64(namespace), 1)
        for (index, unit) in units.enumerated() { put(&value, 0x42 + index * 2, UInt64(unit), 2) }
        return resident(0x30, value)
    }

    /// A fixed-up-on-disk FILE record: stride tails hold the sequence number, the originals the array.
    static func record(number: Int, sequence: Int, flags: Int, _ attributes: [Data]) -> Data {
        var r = Data(count: recordSize)
        r.replaceSubrange(0..<4, with: Data("FILE".utf8))
        put(&r, 4, 0x30, 2); put(&r, 6, UInt64(recordSize / 512 + 1), 2)
        put(&r, 0x10, UInt64(sequence), 2); put(&r, 0x12, 1, 2); put(&r, 0x14, 0x38, 2); put(&r, 0x16, UInt64(flags), 2)
        put(&r, 0x2c, UInt64(number), 4)
        var offset = 0x38
        for attribute in attributes { r.replaceSubrange(offset..<offset + attribute.count, with: attribute); offset += attribute.count }
        put(&r, offset, 0xffff_ffff, 4); offset += 8
        put(&r, 0x18, UInt64(offset), 4); put(&r, 0x1c, UInt64(recordSize), 4)
        let usn: UInt64 = 0x4b1d
        put(&r, 0x30, usn, 2)
        for stride in 1...recordSize / 512 {
            let tail = stride * 512 - 2
            put(&r, 0x30 + stride * 2, UInt64(r[tail]) | UInt64(r[tail + 1]) << 8, 2); put(&r, tail, usn, 2)
        }
        return r
    }

    static func file(_ name: String, data: Data) -> Data {
        // The record number is filled in by `build`.
        [standardInformation(), fileName(name, parent: 5, sequence: 5), data].reduce(into: Data()) { $0 += $1 }
    }

    func build() -> Data {
        let sector = Self.sector
        var image = Data(count: (Self.clusterCount + 1) * sector)
        image.replaceSubrange(3..<11, with: Data("NTFS    ".utf8))
        Self.put(&image, 11, UInt64(sector), 2); Self.put(&image, 13, 1, 1)
        Self.put(&image, 0x28, UInt64(Self.clusterCount), 8); Self.put(&image, 0x30, 16, 8); Self.put(&image, 0x38, 2, 8)
        Self.put(&image, 0x40, 0xf6, 1); Self.put(&image, 0x44, 0xf4, 1); Self.put(&image, 510, 0xaa55, 2)
        var bitmap = Data(count: (Self.clusterCount + 7) / 8)
        var used = Set(0..<91)
        for run in mftRuns { used.formUnion(run.lcn..<run.lcn + run.length) }
        for cluster in used { bitmap[cluster / 8] |= UInt8(1) << (cluster % 8) }
        var all: [Int: Data] = [:]
        all[0] = Self.record(number: 0, sequence: 1, flags: 1, [
            Self.standardInformation(), Self.fileName("$MFT", parent: 5, sequence: 5, namespace: 3),
            Self.nonResident(0x80, runs: mftRuns, size: 32 * Self.recordSize)])
        all[5] = Self.record(number: 5, sequence: 5, flags: 3, [
            Self.standardInformation(), Self.fileName(".", parent: 5, sequence: 5, namespace: 3),
            Self.resident(0x90, Data(count: 16), name: "$I30")])
        all[6] = Self.record(number: 6, sequence: 6, flags: 1, [
            Self.fileName("$Bitmap", parent: 5, sequence: 5, namespace: 3),
            Self.nonResident(0x80, lcn: 90, clusters: 1, size: bitmap.count)])
        for (number, attributes) in records {
            // `file` returns the attributes run together; split them back by their length fields.
            var parts: [Data] = [], offset = 0
            while offset < attributes.count {
                let length = Int(attributes[offset + 4]) | Int(attributes[offset + 5]) << 8
                parts.append(attributes.subdata(in: offset..<offset + length)); offset += length
            }
            all[number] = Self.record(number: number, sequence: 1, flags: 1, parts)
        }
        for (number, bytes) in all {
            for index in 0..<Self.recordSize {
                var cluster = (number * Self.recordSize + index) / sector, located: Int?
                for run in mftRuns {
                    if cluster < run.length { located = run.lcn + cluster; break }
                    cluster -= run.length
                }
                image[located! * sector + (number * Self.recordSize + index) % sector] = bytes[index]
            }
        }
        image.replaceSubrange(90 * sector..<90 * sector + bitmap.count, with: bitmap)
        return image
    }
}
