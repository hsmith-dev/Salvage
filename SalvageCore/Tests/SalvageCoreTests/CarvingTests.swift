import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import SalvageCore

// MARK: - Synthetic file builders

private func be32(_ value: Int) -> Data { Data([UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]) }
private func le32(_ value: Int) -> Data { Data([UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 24 & 0xFF)]) }
private func le64(_ value: Int) -> Data { le32(value & 0xFFFF_FFFF) + le32(value >> 32) }
private func le16(_ value: Int) -> Data { Data([UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF)]) }
private func be64(_ value: Int) -> Data { be32(value >> 32 & 0xFFFF_FFFF) + be32(value & 0xFFFF_FFFF) }
private func ascii(_ text: String) -> Data { Data(text.utf8) }
/// Filler that never contains 0xFF, 0x3B, "PK" or other marker bytes.
private func filler(_ count: Int, seed: UInt8 = 7) -> Data { Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) & 0x3F | 0x40 }) }

/// A JPEG with an APP0 segment, an EXIF APP1 segment carrying an embedded thumbnail (its own
/// SOI/EOI), a start-of-scan segment, entropy data and the EOI footer.
func jpegBytes(body: Int = 1000, thumbnail: Bool = true, footer: Bool = true) -> Data {
    var data = Data([0xFF, 0xD8])
    data += Data([0xFF, 0xE0, 0x00, 0x10]) + ascii("JFIF") + Data([0, 1, 1, 0, 0, 1, 0, 1, 0, 0])
    if thumbnail {
        let thumb = Data([0xFF, 0xD8, 0xFF, 0xDA, 0x00, 0x04, 0x01, 0x02]) + filler(40) + Data([0xFF, 0xD9])
        let length = 2 + 6 + thumb.count
        data += Data([0xFF, 0xE1, UInt8(length >> 8), UInt8(length & 0xFF)]) + ascii("Exif") + Data([0, 0]) + thumb
    }
    data += Data([0xFF, 0xDA, 0x00, 0x0C, 0x03, 0x01, 0x00, 0x02, 0x11, 0x03, 0x11, 0x00, 0x3F, 0x00])
    data += filler(body)
    if footer { data += Data([0xFF, 0xD9]) }
    return data
}

func pngBytes(body: Int = 300) -> Data {
    var data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    data += be32(13) + ascii("IHDR") + filler(13) + filler(4, seed: 1)
    data += be32(body) + ascii("IDAT") + filler(body) + filler(4, seed: 2)
    data += be32(0) + ascii("IEND") + Data([0xAE, 0x42, 0x60, 0x82])
    return data
}

func pdfBytes(revisions: Int = 2, trailingNewline: Bool = true) -> Data {
    var data = ascii("%PDF-1.4\n")
    for revision in 0..<revisions {
        data += ascii("1 0 obj << /Revision \(revision) >> endobj\n") + filler(200) + ascii("\n%%EOF")
        if trailingNewline || revision < revisions - 1 { data += ascii("\n") }
    }
    return data
}

/// A one-entry stored ZIP whose end-of-central-directory record carries the real central
/// directory offset and size.
func zipBytes(comment: String = "", content: Data = Data("hello".utf8)) -> Data {
    let name = ascii("a.txt")
    let local = ascii("PK") + Data([3, 4]) + Data(repeating: 0, count: 22) + Data([UInt8(name.count), 0, 0, 0]) + name + content
    let central = ascii("PK") + Data([1, 2]) + Data(repeating: 0, count: 42) + name
    let eocd = ascii("PK") + Data([5, 6]) + Data(repeating: 0, count: 8) + le32(central.count) + le32(local.count)
        + le16(comment.utf8.count) + ascii(comment)
    return local + central + eocd
}

/// `count` MPEG-1 Layer III frames, 128 kbps at 44.1 kHz: a 4-byte header and 417 bytes each.
func mp3Frames(_ count: Int) -> Data {
    var data = Data()
    for index in 0..<count { data += Data([0xFF, 0xFB, 0x90, 0x00]) + filler(413, seed: UInt8(index & 0x3F)) }
    return data
}

/// A two-frame GIF89a (global and local color tables, graphic control extensions) whose LZW
/// sub-blocks contain `00 3B`.
func gifBytes(trailer: Bool = true) -> Data {
    var data = ascii("GIF89a") + Data([2, 0, 2, 0, 0x81, 0, 0]) + filler(12)
    let control = Data([0x21, 0xF9, 0x04, 0x00, 0x0A, 0x00, 0x00, 0x00])
    data += control + Data([0x2C, 0, 0, 0, 0, 2, 0, 2, 0, 0x00, 0x02, 0x05, 0x01, 0x00, 0x3B, 0x02, 0x03, 0x00])
    data += control + Data([0x2C, 0, 0, 0, 0, 2, 0, 2, 0, 0x81]) + filler(12) + Data([0x02, 0x03, 0x00, 0x3B, 0x00, 0x00])
    data += Data([0x21, 0xFE, 0x02]) + ascii(";;") + Data([0x00])
    if trailer { data += Data([0x3B]) }
    return data
}

