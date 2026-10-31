import Foundation
import Observation
import SalvageCore

/// Scan Results Dashboard and File Browser state (Stories 1.7 + 1.8). Built once from a finished
/// scan's files; every per-file derivation (bucket, confidence, system-file flag, search key) is
/// computed up front so filtering and sorting never touch the render path.
@MainActor @Observable
final class ResultsViewModel {
    struct Row: Identifiable, Sendable, Equatable {
        let file: RecoveredFile
        let category: FileCategory
        /// nil when the file is unmapped and can't be recovered.
        let confidence: RecoveryConfidence?
        let isSystemFile: Bool
        let searchKey: String
        var id: UUID { file.id }
        var name: String { file.name }
        var path: String { file.path }
        var sizeBytes: Int64 { file.sizeBytes }
        /// Non-optional so the browser's Table can sort by it; files without a date sort first.
        var modifiedSortKey: Date { file.modified ?? .distantPast }
        var isRecoverable: Bool { confidence != nil }

        init(_ file: RecoveredFile) {
            self.file = file
            category = file.category
            confidence = file.recoveryConfidence
            isSystemFile = ResultsViewModel.isSystemFile(file)
            searchKey = (file.name + "\n" + file.path).lowercased()
        }
    }

    struct Bucket: Identifiable, Equatable, Sendable {
        let category: FileCategory
        var count: Int
        var totalBytes: Int64
        var id: FileCategory { category }
    }

    enum SortField: Sendable, Equatable { case name, path, size, modified }
    struct Sort: Sendable, Equatable {
        var field: SortField
        var ascending: Bool
        static let `default` = Sort(field: .name, ascending: true)
    }

    /// Everything that decides which rows the browser shows, in what order.
    struct Query: Hashable, Sendable {
        var category: FileCategory?
        var search: String
        var showSystemFiles: Bool
        var sortField: SortField
        var ascending: Bool
    }

    let rows: [Row]
    /// Rows the browser currently shows, filtered and sorted off the main actor by `refresh()`.
    private(set) var visibleRows: [Row] = []
    /// The File Browser's category filter; nil shows every category.
    var category: FileCategory?
    var searchText = ""
    var showSystemFiles = false
    var sort = Sort.default
    /// Files ticked for recovery. Only recoverable rows can be in here.
    private(set) var checked: Set<UUID> = []
    /// The single row selected for preview.
    var focusedID: UUID?
    private var generation = 0
    private var appliedQuery: Query?
    private let rowsByID: [UUID: Row]

    convenience init(files: [RecoveredFile]) { self.init(rows: files.map(Row.init)) }

