import Darwin
import Foundation
import SalvageCore
import SalvageDiskIO

/// `salvage recover`: scan the source, select files, copy them with the app's engine.
///
/// Order of the safety steps (the same rules as the app's `RecoveryCoordinator`):
/// 1. The destination must be an existing folder; the tool never creates it.
/// 2. A drive is looked up in the device tree and refused if it is the startup disk.
/// 3. The destination is checked against the source **before the source is opened** (opening a
///    drive unmounts it): a folder on the same device -- or one whose device can't be determined
///    -- is refused and nothing is read or written.
/// 4. After the scan, the destination is checked again right before writing, and the engine then
///    confirms the folder it actually opened is on the checked volume (`fstatfs`).
/// 5. The engine never overwrites: every file is streamed to a `.partial` name created with
///    O_EXCL and published under a free name (" (2)" ...), inside a new recovery folder.
enum RecoverCommand {
    static let blockedMessage = "This folder is on the drive you're recovering from. Choose a folder on a different drive."
    static let undeterminedMessage = "Salvage couldn't confirm this folder is on a different drive from the one you're recovering from, so it was refused. Choose a folder on another drive."

    static func run(_ options: RecoverOptions, environment: CLIEnvironment, output: CLIOutput) async -> ExitCode {
        // 1. Destination folder.
        let destination = URL(fileURLWithPath: options.destination, isDirectory: true).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            output.message("salvage: --to \(options.destination) isn't an existing folder. Create it first, on a different drive from the source.")
            return .usage
        }

        // 2. Source lookup.
        var device: BlockDevice?
        if case .device(let name) = options.source {
            switch await SalvageCLI.resolveDevice(name, environment: environment, output: output) {
            case .success(let found): device = found
            case .failure(let code): return code
            }
        }
        var imageURL: URL?
        if case .image(let path) = options.source {
            // Opening the image first refuses device nodes and encoded images before any check;
            // it is read-only and changes nothing.
            imageURL = URL(fileURLWithPath: path).standardizedFileURL
        }

        // 3. Destination against the source, before the source is opened.
        let assess: @Sendable () -> DestinationAssessment = { [device, imageURL] in
            if let device { return environment.deviceDestination(destination, device) }
            if let imageURL { return environment.imageDestination(destination, imageURL) }
            return DestinationAssessment(verdict: .undetermined, mountSource: nil)
        }
        var source: OpenedSource?
        if imageURL != nil {
            switch await SalvageCLI.open(options.source, device: nil, environment: environment, output: output) {
            case .success(let opened): source = opened
            case .failure(let code): return code
            }
        }
        let first = await offMain(assess)
        guard first.verdict.isSafe else {
            await source?.close()
            refuse(first.verdict, output: output)
            return .refused
        }
        if source == nil {
            switch await SalvageCLI.open(options.source, device: device, environment: environment, output: output) {
            case .success(let opened): source = opened
            case .failure(let code): return code
            }
        }
        guard let source else { return .failure }

        // Scan.
        let progress = ProgressLine(output: output, label: "Scanning", enabled: !options.quiet)
        let outcome = await ScanRunner.run(source, progress: progress, onFile: { _ in true })
        if outcome.cancelled {
            await source.close()
            output.message("Interrupted before recovery started. Nothing was written.")
            return .interrupted
        }
        for notice in outcome.notices { output.message("Note: \(notice.text)") }
        let scanIncomplete = !outcome.completed
        if let error = outcome.error {
            output.message("salvage: the scan stopped: \(error.description)")
            if outcome.files.isEmpty { await source.close(); return .failure }
            output.message("Recovering the files it found before it stopped.")
        }

        // Selection.
        let (selected, reconstructedLeftOut) = select(outcome.files, options: options)
        guard !selected.isEmpty else {
            await source.close()
            var text = "Nothing to recover: no recoverable file matched."
            if reconstructedLeftOut > 0 {
                text += " \(reconstructedLeftOut) reconstructed files matched; add --include-reconstructed to recover them."
            }
            output.message(text)
            return .nothingMatched
        }
        if reconstructedLeftOut > 0 {
            output.message("\(reconstructedLeftOut) reconstructed files left out (add --include-reconstructed to include them).")
        }

        // 4. Re-check right before writing; the engine confirms the folder it opens.
        let checked = await offMain(assess)
        guard checked.verdict.isSafe else {
            await source.close()
            refuse(checked.verdict, output: output)
            return .refused
        }

        let engine = RecoveryEngine(content: FileContentReader(reader: source.reader))
        let total = selected.reduce(Int64(0)) { $0 + max(0, $1.sizeBytes) }
        let copyProgress = ProgressLine(output: output, label: "Recovering", enabled: !options.quiet)
        let rootName = rootFolderName(source: source.displayName, date: environment.now())
        let result = await engine.run(files: selected, rootName: rootName, in: destination, checked: checked) { update in
            copyProgress.update(done: update.bytesDone, total: max(total, 1),
                                detail: "\(update.filesFinished)/\(selected.count) files")
        }
        copyProgress.finish()
        await source.close()

