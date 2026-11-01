import DiskArbitration
import Foundation
import SalvageCore
import Testing
@testable import SalvageDiskIO

/// spec-tech-batch-7 §B: the replug-stable identity a saved scan reconnects by.
@Suite("Stable disk identity")
struct StableDiskIdentityTests {
    typealias Volume = BlockDevice.StableIdentity.Volume

    @Test func gptDrivesAreIdentifiedByTheirDiskGUID() {
        let identity = StableDiskIdentity.identity(content: "GUID_partition_scheme", schemeUUID: "6fc74900-00f5-4e35-855d-d8162dbd9a32",
                                                   volumes: [Volume(offsetBytes: 1_048_576, volumeUUID: "X")], sizeBytes: 4096,
                                                   model: "  Portable SSD \n", serial: " S4X9NF0M ")
        #expect(identity == BlockDevice.StableIdentity(diskGUID: "6FC74900-00F5-4E35-855D-D8162DBD9A32", sizeBytes: 4096,
                                                       model: "Portable SSD", serial: "S4X9NF0M"))
        // A GPT drive whose GUID wasn't published (or isn't a GUID) has no stable identity.
        #expect(StableDiskIdentity.identity(content: "GUID_partition_scheme", schemeUUID: nil, volumes: [], sizeBytes: 4096,
                                            model: nil, serial: "S") == nil)
        #expect(StableDiskIdentity.identity(content: "GUID_partition_scheme", schemeUUID: "not a guid", volumes: [],
                                            sizeBytes: 4096, model: nil, serial: nil) == nil)
    }

    @Test func otherDrivesAreIdentifiedByTheirVolumesUUIDs() {
        let volumes = [Volume(offsetBytes: 65536, volumeUUID: "B"), Volume(offsetBytes: 512, volumeUUID: "A")]
        let identity = StableDiskIdentity.identity(content: "FDisk_partition_scheme", schemeUUID: nil, volumes: volumes,
                                                   sizeBytes: 8192, model: "", serial: nil)
        #expect(identity == BlockDevice.StableIdentity(diskGUID: nil, volumes: volumes.reversed(), sizeBytes: 8192,
                                                       model: nil, serial: nil))
        // No GPT and no volume UUIDs (unformatted, or a filesystem macOS doesn't recognize): none.
        #expect(StableDiskIdentity.identity(content: "FDisk_partition_scheme", schemeUUID: nil, volumes: [], sizeBytes: 8192,
                                            model: "M", serial: "S") == nil)
        #expect(StableDiskIdentity.identity(content: nil, schemeUUID: nil, volumes: [], sizeBytes: 0, model: nil, serial: nil) == nil)
    }
}

/// Disk images this suite creates in its own temp directory and attaches without mounting.
/// Metadata only: no raw reads, no writes to any device. Each image is detached and deleted.
@Suite("Stable identity of real disk images",
       .enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/hdiutil")
                && ProcessInfo.processInfo.environment["SALVAGE_SKIP_HDIUTIL"] == nil))
struct LiveStableDiskIdentityTests {
    @Test func gptImageReportsTheGUIDInItsPartitionTableAndKeepsItAcrossReattaching() throws {
        let folder = try TempFolder()
        let image = try folder.createImage("gpt", layout: "GPTSPUD", filesystem: "ExFAT")
        let headerGUID = try Self.gptDiskGUID(inRawImage: image)

        let first = try folder.attach(image)
        let identity = try #require(try Self.device(first).stableIdentity)
        let mediaIdentity = try Self.device(first).mediaIdentity
        #expect(identity.diskGUID == headerGUID)
        #expect(identity.volumes.isEmpty && identity.sizeBytes == 8 * 1024 * 1024)
        #expect(identity.model == "Disk Image")
        folder.detach(first)

        let again = try folder.attach(image)
        #expect(try Self.device(again).mediaIdentity != mediaIdentity, "A new attachment gets a new media identity")
        #expect(try Self.device(again).stableIdentity == identity, "but keeps its stable identity")

        // Another image with the same size and layout has another GUID.
        let other = try folder.attach(try folder.createImage("gpt2", layout: "GPTSPUD", filesystem: "ExFAT"))
        let otherIdentity = try #require(try Self.device(other).stableIdentity)
        #expect(otherIdentity.diskGUID != nil && otherIdentity.diskGUID != identity.diskGUID)
        #expect(otherIdentity.sizeBytes == identity.sizeBytes)
    }

