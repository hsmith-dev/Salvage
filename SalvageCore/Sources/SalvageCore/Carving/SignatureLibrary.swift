import Foundation

/// One declarative carving signature (AD-6), decoded from `Carving/Signatures/*.json`.
///
/// Adding a format is a data contribution: a JSON file with a required `schemaVersion` (1), `id`,
/// `extension`, `category` and `header`, plus optional termination rules. Fields the engine does
/// not know are ignored, never rejected, so independent contributors' additions can't break each
/// other. Hex strings may use `?` as a nibble wildcard (`"52494646????????57415645"` is
/// `RIFF....WAVE`).
///
/// Where a file ends is decided, in order of preference, by:
/// 1. `sizeField` — one or more length-prefixed fields read relative to the header start and
///    summed (each `value * scale + adjust`), e.g. RIFF, 7z, SQLite.
/// 2. `segments` — a chained walk over self-describing records (JPEG markers, ISO-BMFF boxes).
///    The walk ends at the first record that fails validation (the file ends there), or at a
///    `stopAt` record type, after which the `footer` search takes over (JPEG's scan data).
/// 3. `footer` — a byte pattern searched after the header; `footerMode` picks the first or the
///    last occurrence, `footerLength` / `footerSizeField` say how many bytes the footer record
///    spans (a ZIP end-of-central-directory record carries its own comment length).
/// 4. `structure` — a format walker built into the engine, for record layouts the declarative
///    `segments` walk can't express:
///    - `"gif"`: logical screen, color tables, extension and image blocks with their sub-blocks,
///      ended by the trailer at a block boundary;
///    - `"mp3"`: an optional ID3v2 tag, then consecutive MPEG audio frames of one stream, then an
///      optional APEv2 and/or ID3v1 trailer (see `MP3Walker`);
///    - `"ole2"`: the compound-file header, FAT (via the DIFAT) and first directory sector; the
///      file ends after the highest allocated sector (see `OLE2Walker`);
///    - `"gzip"`: the member header, the DEFLATE stream decoded to its final block, and the
///      CRC-32/ISIZE trailer (see `GzipWalker`).
/// 5. Otherwise the carve runs until `maxBytes`, the next header, a claimed run or the end of
///    the extent, and is reported as partial.
///
/// How a header found while another carve is open is treated: `embeds` lists the signature ids
/// that may legitimately sit inside this format (a JPEG thumbnail inside a JPEG's APP1, cover art
/// inside an MP4's boxes, MP3 frames inside an ID3-tagged MP3); `cutsOthers: false` marks a weak
/// header (MP3 frame sync, gzip) that never ends a carve that still has an end rule to find.
/// `validate` names a structural check run before a header counts as a match (`"mpegFrames"`:
/// two consecutive valid MPEG audio frame headers). `trustedMaxBytes` is the largest size a size
/// field or record walk may claim and still count as validated: larger claims usually mean a
/// fragmented file or a garbage field, so such carves are partial.
public struct FileSignature: Sendable, Equatable {
    public static let currentSchemaVersion = 1
    /// Most bytes past a candidate position any rule may read (header, size fields, record
    /// headers, footer records, validators). Larger values would make every chunk's carry window
    /// that large, so a signature exceeding it is skipped.
    public static let maxReach = 64 * 1024
    /// Largest `maxBytes` / `trustedMaxBytes` a signature may declare (64 GiB).
    public static let maxBytesCap: Int64 = 64 << 30

    public struct Pattern: Sendable, Equatable {
        public let bytes: [UInt8]
        /// Bit mask per byte; a `?` nibble clears its four mask bits.
        public let mask: [UInt8]
        public var count: Int { bytes.count }

        public func matches(_ data: Data, at index: Data.Index) -> Bool {
            guard index >= data.startIndex, data.endIndex - index >= bytes.count else { return false }
            for offset in 0..<bytes.count where (data[index + offset] & mask[offset]) != bytes[offset] { return false }
            return true
        }
    }

