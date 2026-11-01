import Darwin
import Foundation
import SalvageCore
import SalvageDiskIO
import Testing
@testable import SalvageCLIKit

@Suite("Command line parsing")
struct ArgumentTests {
    @Test func sourcesNameDrivesOrImages() throws {
        #expect(try SourceArgument.parse("disk4") == .device("disk4"))
        #expect(try SourceArgument.parse("/dev/disk4") == .device("disk4"))
        #expect(try SourceArgument.parse("/dev/rdisk12") == .device("disk12"))
        #expect(try SourceArgument.parse("card.img") == .image("card.img"))
        #expect(try SourceArgument.parse("./disk4") == .image("./disk4"))
        #expect(try SourceArgument.parse("/Users/me/disk4.dmg") == .image("/Users/me/disk4.dmg"))
        #expect(throws: RefusedArgument.self) { try SourceArgument.parse("disk4s1") }
        #expect(throws: RefusedArgument.self) { try SourceArgument.parse("/dev/rdisk0s2") }
        #expect(throws: UsageError.self) { try SourceArgument.parse("/dev/null") }
    }

    @Test func scanOptions() throws {
        guard case .scan(let options) = try ArgumentParser.parse(["scan", "x.img", "--json", "--deleted-only",
                                                                  "--format", "pictures,mp3", "--limit", "3", "-q"]) else {
            Issue.record("not a scan"); return
        }
        #expect(options.source == .image("x.img") && options.json && options.deletedOnly && options.quiet)
        #expect(options.limit == 3)
        #expect(options.format.categories == [.pictures] && options.format.extensions == ["mp3"])
        #expect(throws: UsageError.self) { try ArgumentParser.parse(["scan"]) }
        #expect(throws: UsageError.self) { try ArgumentParser.parse(["scan", "a.img", "b.img"]) }
        #expect(throws: UsageError.self) { try ArgumentParser.parse(["scan", "a.img", "--limit", "0"]) }
        #expect(throws: UsageError.self) { try ArgumentParser.parse(["scan", "a.img", "--bogus"]) }
    }

    @Test func recoverNeedsADestinationAndExactlyOneSelection() throws {
        guard case .recover(let options) = try ArgumentParser.parse(["recover", "disk5", "--to", "/Volumes/B", "--path", "/DCIM/*",
                                                                     "--path", "*.pdf", "--include-reconstructed"]) else {
            Issue.record("not a recover"); return
        }
        #expect(options.source == .device("disk5") && options.destination == "/Volumes/B")
        #expect(options.selection == .paths(["/DCIM/*", "*.pdf"]) && options.includeReconstructed)
        guard case .recover(let partitions) = try ArgumentParser.parse(["recover", "a.img", "--to", "o", "--partition", "0x100000",
                                                                        "--partition", "209735680"]) else { return }
        #expect(partitions.selection == .partitions([1_048_576, 209_735_680]))
        #expect(throws: UsageError.self) { try ArgumentParser.parse(["recover", "a.img", "--all"]) }
        #expect(throws: UsageError.self) { try ArgumentParser.parse(["recover", "a.img", "--to", "o"]) }
        #expect(throws: UsageError.self) { try ArgumentParser.parse(["recover", "a.img", "--to", "o", "--all", "--path", "*"]) }
        #expect(throws: UsageError.self) { try ArgumentParser.parse(["recover", "a.img", "--to", "o", "--partition", "-5"]) }
        #expect(throws: UsageError.self) { try ArgumentParser.parse(["recover", "a.img", "--to"]) }
    }

    @Test func otherCommands() throws {
        #expect(try ArgumentParser.parse(["--version"]) == .version)
        #expect(try ArgumentParser.parse(["list", "--json"]) == .list(json: true))
        #expect(try ArgumentParser.parse(["help"]) == .help)
        #expect(throws: UsageError.self) { try ArgumentParser.parse([]) }
        #expect(throws: UsageError.self) { try ArgumentParser.parse(["erase"]) }
    }

