import Dispatch
import Foundation
import SalvageCLIKit

// `salvage`: see docs/CLI.md. Ctrl-C cancels the running command; a file being written is
// removed, never left half-written, and the exit code is 130.
let arguments = Array(CommandLine.arguments.dropFirst())
let command = Task { await SalvageCLI.run(arguments: arguments) }

signal(SIGINT, SIG_IGN)
let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
interrupt.setEventHandler { command.cancel() }
interrupt.resume()

let code = await command.value
interrupt.cancel()
exit(code)