/// Deterministic incompressible-looking bytes.
func randomBytes(_ count: Int, seed: UInt64) -> Data {
    var state = seed
    var data = Data(count: count)
    for index in 0..<count {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var mixed = (state ^ (state >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        data[index] = UInt8(truncatingIfNeeded: mixed ^ (mixed >> 31))
    }
    return data
}

func wavBytes(samples: Int = 500) -> Data {
    let body = ascii("fmt ") + le32(16) + filler(16) + ascii("data") + le32(samples) + filler(samples)
    return ascii("RIFF") + le32(body.count + 4) + ascii("WAVE") + body
}

func mp4Bytes(mediaBytes: Int = 2000, brand: String = "isom") -> Data {
    func box(_ type: String, _ payload: Data) -> Data { be32(payload.count + 8) + ascii(type) + payload }
    return box("ftyp", ascii(brand) + be32(0) + ascii("mp42")) + box("moov", filler(8)) + box("mdat", filler(mediaBytes))
}

func sevenZipBytes(packed: Int = 300, header: Int = 40) -> Data {
    Data([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C, 0, 4]) + filler(4) + le64(packed) + le64(header) + filler(4) + filler(packed) + filler(header)
}

func sqliteBytes(pageSize: Int = 1024, pages: Int = 3) -> Data {
    var header = ascii("SQLite format 3") + Data([0]) + Data(repeating: 0, count: 84)
    header[16] = UInt8(pageSize >> 8); header[17] = UInt8(pageSize & 0xFF)
    header.replaceSubrange(28..<32, with: be32(pages))
    return header + filler(pageSize * pages - header.count)
}

/// A gzip member with stored DEFLATE blocks (at most 65535 bytes each) and a correct trailer.
func gzipBytes(body: Int = 100, content: Data? = nil) -> Data {
    let payload = content ?? filler(body)
    var data = Data([0x1F, 0x8B, 0x08, 0, 0, 0, 0, 0, 0, 3])
    var offset = 0
    repeat {
        let count = min(65535, payload.count - offset)
        let last = offset + count == payload.count
        data += Data([last ? 1 : 0]) + le16(count) + le16(count ^ 0xFFFF) + payload.subdata(in: offset..<offset + count)
        offset += count
    } while offset < payload.count
    var crc = CRC32()
    for byte in payload { crc.update(byte) }
    return data + le32(Int(crc.value)) + le32(payload.count & 0xFFFF_FFFF)
}

// MARK: - Harness

private actor Collector {
    var files: [RecoveredFile] = []
    func add(_ file: RecoveredFile) { files.append(file) }
}

/// A zeroed device with `pieces` written at their offsets.
func device(size: Int, _ pieces: [(Int, Data)]) -> Data {
    var image = Data(repeating: 0, count: size)
    for (offset, piece) in pieces { image.replaceSubrange(offset..<offset + piece.count, with: piece) }
    return image
}

/// Streams `image` through a fresh carver in `chunk`-sized pieces, one contiguous extent per entry
/// of `extents` (the whole device by default), and returns what it emitted.
/// With `announce`, each extent is announced through `beginExtent` first, as `ScanSession` should;
/// `resume` maps an extent's start to the offset its sweep resumes from.
func carve(_ image: Data, chunk: Int = 1 << 20, claimed: [DataRun] = [], library: SignatureLibrary = .bundled,
           limits: SignatureCarver.Limits = .default, extents: [Range<Int>]? = nil, announce: Bool = false,
           resume: [Int: Int] = [:]) async throws -> [RecoveredFile] {
    let collector = Collector()
    let carver = SignatureCarver(emit: { await collector.add($0) }, library: library, limits: limits)
    try await carver.begin(claimed: claimed, deviceSizeBytes: Int64(image.count))
    for extent in extents ?? [0..<image.count] {
        if announce { try await carver.beginExtent(offset: Int64(extent.lowerBound), length: Int64(extent.count)) }
        var offset = resume[extent.lowerBound] ?? extent.lowerBound
        while offset < extent.upperBound {
            let count = min(chunk, extent.upperBound - offset)
            try await carver.consume(image.subdata(in: offset..<offset + count), at: Int64(offset))
            offset += count
        }
    }
    try await carver.finish()
    return await collector.files
}

func library(_ json: String...) throws -> SignatureLibrary {
    SignatureLibrary(signatures: try json.map { try FileSignature(json: Data($0.utf8)) })
}

extension RecoveredFile {
    var run: DataRun? { if case .runs(let runs) = content, runs.count == 1 { runs[0] } else { nil } }
    var bytes: Range<Int>? { run.flatMap { run in run.deviceOffset.map { Int($0)..<Int($0 + run.length) } } }
}

@Suite("Signature carving (AD-6, Stories 3.1 + 3.2)")
struct CarvingTests {
    @Test func jpegInUnallocatedSpaceIsCarvedExactlyWithMediumConfidence() async throws {
        let jpeg = jpegBytes()
        let files = try await carve(device(size: 64 * 1024, [(8192, jpeg)]))
        let file = try #require(files.first)
        #expect(files.count == 1)
        #expect(file.bytes == 8192..<8192 + jpeg.count)
        #expect(file.sizeBytes == Int64(jpeg.count))
        #expect(!file.isPartial)
        #expect(file.overwriteConfidence == 0)
        #expect(file.recoveryMethod == .carved)
        #expect(file.recoveryConfidence == .medium)
        #expect(file.name == "jpeg-000000002000.jpg")
        #expect(file.path == "/Reconstructed/Pictures/jpeg-000000002000.jpg")
        #expect(file.category == .pictures)
        #expect(file.modified == nil && !file.isDeleted)
        #expect(file.sourceMetadata.filesystem == .carved)
        #expect(file.sourceMetadata.recordOffset == 8192 && file.sourceMetadata.volumeOffset == 0)
        #expect(file.sourceMetadata.rawRecord.prefix(3) == Data([0xFF, 0xD8, 0xFF]))
        #expect(file.recoveryEvidence.fragmentCount == 1)
    }

    @Test func embeddedThumbnailFooterDoesNotEndTheJPEGEarly() async throws {
        let withThumbnail = jpegBytes(thumbnail: true), without = jpegBytes(thumbnail: false)
        let files = try await carve(device(size: 32 * 1024, [(4096, withThumbnail), (16384, without)]))
        #expect(files.map(\.bytes) == [4096..<4096 + withThumbnail.count, 16384..<16384 + without.count])
        #expect(files.allSatisfy { !$0.isPartial })
    }

    @Test func headerAndFooterSpanningChunkBoundariesAreStillCarved() async throws {
        // Chunks of 8193 bytes: the header at 8192 is split FF | D8 FF, and a JPEG of 8195 bytes puts
        // its FFD9 footer across the next boundary at 16386.
        var jpeg = jpegBytes(body: 1)
        jpeg = jpegBytes(body: 8195 - jpeg.count + 1)
        #expect(jpeg.count == 8195)
        for chunk in [8193, 1, 7, 512, 1 << 20] {
            let files = try await carve(device(size: 32 * 1024, [(8192, jpeg)]), chunk: chunk)
            #expect(files.map(\.bytes) == [8192..<8192 + jpeg.count], Comment(rawValue: "chunk \(chunk)"))
            #expect(files.first?.isPartial == false, Comment(rawValue: "chunk \(chunk)"))
        }
    }

    @Test func signatureInsideAClaimedRunIsNotCarved() async throws {
        let jpeg = jpegBytes()
        let image = device(size: 64 * 1024, [(8192, jpeg), (32768, jpeg)])
        let files = try await carve(image, claimed: [DataRun(deviceOffset: 8192, length: 5), DataRun(deviceOffset: nil, length: 4096)])
        #expect(files.map(\.bytes) == [32768..<32768 + jpeg.count])
    }

    @Test func carveNeverOverlapsAClaimedRunAndIsMarkedOverwritten() async throws {
        let jpeg = jpegBytes(body: 6000)
        let image = device(size: 64 * 1024, [(4096, jpeg)])
        let files = try await carve(image, claimed: [DataRun(deviceOffset: 6144, length: 512)])
        let file = try #require(files.first)
        #expect(file.bytes == 4096..<6144)
        #expect(file.isPartial)
        #expect(file.overwriteConfidence == 1)
        #expect(file.recoveryConfidence == .low)
    }

    @Test func headerWithoutFooterHittingMaxBytesIsPartialAndLow() async throws {
        let small = try library("""
        {"schemaVersion": 1, "id": "jpeg", "extension": "jpg", "category": "pictures", "header": "FFD8FF", "footer": "FFD9", "maxBytes": 4096}
        """)
        let image = device(size: 64 * 1024, [(8192, jpegBytes(body: 10000, thumbnail: false, footer: false))])
        let files = try await carve(image, library: small)
        let file = try #require(files.first)
        #expect(files.count == 1)
        #expect(file.bytes == 8192..<8192 + 4096)
        #expect(file.isPartial)
        #expect(file.overwriteConfidence == 0.6)
        #expect(file.recoveryConfidence == .low)
    }

    @Test func headerWithoutFooterAtTheEndOfTheExtentIsPartial() async throws {
        let jpeg = jpegBytes(body: 3000, footer: false)
        let files = try await carve(device(size: 8192 + jpeg.count, [(8192, jpeg)]), chunk: 1000)
        let file = try #require(files.first)
        #expect(file.bytes == 8192..<8192 + jpeg.count)
        #expect(file.isPartial && file.overwriteConfidence == 0.6)
        #expect(file.recoveryConfidence == .low)
    }

    @Test func nextHeaderEndsAnOpenEndedCarve() async throws {
        // RAR 5 has no end rule.
        let rar5 = ascii("Rar!") + Data([0x1A, 0x07, 0x01, 0x00]) + filler(100), png = pngBytes()
        let files = try await carve(device(size: 64 * 1024, [(4096, rar5), (8192, png)]))
        #expect(files.map(\.name) == ["rar5-000000001000.rar", "png-000000002000.png"])
        #expect(files[0].bytes == 4096..<8192 && files[0].isPartial && files[0].overwriteConfidence == 0.6)
        #expect(files[1].bytes == 8192..<8192 + png.count && !files[1].isPartial)
    }

    @Test func zipEndsAtTheEndOfCentralDirectoryIncludingItsComment() async throws {
        for comment in ["", "archive comment"] {
            let zip = zipBytes(comment: comment)
            let files = try await carve(device(size: 16 * 1024, [(1024, zip)]))
            #expect(files.map(\.bytes) == [1024..<1024 + zip.count], Comment(rawValue: comment))
            #expect(files.first?.recoveryConfidence == .medium, Comment(rawValue: comment))
            #expect(files.first?.path == "/Reconstructed/Archives/zip-000000000400.zip", Comment(rawValue: comment))
        }
    }

    @Test func pdfEndsAtItsLastEOFMarker() async throws {
        let pdf = pdfBytes(revisions: 3, trailingNewline: false)
        let files = try await carve(device(size: 16 * 1024, [(2048, pdf)]), chunk: 777)
        #expect(files.map(\.bytes) == [2048..<2048 + pdf.count])
        #expect(files.first?.isPartial == false)
        // Cut short by the next header, it still ends at the last %%EOF seen.
        let truncated = pdfBytes(revisions: 2, trailingNewline: false)
        let cut = try await carve(device(size: 16 * 1024, [(2048, truncated + ascii("\ntrailing junk")), (4096, pngBytes())]))
        #expect(cut.map(\.bytes) == [2048..<2048 + truncated.count, 4096..<4096 + pngBytes().count])
        #expect(cut.allSatisfy { !$0.isPartial })
    }

    @Test func sizeFieldsGiveExactSizesForRIFFSevenZipAndSQLite() async throws {
        let wav = wavBytes(), seven = sevenZipBytes(), sqlite = sqliteBytes()
        let files = try await carve(device(size: 64 * 1024, [(1024, wav), (8192, seven), (16384, sqlite)]), chunk: 4000)
        #expect(files.map(\.bytes) == [1024..<1024 + wav.count, 8192..<8192 + seven.count, 16384..<16384 + sqlite.count])
        #expect(files.map(\.name) == ["wav-000000000400.wav", "7z-000000002000.7z", "sqlite-000000004000.sqlite"])
        #expect(files.map { $0.path.split(separator: "/")[1] } == ["Audio", "Archives", "Other"])
        #expect(files.allSatisfy { !$0.isPartial && $0.recoveryConfidence == .medium })
    }

    @Test func inconsistentSizeFieldIsReportedAsOverwritten() async throws {
        var wav = wavBytes()
        wav.replaceSubrange(4..<8, with: le32(0))   // a RIFF shorter than its own header
        let files = try await carve(device(size: 16 * 1024, [(1024, wav), (4096, pngBytes())]))
        #expect(files.first?.bytes == 1024..<4096)
        #expect(files.first?.isPartial == true && files.first?.overwriteConfidence == 1)
    }

    @Test func boxWalkEndsAnMP4AtItsLastBoxAndIgnoresEmbeddedHeaders() async throws {
        // Inside a box of a trusted size, a sector-aligned JPEG (cover art, which MP4 may embed)
        // and a weak gzip header are media data, not new files.
        var mp4 = mp4Bytes(mediaBytes: 6000)
        mp4.replaceSubrange(4096 - 1024..<4096 - 1024 + 4, with: Data([0xFF, 0xD8, 0xFF, 0xE0]))
        mp4.replaceSubrange(4608 - 1024..<4608 - 1024 + 3, with: Data([0x1F, 0x8B, 0x08]))
        let files = try await carve(device(size: 32 * 1024, [(1024, mp4), (16384, jpegBytes())]), chunk: 3000)
        #expect(files.map(\.name) == ["mp4-000000000400.mp4", "jpeg-000000004000.jpg"])
        #expect(files[0].bytes == 1024..<1024 + mp4.count)
        #expect(files[0].recoveryConfidence == .medium && !files[0].isPartial)
        let mov = mp4Bytes(brand: "qt  "), heic = mp4Bytes(brand: "heic"), m4a = mp4Bytes(brand: "M4A ")
        let more = try await carve(device(size: 32 * 1024, [(0, mov), (8192, heic), (16384, m4a)]))
        #expect(more.map(\.name) == ["mov-000000000000.mov", "heic-000000002000.heic", "m4a-000000004000.m4a"])
        #expect(more.map(\.sizeBytes) == [mov, heic, m4a].map { Int64($0.count) })
    }

    @Test func twoSignaturesMatchingOneOffsetGetSequenceSuffixes() async throws {
        let both = try library(
            """
            {"schemaVersion": 1, "id": "pic", "extension": "pic", "category": "pictures", "header": "FFD8FF", "footer": "FFD9"}
            """,
            """
            {"schemaVersion": 1, "id": "pic", "extension": "pic", "category": "pictures", "header": "FFD8FFE0", "maxBytes": 2048}
            """)
        let files = try await carve(device(size: 16 * 1024, [(4096, jpegBytes(thumbnail: false))]), library: both)
        #expect(files.map(\.name).sorted() == ["pic-000000001000-2.pic", "pic-000000001000.pic"])
    }

    @Test func totalCarvedFilesAreBounded() async throws {
        let png = pngBytes()
        let image = device(size: 16 * 1024, [(0, png), (4096, png), (8192, png)])
        var limits = SignatureCarver.Limits.default
        limits.maxCarvedFiles = 2
        let collector = Collector()
        // Read through the protocol, as `ScanSession` would to report the cap to the user.
        let carver: any Carver = SignatureCarver(emit: { await collector.add($0) }, library: .bundled, limits: limits)
        try await carver.begin(claimed: [], deviceSizeBytes: Int64(image.count))
        try await carver.consume(image, at: 0)
        try await carver.finish()
        #expect(await collector.files.count == 2)
        #expect(await carver.hitFileLimit)
    }

    @Test func headersAreOnlyLookedForAtSectorBoundaries() async throws {
        let jpeg = jpegBytes()
        let files = try await carve(device(size: 16 * 1024, [(4100, jpeg), (8192, jpeg)]))
        #expect(files.map(\.bytes) == [8192..<8192 + jpeg.count])
    }

    @Test func extentsAreCarvedIndependently() async throws {
        // The first extent ends mid-JPEG (partial); the second extent starts with its own JPEG.
        let jpeg = jpegBytes(body: 5000)
        let image = device(size: 32 * 1024, [(4096, jpeg), (16384, jpeg)])
        let files = try await carve(image, chunk: 1000, extents: [0..<8192, 16384..<32768])
        #expect(files.map(\.bytes) == [4096..<8192, 16384..<16384 + jpeg.count])
        #expect(files.map(\.isPartial) == [true, false])
        #expect(files.map(\.sourceMetadata.volumeOffset) == [0, 16384])
    }

    @Test func carvedFilesNeverScoreHigh() async throws {
        let image = device(size: 128 * 1024, [
            (0, jpegBytes()), (8192, jpegBytes(footer: false)), (16384, pngBytes()), (24576, pdfBytes()), (32768, zipBytes()),
            (40960, wavBytes()), (49152, mp4Bytes()), (65536, gzipBytes()), (73728, sevenZipBytes()), (81920, sqliteBytes()),
            (98304, Data([0x1F, 0x8B, 0x08]) + filler(100)),
        ])
        let files = try await carve(image, chunk: 4096)
        // The last one is not a gzip header (FLG reserved bits set), so nothing is carved there.
        #expect(files.count == 10)
        #expect(files.allSatisfy { $0.recoveryMethod == .carved && $0.recoveryConfidence != .high && $0.recoveryConfidence != nil })
        #expect(files.allSatisfy { $0.path.hasPrefix("/Reconstructed/") && $0.path.hasSuffix("/" + $0.name) })
        #expect(files.allSatisfy { $0.isPartial == ($0.recoveryConfidence == .low) })
    }

    // MARK: Review fixes

    /// A copy of the bundled JPEG rule with other limits, for walk-termination tests.
    static func jpegRule(maxBytes: Int) throws -> SignatureLibrary {
        try library("""
        {"schemaVersion": 1, "id": "jpeg", "extension": "jpg", "category": "pictures", "header": "FFD8FFE?",
         "segments": {"start": 2, "size": {"offset": 2, "width": 2, "endian": "big", "adjust": 2}, "minimum": 4,
                      "typeOffset": 0, "typeLength": 1, "typeMatch": "FF", "fillByte": "FF", "stopAt": ["FFDA"]},
         "footer": "FFD9", "maxBytes": \(maxBytes)}
        """)
    }

    @Test func sizeClaimOverRealHeadersDoesNotHideThem() async throws {
        // An mp4 whose mdat claims 3 GB, over a region holding a JPEG and a PNG: the claim is far
        // past trustedMaxBytes, so it can't make them embedded data.
        func box(_ type: String, _ payload: Data) -> Data { be32(payload.count + 8) + ascii(type) + payload }
        let mp4 = box("ftyp", ascii("isom") + be32(0) + ascii("mp42")) + box("moov", filler(8)) + be32(3_000_000_000) + ascii("mdat") + filler(200)
        let jpeg = jpegBytes(), png = pngBytes()
        let files = try await carve(device(size: 64 * 1024, [(0, mp4), (8192, jpeg), (16384, png)]), chunk: 5000)
        #expect(files.map(\.name) == ["mp4-000000000000.mp4", "jpeg-000000002000.jpg", "png-000000004000.png"])
        try #require(files.count == 3)
        #expect(files[0].bytes == 0..<8192 && files[0].isPartial && files[0].overwriteConfidence == 0.6)
        #expect(files[1].bytes == 8192..<8192 + jpeg.count && !files[1].isPartial)
        #expect(files[2].bytes == 16384..<16384 + png.count && !files[2].isPartial)

        // A RIFF with a garbage length that still fits the device: a PNG inside its claimed range
        // is not something WAV embeds, so the WAV is cut there and the PNG is carved.
        var wav = wavBytes()
        wav.replaceSubrange(4..<8, with: le32(40000))
        let riff = try await carve(device(size: 64 * 1024, [(1024, wav), (4096, png)]))
        #expect(riff.map(\.name) == ["wav-000000000400.wav", "png-000000001000.png"])
        try #require(riff.count == 2)
        #expect(riff[0].bytes == 1024..<4096 && riff[0].isPartial && riff[0].overwriteConfidence == 0.6)
        #expect(riff[1].bytes == 4096..<4096 + png.count && !riff[1].isPartial)
    }

    @Test func embeddableHeadersInsideATrustedStructureStayEmbedded() async throws {
        // A JPEG whose EXIF thumbnail starts at a sector boundary: JPEG embeds JPEG.
        let thumbnail = Data([0xFF, 0xD8, 0xFF, 0xDB, 0x00, 0x04, 0x01, 0x02]) + filler(40) + Data([0xFF, 0xD9])
        let prefix = Data([0xFF, 0xD8]) + Data([0xFF, 0xE0, 0x00, 0x10]) + ascii("JFIF") + Data([0, 1, 1, 0, 0, 1, 0, 1, 0, 0])
        let pad = 512 - prefix.count - 4 - 6
        let app1 = Data([0xFF, 0xE1]) + Data([UInt8((2 + 6 + pad + thumbnail.count) >> 8), UInt8((2 + 6 + pad + thumbnail.count) & 0xFF)])
            + ascii("Exif") + Data([0, 0]) + filler(pad) + thumbnail
        let jpeg = prefix + app1 + Data([0xFF, 0xDA, 0x00, 0x0C, 0x03, 0x01, 0x00, 0x02, 0x11, 0x03, 0x11, 0x00, 0x3F, 0x00]) + filler(900) + Data([0xFF, 0xD9])
        #expect(jpeg[512..<516] == Data([0xFF, 0xD8, 0xFF, 0xDB]))
        let files = try await carve(device(size: 16 * 1024, [(4096, jpeg)]))
        #expect(files.map(\.bytes) == [4096..<4096 + jpeg.count])
        #expect(files.first?.isPartial == false)
    }

    @Test func sizeClaimsPastTrustedMaxBytesArePartial() async throws {
        // 70 MiB claimed and present on the device: still partial, since the bundled WAV trusts
        // at most 64 MiB.
        let claimed = 70 << 20
        let wav = ascii("RIFF") + le32(claimed - 8) + ascii("WAVE") + ascii("fmt ") + le32(16) + filler(16)
        let files = try await carve(device(size: claimed + 4096, [(0, wav)]))
        let file = try #require(files.first { $0.name.hasPrefix("wav-") })
        #expect(file.bytes == 0..<claimed)
        #expect(file.isPartial && file.overwriteConfidence == 0.6 && file.recoveryConfidence == .low)

        // The cap is per signature, from JSON.
        func rule(_ trusted: String) throws -> SignatureLibrary {
            try library("""
            {"schemaVersion": 1, "id": "wav", "extension": "wav", "category": "audio", "header": "52494646????????57415645",
             "sizeField": {"offset": 4, "width": 4, "endian": "little", "adjust": 8}\(trusted)}
            """)
        }
        let small = wavBytes(samples: 6000)
        let untrusted = try await carve(device(size: 16 * 1024, [(0, small)]), library: rule(", \"trustedMaxBytes\": 4096"))
        #expect(untrusted.map(\.bytes) == [0..<small.count] && untrusted.first?.isPartial == true)
        let trusted = try await carve(device(size: 16 * 1024, [(0, small)]), library: rule(""))
        #expect(trusted.map(\.bytes) == [0..<small.count] && trusted.first?.isPartial == false)
    }

    @Test func gifEndsAtItsTrailerNotAt003BInsideImageData() async throws {
        let gif = gifBytes()
        for chunk in [1, 13, 1 << 20] {
            let files = try await carve(device(size: 16 * 1024, [(2048, gif)]), chunk: chunk)
            #expect(files.map(\.bytes) == [2048..<2048 + gif.count], Comment(rawValue: "chunk \(chunk)"))
            #expect(files.first?.isPartial == false && files.first?.recoveryConfidence == .medium)
        }
        // No trailer before the next header: partial. A broken block: inconsistent.
        let truncated = try await carve(device(size: 16 * 1024, [(2048, gifBytes(trailer: false)), (4096, pngBytes())]))
        #expect(truncated.first?.bytes == 2048..<2048 + gifBytes(trailer: false).count)
        #expect(truncated.first?.isPartial == true && truncated.first?.overwriteConfidence == 1)
        var broken = gif
        broken[6 + 7 + 12 + 8] = 0x99   // the first image descriptor's introducer
        let bad = try await carve(device(size: 16 * 1024, [(2048, broken)]))
        #expect(bad.first?.bytes == 2048..<2048 + 33 && bad.first?.isPartial == true && bad.first?.overwriteConfidence == 1)
    }

    @Test func recordWalkStoppingForTheWrongReasonIsNotValidated() async throws {
        let jpeg = jpegBytes(thumbnail: false)
        let app0End = 2 + 18
        // A non-marker where the next marker must be, before start-of-scan: inconsistent.
        var broken = jpeg
        broken.replaceSubrange(app0End..<app0End + 2, with: Data([0x00, 0x00]))
        let inconsistent = try await carve(device(size: 16 * 1024, [(4096, broken)]))
        #expect(inconsistent.first?.bytes == 4096..<4096 + app0End)
        #expect(inconsistent.first?.isPartial == true && inconsistent.first?.overwriteConfidence == 1)
        // The walk reaches a claimed run before start-of-scan: claimed.
        let claimed = try await carve(device(size: 16 * 1024, [(4096, jpeg)]), claimed: [DataRun(deviceOffset: 4096 + Int64(app0End), length: 100)])
        #expect(claimed.first?.bytes == 4096..<4096 + app0End)
        #expect(claimed.first?.isPartial == true && claimed.first?.overwriteConfidence == 1)
        // The walk reaches maxBytes before start-of-scan: limit.
        let limited = try await carve(device(size: 16 * 1024, [(4096, jpeg)]), library: Self.jpegRule(maxBytes: app0End))
        #expect(limited.first?.bytes == 4096..<4096 + app0End)
        #expect(limited.first?.isPartial == true && limited.first?.overwriteConfidence == 0.6)
        // FF fill bytes before a marker are skipped.
        var filled = jpeg
        filled.insert(contentsOf: [0xFF, 0xFF, 0xFF], at: app0End)
        let fill = try await carve(device(size: 16 * 1024, [(4096, filled)]))
        #expect(fill.map(\.bytes) == [4096..<4096 + filled.count] && fill.first?.isPartial == false)
    }

    @Test func isoBoxSizesZeroAndOneAreHonoured() async throws {
        func box(_ type: String, _ payload: Data) -> Data { be32(payload.count + 8) + ascii(type) + payload }
        let head = box("ftyp", ascii("isom") + be32(0) + ascii("mp42")) + box("moov", filler(8))
        // Size 0: the box runs to the end of the file, so the end isn't validated.
        let toEnd = head + be32(0) + ascii("mdat") + filler(3000)
        let zero = try await carve(device(size: 1024 + toEnd.count, [(1024, toEnd)]), chunk: 700)
        #expect(zero.map(\.bytes) == [1024..<1024 + toEnd.count])
        #expect(zero.first?.isPartial == true && zero.first?.overwriteConfidence == 0.6)
        // Size 1: the real size is the 64-bit largesize after the type.
        let large = head + be32(1) + ascii("mdat") + be64(16 + 3000) + filler(3000) + box("free", filler(4))
        let one = try await carve(device(size: 16 * 1024, [(1024, large)]), chunk: 700)
        #expect(one.map(\.bytes) == [1024..<1024 + large.count] && one.first?.isPartial == false)
    }

    @Test func mp3FrameSyncNeedsTwoConsecutiveValidFrames() async throws {
        // Compressed-looking bytes with a CBR frame-sync header planted at every fourth sector.
        var image = randomBytes(2 << 20, seed: 42)
        for sector in stride(from: 0, to: image.count - 4, by: 2048) { image.replaceSubrange(sector..<sector + 3, with: Data([0xFF, 0xFB, 0x90])) }
        let files = try await carve(image)
        #expect(files.filter { $0.name.hasPrefix("mp3-") }.isEmpty, Comment(rawValue: "\(files.map(\.name))"))
        // A real untagged stream is still found, and now ends exactly after its last frame.
        let stream = try await carve(device(size: 32 * 1024, [(4096, mp3Frames(10))]))
        #expect(stream.map(\.name) == ["mp3-000000001000.mp3"])
        #expect(stream.first?.bytes == 4096..<4096 + mp3Frames(10).count && stream.first?.isPartial == false)
    }

    @Test func weakHeadersDoNotCutAnArchive() async throws {
        // A stored ZIP whose content puts, at sector boundaries, a valid two-frame MP3 sync, a
        // gzip header and an FFD8FF without a valid next marker. None of them ends the ZIP.
        let offset = 1024, dataStart = 30 + 5
        var content = filler(4000)
        for (sector, bytes) in [(2048, mp3Frames(2)), (3072, Data([0x1F, 0x8B, 0x08])), (3584, Data([0xFF, 0xD8, 0xFF, 0x00]))] {
            let at = sector - offset - dataStart
            content.replaceSubrange(at..<at + bytes.count, with: bytes)
        }
        let zip = zipBytes(content: content)
        let files = try await carve(device(size: 32 * 1024, [(offset, zip)]), chunk: 1000)
        #expect(files.map(\.bytes) == [offset..<offset + zip.count], Comment(rawValue: "\(files.map(\.name))"))
        #expect(files.first?.isPartial == false)
    }

    @Test func announcedExtentsAreHardCutsAndSetTheVolumeOffset() async throws {
        let jpeg = jpegBytes(body: 5000)
        let image = device(size: 32 * 1024, [(4096, jpeg), (20480, jpeg)])
        // Adjacent extents, announced: the JPEG crossing the boundary is cut there.
        let announced = try await carve(image, chunk: 1000, extents: [0..<8192, 8192..<32768], announce: true)
        #expect(announced.map(\.bytes) == [4096..<8192, 20480..<20480 + jpeg.count])
        #expect(announced.map(\.isPartial) == [true, false])
        #expect(announced.map(\.sourceMetadata.volumeOffset) == [0, 8192])
        // Not announced, the stream looks contiguous (the previous behaviour).
        let implicit = try await carve(image, chunk: 1000, extents: [0..<8192, 8192..<32768])
        #expect(implicit.map(\.bytes) == [4096..<4096 + jpeg.count, 20480..<20480 + jpeg.count])
        // A resumed sweep: the extent starts at 16384, the sweep at 18432.
        let resumed = try await carve(image, chunk: 1000, extents: [16384..<32768], announce: true, resume: [16384: 18432])
        #expect(resumed.map(\.bytes) == [20480..<20480 + jpeg.count])
        #expect(resumed.first?.sourceMetadata.volumeOffset == 16384)
    }

    @Test func footerSearchStopsAtADeferredHeader() async throws {
        // A JPEG without EOI, then a PNG at the next sector whose IHDR data holds FF D9. The PNG
        // header cuts the JPEG however the chunks fall, even when the window ends between the
        // PNG header and the bytes needed to evaluate it.
        let jpeg = jpegBytes(body: 3000, thumbnail: false, footer: false)
        var png = pngBytes()
        png.replaceSubrange(20..<22, with: Data([0xFF, 0xD9]))
        let image = device(size: 16 * 1024, [(1024, jpeg), (5120, png)])
        for chunk in [1, 7, 333, 4150, 2075, 1 << 20] {
            let files = try await carve(image, chunk: chunk, extents: [1000..<image.count])
            #expect(files.map(\.bytes) == [1024..<5120, 5120..<5120 + png.count], Comment(rawValue: "chunk \(chunk)"))
            #expect(files.map(\.isPartial) == [true, false], Comment(rawValue: "chunk \(chunk)"))
        }
    }

    @Test func zipEndOfCentralDirectoryStraddlingABoundIsNotValidated() async throws {
        let zip = zipBytes(comment: "an archive comment")
        let eocd = zip.count - 22 - 18
        // A claimed run starts inside the comment.
        let claimed = try await carve(device(size: 16 * 1024, [(1024, zip)]), claimed: [DataRun(deviceOffset: Int64(1024 + eocd + 25), length: 512)])
        #expect(claimed.map(\.bytes) == [1024..<1024 + eocd + 25])
        #expect(claimed.first?.isPartial == true && claimed.first?.overwriteConfidence == 1)
        // The extent ends inside the record.
        let truncated = try await carve(device(size: 1024 + eocd + 10, [(1024, zip.prefix(eocd + 10))]))
        #expect(truncated.map(\.bytes) == [1024..<1024 + eocd + 10])
        #expect(truncated.first?.isPartial == true && truncated.first?.overwriteConfidence == 0.6)
    }

    @Test func overflowingFooterLengthIsInconsistentNotACrash() async throws {
        let rule = try library("""
        {"schemaVersion": 1, "id": "blob", "extension": "blob", "category": "other", "header": "AABBCCDD",
         "footer": "EEFF0011", "footerSizeField": {"offset": 4, "width": 8, "endian": "little"}, "maxBytes": 68719476736}
        """)
        let blob = Data([0xAA, 0xBB, 0xCC, 0xDD]) + filler(100) + Data([0xEE, 0xFF, 0x00, 0x11]) + le64(0x7FFF_FFFF_FFFF_FF00) + filler(20)
        let files = try await carve(device(size: 16 * 1024, [(4096, blob)]), library: rule)
        #expect(files.map(\.bytes) == [4096..<4096 + 104])
        #expect(files.first?.isPartial == true && files.first?.overwriteConfidence == 1)
    }

    // MARK: Format fixtures

    @Test func rarOleId3AviHeicAndNestedZipFixtures() async throws {
        let rar = ascii("Rar!") + Data([0x1A, 0x07, 0x00]) + filler(500) + Data([0xC4, 0x3D, 0x7B, 0x00, 0x40, 0x07, 0x00])
        let ole = Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]) + filler(3000)
        // ID3v2.3 tag, then frames; one frame sync lands on a sector boundary and stays part of it.
        let tag = ascii("ID3") + Data([3, 0, 0, 0, 0, 0, 100]) + filler(100)
        let id3 = tag + filler(4096 - tag.count) + mp3Frames(4)
        let avi = ascii("RIFF") + le32(4 + 1000) + ascii("AVI ") + filler(1000)
        let heic = mp4Bytes(brand: "mif1")
        let png = pngBytes()
        // A second ID3 tag is a new file, not more of the first one.
        let image = device(size: 96 * 1024, [(0, rar), (4096, ole), (8192, png), (16384, id3), (24576, tag), (28672, png),
                                             (32768, avi), (36864, heic)])
        let files = try await carve(image, chunk: 3000)
        #expect(files.map(\.name) == ["rar-000000000000.rar", "ole-000000001000.doc", "png-000000002000.png", "mp3-000000004000.mp3",
                                      "mp3-000000006000.mp3", "png-000000007000.png", "avi-000000008000.avi", "heic-000000009000.heic"])
        #expect(files.map(\.bytes) == [0..<rar.count, 4096..<8192, 8192..<8192 + png.count, 16384..<24576, 24576..<28672,
                                       28672..<28672 + png.count, 32768..<32768 + avi.count, 36864..<36864 + heic.count])
        #expect(files.map(\.isPartial) == [false, true, false, true, true, false, false, false])
        #expect(files.map { $0.path.split(separator: "/")[1] } == ["Archives", "Documents", "Pictures", "Audio", "Audio", "Pictures", "Videos", "Pictures"])

        // A stored ZIP inside a ZIP, its local header at a sector boundary or not: the inner
        // EOCD's offsets don't match the outer archive, so the outer one ends at its own EOCD.
        let inner = zipBytes(comment: "inner")
        for lead in [512 - 1024 % 512 - 35, 100] {
            let outer = zipBytes(content: filler(lead) + inner + filler(300))
            let nested = try await carve(device(size: 16 * 1024, [(1024, outer)]), chunk: 777)
            #expect(nested.map(\.bytes) == [1024..<1024 + outer.count], Comment(rawValue: "lead \(lead)"))
            #expect(nested.first?.isPartial == false, Comment(rawValue: "lead \(lead)"))
        }
    }

    @Test func scanSessionCarvesFreeSpaceButNotMetadataFiles() async {
        var image = fatImage()
        let jpeg = jpegBytes()
        // Cluster 3 holds HELLO.TXT's bytes (claimed); cluster 50 is free space.
        let small = jpegBytes(body: 100, thumbnail: false)
        image.replaceSubrange(553 * 512..<553 * 512 + small.count, with: small)
        image.replaceSubrange(600 * 512..<600 * 512 + jpeg.count, with: jpeg)
        let events = await scan(image)
        let files = events.compactMap { if case .found(let file) = $0 { file } else { nil } }
        #expect(events.last == .completed)
        #expect(files.filter { $0.recoveryMethod == .metadata }.map(\.path) == ["/HELLO.TXT", "/FOLDER/NESTED.TXT"])
        let carved = files.filter { $0.recoveryMethod == .carved }
        #expect(carved.map(\.path) == ["/Reconstructed/Pictures/jpeg-00000004b000.jpg"])
        #expect(carved.first?.bytes == 600 * 512..<600 * 512 + jpeg.count)
        #expect(carved.first?.recoveryConfidence == .medium)
    }
}

