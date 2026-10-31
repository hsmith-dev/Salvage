import Foundation

/// The harness's fully-parsed command line. Kept as a pure function (`parseArguments`) separate
/// from `exit(...)`/`print(...)` side effects so it has direct unit coverage.
enum ParsedCommand: Equatable {
    case help(exitCode: Int32)
    case list
    case read(path: String, skipUnmount: Bool)
    case usageError(message: String)
}

func parseArguments(_ arguments: [String]) -> ParsedCommand {
    if arguments.isEmpty {
        return .usageError(message: "no arguments given")
    }
    if arguments.contains("-h") || arguments.contains("--help") {
        return .help(exitCode: 0)
    }

    switch arguments[0] {
    case "--list":
        guard arguments.count == 1 else {
            return .usageError(message: "--list takes no further arguments (got: \(arguments.dropFirst().joined(separator: " ")))")
        }
        return .list

    case "--read":
        let rest = Array(arguments.dropFirst())
        // The path must be the very next argument, and must not itself look like a flag --
        // otherwise `--read --no-unmount` (path omitted) would silently treat "--no-unmount" as
        // the device path instead of producing a clear usage error.
        guard let path = rest.first, !path.hasPrefix("-") else {
            return .usageError(message: "--read requires a device path, e.g. --read /dev/rdisk6 (got: \(rest.first ?? "nothing"))")
        }
        let remaining = rest.dropFirst()
        let unrecognized = remaining.filter { $0 != "--no-unmount" }
        guard unrecognized.isEmpty else {
            return .usageError(message: "unrecognized argument(s) after --read <path>: \(unrecognized.joined(separator: " "))")
        }
        return .read(path: path, skipUnmount: remaining.contains("--no-unmount"))

    default:
        return .usageError(message: "unrecognized argument \"\(arguments[0])\"")
    }
}

func printUsage() {
    print(
        """
        spike-raw-device-access -- Epic 1 Story 1.2 FDA/raw-device-access spike harness.
        Disposable; not part of the shipping app. See
        _bmad-output/implementation-artifacts/spec-1-2-full-disk-access-raw-device-access-spike.md

        Usage:
          spike-raw-device-access --list
          spike-raw-device-access --read <path> [--no-unmount]

        --list            Enumerate attached whole disks via DiskArbitration (no Full Disk
                           Access required for this step).
        --read <path>     Unmount the device (AD-4 sequence) then attempt a raw open()/read()
                           on <path> (expects a raw node like /dev/rdisk6). Refuses outright if
                           <path> resolves to a disk hosting the live boot volume, including a
                           re-check immediately before open().
        --no-unmount      With --read: skip DADiskUnmount, to observe actual behavior while the
                           device remains mounted (I/O matrix row 3).
        -h, --help        Show this message.
        """
    )
}
