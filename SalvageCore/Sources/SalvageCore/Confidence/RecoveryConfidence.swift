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
    /// True when the file can't be previewed or recovered: the parser couldn't map its bytes, or
    /// the mapping it reported fails `FileContentReader.validate`'s size-coverage rules (see
    /// `mappingCoversSize`), which the reader would reject at read time anyway.
    public var isUnmapped: Bool { !mappingCoversSize }

    /// Pure mirror of `FileContentReader.validate`'s coverage rules, without the device-bounds
    /// check (that needs a reader): resident data must hold `sizeBytes`; runs must have
    /// non-negative lengths and offsets, must not overflow when summed, and must cover
    /// `sizeBytes` (a zero-byte file needs no coverage). Keep in step with `validate`.
    public var mappingCoversSize: Bool {
        switch content {
        case .unmapped:
            return false
        case .resident(let data):
            return Int64(data.count) >= sizeBytes
        case .runs(let runs), .encryptedRuns(let runs, _):
            var covered: Int64 = 0
            for run in runs {
                guard run.length >= 0 else { return false }
                if let offset = run.deviceOffset, offset < 0 { return false }
                let (sum, overflow) = covered.addingReportingOverflow(run.length)
                guard !overflow else { return false }
                covered = sum
                if covered >= sizeBytes { return true }
            }
            return covered >= sizeBytes || sizeBytes == 0
        }
    }

    /// Evidence for AD-7. The fragment count comes from the mapping; the overwrite estimate is
    /// the producer's (`overwriteConfidence`, 0 for metadata parsers).
    public var recoveryEvidence: RecoveryEvidence {
        let fragments: Int
        switch content {
        case .unmapped: fragments = 0
        case .resident: fragments = 1
        // NTFS resident data a saved scan keeps as runs inside its own MFT record (spec-tech-batch-7
        // §B): split only around the record's fixup bytes, it is one piece of one record, as before saving.
        case .runs where liesInsideOwnNTFSRecord: fragments = 1
        case .runs(let runs), .encryptedRuns(let runs, _): fragments = runs.lazy.filter { $0.deviceOffset != nil }.count
        }
        return RecoveryEvidence(fragmentCount: fragments, overwriteConfidence: overwriteConfidence)
    }

    /// True for an NTFS file whose runs all lie within the largest MFT record size past its own
    /// record's start. A non-resident file's data is in clusters `$MFT` doesn't own, so it can't
    /// start inside its own record; only resident data a saved scan located there does.
    var liesInsideOwnNTFSRecord: Bool {
        guard sourceMetadata.filesystem == .ntfs, recoveryMethod == .metadata, case .runs(let runs) = content,
              !runs.isEmpty else { return false }
        let start = sourceMetadata.recordOffset
        guard start >= 0, start <= Int64.max - 65536 else { return false }
        return runs.allSatisfy { run in
            guard let offset = run.deviceOffset, offset >= start, run.length >= 0 else { return false }
            return run.length <= start + 65536 - offset
        }
    }

    /// The file's recovery confidence, or nil when it can't be recovered at all (unmapped, or a
    /// mapping that doesn't cover the file).
    public var recoveryConfidence: RecoveryConfidence? {
        isUnmapped ? nil : RecoveryConfidence.assess(method: recoveryMethod, evidence: recoveryEvidence)
    }

    /// The dashboard bucket for this file.
    public var category: FileCategory { FileCategory.classify(fileName: name) }
}
