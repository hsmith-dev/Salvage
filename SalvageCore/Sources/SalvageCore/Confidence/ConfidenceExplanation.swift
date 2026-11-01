import Foundation

/// Plain-language reasons for a recovery confidence (spec-tech-batch-7 §C, AD-7).
///
/// Nothing here scores a file. The level always comes from `RecoveryConfidence.assess`, and the
/// reasons a carved file isn't rated higher come from asking `assess` again with one piece of
/// evidence improved: if the level rises when the file is treated as being in one piece, its
/// fragmentation is a reason, and likewise for the overwrite estimate. No threshold is repeated
/// here, so retuning `assess` changes the explanation with it.
///
/// The sentence describes evidence as it was reported. It never claims more than that evidence
/// says: a deleted file with no overwrite estimate "has no sign of being overwritten", and is not
/// said to be intact.
public enum ConfidenceExplanation {
    /// One plain sentence that starts with the confidence level, such as "High: found through
    /// the filesystem's own records; its data is in one piece."
    public static func sentence(method: RecoveryMethod, evidence: RecoveryEvidence,
                                isDeleted: Bool, isPartial: Bool) -> String {
        let level = RecoveryConfidence.assess(method: method, evidence: evidence)
        switch method {
        case .metadata:
            return metadataSentence(level, evidence, isDeleted: isDeleted, isPartial: isPartial)
        case .carved:
            return carvedSentence(level, evidence, isPartial: isPartial)
        }
    }

    /// The fragment count in words, for the details panel.
    public static func fragmentsDescription(_ evidence: RecoveryEvidence, method: RecoveryMethod) -> String {
        switch evidence.fragmentCount {
        case ...0: return "None of its data is stored on the device; it recovers as empty or zero-filled."
        case 1: return "In one piece."
        case let count:
            switch method {
            case .metadata: return "In \(count.formatted()) pieces. The filesystem records where each one is."
            case .carved: return "In \(count.formatted()) pieces that Salvage joined itself. No filesystem record says how they fit."
            }
        }
    }

    /// The overwrite estimate in words, for the details panel.
    public static func overwriteDescription(_ evidence: RecoveryEvidence) -> String {
        switch Overwrite(evidence.overwriteConfidence) {
        case .none: return "No sign that its data was overwritten."
        case .some(let percent): return "Salvage estimates a \(percent) chance that some of its data was overwritten."
        case .certain: return "Part of its data was almost certainly overwritten."
        case .unusable: return "Salvage has no usable estimate of whether its data was overwritten."
        }
    }

    // MARK: Metadata

    private static func metadataSentence(_ level: RecoveryConfidence, _ evidence: RecoveryEvidence,
                                         isDeleted: Bool, isPartial: Bool) -> String {
        var clauses = [pieces(evidence, method: .metadata)]
        switch Overwrite(evidence.overwriteConfidence) {
        case .none: if isDeleted { clauses.append("nothing suggests it was overwritten") }
        case .some(let percent): clauses.append("Salvage estimates a \(percent) chance some of it was overwritten")
        case .certain: clauses.append("part of it was almost certainly overwritten")
        case .unusable: clauses.append("Salvage has no usable estimate of whether it was overwritten")
        }
        let source = isDeleted ? "found through the filesystem's own records of this deleted file"
                               : "found through the filesystem's own records"
        return "\(level.displayName): \(source); \(list(clauses))\(isPartial ? ", but it may be incomplete" : "")."
    }

    // MARK: Carved