    @Test func globsCrossFoldersAndMayOmitTheLeadingSlash() {
        #expect(RecoverCommand.matches(glob: "/DCIM/*", path: "/DCIM/100APPLE/IMG_1.JPG"))
        #expect(RecoverCommand.matches(glob: "*.JPG", path: "/DCIM/IMG_1.JPG"))
        #expect(RecoverCommand.matches(glob: "Docs/*.txt", path: "/Docs/a.txt"))
        #expect(!RecoverCommand.matches(glob: "/Docs/*", path: "/DCIM/IMG_1.JPG"))
    }

    @Test func formatFilterMatchesCategoriesAndExtensions() throws {
        var filter = FormatFilter()
        try filter.add("documents, .JPG")
        let meta = SourceMetadata(filesystem: .exfat, volumeOffset: 0, recordOffset: 0, allocationStart: 0, contiguous: true, rawRecord: Data())
        #expect(filter.matches(RecoveredFile(name: "a.pdf", path: "/a.pdf", sizeBytes: 1, sourceMetadata: meta)))
        #expect(filter.matches(RecoveredFile(name: "b.jpg", path: "/b.jpg", sizeBytes: 1, sourceMetadata: meta)))
        #expect(!filter.matches(RecoveredFile(name: "c.png", path: "/c.png", sizeBytes: 1, sourceMetadata: meta)))
        #expect(FormatFilter().matches(RecoveredFile(name: "c.png", path: "/c.png", sizeBytes: 1, sourceMetadata: meta)))
    }

    @Test func exitCodesAreTheDocumentedOnes() throws {
        #expect(ExitCode.allCases.map(\.rawValue) == [0, 1, 2, 3, 4, 5, 130])
        let doc = try String(contentsOf: repositoryRoot.appendingPathComponent("docs/CLI.md"), encoding: .utf8)
        for code in ExitCode.allCases { #expect(doc.contains("| \(code.rawValue) |"), "docs/CLI.md documents exit code \(code.rawValue)") }
    }
}

@Suite("Image file reader")
struct ImageFileReaderTests {
    @Test func readsARawFileReadOnlyAndRefusesReadsPastTheEnd() async throws {
        let dir = try TempDir(); defer { dir.remove() }
        let path = dir.url.appendingPathComponent("raw.img").path
        let bytes = ExFATImage.bytes(4096, seed: 9)
        try bytes.write(to: URL(fileURLWithPath: path))
        let reader = try ImageFileReader(path: path)
        #expect(reader.sizeBytes == 4096)
        #expect(try await reader.read(at: 512, count: 1024) == bytes[512..<1536])
        await #expect(throws: ScanError.self) { try await reader.read(at: 4000, count: 512) }
        await #expect(throws: ScanError.self) { try await reader.read(at: -1, count: 1) }
        reader.close()
        await #expect(throws: ScanError.self) { try await reader.read(at: 0, count: 1) }
    }

    @Test func deviceNodesAndLinksToThemAreRefused() throws {
        let dir = try TempDir(); defer { dir.remove() }
        let link = dir.url.appendingPathComponent("disk-link").path
        // /dev/null is a character device like a raw disk node, and harmless to open read-only.
        #expect(symlink("/dev/null", link) == 0)
        #expect(throws: ImageOpenError.deviceNode(path: "/dev/null")) { try ImageFileReader(path: "/dev/null") }
        #expect(throws: ImageOpenError.deviceNode(path: link)) { try ImageFileReader(path: link) }
        #expect(throws: ImageOpenError.notRegularFile(path: dir.url.path)) { try ImageFileReader(path: dir.url.path) }
        let empty = dir.url.appendingPathComponent("empty.img").path
        FileManager.default.createFile(atPath: empty, contents: Data())
        #expect(throws: ImageOpenError.empty(path: empty)) { try ImageFileReader(path: empty) }
    }