// MARK: - Exact ends for MP3, OLE2 and gzip

/// A compound file (version 3, 512-byte sectors): the directory in sector 0, one `Data` stream of
/// `streamBytes` in the sectors after it, then the FAT. `mutate` edits the FAT before it is
/// written.
func ole2Bytes(streamBytes: Int = 5000, declaredSize: Int? = nil, mutate: (inout [UInt32]) -> Void = { _ in }) -> Data {
    let streamSectors = (streamBytes + 511) / 512
    let fatSector = 1 + streamSectors
    var fat = [UInt32](repeating: 0xFFFF_FFFF, count: 128)
    fat[0] = 0xFFFF_FFFE
    for sector in 1..<fatSector { fat[sector] = sector == fatSector - 1 ? 0xFFFF_FFFE : UInt32(sector + 1) }
    fat[fatSector] = 0xFFFF_FFFD
    mutate(&fat)

    var header = Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]) + Data(repeating: 0, count: 16)
    header += le16(0x3E) + le16(3) + le16(0xFFFE) + le16(9) + le16(6) + Data(repeating: 0, count: 6)
    header += le32(0) + le32(1) + le32(0) + le32(0) + le32(4096) + le32(0xFFFF_FFFE) + le32(0) + le32(0xFFFF_FFFE) + le32(0)
    header += le32(fatSector)
    for _ in 1..<109 { header += le32(0xFFFF_FFFF) }
    #expect(header.count == 512)

    func entry(_ name: String, type: UInt8, child: UInt32, start: UInt32, size: Int) -> Data {
        var nameBytes = Data()
        for unit in name.utf16 { nameBytes += le16(Int(unit)) }
        nameBytes += le16(0)
        var record = nameBytes + Data(repeating: 0, count: 64 - nameBytes.count) + le16(nameBytes.count) + Data([type, 1])
        record += le32(0xFFFF_FFFF) + le32(0xFFFF_FFFF) + le32(Int(child)) + Data(repeating: 0, count: 16 + 4 + 16)
        return record + le32(Int(start)) + le64(size)
    }
    var directory = entry("Root Entry", type: 5, child: 1, start: 0xFFFF_FFFE, size: 0)
    directory += entry("Data", type: 2, child: 0xFFFF_FFFF, start: 1, size: declaredSize ?? streamBytes)
    directory += Data(repeating: 0, count: 256)
    var stream = filler(streamBytes, seed: 9)
    stream += Data(repeating: 0, count: streamSectors * 512 - streamBytes)
    var fatData = Data()
    for value in fat { fatData += le32(Int(value)) }
    return header + directory + stream + fatData
}

