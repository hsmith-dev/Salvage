import Darwin
import Foundation
import SalvageCore
import SalvageDiskIO
import Testing
@testable import SalvageCLIKit

/// Safety refusals with injected drives: no real device is listed, opened or read.
@Suite("Safety refusals (fake drives)")
struct SafetyRefusalTests {
    let boot = BlockDevice(bsdName: "disk42", displayName: "Startup SSD", sizeBytes: 1 << 30, isInternal: true,
                           isBootVolume: true, mediaIdentity: 7)
    let external = BlockDevice(bsdName: "disk43", displayName: "SD Card", sizeBytes: 1 << 30, isInternal: false,
                               isBootVolume: false, mediaIdentity: 8)

    @Test func theStartupDiskIsRefusedBeforeAnythingOpensIt() async throws {
        let log = CallLog(), capture = Capture()
        let dir = try TempDir(); defer { dir.remove() }
        let env = fakeEnvironment(devices: [boot], log: log)
        #expect(await SalvageCLI.run(arguments: ["scan", "disk42"], environment: env, output: capture.output) == .refused)
        #expect(await SalvageCLI.run(arguments: ["recover", "/dev/rdisk42", "--to", dir.url.path, "--all"],
                                     environment: env, output: capture.output) == .refused)
        #expect(log.entries.isEmpty)
        #expect(capture.stderr.contains("startup disk"))
        #expect(dir.allFiles().isEmpty)
    }

    @Test func aDestinationOnTheSourceDriveIsRefusedBeforeTheDriveIsOpened() async throws {
        for verdict in [DestinationVerdict.sameDevice, .undetermined] {
            let log = CallLog(), capture = Capture()
            let dir = try TempDir(); defer { dir.remove() }
            let env = fakeEnvironment(devices: [external], log: log, deviceVerdict: verdict)
            let code = await SalvageCLI.run(arguments: ["recover", "disk43", "--to", dir.url.path, "--all"],
                                            environment: env, output: capture.output)
            #expect(code == .refused)
            #expect(log.entries == ["check disk43"], "checked, never opened")
            #expect(capture.stderr.contains("refused"))
            #expect(dir.allFiles().isEmpty)
        }
    }

    @Test func partitionsUnknownDrivesAndMissingFoldersAreRefused() async throws {
        let log = CallLog(), capture = Capture()
        let env = fakeEnvironment(devices: [external], log: log)
        #expect(await SalvageCLI.run(arguments: ["scan", "disk43s1"], environment: env, output: capture.output) == .refused)
        #expect(await SalvageCLI.run(arguments: ["scan", "disk44"], environment: env, output: capture.output) == .failure)
        #expect(await SalvageCLI.run(arguments: ["recover", "disk43", "--to", "/nonexistent-\(UUID().uuidString)", "--all"],
                                     environment: env, output: capture.output) == .usage)
        #expect(await SalvageCLI.run(arguments: ["scan", "/dev/null"], environment: env, output: capture.output) == .usage)
        #expect(log.entries.isEmpty)
    }

    @Test func versionAndList() async throws {
        let capture = Capture()
        let env = fakeEnvironment(devices: [boot, BlockDevice(bsdName: "disk43", displayName: "SD Card", sizeBytes: 1 << 30,
                                                              isInternal: false, isBootVolume: false, mediaIdentity: 8,
                                                              partitions: [DevicePartition(bsdName: "disk43s1", displayName: "PHOTOS",
                                                                                           sizeBytes: 1 << 29, formatName: "exFAT",
                                                                                           offsetBytes: 1_048_576)])])
        #expect(await SalvageCLI.run(arguments: ["--version"], environment: env, output: capture.output) == .success)
        #expect(capture.stdout == "salvage \(SalvageCLI.version)\n")
        let list = Capture()
        #expect(await SalvageCLI.run(arguments: ["list"], environment: env, output: list.output) == .success)
        #expect(list.stdout.contains("disk42  Startup SSD") && list.stdout.contains("startup disk, can't be scanned"))
        #expect(list.stdout.contains("└ disk43s1  PHOTOS  exFAT") && list.stdout.contains("at offset 1048576"))
        let json = Capture()
        #expect(await SalvageCLI.run(arguments: ["list", "--json"], environment: env, output: json.output) == .success)
        let objects = try json.stdoutLines.map { try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
        #expect(objects.count == 2 && objects[0]["startupDisk"] as? Bool == true)
        #expect((objects[1]["partitions"] as? [[String: Any]])?.first?["offset"] as? Int == 1_048_576)
    }
}

