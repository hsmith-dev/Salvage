import Foundation
import Testing
@testable import SalvageCore

@Suite("Recovery confidence (AD-7)")
struct RecoveryConfidenceTests {
    func file(_ content: FileContent, deleted: Bool = false) -> RecoveredFile {
        RecoveredFile(name: "a.jpg", path: "/a.jpg", sizeBytes: 4096, isDeleted: deleted,
                      sourceMetadata: SourceMetadata(filesystem: .fat32, volumeOffset: 0, recordOffset: 0,
                                                     allocationStart: 2, contiguous: false, rawRecord: Data()),
                      content: content)
    }

    @Test func metadataIsAlwaysHigh() {
        for fragments in [0, 1, 2, 50] {
            for overwrite in [0, 0.49, 0.5, 1, .nan] {
                #expect(RecoveryConfidence.assess(method: .metadata,
                                                  evidence: RecoveryEvidence(fragmentCount: fragments, overwriteConfidence: overwrite)) == .high)
            }
        }
    }

    @Test func carvedIsNeverHighWhateverTheEvidence() {
        // The best evidence a hypothetical carved file could carry still stops at Medium.
        for fragments in [-1, 0, 1, 2, 10, Int.max] {
            for overwrite in [-1, 0, 0.25, 0.4999, 0.5, 0.75, 1, 2, .nan, .infinity] {
                let confidence = RecoveryConfidence.assess(method: .carved,
                                                           evidence: RecoveryEvidence(fragmentCount: fragments, overwriteConfidence: overwrite))
                #expect(confidence != .high)
            }
        }
    }

    @Test func carvedMediumLowBoundary() {
        func carved(_ f: Int, _ o: Double) -> RecoveryConfidence {
            RecoveryConfidence.assess(method: .carved, evidence: RecoveryEvidence(fragmentCount: f, overwriteConfidence: o))
        }
        #expect(carved(1, 0) == .medium)
        #expect(carved(0, 0.49) == .medium)
        #expect(carved(1, 0.5) == .low)
        #expect(carved(2, 0) == .low)
        #expect(carved(1, .nan) == .low)
        #expect(carved(1, -0.1) == .low)
    }

    @Test func parserFilesAreMetadataRecoveredWithNoOverwrite() {
        let runs = file(.runs([DataRun(deviceOffset: 0, length: 512), DataRun(deviceOffset: nil, length: 512),
                               DataRun(deviceOffset: 4096, length: 512)]), deleted: true)
        #expect(runs.recoveryMethod == .metadata)
        #expect(runs.recoveryEvidence == RecoveryEvidence(fragmentCount: 2, overwriteConfidence: 0))
        #expect(runs.recoveryConfidence == .high)
        #expect(file(.resident(Data([1]))).recoveryEvidence.fragmentCount == 1)
        #expect(file(.resident(Data([1]))).recoveryConfidence == .high)
    }

    @Test func unmappedHasNoConfidence() {
        let f = file(.unmapped)
        #expect(f.isUnmapped)
        #expect(f.recoveryConfidence == nil)
    }
}
