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
                .font(.subheadline).foregroundStyle(.inkSecondary)
            // Lazy, and capped at `lostPartitionRowLimit` rows: a damaged disk can yield hundreds.
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(model.displayedLostPartitions) { partition in row(partition) }
            }
            if let more = model.moreLostPartitionsText {
                Text(more).font(.subheadline).foregroundStyle(.inkSecondary)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Lost partitions")
    }

    private func row(_ partition: LostPartitionCandidate) -> some View {
        let summary = model.lostPartitionSummary(partition)
        let title = ResultsViewModel.lostPartitionTitle(partition)
        let location = ResultsViewModel.lostPartitionLocation(partition)
        let files = summary.text
        return Button { onOpen(partition) } label: {
            HStack(spacing: 12) {
                Image(systemName: "externaldrive.badge.questionmark").font(.title2).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    Text("\(files) · \(location)").font(.caption).foregroundStyle(.inkSecondary)
                }
                Spacer(minLength: 0)
                if summary.opens { Image(systemName: "chevron.forward").foregroundStyle(.tertiary) }
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(16)
            .background(.background, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(!summary.opens)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(files), \(location)")
    }
}