    public enum Endian: String, Sendable { case little, big }

    /// A length-prefixed field read relative to a record start: `value * scale + adjust`.
    public struct SizeField: Sendable, Equatable {
        public let offset: Int
        public let width: Int
        public let endian: Endian
        public let adjust: Int64
        /// Optional multiplier read from another field (SQLite's page size); nil means 1.
        public let scale: Scale?
        public struct Scale: Sendable, Equatable {
            public let offset: Int
            public let width: Int
            public let endian: Endian
            /// A raw value of 1 stands for this (SQLite stores 65536 as 1).
            public let oneMeans: Int64?
        }
        /// Bytes after the record start the field needs to be readable.
        var reach: Int { max(offset + width, scale.map { $0.offset + $0.width } ?? 0) }
    }

    public enum FooterMode: String, Sendable { case first, last }

    /// A chained walk over self-describing records starting `start` bytes into the file.
    public struct Segments: Sendable, Equatable {
        public let start: Int
        public let size: SizeField
        /// Smallest acceptable record total; anything smaller ends the walk.
        public let minimum: Int64
        /// Record type bytes checked before the record is accepted: `typeMatch` is a pattern,
        /// `typePrintable` requires printable ASCII (ISO-BMFF box types).
        public let typeOffset: Int
        public let typeLength: Int
        public let typeMatch: Pattern?
        public let typePrintable: Bool
        /// When the size field holds `ifValue`, the real size is a wider field at `offset` (ISO-BMFF
        /// `largesize`).
        public let largeSize: LargeSize?
        public struct LargeSize: Sendable, Equatable {
            public let ifValue: Int64
            public let offset: Int
            public let width: Int
        }
        /// Record types that hand over to the footer search (JPEG's start-of-scan).
        public let stopAt: [Pattern]
        /// A padding byte skipped before a record when the byte after it is the same value
        /// (JPEG allows any number of `FF` fill bytes before a marker).
        public let fillByte: UInt8?
        /// A record whose raw size field is 0 extends to the end of the file (ISO-BMFF). The walk
        /// then has no validated end: the carve runs to a limit and is partial.
        public let zeroSizeToEnd: Bool
        var reach: Int {
            var reach = max(size.reach, typeOffset + typeLength)
            if let largeSize { reach = max(reach, largeSize.offset + largeSize.width) }
            for pattern in stopAt { reach = max(reach, typeOffset + pattern.count) }
            if fillByte != nil { reach = max(reach, 2) }
            return reach
        }
    }

    /// Engine-built walkers for formats the declarative rules can't describe.
    public enum Structure: String, Sendable, CaseIterable { case gif, mp3, ole2, gzip }
    /// Engine-built header checks.
    public enum Validation: String, Sendable { case mpegFrames }

    public let id: String
    public let `extension`: String
    public let category: FileCategory
    public let headers: [Pattern]
    public let headerOffset: Int
    public let footer: Pattern?
    public let footerMode: FooterMode
    public let footerLength: Int
    public let footerSizeField: SizeField?
    public let maxBytes: Int64?
    public let sizeFields: [SizeField]
    public let segments: Segments?
    /// Fields read relative to a footer match whose sum must equal the footer's offset from the
    /// file start; a footer failing the check belongs to another (nested) file and is skipped.
    /// ZIP: central directory offset + size == offset of the end-of-central-directory record.
    public let footerOffsetCheck: [SizeField]
    public let structure: Structure?
    public let validation: Validation?
    /// Signature ids whose headers may legitimately appear inside this format.
    public let embeds: Set<String>
    /// False for weak headers that must not end a carve that still has an end rule to find.
    public let cutsOthers: Bool
    /// Largest size-field or record-walk size reported as validated; nil uses the engine default.
    public let trustedMaxBytes: Int64?

