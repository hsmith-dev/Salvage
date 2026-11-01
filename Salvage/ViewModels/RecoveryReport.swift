import Foundation
import SalvageCore

/// The record of one recovery (spec-tech-batch-7 §D): `Salvage Recovery Report.csv` and `.json`,
/// written into the recovery root folder after the copies, through `RecoveryEngine.writeAttachment`
/// (same no-overwrite publishing and containment as the recovered files). One row per selected
/// file, in selection order, built only from the engine's `RecoverySummary`, so its totals are the
/// summary's totals. It lives only in the destination the user chose; it holds file names and
/// paths, never credentials or keys.
struct RecoveryReport: Sendable, Equatable {
    static let baseName = "Salvage Recovery Report"
    static let csvName = baseName + ".csv"
    static let jsonName = baseName + ".json"
    /// Bumped when the JSON layout changes incompatibly.
    static let formatVersion = 1

    /// What the report says about the run as a whole, fixed when the run starts.
    struct Context: Sendable, Equatable {
        var appVersion: String = RecoveryReport.currentAppVersion
        let date: Date
        let deviceName: String
        let device: BlockDevice?
        /// "Photos (exFAT)" for Recover all files…; nil for an ordinary selection.
        let sourceLabel: String?
    }

    enum Status: String, Sendable, Codable {
        case recovered = "Recovered"
        case failed = "Failed"
        case notAttempted = "Not attempted"
    }

    struct Totals: Sendable, Equatable, Codable {
        let selected: Int
        let recovered: Int
        let failed: Int
        let notAttempted: Int
        let bytesWritten: Int64
        let cancelled: Bool
    }

    struct Header: Sendable, Equatable, Codable {
        let formatVersion: Int
        let appVersion: String
        let date: Date
        let sourceDevice: String
        /// The drive's model string as the system reports it (shown as its name in Salvage).
        let sourceModel: String?
        /// The BSD name, e.g. "disk6"; nil when unknown.
        let sourceIdentifier: String?
        let sourceSizeBytes: Int64?
        let recoveredFrom: String?
        let recoveryFolder: String
        let totals: Totals
    }

    struct Row: Sendable, Equatable, Codable {
        let originalPath: String
        let name: String
        /// Relative to the recovery folder; nil unless recovered.
        let recoveredPath: String?
        let status: Status
        /// Why it failed or wasn't attempted; nil when recovered.
        let reason: String?
        let originalSizeBytes: Int64
        /// Bytes actually written; nil unless recovered.
        let writtenBytes: Int64?
        /// Lowercase hex SHA-256 of the written bytes; nil unless recovered.
        let sha256: String?
        /// "High", "Medium", "Low", or nil when the contents couldn't be located.
        let confidence: String?
        let method: String
        let deleted: Bool
        let reconstructed: Bool
        let partial: Bool
        let sourceDevice: String
        let filesystem: String
        let volume: String
        let volumeOffset: Int64
        let recordOffset: Int64
    }

    let header: Header
    let rows: [Row]

    static let notAttemptedReason = "Recovery was cancelled before this file was copied."

    init(files: [RecoveredFile], summary: RecoverySummary, context: Context) {
        let copies = Dictionary(summary.written.compactMap { copy in copy.fileID.map { ($0, copy) } },
                                uniquingKeysWith: { first, _ in first })
        let failures = Dictionary(summary.failed.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let rootPath = summary.root.standardizedFileURL.path
        let partitions = context.device?.partitions ?? []
        rows = files.map { file in
            let copy = copies[file.id]
            let failure = copy == nil ? failures[file.id] : nil
            let status: Status = copy != nil ? .recovered : (failure != nil ? .failed : .notAttempted)
            let format = PartitionGrouping.formatName(file.sourceMetadata.filesystem)
            let volume = file.sourceMetadata.volumeName.map { PartitionGrouping.volumeName($0, formatName: format) }
                ?? PartitionGrouping.name(forVolumeAt: file.sourceMetadata.volumeOffset, formatName: format,
                                          partitions: partitions).name
            return Row(originalPath: file.path, name: file.name,
                       recoveredPath: copy.map { Self.relativePath(of: $0.url, under: rootPath) },
                       status: status,
                       reason: failure?.reason ?? (status == .notAttempted ? Self.notAttemptedReason : nil),
                       originalSizeBytes: file.sizeBytes, writtenBytes: copy?.bytes, sha256: copy?.sha256,
                       confidence: file.recoveryConfidence?.displayName,
                       method: file.recoveryMethod == .carved ? "Reconstructed from raw data" : "Filesystem records",
                       deleted: file.isDeleted, reconstructed: file.recoveryMethod == .carved, partial: file.isPartial,
                       sourceDevice: context.deviceName, filesystem: format, volume: volume,
                       volumeOffset: file.sourceMetadata.volumeOffset, recordOffset: file.sourceMetadata.recordOffset)
        }
        header = Header(formatVersion: Self.formatVersion, appVersion: context.appVersion, date: context.date,
                        sourceDevice: context.deviceName, sourceModel: context.device?.displayName,
                        sourceIdentifier: context.device?.bsdName, sourceSizeBytes: context.device?.sizeBytes,
                        recoveredFrom: context.sourceLabel, recoveryFolder: summary.root.lastPathComponent,
                        totals: Totals(selected: summary.selectedCount, recovered: summary.written.count,
                                       failed: summary.failed.count, notAttempted: summary.notAttempted,
                                       bytesWritten: summary.bytesWritten, cancelled: summary.cancelled))
    }

    /// The two files the engine writes into the root, CSV first.
    func attachments() -> [RootAttachment] {
        var list = [RootAttachment(name: Self.csvName, data: csv())]
        if let json = try? json() { list.append(RootAttachment(name: Self.jsonName, data: json)) }
        return list
    }

    static var currentAppVersion: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? ""
        let build = info["CFBundleVersion"] as? String ?? ""
        switch (short.isEmpty, build.isEmpty) {
        case (false, false): return "\(short) (\(build))"
        case (false, true): return short
        case (true, false): return build
        case (true, true): return "Unknown"
        }
    }