/// Output of a system tool fed `input`, or nil when the tool is unavailable.
func runTool(_ path: String, _ arguments: [String], input: Data? = nil) throws -> Data? {
    guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    if let input {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("salvage-tool-\(UUID().uuidString)")
        try input.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        process.standardInput = try FileHandle(forReadingFrom: file)
        try process.run()
    } else {
        try process.run()
    }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return process.terminationStatus == 0 ? data : nil
}

/// Compressible text: dynamic Huffman blocks with back-references.
func sampleText(_ lines: Int) -> Data {
    var text = ""
    for line in 0..<lines { text += "line \(line): the quick brown fox jumps over the lazy dog \(line * 7919 % 1000)\n" }
    return Data(text.utf8)
}

@Suite("Carving exact ends: MP3, OLE2, gzip")
struct CarvingFormatEndTests {
    // MARK: MP3

    @Test func mp3StreamEndsAfterItsLastFrameOrTrailer() async throws {
        let frames = mp3Frames(12)
        let tagV1 = ascii("TAG") + filler(125)
        var apeHeader = ascii("APETAGEX") + le32(2000) + le32(32 + 20) + le32(1) + le32(1 << 31 | 1 << 29) + Data(repeating: 0, count: 8)
        let apeFooter = ascii("APETAGEX") + le32(2000) + le32(32 + 20) + le32(1) + le32(1 << 31) + Data(repeating: 0, count: 8)
        apeHeader += filler(20) + apeFooter
        let id3 = ascii("ID3") + Data([3, 0, 0, 0, 0, 1, 0]) + filler(128) + Data(repeating: 0, count: 300)
        for (label, file) in [("plain", frames), ("id3v1", frames + tagV1), ("ape+id3v1", frames + apeHeader + tagV1),
                              ("id3v2", id3 + frames + tagV1)] {
            for chunk in [333, 4096, 1 << 20] {
                // Junk after the file's own end, past the zero slack of its last sector.
                let end = 4096 + file.count, junk = (end + 511) / 512 * 512
                let image = device(size: 64 * 1024, [(4096, file), (junk, filler(2000, seed: 3))])
                let files = try await carve(image, chunk: chunk)
                #expect(files.map(\.bytes) == [4096..<end], Comment(rawValue: "\(label) chunk \(chunk) \(files.map(\.name))"))
                #expect(files.first?.isPartial == false && files.first?.recoveryConfidence == .medium, Comment(rawValue: label))
            }
        }
    }

