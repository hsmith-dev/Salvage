import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import SalvageCore
import Testing
import UniformTypeIdentifiers
@testable import Salvage

/// In-memory device: `bytes` at offset 0, zeros after it up to `sizeBytes`.
private struct MemoryReader: BlockReader {
    let bytes: Data
    let sizeBytes: Int64
    var failReads = false
    init(_ bytes: Data, sizeBytes: Int64? = nil, failReads: Bool = false) {
        self.bytes = bytes; self.sizeBytes = sizeBytes ?? Int64(bytes.count); self.failReads = failReads
    }
    func read(at offset: Int64, count: Int) async throws -> Data {
        if failReads { throw ScanError.io("Device went away.") }
        var out = Data(count: count)
        let start = Int(offset), end = min(start + count, bytes.count)
        if start < end { out.replaceSubrange(0..<(end - start), with: bytes[start..<end]) }
        return out
    }
}

private let metadata = SourceMetadata(filesystem: .fat32, volumeOffset: 0, recordOffset: 0,
                                      allocationStart: 2, contiguous: true, rawRecord: Data())

/// A session over `bytes` placed at device offset 512 and a file mapped onto them.
private func fixture(_ bytes: Data, name: String, sizeBytes: Int64? = nil, deviceSize: Int64? = nil,
                     failReads: Bool = false) -> (RecoveredFile, SourceSession) {
    let size = sizeBytes ?? Int64(bytes.count)
    let device = Data(count: 512) + bytes
    let reader = MemoryReader(device, sizeBytes: deviceSize ?? max(Int64(device.count), 512 + size), failReads: failReads)
    let file = RecoveredFile(name: name, path: "/\(name)", sizeBytes: size, isDeleted: true,
                             sourceMetadata: metadata, content: .runs([DataRun(deviceOffset: 512, length: size)]))
    let session = SourceSession(device: BlockDevice(bsdName: "disk99", displayName: "Fixture", sizeBytes: reader.sizeBytes,
                                                    isInternal: false, isBootVolume: false),
                                reader: reader, close: {})
    return (file, session)
}

private func png(width: Int, height: Int) throws -> Data {
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())
    let output = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return output as Data
}

private func encode(_ width: Int, _ height: Int, as type: UTType) throws -> Data {
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    let image = try #require(context.makeImage())
    let output = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return output as Data
}

/// Deterministic pseudo-random bytes (a fixed-seed LCG), so the test can't flake.
private func noise(count: Int, seed: UInt64 = 0x5EED) -> [UInt8] {
    var state = seed
    return (0..<count).map { _ in
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return UInt8(truncatingIfNeeded: state >> 33)
    }
}

private func pdf() throws -> Data {
    let output = NSMutableData()
    let consumer = try #require(CGDataConsumer(data: output))
    var box = CGRect(x: 0, y: 0, width: 200, height: 200)
    let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
    context.beginPDFPage(nil)
    context.fill(CGRect(x: 10, y: 10, width: 50, height: 50))
    context.endPDFPage()
    context.closePDF()
    return output as Data
}

@Suite("Preview loader")
struct PreviewLoaderTests {
    @Test func decodesImageByMagicBytesDespiteWrongExtension() async throws {
        let (file, session) = fixture(try png(width: 40, height: 30), name: "IMG_0001.dat")
        let result = try await PreviewLoader(source: session).load(file)
        guard case .image(let image) = result else { Issue.record("expected image, got \(result)"); return }
        #expect(image.cgImage.width == 40)
        #expect(image.cgImage.height == 30)
    }

    @Test func downsamplesLargeImagesToMaxDimension() async throws {
        let (file, session) = fixture(try png(width: 4096, height: 1024), name: "wide.png")
        let result = try await PreviewLoader(source: session).load(file)
        guard case .image(let image) = result else { Issue.record("expected image, got \(result)"); return }
        #expect(image.cgImage.width == PreviewLoader.maxImageDimension)
        #expect(image.cgImage.height == 512)
    }

    @Test func rendersPDF() async throws {
        let (file, session) = fixture(try pdf(), name: "scan")
        let result = try await PreviewLoader(source: session).load(file)
        guard case .pdf(let document) = result else { Issue.record("expected PDF, got \(result)"); return }
        #expect(document.document.pageCount == 1)
    }

