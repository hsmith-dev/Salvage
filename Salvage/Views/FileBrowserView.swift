import AppKit
import SalvageCore
import SwiftUI

/// The File Browser (FR-12): a lazy, sortable, searchable table with checkbox multi-select, the
/// recovery-confidence label per file, a preview pane, and a persistent Recover button.
struct FileBrowserView: View {
    @Bindable var model: ResultsViewModel
    /// The scanned device's kept read-only session; nil when it isn't available (Recover is disabled).
    let source: SourceSession?
    let onBack: () -> Void

    private struct RecoveryRequest: Identifiable {
        let id = UUID()
        let files: [RecoveredFile]
        let source: SourceSession
    }

    @State private var sortOrder: [KeyPathComparator<ResultsViewModel.Row>]
    @State private var showsPreview = true
    @State private var recovery: RecoveryRequest?
    @State private var detailsFile: RecoveredFile?
    @FocusState private var tableFocused: Bool

    init(model: ResultsViewModel, source: SourceSession?, onBack: @escaping () -> Void) {
        self.model = model; self.source = source; self.onBack = onBack
        // Start from the model's sort so the header arrow matches the order shown.
        _sortOrder = State(initialValue: Self.sortOrder(for: model.sort))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(16)
            Divider()
            HSplitView {
                table.frame(minWidth: 420)
                if showsPreview { previewPane.frame(minWidth: 260, idealWidth: 320, maxWidth: 480) }
            }
        }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search names and paths")
        // Filtering and sorting run off the main actor; a newer query cancels and supersedes an
        // older one, and search edits are debounced.
        .task(id: model.query) { await model.refresh(debounceSearch: true) }
        .onChange(of: sortOrder) { _, order in model.sort = Self.sort(from: order) }
        .sheet(item: $recovery) { request in recoverySheet(request) }
        .sheet(item: $detailsFile) { file in FileDetailsSheet(details: FileDetails(file: file, device: source?.device)) { detailsFile = nil } }
        .background { keyboardShortcuts }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Button("All results", systemImage: "chevron.backward", action: onBack)
            Text(model.browserTitle).font(.headline)
            Spacer()
            Toggle("Show system files", isOn: $model.showSystemFiles).toggleStyle(.checkbox)
            Button(showsPreview ? "Hide Preview" : "Show Preview") { showsPreview.toggle() }
            Button("Show Details") { detailsFile = model.focusedRow?.file }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(model.focusedRow == nil)
                .accessibilityIdentifier("show-details-button")
            selectionMenu
            if let summary = model.selectionSummary {
                Text(summary)
                    .font(.subheadline).foregroundStyle(.inkSecondary)
                    .help("Ticked files hidden by the current filter or search aren't recovered.")
            }
            Button(model.recoverButtonTitle) {
                guard let source else { return }
                recovery = RecoveryRequest(files: model.checkedFiles, source: source)
            }
            .buttonStyle(.borderedProminent)
            .tint(.salvageAccent)
            .disabled(model.visibleCheckedCount == 0 || source == nil)
            .help(source == nil ? "The device is no longer available. Scan it again to recover files." : "")
            .accessibilityIdentifier("recover-button")
        }
    }

    /// Mouse and VoiceOver path to the keyboard commands; the shortcut hints are shown here and
    /// handled by `keyboardShortcuts` and the table's key handler.
    private var selectionMenu: some View {
        Menu("Select") {
            Button("Tick or Untick Selected Rows (Return, \u{2318}K)") { model.toggleCheckedForSelection() }
                .disabled(model.selection.isEmpty)
            Button("Select All Recoverable (\u{2318}A)") { model.selectAllRecoverable() }
            Button("Deselect All (\u{2325}\u{2318}A)") { model.deselectAll() }
                .disabled(model.checkedCount == 0)
        }
        .fixedSize()
    }

    /// Invisible buttons that carry the browser's shortcuts. Cmd-A is enabled only while the
    /// table has focus, so it never takes Select All away from the search field.
    private var keyboardShortcuts: some View {
        Group {
            Button("Tick or Untick Selected Rows") { model.toggleCheckedForSelection() }
                .keyboardShortcut("k", modifiers: .command)
            Button("Select All Recoverable") { model.selectAllRecoverable() }
                .keyboardShortcut("a", modifiers: .command)
                .disabled(!tableFocused)
            Button("Deselect All") { model.deselectAll() }
                .keyboardShortcut("a", modifiers: [.command, .option])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    /// Reconstructed (carved) files are listed in their own section after the filesystem's files
    /// (EXPERIENCE.md "Carved/reconstructed results"); a listing without any shows no sections.
    private var table: some View {
        Table(of: ResultsViewModel.Row.self, selection: $model.selection, sortOrder: $sortOrder) {
            TableColumn("") { (row: ResultsViewModel.Row) in
                Toggle("Select \(row.name) for recovery", isOn: Binding(
                    get: { model.isChecked(row.id) },
                    set: { model.setChecked(row.id, $0) }))
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                    .disabled(!row.isRecoverable)
            }
            .width(24)
            TableColumn("Name", value: \ResultsViewModel.Row.name) { row in
                HStack(spacing: 6) {
                    Text(row.name).lineLimit(1).truncationMode(.middle)
                    if row.file.isDeleted { Text("Deleted").font(.caption).foregroundStyle(.inkSecondary) }
                    if row.isReconstructed { Text(ResultsViewModel.reconstructedSectionTitle).font(.caption).foregroundStyle(.inkSecondary) }
                    if row.isPartial { Text(ResultsViewModel.partialTag).font(.caption).foregroundStyle(.inkSecondary) }
                }
            }
            .width(min: 160, ideal: 240)
            TableColumn("Path", value: \ResultsViewModel.Row.path) { row in
                Text(row.path).lineLimit(1).truncationMode(.middle).foregroundStyle(.inkSecondary)            }
            .width(min: 120, ideal: 220)
            TableColumn("Size", value: \ResultsViewModel.Row.sizeBytes) { row in
                Text(ByteCountFormatter.string(fromByteCount: row.sizeBytes, countStyle: .file)).monospacedDigit()
            }
            .width(min: 64, ideal: 80)
            TableColumn("Modified", value: \ResultsViewModel.Row.modifiedSortKey) { row in
                Text(row.file.modified.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Unknown")
                    .foregroundStyle(.inkSecondary)
            }
            .width(min: 110, ideal: 150)
            TableColumn("Confidence") { row in ConfidenceLabel(confidence: row.confidence) }
                .width(min: 90, ideal: 120)
        } rows: {
            let rows = model.visibleRows
            let split = rows.count - model.visibleReconstructedCount
            if model.visibleReconstructedCount == 0 {
                ForEach(rows) { TableRow($0) }
            } else {
                Section(ResultsViewModel.filesystemSectionTitle) { ForEach(rows[..<split]) { TableRow($0) } }
                Section(ResultsViewModel.reconstructedSectionTitle) { ForEach(rows[split...]) { TableRow($0) } }
            }
        }
        .focused($tableFocused)
        .accessibilityLabel("Files")
        .accessibilityIdentifier("file-table")
        // Space previews, like Quick Look: it shows a hidden preview and never hides a shown one.
        .onKeyPress(.space) {
            guard !model.selection.isEmpty else { return .ignored }
            showsPreview = Self.previewVisibility(afterSpaceWhile: showsPreview)
            return .handled
        }
        // Return ticks or unticks the selected rows (Cmd-K does the same from anywhere).
        .onKeyPress(.return) {
            guard !model.selection.isEmpty else { return .ignored }
            model.toggleCheckedForSelection()
            return .handled
        }
        .accessibilityActions {
            Button("Tick or untick selected rows") { model.toggleCheckedForSelection() }
            Button("Select all recoverable") { model.selectAllRecoverable() }
            Button("Deselect all") { model.deselectAll() }
        }
        .overlay {
            if model.visibleRows.isEmpty {
                Text(model.searchText.isEmpty ? "No files in this category." : "No files match your search.")
                    .foregroundStyle(.inkSecondary)
            }
        }
    }

    /// The preview pane. `FilePreviewView` owns the panel, padding and the name/size/modified
    /// header; this adds only the path and recovery status beneath it.
    @ViewBuilder private var previewPane: some View {
        if let row = model.focusedRow {
            FilePreviewView(file: row.file, source: source) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.path).font(.subheadline).foregroundStyle(.inkSecondary).textSelection(.enabled)
                    HStack(spacing: 6) {
                        Text(row.isRecoverable ? "Recovery confidence:" : "Status:").font(.subheadline).foregroundStyle(.inkSecondary)
                        ConfidenceLabel(confidence: row.confidence)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityAddTraits(.isStaticText)
                    .accessibilityLabel(ConfidenceLabel(confidence: row.confidence).accessibilityText)
                    if !row.isRecoverable {
                        Text("Salvage couldn't locate this file's contents on the device.")
                            .font(.subheadline).foregroundStyle(.inkSecondary)
                    }
                    if row.isReconstructed {
                        Text("Reconstructed from raw bytes by its file signature. No original name, folder or date is available.")
                            .font(.subheadline).foregroundStyle(.inkSecondary)
                    }
                    if row.isPartial {
                        Text("\(ResultsViewModel.partialTag). This file could not be fully reconstructed; its end was not found.")
                            .font(.subheadline).foregroundStyle(.inkSecondary)
                    }
                }
            }
        } else {
            Text(model.selection.isEmpty ? "Select a file to preview." : "\(model.selection.count.formatted()) files selected.")
                .foregroundStyle(.inkTertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)
        }
    }

    @ViewBuilder private func recoverySheet(_ request: RecoveryRequest) -> some View {
        RecoverySheet(files: request.files, source: request.source, onDone: { recovery = nil })
    }

    /// Space never hides a preview that is showing; it only brings back a hidden one.
    static func previewVisibility(afterSpaceWhile showing: Bool) -> Bool { true }

    static func sortOrder(for sort: ResultsViewModel.Sort) -> [KeyPathComparator<ResultsViewModel.Row>] {
        let order: SortOrder = sort.ascending ? .forward : .reverse
        switch sort.field {
        case .name: return [KeyPathComparator(\ResultsViewModel.Row.name, order: order)]
        case .path: return [KeyPathComparator(\ResultsViewModel.Row.path, order: order)]
        case .size: return [KeyPathComparator(\ResultsViewModel.Row.sizeBytes, order: order)]
        case .modified: return [KeyPathComparator(\ResultsViewModel.Row.modifiedSortKey, order: order)]
        }
    }

    static func sort(from order: [KeyPathComparator<ResultsViewModel.Row>]) -> ResultsViewModel.Sort {
        guard let first = order.first else { return .default }
        let field: ResultsViewModel.SortField
        switch first.keyPath {
        case \ResultsViewModel.Row.path: field = .path
        case \ResultsViewModel.Row.sizeBytes: field = .size
        case \ResultsViewModel.Row.modifiedSortKey: field = .modified
        default: field = .name
        }
        return ResultsViewModel.Sort(field: field, ascending: first.order == .forward)
    }
}

extension Color {
    /// DESIGN.md accent (#2E6E6E light / #5FA3A3 dark), for the Recover button only.
    static let salvageAccent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0x5F / 255, green: 0xA3 / 255, blue: 0xA3 / 255, alpha: 1)
            : NSColor(srgbRed: 0x2E / 255, green: 0x6E / 255, blue: 0x6E / 255, alpha: 1)
    })
}