    @Test func mp3WithoutEvidenceOfItsEndStaysPartial() async throws {
        // Too few frames to trust.
        let few = try await carve(device(size: 32 * 1024, [(4096, mp3Frames(5))]))
        #expect(few.map(\.bytes) == [4096..<4096 + mp3Frames(5).count] && few.first?.isPartial == true)
        // Non-zero bytes that aren't a frame right after the last frame: fragmented or overwritten.
        let frames = mp3Frames(12)
        let cut = try await carve(device(size: 32 * 1024, [(4096, frames + filler(600, seed: 5))]))
        #expect(cut.map(\.bytes) == [4096..<4096 + frames.count] && cut.first?.isPartial == true)
        #expect(cut.first?.overwriteConfidence == 0.6)
        // The extent ends inside a frame.
        let truncated = try await carve(device(size: 4096 + frames.count - 100, [(4096, frames.prefix(frames.count - 100))]))
        #expect(truncated.first?.isPartial == true)
        // An APE header whose footer is missing is not a trailer.
        let ape = ascii("APETAGEX") + le32(2000) + le32(52) + le32(1) + le32(1 << 31 | 1 << 29) + Data(repeating: 0, count: 8) + filler(52)
        let broken = try await carve(device(size: 32 * 1024, [(4096, frames + ape)]))
        #expect(broken.map(\.bytes) == [4096..<4096 + frames.count] && broken.first?.isPartial == true)
    }

    @Test func xingFrameCountMustMatchTheWalk() async throws {
        // MPEG-1 stereo: the Xing tag sits after the 4-byte header and 32 bytes of side info.
        func stream(frames: Int, declared: Int) -> Data {
            var data = mp3Frames(frames)
            data.replaceSubrange(36..<48, with: ascii("Xing") + be32(1) + be32(declared))
            return data
        }
        let exact = try await carve(device(size: 32 * 1024, [(4096, stream(frames: 4, declared: 4))]))
        #expect(exact.first?.isPartial == false, Comment(rawValue: "a declared count below the minimum still validates"))
        let mismatch = try await carve(device(size: 32 * 1024, [(4096, stream(frames: 12, declared: 40))]))
        #expect(mismatch.map(\.bytes) == [4096..<4096 + mp3Frames(12).count] && mismatch.first?.isPartial == true)
    }

    @Test func coverArtInsideAnID3TagIsNotANewFile() async throws {
        // A JPEG header at a sector boundary inside the tag's declared size.
        var tag = ascii("ID3") + Data([3, 0, 0, 0, 0, 8, 0]) + filler(1024)   // 1024-byte body
        tag.replaceSubrange(512..<512 + 4, with: Data([0xFF, 0xD8, 0xFF, 0xE0]))
        let file = tag + mp3Frames(10)
        let files = try await carve(device(size: 32 * 1024, [(4096, file)]))
        #expect(files.map(\.name) == ["mp3-000000001000.mp3"])
        #expect(files.first?.bytes == 4096..<4096 + file.count && files.first?.isPartial == false)
    }

    // MARK: OLE2

    @Test func ole2EndsAfterItsHighestAllocatedSector() async throws {
        let ole = ole2Bytes()
        #expect(ole.count == 13 * 512)
        for chunk in [1000, 4096, 1 << 20] {
            let files = try await carve(device(size: 64 * 1024, [(8192, ole), (8192 + ole.count, filler(3000, seed: 4))]), chunk: chunk)
            #expect(files.map(\.bytes) == [8192..<8192 + ole.count], Comment(rawValue: "chunk \(chunk)"))
            #expect(files.first?.isPartial == false && files.first?.recoveryConfidence == .medium)
            #expect(files.first?.path == "/Reconstructed/Documents/ole-000000002000.doc")
        }
    }