    /// Bytes from the header start the engine must see before it can evaluate a match.
    var headerReach: Int {
        var reach = headerOffset + (headers.map(\.count).max() ?? 0)
        for field in sizeFields { reach = max(reach, field.reach) }
        if let segments { reach = max(reach, segments.start + segments.reach) }
        switch structure {
        case .gif: reach = max(reach, 13)
        case .mp3: reach = max(reach, 10)
        case .ole2: reach = max(reach, OLE2Walker.headerBytes)
        case .gzip: reach = max(reach, 10)
        case nil: break
        }
        if validation == .mpegFrames { reach = max(reach, Self.mpegFramesReach) }
        return reach
    }

    /// Bytes from a footer match the engine must see before it can finish the file.
    var footerReach: Int {
        guard let footer else { return 0 }
        var reach = max(footer.count, footerLength, footerSizeField?.reach ?? 0)
        for field in footerOffsetCheck { reach = max(reach, field.reach) }
        return reach
    }

    /// Two MPEG audio frame headers: the longest frame (MPEG-2.5 Layer II, 160 kbps at 8 kHz,
    /// padded) is 2881 bytes, plus the second header.
    static let mpegFramesReach = 2881 + 4

    var hasKnownEnd: Bool { !sizeFields.isEmpty || segments != nil || footer != nil || structure != nil }
}

public enum SignatureError: Error, Sendable, Equatable, CustomStringConvertible {
    case notJSON(String)
    case missingField(String)
    case invalidField(String, String)
    case unsupportedSchemaVersion(Int)

    public var description: String {
        switch self {
        case .notJSON(let reason): "not a JSON object: \(reason)"
        case .missingField(let name): "missing required field '\(name)'"
        case .invalidField(let name, let reason): "invalid field '\(name)': \(reason)"
        case .unsupportedSchemaVersion(let version):
            "schemaVersion \(version) is not supported (engine supports \(FileSignature.currentSchemaVersion))"
        }
    }
}

/// The set of signatures the carving engine runs, with the files it refused and why.
public struct SignatureLibrary: Sendable {
    public struct Skipped: Sendable, Equatable {
        public let file: String
        public let reason: String
    }

    public let signatures: [FileSignature]
    public let skipped: [Skipped]

    public init(signatures: [FileSignature], skipped: [Skipped] = []) {
        self.signatures = signatures; self.skipped = skipped
    }

    static let resourceBundleName = "SalvageCore_SalvageCore.bundle"

    /// The signatures shipped in the package's `Carving/Signatures` resources, loaded once. Files
    /// that fail validation are listed in `skipped` and reported through `NSLog` so the reason is
    /// visible in the console, never silently dropped. A missing resource bundle gives an empty
    /// library with a skipped reason; it never traps (SwiftPM's generated `Bundle.module` calls
    /// `fatalError` when the bundle is absent, so it is not used).
    public static let bundled: SignatureLibrary = {
        let library = bundled(searching: resourceBundleCandidates())
        for skipped in library.skipped { NSLog("SalvageCore: skipped carving signature %@: %@", skipped.file, skipped.reason) }
        return library
    }()

    /// Loads the `Signatures` directory of the first `SalvageCore_SalvageCore.bundle` found in one
    /// of `directories`.
    static func bundled(searching directories: [URL]) -> SignatureLibrary {
        for directory in directories {
            let url = directory.appendingPathComponent(resourceBundleName)
            guard let bundle = Bundle(url: url) else { continue }
            if let signatures = bundle.url(forResource: "Signatures", withExtension: nil) { return load(directory: signatures) }
            let flat = url.appendingPathComponent("Signatures")
            if FileManager.default.fileExists(atPath: flat.path) { return load(directory: flat) }
        }
        return SignatureLibrary(signatures: [], skipped: [Skipped(
            file: "Signatures", reason: "resource bundle \(resourceBundleName) not found; carving is disabled")])
    }

