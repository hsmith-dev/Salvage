import Foundation
import SalvageCore

/// Placeholder entry point for the macOS disk-I/O adapter.
///
/// `SalvageDiskIO` is the hexagonal architecture's adapter module (Architecture AD-1): it
/// depends only on `SalvageCore`. Later Epic 1 stories add `RawBlockReader.swift`
/// (DiskArbitration + unbuffered `/dev/rdiskN` reads, AD-4) and `FileVaultUnlocker.swift`
/// (`diskutil` subprocess, AD-3) here. This file exists only so the package has a buildable,
/// non-empty module before any adapter code lands.
public enum SalvageDiskIO {
    /// A stable marker confirming this module compiled, linked, and can see `SalvageCore`. Not
    /// part of any public API contract -- just a scaffold placeholder.
    public static let scaffoldVersion = SalvageCore.scaffoldVersion
}