    @Test func corruptOrIncompleteOLE2StaysPartial() async throws {
        let cases: [(String, Data)] = [
            ("pointer past the FAT", ole2Bytes { $0[4] = 500 }),
            ("cycle", ole2Bytes { $0[10] = 1 }),
            ("two predecessors", ole2Bytes { $0[0] = 3 }),
            ("FAT sector marked free", ole2Bytes { $0[11] = 0xFFFF_FFFF }),
            ("FAT sector inside a chain", ole2Bytes { $0[11] = 0xFFFF_FFFE; $0[10] = 11 }),
            ("unlisted FAT marker", ole2Bytes { $0[12] = 0xFFFF_FFFD }),
            ("stream size disagrees with its chain", ole2Bytes(declaredSize: 9000)),
        ]
        for (label, ole) in cases {
            let files = try await carve(device(size: 64 * 1024, [(8192, ole), (32768, pngBytes())]))
            #expect(files.first?.name == "ole-000000002000.doc", Comment(rawValue: label))
            #expect(files.first?.isPartial == true && files.first?.overwriteConfidence == 1, Comment(rawValue: label))
        }
        // The FAT (in the last sector) is past the end of the extent.
        let ole = ole2Bytes()
        let truncated = try await carve(device(size: 8192 + ole.count - 512, [(8192, ole.prefix(ole.count - 512))]))
        #expect(truncated.first?.isPartial == true && truncated.first?.overwriteConfidence == 0.6)
        // A strong header before the FAT was read ends the carve.
        var cut = ole
        cut.replaceSubrange(2048..<2048 + 8, with: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
        let files = try await carve(device(size: 64 * 1024, [(8192, cut)]))
        #expect(files.first?.bytes == 8192..<8192 + 2048 && files.first?.isPartial == true)
    }

    @Test func realWordDocumentFromTextutilIsCarvedExactly() async throws {
        let text = FileManager.default.temporaryDirectory.appendingPathComponent("salvage-\(UUID().uuidString).txt")
        let doc = text.deletingPathExtension().appendingPathExtension("doc")
        defer { try? FileManager.default.removeItem(at: text); try? FileManager.default.removeItem(at: doc) }
        try sampleText(400).write(to: text)
        guard try runTool("/usr/bin/textutil", ["-convert", "doc", text.path, "-output", doc.path]) != nil,
              let bytes = try? Data(contentsOf: doc) else {
            Issue.record("textutil unavailable; real-file OLE2 fixture not exercised")
            return
        }
        #expect(bytes.prefix(8) == Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]))
        let files = try await carve(device(size: 4096 + bytes.count + 8192, [(4096, bytes), (4096 + bytes.count, filler(5000, seed: 6))]),
                                    chunk: 3000)
        let file = try #require(files.first { $0.name.hasPrefix("ole-") })
        #expect(file.bytes == 4096..<4096 + bytes.count)
        #expect(!file.isPartial && file.recoveryConfidence == .medium)
    }

    // MARK: gzip

    @Test func gzipEndsAtAVerifiedTrailer() async throws {
        var fixtures: [(String, Data)] = [("stored", gzipBytes(body: 70000)), ("empty", gzipBytes(content: Data()))]
        if let dynamic = try runTool("/usr/bin/gzip", ["-c", "-9"], input: sampleText(3000)) { fixtures.append(("dynamic", dynamic)) }
        if let fixed = try runTool("/usr/bin/gzip", ["-c"], input: Data("hello hello hello".utf8)) { fixtures.append(("fixed", fixed)) }
        if let random = try runTool("/usr/bin/gzip", ["-c"], input: randomBytes(40000, seed: 1)) { fixtures.append(("incompressible", random)) }
        if let named = try runTool("/usr/bin/gzip", ["-c", "-N"], input: sampleText(50)) { fixtures.append(("named", named)) }
        #expect(fixtures.count == 6, Comment(rawValue: "gzip(1) unavailable for real-file fixtures"))
        for (label, gzip) in fixtures {
            for chunk in [777, 1 << 20] {
                let image = device(size: 4096 + gzip.count + 8192, [(4096, gzip), (4096 + gzip.count, filler(4000, seed: 2))])
                let files = try await carve(image, chunk: chunk)
                #expect(files.map(\.bytes) == [4096..<4096 + gzip.count], Comment(rawValue: "\(label) chunk \(chunk) \(files.map(\.name))"))
                #expect(files.first?.isPartial == false && files.first?.recoveryConfidence == .medium, Comment(rawValue: label))
            }
        }
        // Byte-at-a-time chunks for a small real stream.
        if let small = try runTool("/usr/bin/gzip", ["-c"], input: sampleText(20)) {
            let files = try await carve(device(size: 8192, [(1024, small)]), chunk: 1)
            #expect(files.map(\.bytes) == [1024..<1024 + small.count] && files.first?.isPartial == false)
        }
    }

    @Test func multiMemberGzipIsOneFileUnlessAMemberEndsOnASector() async throws {
        let first = gzipBytes(body: 300), second = gzipBytes(body: 200, content: sampleText(3))
        let joined = try await carve(device(size: 16 * 1024, [(1024, first + second)]))
        #expect(joined.map(\.bytes) == [1024..<1024 + first.count + second.count] && joined.first?.isPartial == false)
        // A member ending exactly at a sector boundary: the next gzip is its own file.
        let aligned = gzipBytes(body: 1024 - 23)
        #expect(aligned.count == 1024)
        let split = try await carve(device(size: 16 * 1024, [(1024, aligned), (2048, second)]))
        #expect(split.map(\.bytes) == [1024..<2048, 2048..<2048 + second.count])
        #expect(split.allSatisfy { !$0.isPartial })
    }

    @Test func corruptOrTruncatedGzipStaysPartial() async throws {
        let text = try runTool("/usr/bin/gzip", ["-c", "-9"], input: sampleText(2000)) ?? gzipBytes(body: 5000)
        var badCRC = text
        badCRC[badCRC.count - 6] ^= 0x55
        var badData = text
        badData[text.count / 2] ^= 0xFF
        var badSize = gzipBytes(body: 400)
        badSize[badSize.count - 4] ^= 1
        for (label, gzip) in [("crc", badCRC), ("data", badData), ("isize", badSize)] {
            let files = try await carve(device(size: 64 * 1024 + text.count, [(4096, gzip)]))
            let file = try #require(files.first, Comment(rawValue: label))
            #expect(file.isPartial && file.overwriteConfidence == 1, Comment(rawValue: label))
            #expect(file.bytes.map { $0.upperBound <= 4096 + gzip.count } == true, Comment(rawValue: label))
        }
        // The extent ends mid-stream.
        let truncated = try await carve(device(size: 4096 + text.count / 2, [(4096, text.prefix(text.count / 2))]))
        #expect(truncated.map(\.bytes) == [4096..<4096 + text.count / 2])
        #expect(truncated.first?.isPartial == true && truncated.first?.overwriteConfidence == 0.6)
        // Invalid header flags: not a gzip at all.
        var flags = gzipBytes(body: 100)
        flags[3] = 0x80
        #expect(try await carve(device(size: 16 * 1024, [(4096, flags)])).isEmpty)
        // A stored-block length whose complement doesn't match.
        var stored = gzipBytes(body: 100)
        stored[13] ^= 0x01
        let bad = try await carve(device(size: 16 * 1024, [(4096, stored)]))
        #expect(bad.first?.isPartial == true && bad.first?.overwriteConfidence == 1)
    }

    @Test func gzipHeaderFlagsAreParsed() async throws {
        // FEXTRA, FNAME, FCOMMENT and a correct FHCRC.
        var header = Data([0x1F, 0x8B, 0x08, 0x1E, 0, 0, 0, 0, 0, 3]) + le16(4) + ascii("ab12") + ascii("name.txt") + Data([0])
            + ascii("a comment") + Data([0])
        var crc = CRC32()
        for byte in header { crc.update(byte) }
        header += le16(Int(crc.value & 0xFFFF))
        let body = gzipBytes(body: 300).dropFirst(10)
        let gzip = header + body
        let files = try await carve(device(size: 16 * 1024, [(4096, gzip)]), chunk: 5)
        #expect(files.map(\.bytes) == [4096..<4096 + gzip.count] && files.first?.isPartial == false)
        var wrong = gzip
        wrong[header.count - 1] ^= 0xFF
        #expect(try await carve(device(size: 16 * 1024, [(4096, wrong)])).isEmpty)
    }
}

// MARK: - Baseline JPEG encoding for the entropy decoder and reassembly tests

/// Encodes a baseline (or extended, SOF1) JPEG from synthetic quantized coefficients: no pixels
/// are involved, but the scan is a real T.81 entropy-coded scan (canonical Huffman codes, byte
/// stuffing, restart markers with one-bit padding).
struct TestJPEG {
    struct Table {
        let counts: [UInt8]
        let values: [UInt8]
        /// Canonical code and length of each symbol.
        var codes: [UInt8: (code: Int, length: Int)] {
            var codes: [UInt8: (Int, Int)] = [:]
            var code = 0, index = 0
            for length in 1...16 {
                for _ in 0..<Int(counts[length - 1]) { codes[values[index]] = (code, length); code += 1; index += 1 }
                code <<= 1
            }
            return codes
        }
        /// A table with `values` spread over lengths `first...` (no all-ones code).
        static func spread(_ values: [UInt8], perLength: [Int]) -> Table {
            var counts = [UInt8](repeating: 0, count: 16)
            var remaining = values.count, length = 0
            for count in perLength where remaining > 0 { let used = min(count, remaining); counts[length] = UInt8(used); remaining -= used; length += 1 }
            precondition(remaining == 0)
            return Table(counts: counts, values: values)
        }
    }

    static let acSymbols: [UInt8] = [0x00, 0x01, 0x02, 0x11, 0x03, 0x21, 0x12, 0x04, 0x31, 0xF0]
        + (0..<16).flatMap { run in (1...10).map { UInt8(run << 4 | $0) } }.filter { ![0x01, 0x02, 0x11, 0x03, 0x21, 0x12, 0x04, 0x31].contains($0) }
    /// Luminance-like and chrominance-like tables with different shapes.
    static let dc0 = Table.spread(Array(0...11), perLength: [0, 1, 5, 1, 1, 1, 1, 1, 1])
    static let dc1 = Table.spread(Array(0...11), perLength: [0, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1])
    static let ac0 = Table.spread(acSymbols, perLength: [0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 125])
    static let ac1 = Table.spread(acSymbols, perLength: [0, 2, 1, 3, 2, 3, 3, 4, 3, 5, 4, 4, 0, 0, 2, 126])

    var width = 128
    var height = 96
    /// Sampling factors per component (one component: grayscale).
    var sampling: [(h: Int, v: Int)] = [(2, 2), (1, 1), (1, 1)]
    var restartInterval = 0
    var seed: UInt64 = 1
    var extended = false
    /// How many nonzero AC coefficients a block gets, at most.
    var density = 12

    var totalMCUs: Int {
        let maxH = sampling.map(\.h).max()!, maxV = sampling.map(\.v).max()!
        if sampling.count == 1 { return (width + 7) / 8 * ((height + 7) / 8) }
        return (width + 8 * maxH - 1) / (8 * maxH) * ((height + 8 * maxV - 1) / (8 * maxV))
    }

    func encode() -> Data {
        var data = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10]) + Data("JFIF".utf8) + Data([0, 1, 1, 0, 0, 1, 0, 1, 0, 0])
        func segment(_ marker: UInt8, _ payload: Data) { data += Data([0xFF, marker, UInt8((payload.count + 2) >> 8), UInt8((payload.count + 2) & 0xFF)]) + payload }
        segment(0xDB, Data([0x00]) + Data(repeating: 8, count: 64))
        var frame = Data([8, UInt8(height >> 8), UInt8(height & 0xFF), UInt8(width >> 8), UInt8(width & 0xFF), UInt8(sampling.count)])
        for (index, factor) in sampling.enumerated() { frame += Data([UInt8(index + 1), UInt8(factor.h << 4 | factor.v), 0]) }
        segment(extended ? 0xC1 : 0xC0, frame)
        for (id, table) in [(0x00, Self.dc0), (0x10, Self.ac0), (0x01, Self.dc1), (0x11, Self.ac1)] as [(UInt8, Table)] {
            segment(0xC4, Data([id]) + Data(table.counts) + Data(table.values))
        }
        if restartInterval > 0 { segment(0xDD, Data([UInt8(restartInterval >> 8), UInt8(restartInterval & 0xFF)])) }
        var scan = Data([UInt8(sampling.count)])
        for index in sampling.indices { scan += Data([UInt8(index + 1), index == 0 ? 0x00 : 0x11]) }
        segment(0xDA, scan + Data([0, 63, 0]))