    private static func carvedSentence(_ level: RecoveryConfidence, _ evidence: RecoveryEvidence,
                                       isPartial: Bool) -> String {
        let overwrite = Overwrite(evidence.overwriteConfidence)
        let best = RecoveryConfidence.assess(method: .carved, evidence: RecoveryEvidence(fragmentCount: 1, overwriteConfidence: 0))
        if level == best {
            // Nothing in the evidence holds it back.
            var clauses = [pieces(evidence, method: .carved)]
            if case .some(let percent) = overwrite { clauses.append("Salvage estimates a \(percent) chance some of it was overwritten") }
            clauses.append(isPartial ? "the end of the file couldn't be confirmed, so it may be incomplete"
                                     : "its end was confirmed")
            return "\(level.displayName): reconstructed from raw data, not found through the filesystem's records, "
                + "so it can't be rated higher; \(list(clauses))."
        }

        // Which evidence holds it back: each reason, improved on its own, raises the level.
        // When neither does alone (both are needed), both are reasons.
        let fragmented = evidence.fragmentCount > 1 && raises(evidence, fragmentCount: 1, from: level)
        let overwritten = overwrite != .none && raises(evidence, overwrite: 0, from: level)
        let both = !fragmented && !overwritten
            && RecoveryConfidence.assess(method: .carved, evidence: RecoveryEvidence(fragmentCount: 1, overwriteConfidence: 0)) != level
        var reasons: [String] = []
        if fragmented || (both && evidence.fragmentCount > 1) {
            reasons.append("its data is in \(evidence.fragmentCount.formatted()) pieces that Salvage joined itself, "
                           + "with no filesystem record of how they fit")
        }
        var endExplained = false
        if overwritten || (both && overwrite != .none) {
            if isPartial {
                reasons.append("the end of the file couldn't be confirmed")
                endExplained = true
            }
            switch overwrite {
            case .none: break
            case .some(let percent): if !isPartial { reasons.append("Salvage estimates a \(percent) chance some of it was overwritten") }
            case .certain: reasons.append("part of it was almost certainly overwritten")
            case .unusable: reasons.append("Salvage has no usable estimate of whether it was overwritten")
            }
        }
        if isPartial && !endExplained { reasons.append("the end of the file couldn't be confirmed") }
        if reasons.isEmpty { reasons.append(pieces(evidence, method: .carved)) }
        var sentence = "\(level.displayName): reconstructed from raw data\(reasons.count == 1 ? ", and" : ";") \(list(reasons))"
        if !isPartial && fragmented && !overwritten { sentence += "; its end was confirmed" }
        return sentence + "."
    }

    /// True when `assess` rates the file higher with the given evidence changed.
    private static func raises(_ evidence: RecoveryEvidence, fragmentCount: Int? = nil, overwrite: Double? = nil,
                               from level: RecoveryConfidence) -> Bool {
        let changed = RecoveryEvidence(fragmentCount: fragmentCount ?? evidence.fragmentCount,
                                       overwriteConfidence: overwrite ?? evidence.overwriteConfidence)
        return rank(RecoveryConfidence.assess(method: .carved, evidence: changed)) > rank(level)
    }

    private static func rank(_ level: RecoveryConfidence) -> Int {
        switch level {
        case .low: 0
        case .medium: 1
        case .high: 2
        }
    }

    // MARK: Words

    private static func pieces(_ evidence: RecoveryEvidence, method: RecoveryMethod) -> String {
        switch evidence.fragmentCount {
        case ...0: return "it has no data stored on the device, so it recovers as empty or zero-filled"
        case 1: return "its data is in one piece"
        case let count:
            switch method {
            case .metadata: return "its data is in \(count.formatted()) pieces, all mapped by the filesystem"
            case .carved: return "its data is in \(count.formatted()) pieces that Salvage joined itself"
            }
        }
    }

    /// "a, b and c".
    private static func list(_ clauses: [String]) -> String {
        switch clauses.count {
        case 0: return ""
        case 1: return clauses[0]
        default: return clauses.dropLast().joined(separator: ", ") + " and " + clauses[clauses.count - 1]
        }
    }

    /// The overwrite estimate as reported, sorted only into what can honestly be said about it.
    private enum Overwrite: Equatable {
        case none
        /// Strictly between 0 and 1, as a percentage ("60%").
        case some(String)
        case certain
        /// NaN, infinite, negative or above 1: not a probability.
        case unusable

        init(_ value: Double) {
            guard value.isFinite, value >= 0, value <= 1 else { self = .unusable; return }
            if value == 0 { self = .none; return }
            if value == 1 { self = .certain; return }
            let percent = (value * 100).rounded()
            if percent < 1 { self = .some("less than 1%") } else if percent > 99 { self = .some("over 99%") } else { self = .some("\(Int(percent))%") }
        }
    }
}

extension RecoveredFile {
    /// The one-sentence reason for this file's `recoveryConfidence`, or why it can't be recovered.
    public var confidenceExplanation: String {
        guard !isUnmapped else {
            if case .unmapped = content {
                return "Can't be recovered: Salvage couldn't locate this file's contents on the device."
            }
            return "Can't be recovered: the filesystem's records don't account for all of this file's data."
        }
        return ConfidenceExplanation.sentence(method: recoveryMethod, evidence: recoveryEvidence,
                                              isDeleted: isDeleted, isPartial: isPartial)
    }
}
