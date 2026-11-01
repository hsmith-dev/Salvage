import CryptoKit
import Foundation
import SalvageCore
import UniformTypeIdentifiers

/// A saved scan (spec-tech-batch-7 §B): a `.salvagescan` package, a folder holding
///
/// - `Info.json`: the format version, the scanned device's identity (media identity, size, model
///   name and partitions), the extent fingerprint (the scan's newest checkpoint, offsets and sizes
///   only), the outcome, notices, lost partitions, and the file count and SHA-256 of the file list;
/// - `Files.bin`: every `RecoveredFile` in a compact binary list, content runs included.
///
/// It never holds credentials or keys. A scan's passwords, recovery keys and volume decryptors live
/// only in `ScanRun.credentials` and `SourceSession.decryptors`, and nothing here reads either: an
/// encrypted file is saved as its ciphertext runs and its volume UUID (`keyID`), so it needs the
/// password again after reopening.
///
/// A reopened scan has no source. `ScanViewModel.reconnect` adopts a device only once its media
/// identity and size match (checked before anything is opened) and its freshly read extent
/// fingerprint equals the saved one (`ScanArchive.admits`, `ExtentFingerprint`).
struct ScanArchive: Equatable, Sendable {
    /// Bumped on any incompatible change; any other version is refused (`ArchiveError.unsupportedVersion`).
    static let formatVersion = 1
    static let fileExtension = "salvagescan"
    static let infoFileName = "Info.json"
    static let filesFileName = "Files.bin"
    /// The one privacy warning, shown in the save panel. Kept here so it is written once.
    static let privacyNotice = "This file lists the names of the files Salvage found."
    static var contentType: UTType { UTType(filenameExtension: fileExtension, conformingTo: .package) ?? .package }

    enum Outcome: Equatable, Sendable { case completed, cancelled, failed(ScanError) }

    var device: BlockDevice
    var files: [RecoveredFile]
    var lostPartitions: [LostPartitionCandidate]
    var notices: [ScanNotice]
    /// The scan's newest checkpoint; its `extents` are the fingerprint. Nil when the scan stopped
    /// before mapping the device, and then the saved scan can never be reconnected.
    var checkpoint: ScanCheckpoint?
    var outcome: Outcome
    var bytesScanned: Int64
    var totalBytes: Int64
    var startedAt: Date?
    var endedAt: Date?
    var savedAt: Date

    var fingerprint: [ScanCheckpoint.Extent]? { checkpoint?.extents }

    /// True when `candidate` may be opened to check its fingerprint: the same attachment (media
    /// identity) of a device of the same size. A device without a media identity never matches.
    static func admits(_ candidate: BlockDevice, for archived: BlockDevice) -> Bool {
        guard let identity = archived.mediaIdentity, candidate.mediaIdentity == identity,
              candidate.sizeBytes == archived.sizeBytes, !candidate.isBootVolume else { return false }
        return true
    }

    /// True when encrypted files are listed: they need the password again after reopening.
    var hasEncryptedFiles: Bool {
        files.contains { if case .encryptedRuns = $0.content { true } else { false } }
    }
}

// MARK: - Errors

enum ScanArchiveError: Error, Equatable, CustomStringConvertible {
    case notAScan
    case unsupportedVersion(Int)
    case damaged
    case couldNotWrite(String)

    var description: String {
        switch self {
        case .notAScan: "This isn't a saved Salvage scan."
        case .unsupportedVersion: "This saved scan was made by a different version of Salvage and can't be opened here."
        case .damaged: "This saved scan is damaged and can't be opened."
        case .couldNotWrite(let reason): "Salvage couldn't save the scan. \(reason)"
        }
    }
}

// MARK: - Reading and writing