        var writer = BitWriter()
        var random = seed
        func next(_ bound: Int) -> Int {
            random = random &* 6364136223846793005 &+ 1442695040888963407
            return Int((random >> 33) % UInt64(bound))
        }
        let tables = [(Self.dc0.codes, Self.ac0.codes), (Self.dc1.codes, Self.ac1.codes)]
        var dc = [Int](repeating: 0, count: sampling.count), predictors = dc
        let blocks = sampling.count == 1 ? [0] : sampling.enumerated().flatMap { Array(repeating: $0.offset, count: $0.element.h * $0.element.v) }
        var restart = 0
        for mcu in 0..<totalMCUs {
            if restartInterval > 0, mcu > 0, mcu % restartInterval == 0 {
                data += writer.finish()
                data += Data([0xFF, UInt8(0xD0 + restart)])
                restart = (restart + 1) & 7
                predictors = predictors.map { _ in 0 }
            }
            for component in blocks {
                let (dcCodes, acCodes) = tables[component == 0 ? 0 : 1]
                dc[component] = max(-100, min(100, dc[component] + next(41) - 20))
                let difference = dc[component] - predictors[component]
                predictors[component] = dc[component]
                writer.coded(difference, dcCodes, run: nil)
                // A few AC coefficients, sometimes past a run of 16 zeros (ZRL).
                var position = 1
                for _ in 0..<next(density + 1) {
                    let run = next(5) == 0 ? 16 + next(8) : next(4)
                    guard position + run <= 63 else { break }
                    var value = next(61) - 30
                    if value == 0 { value = 1 }
                    var zeros = run
                    while zeros >= 16 { writer.symbol(0xF0, acCodes); zeros -= 16 }
                    writer.coded(value, acCodes, run: zeros)
                    position += run + 1
                }
                if position < 64 { writer.symbol(0x00, acCodes) }
            }
        }
        data += writer.finish()
        return data + Data([0xFF, 0xD9])
    }

    struct BitWriter {
        var bytes = Data()
        var accumulator = 0
        var count = 0
        mutating func put(_ value: Int, _ length: Int) {
            for bit in stride(from: length - 1, through: 0, by: -1) {
                accumulator = accumulator << 1 | (value >> bit & 1)
                count += 1
                if count == 8 {
                    bytes.append(UInt8(accumulator))
                    if accumulator == 0xFF { bytes.append(0) }
                    accumulator = 0; count = 0
                }
            }
        }
        mutating func symbol(_ symbol: UInt8, _ codes: [UInt8: (code: Int, length: Int)]) {
            let code = codes[symbol]!
            put(code.code, code.length)
        }
        /// A DC difference (`run == nil`) or an AC coefficient after `run` zeros.
        mutating func coded(_ value: Int, _ codes: [UInt8: (code: Int, length: Int)], run: Int?) {
            var size = 0
            while (1 << size) <= abs(value) { size += 1 }
            symbol(UInt8((run ?? 0) << 4 | size), codes)
            if size > 0 { put(value >= 0 ? value : value + (1 << size) - 1, size) }
        }
        /// Pads the last byte with one bits.
        mutating func finish() -> Data {
            if count > 0 { put((1 << (8 - count)) - 1, 8 - count) }
            defer { bytes = Data() }
            return bytes
        }
    }
}

/// A JPEG from ImageIO (Apple's encoder) of a noisy gradient.
func imageIOJPEG(width: Int = 160, height: Int = 120, progressive: Bool = false, quality: Double = 0.9) throws -> Data {
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    var state: UInt64 = 7
    for y in 0..<height {
        for x in 0..<width {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let noise = Int(state >> 59)
            let base = (y * width + x) * 4
            pixels[base] = UInt8((x * 255 / width + noise) & 0xFF)
            pixels[base + 1] = UInt8((y * 255 / height + noise) & 0xFF)
            pixels[base + 2] = UInt8(((x + y) * 2 + noise * 3) & 0xFF)
            pixels[base + 3] = 255
        }
    }
    let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
    let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                     space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                     provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    let output = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(output as CFMutableData, "public.jpeg" as CFString, 1, nil))
    var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
    if progressive { properties[kCGImagePropertyJFIFDictionary] = [kCGImagePropertyJFIFIsProgressive: true] }
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
    return output as Data
}

extension RecoveredFile {
    var runs: [DataRun] { if case .runs(let runs) = content { runs } else { [] } }
    /// The file's bytes read from `image` through its runs.
    func contents(in image: Data) -> Data {
        var data = Data()
        for run in runs { if let offset = run.deviceOffset { data += image.subdata(in: Int(offset)..<Int(offset + run.length)) } }
        return data.prefix(Int(sizeBytes))
    }
}

/// Offset of the start-of-scan data in a JPEG.
func scanDataStart(_ jpeg: Data) -> Int {
    var offset = 2
    while jpeg[offset + 1] != 0xDA { offset += 2 + Int(jpeg[offset + 2]) << 8 + Int(jpeg[offset + 3]) }
    return offset + 2 + Int(jpeg[offset + 2]) << 8 + Int(jpeg[offset + 3])
}

@Suite("Baseline JPEG entropy decoding and bifragment reassembly")
struct JPEGReassemblyTests {
    /// Reassembly is opt-in; these limits turn it on.
    static let joining: SignatureCarver.Limits = {
        var limits = SignatureCarver.Limits.default
        limits.reassembleFragmentedJPEGs = true
        return limits
    }()

    /// A two-fragment layout: the JPEG at `start`, split after `firstLength` bytes, `gap` placed at
    /// the break, the rest of the JPEG at `resume`.
    static func split(_ jpeg: Data, start: Int = 8192, firstLength: Int, gap: Data, resume: Int, size: Int = 256 * 1024) -> Data {
        device(size: size, [(start, jpeg.prefix(firstLength)), (start + firstLength, gap), (resume, jpeg.dropFirst(firstLength))])
    }

    @Test(arguments: [0, 1, 4])
    func syntheticBaselineJPEGsDecodeToTheirFullMCUCount(restartInterval: Int) {
        for (sampling, extended) in [([(2, 2), (1, 1), (1, 1)], false), ([(1, 1)], false), ([(2, 1), (1, 1), (1, 1)], true), ([(1, 1), (1, 1), (1, 1)], false)] {
            let encoder = TestJPEG(width: 99, height: 61, sampling: sampling, restartInterval: restartInterval, seed: 3, extended: extended)
            let jpeg = encoder.encode()
            let result = JPEGBaselineDecoder.decode(jpeg)
            let label = Comment(rawValue: "\(sampling) interval \(restartInterval)")
            #expect(result.outcome == .complete, label)
            #expect(result.mcusDecoded == encoder.totalMCUs && result.totalMCUs == encoder.totalMCUs, label)
            #expect(result.validUpTo == jpeg.count, label)
            #expect(result.restartSequenceOK, label)
            #expect(result.restartMarkers == (restartInterval == 0 ? 0 : (encoder.totalMCUs - 1) / restartInterval), label)
        }
    }

    @Test func imageIOBaselineJPEGsDecodeAndProgressiveOnesAreUnsupported() throws {
        for (width, height, quality) in [(160, 120, 0.9), (33, 17, 0.5), (640, 8, 1.0)] {
            let jpeg = try imageIOJPEG(width: width, height: height, quality: quality)
            let result = JPEGBaselineDecoder.decode(jpeg)
            #expect(result.outcome == .complete, Comment(rawValue: "\(width)x\(height)"))
            #expect(result.mcusDecoded == result.totalMCUs && result.totalMCUs > 0)
        }
        let progressive = try imageIOJPEG(progressive: true)
        #expect(progressive.contains(0xC2))
        guard case .unsupported = JPEGBaselineDecoder.decode(progressive).outcome else {
            Issue.record("a progressive JPEG must be unsupported, not judged")
            return
        }
    }

    @Test func brokenScanDataIsInvalidNearTheBreakAndTruncatedDataIsTruncated() throws {
        let jpeg = TestJPEG(width: 256, height: 128, restartInterval: 8, seed: 5).encode()
        let middle = jpeg.count / 2
        // Foreign bytes from the middle on (FF-free, so the marker syntax still looks fine).
        var foreign = jpeg.prefix(middle) + filler(jpeg.count - middle - 2) + Data([0xFF, 0xD9])
        var result = JPEGBaselineDecoder.decode(foreign)
        #expect(result.outcome == .invalid)
        #expect(result.validUpTo >= middle - 8 && result.validUpTo <= middle + 600)
        #expect(result.mcusDecoded < result.totalMCUs)
        // A restart marker out of sequence.
        foreign = jpeg
        let marker = try #require((scanDataStart(jpeg)..<jpeg.count - 1).first { jpeg[$0] == 0xFF && jpeg[$0 + 1] == 0xD1 })
        foreign[marker + 1] = 0xD3
        result = JPEGBaselineDecoder.decode(foreign)
        #expect(result.outcome == .invalid && !result.restartSequenceOK)
        // Data that just stops.
        result = JPEGBaselineDecoder.decode(jpeg.prefix(middle))
        #expect(result.outcome == .truncated && result.validUpTo == middle)
        // Real data with an EOI too early.
        result = JPEGBaselineDecoder.decode(jpeg.prefix(middle) + Data([0xFF, 0xD9]))
        #expect(result.outcome == .invalid)
    }

    @Test func contiguousRealJPEGsAreStillCarvedInOnePiece() async throws {
        let jpeg = try imageIOJPEG(), synthetic = TestJPEG(restartInterval: 3).encode()
        let files = try await carve(device(size: 128 * 1024, [(4096, jpeg), (65536, synthetic)]), chunk: 4096)
        #expect(files.map(\.bytes) == [4096..<4096 + jpeg.count, 65536..<65536 + synthetic.count])
        #expect(files.allSatisfy { !$0.isPartial && $0.recoveryConfidence == .medium })
    }

