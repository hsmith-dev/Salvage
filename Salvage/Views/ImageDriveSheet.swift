import AppKit
import SalvageCore
import SalvageDiskIO
import SwiftUI
import UniformTypeIdentifiers

/// spec-tech-image-drive: a window's "Image This Drive…" flow. One run at a time per window,
/// presented as a sheet by `ContentView`. Started from the drive's context menu in the sidebar,
/// File > Image This Drive…, or the results dashboard.
@MainActor @Observable
final class DriveImagingCenter {
    var active: DriveImagingModel?
    /// Builds the environment for a run (the live one in the app; tests may swap it).
    var environment: (SourceSession?) -> DriveImagingEnvironment = { DriveImagingEnvironment.live(reusing: $0) }

    var isBusy: Bool { active?.isActive == true }

    /// Whether `device` can be imaged: a whole drive (not an opened image file), not the boot drive.
    static func canImage(_ device: BlockDevice?) -> Bool {
        guard let device else { return false }
        return !device.isBootVolume && !OpenedDiskImage.isImageDeviceID(device.id) && device.sizeBytes > 0
    }

    /// Asks where to save the image, then starts. `session` is the window's finished scan session,
    /// reused when it is of this drive.
    func begin(_ device: BlockDevice, session: SourceSession?) {
        guard Self.canImage(device), !isBusy, let choice = Self.chooseDestination(for: device) else { return }
        let model = DriveImagingModel(device: device, destination: choice.url, replacingConfirmed: choice.replacing,
                                      environment: environment(session))
        active = model
        model.start()
    }

    /// After a refused destination: choose another and try again.
    func chooseAgain(session: SourceSession?) {
        guard let model = active, !model.isActive else { return }
        let device = model.device
        active = nil
        begin(device, session: session)
    }

    func dismiss() {
        guard active?.isActive != true else { return }
        active = nil
    }

    func tearDown() { active?.cancel() }

    /// The save panel. Its own replace prompt is the only way an existing file is replaced.
    private static func chooseDestination(for device: BlockDevice) -> (url: URL, replacing: Bool)? {
        let panel = NSSavePanel()
        panel.title = "Image This Drive"
        panel.prompt = "Image"
        panel.message = "Save a copy of every sector of “\(device.displayName)” (\(DriveImagingFormat.bytes(device.sizeBytes))). Choose a folder on a different drive with at least that much free space."
        panel.nameFieldStringValue = DriveImagingFormat.suggestedFileName(for: device)
        panel.allowedContentTypes = [UTType(filenameExtension: "img") ?? .diskImage]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, var url = panel.url else { return nil }
        // Only a file at the very path the panel confirmed counts as confirmed.
        let confirmed = FileManager.default.fileExists(atPath: url.path)
        if url.pathExtension.lowercased() != "img" {
            url.appendPathExtension("img")
            return (url, false)
        }
        return (url, confirmed)
    }
}

extension EnvironmentValues {
    @Entry var driveImaging: DriveImagingCenter?
}

/// The dashboard's "Image This Drive…" button, for the scanned drive.
struct ImageDriveButton: View {
    let scan: ScanViewModel
    @Environment(\.driveImaging) private var imaging

    var body: some View {
        if let imaging, let device = scan.device, DriveImagingCenter.canImage(device) {
            Button("Image This Drive…") { imaging.begin(device, session: scan.source) }
                .disabled(scan.isActive || imaging.isBusy)
                .help("Copy every sector of this drive into an image file on another drive, then scan the image instead.")
                .accessibilityIdentifier("image-drive-button")
        }
    }
}

/// File > Image This Drive… for the window's current drive (the one last selected or scanned).
struct ImageDriveCommand: Commands {
    @FocusedValue(\.scanArchiveTarget) private var scan
    @FocusedValue(\.driveImagingTarget) private var imaging

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Image This Drive…") {
                if let imaging, let device = scan?.device { imaging.begin(device, session: scan?.source) }
            }
            .disabled(imaging == nil || imaging?.isBusy == true || scan?.isActive != false
                      || !DriveImagingCenter.canImage(scan?.device))
        }
    }
}

struct DriveImagingTargetKey: FocusedValueKey { typealias Value = DriveImagingCenter }

extension FocusedValues {
    var driveImagingTarget: DriveImagingCenter? {
        get { self[DriveImagingTargetKey.self] }
        set { self[DriveImagingTargetKey.self] = newValue }
    }
}