    /// Where SwiftPM places a package's resource bundle: beside an app's resources, a framework's
    /// or test bundle's resources, or a command-line tool.
    static func resourceBundleCandidates() -> [URL] {
        var candidates: [URL?] = []
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["PACKAGE_RESOURCE_BUNDLE_PATH"] {
            candidates.append(URL(fileURLWithPath: path).deletingLastPathComponent())
        }
        #endif
        let own = Bundle(for: BundleToken.self)
        candidates += [Bundle.main.resourceURL, own.resourceURL, Bundle.main.bundleURL,
                       own.bundleURL.deletingLastPathComponent()]
        return candidates.compactMap { $0 }
    }
}

private final class BundleToken {}

extension SignatureLibrary {
    /// Loads every `*.json` file in `directory`, in name order.
    public static func load(directory: URL) -> SignatureLibrary {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let files = names.filter { $0.lowercased().hasSuffix(".json") }.sorted().map { directory.appendingPathComponent($0) }
        return load(files: files)
    }

    public static func load(files: [URL]) -> SignatureLibrary {
        var signatures: [FileSignature] = [], skipped: [Skipped] = []
        for url in files {
            do {
                signatures.append(try FileSignature(json: try Data(contentsOf: url)))
            } catch let error as SignatureError {
                skipped.append(Skipped(file: url.lastPathComponent, reason: error.description))
            } catch {
                skipped.append(Skipped(file: url.lastPathComponent, reason: error.localizedDescription))
            }
        }
        return SignatureLibrary(signatures: signatures, skipped: skipped)
    }
}

// MARK: - Decoding

