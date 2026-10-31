import Foundation
import SalvageCore
import Testing
@testable import Salvage

@MainActor @Suite("Scan results and file browser")
struct ResultsViewModelTests {
    func file(_ name: String, path: String? = nil, size: Int64 = 100, modified: Date? = nil, deleted: Bool = false,
              content: FileContent? = nil) -> RecoveredFile {
        RecoveredFile(name: name, path: path ?? "/\(name)", sizeBytes: size, modified: modified, isDeleted: deleted,
                      sourceMetadata: SourceMetadata(filesystem: .fat32, volumeOffset: 0, recordOffset: 0,
                                                     allocationStart: 2, contiguous: false, rawRecord: Data()),
                      content: content ?? .runs([DataRun(deviceOffset: 4096, length: max(size, 4096))]))
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
        await model.refresh()
        #expect(model.recoverableCount == 1)
        #expect(model.recoverableBytes == 1)
        #expect(model.unrecoverableCount == 1)
        #expect(model.buckets.first { $0.category == .pictures }?.count == 1)
        model.setChecked(unmapped.id, true)
        #expect(model.checkedCount == 0)
        model.setChecked(ok.id, true)
        #expect(model.recoverButtonTitle == "Recover (1 selected)")
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
        let model = ResultsViewModel(files: [file("a.jpg"), file("b.jpg", deleted: true), file("c.txt", size: 1, content: .resident(Data([1])))])
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

    @Test func hiddenTicksAreKeptAndCountedButOnlyVisibleTicksAreRecovered() async {
        let a = file("a.jpg"), b = file("b.mp3")
        let model = ResultsViewModel(files: [a, b])
        await model.refresh()
        model.setChecked(a.id, true); model.setChecked(b.id, true)
        #expect(model.selectionSummary == nil)
        model.category = .audio
        await model.refresh()
        #expect(model.checkedFiles.map(\.id) == [b.id])
        #expect(model.checkedCount == 2)
        #expect(model.hiddenCheckedCount == 1)
        #expect(model.recoverButtonTitle == "Recover (1 selected)")
        #expect(model.selectionSummary == "2 selected (1 hidden)")
        model.setChecked(b.id, false)
        #expect(model.checkedFiles.isEmpty)
        #expect(model.recoverButtonTitle == "Recover (0 selected)")
        model.category = nil
        await model.refresh()
        #expect(model.checkedFiles == [a])
        model.clearChecked()
        #expect(model.recoverButtonTitle == "Recover (0 selected)")
    }

    @Test func focusedRowIsClearedWhenTheFilterHidesIt() async {
        let a = file("a.jpg"), b = file("b.mp3")
        let model = ResultsViewModel(files: [a, b])
        await model.refresh()
        model.focusedID = a.id
        #expect(model.focusedRow?.id == a.id)
        model.category = .audio
        await model.refresh()
        #expect(model.focusedID == nil)
        #expect(model.selection.isEmpty)
        model.focusedID = b.id
        model.category = nil
        await model.refresh()
        #expect(model.focusedID == b.id)
    }

    @Test func staleRefreshIsDroppedWhenReturningToAnAppliedQuery() async {
        let gate = Gate()
        let model = ResultsViewModel(rows: [file("a.jpg"), file("b.jpg")].map(ResultsViewModel.Row.init), apply: { query, rows in
            if query.search == "a" { await gate.enterAndWait() }
            return try ResultsViewModel.apply(query, to: rows)
        })
        await model.refresh()
        #expect(model.visibleRows.count == 2)
        model.searchText = "a"
        let slow = Task { await model.refresh() }
        await gate.waitUntilEntered()
        model.searchText = ""
        await model.refresh()   // already applied: must still supersede the slow "a" refresh
        await gate.open()
        await slow.value
        #expect(model.visibleRows.count == 2)
        #expect(model.query.search == "")
    }

    @Test func searchIsDebouncedAndASupersededRequestNeverApplies() async {
        let slept = Recorder<Duration>(), applied = Recorder<String>()
        let gate = Gate()
        let model = ResultsViewModel(rows: [file("a.jpg"), file("ab.jpg")].map(ResultsViewModel.Row.init),
                                     apply: { query, rows in
                                         await applied.add(query.search)
                                         return try ResultsViewModel.apply(query, to: rows)
                                     },
                                     sleep: { duration in
                                         await slept.add(duration)
                                         if await slept.values.count == 1 { await gate.enterAndWait() }
                                     })
        await model.refresh(debounceSearch: true)   // initial load: nothing typed, no wait
        #expect(await slept.values.isEmpty)
        model.searchText = "a"
        let first = Task { await model.refresh(debounceSearch: true) }
        await gate.waitUntilEntered()
        model.searchText = "ab"
        await model.refresh()
        await gate.open()
        await first.value
        #expect(await slept.values == [ResultsViewModel.searchDebounce])
        #expect(ResultsViewModel.searchDebounce == .milliseconds(150))
        #expect(await applied.values == ["", "ab"])
        #expect(model.visibleRows.map(\.name) == ["ab.jpg"])
        // A sort change isn't a search edit, so it isn't delayed.
        model.sort = .init(field: .size, ascending: false)
        await model.refresh(debounceSearch: true)
        #expect(await slept.values.count == 1)
    }

    @Test func applyStopsWhenCancelled() async {
        let rows = (0..<10_000).map { file("f\($0).jpg") }.map(ResultsViewModel.Row.init)
        let query = ResultsViewModel(rows: []).query
        let task = Task.detached { () throws -> [ResultsViewModel.Row] in
            while !Task.isCancelled { await Task.yield() }
            return try ResultsViewModel.apply(query, to: rows)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func dashboardAggregatesAreComputedOncePerSystemFileSetting() {
        let model = ResultsViewModel(files: [file("a.jpg"), file("._a.jpg"), file("lost.jpg", content: .unmapped)])
        for _ in 0..<3 {
            _ = model.buckets; _ = model.recoverableCount; _ = model.recoverableBytes
            _ = model.unrecoverableCount; _ = model.hasRecoverableFiles
        }
        #expect(model.aggregateComputations == 1)
        model.showSystemFiles = true
        _ = model.buckets; _ = model.recoverableCount
        #expect(model.recoverableCount == 2)
        #expect(model.aggregateComputations == 2)
        model.showSystemFiles = false
        _ = model.buckets; _ = model.hiddenSystemFileCount
        #expect(model.hiddenSystemFileCount == 1)
        #expect(model.aggregateComputations == 2)
    }

    @Test func keyboardTicksSelectedRowsAndSelectsOrDeselectsAll() async {
        let a = file("a.jpg"), b = file("b.jpg"), lost = file("lost.jpg", content: .unmapped), c = file("c.mp3")
        let model = ResultsViewModel(files: [a, b, lost, c])
        await model.refresh()
        model.selection = [a.id, lost.id]
        model.toggleCheckedForSelection()
        #expect(model.isChecked(a.id) && !model.isChecked(lost.id))
        model.selection = [a.id, b.id]
        model.toggleCheckedForSelection()          // b unticked, so both become ticked
        #expect(model.isChecked(a.id) && model.isChecked(b.id))
        model.toggleCheckedForSelection()          // all ticked, so both are unticked
        #expect(model.checkedCount == 0)
        model.selection = []
        model.toggleCheckedForSelection()
        #expect(model.checkedCount == 0)

        model.category = .pictures
        await model.refresh()
        model.selectAllRecoverable()               // visible recoverable rows only
        #expect(Set(model.checkedFiles.map(\.id)) == [a.id, b.id])
        #expect(!model.isChecked(c.id) && !model.isChecked(lost.id))
        model.setChecked(c.id, true)
        model.deselectAll()                        // includes hidden ticks
        #expect(model.checkedCount == 0)
    }

    @Test func emptyStateDependsOnSystemFilesAndHowTheScanEnded() {
        #expect(ResultsViewModel(files: [file("a.jpg")]).emptyState(for: .completed) == nil)
        let nothing = ResultsViewModel(files: [file("x.jpg", content: .unmapped)])
        #expect(nothing.emptyState(for: .completed) == .nothingRecoverable)
        #expect(nothing.emptyState(for: .cancelled) == .nothingRecoverableBeforeStop)
        #expect(nothing.emptyState(for: .failed(.deviceChanged)) == .nothingRecoverableBeforeStop)
        #expect(ResultsViewModel(files: []).emptyState(for: .completed)?.message == "No recoverable files found on this device.")
        let onlySystem = ResultsViewModel(files: [file(".DS_Store"), file("._a.jpg")])
        #expect(onlySystem.emptyState(for: .completed) == .onlySystemFiles)
        #expect(onlySystem.emptyState(for: .cancelled) == .onlySystemFiles)
        #expect(onlySystem.emptyState(for: .completed)?.message.hasPrefix("Only macOS system files were found") == true)
        onlySystem.showSystemFiles = true
        #expect(onlySystem.emptyState(for: .completed) == nil)
        #expect(ResultsViewModel.EmptyState.nothingRecoverableBeforeStop.message == "No recoverable files were found before the scan stopped.")
    }

    @Test func browserTitleCountsRecoverableFilesLikeTheTiles() async {
        let model = ResultsViewModel(files: [file("a.jpg"), file("b.jpg"), file("lost.jpg", content: .unmapped), file("c.mp3")])
        model.category = .pictures
        await model.refresh()
        #expect(model.browserTitle == "Pictures — 2 files, 1 can't be recovered")
        #expect(model.browserTitle.contains("\(model.buckets.first { $0.category == .pictures }?.count ?? -1) files"))
        model.category = .audio
        await model.refresh()
        #expect(model.browserTitle == "Audio — 1 file")
    }

    @Test func browserSortOrderStartsFromTheModelSort() {
        for field in [ResultsViewModel.SortField.name, .path, .size, .modified] {
            for ascending in [true, false] {
                let sort = ResultsViewModel.Sort(field: field, ascending: ascending)
                #expect(FileBrowserView.sort(from: FileBrowserView.sortOrder(for: sort)) == sort)
            }
        }
    }

    @Test func spaceShowsThePreviewAndNeverHidesIt() {
        #expect(FileBrowserView.previewVisibility(afterSpaceWhile: false))
        #expect(FileBrowserView.previewVisibility(afterSpaceWhile: true))
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

/// Lets a test hold an async step open until it says go.
private actor Gate {
    private var entered = false, isOpen = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var openWaiters: [CheckedContinuation<Void, Never>] = []

    func enterAndWait() async {
        entered = true
        enteredWaiters.forEach { $0.resume() }; enteredWaiters = []
        guard !isOpen else { return }
        await withCheckedContinuation { openWaiters.append($0) }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func open() {
        isOpen = true
        openWaiters.forEach { $0.resume() }; openWaiters = []
    }
}

private actor Recorder<Value: Sendable> {
    private(set) var values: [Value] = []
    func add(_ value: Value) { values.append(value) }
}
