import Foundation

// `@main` (rather than a top-level `main.swift`) deliberately, so this target can be imported
// with `@testable import` from the test target added alongside it -- a module containing
// top-level code in a file literally named `main.swift` cannot also be imported as a library.

@main
struct SpikeRawDeviceAccess {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        switch parseArguments(arguments) {
        case .help(let exitCode):
            printUsage()
            exit(exitCode)
        case .usageError(let message):
            print("ERROR: \(message)")
            printUsage()
            exit(64)
        case .list:
            listDevices()
        case .read(let path, let skipUnmount):
            performRead(path: path, skipUnmount: skipUnmount)
        }
    }
}