    @Test func decodesUTF8AndUTF16Text() async throws {
        let (utf8File, utf8Session) = fixture(Data("Grüße\nline two\n".utf8), name: "notes")
        let utf8 = try await PreviewLoader(source: utf8Session).load(utf8File)
        guard case .text(let text, let truncated) = utf8 else { Issue.record("expected text, got \(utf8)"); return }
        #expect(text == "Grüße\nline two\n")
        #expect(!truncated)

        let utf16Data = try #require("hello UTF-16 ✓".data(using: .utf16))   // includes a BOM
        let (utf16File, utf16Session) = fixture(utf16Data, name: "unicode.bin")
        let utf16 = try await PreviewLoader(source: utf16Session).load(utf16File)
        guard case .text(let decoded, _) = utf16 else { Issue.record("expected text, got \(utf16)"); return }
        #expect(decoded == "hello UTF-16 ✓")
    }

    @Test func largeTextIsCappedAtOneMiB() async throws {
        // A multi-byte character straddles the cap, so the decoder has to trim it.
        let body = Data(repeating: UInt8(ascii: "a"), count: Int(PreviewLoader.textCap) - 1) + Data("é tail".utf8)
        let (file, session) = fixture(body, name: "big.log")
        let result = try await PreviewLoader(source: session).load(file)
        guard case .text(let text, let truncated) = result else { Issue.record("expected text, got \(result)"); return }
        #expect(truncated)
        #expect(text.utf8.count == Int(PreviewLoader.textCap) - 1)
    }

    @Test func binaryOffersHexDumpOfFirst4KiB() async throws {
        let bytes = Data([0x00, 0x01, 0x02, 0x41, 0x42, 0xFF]) + Data(repeating: 0x07, count: 10_000)
        let (file, session) = fixture(bytes, name: "blob.bin")
        let result = try await PreviewLoader(source: session).load(file)
        guard case .unavailable(.unsupportedFormat, let raw?) = result else {
            Issue.record("expected unsupported with raw bytes, got \(result)"); return
        }
        let lines = raw.split(separator: "\n")
        #expect(lines.count == 4096 / 16)
        #expect(lines.first == "00000000  00 01 02 41 42 ff 07 07  07 07 07 07 07 07 07 07  |...AB...........|")
        #expect(lines.last?.hasPrefix("00000ff0  ") == true)
    }