extension FileSignature {
    /// Decodes one signature file. Required fields and hex are validated strictly; unknown keys
    /// anywhere are ignored (AD-6).
    public init(json data: Data) throws {
        let object: Any
        do { object = try JSONSerialization.jsonObject(with: data) } catch { throw SignatureError.notJSON(error.localizedDescription) }
        guard let fields = object as? [String: Any] else { throw SignatureError.notJSON("top level is not an object") }
        let decoder = FieldDecoder(fields, path: "")

        let version = try decoder.int("schemaVersion")
        guard version == Self.currentSchemaVersion else { throw SignatureError.unsupportedSchemaVersion(version) }

        id = try decoder.identifier("id")
        `extension` = try decoder.identifier("extension")
        let categoryName = try decoder.string("category")
        guard let category = FileCategory(rawValue: categoryName) else {
            throw SignatureError.invalidField("category", "must be one of \(FileCategory.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        self.category = category

        var headers = [try decoder.pattern("header")]
        for (index, hex) in try decoder.optionalStringArray("alternateHeaders").enumerated() {
            headers.append(try Pattern(hex: hex, field: "alternateHeaders[\(index)]"))
        }
        guard headers.allSatisfy({ $0.count > 0 }) else { throw SignatureError.invalidField("header", "must not be empty") }
        self.headers = headers
        headerOffset = try decoder.optionalInt("headerOffset", default: 0, minimum: 0)

        footer = try decoder.optionalPattern("footer")
        if let footer, footer.count == 0 { throw SignatureError.invalidField("footer", "must not be empty") }
        let footerModeName = try decoder.optionalString("footerMode") ?? FooterMode.first.rawValue
        guard let footerMode = FooterMode(rawValue: footerModeName) else {
            throw SignatureError.invalidField("footerMode", "must be 'first' or 'last'")
        }
        self.footerMode = footerMode
        footerLength = try decoder.optionalInt("footerLength", default: footer?.count ?? 0, minimum: footer?.count ?? 0)
        footerSizeField = try decoder.fields["footerSizeField"].map { try SizeField(any: $0, field: "footerSizeField") }
        if footer == nil, footerSizeField != nil || decoder.fields["footerLength"] != nil || decoder.fields["footerMode"] != nil {
            throw SignatureError.invalidField("footer", "footerLength, footerMode and footerSizeField need a footer")
        }

        if let maxBytes = try decoder.optionalInt64("maxBytes") {
            guard maxBytes > 0 else { throw SignatureError.invalidField("maxBytes", "must be positive") }
            guard maxBytes <= Self.maxBytesCap else { throw SignatureError.invalidField("maxBytes", "must be at most \(Self.maxBytesCap)") }
            self.maxBytes = maxBytes
        } else {
            maxBytes = nil
        }
        if let trusted = try decoder.optionalInt64("trustedMaxBytes") {
            guard trusted > 0, trusted <= Self.maxBytesCap else {
                throw SignatureError.invalidField("trustedMaxBytes", "must be 1...\(Self.maxBytesCap)")
            }
            trustedMaxBytes = trusted
        } else {
            trustedMaxBytes = nil
        }
        embeds = Set(try decoder.optionalStringArray("embeds"))
        cutsOthers = try decoder.optionalBool("cutsOthers") ?? true
        if let name = try decoder.optionalString("structure") {
            guard let structure = Structure(rawValue: name) else {
                throw SignatureError.invalidField("structure", "must be one of \(Structure.allCases.map { "'\($0.rawValue)'" }.joined(separator: ", "))")
            }
            self.structure = structure
        } else {
            structure = nil
        }
        if let name = try decoder.optionalString("validate") {
            guard let validation = Validation(rawValue: name) else { throw SignatureError.invalidField("validate", "must be 'mpegFrames'") }
            self.validation = validation
        } else {
            validation = nil
        }
        if let raw = decoder.fields["footerOffsetCheck"] {
            guard let list = raw as? [Any], !list.isEmpty else { throw SignatureError.invalidField("footerOffsetCheck", "must be a non-empty array") }
            footerOffsetCheck = try list.enumerated().map { try SizeField(any: $1, field: "footerOffsetCheck[\($0)]") }
            guard footer != nil else { throw SignatureError.invalidField("footer", "footerOffsetCheck needs a footer") }
        } else {
            footerOffsetCheck = []
        }

        if let raw = decoder.fields["sizeField"] {
            if let list = raw as? [Any] {
                sizeFields = try list.enumerated().map { try SizeField(any: $1, field: "sizeField[\($0)]") }
                guard !sizeFields.isEmpty else { throw SignatureError.invalidField("sizeField", "must not be empty") }
            } else {
                sizeFields = [try SizeField(any: raw, field: "sizeField")]
            }
        } else {
            sizeFields = []
        }

        if let raw = decoder.fields["segments"] {
            guard let object = raw as? [String: Any] else { throw SignatureError.invalidField("segments", "must be an object") }
            segments = try Segments(FieldDecoder(object, path: "segments."))
        } else {
            segments = nil
        }
        if !sizeFields.isEmpty, segments != nil {
            throw SignatureError.invalidField("segments", "cannot be combined with sizeField")
        }
        if structure != nil, !sizeFields.isEmpty || segments != nil || footer != nil {
            throw SignatureError.invalidField("structure", "cannot be combined with sizeField, segments or footer")
        }
        let reach = max(headerReach, footerReach)
        guard reach <= Self.maxReach else {
            throw SignatureError.invalidField("reach", "rules read \(reach) bytes past a match; the cap is \(Self.maxReach)")
        }
    }
}

extension FileSignature.Pattern {
    /// Hex with optional `?` nibble wildcards; whitespace is allowed between bytes.
    init(hex: String, field: String) throws {
        let cleaned = hex.filter { !$0.isWhitespace }
        guard cleaned.count % 2 == 0 else { throw SignatureError.invalidField(field, "hex must have an even number of digits") }
        var bytes: [UInt8] = [], mask: [UInt8] = []
        var iterator = cleaned.makeIterator()
        while let high = iterator.next(), let low = iterator.next() {
            var byte: UInt8 = 0, maskByte: UInt8 = 0
            for (nibble, shift) in [(high, 4), (low, 0)] as [(Character, Int)] {
                if nibble == "?" { continue }
                guard let value = nibble.hexDigitValue else { throw SignatureError.invalidField(field, "'\(nibble)' is not a hex digit") }
                byte |= UInt8(value) << shift; maskByte |= 0xF << shift
            }
            bytes.append(byte); mask.append(maskByte)
        }
        self.init(bytes: bytes, mask: mask)
    }
}

extension FileSignature.SizeField {
    init(any raw: Any, field: String) throws {
        guard let object = raw as? [String: Any] else { throw SignatureError.invalidField(field, "must be an object") }
        try self.init(FieldDecoder(object, path: field + "."))
    }

    init(_ decoder: FieldDecoder) throws {
        offset = try decoder.int("offset", minimum: 0)
        width = try decoder.int("width", minimum: 1)
        guard width <= 8 else { throw SignatureError.invalidField(decoder.path + "width", "must be 1...8") }
        endian = try decoder.endian("endian")
        adjust = try decoder.optionalInt64("adjust") ?? 0
        if let raw = decoder.fields["scale"] {
            guard let object = raw as? [String: Any] else { throw SignatureError.invalidField(decoder.path + "scale", "must be an object") }
            let scale = FieldDecoder(object, path: decoder.path + "scale.")
            let width = try scale.int("width", minimum: 1)
            guard width <= 8 else { throw SignatureError.invalidField(scale.path + "width", "must be 1...8") }
            self.scale = Scale(offset: try scale.int("offset", minimum: 0), width: width, endian: try scale.endian("endian"),
                               oneMeans: try scale.optionalInt64("oneMeans"))
        } else {
            scale = nil
        }
    }
}

extension FileSignature.Segments {
    init(_ decoder: FieldDecoder) throws {
        start = try decoder.optionalInt("start", default: 0, minimum: 0)
        guard let raw = decoder.fields["size"] else { throw SignatureError.missingField(decoder.path + "size") }
        size = try FileSignature.SizeField(any: raw, field: decoder.path + "size")
        minimum = try decoder.optionalInt64("minimum") ?? 1
        guard minimum >= 1 else { throw SignatureError.invalidField(decoder.path + "minimum", "must be positive") }
        typeOffset = try decoder.optionalInt("typeOffset", default: 0, minimum: 0)
        typeLength = try decoder.optionalInt("typeLength", default: 0, minimum: 0)
        typeMatch = try decoder.optionalPattern("typeMatch")
        typePrintable = try decoder.optionalBool("typePrintable") ?? false
        if typePrintable, typeLength == 0 { throw SignatureError.invalidField(decoder.path + "typePrintable", "needs typeLength") }
        if let raw = decoder.fields["largeSize"] {
            guard let object = raw as? [String: Any] else { throw SignatureError.invalidField(decoder.path + "largeSize", "must be an object") }
            let large = FieldDecoder(object, path: decoder.path + "largeSize.")
            let width = try large.int("width", minimum: 1)
            guard width <= 8 else { throw SignatureError.invalidField(large.path + "width", "must be 1...8") }
            largeSize = LargeSize(ifValue: try large.int64("ifValue"), offset: try large.int("offset", minimum: 0), width: width)
        } else {
            largeSize = nil
        }
        stopAt = try decoder.optionalStringArray("stopAt").enumerated().map {
            try FileSignature.Pattern(hex: $1, field: decoder.path + "stopAt[\($0)]")
        }
        guard stopAt.allSatisfy({ $0.count > 0 }) else { throw SignatureError.invalidField(decoder.path + "stopAt", "patterns must not be empty") }
        if let fill = try decoder.optionalPattern("fillByte") {
            guard fill.count == 1, fill.mask == [0xFF] else { throw SignatureError.invalidField(decoder.path + "fillByte", "must be one hex byte") }
            fillByte = fill.bytes[0]
        } else {
            fillByte = nil
        }
        zeroSizeToEnd = try decoder.optionalBool("zeroSizeToEnd") ?? false
    }
}

/// Typed access to one JSON object's known fields; unknown keys are never looked at, and a key
/// set to `null` counts as absent.
struct FieldDecoder {
    let fields: [String: Any]
    let path: String
    init(_ fields: [String: Any], path: String) { self.fields = fields.filter { !($0.value is NSNull) }; self.path = path }

    func string(_ name: String) throws -> String {
        guard let raw = fields[name] else { throw SignatureError.missingField(path + name) }
        guard let value = raw as? String, !value.isEmpty else { throw SignatureError.invalidField(path + name, "must be a non-empty string") }
        return value
    }

    func optionalString(_ name: String) throws -> String? {
        guard let raw = fields[name] else { return nil }
        guard let value = raw as? String else { throw SignatureError.invalidField(path + name, "must be a string") }
        return value
    }

    /// A short token safe to use in a generated file name: letters, digits, `-`, `_`.
    func identifier(_ name: String) throws -> String {
        let value = try string(name)
        guard value.count <= 32, value.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_") }) else {
            throw SignatureError.invalidField(path + name, "must be 1-32 ASCII letters, digits, '-' or '_'")
        }
        return value
    }

    func int64(_ name: String) throws -> Int64 {
        guard let raw = fields[name] else { throw SignatureError.missingField(path + name) }
        guard let value = Self.integer(raw) else { throw SignatureError.invalidField(path + name, "must be an integer") }
        return value
    }

    func optionalInt64(_ name: String) throws -> Int64? {
        guard let raw = fields[name] else { return nil }
        guard let value = Self.integer(raw) else { throw SignatureError.invalidField(path + name, "must be an integer") }
        return value
    }

    func int(_ name: String, minimum: Int = Int.min) throws -> Int {
        let value = try int64(name)
        guard value >= Int64(minimum), value <= Int64(Int32.max) else {
            throw SignatureError.invalidField(path + name, minimum == Int.min ? "out of range" : "must be at least \(minimum)")
        }
        return Int(value)
    }

    func optionalInt(_ name: String, default fallback: Int, minimum: Int) throws -> Int {
        guard fields[name] != nil else { return fallback }
        return try int(name, minimum: minimum)
    }

    func optionalBool(_ name: String) throws -> Bool? {
        guard let raw = fields[name] else { return nil }
        guard let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw SignatureError.invalidField(path + name, "must be true or false")
        }
        return number.boolValue
    }

    func pattern(_ name: String) throws -> FileSignature.Pattern {
        try FileSignature.Pattern(hex: try string(name), field: path + name)
    }

    func optionalPattern(_ name: String) throws -> FileSignature.Pattern? {
        guard let hex = try optionalString(name) else { return nil }
        return try FileSignature.Pattern(hex: hex, field: path + name)
    }

    func optionalStringArray(_ name: String) throws -> [String] {
        guard let raw = fields[name] else { return [] }
        guard let list = raw as? [String] else { throw SignatureError.invalidField(path + name, "must be an array of strings") }
        return list
    }

    func endian(_ name: String) throws -> FileSignature.Endian {
        let value = try optionalString(name) ?? FileSignature.Endian.little.rawValue
        guard let endian = FileSignature.Endian(rawValue: value) else { throw SignatureError.invalidField(path + name, "must be 'little' or 'big'") }
        return endian
    }

    /// JSON numbers arrive as NSNumber; only whole values within Int64 count as integers (a
    /// boolean is an NSNumber too, and is refused here).
    static func integer(_ raw: Any) -> Int64? {
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double == double.rounded(), abs(double) < 9.2e18 else { return nil }
        return number.int64Value
    }
}
