import SalvageCore
import SwiftUI

/// The results surface shown once a scan has ended: the dashboard, and the File Browser it opens.
struct ResultsView: View {
    let scan: ScanViewModel
    /// "Recover all files…" picked on a partition in the sidebar; consumed (set back to nil) here.
    var partitionRequest: Binding<PartitionRecoveryRequest?> = .constant(nil)
    @State private var model: ResultsViewModel?
    @State private var browsing = false
    @State private var partitionCache = PartitionSectionCache()
    @State private var partitionPlan: PartitionRecoveryPlan?

    var body: some View {
        VStack(spacing: 0) {
        SavedScanBanner(scan: scan)
        Group {
            if let model {
                if browsing {
                    FileBrowserView(model: model, source: scan.source, onBack: { browsing = false })
                } else {
                    ResultsDashboardView(model: model, scan: scan, partitionCache: partitionCache, onRecoverPartition: { summary in
                        partitionPlan = model.recoverAllPlan(for: summary, devicePartitions: scan.device?.partitions ?? [],
                                                             context: scan.partitionScanContext, cache: partitionCache)
                    }, onOpen: { category in
                        model.category = category
                        model.volumeFilter = nil
                        model.focusedID = nil
                        browsing = true
                    }, onOpenLostPartition: { partition in
                        model.category = nil
                        model.volumeFilter = partition.offset
                        model.focusedID = nil
                        browsing = true
                    })
                }
            } else {
                ProgressView("Organizing results…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxHeight: .infinity)
        }
        .task { if model == nil { model = await ResultsViewModel.build(files: scan.files, lostPartitions: scan.lostPartitions) } }
        .onChange(of: partitionRequest.wrappedValue) { _, _ in takePartitionRequest() }
        .onChange(of: model == nil) { _, _ in takePartitionRequest() }
        .sheet(item: $partitionPlan) { plan in
            if let source = scan.source {
                RecoverySheet(plan: plan, source: source, onDone: { partitionPlan = nil })
            }
        }
    }

    /// Opens Recover all files… for a partition picked in the sidebar, once results are ready.
    private func takePartitionRequest() {
        guard let request = partitionRequest.wrappedValue, let model, scan.source != nil else { return }
        partitionRequest.wrappedValue = nil
        partitionPlan = model.recoverAllPlan(for: request.partition, devicePartitions: scan.device?.partitions ?? [],
                                             context: scan.partitionScanContext, cache: partitionCache)
    }
}

/// Scan Results Dashboard (FR-11): one tile per type bucket with count and size, and a total.
struct ResultsDashboardView: View {
    @Bindable var model: ResultsViewModel
    let scan: ScanViewModel
    /// The Partitions section's grouping cache, owned by `ResultsView`.
    var partitionCache = PartitionSectionCache()
    /// Recover all files… on one partition row.
    var onRecoverPartition: (PartitionSummary) -> Void = { _ in }
    /// Opens the File Browser, filtered to a category or (nil) showing everything.
    let onOpen: (FileCategory?) -> Void
    /// Opens the File Browser scoped to one lost partition's files (FR-9/FR-10).
    var onOpenLostPartition: (LostPartitionCandidate) -> Void = { _ in }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(scan.device?.displayName ?? "Scan results").font(.largeTitle).bold()
                    Text(statusLine).foregroundStyle(.inkSecondary)
                        .accessibilityIdentifier("results-status")
                }
                Button("Save Scan…") { ScanArchiveActions.save(scan) }.disabled(!scan.canSaveArchive).accessibilityIdentifier("save-scan")
                if case .failed(let error) = scan.state {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(error.description).textSelection(.enabled)
                        if error == .permissionDenied || scan.canRetryFromCheckpoint, !scan.isActive, let device = scan.device {
                            Button("Retry scan") { scan.start(device) }
                        }
                    }
                }
                // Read once per body: each accessor is a cached lookup, not a rescan of the rows.
                let totals = model.aggregates(includingSystemFiles: model.showSystemFiles)
                let emptyState = model.emptyState(for: scan.state)
                if let empty = emptyState {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(empty.message)
                        if empty == .onlySystemFiles {
                            Toggle("Show system files", isOn: $model.showSystemFiles).toggleStyle(.checkbox)
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("By type").font(.headline)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 280), spacing: 16)],
                                  alignment: .leading, spacing: 16) {
                            ForEach(totals.buckets) { bucket in tile(bucket) }
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("By type")
                        Text("\(filesText(totals.recoverableCount)) · \(bytes(totals.recoverableBytes)) in total")
                            .font(.subheadline).foregroundStyle(.inkSecondary)
                        Button("Browse all files") { onOpen(nil) }
                    }
                }
                let partitionRows = model.partitionSummaries(devicePartitions: scan.device?.partitions ?? [],
                                                             context: scan.partitionScanContext, cache: partitionCache)
                if !partitionRows.isEmpty {
                    PartitionsSection(summaries: partitionRows, canRecover: scan.source != nil, onRecoverAll: onRecoverPartition)
                }
                // Its own section, after the type grid and never inside it (FR-9).
                if !model.lostPartitions.isEmpty {
                    LostPartitionsCard(model: model, onOpen: onOpenLostPartition)
                }
                if totals.unrecoverableCount > 0 {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Can't be recovered").font(.headline)
                        Text("\(filesText(totals.unrecoverableCount)) were found, but Salvage couldn't locate their contents on the device. They aren't counted above.")
                            .foregroundStyle(.inkSecondary)
                        Button("View these files") { onOpen(nil) }
                    }
                }
                // What the scan could not do: calm, text only, no alarm color (DESIGN.md).
                if !scan.noticeLines.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("About this scan").font(.headline)
                        ForEach(Array(scan.noticeLines.enumerated()), id: \.offset) { _, line in
                            Text(line).foregroundStyle(.inkSecondary).textSelection(.enabled)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
                // The only-system-files state carries its own toggle; don't show a second one.
                if emptyState != .onlySystemFiles {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Show system files", isOn: $model.showSystemFiles).toggleStyle(.checkbox)
                        if model.hiddenSystemFileCount > 0 {
                            Text("\(filesText(model.hiddenSystemFileCount)) of macOS housekeeping (such as ._ and .DS_Store) hidden.")
                                .font(.caption).foregroundStyle(.inkSecondary)
                        }
                    }
                }
                Text(Self.closingNote(reconstructed: totals.reconstructedCount,
                                      fromMetadata: totals.recoverableCount - totals.reconstructedCount + totals.unrecoverableCount))
                    .font(.subheadline).foregroundStyle(.inkSecondary)
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
                Text(["\(filesText(bucket.count)) · \(bytes(bucket.totalBytes))", ResultsViewModel.reconstructedCaption(bucket.reconstructedCount)].compactMap { $0 }.joined(separator: " ")).font(.caption).foregroundStyle(.inkSecondary)
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
        .accessibilityLabel(Self.tileAccessibilityLabel(bucket))
        .accessibilityIdentifier("bucket-\(bucket.category.rawValue)")
    }

    private var statusLine: String {
        let found = "\(scan.files.count.formatted()) \(scan.files.count == 1 ? "item" : "items") found"
        switch scan.state {
        case .cancelled: return "Scan cancelled — \(found) before it stopped"
        case .failed: return "Scan stopped early — \(found) before it stopped"
        default: return "Scan completed — \(found)"
        }
    }

    /// The dashboard's closing sentence: how the listed files were found, and that nothing was copied.
    static func closingNote(reconstructed: Int, fromMetadata: Int) -> String {
        let how = switch (fromMetadata > 0, reconstructed > 0) {
        case (_, false): "have been indexed from intact metadata"
        case (false, true): "have been reconstructed from their contents on the device"
        case (true, true): "have been indexed from intact metadata or reconstructed from their contents on the device"
        }
        return "Files listed here \(how). No files have been copied or recovered."
    }

    static func tileAccessibilityLabel(_ bucket: ResultsViewModel.Bucket) -> String {
        var parts = [bucket.category.displayName, ResultsViewModel.filesText(bucket.count),
                     ByteCountFormatter.string(fromByteCount: bucket.totalBytes, countStyle: .file)]
        if bucket.reconstructedCount > 0 { parts.append("\(bucket.reconstructedCount.formatted()) reconstructed") }
        return parts.joined(separator: ", ")
    }

    private func filesText(_ count: Int) -> String { ResultsViewModel.filesText(count) }
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
