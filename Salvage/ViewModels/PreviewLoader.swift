import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import SalvageCore

/// Why a file has no rendered preview. Each case carries the user-facing reason.
enum PreviewUnavailableReason: Error, Sendable, Equatable {
    /// Not an image, PDF or decodable text (raw bytes may still be offered).
    case unsupportedFormat
    /// The scan couldn't map where the file's bytes live, so they can't be read or recovered.
    case unmapped
    /// Bigger than the in-memory preview cap for its format.
    case tooLarge
    /// The device read failed, or there is no open device session.
    case deviceUnreadable
    /// The file has no bytes.
    case empty

    var message: String {
        switch self {
        case .unsupportedFormat: "This file type can't be previewed."
        case .unmapped: "This file's contents couldn't be located on the device, so it can't be recovered."
        case .tooLarge: "This file is too large to preview."
        case .deviceUnreadable: "The device couldn't be read."
        case .empty: "This file is empty."
        }
    }
}

/// The format a preview is rendered as.
enum PreviewFormat: Sendable, Equatable {
    case image, pdf, text, unknown

    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "jpe", "gif", "tif", "tiff", "bmp", "heic", "heif", "webp", "ico", "icns",
    ]
    private static let textExtensions: Set<String> = [
        "txt", "text", "md", "markdown", "csv", "tsv", "log", "json", "xml", "yaml", "yml", "ini", "cfg",
        "conf", "rtf", "html", "htm", "css", "js", "ts", "swift", "c", "h", "m", "cpp", "py", "rb", "sh",
        "srt", "vtt", "plist",
    ]

    /// Magic bytes first; the file extension only when the header is not recognised.
    static func detect(header: Data, name: String) -> PreviewFormat {
        let bytes = [UInt8](header.prefix(32))
        func starts(_ magic: [UInt8], at offset: Int = 0) -> Bool {
            bytes.count >= offset + magic.count && Array(bytes[offset..<offset + magic.count]) == magic
        }
        if starts([0x25, 0x50, 0x44, 0x46, 0x2D]) { return .pdf }                       // %PDF-
        if starts([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])                      // PNG
            || starts([0xFF, 0xD8, 0xFF])                                                  // JPEG
            || starts(Array("GIF87a".utf8)) || starts(Array("GIF89a".utf8))
            || starts([0x49, 0x49, 0x2A, 0x00]) || starts([0x4D, 0x4D, 0x00, 0x2A])        // TIFF
            || isPlausibleBMP(bytes)                                                       // BMP
            || (starts(Array("RIFF".utf8)) && starts(Array("WEBP".utf8), at: 8))
            || (starts(Array("ftyp".utf8), at: 4)
                && ["heic", "heix", "hevc", "mif1", "msf1", "avif"].contains { starts(Array($0.utf8), at: 8) }) {
            return .image
        }
        let ext = (name as NSString).pathExtension.lowercased()
        if ext == "pdf" { return .pdf }
        if imageExtensions.contains(ext) { return .image }
        if textExtensions.contains(ext) { return .text }
        return .unknown
    }
}

extension PreviewFormat {
    /// "BM" alone is too weak (a CSV can start "BMI,"), so the BITMAPFILEHEADER and the size of
    /// the DIB header after it must be sane: a known DIB header size, a pixel-data offset past
    /// both headers, and a file-size field (when set) that is not smaller than that offset.
    static func isPlausibleBMP(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 18, bytes[0] == 0x42, bytes[1] == 0x4D else { return false }
        func le32(_ offset: Int) -> UInt32 {
            (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << (8 * UInt32($1)) }
        }
        let fileSize = le32(2), pixelOffset = le32(10), dibSize = le32(14)
        let knownDIBSizes: Set<UInt32> = [12, 16, 40, 52, 56, 64, 108, 124]
        guard knownDIBSizes.contains(dibSize) else { return false }
        guard pixelOffset >= 14 + dibSize else { return false }
        // Some writers leave the size field 0; otherwise it must hold the headers.
        return fileSize == 0 || fileSize >= pixelOffset
    }
}

/// Wraps decoded values that are immutable once produced, so they can cross from the loader to
/// the main actor.
struct PreviewImage: @unchecked Sendable {
    let cgImage: CGImage
}

struct PreviewPDF: @unchecked Sendable {
    let document: PDFDocument
}

enum PreviewResult: Sendable {
    case image(PreviewImage)
    case pdf(PreviewPDF)
    /// `truncated` when only the first `textCap` bytes were read.
    case text(String, truncated: Bool)
    /// No rendered preview; `rawBytes` is a hex dump of the first 4 KiB when one could be read.
    case unavailable(PreviewUnavailableReason, rawBytes: String?)

    var unavailableReason: PreviewUnavailableReason? {
        if case .unavailable(let reason, _) = self { return reason }
        return nil
    }
}

/// Reads a bounded prefix of a discovered file in memory and turns it into something the
/// preview pane can render. Never writes to disk. Bytes are untrusted: only ImageIO and PDFKit
/// decode them.
struct PreviewLoader: Sendable {
    typealias PrefixReader = @Sendable (RecoveredFile, Int64) async throws -> Data

