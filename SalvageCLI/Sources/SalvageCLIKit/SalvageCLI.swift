import Darwin
import Foundation
import SalvageCore
import SalvageDiskIO

/// The `salvage` command-line tool (spec-tech-batch-6 §C). See docs/CLI.md.
public enum SalvageCLI {
    /// Kept equal to the app's MARKETING_VERSION in project.yml (a test checks).
    public static let version = "1.0.0"

    /// Runs one command line (without the program name) and returns the exit code.
    public static func run(arguments: [String], output: CLIOutput = .standard) async -> Int32 {
        await run(arguments: arguments, environment: .live, output: output).rawValue
    }

    static func run(arguments: [String], environment: CLIEnvironment, output: CLIOutput) async -> ExitCode {
        let command: Command
        do { command = try ArgumentParser.parse(arguments) } catch let refused as RefusedArgument {
            output.message("salvage: \(refused)")
            return .refused
        } catch {
            output.message("salvage: \(error)")
            output.message("")
            output.message(ArgumentParser.usage)
            return .usage
        }
        switch command {
        case .help:
            output.line(ArgumentParser.usage)
            return .success
        case .version:
            output.line("salvage \(version)")
            return .success
        case .list(let json):
            return await ListCommand.run(json: json, environment: environment, output: output)
        case .scan(let options):
            return await ScanCommand.run(options, environment: environment, output: output)
        case .recover(let options):
            return await RecoverCommand.run(options, environment: environment, output: output)
        }
    }

    /// A drive from the device tree, by BSD name, refusing the startup disk before anything opens it.
    static func resolveDevice(_ name: String, environment: CLIEnvironment, output: CLIOutput) async -> Result<BlockDevice, ExitCode> {
        let devices: [BlockDevice]
        do { devices = try await environment.listDevices(false) } catch {
            output.message("salvage: couldn't list drives: \(error)")
            return .failure(.failure)
        }
        guard let device = devices.first(where: { $0.bsdName == name }) else {
            let inside = devices.first { device in PartitionTree.flatten(device.partitions).contains { $0.bsdName.hasPrefix(name + "s") } }
            if let inside {
                output.message("salvage: \(name) is a container inside \(inside.bsdName). Salvage scans whole drives: use \(inside.bsdName).")
                return .failure(.refused)
            }
            output.message("salvage: no drive named \(name). Run `salvage list` to see the drives.")
            return .failure(.failure)
        }
        guard !device.isBootVolume else {
            output.message("salvage: refused: \(device.bsdName) is your startup disk, which can't be scanned while macOS is running from it.")
            return .failure(.refused)
        }
        return .success(device)
    }

    /// Opens the source; a device has already passed `resolveDevice`.
    static func open(_ source: SourceArgument, device: BlockDevice?, environment: CLIEnvironment,
                     output: CLIOutput) async -> Result<OpenedSource, ExitCode> {
        do {
            switch source {
            case .image(let path):
                return .success(try environment.openImage(path))
            case .device:
                guard let device else { return .failure(.failure) }
                if !device.partitions.isEmpty {
                    output.message("Unmounting \(device.bsdName)'s volumes so it can be read (the drive stays connected and is never written).")
                }
                return .success(try await environment.openDevice(device))
            }
        } catch let error as ImageOpenError {
            output.message("salvage: \(error)")
            switch error {
            case .deviceNode, .notReadOnly: return .failure(.refused)
            default: return .failure(.failure)
            }
        } catch let error as ScanError {
            output.message("salvage: \(error.description)")
            if case .unsafeTarget = error { return .failure(.refused) }
            return .failure(.failure)
        } catch {
            output.message("salvage: \(error)")
            return .failure(.failure)
        }
    }
}

enum PartitionTree {
    static func flatten(_ partitions: [DevicePartition]) -> [DevicePartition] {
        partitions.flatMap { [$0] + flatten($0.children) }
    }
}

// MARK: - list

enum ListCommand {
    static func run(json: Bool, environment: CLIEnvironment, output: CLIOutput) async -> ExitCode {
        let devices: [BlockDevice]
        do { devices = try await environment.listDevices(true) } catch {
            output.message("salvage: couldn't list drives: \(error)")
            return .failure
        }
        if json {
            for device in devices { output.line(JSONLine.encode(object(device))) }
            return .success
        }
        if devices.isEmpty { output.message("No drives found.") }
        for line in lines(devices) { output.line(line) }
        return .success
    }

    static func lines(_ devices: [BlockDevice]) -> [String] {
        var lines: [String] = []
        for device in devices {
            var flags = [device.isInternal ? "internal" : "external"]
            if device.isBootVolume { flags.append("startup disk, can't be scanned") }
            if let locked = device.encryptedVolumeName ?? device.encryptedVolumeUUID { flags.append("locked: \(locked)") }
            lines.append("\(device.bsdName)  \(device.displayName)  \(ProgressLine.bytes(device.sizeBytes))  (\(flags.joined(separator: ", ")))")
            func walk(_ partitions: [DevicePartition], depth: Int) {
                for partition in partitions {
                    var text = String(repeating: "   ", count: depth) + "└ \(partition.bsdName)  \(partition.displayName)  \(partition.formatName)"
                    if let size = partition.sizeBytes { text += "  \(ProgressLine.bytes(size))" }
                    if let offset = partition.offsetBytes { text += "  at offset \(offset)" }
                    lines.append(text)
                    walk(partition.children, depth: depth + 1)
                }
            }
            walk(device.partitions, depth: 1)
        }
        return lines
    }

