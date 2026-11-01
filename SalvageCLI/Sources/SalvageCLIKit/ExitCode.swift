/// The documented exit codes (docs/CLI.md, "Exit codes"). Stable: scripts may depend on them.
public enum ExitCode: Int32, Sendable, CaseIterable {
    /// Done: the scan ran to the end, or every selected file was recovered intact.
    case success = 0
    /// The source couldn't be opened or read, or the destination couldn't be written at all.
    case failure = 1
    /// Bad command line: unknown command or option, missing argument, missing destination folder.
    case usage = 2
    /// Refused for safety: the startup disk, a destination on the source (or one whose device
    /// couldn't be determined), a device node given as an image path, a partition instead of a drive.
    case refused = 3
    /// Recovery finished with problems: some files couldn't be recovered, or the scan didn't run
    /// to the end so only the files found before it stopped were recovered.
    case partial = 4
    /// Recovery had nothing to copy: no recoverable file matched the selection.
    case nothingMatched = 5
    /// Interrupted (Ctrl-C). A file being written is removed, never left half-written.
    case interrupted = 130
}

/// Lets a command step fail with the code the command exits with.
extension ExitCode: Error {}
