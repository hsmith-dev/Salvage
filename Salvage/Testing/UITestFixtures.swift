#if DEBUG
import CoreGraphics
import Foundation
import ImageIO
import SalvageCore
import SalvageDiskIO
import UniformTypeIdentifiers

/// DEBUG-only UI-test fixture (spec-tech-batch-5 §C). Launching a Debug build with
/// `-SalvageUITestFixture <name>` swaps the composition root's live adapters for in-memory fakes:
///
/// - the device watcher publishes a fixed device list (a grayed boot drive, a fixture drive and,
///   for `fileVault`, a FileVault-locked drive) instead of asking DiskArbitration;
/// - the scan runner drives the real `ScanSession` over an in-memory `BlockReader` holding a
///   synthetic exFAT image built here (no privileged helper, no raw device, nothing unmounted);
/// - recovery is pointed at the folder named by `-SalvageUITestDestination <dir>`, so no
///   `NSOpenPanel` is needed, and its destination check is decided by the fixture name;
/// - FileVault unlock is checked against `correctPassword` without reading any device;
/// - scan checkpoints are not saved (nothing goes to Application Support).
///
/// `-SalvageUITestExpected <dir>` additionally writes every fixture file's exact bytes there, at
/// its path on the image, so a test can compare recovered copies byte for byte.
///
/// The whole file, and every call site of it (see `CompositionRoot` in `ContentView.swift`), is
/// inside `#if DEBUG`: a Release build contains none of it. Nothing here uses the network.
struct UITestFixture: Sendable {
    enum Name: String, Sendable {
        /// Boot drive + fixture drive; a destination is safe.
        case standard
        /// As `standard`, but every sweep read is delayed so a test can pause and resume.
        case slowScan
        /// As `standard`, but every destination is treated as being on the source drive.
        case destinationOnSource
        /// As `standard`, plus a FileVault-locked drive offering the unlock sheet.
        case fileVault
    }

    static let fixtureArgument = "-SalvageUITestFixture"
    static let destinationArgument = "-SalvageUITestDestination"
    static let expectedArgument = "-SalvageUITestExpected"

    /// The only password the `fileVault` fixture accepts. `VolumeCredential` deliberately exposes
    /// no way to read its secret outside SalvageCore, so the fake check compares kind and length:
    /// the tests type this password (accepted) and `"wrong"` (rejected).
    static let correctPassword = "fixture-vault-pass"

    static let bootDrive = BlockDevice(bsdName: "disk990", displayName: "Fixture Macintosh HD", sizeBytes: 500_000_000_000,
                                       isInternal: true, isBootVolume: true,
                                       partitions: [DevicePartition(bsdName: "disk990s1", displayName: "Macintosh HD",
                                                                    sizeBytes: 499_000_000_000, formatName: "APFS")])
    static let lockedVolumeUUID = "5A1A6E00-F1C7-4E5A-9C0D-0000000000F1"

    /// The fixture launched with, if any; parsed once from the process arguments.
    static let active: UITestFixture? = UITestFixture(arguments: ProcessInfo.processInfo.arguments)

    let name: Name
    let destination: URL?
    let image: Data
    let fixtureDrive: BlockDevice
    let lockedDrive: BlockDevice

