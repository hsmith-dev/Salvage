import Foundation

/// Placeholder entry point for the Salvage domain engine.
///
/// `SalvageCore` is the hexagonal architecture's domain module (Architecture AD-1): it depends
/// on nothing but Foundation. Later Epic 1 stories populate the sibling `Entities/`, `Parsers/`,
/// `Carving/`, `Confidence/`, and `Ports/` directories with the recovery engine itself. This
/// file exists only so the package has a buildable, non-empty module before any domain code
/// lands -- no recovery logic, disk I/O, or UI belongs here (see spec-1-1 Boundaries).
public enum SalvageCore {
    /// A stable marker confirming the module compiled and linked successfully. Not part of any
    /// public API contract -- just a scaffold placeholder until real domain types exist.
    public static let scaffoldVersion = "0.0.0"
}
