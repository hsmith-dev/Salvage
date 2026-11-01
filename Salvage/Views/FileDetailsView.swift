import AppKit
import SalvageCore
import SwiftUI

/// The file details panel (spec-tech-batch-7 §C): what Salvage knows about one file, and one
/// plain sentence on why it has its recovery confidence. Everything shown comes from
/// `FileDetails`; the view adds no wording of its own beyond headings.
struct FileDetailsView: View {
    let details: FileDetails
    /// Lists every run when true (the sheet); the preview pane's disclosure shows the first few.
    var showsAllRuns = true

    /// Runs drawn at most; Copy Details includes up to `FileDetails.maxCopiedRuns`.
    static let maxShownRuns = 500
    static let compactRuns = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("Recovery confidence:").foregroundStyle(.secondary)
                    ConfidenceLabel(confidence: details.confidence)
                }
                Text(details.explanation)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("confidence-explanation")
            }
            ForEach(details.sections) { section in
                VStack(alignment: .leading, spacing: 6) {
                    Text(section.title).font(.headline)
                    ForEach(section.fields) { field in
                        LabeledContent(field.label) {
                            Text(field.value).multilineTextAlignment(.trailing).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            runsSection
        }
        .font(.subheadline)
    }

    private var runsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Where its bytes are").font(.headline)
            if let storage = details.storage {
                Text(storage).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            let limit = showsAllRuns ? Self.maxShownRuns : Self.compactRuns
            ForEach(details.runs.prefix(limit)) { run in
                Text(run.text).monospacedDigit().foregroundStyle(run.deviceOffset == nil ? .secondary : .primary)
                    .textSelection(.enabled)
            }
            if details.runs.count > limit {
                Text("… and \((details.runs.count - limit).formatted()) more runs. Copy Details includes them.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// The Show Details sheet (⌘I in the File Browser).
struct FileDetailsSheet: View {
    let details: FileDetails
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(details.name).font(.title3.weight(.semibold)).lineLimit(2).truncationMode(.middle)
            ScrollView {
                FileDetailsView(details: details).padding(.trailing, 8)
            }
            HStack {
                Button("Copy Details") { Self.copy(details) }
                    .accessibilityIdentifier("copy-details-button")
                Spacer()
                Button("Done", action: onDone).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 480, idealWidth: 560, minHeight: 420, idealHeight: 560)
    }

    static func copy(_ details: FileDetails) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(details.copyText, forType: .string)
    }
}