    init?(arguments: [String]) {
        guard let raw = Self.value(after: Self.fixtureArgument, in: arguments) else { return nil }
        guard let name = Name(rawValue: raw) else {
            // A typo must not silently fall back to the live adapters during a UI test.
            fatalError("Unknown \(Self.fixtureArgument) '\(raw)'")
        }
        self.name = name
        destination = Self.value(after: Self.destinationArgument, in: arguments).map { URL(fileURLWithPath: $0, isDirectory: true) }
        let size = name == .slowScan ? 64 * 1024 * 1024 : 8 * 1024 * 1024
        let files = Self.files()
        image = ExFATFixtureImage.build(files: files, sizeBytes: size)
        let partition = DevicePartition(bsdName: "disk991s1", displayName: "FIXTURE", sizeBytes: Int64(size), formatName: "exFAT")
        fixtureDrive = BlockDevice(bsdName: "disk991", displayName: "Salvage Fixture Drive", sizeBytes: Int64(size),
                                   isInternal: false, isBootVolume: false, partitions: [partition])
        lockedDrive = BlockDevice(bsdName: "disk992", displayName: "Locked Fixture Drive", sizeBytes: Int64(size),
                                  isInternal: false, isBootVolume: false,
                                  encryptedVolumeUUID: Self.lockedVolumeUUID, encryptedVolumeName: "Fixture Vault",
                                  partitions: [DevicePartition(bsdName: "disk992s1", displayName: "Fixture Vault",
                                                               sizeBytes: Int64(size), formatName: "APFS")])
        if let expected = Self.value(after: Self.expectedArgument, in: arguments) {
            Self.writeExpected(files, to: URL(fileURLWithPath: expected, isDirectory: true))
        }
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    // MARK: Fakes

    var devices: [BlockDevice] {
        name == .fileVault ? [Self.bootDrive, fixtureDrive, lockedDrive] : [Self.bootDrive, fixtureDrive]
    }

    var deviceWatcher: any DeviceWatching { FixtureDeviceWatcher(devices: devices) }

    /// The real `ScanSession` over the in-memory image, mirroring `ContentView.runScan`.
    var runScan: ScanViewModel.Runner {
        let reader = FixtureReader(data: image, sweepDelay: name == .slowScan ? .milliseconds(400) : nil)
        return { run, events in
            await ScanSession(reader: reader).run(events: events, pauseGate: run.pauseGate,
                                                  checkpoints: run.checkpoints, notices: run.notices,
                                                  resumingFrom: run.resumeFrom, device: run.device,
                                                  credentials: run.credentials)
            let decryptors = run.credentials.compactMapValues(\.decryptor)
            for credential in run.credentials.values { credential.zero() }
            await run.keepSource(SourceSession(device: run.device, reader: reader, decryptors: decryptors, close: {}))
        }
    }

    var verifyUnlock: UnlockViewModel.Verify {
        { device, credential in
            guard device.encryptedVolumeUUID == Self.lockedVolumeUUID else { return .failure(.toolFailure) }
            try? await Task.sleep(for: .milliseconds(200))
            let matches = credential.kind == .password && credential.count == Self.correctPassword.utf8.count
            return matches ? .success(()) : .failure(.wrongPassword)
        }
    }

    /// The fixture's verdict for a destination; the mount source is the real one, so the
    /// recovery engine's check of the folder it actually opens still applies.
    var destinationCheck: @Sendable (URL) -> DestinationAssessment {
        let blocks = name == .destinationOnSource
        return { url in
            DestinationAssessment(verdict: blocks ? .sameDevice : .safe,
                                  mountSource: mountSourceName(ofPath: url.resolvingSymlinksInPath().path))
        }
    }

    // MARK: Image contents

    /// The files on the fixture image: two pictures and three documents, two of them in folders.
    static func files() -> [(path: String, contents: Data)] {
        [
            ("/DCIM/IMG_0001.jpg", picture(type: .jpeg, seed: 1)),
            ("/DCIM/IMG_0002.png", picture(type: .png, seed: 2)),
            ("/Documents/notes.txt", Data("Salvage UI test fixture.\nThese notes live on a synthetic exFAT image.\n".utf8)),
            ("/Documents/budget.csv", Data((["item,amount"] + (1...200).map { "line \($0),\($0 * 3)" }).joined(separator: "\n").utf8)),
            ("/readme.txt", Data(String(repeating: "Fixture readme. ", count: 600).utf8)),
        ]
    }

    /// A small, deterministic picture encoded with ImageIO.
    private static func picture(type: UTType, seed: Int) -> Data {
        let width = 96, height = 64
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return Data() }
        for band in 0..<8 {
            let shade = CGFloat((band * 29 + seed * 71) % 255) / 255
            context.setFillColor(red: shade, green: 1 - shade, blue: CGFloat(seed) / 3, alpha: 1)
            context.fill(CGRect(x: band * width / 8, y: 0, width: width / 8, height: height))
        }
        guard let image = context.makeImage() else { return Data() }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return Data() }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return Data() }
        return data as Data
    }

    private static func writeExpected(_ files: [(path: String, contents: Data)], to root: URL) {
        for file in files {
            let url = root.appending(path: String(file.path.dropFirst()), directoryHint: .notDirectory)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? file.contents.write(to: url)
        }
    }
}

