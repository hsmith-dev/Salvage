import Foundation

/// The Scan Results Dashboard's type buckets (FR-11). Every file lands in exactly one bucket;
/// anything unrecognised goes to `.other` and is never dropped.
public enum FileCategory: String, CaseIterable, Sendable, Hashable, Identifiable {
    case pictures, videos, audio, documents, archives, other

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .pictures: "Pictures"
        case .videos: "Videos"
        case .audio: "Audio"
        case .documents: "Documents"
        case .archives: "Archives"
        case .other: "Other"
        }
    }

    /// Classifies by file extension, case-insensitively. `signature` (the file's leading bytes) is
    /// the magic-byte hook: it is consulted only when the extension is missing or unknown, and no
    /// signatures are recognised yet, so such files go to `.other` for now.
    public static func classify(fileName: String, signature: Data? = nil) -> FileCategory {
        if let ext = fileExtension(of: fileName), let category = byExtension[ext] { return category }
        if let signature, let category = fromSignature(signature) { return category }
        return .other
    }

    /// Lower-cased extension after the last dot, or nil for names without one (including
    /// dot-files like `.profile`, whose leading dot is not an extension separator).
    static func fileExtension(of name: String) -> String? {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return nil }
        let ext = name[name.index(after: dot)...]
        return ext.isEmpty ? nil : ext.lowercased()
    }

    /// Magic-byte classification hook, deliberately empty until carving (AD-6) needs it.
    static func fromSignature(_ signature: Data) -> FileCategory? { nil }

    static let byExtension: [String: FileCategory] = {
        var map: [String: FileCategory] = [:]
        let table: [(FileCategory, [String])] = [
            (.pictures, ["jpg", "jpeg", "jpe", "png", "gif", "bmp", "tif", "tiff", "heic", "heif", "webp",
                         "raw", "cr2", "cr3", "nef", "arw", "dng", "orf", "rw2", "raf", "srw", "psd", "svg", "ico"]),
            (.videos, ["mp4", "m4v", "mov", "avi", "mkv", "wmv", "flv", "webm", "mpg", "mpeg", "3gp", "mts",
                       "m2ts", "ts", "vob"]),
            (.audio, ["mp3", "m4a", "aac", "wav", "aif", "aiff", "flac", "ogg", "oga", "opus", "wma", "alac", "mid", "midi"]),
            (.documents, ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "odt", "ods", "odp", "rtf", "txt",
                          "md", "csv", "pages", "numbers", "key", "epub", "html", "htm", "xml", "json"]),
            (.archives, ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "dmg", "iso", "cab", "lz", "zst"]),
        ]
        for (category, extensions) in table { for ext in extensions { map[ext] = category } }
        return map
    }()
}
