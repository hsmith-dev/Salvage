import Foundation
import SalvageCore

struct UsageError: Error, Equatable, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// A command line naming something Salvage refuses to read (exit code 3, not a usage error).
struct RefusedArgument: Error, Equatable, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// What a scan or recovery reads: a whole drive by BSD name, or a disk image file.
enum SourceArgument: Equatable {
    case device(String)
    case image(String)

    /// `disk4`, `/dev/disk4` and `/dev/rdisk4` name a drive; anything else is an image path (use
    /// `./disk4` for a file of that name). A partition (`disk4s1`) is refused: scans cover whole
    /// drives, and the partitions are found inside them.
    static func parse(_ text: String) throws -> SourceArgument {
        var name = text
        if name.hasPrefix("/dev/r") { name = String(name.dropFirst("/dev/r".count)) }
        else if name.hasPrefix("/dev/") { name = String(name.dropFirst("/dev/".count)) }
        let bytes = Array(name.utf8)
        let isDiskShaped = name.hasPrefix("disk") && bytes.count > 4
            && bytes.dropFirst(4).allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || $0 == UInt8(ascii: "s") }
            && bytes[4] >= 0x30 && bytes[4] <= 0x39
        if isDiskShaped {
            guard !name.dropFirst(4).contains("s") else {
                let whole = "disk" + name.dropFirst(4).prefix { $0 != "s" }
                throw RefusedArgument("refused: \(text) is a partition. Salvage scans whole drives: use \(whole).")
            }
            return .device(name)
        }
        if text.hasPrefix("/dev/") {
            throw UsageError("\(text) isn't a drive Salvage can read. Name a whole drive, such as disk4 (see `salvage list`).")
        }
        return .image(text)
    }
}

/// `--format` values: a category (pictures, videos, audio, documents, archives, other) or a file
/// extension (jpg), comma-separated and repeatable.
struct FormatFilter: Equatable {
    var categories: Set<FileCategory> = []
    var extensions: Set<String> = []
    var isEmpty: Bool { categories.isEmpty && extensions.isEmpty }

    mutating func add(_ value: String) throws {
        for raw in value.split(separator: ",") {
            let item = raw.trimmingCharacters(in: .whitespaces).lowercased()
            let bare = item.hasPrefix(".") ? String(item.dropFirst()) : item
            guard !bare.isEmpty else { throw UsageError("--format needs a category or file extension.") }
            if let category = FileCategory(rawValue: bare) { categories.insert(category) } else { extensions.insert(bare) }
        }
    }

    func matches(_ file: RecoveredFile) -> Bool {
        if isEmpty { return true }
        if categories.contains(file.category) { return true }
        let ext = (file.name as NSString).pathExtension.lowercased()
        return !ext.isEmpty && extensions.contains(ext)
    }
}

enum Command: Equatable {
    case help
    case version
    case list(json: Bool)
    case scan(ScanOptions)
    case recover(RecoverOptions)
}

struct ScanOptions: Equatable {
    var source: SourceArgument
    var json = false
    var quiet = false
    var deletedOnly = false
    var format = FormatFilter()
    var limit: Int?
}

struct RecoverOptions: Equatable {
    enum Selection: Equatable {
        case all
        case paths([String])
        case partitions([Int64])
    }
    var source: SourceArgument
    var destination: String
    var selection: Selection
    var includeReconstructed = false
    var json = false
    var quiet = false
}

enum ArgumentParser {
    static func parse(_ arguments: [String]) throws -> Command {
        guard let first = arguments.first else { throw UsageError("Missing command.") }
        var rest = Array(arguments.dropFirst())
        switch first {
        case "--version", "-V", "version":
            guard rest.isEmpty else { throw UsageError("--version takes no arguments.") }
            return .version
        case "--help", "-h", "help":
            return .help
        case "list":
            var json = false
            while let arg = rest.first {
                rest.removeFirst()
                switch arg {
                case "--json": json = true
                default: throw UsageError("Unknown option for list: \(arg)")
                }
            }
            return .list(json: json)
        case "scan":
            return .scan(try parseScan(rest))
        case "recover":
            return .recover(try parseRecover(rest))
        default:
            throw UsageError("Unknown command: \(first)")
        }
    }

    private static func value(after option: String, in rest: inout [String]) throws -> String {
        guard let value = rest.first, !value.hasPrefix("--") else { throw UsageError("\(option) needs a value.") }
        rest.removeFirst()
        return value
    }