/// Publishes one fixed device list, once.
private struct FixtureDeviceWatcher: DeviceWatching {
    let devices: [BlockDevice]
    @MainActor func watch() async throws -> AsyncStream<[BlockDevice]> {
        let (stream, continuation) = AsyncStream<[BlockDevice]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuation.yield(devices)
        return stream
    }
}

/// Exact, bounded reads from memory. `sweepDelay` slows each 1 MiB sweep read (metadata reads
/// are small and stay fast), so a scan lasts long enough to be paused.
private struct FixtureReader: BlockReader {
    let data: Data
    let sweepDelay: Duration?
    var sizeBytes: Int64 { Int64(data.count) }

    func read(at offset: Int64, count: Int) async throws -> Data {
        try Task.checkCancellation()
        guard offset >= 0, count >= 0, offset <= sizeBytes, Int64(count) <= sizeBytes - offset else {
            throw ScanError.io("Read outside the fixture image.")
        }
        if let sweepDelay, count >= 256 * 1024 { try await Task.sleep(for: sweepDelay) }
        return data.subdata(in: Int(offset)..<Int(offset) + count)
    }
}

/// Builds an exFAT volume in memory, the same way SalvageCore's tests do (`exfatImage()` in
/// `ScanSessionTests.swift`): 512-byte sectors, 4 KiB clusters, one FAT, an allocation bitmap,
/// and every file and folder stored contiguously (NoFatChain) under the root directory.
enum ExFATFixtureImage {
    private static let sector = 512
    private static let clusterShift = 3
    private static let cluster = sector << clusterShift

    static func build(files: [(path: String, contents: Data)], sizeBytes: Int) -> Data {
        var image = Data(repeating: 0, count: sizeBytes)
        let totalSectors = sizeBytes / sector
        let fatOffset = 24
        let sectorsPerCluster = 1 << clusterShift
        var clusterCount = (totalSectors - fatOffset) / sectorsPerCluster
        var fatLength = 0, heapOffset = 0
        for _ in 0..<3 {
            fatLength = ((clusterCount + 2) * 4 + sector - 1) / sector
            heapOffset = (fatOffset + fatLength + sectorsPerCluster - 1) / sectorsPerCluster * sectorsPerCluster
            clusterCount = (totalSectors - heapOffset) / sectorsPerCluster
        }
        func clusterOffset(_ index: Int) -> Int { (heapOffset + (index - 2) * sectorsPerCluster) * sector }
        var nextCluster = 2
        func allocate(_ bytes: Int) -> Int {
            let first = nextCluster
            nextCluster += max(1, (bytes + cluster - 1) / cluster)
            precondition(nextCluster - 2 <= clusterCount, "Fixture files don't fit the fixture image")
            return first
        }

        let fat = fatOffset * sector
        image.put(fat, 0xffff_fff8, 4); image.put(fat + 4, 0xffff_ffff, 4)
        let root = allocate(cluster)
        image.put(fat + root * 4, 0xffff_ffff, 4)
        let bitmapBytes = (clusterCount + 7) / 8
        let bitmap = allocate(bitmapBytes)
        let bitmapClusters = max(1, (bitmapBytes + cluster - 1) / cluster)
        for index in bitmap..<(bitmap + bitmapClusters) {
            image.put(fat + index * 4, index == bitmap + bitmapClusters - 1 ? 0xffff_ffff : UInt64(index + 1), 4)
        }

        // Directory entries per folder ("" is the root), in the order they were met.
        var entries: [String: [Data]] = ["": [bitmapEntry(firstCluster: bitmap, length: bitmapBytes)]]
        var folderClusters: [String: Int] = ["": root]
        for file in files {
            let parts = file.path.split(separator: "/").map(String.init)
            var parent = ""
            for folder in parts.dropLast() {
                let path = parent + "/" + folder
                if folderClusters[path] == nil {
                    let first = allocate(cluster)
                    folderClusters[path] = first
                    entries[path] = []
                    entries[parent, default: []].append(entrySet(name: folder, directory: true, firstCluster: first, length: cluster))
                }
                parent = path
            }
            let first = file.contents.isEmpty ? 0 : allocate(file.contents.count)
            if first != 0 { image.replaceSubrange(clusterOffset(first)..<clusterOffset(first) + file.contents.count, with: file.contents) }
            entries[parent, default: []].append(entrySet(name: parts.last ?? "", directory: false, firstCluster: first,
                                                         length: file.contents.count))
        }
        for (folder, sets) in entries {
            let start = clusterOffset(folderClusters[folder]!)
            let bytes = sets.reduce(Data(), +)
            precondition(bytes.count <= cluster, "Fixture folder doesn't fit one cluster")
            image.replaceSubrange(start..<start + bytes.count, with: bytes)
        }

        // Every cluster handed out is allocated in the bitmap; the rest of the heap is free.
        let bitmapStart = clusterOffset(bitmap)
        for index in 2..<nextCluster { image[bitmapStart + (index - 2) / 8] |= UInt8(1 << ((index - 2) % 8)) }

        // Main boot region: boot sector, eight extended boot sectors, the boot checksum sector.
        image.text(3, "EXFAT   ")
        image.put(72, UInt64(totalSectors), 8); image.put(80, UInt64(fatOffset), 4); image.put(84, UInt64(fatLength), 4)
        image.put(88, UInt64(heapOffset), 4); image.put(92, UInt64(clusterCount), 4); image.put(96, UInt64(root), 4)
        image.put(100, 0x5A17_A6E0, 4); image.put(104, 0x100, 2)
        image.put(108, 9, 1); image.put(109, UInt64(clusterShift), 1); image.put(110, 1, 1); image.put(510, 0xaa55, 2)
        for index in 1...8 { image.put(sector * (index + 1) - 4, 0xaa55_0000, 4) }
        var bootSum: UInt32 = 0
        for index in 0..<sector * 11 where index != 106 && index != 107 && index != 112 {
            bootSum = ((bootSum & 1) << 31) &+ (bootSum >> 1) &+ UInt32(image[index])
        }
        for index in stride(from: sector * 11, to: sector * 12, by: 4) { image.put(index, UInt64(bootSum), 4) }
        return image
    }