    /// A UDIF trailer is stripped when it describes a raw data fork; a compressed image is refused.
    @Test func udifTrailers() throws {
        let dir = try TempDir(); defer { dir.remove() }
        func trailer(dataLength: UInt64, xmlOffset: UInt64, xmlLength: UInt64) -> Data {
            var bytes = [UInt8](repeating: 0, count: 512)
            bytes.replaceSubrange(0..<4, with: Array("koly".utf8))
            func put(_ value: UInt64, at offset: Int) { for i in 0..<8 { bytes[offset + i] = UInt8(truncatingIfNeeded: value >> (56 - 8 * UInt64(i))) } }
            put(dataLength, at: 0x20); put(xmlOffset, at: 0xD8); put(xmlLength, at: 0xE0)
            return Data(bytes)
        }
        let raw = dir.url.appendingPathComponent("raw.dmg").path
        try (Data(count: 2048) + trailer(dataLength: 2048, xmlOffset: 0, xmlLength: 0)).write(to: URL(fileURLWithPath: raw))
        #expect(try ImageFileReader(path: raw).sizeBytes == 2048)
        let compressed = dir.url.appendingPathComponent("udzo.dmg").path
        try (Data(count: 2048) + trailer(dataLength: 1000, xmlOffset: 1000, xmlLength: 500)).write(to: URL(fileURLWithPath: compressed))
        #expect(throws: ImageOpenError.encodedImage(path: compressed)) { try ImageFileReader(path: compressed) }
    }
}

@Suite("Destination safety for image files")
struct ImageFileDestinationSafetyTests {
    let image = URL(fileURLWithPath: "/Users/me/card.dmg")
    let destination = URL(fileURLWithPath: "/Volumes/Somewhere/out")
    let imageID = FileIdentity(device: 1, inode: 42)

    func safety(mount: String?, mounts: [String: String] = [:], backings: [String: DiskBacking?] = [:],
                identities: [String: FileIdentity] = [:], failing: Set<String> = []) -> ImageFileDestinationSafety {
        let source = imageID
        return ImageFileDestinationSafety(
            mountSource: { path in mounts[path] ?? mount },
            physicalDisks: { failing.contains($0) ? nil : [$0] },
            backing: { disk in backings.keys.contains(disk) ? backings[disk]! : .physical },
            fileIdentity: { path in path == "/Users/me/card.dmg" ? source : identities[path] })
    }

    @Test func aFolderOnTheMountedImageItselfIsBlocked() {
        let check = safety(mount: "/dev/disk9s1", mounts: ["/Users/me/card.dmg": "/dev/disk3s5"],
                           backings: ["disk9": .diskImage(path: "/Users/me/card.dmg")])
        #expect(check.assess(destination: destination, imageFile: image).verdict == .sameDevice)
    }

    @Test func aSecondPathToTheSameImageFileIsStillBlocked() {
        let check = safety(mount: "/dev/disk9s1", mounts: ["/Users/me/link.dmg": "/dev/disk3s5"],
                           backings: ["disk9": .diskImage(path: "/Users/me/link.dmg")],
                           identities: ["/Users/me/link.dmg": imageID])
        #expect(check.assess(destination: destination, imageFile: image).verdict == .sameDevice)
    }

    @Test func anImageNestedInsideTheSourceImageIsBlocked() {
        let check = safety(mount: "/dev/disk10s1",
                           mounts: ["/Volumes/CARD/inner.dmg": "/dev/disk9s1", "/Users/me/card.dmg": "/dev/disk3s5"],
                           backings: ["disk10": .diskImage(path: "/Volumes/CARD/inner.dmg"), "disk9": .diskImage(path: "/Users/me/card.dmg")],
                           identities: ["/Volumes/CARD/inner.dmg": FileIdentity(device: 9, inode: 2)])
        #expect(check.assess(destination: destination, imageFile: image).verdict == .sameDevice)
    }

