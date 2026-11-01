import SalvageCore
import SwiftUI

/// The dashboard's Lost Partitions section (FR-9): filesystems found in unallocated space, outside
/// the current partition table. Its own section below the type grid, never a seventh tile: the
/// distinction is positional and structural, not a color treatment (DESIGN.md). Each row opens the
/// File Browser scoped to that partition's files (FR-10). Salvage reads these in place; it never
/// rewrites the partition table.
struct LostPartitionsCard: View {
    let model: ResultsViewModel
    let onOpen: (LostPartitionCandidate) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Lost partitions").font(.headline)
            Text("Found in unallocated space, outside the current partition table. Their files are listed separately from the mounted volumes; the partition table itself is never modified.")
                .font(.subheadline).foregroundStyle(.secondary)
            ForEach(model.lostPartitions) { partition in row(partition) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Lost partitions")
    }

    private func row(_ partition: LostPartitionCandidate) -> some View {
        let count = model.fileCount(in: partition)
        let title = ResultsViewModel.lostPartitionTitle(partition)
        let location = ResultsViewModel.lostPartitionLocation(partition)
        let files = count == 0 ? "No recoverable files" : ResultsViewModel.filesText(count)
        return Button { onOpen(partition) } label: {
            HStack(spacing: 12) {
                Image(systemName: "externaldrive.badge.questionmark").font(.title2).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    Text("\(files) · \(location)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if count > 0 { Image(systemName: "chevron.forward").foregroundStyle(.tertiary) }
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(16)
            .background(.background, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(count == 0)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(files), \(location)")
    }
}