/// Scan and recover against a real exFAT image built by the test in a temp folder.
@Suite("Scan and recover a temp exFAT image", .serialized, .enabled(if: !hdiutilSkipped))
struct ExFATImageTests {
    @Test func scanJSONParsesAndListsLiveAndDeletedFiles() async throws {
        let image = try ExFATImage.shared()
        let capture = Capture()
        let code = await SalvageCLI.run(arguments: ["scan", image.image.path, "--json"], environment: fakeEnvironment(),
                                        output: capture.output)
        #expect(code == .success)
        var files: [String: [String: Any]] = [:]
        for line in capture.stdoutLines {
            let object = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], "not JSON: \(line)")
            let type = try #require(object["type"] as? String)
            #expect(["file", "notice", "lostPartition"].contains(type))
            if type == "file" { files[try #require(object["path"] as? String)] = object }
        }
        for (path, data) in image.live {
            let file = try #require(files[path], "\(path) listed")
            #expect(file["deleted"] as? Bool == false && file["size"] as? Int == data.count && file["filesystem"] as? String == "exfat")
        }
        let deleted = try #require(files["/DCIM/IMG_0002.JPG"])
        #expect(deleted["deleted"] as? Bool == true && deleted["recoverable"] as? Bool == true && deleted["confidence"] as? String == "high")
        #expect(capture.stderr.contains("Scanning: 100%"))

        // Filters.
        let filtered = Capture()
        #expect(await SalvageCLI.run(arguments: ["scan", image.image.path, "--deleted-only", "--format", "pictures", "-q"],
                                     environment: fakeEnvironment(), output: filtered.output) == .success)
        #expect(filtered.stdoutLines.contains("deleted\t70000\thigh\t/DCIM/IMG_0002.JPG"))
        #expect(filtered.stdoutLines.allSatisfy { $0.hasPrefix("deleted\t") })
        let limited = Capture()
        #expect(await SalvageCLI.run(arguments: ["scan", image.image.path, "--json", "--limit", "1", "-q"],
                                     environment: fakeEnvironment(), output: limited.output) == .success)
        #expect(limited.stdoutLines.filter { $0.contains("\"type\":\"file\"") }.count == 1)
    }

    @Test func recoverAllIsByteIdenticalIncludingTheDeletedFile() async throws {
        let image = try ExFATImage.shared()
        let out = try TempDir("SalvageCLIOut"); defer { out.remove() }
        let capture = Capture()
        let code = await SalvageCLI.run(arguments: ["recover", image.image.path, "--to", out.url.path, "--all", "--json", "-q"],
                                        environment: fakeEnvironment(), output: capture.output)
        #expect(code == .success, "\(capture.stderr)")
        let objects = try capture.stdoutLines.map { try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
        let recovered = objects.filter { $0["type"] as? String == "recovered" }
        let summary = try #require(objects.last)
        #expect(summary["type"] as? String == "summary" && summary["failed"] as? Int == 0)
        let root = try #require(summary["folder"] as? String)
        #expect(URL(fileURLWithPath: root).lastPathComponent.hasPrefix("Salvage Recovery card.dmg "))
        for (path, data) in image.live.merging(image.deleted, uniquingKeysWith: { a, _ in a }) {
            let copy = URL(fileURLWithPath: root).appendingPathComponent(String(path.dropFirst()))
            #expect(try Data(contentsOf: copy) == data, "\(path) is byte-identical")
            let entry = try #require(recovered.first { $0["source"] as? String == path })
            #expect(entry["destination"] as? String == copy.path && entry["size"] as? Int == data.count)
        }
        #expect(!out.allFiles().contains { $0.hasSuffix(".partial") })
    }

    @Test func recoveringAgainNeverOverwritesAndSelectsByPathAndPartition() async throws {
        let image = try ExFATImage.shared()
        let out = try TempDir("SalvageCLIOut"); defer { out.remove() }
        // The same fixed clock both times, so the second run's folder name is taken.
        let first = Capture(), second = Capture()
        #expect(await SalvageCLI.run(arguments: ["recover", image.image.path, "--to", out.url.path, "--path", "/Docs/*", "-q"],
                                     environment: fakeEnvironment(), output: first.output) == .success)
        let firstFiles = out.allFiles()
        // macOS adds AppleDouble ("._name") files on exFAT; they are recovered like any other file,
        // and the leading dot is dropped from the name written (as in the app).
        #expect(firstFiles.filter { !$0.contains("/_") }.count == 2 && firstFiles.allSatisfy { $0.contains("/Docs/") })
        let before = try firstFiles.map { try Data(contentsOf: out.url.appendingPathComponent($0)) }
        // The second run wants the same recovery folder name: it must get a new one.
        #expect(await SalvageCLI.run(arguments: ["recover", image.image.path, "--to", out.url.path, "--partition", "1048576", "-q"],
                                     environment: fakeEnvironment(), output: second.output) == .success)
        let after = try firstFiles.map { try Data(contentsOf: out.url.appendingPathComponent($0)) }
        #expect(before == after, "the first run's files are untouched")
        let roots = Set(out.allFiles().map { String($0.prefix { $0 != "/" }) })
        #expect(roots.count == 2 && roots.contains { $0.hasSuffix(" (2)") }, "\(roots)")
        #expect(second.stdoutLines.filter { $0.hasPrefix("recovered\t") && !$0.contains("/._") }.count
            == image.live.count + image.deleted.count)
        // No match: nothing written, its own exit code.
        let none = Capture()
        let count = out.allFiles().count
        #expect(await SalvageCLI.run(arguments: ["recover", image.image.path, "--to", out.url.path, "--path", "/nothing/*", "-q"],
                                     environment: fakeEnvironment(), output: none.output) == .nothingMatched)
        #expect(out.allFiles().count == count)
        #expect(await SalvageCLI.run(arguments: ["recover", image.image.path, "--to", out.url.path, "--partition", "512", "-q"],
                                     environment: fakeEnvironment(), output: none.output) == .nothingMatched)
    }

    /// The real check (`ImageFileDestinationSafety.live`): a folder on the image's own mounted
    /// volume is the source, so it is refused and nothing is written there.
    @Test func aDestinationInsideTheMountedSourceImageIsRefused() async throws {
        let image = try ExFATImage(); defer { image.remove() }
        try image.attach()
        defer { try? image.detach() }
        let before = try FileManager.default.contentsOfDirectory(atPath: image.mountPoint.path).sorted()
        let capture = Capture()
        let code = await SalvageCLI.run(arguments: ["recover", image.image.path, "--to", image.mountPoint.path, "--all", "-q"],
                                        environment: fakeEnvironment(), output: capture.output)
        #expect(code == .refused)
        #expect(capture.stderr.contains("refused"))
        #expect(capture.stdout.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: image.mountPoint.path).sorted() == before)
        // A folder on the volume that holds the image file is a different device, as in the app.
        let host = ImageFileDestinationSafety.live.assess(destination: image.base, imageFile: image.image)
        #expect(host.verdict == .safe)
    }

    /// The drive path, with the drive played by the temp image: the destination is checked
    /// before the drive is opened and again before writing.
    @Test func aDriveSourceIsCheckedBeforeOpeningThenRecovered() async throws {
        let image = try ExFATImage.shared()
        let out = try TempDir("SalvageCLIOut"); defer { out.remove() }
        let device = BlockDevice(bsdName: "disk43", displayName: "SD Card", sizeBytes: 16 << 20, isInternal: false,
                                 isBootVolume: false, mediaIdentity: 8)
        let log = CallLog(), capture = Capture()
        let path = image.image.path
        let env = fakeEnvironment(devices: [device], log: log, openDevice: { device in
            let reader = try ImageFileReader(path: path)
            return OpenedSource(reader: reader, displayName: device.displayName, device: device, close: { reader.close() })
        })
        #expect(await SalvageCLI.run(arguments: ["recover", "disk43", "--to", out.url.path, "--path", "*.JPG", "-q"],
                                     environment: env, output: capture.output) == .success)
        #expect(log.entries == ["check disk43", "open disk43", "check disk43"])
        let files = out.allFiles().filter { !$0.contains("/_") }
        #expect(files.count == 2 && files.allSatisfy { $0.hasPrefix("Salvage Recovery SD Card ") })
        #expect(try Data(contentsOf: out.url.appendingPathComponent(try #require(files.first { $0.hasSuffix("IMG_0002.JPG") })))
            == image.deleted["/DCIM/IMG_0002.JPG"])
    }

    /// The built binary: exit codes and JSON through a real process.
    @Test func theExecutable() throws {
        guard let salvage = salvageExecutable() else {
            Issue.record("The salvage executable wasn't found beside the tests.")
            return
        }
        let version = try runSalvage(salvage, ["--version"])
        #expect(version.status == 0 && version.stdout == "salvage \(SalvageCLI.version)\n")
        #expect(try runSalvage(salvage, ["frobnicate"]).status == 2)
        let image = try ExFATImage.shared()
        let scan = try runSalvage(salvage, ["scan", image.image.path, "--json"])
        #expect(scan.status == 0, "\(scan.stderr)")
        let lines = scan.stdout.split(separator: "\n")
        #expect(lines.count >= image.live.count + image.deleted.count)
        for line in lines { #expect((try? JSONSerialization.jsonObject(with: Data(line.utf8))) is [String: Any]) }
        #expect(scan.stderr.contains("Found "))
        let refused = try runSalvage(salvage, ["scan", "/dev/null"])
        #expect(refused.status == 2)
    }
}
