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

    @State private var sortOrder = [KeyPathComparator(\ResultsViewModel.Row.name)]
    @State private var showsPreview = true
    @State private var recovery: RecoveryRequest?

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
        // Filtering and sorting run off the main actor; a newer query supersedes an older one.
        .task(id: model.query) { await model.refresh() }
        .onChange(of: sortOrder) { _, order in model.sort = Self.sort(from: order) }
        .sheet(item: $recovery) { request in recoverySheet(request) }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Button("All results", systemImage: "chevron.backward", action: onBack)
            Text(title).font(.headline)
            Spacer()
            Toggle("Show system files", isOn: $model.showSystemFiles).toggleStyle(.checkbox)
            Button(model.recoverButtonTitle) {
                guard let source else { return }
                recovery = RecoveryRequest(files: model.checkedFiles, source: source)
            }
            .buttonStyle(.borderedProminent)
            .tint(.salvageAccent)
            .disabled(model.checkedCount == 0 || source == nil)
            .help(source == nil ? "The device is no longer available. Scan it again to recover files." : "")
        }
    }

    private var title: String {
        let count = model.visibleRows.count
        let files = "\(count.formatted()) \(count == 1 ? "file" : "files")"
        return "\(model.category?.displayName ?? "All files") — \(files)"
    }

    private var table: some View {
        Table(model.visibleRows, selection: $model.focusedID, sortOrder: $sortOrder) {
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
                    if row.file.isDeleted { Text("Deleted").font(.caption).foregroundStyle(.secondary) }
                }
            }
            .width(min: 160, ideal: 240)
            TableColumn("Path", value: \ResultsViewModel.Row.path) { row in
                Text(row.path).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
            }
            .width(min: 120, ideal: 220)
            TableColumn("Size", value: \ResultsViewModel.Row.sizeBytes) { row in
                Text(ByteCountFormatter.string(fromByteCount: row.sizeBytes, countStyle: .file)).monospacedDigit()
            }
            .width(min: 64, ideal: 80)
            TableColumn("Modified", value: \ResultsViewModel.Row.modifiedSortKey) { row in
                Text(row.file.modified.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Unknown")
                    .foregroundStyle(.secondary)
            }
            .width(min: 110, ideal: 150)
            TableColumn("Confidence") { row in ConfidenceLabel(confidence: row.confidence) }
                .width(min: 90, ideal: 120)
        }
        // Single click selects and previews; Space shows or hides the preview, like Quick Look.
        .onKeyPress(.space) {
            guard model.focusedID != nil else { return .ignored }
            showsPreview.toggle()
            return .handled
        }
        .overlay {
            if model.visibleRows.isEmpty {
                Text(model.searchText.isEmpty ? "No files in this category." : "No files match your search.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var previewPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let row = model.focusedRow {
                FilePreviewView(file: row.file, source: source)
                    .frame(maxWidth: .infinity, minHeight: 200, maxHeight: .infinity)
                    .background(.background, in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.name).font(.headline).textSelection(.enabled)
                    Text(row.path).font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled)
                    Text(ByteCountFormatter.string(fromByteCount: row.sizeBytes, countStyle: .file))
                        .font(.subheadline).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Text(row.isRecoverable ? "Recovery confidence:" : "Status:").font(.subheadline).foregroundStyle(.secondary)
                        ConfidenceLabel(confidence: row.confidence)
                    }
                    .accessibilityElement(children: .combine)
                    if !row.isRecoverable {
                        Text("Salvage couldn't locate this file's contents on the device.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("Select a file to preview.")
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(16)
    }

    @ViewBuilder private func recoverySheet(_ request: RecoveryRequest) -> some View {
        // INTEGRATION SLOT (Story 1.10): replace `RecoverySlot` with `RecoverySheet`.
        RecoverySlot(files: request.files, source: request.source, onDone: { recovery = nil })
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