    @Test(arguments: [0, 2])
    func twoFragmentsAroundAnUnrelatedFileAreJoined(restartInterval: Int) async throws {
        let jpeg = TestJPEG(width: 256, height: 192, restartInterval: restartInterval, seed: 11).encode()
        #expect(jpeg.count > 12 * 1024)
        let firstLength = 8 * 512, png = pngBytes(body: 3000), resume = 8192 + firstLength + 8192
        let image = Self.split(jpeg, firstLength: firstLength, gap: png, resume: resume)
        for chunk in [1 << 20, 4096, 1000, 513] {
            let label = Comment(rawValue: "interval \(restartInterval), chunk \(chunk)")
            let files = try await carve(image, chunk: chunk, limits: Self.joining)
            #expect(files.count == 2, label)
            let joined = try #require(files.first { $0.signature == "jpeg" }, label)
            #expect(joined.runs == [DataRun(deviceOffset: 8192, length: Int64(firstLength)),
                                    DataRun(deviceOffset: Int64(resume), length: Int64(jpeg.count - firstLength))], label)
            #expect(joined.sizeBytes == Int64(jpeg.count), label)
            #expect(joined.contents(in: image) == jpeg, label)
            #expect(!joined.isPartial && joined.overwriteConfidence == 0.3, label)
            #expect(joined.recoveryEvidence.fragmentCount == 2 && joined.recoveryConfidence == .low, label)
            #expect(!joined.sourceMetadata.contiguous && joined.name == "jpeg-000000002000.jpg", label)
            #expect(files.first { $0.signature == "png" }?.bytes == 8192 + firstLength..<8192 + firstLength + png.count, label)
        }
    }

    @Test func aGapWithoutAHeaderOrWithAStrayFooterIsBridgedToo() async throws {
        let jpeg = TestJPEG(width: 256, height: 192, seed: 21).encode()
        let firstLength = 11 * 512, resume = 8192 + firstLength + 3 * 512
        // Old random data between the fragments, holding an FF D9 that ends the carve early today.
        var gap = randomBytes(3 * 512, seed: 9)
        gap[700] = 0xFF; gap[701] = 0xD9
        let image = Self.split(jpeg, firstLength: firstLength, gap: gap, resume: resume)
        let files = try await carve(image, chunk: 2048, limits: Self.joining)
        let joined = try #require(files.first)
        #expect(files.count == 1)
        #expect(joined.runs.map(\.deviceOffset) == [8192, Int64(resume)] && joined.contents(in: image) == jpeg)
        #expect(!joined.isPartial && joined.recoveryConfidence == .low)
    }

    @Test func aLiveFileBetweenTheFragmentsIsSkipped() async throws {
        let jpeg = TestJPEG(width: 200, height: 200, restartInterval: 5, seed: 31).encode()
        let firstLength = 6 * 512, resume = 8192 + firstLength + 4096
        let image = Self.split(jpeg, firstLength: firstLength, gap: filler(4096), resume: resume)
        let files = try await carve(image, claimed: [DataRun(deviceOffset: Int64(8192 + firstLength), length: 4096)], limits: Self.joining)
        let joined = try #require(files.first)
        #expect(files.count == 1 && joined.contents(in: image) == jpeg && joined.runs.count == 2)
    }

    @Test func aDecoyThatPassesMarkerSyntaxButNotEntropyDecodingIsNeverJoined() async throws {
        let jpeg = TestJPEG(width: 256, height: 192, restartInterval: 4, seed: 41).encode()
        let firstLength = 8 * 512, png = pngBytes(body: 3000), resume = 8192 + firstLength + 8192
        let rest = jpeg.count - firstLength
        // FF-free filler and stuffed random bytes ending in EOI: valid marker syntax, but not this
        // JPEG's entropy data. Also the true continuation with a single corrupted byte.
        var stuffed = Data()
        for byte in randomBytes(rest, seed: 77) { stuffed.append(byte); if byte == 0xFF { stuffed.append(0) } }
        var corrupted = Data(jpeg.dropFirst(firstLength))
        corrupted[corrupted.startIndex + rest / 2] ^= 0x5A
        let decoys: [(String, Data)] = [
            ("filler", filler(rest - 2) + Data([0xFF, 0xD9])), ("stuffed", stuffed + Data([0xFF, 0xD9])),
            ("corrupted", corrupted),
        ]
        for (label, decoy) in decoys {
            let image = device(size: 256 * 1024, [(8192, jpeg.prefix(firstLength)), (8192 + firstLength, png), (resume, decoy)])
            let files = try await carve(image, chunk: 4096, limits: Self.joining)
            let partial = try #require(files.first { $0.signature == "jpeg" }, Comment(rawValue: label))
            #expect(partial.runs.count == 1 && partial.isPartial, Comment(rawValue: label))
            #expect(partial.bytes == 8192..<8192 + firstLength, Comment(rawValue: label))
            #expect(files.allSatisfy { $0.runs.count == 1 }, Comment(rawValue: label))
        }
    }

    @Test func twoCandidateContinuationsAreAmbiguousAndNeitherIsUsed() async throws {
        let jpeg = TestJPEG(width: 256, height: 192, seed: 51).encode()
        let firstLength = 8 * 512, png = pngBytes(body: 3000)
        let rest = Data(jpeg.dropFirst(firstLength))
        let second = 8192 + firstLength + 8192, third = (second + rest.count + 4096) / 512 * 512
        let image = device(size: 256 * 1024, [(8192, jpeg.prefix(firstLength)), (8192 + firstLength, png), (second, rest), (third, rest)])
        let files = try await carve(image, limits: Self.joining)
        let partial = try #require(files.first { $0.signature == "jpeg" })
        #expect(partial.runs.count == 1 && partial.isPartial && partial.bytes == 8192..<8192 + firstLength)
    }

    @Test func aFragmentedProgressiveJPEGStaysUnreassembled() async throws {
        let jpeg = try imageIOJPEG(width: 320, height: 240, progressive: true)
        #expect(jpeg.count > 8 * 512 + 2048)
        let firstLength = 8 * 512, png = pngBytes(body: 3000), resume = 8192 + firstLength + 8192
        let files = try await carve(Self.split(jpeg, firstLength: firstLength, gap: png, resume: resume), limits: Self.joining)
        let partial = try #require(files.first { $0.signature == "jpeg" })
        #expect(partial.runs.count == 1 && partial.isPartial && partial.bytes == 8192..<8192 + firstLength)
    }

    @Test func theSearchIsBoundedByItsWindow() async throws {
        let jpeg = TestJPEG(width: 256, height: 192, seed: 61).encode()
        let firstLength = 8 * 512, png = pngBytes(body: 3000), resume = 8192 + firstLength + 64 * 1024
        let image = Self.split(jpeg, firstLength: firstLength, gap: png, resume: resume)
        var limits = Self.joining
        limits.joinSearchBytes = 32 * 1024
        let bounded = try await carve(image, limits: limits)
        #expect(bounded.first { $0.signature == "jpeg" }?.isPartial == true)
        limits.joinSearchBytes = 128 * 1024
        let found = try await carve(image, limits: limits)
        #expect(found.first { $0.signature == "jpeg" }?.contents(in: image) == jpeg)
    }

    @Test func byDefaultASplitJPEGStaysPartialAndAStrayFooterNoLongerValidatesIt() async throws {
        let jpeg = TestJPEG(width: 256, height: 192, seed: 11).encode()
        let firstLength = 8 * 512, resume = 8192 + firstLength + 8192
        let split = try await carve(Self.split(jpeg, firstLength: firstLength, gap: pngBytes(body: 3000), resume: resume))
        #expect(split.first { $0.signature == "jpeg" }?.bytes == 8192..<8192 + firstLength)
        #expect(split.allSatisfy { $0.runs.count == 1 })
        #expect(split.first { $0.signature == "jpeg" }?.isPartial == true)
        // Foreign bytes after the break, then an FF D9: marker syntax alone would call this a
        // complete file; the scan data says it isn't.
        var gap = randomBytes(3 * 512, seed: 9)
        gap[700] = 0xFF; gap[701] = 0xD9
        let image = Self.split(jpeg, firstLength: firstLength, gap: gap, resume: 8192 + firstLength + 3 * 512)
        let files = try await carve(image)
        let file = try #require(files.first)
        #expect(files.count == 1 && file.bytes == 8192..<8192 + firstLength + 702)
        #expect(file.isPartial && file.overwriteConfidence == 1 && file.recoveryConfidence == .low)
    }

    @Test func aSameSizeSiblingsOrphanedTailCanPassEntropyValidationWhichIsWhyJoiningIsOff() async throws {
        // Two JPEGs with the same tables and dimensions; the second's tail (its header gone) lies
        // where the first's second fragment would be, and the first's real continuation is gone.
        let first = TestJPEG(width: 256, height: 192, seed: 1134, density: 13).encode()
        let sibling = TestJPEG(width: 256, height: 192, seed: 5135, density: 13).encode()
        let firstLength = 11 * 512
        let image = device(size: 192 * 1024, [(8192, first.prefix(firstLength)), (8192 + firstLength, pngBytes(body: 3000)),
                                              (8192 + firstLength + 8192, Data(sibling.dropFirst(firstLength / 2 + 1000)))])
        // With joining on, the decoder validates a join that is not the first JPEG.
        let joined = try await carve(image, limits: Self.joining)
        let wrong = try #require(joined.first { $0.runs.count == 2 })
        #expect(wrong.contents(in: image) != first)
        #expect(JPEGBaselineDecoder.decode(wrong.contents(in: image)).outcome == .complete)
        // By default it stays a partial carve of the bytes that really are the first JPEG's.
        let files = try await carve(image)
        #expect(files.allSatisfy { $0.runs.count == 1 })
        #expect(files.first { $0.signature == "jpeg" }?.bytes == 8192..<8192 + firstLength)
    }

    @Test func entropySignatureFieldIsValidated() throws {
        #expect(SignatureLibrary.bundled.signatures.first { $0.id == "jpeg" }?.entropy == .jpegBaseline)
        #expect(throws: SignatureError.self) {
            try FileSignature(json: Data(#"{"schemaVersion": 1, "id": "x", "extension": "x", "category": "pictures", "header": "FF", "footer": "FFD9", "entropy": "jpegBaseline"}"#.utf8))
        }
        #expect(throws: SignatureError.self) {
            try FileSignature(json: Data(#"{"schemaVersion": 1, "id": "x", "extension": "x", "category": "pictures", "header": "FF", "entropy": "zstd"}"#.utf8))
        }
    }
}

extension RecoveredFile {
    /// The carving signature id a carved file's name starts with.
    var signature: String { String(name.prefix { $0 != "-" }) }
}
