import Foundation
import Testing
@testable import SalvageCore

@Suite("Recovery confidence (AD-7)")
struct RecoveryConfidenceTests {
    func file(_ content: FileContent, deleted: Bool = false, size: Int64 = 4096) -> RecoveredFile {
        RecoveredFile(name: "a.jpg", path: "/a.jpg", sizeBytes: size, isDeleted: deleted,
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
                               DataRun(deviceOffset: 4096, length: 512)]), deleted: true, size: 1536)
        #expect(runs.recoveryMethod == .metadata)
        #expect(runs.recoveryEvidence == RecoveryEvidence(fragmentCount: 2, overwriteConfidence: 0))
        #expect(runs.recoveryConfidence == .high)
        #expect(file(.resident(Data([1])), size: 1).recoveryEvidence.fragmentCount == 1)
        #expect(file(.resident(Data([1])), size: 1).recoveryConfidence == .high)
    }

    @Test func unmappedHasNoConfidence() {
        let f = file(.unmapped)
        #expect(f.isUnmapped)
        #expect(f.recoveryConfidence == nil)
    }

    @Test func mappingThatFailsCoverageValidationCantBeRecovered() {
        let bad: [(String, FileContent)] = [
            ("runs shorter than the file", .runs([DataRun(deviceOffset: 0, length: 4095)])),
            ("no runs at all", .runs([])),
            ("negative length", .runs([DataRun(deviceOffset: 0, length: -1), DataRun(deviceOffset: 0, length: 8192)])),
            ("negative offset", .runs([DataRun(deviceOffset: -512, length: 4096)])),
            ("summed lengths overflow", .runs([DataRun(deviceOffset: 0, length: 1), DataRun(deviceOffset: 0, length: .max)])),
            ("resident data shorter than the file", .resident(Data(count: 10))),
        ]
        for (label, content) in bad {
            let f = file(content)
            #expect(f.isUnmapped, "\(label)")
            #expect(!f.mappingCoversSize, "\(label)")
            #expect(f.recoveryConfidence == nil, "\(label)")
        }
        let good: [FileContent] = [
            .runs([DataRun(deviceOffset: 0, length: 4096)]),
            .runs([DataRun(deviceOffset: 0, length: 2048), DataRun(deviceOffset: nil, length: 4096)]),
            .resident(Data(count: 4096)),
        ]
        for content in good { #expect(file(content).recoveryConfidence == .high) }
        // A zero-byte file needs no coverage, matching FileContentReader.validate.
        #expect(file(.runs([]), size: 0).recoveryConfidence == .high)
    }
}
