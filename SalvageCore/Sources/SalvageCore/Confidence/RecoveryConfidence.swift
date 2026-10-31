import Foundation

/// How a file's bytes were found (AD-7).
public enum RecoveryMethod: Sendable, Equatable {
    /// Located through intact filesystem metadata (directory entry, MFT record, inode).
    case metadata
    /// Reconstructed from raw sectors by signature carving (AD-6, not built yet).
    case carved
}

/// Graduated evidence about a recovery (AD-7). Deliberately numeric rather than boolean so the
/// Medium/Low boundary can be tuned later without changing what producers report.
public struct RecoveryEvidence: Sendable, Equatable {
    /// Number of non-hole data runs the file's bytes occupy.
    public let fragmentCount: Int
    /// Likelihood, in `0...1`, that the file's bytes have been overwritten since it was lost.
    public let overwriteConfidence: Double
    public init(fragmentCount: Int, overwriteConfidence: Double) {
        self.fragmentCount = fragmentCount; self.overwriteConfidence = overwriteConfidence
    }
}

/// Recovery confidence shown in the File Browser (FR-12).
public enum RecoveryConfidence: Sendable, Equatable, CaseIterable {
    case high, medium, low

    public var displayName: String {
        switch self {
        case .high: "High"
        case .medium: "Medium"
        case .low: "Low"
        }
    }

    /// The single AD-7 scoring function; no other layer computes confidence.
    ///
    /// Floor rule: metadata-recovered is always High. Carved is never High, whatever its
    /// evidence: Medium when it is in one piece and probably not overwritten, otherwise Low.
    public static func assess(method: RecoveryMethod, evidence: RecoveryEvidence) -> RecoveryConfidence {
        switch method {
        case .metadata:
            return .high
        case .carved:
            // A NaN or out-of-range overwrite estimate is treated as untrustworthy, not as safe.
            let overwrite = evidence.overwriteConfidence
            guard overwrite.isFinite, overwrite >= 0 else { return .low }
            return evidence.fragmentCount <= 1 && overwrite < 0.5 ? .medium : .low
        }
    }
}

extension RecoveredFile {
    /// Every file a filesystem parser reports was found through intact metadata.
    public var recoveryMethod: RecoveryMethod { .metadata }

    /// True when the parser couldn't map the file's bytes, so it can't be previewed or recovered.
    public var isUnmapped: Bool { content == .unmapped }

    /// Evidence for AD-7. Live and deleted files from intact metadata both report no overwrite:
    /// deleted files are only reported after their clusters passed the free-space check.
    public var recoveryEvidence: RecoveryEvidence {
        let fragments: Int
        switch content {
        case .unmapped: fragments = 0
        case .resident: fragments = 1
        case .runs(let runs): fragments = runs.lazy.filter { $0.deviceOffset != nil }.count
        }
        return RecoveryEvidence(fragmentCount: fragments, overwriteConfidence: 0)
    }

    /// The file's recovery confidence, or nil when it can't be recovered at all (unmapped).
    public var recoveryConfidence: RecoveryConfidence? {
        isUnmapped ? nil : RecoveryConfidence.assess(method: recoveryMethod, evidence: recoveryEvidence)
    }

    /// The dashboard bucket for this file.
    public var category: FileCategory { FileCategory.classify(fileName: name) }
}