    static let imageCap: Int64 = 32 * 1024 * 1024
    static let pdfCap: Int64 = 32 * 1024 * 1024
    static let textCap: Int64 = 1024 * 1024
    static let rawBytesCap: Int64 = 4 * 1024
    static let maxImageDimension = 2048
    /// Refuse to decode images whose declared size would need an outsized decode buffer.
    static let maxImagePixels = 100_000_000

    private let readPrefix: PrefixReader?

    /// `readPrefix` returns up to `limit` bytes from the file's start; nil means no device.
    init(readPrefix: PrefixReader?) { self.readPrefix = readPrefix }

    init(source: SourceSession?) {
        if let content = source?.content {
            self.init { file, limit in try await content.prefix(of: file, limit: limit) }
        } else {
            self.init(readPrefix: nil)
        }
    }

    /// Runs off the main actor. Throws only `CancellationError`.
    func load(_ file: RecoveredFile) async throws -> PreviewResult {
        if case .unmapped = file.content { return .unavailable(.unmapped, rawBytes: nil) }
        guard let readPrefix else { return .unavailable(.deviceUnreadable, rawBytes: nil) }
        if file.sizeBytes <= 0 { return .unavailable(.empty, rawBytes: nil) }

        func read(_ limit: Int64) async throws -> Data? {
            let expected = min(limit, file.sizeBytes)
            do {
                let data = try await readPrefix(file, expected)
                try Task.checkCancellation()
                // A cancelled stream ends early without an error; never treat that as content.
                return Int64(data.count) == expected ? data : nil
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as FileContentError {
                if Task.isCancelled { throw CancellationError() }
                switch error {
                case .unmapped, .runsShorterThanFile, .runOutsideDevice, .locked, .decryptionFailed: throw Unavailable(reason: .unmapped)
                }
            } catch {
                if Task.isCancelled { throw CancellationError() }
                return nil
            }
        }

        do {
            guard let header = try await read(Self.rawBytesCap) else {
                return .unavailable(.deviceUnreadable, rawBytes: nil)
            }
            let raw = Self.hexDump(header)
            switch PreviewFormat.detect(header: header, name: file.name) {
            case .image:
                guard file.sizeBytes <= Self.imageCap else { return .unavailable(.tooLarge, rawBytes: raw) }
                guard let data = try await read(Self.imageCap) else { return .unavailable(.deviceUnreadable, rawBytes: raw) }
                try Task.checkCancellation()
                switch Self.decodeImage(data) {
                case .success(let image): return .image(PreviewImage(cgImage: image))
                case .failure(let reason): return .unavailable(reason, rawBytes: raw)
                }
            case .pdf:
                guard file.sizeBytes <= Self.pdfCap else { return .unavailable(.tooLarge, rawBytes: raw) }
                guard let data = try await read(Self.pdfCap) else { return .unavailable(.deviceUnreadable, rawBytes: raw) }
                try Task.checkCancellation()
                guard let document = PDFDocument(data: data), document.pageCount > 0 else {
                    return .unavailable(.unsupportedFormat, rawBytes: raw)
                }
                return .pdf(PreviewPDF(document: document))
            case .text, .unknown:
                let data: Data
                if file.sizeBytes <= Self.rawBytesCap {
                    data = header
                } else if Self.decodeText(header, truncated: true) == nil {
                    // The 4 KiB header is already binary; don't pull 1 MiB to find that out again.
                    return .unavailable(.unsupportedFormat, rawBytes: raw)
                } else {
                    guard let more = try await read(Self.textCap) else { return .unavailable(.deviceUnreadable, rawBytes: raw) }
                    data = more
                }
                let truncated = Int64(data.count) < file.sizeBytes
                if let text = Self.decodeText(data, truncated: truncated) {
                    return .text(text, truncated: truncated)
                }
                return .unavailable(.unsupportedFormat, rawBytes: raw)
            }
        } catch let unavailable as Unavailable {
            return .unavailable(unavailable.reason, rawBytes: nil)
        }
    }

    private struct Unavailable: Error { let reason: PreviewUnavailableReason }

    // MARK: - Decoding

    static func decodeImage(_ data: Data) -> Result<CGImage, PreviewUnavailableReason> {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
              CGImageSourceGetCount(source) > 0 else { return .failure(.unsupportedFormat) }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        if let refusal = checkDeclaredSize(properties) { return .failure(refusal) }
        // A thumbnail at most `maxImageDimension` on its long side, built straight from the
        // source (never from a full-size decode first) and not cached.
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: false,
            kCGImageSourceThumbnailMaxPixelSize: maxImageDimension,
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
            return .failure(.unsupportedFormat)
        }
        return .success(image)
    }