extension ScanArchive {
    /// Writes the package to `url`, replacing what is there (the save panel has asked). The package
    /// is built beside `url` and moved into place, so a failed save never leaves half a package.
    func write(to url: URL) throws {
        let fileList = FileListCodec.encode(files)
        let info = Info(archive: self, fileListDigest: Self.digest(fileList))
        let encoder = JSONEncoder()
        // Dates keep the default encoding (seconds since 2001, as a double), which round-trips exactly.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let fm = FileManager.default
        let staging = url.deletingLastPathComponent()
            .appending(path: ".\(url.lastPathComponent)-\(UUID().uuidString)", directoryHint: .isDirectory)
        do {
            let infoData = try encoder.encode(info)
            try fm.createDirectory(at: staging, withIntermediateDirectories: false,
                                   attributes: [.posixPermissions: 0o700])
            // Only the user may read it: it lists file names.
            for (name, data) in [(Self.infoFileName, infoData), (Self.filesFileName, fileList)] {
                let file = staging.appending(path: name, directoryHint: .notDirectory)
                guard fm.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                    throw ScanArchiveError.couldNotWrite("The folder may be read-only or full.")
                }
            }
            if fm.fileExists(atPath: url.path) {
                _ = try fm.replaceItemAt(url, withItemAt: staging)
            } else {
                try fm.moveItem(at: staging, to: url)
            }
        } catch {
            try? fm.removeItem(at: staging)
            if let error = error as? ScanArchiveError { throw error }
            throw ScanArchiveError.couldNotWrite("The folder may be read-only or full.")
        }
    }

    /// Reads a package. The version is checked before anything else is decoded.
    static func read(from url: URL) throws -> ScanArchive {
        let infoURL = url.appending(path: infoFileName, directoryHint: .notDirectory)
        guard let infoData = try? Data(contentsOf: infoURL) else { throw ScanArchiveError.notAScan }
        let decoder = JSONDecoder()
        guard let header = try? decoder.decode(VersionHeader.self, from: infoData),
              header.format == Info.formatName else { throw ScanArchiveError.notAScan }
        guard header.formatVersion == formatVersion else { throw ScanArchiveError.unsupportedVersion(header.formatVersion) }
        guard let info = try? decoder.decode(Info.self, from: infoData),
              let fileList = try? Data(contentsOf: url.appending(path: filesFileName, directoryHint: .notDirectory)),
              digest(fileList) == info.fileListSHA256 else { throw ScanArchiveError.damaged }
        let files = try FileListCodec.decode(fileList)
        guard files.count == info.fileCount else { throw ScanArchiveError.damaged }
        return try info.archive(files: files)
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Info.json

private struct VersionHeader: Decodable {
    let format: String
    let formatVersion: Int
}

private struct Info: Codable {
    static let formatName = "Salvage saved scan"

    struct Device: Codable {
        let bsdName: String
        let displayName: String
        let sizeBytes: Int64
        let isInternal: Bool
        /// A string: IORegistry IDs are 64-bit, and JSON numbers are not exact past 2^53.
        let mediaIdentity: String?
        let partitions: [Partition]
    }
    struct Partition: Codable {
        let bsdName: String
        let displayName: String
        let sizeBytes: Int64?
        let formatName: String
        let offsetBytes: Int64?
        let children: [Partition]
        init(_ p: DevicePartition) {
            bsdName = p.bsdName; displayName = p.displayName; sizeBytes = p.sizeBytes; formatName = p.formatName
            offsetBytes = p.offsetBytes; children = p.children.map(Partition.init)
        }
        var value: DevicePartition {
            DevicePartition(bsdName: bsdName, displayName: displayName, sizeBytes: sizeBytes, formatName: formatName,
                            children: children.map(\.value), offsetBytes: offsetBytes)
        }
    }
    struct LostPartition: Codable {
        let id: UUID
        let offset: Int64
        let sizeBytes: Int64
        let formatName: String
    }
    enum Unlock: String, Codable {
        case wrongPassword, toolFailure, unsupported, damaged
        init(_ error: UnlockError) {
            switch error {
            case .wrongPassword: self = .wrongPassword
            case .toolFailure: self = .toolFailure
            case .unsupported: self = .unsupported
            case .damaged: self = .damaged
            }
        }
        var value: UnlockError {
            switch self {
            case .wrongPassword: .wrongPassword
            case .toolFailure: .toolFailure
            case .unsupported: .unsupported
            case .damaged: .damaged
            }
        }
    }
    enum Failure: Codable {
        case unsupportedFilesystem, malformed(String), io(String), unsafeTarget(String), deviceInUse
        case permissionDenied, deviceChanged, unlockFailed(Unlock)
    }
    enum Outcome: Codable { case completed, cancelled, failed(Failure) }
    enum Notice: Codable {
        case partitionTableIgnored(reason: String)
        case lostPartitionSearchLimited(searchedBytes: Int64, deviceBytes: Int64)
        case unreadableAreasSkipped(count: Int)
        case carvingLimitReached(count: Int)
        case signaturesSkipped([String])
        case resumedCarvingPartial
        case volumeSkipped(formatName: String, offset: Int64, reason: String)
        case damagedItemsSkipped(count: Int, examples: [String])
    }

    let format: String
    let formatVersion: Int
    let savedAt: Date
    let appVersion: String?
    let device: Device
    let checkpoint: ScanCheckpoint?
    let outcome: Outcome
    let bytesScanned: Int64
    let totalBytes: Int64
    let startedAt: Date?
    let endedAt: Date?
    let lostPartitions: [LostPartition]
    let notices: [Notice]
    let fileCount: Int
    let fileListSHA256: String

    init(archive a: ScanArchive, fileListDigest: String) {
        format = Self.formatName
        formatVersion = ScanArchive.formatVersion
        savedAt = a.savedAt
        appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let d = a.device
        device = Device(bsdName: d.bsdName, displayName: d.displayName, sizeBytes: d.sizeBytes, isInternal: d.isInternal,
                        mediaIdentity: d.mediaIdentity.map(String.init), partitions: d.partitions.map(Partition.init))
        checkpoint = a.checkpoint
        outcome = switch a.outcome {
        case .completed: .completed
        case .cancelled: .cancelled
        case .failed(let error): .failed(Self.failure(error))
        }
        bytesScanned = a.bytesScanned; totalBytes = a.totalBytes
        startedAt = a.startedAt; endedAt = a.endedAt
        lostPartitions = a.lostPartitions.map { LostPartition(id: $0.id, offset: $0.offset, sizeBytes: $0.sizeBytes, formatName: $0.formatName) }
        notices = a.notices.map(Self.notice)
        fileCount = a.files.count
        fileListSHA256 = fileListDigest
    }

    func archive(files: [RecoveredFile]) throws -> ScanArchive {
        var identity: UInt64?
        if let text = device.mediaIdentity {
            guard let value = UInt64(text) else { throw ScanArchiveError.damaged }
            identity = value
        }
        guard device.sizeBytes > 0, bytesScanned >= 0, totalBytes >= 0, checkpoint?.isWellFormed ?? true,
              checkpoint.map({ $0.deviceSizeBytes == device.sizeBytes }) ?? true else { throw ScanArchiveError.damaged }
        let blockDevice = BlockDevice(bsdName: device.bsdName, displayName: device.displayName, sizeBytes: device.sizeBytes,
                                      isInternal: device.isInternal, isBootVolume: false, mediaIdentity: identity,
                                      partitions: device.partitions.map(\.value))
        let outcome: ScanArchive.Outcome = switch self.outcome {
        case .completed: .completed
        case .cancelled: .cancelled
        case .failed(let failure): .failed(Self.error(failure))
        }
        return ScanArchive(device: blockDevice, files: files,
                           lostPartitions: lostPartitions.map { LostPartitionCandidate(id: $0.id, offset: $0.offset,
                                                                                       sizeBytes: $0.sizeBytes, formatName: $0.formatName) },
                           notices: notices.map(Self.notice), checkpoint: checkpoint, outcome: outcome,
                           bytesScanned: bytesScanned, totalBytes: totalBytes, startedAt: startedAt, endedAt: endedAt,
                           savedAt: savedAt)
    }

    private static func failure(_ error: ScanError) -> Failure {
        switch error {
        case .unsupportedFilesystem: .unsupportedFilesystem
        case .malformed(let r): .malformed(r)
        case .io(let r): .io(r)
        case .unsafeTarget(let r): .unsafeTarget(r)
        case .deviceInUse: .deviceInUse
        case .permissionDenied: .permissionDenied
        case .deviceChanged: .deviceChanged
        case .unlockFailed(let u): .unlockFailed(Unlock(u))
        }
    }

    private static func error(_ failure: Failure) -> ScanError {
        switch failure {
        case .unsupportedFilesystem: .unsupportedFilesystem
        case .malformed(let r): .malformed(r)
        case .io(let r): .io(r)
        case .unsafeTarget(let r): .unsafeTarget(r)
        case .deviceInUse: .deviceInUse
        case .permissionDenied: .permissionDenied
        case .deviceChanged: .deviceChanged
        case .unlockFailed(let u): .unlockFailed(u.value)
        }
    }

    private static func notice(_ n: ScanNotice) -> Notice {
        switch n {
        case .partitionTableIgnored(let r): .partitionTableIgnored(reason: r)
        case .lostPartitionSearchLimited(let s, let d): .lostPartitionSearchLimited(searchedBytes: s, deviceBytes: d)
        case .unreadableAreasSkipped(let c): .unreadableAreasSkipped(count: c)
        case .carvingLimitReached(let c): .carvingLimitReached(count: c)
        case .signaturesSkipped(let f): .signaturesSkipped(f)
        case .resumedCarvingPartial: .resumedCarvingPartial
        case .volumeSkipped(let f, let o, let r): .volumeSkipped(formatName: f, offset: o, reason: r)
        case .damagedItemsSkipped(let c, let e): .damagedItemsSkipped(count: c, examples: e)
        }
    }

    private static func notice(_ n: Notice) -> ScanNotice {
        switch n {
        case .partitionTableIgnored(let r): .partitionTableIgnored(reason: r)
        case .lostPartitionSearchLimited(let s, let d): .lostPartitionSearchLimited(searchedBytes: s, deviceBytes: d)
        case .unreadableAreasSkipped(let c): .unreadableAreasSkipped(count: c)
        case .carvingLimitReached(let c): .carvingLimitReached(count: c)
        case .signaturesSkipped(let f): .signaturesSkipped(f)
        case .resumedCarvingPartial: .resumedCarvingPartial
        case .volumeSkipped(let f, let o, let r): .volumeSkipped(formatName: f, offset: o, reason: r)
        case .damagedItemsSkipped(let c, let e): .damagedItemsSkipped(count: c, examples: e)
        }
    }
}

// MARK: - Files.bin

/// The binary file list: an 8-byte magic, the format version (UInt32 LE) and the file count
/// (UInt64 LE), then one record per file. Integers are LEB128 varints (signed ones zigzagged),
/// doubles their 8-byte bit pattern, the filesystem its raw name, strings and byte blobs a varint length then the bytes.
enum FileListCodec {
    static let magic = Array("SLVGFLST".utf8)

    private struct Flags: OptionSet {
        let rawValue: UInt8
        static let deleted = Flags(rawValue: 1 << 0)
        static let partial = Flags(rawValue: 1 << 1)
        static let contiguous = Flags(rawValue: 1 << 2)
        static let carved = Flags(rawValue: 1 << 3)
        static let hasModified = Flags(rawValue: 1 << 4)
        static let hasVolumeName = Flags(rawValue: 1 << 5)
        static let hasVolumeID = Flags(rawValue: 1 << 6)
    }
    private struct RunFlags: OptionSet {
        let rawValue: UInt8
        static let placed = RunFlags(rawValue: 1 << 0)
        static let hasDataUnit = RunFlags(rawValue: 1 << 1)
    }

    static func encode(_ files: [RecoveredFile]) -> Data {
        var out = Writer()
        out.bytes.reserveCapacity(64 + files.count * 160)
        out.bytes += magic
        out.fixed(UInt64(ScanArchive.formatVersion), width: 4)
        out.fixed(UInt64(files.count), width: 8)
        for file in files {
            withUnsafeBytes(of: file.id.uuid) { out.bytes += $0 }
            var flags: Flags = []
            if file.isDeleted { flags.insert(.deleted) }
            if file.isPartial { flags.insert(.partial) }
            if file.sourceMetadata.contiguous { flags.insert(.contiguous) }
            if file.recoveryMethod == .carved { flags.insert(.carved) }
            if file.modified != nil { flags.insert(.hasModified) }
            if file.sourceMetadata.volumeName != nil { flags.insert(.hasVolumeName) }
            if file.sourceMetadata.volumeID != nil { flags.insert(.hasVolumeID) }
            out.bytes.append(flags.rawValue)
            out.string(file.name)
            out.string(file.path)
            out.signed(file.sizeBytes)
            if let modified = file.modified { out.fixed(modified.timeIntervalSinceReferenceDate.bitPattern, width: 8) }
            out.fixed(file.overwriteConfidence.bitPattern, width: 8)
            let meta = file.sourceMetadata
            out.string(meta.filesystem.rawValue)
            out.signed(meta.volumeOffset)
            out.signed(meta.recordOffset)
            out.varint(meta.allocationStart)
            out.blob(meta.rawRecord)
            if let name = meta.volumeName { out.string(name) }
            if let id = meta.volumeID { out.string(id) }
            switch file.content {
            case .unmapped: out.bytes.append(0)
            case .resident(let data): out.bytes.append(1); out.blob(data)
            case .runs(let runs): out.bytes.append(2); out.runs(runs)
            case .encryptedRuns(let runs, let keyID): out.bytes.append(3); out.string(keyID); out.runs(runs)
            }
        }
        return Data(out.bytes)
    }

    static func decode(_ data: Data) throws -> [RecoveredFile] {
        var input = Reader(bytes: [UInt8](data))
        guard Array(try input.take(magic.count)) == magic else { throw ScanArchiveError.damaged }
        let version = try input.fixed(width: 4)
        guard version == UInt64(ScanArchive.formatVersion) else { throw ScanArchiveError.unsupportedVersion(Int(clamping: version)) }
        let count = try input.fixed(width: 8)
        // Every record takes well over 16 bytes, so a count the data can't hold is damage, not a reason to reserve.
        guard count <= UInt64(input.remaining / 16) else { throw ScanArchiveError.damaged }
        var files: [RecoveredFile] = []
        files.reserveCapacity(Int(count))
        for _ in 0..<count {
            let idBytes = Array(try input.take(16))
            let id = UUID(uuid: (idBytes[0], idBytes[1], idBytes[2], idBytes[3], idBytes[4], idBytes[5], idBytes[6], idBytes[7],
                                 idBytes[8], idBytes[9], idBytes[10], idBytes[11], idBytes[12], idBytes[13], idBytes[14], idBytes[15]))
            let flags = Flags(rawValue: try input.byte())
            let name = try input.string()
            let path = try input.string()
            let size = try input.signed()
            let modified = flags.contains(.hasModified)
                ? Date(timeIntervalSinceReferenceDate: Double(bitPattern: try input.fixed(width: 8))) : nil
            let overwrite = Double(bitPattern: try input.fixed(width: 8))
            guard let filesystem = SourceMetadata.Filesystem(rawValue: try input.string()) else { throw ScanArchiveError.damaged }
            let volumeOffset = try input.signed()
            let recordOffset = try input.signed()
            let allocationStart = try input.varint()
            let rawRecord = try input.blob()
            let volumeName = flags.contains(.hasVolumeName) ? try input.string() : nil
            let volumeID = flags.contains(.hasVolumeID) ? try input.string() : nil
            let content: FileContent
            switch try input.byte() {
            case 0: content = .unmapped
            case 1: content = .resident(try input.blob())
            case 2: content = .runs(try input.runs())
            case 3:
                let keyID = try input.string()
                content = .encryptedRuns(try input.runs(), keyID: keyID)
            default: throw ScanArchiveError.damaged
            }
            guard size >= 0, overwrite.isFinite else { throw ScanArchiveError.damaged }
            files.append(RecoveredFile(
                id: id, name: name, path: path, sizeBytes: size, modified: modified, isDeleted: flags.contains(.deleted),
                sourceMetadata: SourceMetadata(filesystem: filesystem, volumeOffset: volumeOffset,
                                               recordOffset: recordOffset, allocationStart: allocationStart,
                                               contiguous: flags.contains(.contiguous), rawRecord: rawRecord,
                                               volumeName: volumeName, volumeID: volumeID),
                content: content, recoveryMethod: flags.contains(.carved) ? .carved : .metadata,
                isPartial: flags.contains(.partial), overwriteConfidence: overwrite))
        }
        guard input.remaining == 0 else { throw ScanArchiveError.damaged }
        return files
    }

    private struct Writer {
        var bytes: [UInt8] = []
        mutating func fixed(_ value: UInt64, width: Int) {
            for index in 0..<width { bytes.append(UInt8(truncatingIfNeeded: value >> (index * 8))) }
        }
        mutating func varint(_ value: UInt64) {
            var v = value
            while v >= 0x80 { bytes.append(UInt8(v & 0x7f) | 0x80); v >>= 7 }
            bytes.append(UInt8(v))
        }
        mutating func signed(_ value: Int64) { varint(UInt64(bitPattern: (value << 1) ^ (value >> 63))) }
        mutating func blob(_ data: Data) { varint(UInt64(data.count)); bytes += data }
        mutating func string(_ text: String) { varint(UInt64(text.utf8.count)); bytes += text.utf8 }
        mutating func runs(_ runs: [DataRun]) {
            varint(UInt64(runs.count))
            for run in runs {
                var flags: RunFlags = []
                if run.deviceOffset != nil { flags.insert(.placed) }
                if run.firstDataUnit != nil { flags.insert(.hasDataUnit) }
                bytes.append(flags.rawValue)
                if let offset = run.deviceOffset { signed(offset) }
                signed(run.length)
                if let unit = run.firstDataUnit { varint(unit) }
            }
        }
    }

    private struct Reader {
        let bytes: [UInt8]
        var position = 0
        var remaining: Int { bytes.count - position }

        mutating func byte() throws -> UInt8 {
            guard position < bytes.count else { throw ScanArchiveError.damaged }
            defer { position += 1 }
            return bytes[position]
        }
        mutating func take(_ count: Int) throws -> ArraySlice<UInt8> {
            guard count >= 0, count <= remaining else { throw ScanArchiveError.damaged }
            defer { position += count }
            return bytes[position..<position + count]
        }
        mutating func fixed(width: Int) throws -> UInt64 {
            var value: UInt64 = 0
            for (index, byte) in try take(width).enumerated() { value |= UInt64(byte) << (index * 8) }
            return value
        }
        mutating func varint() throws -> UInt64 {
            var value: UInt64 = 0, shift: UInt64 = 0
            while true {
                let byte = try self.byte()
                guard shift < 64, shift < 63 || byte <= 1 else { throw ScanArchiveError.damaged }
                value |= UInt64(byte & 0x7f) << shift
                if byte & 0x80 == 0 { return value }
                shift += 7
            }
        }
        mutating func signed() throws -> Int64 {
            let raw = try varint()
            return Int64(bitPattern: raw >> 1) ^ -Int64(bitPattern: raw & 1)
        }
        mutating func length() throws -> Int {
            let value = try varint()
            guard value <= UInt64(remaining) else { throw ScanArchiveError.damaged }
            return Int(value)
        }
        mutating func blob() throws -> Data { Data(try take(try length())) }
        mutating func string() throws -> String {
            guard let text = String(bytes: try take(try length()), encoding: .utf8) else { throw ScanArchiveError.damaged }
            return text
        }
        mutating func runs() throws -> [DataRun] {
            let count = try length()  // each run takes at least 2 bytes, so `count <= remaining` bounds it
            var runs: [DataRun] = []
            runs.reserveCapacity(count)
            for _ in 0..<count {
                let flags = RunFlags(rawValue: try byte())
                let offset = flags.contains(.placed) ? try signed() : nil
                let length = try signed()
                let unit = flags.contains(.hasDataUnit) ? try varint() : nil
                guard length >= 0, (offset ?? 0) >= 0 else { throw ScanArchiveError.damaged }
                runs.append(DataRun(deviceOffset: offset, length: length, firstDataUnit: unit))
            }
            return runs
        }
    }
}