    private static func bitmapEntry(firstCluster: Int, length: Int) -> Data {
        var entry = Data(repeating: 0, count: 32)
        entry[0] = 0x81
        entry.put(20, UInt64(firstCluster), 4); entry.put(24, UInt64(length), 8)
        return entry
    }

    /// A File entry, its Stream Extension (contiguous: AllocationPossible | NoFatChain) and the
    /// File Name entries, with the set checksum.
    private static func entrySet(name: String, directory: Bool, firstCluster: Int, length: Int) -> Data {
        let units = Array(name.utf16)
        precondition(!units.isEmpty && units.count <= 255)
        let nameEntries = (units.count + 14) / 15
        var set = Data(repeating: 0, count: 32 * (2 + nameEntries))
        set[0] = 0x85; set[1] = UInt8(1 + nameEntries)
        set.put(4, directory ? 0x10 : 0x20, 2)
        set[32] = 0xc0; set[33] = firstCluster == 0 ? 0x01 : 0x03; set[35] = UInt8(units.count)
        set.put(40, UInt64(length), 8); set.put(52, UInt64(firstCluster), 4); set.put(56, UInt64(length), 8)
        for (index, unit) in units.enumerated() {
            let entry = 64 + (index / 15) * 32
            set[entry] = 0xc1
            set.put(entry + 2 + (index % 15) * 2, UInt64(unit), 2)
        }
        var sum: UInt16 = 0
        for index in set.indices where index != 2 && index != 3 { sum = ((sum & 1) << 15) &+ (sum >> 1) &+ UInt16(set[index]) }
        set.put(2, UInt64(sum), 2)
        return set
    }
}

private extension Data {
    mutating func put(_ offset: Int, _ value: UInt64, _ width: Int) {
        for index in 0..<width { self[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8)) }
    }
    mutating func text(_ offset: Int, _ text: String) { replaceSubrange(offset..<offset + text.utf8.count, with: text.utf8) }
}
#endif