    /// hdiutil's MBR images all have a zero disk signature, and macOS doesn't publish an MBR disk
    /// signature anyway, so an MBR drive is told apart by its volumes' filesystem UUIDs.
    @Test func mbrImageIsIdentifiedByItsVolumeUUID() throws {
        let folder = try TempFolder()
        let image = try folder.createImage("mbr", layout: "MBRSPUD", filesystem: "MS-DOS")
        let raw = try Data(contentsOf: image)
        #expect(raw[440..<444].allSatisfy { $0 == 0 }, "hdiutil writes no MBR disk signature")

        let first = try folder.attach(image)
        let identity = try #require(try Self.device(first).stableIdentity)
        #expect(identity.diskGUID == nil)
        let volume = try #require(identity.volumes.only)
        #expect(volume.offsetBytes == 512)
        #expect(volume.volumeUUID == Self.diskutilVolumeUUID(first + "s1"))
        folder.detach(first)

        let again = try folder.attach(image)
        #expect(try Self.device(again).stableIdentity == identity)
        let other = try folder.attach(try folder.createImage("mbr2", layout: "MBRSPUD", filesystem: "MS-DOS"))
        #expect(try Self.device(other).stableIdentity?.volumes.only?.volumeUUID != volume.volumeUUID)
    }

    // MARK: Helpers

    static func device(_ bsdName: String) throws -> BlockDevice {
        let session = try #require(DASessionCreate(kCFAllocatorDefault))
        let descriptions = DiskWatchRegistration.readDiskDescriptions(session: session)
        let devices = StableDiskIdentity.annotate(buildDeviceTree(descriptions, bootDisks: []), descriptions: descriptions,
                                                  session: session)
        return try #require(devices.first { $0.bsdName == bsdName })
    }

    /// The disk GUID at offset 56 of the GPT header (LBA 1), in GUID byte order.
    static func gptDiskGUID(inRawImage url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        #expect(String(decoding: data[512..<520], as: UTF8.self) == "EFI PART")
        let b = [UInt8](data[568..<584])
        let ordered = [b[3], b[2], b[1], b[0], b[5], b[4], b[7], b[6]] + b[8..<16]
        return UUID(uuid: (ordered[0], ordered[1], ordered[2], ordered[3], ordered[4], ordered[5], ordered[6], ordered[7],
                           ordered[8], ordered[9], ordered[10], ordered[11], ordered[12], ordered[13], ordered[14], ordered[15])).uuidString
    }

    static func diskutilVolumeUUID(_ bsdName: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["info", "-plist", bsdName]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        return plist?["VolumeUUID"] as? String
    }
}

/// A temp directory of raw disk images, each attached without mounting; everything attached is
/// detached and the directory deleted when the value goes away.
final class TempFolder {
    let url: URL
    private var attached: [String] = []

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("salvage-identity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        for disk in attached { _ = Self.hdiutil(["detach", "-force", disk]) }
        try? FileManager.default.removeItem(at: url)
    }

    func createImage(_ name: String, layout: String, filesystem: String) throws -> URL {
        let image = url.appendingPathComponent("\(name).dmg")
        let result = Self.hdiutil(["create", "-quiet", "-size", "8m", "-fs", filesystem, "-volname", name.uppercased(),
                                   "-layout", layout, "-type", "UDIF", image.path])
        guard result.status == 0 else { throw ImageError("hdiutil couldn't create an image here (set SALVAGE_SKIP_HDIUTIL=1 to skip).") }
        return image
    }

    /// Attaches without mounting and returns the whole disk's BSD name.
    func attach(_ image: URL) throws -> String {
        let result = Self.hdiutil(["attach", "-nobrowse", "-nomount", image.path])
        let nodes = result.output.split(separator: "\n").compactMap { line in
            line.split(separator: "\t").first.map { $0.trimmingCharacters(in: .whitespaces) }
        }.filter { $0.hasPrefix("/dev/disk") }
        guard result.status == 0, let whole = nodes.min(by: { $0.count < $1.count }) else {
            throw ImageError("hdiutil couldn't attach an image here (set SALVAGE_SKIP_HDIUTIL=1 to skip).")
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

struct ImageError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