    private static func relativePath(of url: URL, under rootPath: String) -> String {
        let path = url.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : url.lastPathComponent
    }

    // MARK: CSV

    static let csvColumns = ["Original path", "Name", "Recovered path", "Status", "Reason", "Original size (bytes)",
                             "Written size (bytes)", "SHA-256", "Confidence", "Method", "Deleted", "Reconstructed",
                             "Partial", "Source device", "Filesystem", "Volume", "Volume offset", "Record offset"]

    /// UTF-8 with a byte-order mark (so spreadsheet apps read non-Latin names correctly) and CRLF
    /// line ends (RFC 4180). A short key/value header, a blank line, then the table.
    func csv() -> Data {
        let date = ISO8601DateFormatter().string(from: header.date)
        let totals = header.totals
        var lines: [[String]] = [
            ["Salvage Recovery Report"],
            ["App version", header.appVersion],
            ["Date", date],
            ["Source device", header.sourceDevice],
        ]
        if let model = header.sourceModel { lines.append(["Model", model]) }
        if let identifier = header.sourceIdentifier { lines.append(["Device identifier", identifier]) }
        if let size = header.sourceSizeBytes { lines.append(["Device size (bytes)", String(size)]) }
        if let from = header.recoveredFrom { lines.append(["Recovered from", from]) }
        lines += [
            ["Recovery folder", header.recoveryFolder],
            ["Files selected", String(totals.selected)],
            ["Recovered", String(totals.recovered)],
            ["Failed", String(totals.failed)],
            ["Not attempted", String(totals.notAttempted)],
            ["Bytes written", String(totals.bytesWritten)],
            ["Cancelled", totals.cancelled ? "Yes" : "No"],
            [],
            Self.csvColumns,
        ]
        for row in rows {
            lines.append([row.originalPath, row.name, row.recoveredPath ?? "", row.status.rawValue, row.reason ?? "",
                          String(row.originalSizeBytes), row.writtenBytes.map(String.init) ?? "", row.sha256 ?? "",
                          row.confidence ?? "None", row.method, Self.yesNo(row.deleted), Self.yesNo(row.reconstructed),
                          Self.yesNo(row.partial), row.sourceDevice, row.filesystem, row.volume,
                          String(row.volumeOffset), String(row.recordOffset)])
        }
        let text = lines.map { $0.map(Self.csvField).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
        return Data("\u{FEFF}".utf8) + Data(text.utf8)
    }

    private static func yesNo(_ value: Bool) -> String { value ? "Yes" : "No" }

    /// Characters that make a spreadsheet treat a cell as a formula (or, for tab and CR, can be
    /// used to smuggle one past a check). Full-width forms are included: some spreadsheet apps
    /// normalize them.
    private static let formulaLeaders: Set<Unicode.Scalar> = ["=", "+", "-", "@", "\t", "\r",
                                                              "\u{FF1D}", "\u{FF0B}", "\u{FF0D}", "\u{FF20}"]

    /// One CSV field. Defeats formula injection by prefixing an apostrophe to a value whose first
    /// character -- or first character after leading spaces, which some apps skip -- is one of
    /// `formulaLeaders`; NUL becomes U+FFFD; then the value is quoted (with `"` doubled) whenever it
    /// holds a comma, quote, CR or LF, or starts or ends with a space (RFC 4180).
    static func csvField(_ value: String) -> String {
        var text = value.replacingOccurrences(of: "\u{0}", with: "\u{FFFD}")
        if let leader = text.unicodeScalars.first(where: { $0 != " " }), formulaLeaders.contains(leader) {
            text = "'" + text
        }
        let needsQuotes = text.contains { $0 == "," || $0 == "\"" || $0 == "\r" || $0 == "\n" || $0 == "\r\n" }
            || text.hasPrefix(" ") || text.hasSuffix(" ")
        guard needsQuotes else { return text }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: JSON

    private struct Document: Codable {
        let header: Header
        let files: [Row]
    }

    /// Pretty-printed, sorted keys, ISO 8601 dates; absent values are omitted.
    func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(Document(header: header, files: rows))
    }

    /// Reads a report's JSON back (tests).
    static func decodeJSON(_ data: Data) throws -> (header: Header, rows: [Row]) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(Document.self, from: data)
        return (document.header, document.files)
    }
}
