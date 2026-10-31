import Foundation
import SalvageCore
import Testing
@testable import Salvage

@MainActor @Suite("Scan results and file browser")
struct ResultsViewModelTests {
    func file(_ name: String, path: String? = nil, size: Int64 = 100, modified: Date? = nil, deleted: Bool = false,
              content: FileContent = .runs([DataRun(deviceOffset: 4096, length: 4096)])) -> RecoveredFile {
        RecoveredFile(name: name, path: path ?? "/\(name)", sizeBytes: size, modified: modified, isDeleted: deleted,
                      sourceMetadata: SourceMetadata(filesystem: .fat32, volumeOffset: 0, recordOffset: 0,
                                                     allocationStart: 2, contiguous: false, rawRecord: Data()),
                      content: content)
    }

    @Test func bucketsCountAndSizeRecoverableFilesPerCategory() {
        let model = ResultsViewModel(files: [
            file("a.JPG", size: 10), file("b.png", size: 20), file("c.mov", size: 300),
            file("d.pdf", size: 4), file("e.zip", size: 5), file("f.unknownext", size: 6),
        ])
        let buckets = Dictionary(uniqueKeysWithValues: model.buckets.map { ($0.category, $0) })
        #expect(model.buckets.map(\.category) == FileCategory.allCases)
        #expect(buckets[.pictures]?.count == 2 && buckets[.pictures]?.totalBytes == 30)
        #expect(buckets[.videos]?.count == 1 && buckets[.videos]?.totalBytes == 300)
        #expect(buckets[.audio]?.count == 0 && buckets[.audio]?.totalBytes == 0)
        #expect(buckets[.other]?.count == 1)
        #expect(model.recoverableCount == 6)
        #expect(model.recoverableBytes == 345)
        #expect(model.hasRecoverableFiles)
    }

    @Test func unmappedFilesAreSeparateUnselectableAndCantBeRecovered() async {
        let unmapped = file("lost.jpg", size: 1000, content: .unmapped)
        let ok = file("ok.jpg", size: 1)
        let model = ResultsViewModel(files: [unmapped, ok])
        #expect(model.recoverableCount == 1)
        #expect(model.recoverableBytes == 1)
        #expect(model.unrecoverableCount == 1)
        #expect(model.buckets.first { $0.category == .pictures }?.count == 1)
        model.setChecked(unmapped.id, true)
        #expect(model.checkedCount == 0)
        model.setChecked(ok.id, true)
        #expect(model.recoverButtonTitle == "Recover (1 selected)")
        await model.refresh()
        let row = model.visibleRows.first { $0.id == unmapped.id }
        #expect(row != nil)
        #expect(row?.confidence == nil)
        #expect(row?.isRecoverable == false)
    }

    @Test func nothingRecoverableIsReported() {
        #expect(!ResultsViewModel(files: []).hasRecoverableFiles)
        #expect(!ResultsViewModel(files: [file("x.jpg", content: .unmapped)]).hasRecoverableFiles)
    }

    @Test func parserFilesShowHighConfidence() async {
        let model = ResultsViewModel(files: [file("a.jpg"), file("b.jpg", deleted: true), file("c.txt", content: .resident(Data([1])))])
        await model.refresh()
        #expect(model.visibleRows.allSatisfy { $0.confidence == .high })
    }

    @Test func systemFilesAreHiddenUntilShown() async {
        let files = [
            file("photo.jpg"), file("._photo.jpg"), file(".DS_Store", path: "/DCIM/.DS_Store"),
            file("0000000000a1b2c3", path: "/.fseventsd/0000000000a1b2c3"),
            file("store.db", path: "/.Spotlight-V100/Store-V2/store.db"),
            file("trashed.jpg", path: "/.Trashes/501/trashed.jpg"),
            file("inner.jpg", path: "/._dir/inner.jpg"),
        ]
        let model = ResultsViewModel(files: files)
        #expect(model.recoverableCount == 1)
        #expect(model.hiddenSystemFileCount == 6)
        await model.refresh()
        #expect(model.visibleRows.map(\.name) == ["photo.jpg"])
        model.showSystemFiles = true
        await model.refresh()
        #expect(model.visibleRows.count == 7)
        #expect(model.recoverableCount == 7)
        #expect(model.hiddenSystemFileCount == 0)
        #expect(!ResultsViewModel.isSystemFile(file("normal._name.jpg", path: "/a/normal._name.jpg")))
    }