    @Test func hexDumpPadsShortFinalRow() {
        #expect(PreviewLoader.hexDump(Data([0x41, 0x42, 0x43]))
                == "00000000  41 42 43 " + String(repeating: " ", count: 13 * 3 + 1) + " |ABC|")
    }

    @Test func unmappedFileIsNotRead() async throws {
        let file = RecoveredFile(name: "lost.jpg", path: "/lost.jpg", sizeBytes: 100, sourceMetadata: metadata)
        let (_, session) = fixture(Data(), name: "x", failReads: true)
        let result = try await PreviewLoader(source: session).load(file)
        #expect(result.unavailableReason == .unmapped)
    }

    @Test func runsShorterThanFileCountAsUnmapped() async throws {
        let (base, session) = fixture(Data("abc".utf8), name: "a.txt")
        let file = RecoveredFile(name: base.name, path: base.path, sizeBytes: 10, sourceMetadata: metadata,
                                 content: .runs([DataRun(deviceOffset: 512, length: 3)]))
        let result = try await PreviewLoader(source: session).load(file)
        #expect(result.unavailableReason == .unmapped)
    }

    @Test func oversizeImageIsRefusedBeforeReadingItAll() async throws {
        let header = try png(width: 8, height: 8)
        let size = PreviewLoader.imageCap + 1
        let (file, session) = fixture(header, name: "huge.png", sizeBytes: size)
        let probe = ReadProbe()
        let content = session.content
        let loader = PreviewLoader { file, limit in
            await probe.record(limit)
            return try await content.prefix(of: file, limit: limit)
        }
        let result = try await loader.load(file)
        #expect(result.unavailableReason == .tooLarge)
        #expect(await probe.limits == [PreviewLoader.rawBytesCap])
    }

    @Test func readFailureReportsDevice() async throws {
        let (file, session) = fixture(Data("hello".utf8), name: "a.txt", failReads: true)
        let result = try await PreviewLoader(source: session).load(file)
        #expect(result.unavailableReason == .deviceUnreadable)
    }

    @Test func missingSessionAndEmptyFile() async throws {
        let (file, session) = fixture(Data("hello".utf8), name: "a.txt")
        #expect(try await PreviewLoader(source: nil).load(file).unavailableReason == .deviceUnreadable)
        let empty = RecoveredFile(name: "e.txt", path: "/e.txt", sizeBytes: 0, sourceMetadata: metadata, content: .runs([]))
        #expect(try await PreviewLoader(source: session).load(empty).unavailableReason == .empty)
    }

    @Test func residentDataIsPreviewed() async throws {
        let (_, session) = fixture(Data(), name: "x")
        let file = RecoveredFile(name: "r.txt", path: "/r.txt", sizeBytes: 5, sourceMetadata: metadata,
                                 content: .resident(Data("small".utf8)))
        guard case .text(let text, _) = try await PreviewLoader(source: session).load(file) else {
            Issue.record("expected text"); return
        }
        #expect(text == "small")
    }

    @Test func corruptImageFallsBackToNoPreview() async throws {
        let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data(repeating: 0xAB, count: 200)
        let (file, session) = fixture(bytes, name: "broken.png")
        let result = try await PreviewLoader(source: session).load(file)
        #expect(result.unavailableReason == .unsupportedFormat)
    }

    @Test func cancellationThrowsInsteadOfReturningPartialContent() async throws {
        let (file, _) = fixture(Data("hello".utf8), name: "a.txt")
        let loader = PreviewLoader { _, _ in
            try await Task.sleep(for: .seconds(60))
            return Data()
        }
        let task = Task { try await loader.load(file) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func formatDetectionPrefersMagicOverExtension() {
        #expect(PreviewFormat.detect(header: Data("%PDF-1.7".utf8), name: "photo.jpg") == .pdf)
        #expect(PreviewFormat.detect(header: Data([0xFF, 0xD8, 0xFF, 0xE0]), name: "notes.txt") == .image)
        #expect(PreviewFormat.detect(header: Data("plain".utf8), name: "README.md") == .text)
        #expect(PreviewFormat.detect(header: Data([0, 1, 2]), name: "IMG.HEIC") == .image)
        #expect(PreviewFormat.detect(header: Data([0, 1, 2]), name: "archive.zip") == .unknown)
    }
}

extension PreviewLoaderTests {
    @Test func imageDeclaringOverOneHundredMegapixelsIsRefused() {
        // Checked from the declared size before any decode. (ImageIO won't report the size of a
        // header-only fixture this large, so the check is exercised directly.)
        #expect(PreviewLoader.maxImagePixels == 100_000_000)
        #expect(PreviewLoader.checkDeclaredSize([kCGImagePropertyPixelWidth: 10_001, kCGImagePropertyPixelHeight: 10_000]) == .tooLarge)
        #expect(PreviewLoader.checkDeclaredSize([kCGImagePropertyPixelWidth: 20_000, kCGImagePropertyPixelHeight: 20_000]) == .tooLarge)
        #expect(PreviewLoader.checkDeclaredSize([kCGImagePropertyPixelWidth: Int.max, kCGImagePropertyPixelHeight: 2]) == .tooLarge)
        #expect(PreviewLoader.checkDeclaredSize([kCGImagePropertyPixelWidth: 10_000, kCGImagePropertyPixelHeight: 10_000]) == nil)
    }

    @Test func imageWithoutDeclaredDimensionsIsRefused() {
        #expect(PreviewLoader.checkDeclaredSize([:]) == .unsupportedFormat)
        #expect(PreviewLoader.checkDeclaredSize([kCGImagePropertyPixelWidth: 100]) == .unsupportedFormat)
        #expect(PreviewLoader.checkDeclaredSize([kCGImagePropertyPixelHeight: 100]) == .unsupportedFormat)
        #expect(PreviewLoader.checkDeclaredSize([kCGImagePropertyPixelWidth: 0, kCGImagePropertyPixelHeight: 100]) == .unsupportedFormat)
    }

    @Test func csvStartingWithBMIPreviewsAsText() async throws {
        let csv = "BMI,Weight,Height\n22.5,70,1.76\n24.1,80,1.82\n"
        #expect(PreviewFormat.detect(header: Data(csv.utf8), name: "bmi.csv") == .text)
        #expect(PreviewFormat.detect(header: Data(csv.utf8), name: "bmi") == .unknown)
        let (file, session) = fixture(Data(csv.utf8), name: "bmi.csv")
        guard case .text(let text, _) = try await PreviewLoader(source: session).load(file) else {
            Issue.record("expected text"); return
        }
        #expect(text == csv)
    }

    @Test func realBMPIsStillDetectedByMagic() throws {
        let bmp = try encode(16, 8, as: .bmp)
        #expect(PreviewFormat.isPlausibleBMP([UInt8](bmp.prefix(32))))
        #expect(PreviewFormat.detect(header: bmp, name: "IMG_0001.dat") == .image)
        #expect(!PreviewFormat.isPlausibleBMP(Array("BMI,Weight,Height\n22.5,70".utf8)))
    }

    @Test func byteOrderMarkFollowedByRandomBytesIsNotText() async throws {
        // Random bytes, nudged so every code unit is non-NUL and not a surrogate: they decode as
        // UTF-16 without error, so only the printable-ratio check can tell they aren't text.
        var units = noise(count: 8_000)
        for i in stride(from: 0, to: units.count - 1, by: 2) {
            if units[i] == 0, units[i + 1] == 0 { units[i] = 1 }
            if (0xD8...0xDF).contains(units[i + 1]) { units[i + 1] ^= 0x40 }
        }
        let bytes = Data([0xFF, 0xFE] + units)
        #expect(String(data: bytes, encoding: .utf16).map { !$0.contains("\u{0}") } == true)
        #expect(PreviewLoader.decodeText(bytes, truncated: false) == nil)
        let (file, session) = fixture(bytes, name: "blob.bin")
        #expect(try await PreviewLoader(source: session).load(file).unavailableReason == .unsupportedFormat)
        #expect(PreviewLoader.decodeText(Data([0xFF, 0xFE] + noise(count: 8_000, seed: 7)), truncated: false) == nil)
        // Real UTF-16 text with a BOM, including a surrogate pair, still decodes.
        let text = String(repeating: "Hello, 世界 \u{1F600}\n", count: 50)
        #expect(PreviewLoader.decodeText(try #require(text.data(using: .utf16)), truncated: false) == text)
    }

    @Test func binaryHeaderStopsBeforeTheTextRead() async throws {
        let bytes = Data([0x00, 0x01, 0x02, 0x03]) + Data(noise(count: 20_000))
        let (file, session) = fixture(bytes, name: "mystery")
        let probe = ReadProbe()
        let content = session.content
        let loader = PreviewLoader { file, limit in
            await probe.record(limit)
            return try await content.prefix(of: file, limit: limit)
        }
        let result = try await loader.load(file)
        guard case .unavailable(.unsupportedFormat, let raw?) = result else { Issue.record("got \(result)"); return }
        #expect(raw.hasPrefix("00000000  00 01 02 03"))
        #expect(await probe.limits == [PreviewLoader.rawBytesCap])
    }

    @Test func shortReadWithoutAnErrorIsNeverShownAsContent() async throws {
        let (file, _) = fixture(Data("hello".utf8), name: "a.txt")
        let loader = PreviewLoader { _, _ in Data("he".utf8) }   // ends early, doesn't throw
        #expect(try await loader.load(file).unavailableReason == .deviceUnreadable)
    }

    @MainActor @Test func pdfLinkClicksAreSwallowed() throws {
        let blocker = PDFLinkBlocker()
        // PDFView opens the URL itself only when its delegate doesn't implement this method.
        #expect(blocker.responds(to: #selector(PDFViewDelegate.pdfViewWillClick(onLink:with:))))
        let url = try #require(URL(string: "https://example.com/track"))
        blocker.pdfViewWillClick(onLink: PDFView(), with: url)
        #expect(blocker.blockedURLs == [url])
    }
}

private actor ReadProbe {
    var limits: [Int64] = []
    func record(_ limit: Int64) { limits.append(limit) }
}
