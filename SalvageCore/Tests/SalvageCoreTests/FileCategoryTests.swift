import Foundation
import Testing
@testable import SalvageCore

@Suite("File categories")
struct FileCategoryTests {
    @Test func classifiesByExtensionCaseInsensitively() {
        #expect(FileCategory.classify(fileName: "IMG_0001.JPG") == .pictures)
        #expect(FileCategory.classify(fileName: "photo.HeIc") == .pictures)
        #expect(FileCategory.classify(fileName: "clip.mov") == .videos)
        #expect(FileCategory.classify(fileName: "song.FLAC") == .audio)
        #expect(FileCategory.classify(fileName: "report.final.pdf") == .documents)
        #expect(FileCategory.classify(fileName: "backup.tar.gz") == .archives)
    }

    @Test func unknownTypesGoToOther() {
        #expect(FileCategory.classify(fileName: "data.xyz") == .other)
        #expect(FileCategory.classify(fileName: "README") == .other)
        #expect(FileCategory.classify(fileName: "trailing.") == .other)
        #expect(FileCategory.classify(fileName: ".jpg") == .other)
        #expect(FileCategory.classify(fileName: "") == .other)
    }

    @Test func signatureHookDoesNotOverrideAKnownExtension() {
        #expect(FileCategory.classify(fileName: "a.mp3", signature: Data([0xFF, 0xD8, 0xFF])) == .audio)
        #expect(FileCategory.classify(fileName: "noext", signature: Data([0xFF, 0xD8, 0xFF])) == .other)
    }

    @Test func everyCategoryHasADisplayName() {
        #expect(FileCategory.allCases.map(\.displayName) == ["Pictures", "Videos", "Audio", "Documents", "Archives", "Other"])
    }

    @Test func recoveredFileCategoryUsesItsName() {
        let f = RecoveredFile(name: "Movie.MP4", path: "/x/Movie.MP4", sizeBytes: 1,
                              sourceMetadata: SourceMetadata(filesystem: .ntfs, volumeOffset: 0, recordOffset: 0,
                                                             allocationStart: 0, contiguous: true, rawRecord: Data()))
        #expect(f.category == .videos)
    }
}
