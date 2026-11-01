import Foundation
import SalvageCore
import Testing
@testable import Salvage

// File details and "why this confidence" (spec-tech-batch-7 §C): the details model the panel and
// Copy Details are built from.

private func metadataFile(_ content: FileContent, size: Int64 = 12_288, deleted: Bool = false,
                          filesystem: SourceMetadata.Filesystem = .exfat, volumeOffset: Int64 = 1_048_576,
                          volumeName: String? = nil) -> RecoveredFile {
    RecoveredFile(name: "report.pdf", path: "/Documents/report.pdf", sizeBytes: size,
                  modified: Date(timeIntervalSince1970: 1_700_000_000), isDeleted: deleted,
                  sourceMetadata: SourceMetadata(filesystem: filesystem, volumeOffset: volumeOffset, recordOffset: 1_052_704,
                                                 allocationStart: 5, contiguous: false, rawRecord: Data(),
                                                 volumeName: volumeName),
                  content: content)
}

private func carvedFile(_ name: String, runs: [DataRun] = [DataRun(deviceOffset: 40_960, length: 8192)],
                        partial: Bool = false, overwrite: Double = 0, header: Data = Data()) -> RecoveredFile {
    RecoveredFile(name: name, path: "/Reconstructed/Pictures/\(name)", sizeBytes: runs.reduce(0) { $0 + $1.length },
                  sourceMetadata: SourceMetadata(filesystem: .carved, volumeOffset: 0, recordOffset: runs[0].deviceOffset ?? 0,
                                                 allocationStart: 0, contiguous: runs.count == 1, rawRecord: header),
                  content: .runs(runs), recoveryMethod: .carved, isPartial: partial, overwriteConfidence: overwrite)
}

private func value(_ details: FileDetails, _ label: String) -> String? {
    details.sections.flatMap(\.fields).first { $0.label == label }?.value
}