/// The imaging sheet: checking, copying with live progress, then the summary.
struct ImageDriveSheet: View {
    let model: DriveImagingModel
    var onChooseAgain: () -> Void = {}
    var onDone: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch model.phase {
            case .checking, .copying: running
            case .blocked(let message): refused(DestinationBlockBanner(message: message))
            case .failed(let message): refused(Text(message).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                                                .accessibilityIdentifier("image-drive-error"))
            case .finished(let summary): ImagingSummaryView(summary: summary, onDone: onDone)
            }
        }
        .padding(24)
        .frame(minWidth: 480, idealWidth: 520)
        .interactiveDismissDisabled(model.isActive)
        .accessibilityIdentifier("image-drive-sheet")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Image “\(model.device.displayName)”")
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text("To \(model.destination.path)")
                .font(.subheadline).foregroundStyle(.inkSecondary)
                .lineLimit(2).truncationMode(.middle)
                .help(model.destination.path)
        }
    }

    private var running: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if model.phase == .checking {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(model.isCancelling ? "Canceling…"
                         : model.asksForPassword ? "macOS asks for an administrator password so Salvage can read this drive. Salvage only reads it and never changes it."
                         : "Checking the destination and preparing the drive for read-only access…")
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                let progress = model.progress
                ProgressView(value: Double(progress.bytesDone), total: Double(max(1, progress.totalBytes)))
                    .accessibilityLabel("Bytes copied")
                    .accessibilityValue("\(percent(progress)) percent, \(DriveImagingFormat.bytes(progress.bytesDone)) of \(DriveImagingFormat.bytes(progress.totalBytes))")
                    .accessibilityIdentifier("image-progress")
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(DriveImagingFormat.bytes(progress.bytesDone)) of \(DriveImagingFormat.bytes(progress.totalBytes)) copied")
                            .monospacedDigit()
                            .accessibilityIdentifier("image-bytes-copied")
                        HStack(spacing: 24) {
                            Text("Speed: \(model.speed(at: context.date).map(DriveImagingFormat.speed) ?? "Calculating…")")
                            Text("Remaining: \(model.remaining(at: context.date).map(DriveImagingFormat.duration) ?? "Calculating…")")
                        }
                        .monospacedDigit()
                        .accessibilityElement(children: .combine)
                        Text(badBlocksLine(progress))
                            .accessibilityIdentifier("image-bad-blocks")
                    }
                    .font(.subheadline).foregroundStyle(.inkSecondary)
                }
                Text("Salvage only reads the drive. Unreadable sectors are retried in smaller pieces, then saved as zeros and listed in a file next to the image.")
                    .font(.subheadline).foregroundStyle(.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(model.isCancelling ? "Canceling…" : "Cancel") { model.cancel() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.isCancelling)
                    .accessibilityHint("Stops copying. The part copied so far stays in the image file.")
                    .accessibilityIdentifier("image-cancel")
            }
        }
    }

    private func refused(_ message: some View) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            message
            Text("Nothing was copied.").font(.subheadline).foregroundStyle(.inkSecondary)
            HStack {
                Spacer()
                Button("Close", action: onDone)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("image-close")
                Button("Choose Another Destination…", action: onChooseAgain)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("image-choose-again")
            }
        }
    }

    private func badBlocksLine(_ progress: ImagingProgress) -> String {
        guard progress.badRangeCount > 0 else { return "Unreadable: none so far" }
        return "Unreadable: \(DriveImagingFormat.areas(progress.badRangeCount)), \(DriveImagingFormat.bytes(progress.unreadableBytes)) (saved as zeros)"
    }

    private func percent(_ progress: ImagingProgress) -> Int {
        progress.totalBytes > 0 ? Int(Double(progress.bytesDone) / Double(progress.totalBytes) * 100) : 0
    }
}

/// What the run left behind: no celebration (DESIGN.md Recovery Summary), just the facts.
private struct ImagingSummaryView: View {
    let summary: DriveImagingSummary
    let onDone: () -> Void
    /// Bad ranges listed in the sheet; the full list is in the sidecar.
    private let listed = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(summary.title)
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("image-summary-title")
            Text(summary.note)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("image-summary-note")
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                row("Image", summary.imageURL.path)
                row("Copied", "\(DriveImagingFormat.bytes(summary.bytesCopied)) of \(DriveImagingFormat.bytes(summary.totalBytes)) in \(DriveImagingFormat.duration(summary.elapsed))")
                row("Unreadable", summary.badRanges.isEmpty ? "None"
                    : "\(DriveImagingFormat.areas(summary.badRanges.count)), \(DriveImagingFormat.bytes(summary.unreadableBytes))")
                if let sidecar = summary.sidecarURL { row("Bad-block list", sidecar.lastPathComponent) }
                if let sha = summary.sha256 { row("SHA-256", sha) }
            }
            .font(.subheadline)
            if let error = summary.sidecarError {
                Text("The bad-block list couldn't be saved: \(error)").font(.subheadline).foregroundStyle(.inkSecondary)
            }
            if !summary.badRanges.isEmpty { badRanges }
            HStack {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([summary.imageURL]) }
                    .accessibilityIdentifier("image-show-in-finder")
                Spacer()
                Button("Done", action: onDone)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("image-done")
                Button("Open Image") {
                    DiskImageLibrary.shared.open(summary.imageURL)
                    onDone()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(summary.bytesCopied == 0)
                .accessibilityHint("Lists the image under Disk images, ready to scan")
                .accessibilityIdentifier("image-open")
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.inkSecondary)
            Text(value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var badRanges: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Unreadable areas (byte offsets on the drive)").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(summary.badRanges.prefix(listed).enumerated()), id: \.offset) { _, range in
                        Text("\(range.offset)–\(range.end - 1) (\(DriveImagingFormat.bytes(range.length)))")
                            .monospacedDigit().textSelection(.enabled)
                    }
                    if summary.badRanges.count > listed {
                        Text("and \(summary.badRanges.count - listed) more, listed in \(summary.sidecarURL?.lastPathComponent ?? "the bad-block list")")
                            .foregroundStyle(.inkSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 140)
            .accessibilityIdentifier("image-bad-ranges")
        }
        .font(.subheadline)
    }
}
