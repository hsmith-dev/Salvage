import Foundation
import Testing
@testable import SalvageCore

@Suite("Confidence explanation (spec-tech-batch-7 §C, AD-7)")
struct ConfidenceExplanationTests {
    static let fragmentCounts = [0, 1, 2, 5]
    static let overwrites: [Double] = [0, 0.003, 0.3, 0.4999, 0.5, 0.6, 0.996, 1, 1.5, -0.1, .nan, .infinity]

    func sentence(_ method: RecoveryMethod, _ fragments: Int, _ overwrite: Double,
                  deleted: Bool = false, partial: Bool = false) -> String {
        ConfidenceExplanation.sentence(method: method, evidence: RecoveryEvidence(fragmentCount: fragments, overwriteConfidence: overwrite),
                                       isDeleted: deleted, isPartial: partial)
    }

    // MARK: Exact sentences for the cases scans produce

    @Test func liveFilesystemFile() {
        #expect(sentence(.metadata, 1, 0)
                == "High: found through the filesystem's own records; its data is in one piece.")
    }

    @Test func deletedFilesystemFileNeverClaimsToBeIntact() {
        #expect(sentence(.metadata, 1, 0, deleted: true)
                == "High: found through the filesystem's own records of this deleted file; its data is in one piece and nothing suggests it was overwritten.")
    }

    @Test func fragmentedFilesystemFileIsStillHigh() {
        #expect(sentence(.metadata, 3, 0)
                == "High: found through the filesystem's own records; its data is in 3 pieces, all mapped by the filesystem.")
    }

    @Test func emptyFilesystemFile() {
        #expect(sentence(.metadata, 0, 0)
                == "High: found through the filesystem's own records; it has no data stored on the device, so it recovers as empty or zero-filled.")
    }

    @Test func validatedCarve() {
        #expect(sentence(.carved, 1, 0)
                == "Medium: reconstructed from raw data, not found through the filesystem's records, so it can't be rated higher; its data is in one piece and its end was confirmed.")
    }

    @Test func carveCutShort() {
        // The engine's cut-short carves: partial with 0.6 (a limit, the next header, the extent's
        // end, an untrusted size) or 1.0 (a claimed run, an inconsistent structure).
        #expect(sentence(.carved, 1, 0.6, partial: true)
                == "Low: reconstructed from raw data, and the end of the file couldn't be confirmed.")
        #expect(sentence(.carved, 1, 1, partial: true)
                == "Low: reconstructed from raw data; the end of the file couldn't be confirmed and part of it was almost certainly overwritten.")
    }

    @Test func reassembledJPEG() {
        #expect(sentence(.carved, 2, SignatureCarver.joinedOverwrite)
                == "Low: reconstructed from raw data, and its data is in 2 pieces that Salvage joined itself, with no filesystem record of how they fit; its end was confirmed.")
    }

    @Test func untrustworthyEstimate() {
        #expect(sentence(.carved, 1, .nan)
                == "Low: reconstructed from raw data, and Salvage has no usable estimate of whether it was overwritten.")
    }

    @Test func bothReasonsNeeded() {
        #expect(sentence(.carved, 3, 0.7)
                == "Low: reconstructed from raw data; its data is in 3 pieces that Salvage joined itself, with no filesystem record of how they fit and Salvage estimates a 70% chance some of it was overwritten.")
    }

    @Test func partialMediumCarveSaysItMayBeIncomplete() {
        #expect(sentence(.carved, 1, 0.2, partial: true)
                == "Medium: reconstructed from raw data, not found through the filesystem's records, so it can't be rated higher; its data is in one piece, Salvage estimates a 20% chance some of it was overwritten and the end of the file couldn't be confirmed, so it may be incomplete.")
    }

    @Test func percentagesAtTheEdges() {
        #expect(sentence(.carved, 1, 0.003).contains("less than 1% chance"))
        #expect(sentence(.carved, 1, 0.996).contains("over 99% chance"))
    }

    // MARK: Every method/evidence combination

    @Test(arguments: [RecoveryMethod.metadata, .carved])
    func everyCombinationIsTrueToItsEvidence(method: RecoveryMethod) {
        for fragments in Self.fragmentCounts {
            for overwrite in Self.overwrites {
                for deleted in [false, true] {
                    for partial in [false, true] {
                        let evidence = RecoveryEvidence(fragmentCount: fragments, overwriteConfidence: overwrite)
                        let level = RecoveryConfidence.assess(method: method, evidence: evidence)
                        let text = sentence(method, fragments, overwrite, deleted: deleted, partial: partial)
                        let label = "\(method) f=\(fragments) o=\(overwrite) d=\(deleted) p=\(partial): \(text)"
                        let usable = overwrite.isFinite && overwrite >= 0 && overwrite <= 1

                        // The level is assess's, never re-derived.
                        #expect(text.hasPrefix("\(level.displayName): "), "\(label)")
                        #expect(text.hasSuffix("."), "\(label)")
                        #expect(!text.contains("  ") && !text.contains(",,") && !text.contains("; ;") && !text.contains(" ."), "\(label)")
                        #expect(text == sentence(method, fragments, overwrite, deleted: deleted, partial: partial), "deterministic")

                        // How it was found.
                        switch method {
                        case .metadata:
                            #expect(text.contains("found through the filesystem's own records"), "\(label)")
                            #expect(!text.contains("reconstructed"), "\(label)")
                            #expect(text.contains("deleted file") == deleted, "\(label)")
                        case .carved:
                            #expect(text.contains("reconstructed from raw data"), "\(label)")
                            #expect(!text.contains("deleted"), "\(label)")
                        }

                        // Pieces: "one piece" only when it is.
                        if fragments == 1, method == .metadata || level == .medium { #expect(text.contains("in one piece"), "\(label)") }
                        if fragments != 1 { #expect(!text.contains("one piece"), "\(label)") }
                        if fragments > 1, method == .carved { #expect(text.contains("\(fragments) pieces that Salvage joined itself"), "\(label)") }
                        if fragments > 1, method == .metadata { #expect(text.contains("\(fragments) pieces, all mapped by the filesystem"), "\(label)") }

                        // Overwriting: reassurance only when the estimate is 0, numbers only when usable.
                        if text.contains("nothing suggests it was overwritten") { #expect(overwrite == 0 && deleted, "\(label)") }
                        if text.contains("no usable estimate") { #expect(!usable, "\(label)") }
                        if text.contains("% chance") { #expect(usable && overwrite > 0 && overwrite < 1, "\(label)") }
                        if text.contains("almost certainly overwritten") { #expect(overwrite == 1, "\(label)") }
                        if method == .metadata, !usable { #expect(text.contains("no usable estimate"), "\(label)") }

                        // The end: confirmed only when not partial; a partial file is never complete.
                        if text.contains("its end was confirmed") { #expect(!partial, "\(label)") }
                        if partial {
                            #expect(text.contains("couldn't be confirmed") || text.contains("may be incomplete"), "\(label)")
                        }
                        if method == .carved {
                            #expect(text.contains("couldn't be confirmed") == partial, "\(label)")
                        }

                        // Low carves name what holds them back.
                        if method == .carved, level == .low {
                            #expect(!text.contains("can't be rated higher"), "\(label)")
                            if !usable { #expect(text.contains("no usable estimate"), "\(label)") }
                            if fragments > 1 && RecoveryConfidence.assess(method: .carved, evidence: RecoveryEvidence(fragmentCount: 1, overwriteConfidence: overwrite)) != .low {
                                #expect(text.contains("pieces that Salvage joined itself"), "\(label)")
                            }
                        }
                        if method == .carved, level == .medium { #expect(text.contains("can't be rated higher"), "\(label)") }
                    }
                }
            }
        }
    }

    // MARK: Words for the details panel

    @Test func evidenceWords() {
        func ev(_ f: Int, _ o: Double) -> RecoveryEvidence { RecoveryEvidence(fragmentCount: f, overwriteConfidence: o) }
        #expect(ConfidenceExplanation.fragmentsDescription(ev(1, 0), method: .metadata) == "In one piece.")
        #expect(ConfidenceExplanation.fragmentsDescription(ev(4, 0), method: .metadata) == "In 4 pieces. The filesystem records where each one is.")
        #expect(ConfidenceExplanation.fragmentsDescription(ev(2, 0), method: .carved) == "In 2 pieces that Salvage joined itself. No filesystem record says how they fit.")
        #expect(ConfidenceExplanation.fragmentsDescription(ev(0, 0), method: .metadata).hasPrefix("None of its data is stored"))
        #expect(ConfidenceExplanation.overwriteDescription(ev(1, 0)) == "No sign that its data was overwritten.")
        #expect(ConfidenceExplanation.overwriteDescription(ev(1, 0.6)) == "Salvage estimates a 60% chance that some of its data was overwritten.")
        #expect(ConfidenceExplanation.overwriteDescription(ev(1, 1)) == "Part of its data was almost certainly overwritten.")
        for bad: Double in [-1, 2, .nan, -.infinity] {
            #expect(ConfidenceExplanation.overwriteDescription(ev(1, bad)) == "Salvage has no usable estimate of whether its data was overwritten.")
        }
    }

    // MARK: RecoveredFile entry point

    func file(_ content: FileContent, size: Int64 = 4096, method: RecoveryMethod = .metadata,
              deleted: Bool = false, partial: Bool = false, overwrite: Double = 0) -> RecoveredFile {
        RecoveredFile(name: "a.jpg", path: "/a.jpg", sizeBytes: size, isDeleted: deleted,
                      sourceMetadata: SourceMetadata(filesystem: method == .carved ? .carved : .exfat, volumeOffset: 0, recordOffset: 0,
                                                     allocationStart: 2, contiguous: true, rawRecord: Data()),
                      content: content, recoveryMethod: method, isPartial: partial, overwriteConfidence: overwrite)
    }

    @Test func fileExplanationUsesTheFilesOwnEvidence() {
        let runs = FileContent.runs([DataRun(deviceOffset: 0, length: 2048), DataRun(deviceOffset: nil, length: 1024),
                                     DataRun(deviceOffset: 8192, length: 1024)])
        let f = file(runs, deleted: true)
        #expect(f.confidenceExplanation == ConfidenceExplanation.sentence(method: .metadata, evidence: f.recoveryEvidence,
                                                                          isDeleted: true, isPartial: false))
        #expect(f.confidenceExplanation.hasPrefix("High: "))
        #expect(f.confidenceExplanation.contains("2 pieces"), "holes aren't pieces")
        let carved = file(.runs([DataRun(deviceOffset: 4096, length: 4096)]), method: .carved, partial: true, overwrite: 0.6)
        #expect(carved.confidenceExplanation == "Low: reconstructed from raw data, and the end of the file couldn't be confirmed.")
        #expect(carved.confidenceExplanation.hasPrefix(carved.recoveryConfidence!.displayName + ":"))
    }

    @Test func unrecoverableFilesSayWhy() {
        #expect(file(.unmapped).confidenceExplanation
                == "Can't be recovered: Salvage couldn't locate this file's contents on the device.")
        #expect(file(.runs([DataRun(deviceOffset: 0, length: 100)])).confidenceExplanation
                == "Can't be recovered: the filesystem's records don't account for all of this file's data.")
    }
}
