import AppKit
import PDFKit
import SalvageCore
import SwiftUI

/// Selection-driven preview of one discovered file (FR-13), rendered entirely from bytes read
/// into memory through the open `SourceSession`. Nothing is written to disk and no QuickLook or
/// web rendering is used. `DESIGN.md`'s `preview-pane`: surface-raised panel, `rounded/lg`,
/// "No preview available" in `ink-tertiary`, never a blank pane.
///
/// The view owns the whole pane: the rendered panel, its padding, and the metadata header (name,
/// size, modified, "Deleted"). A host adds anything else, such as the path or recovery status,
/// through `details`, which is laid out under the header rather than around the view.
struct FilePreviewView<Details: View>: View {
    let file: RecoveredFile
    let source: SourceSession?
    private let details: Details

    init(file: RecoveredFile, source: SourceSession?, @ViewBuilder details: () -> Details) {
        self.file = file; self.source = source; self.details = details()
    }

    @State private var loaded: (id: RecoveredFile.ID, result: PreviewResult)?
    @State private var showRawBytes = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            preview
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor)))
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Preview of \(file.name)")
            VStack(alignment: .leading, spacing: 4) {
                PreviewMetadataHeader(file: file)
                details
            }
        }
        .padding(24)
        .task(id: file.id) {
            showRawBytes = false
            let loader = PreviewLoader(source: source)
            let file = self.file
            guard let result = try? await loader.load(file), !Task.isCancelled else { return }
            loaded = (file.id, result)
            if let reason = result.unavailableReason {
                AccessibilityNotification.Announcement("No preview available. \(reason.message)").post()
            }
        }
    }

    @ViewBuilder private var preview: some View {
        if let loaded, loaded.id == file.id {
            switch loaded.result {
            case .image(let image):
                Image(decorative: image.cgImage, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .padding(16)
                    .accessibilityLabel("Image preview")
            case .pdf(let pdf):
                PDFPreview(document: pdf.document)
                    .accessibilityLabel("PDF preview")
            case .text(let text, let truncated):
                VStack(alignment: .leading, spacing: 0) {
                    ReadOnlyTextView(text: text, monospaced: false)
                    if truncated {
                        Text("Showing the first 1 MB.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .padding(8)
                    }
                }
                .accessibilityLabel("Text preview")
            case .unavailable(let reason, let rawBytes):
                if showRawBytes, let rawBytes {
                    VStack(alignment: .leading, spacing: 0) {
                        ReadOnlyTextView(text: rawBytes, monospaced: true)
                            .accessibilityLabel("Raw bytes, first 4 KB")
                        Button("Hide raw bytes") { showRawBytes = false }
                            .padding(8)
                    }
                } else {
                    NoPreview(reason: reason, canShowRawBytes: rawBytes != nil) { showRawBytes = true }
                }
            }
        } else {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Loading preview")
        }
    }
}

extension FilePreviewView where Details == EmptyView {
    init(file: RecoveredFile, source: SourceSession?) {
        self.init(file: file, source: source) { EmptyView() }
    }
}

private struct NoPreview: View {
    let reason: PreviewUnavailableReason
    let canShowRawBytes: Bool
    let showRawBytes: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Text("No preview available")
                .font(.headline)
            Text(reason.message)
                .font(.subheadline)
                .multilineTextAlignment(.center)
            if canShowRawBytes {
                Button("Show raw bytes", action: showRawBytes)
                    .padding(.top, 8)
            }
        }
        .foregroundStyle(.tertiary)
        .padding(24)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("No preview available. \(reason.message)")
    }
}

private struct PreviewMetadataHeader: View {
    let file: RecoveredFile

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(file.name)
                    .font(.headline)
                    .lineLimit(2)
                    .truncationMode(.middle)
                if file.isDeleted {
                    Text("Deleted")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color(nsColor: .separatorColor)))
                }
            }
            Text(details)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var details: String {
        let size = ByteCountFormatter.string(fromByteCount: file.sizeBytes, countStyle: .file)
        guard let modified = file.modified else { return "\(size) — modified date unknown" }
        return "\(size) — modified \(modified.formatted(date: .abbreviated, time: .shortened))"
    }
}

/// Non-editable, selectable text in an AppKit text view, which stays responsive for up to the
/// 1 MiB text cap where a SwiftUI `Text` would not.
private struct ReadOnlyTextView: NSViewRepresentable {
    let text: String
    let monospaced: Bool

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        if let textView = scrollView.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = true
            textView.drawsBackground = false
            textView.isAutomaticLinkDetectionEnabled = false
            textView.isAutomaticDataDetectionEnabled = false
            textView.textContainerInset = NSSize(width: 12, height: 12)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        let font = monospaced
            ? NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            : NSFont.systemFont(ofSize: NSFont.systemFontSize)
        if textView.string != text || textView.font != font {
            textView.string = text
            textView.font = font
            textView.textColor = .labelColor
            textView.scroll(.zero)
        }
    }
}

/// PDFKit view over an in-memory document. Link clicks are swallowed so a hostile PDF can't open
/// a URL (the zero-network rule).
private struct PDFPreview: NSViewRepresentable {
    let document: PDFDocument

    func makeCoordinator() -> PDFLinkBlocker { PDFLinkBlocker() }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.backgroundColor = .clear
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document !== document { view.document = document }
    }
}

/// `PDFView`'s delegate. Implementing `pdfViewWillClick(onLink:with:)` replaces PDFView's default
/// of opening the URL with NSWorkspace; this implementation does nothing with it.
final class PDFLinkBlocker: NSObject, PDFViewDelegate {
    /// Links clicked and dropped, most recent last (kept for tests; never opened).
    private(set) var blockedURLs: [URL] = []

    func pdfViewWillClick(onLink sender: PDFView, with url: URL) {
        blockedURLs.append(url)
    }
}