    init(rows: [Row]) {
        self.rows = rows
        rowsByID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Builds the model with per-file derivations computed off the main actor (large scans).
    static func build(files: [RecoveredFile]) async -> ResultsViewModel {
        let rows = await Task.detached(priority: .userInitiated) { files.map(Row.init) }.value
        let model = ResultsViewModel(rows: rows)
        await model.refresh()
        return model
    }

    // MARK: Dashboard

    /// Rows counted by the dashboard and listed by the browser: system files only when shown.
    private var inScope: [Row] { showSystemFiles ? rows : rows.filter { !$0.isSystemFile } }

    /// One bucket per category, in dashboard order, counting only recoverable files.
    var buckets: [Bucket] {
        var byCategory = Dictionary(uniqueKeysWithValues: FileCategory.allCases.map { ($0, Bucket(category: $0, count: 0, totalBytes: 0)) })
        for row in inScope where row.isRecoverable {
            byCategory[row.category]?.count += 1
            byCategory[row.category]?.totalBytes += max(0, row.sizeBytes)
        }
        return FileCategory.allCases.compactMap { byCategory[$0] }
    }
    var recoverableCount: Int { inScope.lazy.filter(\.isRecoverable).count }
    var recoverableBytes: Int64 { inScope.lazy.filter(\.isRecoverable).reduce(0) { $0 + max(0, $1.sizeBytes) } }
    /// Found but unmapped: shown separately, never part of the recoverable totals.
    var unrecoverableCount: Int { inScope.lazy.filter { !$0.isRecoverable }.count }
    var hiddenSystemFileCount: Int { showSystemFiles ? 0 : rows.lazy.filter(\.isSystemFile).count }
    var hasRecoverableFiles: Bool { recoverableCount > 0 }

    // MARK: Browser

    var query: Query {
        Query(category: category, search: searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              showSystemFiles: showSystemFiles, sortField: sort.field, ascending: sort.ascending)
    }

    /// Recomputes `visibleRows` for the current query away from the main actor. A refresh that a
    /// newer one overtakes is discarded rather than published.
    func refresh() async {
        let query = query
        if appliedQuery == query { return }
        generation += 1
        let mine = generation
        let rows = rows
        let result = await Task.detached(priority: .userInitiated) { Self.apply(query, to: rows) }.value
        guard mine == generation else { return }
        visibleRows = result
        appliedQuery = query
    }

    nonisolated static func apply(_ query: Query, to rows: [Row]) -> [Row] {
        var result = rows.filter { row in
            (query.showSystemFiles || !row.isSystemFile)
                && (query.category == nil || row.category == query.category)
                && (query.search.isEmpty || row.searchKey.contains(query.search))
        }
        let ascending = query.ascending
        func ordered<T: Comparable>(_ a: T, _ b: T, _ tieA: Row, _ tieB: Row) -> Bool {
            if a != b { return ascending ? a < b : a > b }
            return tieA.path < tieB.path
        }
        switch query.sortField {
        case .name:
            result.sort { a, b in
                let c = a.name.localizedStandardCompare(b.name)
                if c != .orderedSame { return ascending ? c == .orderedAscending : c == .orderedDescending }
                return a.path < b.path
            }
        case .path: result.sort { ordered($0.path, $1.path, $0, $1) }
        case .size: result.sort { ordered($0.sizeBytes, $1.sizeBytes, $0, $1) }
        case .modified: result.sort { ordered($0.modifiedSortKey, $1.modifiedSortKey, $0, $1) }
        }
        return result
    }

    func isChecked(_ id: UUID) -> Bool { checked.contains(id) }

    /// Ticks or unticks a file for recovery; an unrecoverable file can't be ticked.
    func setChecked(_ id: UUID, _ on: Bool) {
        if on {
            guard rowsByID[id]?.isRecoverable == true else { return }
            checked.insert(id)
        } else {
            checked.remove(id)
        }
    }

    func clearChecked() { checked = [] }

    /// Files ticked for recovery, in the browser's current order where visible.
    var checkedFiles: [RecoveredFile] {
        let visible = visibleRows.filter { checked.contains($0.id) }.map(\.file)
        guard visible.count < checked.count else { return visible }
        let seen = Set(visible.map(\.id))
        return visible + rows.filter { checked.contains($0.id) && !seen.contains($0.id) }.map(\.file)
    }
    var checkedCount: Int { checked.count }
    var recoverButtonTitle: String { "Recover (\(checked.count) selected)" }

    var focusedRow: Row? { focusedID.flatMap { rowsByID[$0] } }

    // MARK: Rules

    nonisolated private static let systemPathComponents: Set<String> = [".fseventsd", ".Spotlight-V100", ".Trashes"]

    /// macOS housekeeping: AppleDouble `._` files, `.DS_Store`, and anything under `.fseventsd`,
    /// `.Spotlight-V100` or `.Trashes`.
    nonisolated static func isSystemFile(_ file: RecoveredFile) -> Bool {
        if file.name.hasPrefix("._") || file.name == ".DS_Store" { return true }
        return file.path.split(separator: "/").contains { component in
            component.hasPrefix("._") || component == ".DS_Store" || systemPathComponents.contains(String(component))
        }
    }

    /// The results surface replaces scan progress once a scan has ended (completed, cancelled or
    /// failed) with files to show. A completed scan with none still shows the dashboard so it can
    /// say so; a failed or cancelled scan with none keeps the progress view and its error/retry.
    static func showsResults(state: ScanViewModel.State, isActive: Bool, fileCount: Int) -> Bool {
        guard !isActive else { return false }
        switch state {
        case .completed: return true
        case .cancelled, .failed: return fileCount > 0
        case .idle, .preparing, .running, .paused, .resumable: return false
        }
    }
}
