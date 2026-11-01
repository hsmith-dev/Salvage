import Foundation
import Testing
@testable import SalvageCore

@Suite("Carving signature library (AD-6)")
struct SignatureLibraryTests {
    func signature(_ json: String) throws -> FileSignature { try FileSignature(json: Data(json.utf8)) }
    func error(_ json: String) -> SignatureError? {
        do { _ = try signature(json); return nil } catch let error as SignatureError { return error } catch { return nil }
    }

    @Test func bundledSignaturesAllLoadAndMatchTheirCategories() {
        let library = SignatureLibrary.bundled
        #expect(library.skipped.isEmpty, Comment(rawValue: "\(library.skipped)"))
        let ids = Set(library.signatures.map(\.id))
        for id in ["jpeg", "png", "gif", "heic", "mp4", "mov", "m4a", "mp3", "wav", "avi", "pdf", "zip", "gzip", "7z", "rar", "rar5", "sqlite", "ole"] {
            #expect(ids.contains(id), Comment(rawValue: id))
        }
        #expect(library.signatures.count == 19)
        for signature in library.signatures {
            // The folder a carved file lands in must agree with the bucket its extension gives it.
            #expect(FileCategory.classify(fileName: "x.\(signature.extension)") == signature.category, Comment(rawValue: signature.id))
            #expect(signature.headerReach <= FileSignature.maxReach && signature.footerReach <= FileSignature.maxReach, Comment(rawValue: signature.id))
            #expect(signature.maxBytes ?? 1 > 0, Comment(rawValue: signature.id))
        }
        #expect(library.signatures.filter { !$0.hasKnownEnd }.map(\.id).sorted() == ["gzip", "mp3", "mp3", "ole", "rar5"])
        // Review fixes: weak headers, embedding, structural checks and trusted sizes.
        #expect(library.signatures.filter { !$0.cutsOthers }.map(\.id).sorted() == ["gzip", "mp3"])
        #expect(library.signatures.first { $0.id == "jpeg" }?.embeds == ["jpeg"])
        #expect(library.signatures.first { $0.id == "gif" }?.structure == .gif)
        #expect(library.signatures.first { $0.id == "gif" }?.footer == nil)
        #expect(library.signatures.filter { $0.validation == .mpegFrames }.count == 1)
        for id in ["mp4", "mov", "m4a", "heic", "wav", "avi"] {
            #expect(library.signatures.first { $0.id == id }?.trustedMaxBytes == 64 << 20, Comment(rawValue: id))
        }
    }

    @Test func reachAndSizeBoundsAreCappedWithAReason() throws {
        let base = """
        {"schemaVersion": 1, "id": "x", "extension": "x", "category": "other", "header": "AABB"}
        """
        func with(_ field: String) -> String { base.replacingOccurrences(of: "\"header\"", with: field + ", \"header\"") }
        #expect(error(with("\"headerOffset\": 2000000"))?.description.contains("cap is 65536") == true)
        #expect(error(with("\"sizeField\": {\"offset\": 2000000, \"width\": 4}")) != nil)
        #expect(error(with("\"footer\": \"CC\", \"footerSizeField\": {\"offset\": 70000, \"width\": 2}")) != nil)
        #expect(error(with("\"headerOffset\": 60000")) == nil)
        #expect(error(with("\"maxBytes\": 68719476737")) == .invalidField("maxBytes", "must be at most 68719476736"))
        #expect(error(with("\"maxBytes\": 68719476736")) == nil)
        #expect(error(with("\"trustedMaxBytes\": 0")) != nil)
        #expect(error(with("\"structure\": \"png\"")) == .invalidField("structure", "must be 'gif'"))
        #expect(error(with("\"validate\": \"crc\"")) == .invalidField("validate", "must be 'mpegFrames'"))
        #expect(error(with("\"cutsOthers\": \"no\"")) == .invalidField("cutsOthers", "must be true or false"))
        #expect(error(with("\"structure\": \"gif\", \"footer\": \"3B\"")) != nil)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("salvage-signatures-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(with("\"headerOffset\": 2000000").utf8).write(to: directory.appendingPathComponent("far.json"))
        try Data(base.utf8).write(to: directory.appendingPathComponent("ok.json"))
        let library = SignatureLibrary.load(directory: directory)
        #expect(library.signatures.map(\.id) == ["x"])
        #expect(library.skipped.map(\.file) == ["far.json"])
        #expect(library.skipped.first?.reason.contains("2000002 bytes") == true)
    }