    private static func parseScan(_ arguments: [String]) throws -> ScanOptions {
        var rest = arguments
        var source: SourceArgument?
        var options = ScanOptions(source: .image(""))
        while let arg = rest.first {
            rest.removeFirst()
            switch arg {
            case "--json": options.json = true
            case "--quiet", "-q": options.quiet = true
            case "--deleted-only": options.deletedOnly = true
            case "--format": try options.format.add(try value(after: arg, in: &rest))
            case "--limit":
                let text = try value(after: arg, in: &rest)
                guard let limit = Int(text), limit > 0 else { throw UsageError("--limit needs a positive whole number.") }
                options.limit = limit
            case "--": if let next = rest.first { rest.removeFirst(); source = try setSource(source, next) }
            default:
                guard !arg.hasPrefix("-") else { throw UsageError("Unknown option for scan: \(arg)") }
                source = try setSource(source, arg)
            }
        }
        guard let source else { throw UsageError("scan needs a drive (diskN) or a disk image path.") }
        options.source = source
        return options
    }

    private static func setSource(_ current: SourceArgument?, _ text: String) throws -> SourceArgument {
        guard current == nil else { throw UsageError("Only one source can be given.") }
        return try SourceArgument.parse(text)
    }

    private static func parseRecover(_ arguments: [String]) throws -> RecoverOptions {
        var rest = arguments
        var source: SourceArgument?
        var destination: String?
        var all = false
        var paths: [String] = []
        var partitions: [Int64] = []
        var includeReconstructed = false, json = false, quiet = false
        while let arg = rest.first {
            rest.removeFirst()
            switch arg {
            case "--to":
                guard destination == nil else { throw UsageError("Only one --to folder can be given.") }
                destination = try value(after: arg, in: &rest)
            case "--all": all = true
            case "--path": paths.append(try value(after: arg, in: &rest))
            case "--partition":
                let text = try value(after: arg, in: &rest)
                guard let offset = parseOffset(text) else {
                    throw UsageError("--partition needs a byte offset, such as 1048576 or 0x100000 (shown by `salvage scan`).")
                }
                partitions.append(offset)
            case "--include-reconstructed": includeReconstructed = true
            case "--json": json = true
            case "--quiet", "-q": quiet = true
            default:
                guard !arg.hasPrefix("-") else { throw UsageError("Unknown option for recover: \(arg)") }
                source = try setSource(source, arg)
            }
        }
        guard let source else { throw UsageError("recover needs a drive (diskN) or a disk image path.") }
        guard let destination else { throw UsageError("recover needs --to <folder>: a folder on a different drive.") }
        let modes = (all ? 1 : 0) + (paths.isEmpty ? 0 : 1) + (partitions.isEmpty ? 0 : 1)
        guard modes == 1 else { throw UsageError("recover needs exactly one of --all, --path <glob> or --partition <offset>.") }
        let selection: RecoverOptions.Selection = all ? .all : paths.isEmpty ? .partitions(partitions) : .paths(paths)
        return RecoverOptions(source: source, destination: destination, selection: selection,
                              includeReconstructed: includeReconstructed, json: json, quiet: quiet)
    }

    static func parseOffset(_ text: String) -> Int64? {
        let lower = text.lowercased()
        let value = lower.hasPrefix("0x") ? Int64(lower.dropFirst(2), radix: 16) : Int64(lower)
        guard let value, value >= 0 else { return nil }
        return value
    }

    static let usage = """
    Usage:
      salvage list [--json]
      salvage scan <diskN | /path/to/image> [--json] [--deleted-only] [--format <type>[,...]] [--limit <n>] [--quiet]
      salvage recover <diskN | /path/to/image> --to <folder>
                      (--all | --path <glob> [--path <glob> ...] | --partition <offset> [...])
                      [--include-reconstructed] [--json] [--quiet]
      salvage --version
      salvage --help

    Salvage only reads the source. It refuses your startup disk, refuses a destination folder on the
    drive (or image) being recovered from, never overwrites a file, and never uses the network.
    --format takes pictures, videos, audio, documents, archives, other, or an extension such as jpg.
    Exit codes: 0 done, 1 failed, 2 usage, 3 refused for safety, 4 finished with problems,
    5 nothing matched, 130 interrupted. See docs/CLI.md.
    """
}