    static func object(_ device: BlockDevice) -> [String: Any] {
        func partition(_ p: DevicePartition) -> [String: Any] {
            ["bsdName": p.bsdName, "name": p.displayName, "format": p.formatName,
             "size": p.sizeBytes.map { $0 as Any } ?? NSNull(), "offset": p.offsetBytes.map { $0 as Any } ?? NSNull(),
             "children": p.children.map(partition)]
        }
        return ["type": "device", "bsdName": device.bsdName, "name": device.displayName, "size": device.sizeBytes,
                "internal": device.isInternal, "startupDisk": device.isBootVolume,
                "lockedVolume": (device.encryptedVolumeName ?? device.encryptedVolumeUUID).map { $0 as Any } ?? NSNull(),
                "partitions": device.partitions.map(partition)]
    }
}

// MARK: - scan

enum ScanCommand {
    static func run(_ options: ScanOptions, environment: CLIEnvironment, output: CLIOutput) async -> ExitCode {
        var device: BlockDevice?
        if case .device(let name) = options.source {
            switch await SalvageCLI.resolveDevice(name, environment: environment, output: output) {
            case .success(let found): device = found
            case .failure(let code): return code
            }
        }
        let source: OpenedSource
        switch await SalvageCLI.open(options.source, device: device, environment: environment, output: output) {
        case .success(let opened): source = opened
        case .failure(let code): return code
        }
        let progress = ProgressLine(output: output, label: "Scanning", enabled: !options.quiet)
        var shown = 0
        let outcome = await ScanRunner.run(source, progress: progress, onFile: { file in
            guard !options.deletedOnly || file.isDeleted, options.format.matches(file) else { return true }
            if options.json {
                output.line(JSONLine.encode(JSONLine.file(file)))
            } else {
                output.line(humanLine(file))
            }
            shown += 1
            if let limit = options.limit, shown >= limit { return false }
            return true
        }, onLostPartition: { partition in
            if options.json { output.line(JSONLine.encode(JSONLine.lostPartition(partition))) }
        })
        await source.close()
        for notice in outcome.notices {
            if options.json { output.line(JSONLine.encode(JSONLine.notice(notice))) } else { output.message("Note: \(notice.text)") }
        }
        summarize(outcome, shown: shown, output: output)
        if outcome.cancelled { output.message("Scan interrupted."); return .interrupted }
        if outcome.stoppedEarly { return .success }
        if let error = outcome.error { output.message("salvage: the scan stopped: \(error.description)"); return .failure }
        return outcome.completed ? .success : .failure
    }

    /// `<live|deleted|rebuilt>  <size>  <confidence>  <path>`, tab-separated for `cut`/`awk`.
    static func humanLine(_ file: RecoveredFile) -> String {
        let state = file.recoveryMethod == .carved ? "rebuilt" : (file.isDeleted ? "deleted" : "live")
        let confidence = file.recoveryConfidence?.displayName.lowercased() ?? "unrecoverable"
        return [state, String(file.sizeBytes), confidence + (file.isPartial ? ",partial" : ""), file.path].joined(separator: "\t")
    }

    static func summarize(_ outcome: ScanOutcome, shown: Int, output: CLIOutput) {
        let deleted = outcome.files.filter(\.isDeleted).count
        let carved = outcome.files.filter { $0.recoveryMethod == .carved }.count
        output.message("Found \(outcome.files.count) files (\(deleted) deleted, \(carved) reconstructed); \(shown) shown.")
        // Per-volume counts, with the offsets `recover --partition` takes.
        var volumes: [Int64: (format: String, count: Int)] = [:]
        for file in outcome.files {
            let key = file.sourceMetadata.volumeOffset
            let format = file.sourceMetadata.filesystem == .carved ? volumes[key]?.format ?? "reconstructed" : file.sourceMetadata.filesystem.rawValue
            volumes[key] = (format, (volumes[key]?.count ?? 0) + 1)
        }
        for offset in volumes.keys.sorted() {
            let volume = volumes[offset]!
            output.message("  volume at offset \(offset) (\(volume.format)): \(volume.count) files")
        }
        for partition in outcome.lostPartitions {
            output.message("  lost partition at offset \(partition.offset): \(partition.formatName), \(ProgressLine.bytes(partition.sizeBytes))")
        }
        for volume in outcome.lockedVolumes {
            output.message("Note: \(volume) is encrypted (FileVault) and locked; the command-line tool can't unlock it, so its files weren't listed. Use the Salvage app to unlock it.")
        }
    }
}
