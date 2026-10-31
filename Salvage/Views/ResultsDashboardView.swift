import SalvageCore
import SwiftUI

/// The results surface shown once a scan has ended: the dashboard, and the File Browser it opens.
struct ResultsView: View {
    let scan: ScanViewModel
    @State private var model: ResultsViewModel?
    @State private var browsing = false

    var body: some View {
        Group {
            if let model {
                if browsing {
                    FileBrowserView(model: model, source: scan.source, onBack: { browsing = false })
                } else {
                    ResultsDashboardView(model: model, scan: scan) { category in
                        model.category = category
                        model.focusedID = nil
                        browsing = true
                    }
                }
            } else {
                ProgressView("Organizing results…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { if model == nil { model = await ResultsViewModel.build(files: scan.files) } }
    }
}

/// Scan Results Dashboard (FR-11): one tile per type bucket with count and size, and a total.
struct ResultsDashboardView: View {
    @Bindable var model: ResultsViewModel
    let scan: ScanViewModel
    /// Opens the File Browser, filtered to a category or (nil) showing everything.
    let onOpen: (FileCategory?) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(scan.device?.displayName ?? "Scan results").font(.largeTitle).bold()
                    Text(statusLine).foregroundStyle(.secondary)
                }
                if case .failed(let error) = scan.state {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(error.description).textSelection(.enabled)
                        if error == .permissionDenied || scan.canRetryFromCheckpoint, !scan.isActive, let device = scan.device {
                            Button("Retry scan") { scan.start(device) }
                        }
                    }
                }
                if model.hasRecoverableFiles {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("By type").font(.headline)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 280), spacing: 16)],
                                  alignment: .leading, spacing: 16) {
                            ForEach(model.buckets) { bucket in tile(bucket) }
                        }
                        Text("\(filesText(model.recoverableCount)) · \(bytes(model.recoverableBytes)) in total")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Button("Browse all files") { onOpen(nil) }
                    }
                } else {
                    Text("No recoverable files found on this device.")
                }
                if model.unrecoverableCount > 0 {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Can't be recovered").font(.headline)
                        Text("\(filesText(model.unrecoverableCount)) were found, but Salvage couldn't locate their contents on the device. They aren't counted above.")
                            .foregroundStyle(.secondary)
                        Button("View these files") { onOpen(nil) }
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Show system files", isOn: $model.showSystemFiles).toggleStyle(.checkbox)
                    if model.hiddenSystemFileCount > 0 {
                        Text("\(filesText(model.hiddenSystemFileCount)) of macOS housekeeping (such as ._ and .DS_Store) hidden.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("Files listed here have been indexed from intact metadata. No files have been copied or recovered.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func tile(_ bucket: ResultsViewModel.Bucket) -> some View {
        Button { onOpen(bucket.category) } label: {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: Self.symbol(for: bucket.category)).font(.title2).foregroundStyle(.secondary)
                Text(bucket.category.displayName).font(.headline)
                Text("\(filesText(bucket.count)) · \(bytes(bucket.totalBytes))").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(.background, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(bucket.count == 0)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(bucket.category.displayName), \(filesText(bucket.count)), \(bytes(bucket.totalBytes))")
    }

    private var statusLine: String {
        let found = "\(scan.files.count.formatted()) \(scan.files.count == 1 ? "item" : "items") found"
        switch scan.state {
        case .cancelled: return "Scan cancelled — \(found) before it stopped"
        case .failed: return "Scan stopped early — \(found) before it stopped"
        default: return "Scan completed — \(found)"
        }
    }

    private func filesText(_ count: Int) -> String { "\(count.formatted()) \(count == 1 ? "file" : "files")" }
    private func bytes(_ count: Int64) -> String { ByteCountFormatter.string(fromByteCount: count, countStyle: .file) }

    static func symbol(for category: FileCategory) -> String {
        switch category {
        case .pictures: "photo"
        case .videos: "film"
        case .audio: "music.note"
        case .documents: "doc.text"
        case .archives: "archivebox"
        case .other: "doc"
        }
    }
}