    @Test func searchCategoryAndSort() async {
        let model = ResultsViewModel(files: [
            file("b.jpg", path: "/Holiday/b.jpg", size: 5, modified: Date(timeIntervalSince1970: 200)),
            file("A.jpg", path: "/Work/A.jpg", size: 50, modified: nil),
            file("c.mp3", path: "/Holiday/c.mp3", size: 1, modified: Date(timeIntervalSince1970: 100)),
        ])
        await model.refresh()
        #expect(model.visibleRows.map(\.name) == ["A.jpg", "b.jpg", "c.mp3"])
        model.sort = .init(field: .size, ascending: false)
        await model.refresh()
        #expect(model.visibleRows.map(\.name) == ["A.jpg", "b.jpg", "c.mp3"])
        model.sort = .init(field: .modified, ascending: true)
        await model.refresh()
        #expect(model.visibleRows.map(\.name) == ["A.jpg", "c.mp3", "b.jpg"])
        model.sort = .init(field: .path, ascending: false)
        await model.refresh()
        #expect(model.visibleRows.map(\.name) == ["A.jpg", "c.mp3", "b.jpg"])
        model.searchText = "  HOLIDAY "
        await model.refresh()
        #expect(Set(model.visibleRows.map(\.name)) == ["b.jpg", "c.mp3"])
        model.category = .pictures
        await model.refresh()
        #expect(model.visibleRows.map(\.name) == ["b.jpg"])
    }

    @Test func checkedFilesSurviveFilteringAndCanBeCleared() async {
        let a = file("a.jpg"), b = file("b.mp3")
        let model = ResultsViewModel(files: [a, b])
        model.setChecked(a.id, true); model.setChecked(b.id, true)
        model.category = .audio
        await model.refresh()
        #expect(model.checkedFiles.map(\.id) == [b.id, a.id])
        #expect(model.recoverButtonTitle == "Recover (2 selected)")
        model.setChecked(b.id, false)
        #expect(model.checkedFiles == [a])
        model.clearChecked()
        #expect(model.recoverButtonTitle == "Recover (0 selected)")
    }

    @Test func browserSortMapsFromTableColumns() {
        typealias Row = ResultsViewModel.Row
        #expect(FileBrowserView.sort(from: []) == .default)
        #expect(FileBrowserView.sort(from: [KeyPathComparator(\Row.sizeBytes, order: .reverse)]) == .init(field: .size, ascending: false))
        #expect(FileBrowserView.sort(from: [KeyPathComparator(\Row.path)]) == .init(field: .path, ascending: true))
        #expect(FileBrowserView.sort(from: [KeyPathComparator(\Row.modifiedSortKey)]) == .init(field: .modified, ascending: true))
    }

    @Test func resultsReplaceProgressOnlyOnceTheScanHasEnded() {
        #expect(ResultsViewModel.showsResults(state: .completed, isActive: false, fileCount: 0))
        #expect(ResultsViewModel.showsResults(state: .cancelled, isActive: false, fileCount: 3))
        #expect(ResultsViewModel.showsResults(state: .failed(.deviceChanged), isActive: false, fileCount: 3))
        #expect(!ResultsViewModel.showsResults(state: .failed(.deviceChanged), isActive: false, fileCount: 0))
        #expect(!ResultsViewModel.showsResults(state: .cancelled, isActive: false, fileCount: 0))
        for state: ScanViewModel.State in [.idle, .preparing, .running, .paused, .resumable] {
            #expect(!ResultsViewModel.showsResults(state: state, isActive: false, fileCount: 5))
        }
        #expect(!ResultsViewModel.showsResults(state: .completed, isActive: true, fileCount: 5))
    }

    @Test func handlesOneHundredThousandFiles() async {
        let files = (0..<100_000).map { i in file("IMG_\(i).jpg", path: "/DCIM/\(i % 100)/IMG_\(i).jpg", size: Int64(i)) }
        let model = await ResultsViewModel.build(files: files)
        #expect(model.visibleRows.count == 100_000)
        #expect(model.recoverableCount == 100_000)
        model.searchText = "img_9999"
        await model.refresh()
        #expect(model.visibleRows.count == 11)
    }

    @Test func confidenceLabelAnnouncesTheWord() {
        #expect(ConfidenceLabel(confidence: .high).accessibilityText == "Recovery confidence High")
        #expect(ConfidenceLabel(confidence: .low).accessibilityText == "Recovery confidence Low")
        #expect(ConfidenceLabel(confidence: nil).accessibilityText == "Can't be recovered")
    }
}