        switch result {
        case .failure(.destinationUnsafe):
            refuse(.sameDevice, output: output)
            return .refused
        case .failure(.destinationUnavailable(let reason)):
            output.message("salvage: couldn't write to \(destination.path): \(reason)")
            return .failure
        case .success(let summary):
            report(summary, json: options.json, output: output)
            if summary.cancelled { return .interrupted }
            if !summary.failed.isEmpty || scanIncomplete { return .partial }
            return .success
        }
    }

    /// The files to copy, and how many matching reconstructed files were left out. Only
    /// recoverable files (a mapping that covers the file) are selected, as in the app.
    static func select(_ files: [RecoveredFile], options: RecoverOptions) -> (files: [RecoveredFile], reconstructedLeftOut: Int) {
        let matching = files.filter { file in
            guard !file.isUnmapped else { return false }
            switch options.selection {
            case .all: return true
            case .paths(let globs): return globs.contains { glob in matches(glob: glob, path: file.path) }
            case .partitions(let offsets): return offsets.contains(file.sourceMetadata.volumeOffset)
            }
        }
        let reconstructed = matching.filter { $0.recoveryMethod == .carved }
        let base = matching.filter { $0.recoveryMethod != .carved }
        // Folder records first, reconstructed files after them, as the app's sheet orders them.
        return options.includeReconstructed ? (base + reconstructed, 0) : (base, reconstructed.count)
    }

    /// `fnmatch(3)` without FNM_PATHNAME, so `*` also crosses folders: `/DCIM/*` matches every
    /// file under /DCIM. A glob without a leading slash also matches relative to the root.
    static func matches(glob: String, path: String) -> Bool {
        let pattern = glob.hasPrefix("/") || glob.hasPrefix("*") ? glob : "/" + glob
        return fnmatch(pattern, path, 0) == 0
    }

    static func refuse(_ verdict: DestinationVerdict, output: CLIOutput) {
        output.message("salvage: refused: " + (verdict == .sameDevice ? blockedMessage : undeterminedMessage))
        output.message("Nothing was written.")
    }

    static func report(_ summary: RecoverySummary, json: Bool, output: CLIOutput) {
        for copy in summary.written {
            if json {
                output.line(JSONLine.encode(["type": "recovered", "source": copy.sourcePath, "destination": copy.url.path,
                                             "size": copy.bytes, "sha256": copy.sha256]))
            } else {
                output.line(["recovered", copy.sourcePath, copy.url.path, String(copy.bytes), copy.sha256].joined(separator: "\t"))
            }
        }
        for failure in summary.failed {
            if json {
                output.line(JSONLine.encode(["type": "failed", "source": failure.sourcePath, "name": failure.name, "reason": failure.reason]))
            } else {
                output.line(["failed", failure.sourcePath, failure.reason].joined(separator: "\t"))
            }
        }
        if json {
            output.line(JSONLine.encode(["type": "summary", "folder": summary.root.path, "selected": summary.selectedCount,
                                         "recovered": summary.written.count, "failed": summary.failed.count,
                                         "notAttempted": summary.notAttempted, "bytesWritten": summary.bytesWritten,
                                         "cancelled": summary.cancelled]))
        }
        var text = "Recovered \(summary.written.count) of \(summary.selectedCount) files (\(ProgressLine.bytes(summary.bytesWritten)) written) into \(summary.root.path)"
        if !summary.failed.isEmpty { text += "; \(summary.failed.count) couldn't be recovered" }
        if summary.notAttempted > 0 { text += "; \(summary.notAttempted) not attempted (interrupted)" }
        output.message(text + ".")
    }

    /// "Salvage Recovery <source> <date>", fitted to one folder name as the app's
    /// `RecoveryCoordinator.rootFolderName(device:date:)` does.
    static func rootFolderName(source: String, date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let label = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = " \(formatter.string(from: date))"
        let cleaned = RecoveryPaths.clean(label.isEmpty ? "Drive" : label)
        let budget = RecoveryPaths.maxComponentBytes - ("Salvage Recovery " + suffix).utf8.count
        let cut = RecoveryPaths.prefix(cleaned, maxBytes: max(1, budget)).trimmingCharacters(in: .whitespaces)
        return "Salvage Recovery " + (cut.isEmpty ? "_" : cut) + suffix
    }

    /// The safety checks run subprocesses (`diskutil`, `hdiutil`); keep them off the cooperative pool.
    private static func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: work()) }
        }
    }
}
