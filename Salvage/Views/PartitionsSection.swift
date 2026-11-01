import SalvageCore
import SwiftUI

/// The dashboard's Partitions section (spec-tech-recover-whole-partition): one row per volume the
/// scan read files from, each lost partition, and any unpartitioned space, with its recoverable,
/// deleted and reconstructed counts and a Recover all files… button. Copying never touches the
/// drive being recovered; the recovery sheet's destination rules apply unchanged.
struct PartitionsSection: View {
    let summaries: [PartitionSummary]
    /// False when the scan's read-only session is gone, so nothing can be copied.
    let canRecover: Bool
    let onRecoverAll: (PartitionSummary) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Partitions").font(.headline)
            Text("Recover every file from one partition into a folder on another drive, keeping its folders.")
                .font(.subheadline).foregroundStyle(.secondary)
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(summaries) { summary in row(summary) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Partitions")
    }

    private func row(_ summary: PartitionSummary) -> some View {
        HStack(spacing: 12) {
            Image(systemName: Self.symbol(summary.kind)).font(.title2).foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(summary.title).font(.headline)
                Text(summary.countsText).font(.caption).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            Button("Recover all files…") { onRecoverAll(summary) }
                .disabled(!canRecover || !summary.canRecoverAll)
                .accessibilityLabel("Recover all files from \(summary.name)")
        }
        .frame(maxWidth: 640, alignment: .leading)
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
    }

    static func symbol(_ kind: PartitionSummary.Kind) -> String {
        switch kind {
        case .mapped: "externaldrive"
        case .lost: "externaldrive.badge.questionmark"
        case .unpartitioned: "square.dashed"
        }
    }
}
