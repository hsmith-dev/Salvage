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

    /// The dashboard's totals for one `showSystemFiles` setting.
    struct Aggregates: Equatable, Sendable {
        /// One bucket per category, in dashboard order, counting only recoverable files.
        var buckets: [Bucket]
        var recoverableCount: Int
        var recoverableBytes: Int64
        /// Found but unmapped: shown separately, never part of the recoverable totals.
        var unrecoverableCount: Int
    }

    /// What the dashboard says when there is nothing to show in the type tiles.
    enum EmptyState: Equatable, Sendable {
        /// Only macOS housekeeping files were recoverable, and they are hidden.
        case onlySystemFiles
        /// A completed scan found nothing recoverable, system files included.
        case nothingRecoverable
        /// A cancelled or failed scan found nothing recoverable before it stopped.
        case nothingRecoverableBeforeStop

        var message: String {
            switch self {
            case .onlySystemFiles: "Only macOS system files were found. Show system files to see them."
            case .nothingRecoverable: "No recoverable files found on this device."
            case .nothingRecoverableBeforeStop: "No recoverable files were found before the scan stopped."
            }
        }
    }

    /// The filter and sort step, injectable so tests can hold it open. It runs off the main
    /// actor and must throw `CancellationError` once its task is cancelled.
    typealias Apply = @Sendable (Query, [Row]) async throws -> [Row]
    typealias Sleep = @Sendable (Duration) async throws -> Void

    /// How long a search edit waits for the next keystroke before filtering.
    static let searchDebounce: Duration = .milliseconds(150)

    let rows: [Row]
    /// Rows the browser currently shows, filtered and sorted off the main actor by `refresh()`.
    private(set) var visibleRows: [Row] = []
    /// Recoverable and unrecoverable counts within `visibleRows`, for the browser title.
    private(set) var visibleRecoverableCount = 0
    private(set) var visibleUnrecoverableCount = 0
    /// The File Browser's category filter; nil shows every category.
    var category: FileCategory?
    var searchText = ""
    var showSystemFiles = false
    var sort = Sort.default
    /// Files ticked for recovery. Only recoverable rows can be in here.
    private(set) var checked: Set<UUID> = []
    /// Rows highlighted in the browser's table (keyboard and click selection, not ticks).
    var selection: Set<UUID> = []
    /// The single row selected for preview: set when exactly one row is selected.
    var focusedID: UUID? {
        get { selection.count == 1 ? selection.first : nil }
        set { selection = newValue.map { [$0] } ?? [] }
    }
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var appliedQuery: Query?
    @ObservationIgnored private var inFlight: Task<Applied, Error>?
    @ObservationIgnored private var visibleIDs: Set<UUID> = []
    @ObservationIgnored private var aggregateCache: [Bool: Aggregates] = [:]
    /// How many times the dashboard aggregates were computed (each is a full scan of `rows`).
    @ObservationIgnored private(set) var aggregateComputations = 0
    private let rowsByID: [UUID: Row]
    private let applyQuery: Apply
    private let sleep: Sleep

    convenience init(files: [RecoveredFile]) { self.init(rows: files.map(Row.init)) }

    init(rows: [Row],
         apply: @escaping Apply = { query, rows in try ResultsViewModel.apply(query, to: rows) },
         sleep: @escaping Sleep = { try await Task.sleep(for: $0) }) {
        self.rows = rows
        rowsByID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        applyQuery = apply
        self.sleep = sleep
    }

    /// Builds the model with per-file derivations computed off the main actor (large scans).
    static func build(files: [RecoveredFile]) async -> ResultsViewModel {
        let rows = await Task.detached(priority: .userInitiated) { files.map(Row.init) }.value
        let model = ResultsViewModel(rows: rows)
        await model.refresh()
        return model
    }

    // MARK: Dashboard

    /// Computed once per `showSystemFiles` setting (`rows` never changes) and cached.
    func aggregates(includingSystemFiles: Bool) -> Aggregates {
        if let cached = aggregateCache[includingSystemFiles] { return cached }
        aggregateComputations += 1
        var byCategory = Dictionary(uniqueKeysWithValues: FileCategory.allCases.map { ($0, Bucket(category: $0, count: 0, totalBytes: 0)) })
        var recoverable = 0, unrecoverable = 0
        var bytes: Int64 = 0
        for row in rows where includingSystemFiles || !row.isSystemFile {
            guard row.isRecoverable else { unrecoverable += 1; continue }
            let size = max(0, row.sizeBytes)
            recoverable += 1
            bytes += size
            byCategory[row.category]?.count += 1
            byCategory[row.category]?.totalBytes += size
        }
        let result = Aggregates(buckets: FileCategory.allCases.compactMap { byCategory[$0] }, recoverableCount: recoverable,
                                recoverableBytes: bytes, unrecoverableCount: unrecoverable)
        aggregateCache[includingSystemFiles] = result
        return result
    }

    private var current: Aggregates { aggregates(includingSystemFiles: showSystemFiles) }
    var buckets: [Bucket] { current.buckets }
    var recoverableCount: Int { current.recoverableCount }
    var recoverableBytes: Int64 { current.recoverableBytes }
    var unrecoverableCount: Int { current.unrecoverableCount }
    /// Equal to the difference between the two cached aggregates, so it costs no extra scan.
    var hiddenSystemFileCount: Int {
        guard !showSystemFiles else { return 0 }
        let all = aggregates(includingSystemFiles: true), shown = current
        return all.recoverableCount + all.unrecoverableCount - shown.recoverableCount - shown.unrecoverableCount
    }
    var hasRecoverableFiles: Bool { recoverableCount > 0 }

    /// What the dashboard says instead of the tiles, or nil when there are tiles to show.
    func emptyState(scanCompleted: Bool) -> EmptyState? {
        guard !hasRecoverableFiles else { return nil }
        if aggregates(includingSystemFiles: true).recoverableCount > 0 { return .onlySystemFiles }
        return scanCompleted ? .nothingRecoverable : .nothingRecoverableBeforeStop
    }

    func emptyState(for state: ScanViewModel.State) -> EmptyState? {
        emptyState(scanCompleted: state == .completed)
    }

    // MARK: Browser

    var query: Query {
        Query(category: category, search: searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              showSystemFiles: showSystemFiles, sortField: sort.field, ascending: sort.ascending)
    }

    struct Applied: Sendable {
        let rows: [Row]
        let ids: Set<UUID>
        let recoverable: Int
    }

    /// Recomputes `visibleRows` for the current query away from the main actor. Every call
    /// supersedes (and cancels) the one before it, including a call for a query that is already
    /// applied, so a stale result is never published. With `debounceSearch`, a change to the
    /// search text first waits `searchDebounce` for further keystrokes.
    func refresh(debounceSearch: Bool = false) async {
        generation += 1
        let mine = generation
        inFlight?.cancel()
        inFlight = nil
        let query = query
        if appliedQuery == query { return }
        if debounceSearch, query.search != (appliedQuery?.search ?? "") {
            do { try await sleep(Self.searchDebounce) } catch { return }
            guard mine == generation, !Task.isCancelled else { return }
        }
        let rows = rows, apply = applyQuery
        let task = Task.detached(priority: .userInitiated) { () throws -> Applied in
            let result = try await apply(query, rows)
            try Task.checkCancellation()
            return Applied(rows: result, ids: Set(result.lazy.map(\.id)), recoverable: result.lazy.filter(\.isRecoverable).count)
        }
        inFlight = task
        let applied = try? await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        guard let applied, mine == generation, !Task.isCancelled else { return }
        inFlight = nil
        visibleRows = applied.rows
        visibleIDs = applied.ids
        visibleRecoverableCount = applied.recoverable
        visibleUnrecoverableCount = applied.rows.count - applied.recoverable
        appliedQuery = query
        // A selected row the filter now hides can't stay selected (or previewed).
        if !selection.isSubset(of: visibleIDs) { selection.formIntersection(visibleIDs) }
    }

    /// Filters and sorts; checks for cancellation every few thousand rows and comparisons, so a
    /// superseded query stops early instead of finishing a 100k-row sort.
    nonisolated static func apply(_ query: Query, to rows: [Row]) throws -> [Row] {
        let stride = 4096
        try Task.checkCancellation()
        var result: [Row] = []
        for (index, row) in rows.enumerated() {
            if index % stride == stride - 1 { try Task.checkCancellation() }
            if (query.showSystemFiles || !row.isSystemFile)
                && (query.category == nil || row.category == query.category)
                && (query.search.isEmpty || row.searchKey.contains(query.search)) {
                result.append(row)
            }
        }
        let ascending = query.ascending
        var comparisons = 0
        func tick() throws {
            comparisons &+= 1
            if comparisons % (stride * 4) == 0 { try Task.checkCancellation() }
        }
        func ordered<T: Comparable>(_ a: T, _ b: T, _ tieA: Row, _ tieB: Row) throws -> Bool {
            try tick()
            if a != b { return ascending ? a < b : a > b }
            return tieA.path < tieB.path
        }
        switch query.sortField {
        case .name:
            try result.sort { a, b in
                try tick()
                let c = a.name.localizedStandardCompare(b.name)
                if c != .orderedSame { return ascending ? c == .orderedAscending : c == .orderedDescending }
                return a.path < b.path
            }
        case .path: try result.sort { try ordered($0.path, $1.path, $0, $1) }
        case .size: try result.sort { try ordered($0.sizeBytes, $1.sizeBytes, $0, $1) }
        case .modified: try result.sort { try ordered($0.modifiedSortKey, $1.modifiedSortKey, $0, $1) }
        }
        return result
    }

    /// "Pictures — 12 files, 2 can't be recovered": counts recoverable files, like the tiles,
    /// with unrecoverable ones named separately.
    var browserTitle: String {
        var title = "\(category?.displayName ?? "All files") — \(Self.filesText(visibleRecoverableCount))"
        if visibleUnrecoverableCount > 0 { title += ", \(visibleUnrecoverableCount.formatted()) can't be recovered" }
        return title
    }

    nonisolated static func filesText(_ count: Int) -> String { "\(count.formatted()) \(count == 1 ? "file" : "files")" }

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

    // MARK: Keyboard selection

    /// Return / Cmd-K: ticks every selected recoverable row, or, when they are all ticked
    /// already, unticks them.
    func toggleCheckedForSelection() {
        let ids = selection.filter { rowsByID[$0]?.isRecoverable == true }
        guard !ids.isEmpty else { return }
        if ids.isSubset(of: checked) { checked.subtract(ids) } else { checked.formUnion(ids) }
    }

    /// Ticks every recoverable row the browser currently shows.
    func selectAllRecoverable() {
        checked.formUnion(visibleRows.lazy.filter(\.isRecoverable).map(\.id))
    }

    /// Unticks everything, including ticked files the current filter hides.
    func deselectAll() { clearChecked() }

    // MARK: Recover

    /// Ticked files the current filter shows, in the browser's order. Recover acts on these only;
    /// ticks hidden by the filter are kept, counted in `selectionSummary`, and not recovered.
    var checkedFiles: [RecoveredFile] { visibleRows.lazy.filter { self.checked.contains($0.id) }.map(\.file) }
    var checkedCount: Int { checked.count }
    var visibleCheckedCount: Int { checked.lazy.filter { self.visibleIDs.contains($0) }.count }
    var hiddenCheckedCount: Int { checked.count - visibleCheckedCount }
    var recoverButtonTitle: String { "Recover (\(visibleCheckedCount.formatted()) selected)" }
    /// "5 selected (2 hidden)" when the filter hides ticked files; nil otherwise.
    var selectionSummary: String? {
        let hidden = hiddenCheckedCount
        guard hidden > 0 else { return nil }
        return "\(checked.count.formatted()) selected (\(hidden.formatted()) hidden)"
    }

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