    @Test func anotherDriveOrTheVolumeHoldingTheImageFileIsSafe() {
        #expect(safety(mount: "/dev/disk7s1").assess(destination: destination, imageFile: image).verdict == .safe)
        // As for an attached image in the app: the image's own host volume is a different device.
        let host = safety(mount: "/dev/disk3s5").assess(destination: destination, imageFile: image)
        #expect(host.verdict == .safe && host.mountSource == "/dev/disk3s5")
    }

    @Test func anythingUnknownFailsClosed() {
        #expect(safety(mount: nil).assess(destination: destination, imageFile: image).verdict == .undetermined)
        #expect(safety(mount: "//user@server/share").assess(destination: destination, imageFile: image).verdict == .undetermined)
        #expect(safety(mount: "/dev/disk7s1", failing: ["disk7"]).assess(destination: destination, imageFile: image).verdict == .undetermined)
        #expect(safety(mount: "/dev/disk8s1", backings: ["disk8": .unknownVirtual]).assess(destination: destination, imageFile: image).verdict == .undetermined)
        #expect(safety(mount: "/dev/disk8s1", backings: ["disk8": nil]).assess(destination: destination, imageFile: image).verdict == .undetermined)
        // An image whose file can't be stat'ed can't be told apart from the source.
        #expect(safety(mount: "/dev/disk8s1", backings: ["disk8": .diskImage(path: "/gone.dmg")])
            .assess(destination: destination, imageFile: image).verdict == .undetermined)
        let missingSource = ImageFileDestinationSafety(mountSource: { _ in "/dev/disk7s1" }, physicalDisks: { [$0] },
                                                       backing: { _ in .physical }, fileIdentity: { _ in nil })
        #expect(missingSource.assess(destination: destination, imageFile: image).verdict == .undetermined)
        #expect(safety(mount: "/dev/disk7s1").assess(destination: URL(string: "ftp://x.invalid/a")!, imageFile: image).verdict == .undetermined)
    }
}

@Suite("Repository guards")
struct RepositoryGuardTests {
    /// The CLI's recovery engine is a verbatim copy of the app's (see RecoveryEngine.swift).
    @Test func engineCopyMatchesTheApp() throws {
        let app = try String(contentsOf: repositoryRoot.appendingPathComponent("Salvage/ViewModels/RecoveryCoordinator.swift"), encoding: .utf8)
        let copy = try String(contentsOf: repositoryRoot.appendingPathComponent("SalvageCLI/Sources/SalvageCLIKit/RecoveryEngine.swift"), encoding: .utf8)
        let start = try #require(app.range(of: "// MARK: - Results\n"))
        let end = try #require(app.range(of: "// MARK: - Coordinator\n"))
        let marker = try #require(copy.range(of: "// BEGIN VERBATIM COPY\n"))
        #expect(String(copy[marker.upperBound...]) == String(app[start.lowerBound..<end.lowerBound]),
                "SalvageCLI's RecoveryEngine.swift drifted from the app's engine; re-copy it (docs/CLI.md, Maintenance).")
    }

    @Test func versionMatchesTheApp() throws {
        let spec = try String(contentsOf: repositoryRoot.appendingPathComponent("project.yml"), encoding: .utf8)
        #expect(spec.contains("MARKETING_VERSION: \"\(SalvageCLI.version)\""))
    }

    /// The zero-network checker scans SalvageCLI/: a planted violation there is caught.
    @Test func noNetworkCheckerCoversTheCLI() throws {
        let dir = try TempDir(); defer { dir.remove() }
        let planted = dir.url.appendingPathComponent("SalvageCLI/Sources/Leak.swift")
        try FileManager.default.createDirectory(at: planted.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Assembled at run time so this file itself never matches the checker's patterns.
        try Data("let s = \("URL" + "Session").shared\n".utf8).write(to: planted)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [repositoryRoot.appendingPathComponent("scripts/check-no-network.sh").path, dir.url.path]
        let pipe = Pipe()
        process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        #expect(process.terminationStatus != 0)
        #expect(text.contains("SalvageCLI/Sources/Leak.swift"))
    }
}
