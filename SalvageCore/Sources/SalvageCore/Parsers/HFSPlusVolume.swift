import Foundation

/// Read-only HFS+/HFSX parser (AD-2: original Swift from Apple's public TN1150). All offsets are
/// relative to one validated partition; no read can escape `extent`. Live metadata is fail-closed
/// (`ScanError.malformed`); deleted-file recovery is best effort: it runs only after every live
/// file has been emitted, any I/O or structural failure in it skips the affected source, and it
/// skips any candidate that does not validate against the allocation bitmap.
actor HFSPlusVolume {
    static let isImplemented = true
    let reader: any BlockReader
    let extent: VolumeExtent
    let emit: @Sendable (RecoveredFile) async throws -> Void

    var header = HFSPlusVolumeHeader()
    var limits = HFSPlusLimits()
    var stats = HFSPlusScanStats()
    var catalog: HFSPlusBTree? = nil
    var allocation: HFSPlusForkMap? = nil
    /// The extents overflow tree, searched per file ID when a fork needs more than eight extents.
    var extentsTree: HFSPlusBTree? = nil
    var overflowNodeCache: [UInt32: HFSPlusNode] = [:]
    /// Every live folder, by CNID. Paths are built only when a file is emitted.
    var folders: [UInt32: HFSPlusFolderEntry] = [:]
    /// Folder records seen only in stale copies; used to place deleted files whose folder is gone.
    var staleFolders: [UInt32: HFSPlusStaleFolder] = [:]
    var privateDataFolderID: UInt32? = nil
    /// Indirect-node number → catalog leaf node holding its file record.
    var indirectNodes: [UInt32: UInt32] = [:]
    /// CNIDs of every live file record (sorted after pass 1); deleted candidates must not be live.
    var liveFileIDs: [UInt32] = []
    var cachedNode: (number: UInt32, node: HFSPlusNode)? = nil
    var candidates: [HFSPlusCandidate] = []
    var candidateIndex: [UInt32: Int] = [:]
    var candidateBytes = 0
    /// Blocks named by every plausible deleted-file record, superseded versions included.
    var claims: [HFSPlusClaim] = []
    var claimsOverflowed = false
    var compressedSizes: [UInt32: UInt64] = [:]
    var compressedSizesLoaded = false
    var bitmapPages: [Int64: Data] = [:]
    var unreadableBitmapPages: Set<Int64> = []
    var deletedWorkRemaining: UInt64 = 0
    /// Set once the journal or the volume header shows deleted candidates cannot be trusted.
    var recoveryDisabled: String? = nil

    static let bitmapPageSize: Int64 = 65536

    init(reader: any BlockReader, extent: VolumeExtent, emit: @escaping @Sendable (RecoveredFile) async throws -> Void) {
        self.reader = reader; self.extent = extent; self.emit = emit
    }

    /// Lowers the bounds (tests only; the defaults are the production limits).
    func setLimits(_ limits: HFSPlusLimits) { self.limits = limits }

    func read(_ offset: Int64, _ count: Int) async throws -> Data {
        try Task.checkCancellation()
        guard offset >= 0, count >= 0, offset <= extent.length, Int64(count) <= extent.length - offset else {
            throw ScanError.malformed("Read outside partition.")
        }
        let data = try await reader.read(at: checkedAdd(extent.offset, offset), count: count)
        guard data.count == count else { throw ScanError.malformed("Truncated structure.") }
        return data
    }

    func scan() async throws {
        header = try HFSPlusVolumeHeader.parse(try await read(1024, 512), volumeLength: extent.length)
        checkVolumeState()
        deletedWorkRemaining = limits.deletedWorkBudget ?? (4 * UInt64(header.totalBlocks) + 1_000_000)
        extentsTree = try await loadTree(header.extentsFile, fileID: HFSPlus.extentsFileID, name: "Extents overflow")
        let catalog = try await loadTree(header.catalogFile, fileID: HFSPlus.catalogFileID, name: "Catalog")
        self.catalog = catalog
        allocation = try HFSPlusForkMap(try await fullExtents(header.allocationFile, fileID: HFSPlus.allocationFileID),
                                        blockSize: header.blockSize)
        // Pass 1 indexes folders; its visited set is released before pass 2 builds its own.
        try await walkLeaves(catalog) { node, number in try self.indexLeaf(node, number: number) }
        liveFileIDs.sort()
        // Pass 2 emits every live file before any deleted-file work starts.
        let visited = try await walkLeaves(catalog) { node, number in try await self.emitLeaf(node, number: number) }
        try await bestEffort(.journal) { try await self.scanJournal() }
        if recoveryDisabled == nil {
            try await bestEffort(.staleNode) { try await self.scanStaleNodes(visited: visited) }
        }
        try await recoverDeleted()
    }

    /// Volume-header attributes that make the allocation bitmap untrustworthy for deleted files.
    func checkVolumeState() {
        if header.catalogNodeIDsReused {
            recoveryDisabled = "catalog node IDs have wrapped; stale records cannot be placed"
        } else if !header.isJournaled, header.isMarkedInconsistent {
            recoveryDisabled = "the volume is marked inconsistent, so the allocation bitmap may be stale"
        } else if !header.isJournaled, !header.wasCleanlyUnmounted {
            recoveryDisabled = "the volume was not cleanly unmounted, so the allocation bitmap may be stale"
        }
    }

    /// Runs one deleted-file source. An I/O or structural failure skips that source (its
    /// candidates are kept only as evidence of block use) and never ends the scan.
    func bestEffort(_ source: HFSPlusCandidateSource, _ body: () async throws -> Void) async throws {
        do {
            try await body()
        } catch let error as ScanError {
            switch error {
            case .io, .malformed:
                stats.notes.append("Deleted-file source \(source) skipped: \(error)")
                for index in candidates.indices where candidates[index].source == source { candidates[index].conflicted = true }
            default:
                throw error
            }
        }
    }

    // MARK: Forks and trees

    /// Reads `count` bytes of a fork starting at a logical offset.
    func readFork(_ map: HFSPlusForkMap, _ offset: Int64, _ count: Int) async throws -> Data {
        var result = Data(capacity: count)
        for piece in try map.pieces(offset: offset, count: count) {
            result.append(try await read(piece.volumeOffset, piece.count))
        }
        return result
    }

    /// Device-absolute offset of a fork's logical byte.
    func deviceOffset(_ map: HFSPlusForkMap, logical: Int64) throws -> Int64 {
        guard let volume = try map.volumeOffset(of: logical) else { throw ScanError.malformed("Offset past fork extents.") }
        return try checkedAdd(extent.offset, volume)
    }

    /// The complete extent list of a fork: the eight in the record plus overflow records, which
    /// are looked up in the extents overflow tree only when the fork needs them.
    func fullExtents(_ fork: HFSPlusForkData, fileID: UInt32) async throws -> [HFSPlusExtent] {
        var result = fork.extents
        for extent in result { try header.validate(extent) }
        var blocks = fork.extentBlocks
        guard blocks <= UInt64(fork.totalBlocks), fork.logicalSize <= UInt64(fork.totalBlocks) * UInt64(header.blockSize) else {
            throw ScanError.malformed("Fork size disagrees with its extents.")
        }
        while blocks < UInt64(fork.totalBlocks) {
            guard let more = try await overflowExtents(fileID: fileID, startBlock: UInt32(blocks)) else {
                throw ScanError.malformed("Missing overflow extents.")
            }
            for extent in more {
                try header.validate(extent)
                blocks += UInt64(extent.blockCount)
            }
            guard blocks <= UInt64(fork.totalBlocks) else { throw ScanError.malformed("Overflow extents exceed fork total.") }
            result.append(contentsOf: more)
            guard result.count <= limits.maxExtentsPerFile else { throw ScanError.malformed("Too many extents.") }
        }
        return result
    }

    /// The data-fork overflow record keyed (fileID, startBlock), found by descending the extents
    /// overflow tree from its root. Nil when the tree has no such record.
    func overflowExtents(fileID: UInt32, startBlock: UInt32) async throws -> [HFSPlusExtent]? {
        guard let tree = extentsTree, tree.header.rootNode != 0 else { return nil }
        let target = HFSPlusExtentKey(fileID: fileID, forkType: 0, startBlock: startBlock)
        var number = tree.header.rootNode
        var height = tree.header.treeDepth
        while height >= 1 {
            try Task.checkCancellation()
            let node = try await overflowNode(tree, number)
            guard Int(node.height) == height else { throw ScanError.malformed("Extents overflow tree height mismatch.") }
            if height == 1 {
                guard node.isLeaf else { throw ScanError.malformed("Extents overflow tree reaches a non-leaf node.") }
                for index in 0..<node.numRecords {
                    let record = node.record(index)
                    guard try HFSPlusExtentKey(record) == target else { continue }
                    guard record.count >= 12 + 64 else { throw ScanError.malformed("Invalid extents overflow record.") }
                    let extents = try HFSPlusExtent.list(record, at: 12, count: 8)
                    guard !extents.isEmpty else { throw ScanError.malformed("Empty extents overflow record.") }
                    return extents
                }
                return nil
            }
            guard node.kind == HFSPlusNode.indexKind else { throw ScanError.malformed("Extents overflow tree reaches a non-index node.") }
            // Follow the last child whose key is not greater than the target.
            var child: UInt32? = nil
            for index in 0..<node.numRecords {
                let record = node.record(index)
                guard try HFSPlusExtentKey(record) <= target else { break }
                child = UInt32(try record.hfsNumber(12, 4))
            }
            guard let child else { return nil }
            number = child
            height -= 1
        }
        throw ScanError.malformed("Invalid extents overflow tree depth.")
    }

    func overflowNode(_ tree: HFSPlusBTree, _ number: UInt32) async throws -> HFSPlusNode {
        if let cached = overflowNodeCache[number] { return cached }
        let node = try HFSPlusNode(try await readNode(tree, number))
        if overflowNodeCache.count >= limits.maxOverflowCachedNodes { overflowNodeCache.removeAll() }
        overflowNodeCache[number] = node
        return node
    }

    func loadTree(_ fork: HFSPlusForkData, fileID: UInt32, name: String) async throws -> HFSPlusBTree {
        let map = try HFSPlusForkMap(try await fullExtents(fork, fileID: fileID), blockSize: header.blockSize)
        guard fork.logicalSize >= 512, fork.logicalSize <= UInt64(map.length) else {
            throw ScanError.malformed("\(name) B-tree size disagrees with its extents.")
        }
        let tree = HFSPlusBTree(map: map, header: try HFSPlusBTreeHeader.parse(try await readFork(map, 0, 512)))
        guard UInt64(tree.header.totalNodes) * UInt64(tree.nodeSize) <= fork.logicalSize else {
            throw ScanError.malformed("\(name) B-tree nodes exceed its file.")
        }
        return tree
    }

    func readNode(_ tree: HFSPlusBTree, _ number: UInt32) async throws -> Data {
        guard number < tree.header.totalNodes else { throw ScanError.malformed("B-tree node number out of range.") }
        return try await readFork(tree.map, Int64(number) * Int64(tree.nodeSize), tree.nodeSize)
    }

    /// Follows the leaf chain from the first leaf. Every node is visited once; a repeat or an
    /// out-of-range link is malformed. Returns the set of leaf nodes reached.
    @discardableResult
    func walkLeaves(_ tree: HFSPlusBTree, _ body: (HFSPlusNode, UInt32) async throws -> Void) async throws -> HFSPlusNodeSet {
        var visited = HFSPlusNodeSet()
        var number = tree.header.firstLeafNode
        while number != 0 {
            try Task.checkCancellation()
            guard number < tree.header.totalNodes, visited.insert(number) else {
                throw ScanError.malformed("B-tree leaf chain cycle.")
            }
            stats.largestNodeSet = max(stats.largestNodeSet, visited.count)
            let node = try HFSPlusNode(try await readNode(tree, number))
            guard node.isLeaf, node.height == 1 else { throw ScanError.malformed("B-tree leaf chain reaches a non-leaf node.") }
            try await body(node, number)
            number = node.fLink
        }
        return visited
    }

    // MARK: Catalog pass 1: folders, indirect nodes, live CNIDs, slack

    func indexLeaf(_ node: HFSPlusNode, number: UInt32) throws {
        for index in 0..<node.numRecords {
            let record = node.record(index)
            let key = try HFSPlusCatalogKey(record)
            switch try record.hfsNumber(key.dataOffset, 2) {
            case HFSPlusCatalogRecordType.folder:
                let folder = try HFSPlusCatalogFolder(record, at: key.dataOffset)
                guard let name = key.name else { throw ScanError.malformed("Invalid folder name encoding.") }
                guard folders[folder.folderID] == nil else { throw ScanError.malformed("Duplicate catalog folder ID.") }
                folders[folder.folderID] = HFSPlusFolderEntry(parent: key.parentID, name: name)
                if key.parentID == HFSPlus.rootFolderID, key.nameUnits == HFSPlus.privateDataFolderName {
                    privateDataFolderID = folder.folderID
                }
            case HFSPlusCatalogRecordType.file:
                let file = try HFSPlusCatalogFile(record, at: key.dataOffset)
                liveFileIDs.append(file.fileID)
                // Indirect nodes are keyed by the private folder's CNID, which is larger than the
                // root's, so the folder record has always been seen by the time they appear.
                if let privateID = privateDataFolderID, key.parentID == privateID,
                   let inode = HFSPlus.indirectNodeNumber(key.nameUnits) {
                    indirectNodes[inode] = number
                }
            case HFSPlusCatalogRecordType.folderThread, HFSPlusCatalogRecordType.fileThread:
                break
            default:
                throw ScanError.malformed("Unknown catalog record type.")
            }
        }
        // Slack is examined in memory only; nothing here can fail the live scan.
        if recoveryDisabled == nil, let catalog,
           let offset = try? deviceOffset(catalog.map, logical: Int64(number) * Int64(node.data.count)) {
            collectCandidates(in: node, deviceOffset: offset, source: .slack, includeRecords: false)
        }
    }

    func isLive(_ fileID: UInt32) -> Bool {
        var low = 0, high = liveFileIDs.count
        while low < high {
            let middle = (low + high) / 2
            if liveFileIDs[middle] < fileID { low = middle + 1 } else { high = middle }
        }
        return low < liveFileIDs.count && liveFileIDs[low] == fileID
    }

    // MARK: Catalog pass 2: emit live files

    func emitLeaf(_ node: HFSPlusNode, number: UInt32) async throws {
        guard let catalog else { return }
        for index in 0..<node.numRecords {
            try Task.checkCancellation()
            let record = node.record(index)
            let key = try HFSPlusCatalogKey(record)
            guard try record.hfsNumber(key.dataOffset, 2) == HFSPlusCatalogRecordType.file else { continue }
            let file = try HFSPlusCatalogFile(record, at: key.dataOffset)
            // Indirect nodes are reached through their links; symlinks, directory-link aliases and
            // the journal's hidden files are not regular files.
            if let privateID = privateDataFolderID, key.parentID == privateID { continue }
            guard file.isRegular, !file.isSymlink, !file.isDirectoryHardLink, !file.isJournalFile else { continue }
            guard let name = key.name else { throw ScanError.malformed("Invalid file name encoding.") }
            guard let path = path(parent: key.parentID, name: name, allowStale: false) else {
                throw ScanError.malformed("Catalog file has no parent folder.")
            }
            var target = file
            var raw = record
            if file.isHardLink {
                guard let resolved = try await indirectNode(file.special) else { stats.unresolvedHardLinks += 1; continue }
                target = resolved.file
                raw = record + resolved.raw
            }
            let mapped = try await content(of: target)
            let recordOffset = try deviceOffset(catalog.map, logical: Int64(number) * Int64(node.data.count) + Int64(node.offsets[index]))
            try await emit(RecoveredFile(name: name, path: path, sizeBytes: mapped.size, modified: HFSPlus.date(target.contentModDate),
                                         isDeleted: false,
                                         sourceMetadata: SourceMetadata(filesystem: .hfsPlus, volumeOffset: extent.offset,
                                                                        recordOffset: recordOffset,
                                                                        allocationStart: UInt64(target.fileID),
                                                                        contiguous: mapped.contiguous, rawRecord: raw),
                                         content: mapped.content))
        }
    }

    /// The path of a file under its parent ("" never occurs; the root is CNID 2). Nil when the
    /// parent chain is broken, too deep, cyclic, or passes through an ambiguous stale folder.
    func path(parent: UInt32, name: String, allowStale: Bool) -> String? {
        var components = [name]
        var current = parent
        var depth = 0
        while current != HFSPlus.rootFolderID {
            guard depth < limits.maxPathDepth else { return nil }
            let folder: HFSPlusFolderEntry
            if let live = folders[current] {
                folder = live
            } else if allowStale, let stale = staleFolders[current], !stale.ambiguous {
                folder = stale.entry
            } else {
                return nil
            }
            components.append(folder.name)
            current = folder.parent
            depth += 1
        }
        return components.reversed().map { "/" + $0 }.joined()
    }

    /// The file record of hard-link indirect node `number`, found in the leaf pass 1 recorded.
    func indirectNode(_ number: UInt32) async throws -> (file: HFSPlusCatalogFile, raw: Data)? {
        guard let catalog, let privateID = privateDataFolderID, let leaf = indirectNodes[number] else { return nil }
        let node: HFSPlusNode
        if let cachedNode, cachedNode.number == leaf { node = cachedNode.node } else {
            node = try HFSPlusNode(try await readNode(catalog, leaf))
            cachedNode = (leaf, node)
        }
        let wanted = Array("iNode\(number)".utf16)
        for index in 0..<node.numRecords {
            let record = node.record(index)
            let key = try HFSPlusCatalogKey(record)
            if key.parentID == privateID, key.nameUnits == wanted,
               try record.hfsNumber(key.dataOffset, 2) == HFSPlusCatalogRecordType.file {
                return (try HFSPlusCatalogFile(record, at: key.dataOffset), record)
            }
        }
        return nil
    }

    /// Size and device-absolute runs of a live file's data fork.
    func content(of file: HFSPlusCatalogFile) async throws -> (size: Int64, content: FileContent, contiguous: Bool) {
        if file.isCompressed {
            // The data fork of a compressed file is empty or holds compressed bytes; the real
            // size lives in the decmpfs attribute. Contents are never mapped.
            stats.compressedFiles += 1
            let size = try await compressedSize(file.fileID) ?? file.dataFork.logicalSize
            return (try signed(size), .unmapped, true)
        }
        let size = try signed(file.dataFork.logicalSize)
        let extents = try await fullExtents(file.dataFork, fileID: file.fileID)
        return (size, try runs(extents, size: size), extents.count <= 1)
    }

    /// Device-absolute runs for validated extents, coalesced and clipped to the logical size.
    func runs(_ extents: [HFSPlusExtent], size: Int64) throws -> FileContent {
        guard size > 0 else { return .runs([]) }
        var runs: [DataRun] = []
        var remaining = size
        for extent in extents where remaining > 0 {
            let offset = try checkedAdd(self.extent.offset, checkedMultiply(Int64(extent.startBlock), header.blockSize))
            let length = min(remaining, try checkedMultiply(Int64(extent.blockCount), header.blockSize))
            if let last = runs.last, let previous = last.deviceOffset, previous + last.length == offset {
                runs[runs.count - 1] = DataRun(deviceOffset: previous, length: last.length + length)
            } else {
                runs.append(DataRun(deviceOffset: offset, length: length))
            }
            remaining -= length
        }
        guard remaining == 0 else { throw ScanError.malformed("File extents shorter than its size.") }
        return .runs(runs)
    }

    // MARK: Compressed files (decmpfs)

    func compressedSize(_ fileID: UInt32) async throws -> UInt64? {
        if !compressedSizesLoaded {
            compressedSizesLoaded = true
            await loadCompressedSizes()
        }
        return compressedSizes[fileID]
    }

    /// Reads every inline `com.apple.decmpfs` attribute once. The attributes tree only supplies
    /// sizes, so an unreadable tree is noted rather than failing the scan.
    func loadCompressedSizes() async {
        let fork = header.attributesFile
        guard fork.logicalSize > 0, !fork.extents.isEmpty else { return }
        do {
            let tree = try await loadTree(fork, fileID: HFSPlus.attributesFileID, name: "Attributes")
            try await walkLeaves(tree) { node, _ in
                for index in 0..<node.numRecords {
                    let record = node.record(index)
                    // HFSPlusAttrKey: keyLength, pad, fileID, startBlock, attrName (length + units).
                    let keyLength = Int(try record.hfsNumber(0, 2))
                    let nameLength = Int(try record.hfsNumber(12, 2))
                    guard keyLength == 12 + 2 * nameLength, nameLength <= 127 else {
                        throw ScanError.malformed("Invalid attribute key.")
                    }
                    guard nameLength == HFSPlus.decmpfsAttributeName.count else { continue }
                    var units: [UInt16] = []
                    for unit in 0..<nameLength { units.append(UInt16(try record.hfsNumber(14 + unit * 2, 2))) }
                    guard units == HFSPlus.decmpfsAttributeName else { continue }
                    let fileID = UInt32(try record.hfsNumber(4, 4))
                    let data = 2 + keyLength
                    // HFSPlusAttrData: recordType (0x10 inline), reserved[2], attrSize, attrData.
                    guard try record.hfsNumber(data, 4) == 0x10 else { continue }
                    let attrSize = Int(try record.hfsNumber(data + 12, 4))
                    guard attrSize >= 16, data + 16 + attrSize <= record.count else { continue }
                    // decmpfs header (little-endian): magic "fpmc", compression type, uncompressed size.
                    guard try record.number(data + 16, 4) == 0x636D_7066 else { continue }
                    guard self.compressedSizes.count < self.limits.maxCompressedEntries else { return }
                    self.compressedSizes[fileID] = try record.number(data + 24, 8)
                }
            }
        } catch is CancellationError {
            return
        } catch {
            stats.notes.append("Attributes tree unreadable; compressed file sizes are unknown.")
        }
    }

    // MARK: Deleted-file recovery (best effort)

    /// Collects catalog file records from a stale leaf node: its records (when the node itself is
    /// not live) and anything intact in its slack. Folder records become fallback path parents.
    func collectCandidates(in node: HFSPlusNode, deviceOffset: Int64, source: HFSPlusCandidateSource, includeRecords: Bool,
                           sequence: UInt32? = nil) {
        if includeRecords {
            for index in 0..<node.numRecords {
                _ = consider(node.data, at: node.offsets[index], limit: node.offsets[index + 1],
                             deviceOffset: deviceOffset + Int64(node.offsets[index]), source: source, sequence: sequence)
            }
        }
        let slack = node.slack
        var position = slack.lowerBound
        while position + 2 + 6 + HFSPlusCatalogFile.size <= slack.upperBound {
            if let consumed = consider(node.data, at: position, limit: slack.upperBound,
                                       deviceOffset: deviceOffset + Int64(position), source: source, sequence: sequence) {
                position += consumed
            } else {
                position += 2
            }
        }
    }

    /// Parses one possible catalog record at `offset`; returns its byte length when it is a
    /// plausible file (recorded as a candidate) or folder (recorded as a stale parent).
    func consider(_ data: Data, at offset: Int, limit: Int, deviceOffset: Int64, source: HFSPlusCandidateSource,
                  sequence: UInt32?) -> Int? {
        guard let key = try? HFSPlusCatalogKey(data, at: offset), key.dataOffset + 2 <= limit,
              let type = try? data.hfsNumber(key.dataOffset, 2), let name = key.name, !name.isEmpty else { return nil }
        if type == HFSPlusCatalogRecordType.folder {
            guard key.dataOffset + HFSPlusCatalogFolder.size <= limit,
                  let folder = try? HFSPlusCatalogFolder(data, at: key.dataOffset) else { return nil }
            guard folder.folderID >= HFSPlus.firstUserCatalogNodeID, folder.folderID < header.nextCatalogID,
                  key.parentID >= HFSPlus.rootFolderID else { return nil }
            recordStaleFolder(folder, entry: HFSPlusFolderEntry(parent: key.parentID, name: name))
            return key.dataOffset - offset + HFSPlusCatalogFolder.size
        }
        guard type == HFSPlusCatalogRecordType.file, key.dataOffset + HFSPlusCatalogFile.size <= limit,
              let file = try? HFSPlusCatalogFile(data, at: key.dataOffset), plausible(file, key: key) else { return nil }
        let length = key.dataOffset - offset + HFSPlusCatalogFile.size
        record(HFSPlusCandidate(file: file, parentID: key.parentID, name: name, recordOffset: deviceOffset,
                                raw: data.subdata(in: offset..<offset + length), source: source, sequence: sequence))
        return length
    }

    /// Keeps the latest stale copy of a folder that is not live. Copies with the same date that
    /// disagree on name or parent make the folder unresolvable for paths.
    ///
    /// A copy filed in the private data folder is skipped: when a folder is removed while still
    /// open (as `rm -r` and `FileManager.removeItem` leave it), HFS+ first moves it there as
    /// "temp<CNID>" until its last reference closes. The journal or a freed node may keep that
    /// interim copy. It is not where the folder lived, and since it carries the same date as the
    /// real copy, it would otherwise make the folder ambiguous and drop every file inside it.
    func recordStaleFolder(_ folder: HFSPlusCatalogFolder, entry: HFSPlusFolderEntry) {
        guard folders[folder.folderID] == nil else { return }
        if let privateID = privateDataFolderID {
            guard entry.parent != privateID else { return }
        } else if entry.name == HFSPlus.deletedName(folder.folderID) {
            // Slack seen before the private folder's record: recognise the interim name instead.
            return
        }
        guard var existing = staleFolders[folder.folderID] else {
            if staleFolders.count < limits.maxStaleFolders {
                staleFolders[folder.folderID] = HFSPlusStaleFolder(entry: entry, modified: folder.modified)
            }
            return
        }
        if folder.modified > existing.modified {
            existing = HFSPlusStaleFolder(entry: entry, modified: folder.modified)
        } else if folder.modified == existing.modified, entry.name != existing.entry.name || entry.parent != existing.entry.parent {
            existing.ambiguous = true
        }
        staleFolders[folder.folderID] = existing
    }

    /// Structural checks a deleted candidate must pass before any bitmap work is spent on it.
    func plausible(_ file: HFSPlusCatalogFile, key: HFSPlusCatalogKey) -> Bool {
        guard key.parentID >= HFSPlus.rootFolderID, key.parentID != privateDataFolderID,
              file.fileID >= HFSPlus.firstUserCatalogNodeID, file.fileID < header.nextCatalogID,
              file.isRegular, !file.isSymlink, !file.isHardLink, !file.isDirectoryHardLink, !file.isJournalFile,
              !file.isCompressed, file.dataFork.logicalSize > 0 else { return false }
        let fork = file.dataFork
        // Every block must be named by the record itself: the overflow records of a deleted file
        // are gone, so a longer file can't be mapped faithfully.
        guard !fork.extents.isEmpty, fork.extentBlocks == UInt64(fork.totalBlocks),
              fork.logicalSize <= UInt64(fork.totalBlocks) * UInt64(header.blockSize) else { return false }
        var previousEnd: UInt64 = 0
        for extent in fork.extents.sorted(by: { $0.startBlock < $1.startBlock }) {
            guard (try? header.validate(extent)) != nil, UInt64(extent.startBlock) >= previousEnd else { return false }
            previousEnd = UInt64(extent.startBlock) + UInt64(extent.blockCount)
        }
        return true
    }

    /// Registers the blocks a plausible record names, whatever later happens to the record: a
    /// superseded or rejected version is still evidence that those blocks were reused.
    func claim(_ candidate: HFSPlusCandidate) {
        let extents = candidate.file.dataFork.extents
        guard !claimsOverflowed, claims.count + extents.count <= limits.maxClaimedRanges else { claimsOverflowed = true; return }
        claims.append(contentsOf: extents.map {
            HFSPlusClaim(start: UInt64($0.startBlock), end: UInt64($0.startBlock) + UInt64($0.blockCount), owner: candidate.file.fileID)
        })
    }

    /// Keeps one candidate per file ID: the newest version (by journal sequence, else by
    /// modification time). Copies that can't be ordered and disagree are ambiguous, so the file is
    /// skipped. Every version's blocks are claimed.
    func record(_ candidate: HFSPlusCandidate) {
        stats.candidatesFound += 1
        if let index = candidateIndex[candidate.file.fileID] {
            let existing = candidates[index]
            if existing.agrees(with: candidate) { return }
            claim(candidate)
            switch candidate.isNewer(than: existing) {
            case true?:
                candidateBytes += candidate.raw.count - existing.raw.count
                candidates[index] = candidate
            case nil:
                candidates[index].conflicted = true
            case false?:
                break
            }
            return
        }
        claim(candidate)
        guard candidates.count < limits.maxCandidates, candidateBytes + candidate.raw.count <= limits.maxCandidateBytes else {
            stats.candidatesDropped += 1
            return
        }
        candidateIndex[candidate.file.fileID] = candidates.count
        candidates.append(candidate)
        candidateBytes += candidate.raw.count
    }

    /// Examines catalog nodes outside the live leaf chain: freed leaves keep their records intact.
    func scanStaleNodes(visited: HFSPlusNodeSet) async throws {
        guard let catalog else { return }
        let nodeSize = catalog.nodeSize, total = catalog.header.totalNodes
        let perChunk = UInt32(max(1, (1 << 20) / nodeSize))
        var number: UInt32 = 1
        do {
            while number < total {
                try Task.checkCancellation()
                let count = min(perChunk, total - number)
                if (0..<count).contains(where: { !visited.contains(number + $0) }) {
                    let chunk = try await readFork(catalog.map, Int64(number) * Int64(nodeSize), Int(count) * nodeSize)
                    for k in 0..<count where !visited.contains(number + k) {
                        try spend(1)
                        stats.staleNodesExamined += 1
                        let data = chunk.subdata(in: Int(k) * nodeSize..<Int(k + 1) * nodeSize)
                        guard Int8(bitPattern: data[8]) == HFSPlusNode.leafKind, let node = try? HFSPlusNode(data) else { continue }
                        collectCandidates(in: node, deviceOffset: try deviceOffset(catalog.map, logical: Int64(number + k) * Int64(nodeSize)),
                                          source: .staleNode, includeRecords: true)
                    }
                }
                number += count
            }
        } catch is HFSPlusWorkBudgetExhausted {
            stats.deletedBudgetExhausted = true
        }
    }

    /// Charges deleted-file work against the per-volume budget.
    func spend(_ amount: UInt64) throws {
        guard amount <= deletedWorkRemaining else { deletedWorkRemaining = 0; throw HFSPlusWorkBudgetExhausted() }
        deletedWorkRemaining -= amount
        stats.deletedWorkSpent += amount
    }

    /// Whether an allocation block is free in the allocation file bitmap (MSB-first bits).
    func blockIsFree(_ block: UInt32) async throws -> Bool {
        guard let allocation, block < header.totalBlocks else { throw ScanError.malformed("Block outside volume.") }
        let byte = Int64(block / 8)
        let page = byte / Self.bitmapPageSize
        let data: Data
        if let cached = bitmapPages[page] { data = cached } else {
            guard !unreadableBitmapPages.contains(page) else { throw ScanError.io("Allocation bitmap page unreadable.") }
            let start = page * Self.bitmapPageSize
            let count = Int(min(Self.bitmapPageSize, try signed(header.allocationFile.logicalSize) - start))
            guard count > 0 else { throw ScanError.malformed("Allocation file too short.") }
            do {
                data = try await readFork(allocation, start, count)
            } catch let error as ScanError {
                if case .io = error { unreadableBitmapPages.insert(page) }
                throw error
            }
            if bitmapPages.count >= 64 { bitmapPages.removeAll() }
            bitmapPages[page] = data
        }
        let index = Int(byte - page * Self.bitmapPageSize)
        guard index < data.count else { throw ScanError.malformed("Allocation file too short.") }
        return data[index] & (0x80 >> UInt8(block % 8)) == 0
    }

    func recoverDeleted() async throws {
        defer { candidates = []; candidateIndex = [:]; staleFolders = [:]; claims = []; bitmapPages = [:] }
        if recoveryDisabled == nil, claimsOverflowed {
            recoveryDisabled = "too many deleted-file records to rule out block reuse"
        }
        if let reason = recoveryDisabled {
            stats.deletedRecoveryDisabled = reason
            return
        }
        candidates.sort { $0.file.fileID < $1.file.fileID }
        var accepted: [(candidate: HFSPlusCandidate, path: String, content: FileContent)] = []
        var bitmapFailures = 0
        do {
            evaluation: for candidate in candidates where !candidate.conflicted && !isLive(candidate.file.fileID) {
                try Task.checkCancellation()
                guard let path = path(parent: candidate.parentID, name: candidate.name, allowStale: true) else { continue }
                let extents = candidate.file.dataFork.extents
                do {
                    for extent in extents {
                        for k in 0..<extent.blockCount {
                            try spend(1)
                            guard try await blockIsFree(extent.startBlock + k) else { continue evaluation }
                        }
                    }
                    accepted.append((candidate, path, try runs(extents, size: try signed(candidate.file.dataFork.logicalSize))))
                } catch ScanError.io(_) {
                    // A bitmap page that can't be read leaves the blocks unconfirmed: skip.
                    bitmapFailures += 1
                } catch ScanError.malformed(_) {
                    // An implausible deleted candidate is skipped and never aborts the scan.
                    continue
                }
            }
        } catch is HFSPlusWorkBudgetExhausted {
            stats.deletedBudgetExhausted = true
        }
        if bitmapFailures > 0 {
            stats.notes.append("Allocation bitmap partly unreadable; \(bitmapFailures) deleted candidates skipped.")
        }
        // A deleted file whose blocks any other record (accepted, rejected or superseded) also
        // names may have had its data overwritten; skip it so data is never misattributed.
        let ranges = accepted.flatMap { entry in
            entry.candidate.file.dataFork.extents.map {
                HFSPlusClaim(start: UInt64($0.startBlock), end: UInt64($0.startBlock) + UInt64($0.blockCount),
                             owner: entry.candidate.file.fileID)
            }
        }
        let overlapping = Self.overlappingOwners(accepted: ranges, evidence: claims)
        for entry in accepted where !overlapping.contains(entry.candidate.file.fileID) {
            let file = entry.candidate.file
            try await emit(RecoveredFile(name: entry.candidate.name, path: entry.path,
                                         sizeBytes: try signed(file.dataFork.logicalSize),
                                         modified: HFSPlus.date(file.contentModDate), isDeleted: true,
                                         sourceMetadata: SourceMetadata(filesystem: .hfsPlus, volumeOffset: extent.offset,
                                                                        recordOffset: entry.candidate.recordOffset,
                                                                        allocationStart: UInt64(file.fileID),
                                                                        contiguous: file.dataFork.extents.count <= 1,
                                                                        rawRecord: entry.candidate.raw),
                                         content: entry.content))
        }
    }

    /// The owners of `accepted` ranges that overlap an `evidence` range of a different owner.
    /// Versions of one file sharing blocks are not an overlap, and only an accepted candidate's
    /// own extents count (an older version of it elsewhere does not make it wrong).
    static func overlappingOwners(accepted: [HFSPlusClaim], evidence: [HFSPlusClaim]) -> Set<UInt32> {
        let claims = evidence.sorted { $0.start < $1.start }
        var flagged: Set<UInt32> = []
        // Over the claims starting before the current accepted range: the furthest reach and the
        // furthest reach of any other owner.
        var first: (end: UInt64, owner: UInt32)? = nil, second: (end: UInt64, owner: UInt32)? = nil
        var next = 0
        for range in accepted.sorted(by: { $0.start < $1.start }) {
            while next < claims.count, claims[next].start < range.start {
                let claim = claims[next]
                if let current = first, current.owner == claim.owner {
                    first = (max(current.end, claim.end), claim.owner)
                } else if first == nil || claim.end > first!.end {
                    second = first
                    first = (claim.end, claim.owner)
                } else if second == nil || claim.end > second!.end {
                    second = (claim.end, claim.owner)
                }
                next += 1
            }
            if let reach = first, reach.owner != range.owner, reach.end > range.start {
                flagged.insert(range.owner); continue
            }
            if let reach = second, reach.end > range.start {
                flagged.insert(range.owner); continue
            }
            // Claims starting inside the range.
            var index = next
            while index < claims.count, claims[index].start < range.end {
                if claims[index].owner != range.owner { flagged.insert(range.owner); break }
                index += 1
            }
        }
        return flagged
    }
}