    @Test func missingResourceBundleGivesAnEmptyLibraryWithAReason() {
        let nowhere = FileManager.default.temporaryDirectory.appendingPathComponent("salvage-no-bundle-\(UUID().uuidString)")
        let library = SignatureLibrary.bundled(searching: [nowhere])
        #expect(library.signatures.isEmpty)
        #expect(library.skipped.count == 1 && library.skipped.first?.reason.contains("not found") == true)
        // The real lookup finds the package's bundle.
        #expect(SignatureLibrary.bundled(searching: SignatureLibrary.resourceBundleCandidates()).signatures.count == 19)
    }

    @Test func wrongSchemaVersionIsSkippedWithAReason() throws {
        let json = """
        {"schemaVersion": 2, "id": "x", "extension": "x", "category": "other", "header": "AA"}
        """
        #expect(error(json) == .unsupportedSchemaVersion(2))
        #expect(error(json)?.description.contains("schemaVersion 2") == true)
        #expect(error(json.replacingOccurrences(of: "\"schemaVersion\": 2, ", with: "")) == .missingField("schemaVersion"))
        #expect(error(json.replacingOccurrences(of: "2,", with: "\"1\",")) == .invalidField("schemaVersion", "must be an integer"))

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("salvage-signatures-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(json.utf8).write(to: directory.appendingPathComponent("future.json"))
        try Data("not json".utf8).write(to: directory.appendingPathComponent("broken.json"))
        try Data("[1]".utf8).write(to: directory.appendingPathComponent("array.json"))
        try Data(json.replacingOccurrences(of: "2", with: "1").utf8).write(to: directory.appendingPathComponent("ok.json"))
        try Data("ignored".utf8).write(to: directory.appendingPathComponent("readme.txt"))
        let library = SignatureLibrary.load(directory: directory)
        #expect(library.signatures.map(\.id) == ["x"])
        #expect(library.skipped.map(\.file) == ["array.json", "broken.json", "future.json"])
        #expect(library.skipped.last?.reason.contains("schemaVersion 2") == true)
        #expect(library.skipped.first?.reason.contains("not a JSON object") == true)
    }

    @Test func unknownFieldsAreIgnoredEverywhere() throws {
        let decoded = try signature("""
        {"schemaVersion": 1, "id": "jpeg", "extension": "jpg", "category": "pictures", "header": "FFD8FF",
         "footer": "FFD9", "footerBytes": "ignored", "maxFragments": 3, "author": {"name": "someone"},
         "sizeField": {"offset": 4, "width": 4, "endian": "little", "adjust": 8, "unit": "bytes"},
         "segments": null, "notes": ["a", "b"]}
        """)
        #expect(decoded.id == "jpeg" && decoded.extension == "jpg" && decoded.category == .pictures)
        #expect(decoded.headers.first?.bytes == [0xFF, 0xD8, 0xFF])
        #expect(decoded.footer?.bytes == [0xFF, 0xD9] && decoded.footerLength == 2 && decoded.footerMode == .first)
        #expect(decoded.sizeFields == [FileSignature.SizeField(offset: 4, width: 4, endian: .little, adjust: 8, scale: nil)])
        #expect(decoded.segments == nil && decoded.maxBytes == nil)
    }

    @Test func requiredFieldsAndHexAreValidatedStrictly() {
        let base = """
        {"schemaVersion": 1, "id": "x", "extension": "x", "category": "other", "header": "AABB"}
        """
        for field in ["id", "extension", "category", "header"] {
            let json = base.replacingOccurrences(of: "\"\(field)\"", with: "\"_\(field)\"")
            #expect(error(json) == .missingField(field), Comment(rawValue: field))
        }
        #expect(error(base.replacingOccurrences(of: "AABB", with: "AABBC")) == .invalidField("header", "hex must have an even number of digits"))
        #expect(error(base.replacingOccurrences(of: "AABB", with: "AAGG")) == .invalidField("header", "'G' is not a hex digit"))
        #expect(error(base.replacingOccurrences(of: "AABB", with: "")) == .invalidField("header", "must be a non-empty string"))
        #expect(error(base.replacingOccurrences(of: "\"other\"", with: "\"images\""))?.description.contains("invalid field 'category'") == true)
        #expect(error(base.replacingOccurrences(of: "\"x\", \"extension\"", with: "\"a b\", \"extension\"")) != nil)
        #expect(error(base.replacingOccurrences(of: "\"header\"", with: "\"footerLength\": 4, \"header\"")) == .invalidField("footer", "footerLength, footerMode and footerSizeField need a footer"))
        #expect(error(base.replacingOccurrences(of: "\"header\"", with: "\"maxBytes\": 0, \"header\"")) == .invalidField("maxBytes", "must be positive"))
        #expect(error(base.replacingOccurrences(of: "\"header\"", with: "\"maxBytes\": true, \"header\"")) == .invalidField("maxBytes", "must be an integer"))
        #expect(error(base.replacingOccurrences(of: "\"header\"", with: "\"sizeField\": {\"offset\": 0, \"width\": 9}, \"header\"")) == .invalidField("sizeField.width", "must be 1...8"))
        #expect(error(base.replacingOccurrences(of: "\"header\"", with: "\"sizeField\": {\"offset\": -1, \"width\": 2}, \"header\"")) == .invalidField("sizeField.offset", "must be at least 0"))
        #expect(error(base.replacingOccurrences(of: "\"header\"", with: "\"sizeField\": {\"offset\": 0, \"width\": 2, \"endian\": \"middle\"}, \"header\"")) == .invalidField("sizeField.endian", "must be 'little' or 'big'"))
        #expect(error(base.replacingOccurrences(of: "\"header\"", with: "\"segments\": {\"start\": 0}, \"header\"")) == .missingField("segments.size"))
        #expect(error(base.replacingOccurrences(of: "\"header\"", with: "\"alternateHeaders\": [\"ZZ\"], \"header\"")) == .invalidField("alternateHeaders[0]", "'Z' is not a hex digit"))
        #expect(error(base.replacingOccurrences(of: "\"header\"", with: "\"footer\": \"\", \"header\"")) == .invalidField("footer", "must not be empty"))
        #expect(error("[]") == .notJSON("top level is not an object"))
        #expect(error("{") != nil)
    }

    @Test func wildcardNibblesMatchAnyValue() throws {
        let pattern = try FileSignature.Pattern(hex: "52 49 ?? 4? ?F", field: "header")
        #expect(pattern.bytes == [0x52, 0x49, 0x00, 0x40, 0x0F])
        #expect(pattern.mask == [0xFF, 0xFF, 0x00, 0xF0, 0x0F])
        #expect(pattern.matches(Data([0x52, 0x49, 0x99, 0x4A, 0xCF]), at: 0))
        #expect(!pattern.matches(Data([0x52, 0x49, 0x99, 0x5A, 0xCF]), at: 0))
        #expect(!pattern.matches(Data([0x52, 0x49, 0x99, 0x4A]), at: 0))
        let riff = try signature("""
        {"schemaVersion": 1, "id": "wav", "extension": "wav", "category": "audio", "header": "52494646????????57415645"}
        """)
        #expect(riff.headerReach == 12)
        #expect(riff.headers[0].matches(wavBytes(), at: 0))
    }

    @Test func reachCoversEveryFieldTheEngineMustRead() throws {
        let seven = try signature("""
        {"schemaVersion": 1, "id": "7z", "extension": "7z", "category": "archives", "header": "377ABCAF271C",
         "sizeField": [{"offset": 12, "width": 8, "adjust": 32}, {"offset": 20, "width": 8}]}
        """)
        #expect(seven.headerReach == 28)
        let zip = try signature("""
        {"schemaVersion": 1, "id": "zip", "extension": "zip", "category": "archives", "header": "504B0304",
         "footer": "504B0506", "footerSizeField": {"offset": 20, "width": 2, "adjust": 22}}
        """)
        #expect(zip.footerReach == 22 && zip.footerLength == 4)
        let mp4 = try signature("""
        {"schemaVersion": 1, "id": "mp4", "extension": "mp4", "category": "videos", "headerOffset": 4, "header": "66747970",
         "segments": {"size": {"offset": 0, "width": 4, "endian": "big"}, "minimum": 8, "typeOffset": 4, "typeLength": 4,
                      "typePrintable": true, "largeSize": {"ifValue": 1, "offset": 8, "width": 8}}}
        """)
        #expect(mp4.segments?.reach == 16 && mp4.headerReach == 16)
    }
}
