import Foundation
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

func gzipBytes(body: Int = 100) -> Data { Data([0x1F, 0x8B, 0x08, 0, 0, 0, 0, 0, 0, 3]) + filler(body) }

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
        let gzip = gzipBytes(body: 100), png = pngBytes()
        let files = try await carve(device(size: 64 * 1024, [(4096, gzip), (8192, png)]))
        #expect(files.map(\.name) == ["gzip-000000001000.gz", "png-000000002000.png"])
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
        #expect(files.count == 11)
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
        // A real untagged stream is still found.
        let stream = try await carve(device(size: 32 * 1024, [(4096, mp3Frames(10))]))
        #expect(stream.map(\.name) == ["mp3-000000001000.mp3"])
        #expect(stream.first?.bytes?.lowerBound == 4096 && stream.first?.isPartial == true)
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
