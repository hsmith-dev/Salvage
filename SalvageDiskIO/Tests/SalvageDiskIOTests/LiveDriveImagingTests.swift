import DiskArbitration
import Foundation
import SalvageCore
import Testing
@testable import SalvageDiskIO

/// spec-tech-image-drive end to end: a raw file of random bytes this test creates in its own temp
/// folder is attached with `hdiutil attach -nomount` (a user-owned device, so the direct read-only
/// open works with no helper or password), opened only through `RawBlockReader.prepare`, imaged
/// into a second file, and compared byte for byte. The device is checked to be backed by that
/// file before it is opened and before it is detached; the folder is deleted afterwards.
@Suite("Imaging an attached disk image",
       .enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/hdiutil")
                && ProcessInfo.processInfo.environment["SALVAGE_SKIP_HDIUTIL"] == nil))
struct LiveDriveImagingTests {
    @Test func imagesAnAttachedDeviceByteForByte() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("salvage-imaging-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let sourceFile = folder.appendingPathComponent("source.img")
        var bytes = Data(count: 6 * 1024 * 1024 + 512 * 3)
        bytes.withUnsafeMutableBytes { raw in
            var generator = SystemRandomNumberGenerator()
            for index in 0..<raw.count { raw[index] = UInt8.random(in: 0...255, using: &generator) }
        }
        try bytes.write(to: sourceFile)

        let disk = try Self.attach(sourceFile)
        defer { Self.detachIfOurs(disk, image: sourceFile) }
        try #require(Self.backingImage(of: disk) == sourceFile.resolvingSymlinksInPath().path,
                     "the device must be the image this test attached")

        // User-owned, so the direct read-only open succeeds and no helper or password is involved.
        var node = stat()
        try #require(stat("/dev/r\(disk)", &node) == 0 && node.st_uid == getuid())
        let device = try Self.device(disk)
        let reader = try await RawBlockReader.prepare(device: device)
        let destination = folder.appendingPathComponent("copy.img")
        let checked = DestinationAssessment(verdict: .safe, mountSource: mountSourceName(ofPath: folder.path))
        let output = try ImageOutputFile(creating: destination, replacingConfirmed: false, checked: checked)
        var imager = DriveImager()
        imager.chunkSize = 1024 * 1024
        let result = await imager.run(reader: reader, sink: output)
        output.close()
        await reader.close()

        #expect(result.outcome == .completed)
        #expect(result.badRanges.isEmpty)
        #expect(try Data(contentsOf: destination) == bytes)
    }

    // MARK: Helpers

    static func attach(_ image: URL) throws -> String {
        let result = hdiutil(["attach", "-nobrowse", "-nomount", "-readonly",
                              "-imagekey", "diskimage-class=CRawDiskImage", image.path])
        let nodes = result.output.split(separator: "\n").compactMap { line in
            line.split(separator: "\t").first.map { $0.trimmingCharacters(in: .whitespaces) }
        }.filter { $0.hasPrefix("/dev/disk") }
        guard result.status == 0, let whole = nodes.min(by: { $0.count < $1.count }) else {
            throw ImageError("hdiutil couldn't attach an image here (set SALVAGE_SKIP_HDIUTIL=1 to skip).")
        }
        return String(whole.dropFirst("/dev/".count))
    }

    /// The image file backing whole disk `disk`, from `hdiutil info -plist`; nil when it isn't an
    /// attached image.
    static func backingImage(of disk: String) -> String? {
        let result = hdiutil(["info", "-plist"])
        guard result.status == 0,
              let plist = try? PropertyListSerialization.propertyList(from: Data(result.output.utf8), format: nil) as? [String: Any],
              let images = plist["images"] as? [[String: Any]] else { return nil }
        for image in images {
            let entries = (image["system-entities"] as? [[String: Any]] ?? []).compactMap { $0["dev-entry"] as? String }
            if entries.contains("/dev/\(disk)"), let path = image["image-path"] as? String {
                return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            }
        }
        return nil
    }

    /// Detaches only when `disk` is still backed by this test's image.
    static func detachIfOurs(_ disk: String, image: URL) {
        guard backingImage(of: disk) == image.resolvingSymlinksInPath().path else { return }
        _ = hdiutil(["detach", "-force", disk])
    }

    static func device(_ bsdName: String) throws -> BlockDevice {
        let session = try #require(DASessionCreate(kCFAllocatorDefault))
        let descriptions = DiskWatchRegistration.readDiskDescriptions(session: session)
        return try #require(buildDeviceTree(descriptions, bootDisks: []).first { $0.bsdName == bsdName })
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
