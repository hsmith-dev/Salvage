import Foundation
import Testing
@testable import SalvageCore

// MARK: - Synthetic file builders

private func be32(_ value: Int) -> Data { Data([UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]) }
private func le32(_ value: Int) -> Data { Data([UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 24 & 0xFF)]) }
private func le64(_ value: Int) -> Data { le32(value & 0xFFFF_FFFF) + le32(value >> 32) }
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

func zipBytes(comment: String = "") -> Data {
    let name = ascii("a.txt"), content = ascii("hello")
    var data = ascii("PK") + Data([3, 4]) + Data(repeating: 0, count: 22) + Data([UInt8(name.count), 0, 0, 0]) + name + content
    data += ascii("PK") + Data([1, 2]) + Data(repeating: 0, count: 42) + name
    data += ascii("PK") + Data([5, 6]) + Data(repeating: 0, count: 16) + Data([UInt8(comment.utf8.count), 0]) + ascii(comment)
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
func carve(_ image: Data, chunk: Int = 1 << 20, claimed: [DataRun] = [], library: SignatureLibrary = .bundled,
           limits: SignatureCarver.Limits = .default, extents: [Range<Int>]? = nil) async throws -> [RecoveredFile] {
    let collector = Collector()
    let carver = SignatureCarver(emit: { await collector.add($0) }, library: library, limits: limits)
    try await carver.begin(claimed: claimed, deviceSizeBytes: Int64(image.count))
    for extent in extents ?? [0..<image.count] {
        var offset = extent.lowerBound
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
        // A sector-aligned JPEG header inside mdat is media data, not a new file.
        var mp4 = mp4Bytes(mediaBytes: 6000)
        mp4.replaceSubrange(4096 - 1024..<4096 - 1024 + 3, with: Data([0xFF, 0xD8, 0xFF]))
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
        let carver = SignatureCarver(emit: { await collector.add($0) }, library: .bundled, limits: limits)
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