    /// Checks the declared pixel size before any decode. An image that doesn't declare both
    /// dimensions is refused (its decode cost can't be bounded); so is one over `maxImagePixels`.
    static func checkDeclaredSize(_ properties: [CFString: Any]) -> PreviewUnavailableReason? {
        guard let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else {
            return .unsupportedFormat
        }
        guard width > 0, height > 0 else { return .unsupportedFormat }
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, pixels <= maxImagePixels else { return .tooLarge }
        return nil
    }

    /// UTF-16 needs a byte-order mark and more than 95% printable code units; UTF-8 must decode
    /// cleanly (allowing a sequence cut off by the read cap) and contain no NULs or other
    /// non-whitespace control bytes.
    static func decodeText(_ data: Data, truncated: Bool) -> String? {
        let bytes = [UInt8](data.prefix(2))
        if bytes == [0xFF, 0xFE] || bytes == [0xFE, 0xFF] {
            var body = data
            if truncated, body.count % 2 == 1 { body = body.dropLast() }
            guard isMostlyPrintableUTF16(body, littleEndian: bytes == [0xFF, 0xFE], truncated: truncated),
                  let text = String(data: body, encoding: .utf16), !text.isEmpty else { return nil }
            return text.contains("\u{0}") ? nil : text
        }
        var body = data
        if body.starts(with: [0xEF, 0xBB, 0xBF]) { body = body.dropFirst(3) }
        var text = String(data: body, encoding: .utf8)
        if text == nil, truncated {
            // Drop at most three trailing bytes of a multi-byte sequence split by the cap.
            for cut in 1...3 where body.count > cut {
                if let decoded = String(data: body.dropLast(cut), encoding: .utf8) { text = decoded; break }
            }
        }
        guard let text else { return nil }
        let allowed: Set<UInt8> = [0x09, 0x0A, 0x0D, 0x0C]
        guard !body.contains(where: { ($0 < 0x20 && !allowed.contains($0)) || $0 == 0x7F }) else { return nil }
        return text
    }

    /// Random bytes after a BOM still decode as UTF-16, mostly as BMP characters, so require that
    /// more than 95% of the code units (after the BOM) are printable: assigned, not private-use,
    /// not a lone surrogate, and not a control character other than tab, LF, CR or FF.
    static func isMostlyPrintableUTF16(_ data: Data, littleEndian: Bool, truncated: Bool) -> Bool {
        let bytes = [UInt8](data.dropFirst(2))
        var units: [UInt16] = []
        units.reserveCapacity(bytes.count / 2)
        var index = 0
        while index + 1 < bytes.count {
            let a = UInt16(bytes[index]), b = UInt16(bytes[index + 1])
            units.append(littleEndian ? a | b << 8 : a << 8 | b)
            index += 2
        }
        guard !units.isEmpty else { return false }
        let whitespace: Set<UInt32> = [0x09, 0x0A, 0x0D, 0x0C]
        var printable = 0
        var i = 0
        while i < units.count {
            let unit = units[i]
            if UTF16.isLeadSurrogate(unit) {
                if i + 1 < units.count, UTF16.isTrailSurrogate(units[i + 1]) {
                    let value = 0x10000 + (UInt32(unit - 0xD800) << 10) + UInt32(units[i + 1] - 0xDC00)
                    if let scalar = Unicode.Scalar(value), isPrintable(scalar, whitespace) { printable += 2 }
                    i += 2
                    continue
                }
                // A pair split by the read cap at the very end is not evidence of binary.
                if truncated, i == units.count - 1 { printable += 1 }
            } else if let scalar = Unicode.Scalar(unit), isPrintable(scalar, whitespace) {
                printable += 1
            }
            i += 1
        }
        return printable * 100 > units.count * 95
    }

    private static func isPrintable(_ scalar: Unicode.Scalar, _ whitespace: Set<UInt32>) -> Bool {
        switch scalar.properties.generalCategory {
        case .control: return whitespace.contains(scalar.value)
        case .unassigned, .privateUse, .surrogate: return false
        default: return true
        }
    }

    /// Classic 16-bytes-per-line hex dump: offset, hex bytes, printable ASCII.
    static func hexDump(_ data: Data) -> String {
        let bytes = [UInt8](data.prefix(Int(rawBytesCap)))
        let hex = Array("0123456789abcdef")
        var lines: [String] = []
        lines.reserveCapacity(bytes.count / 16 + 1)
        var offset = 0
        while offset < bytes.count {
            let row = bytes[offset..<min(offset + 16, bytes.count)]
            var line = String(format: "%08x  ", offset)
            for (index, byte) in row.enumerated() {
                line.append(hex[Int(byte >> 4)]); line.append(hex[Int(byte & 0x0F)]); line.append(" ")
                if index == 7 { line.append(" ") }
            }
            if row.count < 16 {
                line.append(String(repeating: " ", count: (16 - row.count) * 3 + (row.count <= 7 ? 1 : 0)))
            }
            line.append(" |")
            for byte in row { line.append((0x20...0x7E).contains(byte) ? Character(UnicodeScalar(byte)) : ".") }
            line.append("|")
            lines.append(line)
            offset += 16
        }
        return lines.joined(separator: "\n")
    }
}