@Suite("File details (batch 7 §C)")
struct FileDetailsTests {
    @Test func liveFilesystemFile() {
        let device = BlockDevice(bsdName: "disk9", displayName: "Card", sizeBytes: 1 << 30, isInternal: false, isBootVolume: false,
                                 partitions: [DevicePartition(bsdName: "disk9s1", displayName: "PHOTOS", sizeBytes: 1 << 29,
                                                              formatName: "exFAT", offsetBytes: 1_048_576)])
        let file = metadataFile(.runs([DataRun(deviceOffset: 2_097_152, length: 8192), DataRun(deviceOffset: nil, length: 4096)]))
        let details = FileDetails(file: file, device: device)
        #expect(details.confidence == .high)
        #expect(details.explanation == file.confidenceExplanation, "The sentence is Core's, not the app's")
        #expect(details.explanation == "High: found through the filesystem's own records; its data is in one piece.")
        #expect(value(details, "Original path") == "/Documents/report.pdf")
        #expect(value(details, "Size")?.hasSuffix("(12,288 bytes)") == true)
        #expect(value(details, "Modified") != "Unknown")
        #expect(value(details, "Status") == "Live")
        #expect(value(details, "Filesystem") == "exFAT")
        #expect(value(details, "Volume") == "PHOTOS (exFAT), at device 1,048,576 (0x100000)")
        #expect(value(details, "Recovery method") == "Found through the filesystem's records")
        #expect(value(details, "Record") == "At device 1,052,704 (0x101020)")
        #expect(value(details, "Pieces") == "In one piece.")
        #expect(value(details, "Overwriting") == "No sign that its data was overwritten.")
        #expect(!details.sections.contains { $0.title == "Reconstruction" })
        #expect(details.storage == nil)
        #expect(details.runs.map(\.text) == ["Run 1: device 2,097,152 (0x200000), 8,192 bytes",
                                             "Run 2: hole, 4,096 bytes, reads as zeros"])
        #expect(details.runs.map(\.fileOffset) == [0, 8192])
    }

    @Test func deletedFragmentedAPFSVolumeWithoutDevice() {
        let file = metadataFile(.runs([DataRun(deviceOffset: 4096, length: 4096), DataRun(deviceOffset: 65_536, length: 8192)]),
                                deleted: true, filesystem: .apfs, volumeOffset: 20_480, volumeName: "Data")
        let details = FileDetails(file: file)
        #expect(value(details, "Status") == "Deleted")
        #expect(value(details, "Filesystem") == "APFS")
        #expect(value(details, "Volume") == "Data, at device 20,480 (0x5000)")
        #expect(value(details, "Pieces") == "In 2 pieces. The filesystem records where each one is.")
        #expect(details.explanation.hasPrefix("High: found through the filesystem's own records of this deleted file; its data is in 2 pieces"))
        #expect(details.explanation.hasSuffix("nothing suggests it was overwritten."))
    }

    @Test func unnamedVolume() {
        #expect(value(FileDetails(file: metadataFile(.runs([DataRun(deviceOffset: 0, length: 12_288)]))), "Volume")
                == "Unnamed volume at device 1,048,576 (0x100000)")
    }

    @Test func encryptedRunsAreMarked() {
        let file = metadataFile(.encryptedRuns([DataRun(deviceOffset: 8192, length: 8192, firstDataUnit: 2),
                                                DataRun(deviceOffset: nil, length: 4096)], keyID: "VOL"), filesystem: .apfs)
        let details = FileDetails(file: file)
        #expect(details.storage == "Encrypted: the bytes on the device are ciphertext, decrypted as they're read.")
        #expect(details.runs.map(\.isEncrypted) == [true, false], "A hole has no ciphertext")
        #expect(details.runs[0].text.hasSuffix(", encrypted"))
    }

    @Test func residentAndUnmapped() {
        let resident = FileDetails(file: metadataFile(.resident(Data(count: 700)), size: 700, filesystem: .ntfs))
        #expect(resident.storage == "Stored inside the filesystem record itself (700 bytes).")
        #expect(resident.runs.isEmpty)
        let unmapped = FileDetails(file: metadataFile(.unmapped))
        #expect(unmapped.confidence == nil)
        #expect(unmapped.storage == "Not located on the device.")
        #expect(unmapped.explanation == "Can't be recovered: Salvage couldn't locate this file's contents on the device.")
        #expect(unmapped.copyText.contains("Recovery confidence: Can't be recovered"))
    }

    @Test func validatedCarvesNameTheirSignatureAndEndRule() {
        let jpeg = FileDetails(file: carvedFile("jpeg-00000000a000.jpg"))
        #expect(jpeg.confidence == .medium)
        #expect(value(jpeg, "Original path") == "Not known. Reconstructed files have no original path.")
        #expect(value(jpeg, "Listed as") == "/Reconstructed/Pictures/jpeg-00000000a000.jpg")
        #expect(value(jpeg, "Status") == "Reconstructed")
        #expect(value(jpeg, "Filesystem") == "None. Reconstructed from raw data.")
        #expect(value(jpeg, "Volume") == "Scanned area starting at device 0 (0x0)")
        #expect(value(jpeg, "Recovery method") == "Reconstructed from raw data by its file signature")
        #expect(value(jpeg, "Record") == nil)
        #expect(value(jpeg, "Signature") == "JPEG (.jpg), header at device 40,960 (0xa000)")
        #expect(value(jpeg, "End") == "Footer: its end marker was found.")
        #expect(value(FileDetails(file: carvedFile("png-00000000a000.png")), "End") == "Footer: its end marker was found.")
        #expect(value(FileDetails(file: carvedFile("wav-00000000a000.wav")), "End") == "Size field: its header states its length.")
        #expect(value(FileDetails(file: carvedFile("mp4-00000000a000.mp4")), "End")
                == "Validated: Salvage followed its internal records to the last one.")
        #expect(value(FileDetails(file: carvedFile("gif-00000000a000-2.gif")), "End")
                == "Validated: Salvage checked its internal structure to its end.")
        let unknown = FileDetails(file: carvedFile("mystery-00000000a000.xyz"))
        #expect(value(unknown, "Signature") == "Not identified (header at device 40,960 (0xa000))")
        #expect(value(unknown, "End") == "Confirmed by its format's end rule.")
    }

    @Test func sharedSignatureIDsPickTheHeaderThatMatches() {
        // Two bundled signatures are "mp3": untagged frames and an ID3 tag. Both walk frames.
        let id3 = carvedFile("mp3-00000000a000.mp3", header: Data([0x49, 0x44, 0x33, 0x03, 0x00]))
        let signature = FileDetails.signature(of: id3, in: .bundled)
        #expect(signature?.headers.first?.bytes.prefix(3) == [0x49, 0x44, 0x33])
        let frames = carvedFile("mp3-00000000a000.mp3", header: Data([0xFF, 0xFB, 0x90, 0x64]))
        #expect(FileDetails.signature(of: frames, in: .bundled)?.headers.first?.bytes == [0xFF, 0xFB])
    }

    @Test func cutShortCarves() {
        let limit = FileDetails(file: carvedFile("jpeg-00000000a000.jpg", partial: true, overwrite: 0.6))
        #expect(limit.confidence == .low)
        #expect(value(limit, "Status") == "Reconstructed, partial — may be incomplete")
        #expect(value(limit, "End")?.hasPrefix("Cut short: its end couldn't be confirmed, so it may be incomplete. It stopped at a size limit") == true)
        #expect(limit.explanation == "Low: reconstructed from raw data, and the end of the file couldn't be confirmed.")
        let claimed = FileDetails(file: carvedFile("jpeg-00000000a000.jpg", partial: true, overwrite: 1))
        #expect(value(claimed, "End")?.contains("ran into another file's") == true)
        #expect(value(claimed, "Overwriting") == "Part of its data was almost certainly overwritten.")
    }

    @Test func reassembledJPEG() {
        let joined = FileDetails(file: carvedFile("jpeg-00000000a000.jpg",
                                                  runs: [DataRun(deviceOffset: 40_960, length: 4096), DataRun(deviceOffset: 90_112, length: 2048)],
                                                  overwrite: 0.3))
        #expect(joined.confidence == .low)
        #expect(value(joined, "Pieces") == "In 2 pieces that Salvage joined itself. No filesystem record says how they fit.")
        #expect(value(joined, "End") == "Footer: its end marker was found. Salvage joined 2 pieces, checking that its data decodes across each join.")
        #expect(value(joined, "Overwriting") == "Salvage estimates a 30% chance that some of its data was overwritten.")
        #expect(joined.explanation.hasPrefix("Low: reconstructed from raw data, and its data is in 2 pieces"))
    }

    @Test func copyTextHasEverythingInPanelOrder() {
        let file = metadataFile(.runs([DataRun(deviceOffset: 2_097_152, length: 12_288)]))
        let details = FileDetails(file: file)
        let text = details.copyText
        let expectedOrder = ["report.pdf\n", "Recovery confidence: High\n", details.explanation, "\nFile\n", "Original path: /Documents/report.pdf",
                             "Status: Live", "\nSource\n", "Filesystem: exFAT", "\nEvidence\n", "Pieces: In one piece.",
                             "\nWhere its bytes are\n", "Run 1: device 2,097,152 (0x200000), 12,288 bytes\n"]
        var cursor = text.startIndex
        for part in expectedOrder {
            let range = text.range(of: part, range: cursor..<text.endIndex)
            #expect(range != nil, "\(part) in order")
            if let range { cursor = range.upperBound }
        }
    }

    @Test func copyTextCapsHugeRunLists() {
        let count = FileDetails.maxCopiedRuns + 3
        let runs = (0..<count).map { DataRun(deviceOffset: Int64($0) * 8192, length: 4096) }
        let details = FileDetails(file: metadataFile(.runs(runs), size: Int64(count) * 4096))
        #expect(details.runs.count == count)
        let lines = details.copyText.split(separator: "\n")
        #expect(lines.filter { $0.hasPrefix("Run ") }.count == FileDetails.maxCopiedRuns)
        #expect(lines.last == "… and 3 more runs not listed.")
    }
}
