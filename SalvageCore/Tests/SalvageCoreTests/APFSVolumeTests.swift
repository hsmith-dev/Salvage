import Foundation
import Testing
@testable import SalvageCore

// APFS tests. Hostile and layout cases use `APFSImageBuilder`, a synthetic container writer built
// from Apple's public APFS Reference layouts (the same source as the parser). The real-volume tests
// create disposable `hdiutil` images in a private temp directory (Story 2.1's spike, kept as a
// regression test); they skip when `hdiutil` isn't available and only ever touch images they made.

private func found(_ events: [ScanEvent]) -> [RecoveredFile] {
    events.compactMap { if case .found(let file) = $0 { file } else { nil } }
}
private func hasMalformed(_ events: [ScanEvent]) -> Bool {
    events.contains { if case .error(.malformed) = $0 { true } else { false } }
}
private func unlocks(_ events: [ScanEvent]) -> [BlockDevice] {
    events.compactMap { if case .unlockRequired(let device) = $0 { device } else { nil } }
}
private func bytes(of file: RecoveredFile, in image: Data) async throws -> Data {
    try await FileContentReader(reader: ImageReader(data: image)).prefix(of: file, limit: file.sizeBytes)
}

/// Drives `APFSContainer` directly over an image, without discovery or the sweep.
private actor Collected {
    var events: [ScanEvent] = []
    func add(_ event: ScanEvent) { events.append(event) }
}
private func containerEvents(_ image: Data, offset: Int64 = 0, device: BlockDevice? = nil,
                             deletedBudget: Int64? = nil) async throws -> [ScanEvent] {
    let collected = Collected()
    let container = APFSContainer(reader: ImageReader(data: image),
                                  extent: VolumeExtent(offset: offset, length: Int64(image.count) - offset, format: .apfs),
                                  device: device, emit: { await collected.add($0) })
    if let deletedBudget { await container.limitDeletedWork(to: deletedBudget) }
    try await container.scan()
    return await collected.events
}

/// Like `containerEvents`, also returning the container for its recorded state.
private func containerScan(_ image: Data, reader: (any BlockReader)? = nil) async throws -> ([ScanEvent], APFSContainer) {
    let collected = Collected()
    let container = APFSContainer(reader: reader ?? ImageReader(data: image),
                                  extent: VolumeExtent(offset: 0, length: Int64(image.count), format: .apfs),
                                  device: nil, emit: { await collected.add($0) })
    try await container.scan()
    return (await collected.events, container)
}

/// Records the offset of every read.
private actor RecordingReader: BlockReader {
    let data: Data
    nonisolated let sizeBytes: Int64
    var offsets: [Int64] = []
    init(data: Data) { self.data = data; sizeBytes = Int64(data.count) }
    func read(at offset: Int64, count: Int) async throws -> Data {
        offsets.append(offset)
        return try await ImageReader(data: data).read(at: offset, count: count)
    }
    func reads(ofBlock block: Int) -> Int { offsets.filter { $0 == Int64(block * APFSImageBuilder.blockSize) }.count }
}

// MARK: - Synthetic image builder

/// A file in a synthetic volume state. Blocks are assigned by the builder.
private struct SynthFile {
    var id: UInt64
    var parent: UInt64
    var name: String
    var data: Data
    var modified: UInt64 = 1_730_000_000_000_000_000
    /// Logical bytes of unwritten (sparse) data before the real data; marks the inode sparse.
    var leadingHole: Int = 0
    var compressed = false
    /// Another file whose data stream this one shares (a clone).
    var cloneOf: UInt64?
    /// Blocks assigned by the builder (or by a test, to alias another file's blocks).
    var firstBlock: Int?
    /// The extent's `crypto_id`.
    var cryptoID: UInt64 = 0
    /// Overrides the inode's sparse flag (by default set exactly when there is a leading hole).
    var sparse: Bool?
    /// Blocks left off the end of the extent, so it covers less than the file's size.
    var extentShortfallBlocks = 0
}
private struct SynthDirectory { var id: UInt64; var parent: UInt64; var name: String }

/// One volume's contents at one transaction.
private struct SynthVolumeState {
    var files: [SynthFile]
    var directories: [SynthDirectory] = []
}

private struct SynthVolume {
    var fsOID: UInt64
    var name: String
    var uuid = UUID()
    var encrypted = false
    var caseInsensitive = true
    /// `om_flags` of the volume's object map (0x2 encrypting, 0x4 decrypting).
    var omapFlags: UInt32 = 0
    /// Flags every entry of the volume's object map `OMAP_VAL_ENCRYPTED`.
    var omapEntriesEncrypted = false
    /// Replaces the filesystem tree root with a hostile node.
    var hostileRoot: HostileRoot?
    /// States per transaction; the last one is live, earlier ones belong to older checkpoints.
    var states: [UInt64: SynthVolumeState]
}
private enum HostileRoot { case tooDeep, selfCycle, ancestorCycle, oversizedKey, wrongIdentity }
/// How a block in an older checkpoint's tree was reused by a node that checksums but isn't it.
private enum ReusedNode { case rootWithAnotherOID, rootWithAnotherXID, leafWithAnotherXID }

/// Writes an APFS container (or bare volume) image with 4096-byte blocks.
private final class APFSImageBuilder {
    static let blockSize = 4096
    static let spacemanOID: UInt64 = 1024, freeQueueOID: UInt64 = 1029
    let blockCount: Int
    var image: Data
    var used: [Bool]
    var nextBlock = 32
    let containerUUID = UUID()
    /// Blocks the main free queue reports as pending frees, by freeing transaction.
    var pendingFrees: [(xid: UInt64, block: Int, count: Int)] = []
    /// Replaces the free-queue contents written at a checkpoint (by default, `pendingFrees` up to it).
    var freeQueueOverride: [UInt64: [(xid: UInt64, block: Int, count: Int)]] = [:]
    /// Where each volume's tree root and superblock landed, keyed "fsOID@xid".
    var fsRootBlocks: [String: Int] = [:]
    var apsbBlocks: [String: Int] = [:]
    /// Leaf blocks of split filesystem trees, keyed "fsOID@xid".
    var fsLeafBlocks: [String: [Int]] = [:]
    /// Each checkpoint's space manager and checkpoint-map block, by xid.
    var spacemanBlocks: [UInt64: Int] = [:]
    var checkpointMapBlocks: [UInt64: Int] = [:]
    /// Splits every object map and filesystem tree with two or more records into a root index
    /// node over two leaves.
    var splitTrees = false
    /// `nx_block_count` recorded in the superblocks, when it should differ from the image's.
    var claimedBlockCount: Int?

    init(blocks: Int = 1024) {
        blockCount = blocks
        image = Data(repeating: 0, count: blocks * Self.blockSize)
        used = [Bool](repeating: false, count: blocks)
        for block in 0..<32 { used[block] = true }
    }

    func allocate(_ count: Int = 1) -> Int {
        let block = nextBlock
        precondition(block + count <= blockCount, "synthetic image is full")
        nextBlock += count
        for b in block..<block + count { used[b] = true }
        return block
    }

    func write(_ block: Int, _ data: Data) {
        precondition(data.count <= Self.blockSize)
        image.replaceSubrange(block * Self.blockSize..<block * Self.blockSize + data.count, with: data)
    }

    func block(_ block: Int) -> Data { image.subdata(in: block * Self.blockSize..<(block + 1) * Self.blockSize) }

    /// Edits an object in place and recomputes its checksum, so only its meaning is wrong.
    func rewrite(_ block: Int, _ edit: (inout Data) -> Void) {
        var data = image.subdata(in: block * Self.blockSize..<(block + 1) * Self.blockSize)
        edit(&data)
        data.put(0, apfsFletcher64(data), 8)
        write(block, data)
    }

    func writeData(_ data: Data) -> Int {
        let blocks = max(1, (data.count + Self.blockSize - 1) / Self.blockSize)
        let first = allocate(blocks)
        image.replaceSubrange(first * Self.blockSize..<first * Self.blockSize + data.count, with: data)
        return first
    }

    /// Finishes an object: header then Fletcher-64 checksum; `body` fills bytes after offset 32.
    func object(oid: UInt64, xid: UInt64, type: UInt32, subtype: UInt32, size: Int = APFSImageBuilder.blockSize,
                _ body: (inout Data) -> Void) -> Data {
        var data = Data(repeating: 0, count: size)
        data.put(8, oid, 8); data.put(16, xid, 8); data.put(24, UInt64(type), 4); data.put(28, UInt64(subtype), 4)
        body(&data)
        data.put(0, apfsFletcher64(data), 8)
        return data
    }

    // B-tree nodes

    struct NodeEntry { let key: Data; let value: Data? }

    /// A node. Variable-size entries unless `fixed` gives the key and value sizes.
    func node(oid: UInt64, xid: UInt64, subtype: UInt32, level: Int, isRoot: Bool, entries: [NodeEntry],
              fixed: (key: Int, value: Int)? = nil, treeFlags: UInt32 = 0, nodeCount: UInt64 = 1,
              corruptKeyLength: Bool = false, levelOverride: Int? = nil) -> Data {
        object(oid: oid, xid: xid, type: isRoot ? APFS.ObjectType.btree : APFS.ObjectType.btreeNode, subtype: subtype) { data in
            var flags: UInt64 = level == 0 ? 2 : 0
            if isRoot { flags |= 1 }
            if fixed != nil { flags |= 4 }
            data.put(32, flags, 2); data.put(34, UInt64(levelOverride ?? level), 2); data.put(36, UInt64(entries.count), 4)
            let entrySize = fixed == nil ? 8 : 4
            let tableLength = max(64, (entries.count * entrySize + 63) / 64 * 64)
            data.put(40, 0, 2); data.put(42, UInt64(tableLength), 2)
            let keyArea = 56 + tableLength
            let valueEnd = Self.blockSize - (isRoot ? 40 : 0)
            var keyOffset = 0, valueOffset = 0
            for (index, entry) in entries.enumerated() {
                data.replaceSubrange(keyArea + keyOffset..<keyArea + keyOffset + entry.key.count, with: entry.key)
                let toc = 56 + index * entrySize
                if let fixed {
                    data.put(toc, UInt64(keyOffset), 2)
                    if let value = entry.value {
                        valueOffset += level == 0 ? fixed.value : 8
                        data.replaceSubrange(valueEnd - valueOffset..<valueEnd - valueOffset + value.count, with: value)
                        data.put(toc + 2, UInt64(valueOffset), 2)
                    } else {
                        data.put(toc + 2, 0xffff, 2)
                    }
                    keyOffset += fixed.key
                } else {
                    data.put(toc, UInt64(keyOffset), 2)
                    data.put(toc + 2, UInt64(corruptKeyLength ? 0x7fff : entry.key.count), 2)
                    let value = entry.value ?? Data()
                    valueOffset += value.count
                    data.replaceSubrange(valueEnd - valueOffset..<valueEnd - valueOffset + value.count, with: value)
                    data.put(toc + 4, UInt64(valueOffset), 2); data.put(toc + 6, UInt64(value.count), 2)
                    keyOffset += entry.key.count
                }
            }
            if isRoot {
                let info = Self.blockSize - 40
                data.put(info, UInt64(treeFlags), 4); data.put(info + 4, UInt64(Self.blockSize), 4)
                data.put(info + 8, UInt64(fixed?.key ?? 0), 4); data.put(info + 12, UInt64(fixed?.value ?? 0), 4)
                data.put(info + 24, UInt64(entries.count), 8); data.put(info + 32, nodeCount, 8)
            }
        }
    }

    func uint64(_ value: UInt64) -> Data { var data = Data(count: 8); data.put(0, value, 8); return data }
    func pair(_ a: UInt64, _ b: UInt64) -> Data { uint64(a) + uint64(b) }

    /// An object map: (oid, xid) → paddr, in one root leaf, or (with `splitTrees`) a root index
    /// node over two leaves. Returns the omap's address.
    func omap(xid: UInt64, entries: [(oid: UInt64, xid: UInt64, address: Int)], flags: UInt32 = 0, entryFlags: UInt32 = 0) -> Int {
        let sorted = entries.sorted { ($0.oid, $0.xid) < ($1.oid, $1.xid) }
        let records = sorted.map { entry in
            var value = Data(count: 16); value.put(0, UInt64(entryFlags), 4); value.put(8, UInt64(entry.address), 8)
            return NodeEntry(key: pair(entry.oid, entry.xid), value: value)
        }
        let root = allocate()
        if splitTrees, records.count >= 2 {
            let halves = [Array(records[..<(records.count / 2)]), Array(records[(records.count / 2)...])]
            var index: [NodeEntry] = []
            for half in halves {
                let leaf = allocate()
                write(leaf, node(oid: UInt64(leaf), xid: xid, subtype: APFS.ObjectType.omap, level: 0, isRoot: false,
                                 entries: half, fixed: (16, 16)))
                index.append(NodeEntry(key: half[0].key, value: uint64(UInt64(leaf))))
            }
            write(root, node(oid: UInt64(root), xid: xid, subtype: APFS.ObjectType.omap, level: 1, isRoot: true,
                             entries: index, fixed: (16, 16), treeFlags: 0x10, nodeCount: 3))
        } else {
            write(root, node(oid: UInt64(root), xid: xid, subtype: APFS.ObjectType.omap, level: 0, isRoot: true,
                             entries: records, fixed: (16, 16), treeFlags: 0x10))
        }
        let omapBlock = allocate()
        write(omapBlock, object(oid: UInt64(omapBlock), xid: xid, type: APFS.ObjectType.omap, subtype: 0) { data in
            data.put(32, UInt64(flags), 4); data.put(40, UInt64(APFS.ObjectType.btree), 4); data.put(48, UInt64(root), 8)
        })
        return omapBlock
    }

    // Filesystem records

    func inodeKey(_ id: UInt64) -> Data { APFSRecordKey.encode(objectID: id, type: APFS.RecordType.inode) }

    func inodeValue(parent: UInt64, privateID: UInt64, mode: UInt16, name: String, modified: UInt64,
                    stream: (size: Int, allocated: Int)?, flags: UInt64 = 0, bsdFlags: UInt32 = 0, uncompressedSize: UInt64 = 0) -> Data {
        var value = Data(count: 92)
        value.put(0, parent, 8); value.put(8, privateID, 8)
        value.put(16, modified, 8); value.put(24, modified, 8); value.put(32, modified, 8); value.put(40, modified, 8)
        value.put(48, flags, 8); value.put(56, 1, 4); value.put(68, UInt64(bsdFlags), 4)
        value.put(80, UInt64(mode), 2); value.put(84, uncompressedSize, 8)
        var fields: [(type: UInt8, payload: Data)] = [(APFS.xfieldName, Data(name.utf8) + [0])]
        if let stream {
            var payload = Data(count: 40); payload.put(0, UInt64(stream.size), 8); payload.put(8, UInt64(stream.allocated), 8)
            fields.append((APFS.xfieldDataStream, payload))
        }
        var blob = Data(count: 4); blob.put(0, UInt64(fields.count), 2)
        var payloads = Data()
        for field in fields {
            var descriptor = Data(count: 4); descriptor.put(0, UInt64(field.type), 1); descriptor.put(2, UInt64(field.payload.count), 2)
            blob += descriptor
            payloads += field.payload + Data(count: (8 - field.payload.count % 8) % 8)
        }
        blob.put(2, UInt64(blob.count + payloads.count - 4), 2)
        return value + blob + payloads
    }

    func directoryRecord(parent: UInt64, name: String, child: UInt64, isDirectory: Bool, hashed: Bool) -> NodeEntry {
        let nameBytes = Data(name.utf8) + [0]
        var key = APFSRecordKey.encode(objectID: parent, type: APFS.RecordType.directoryRecord)
        if hashed {
            var lengthAndHash = Data(count: 4)
            lengthAndHash.put(0, UInt64(nameBytes.count) | UInt64(crc32(Data(name.utf8)) & 0x3f_ffff) << 10, 4)
            key += lengthAndHash
        } else {
            var length = Data(count: 2); length.put(0, UInt64(nameBytes.count), 2); key += length
        }
        key += nameBytes
        var value = Data(count: 18); value.put(0, child, 8); value.put(16, isDirectory ? 4 : 8, 2)
        return NodeEntry(key: key, value: value)
    }

    func extentRecord(streamID: UInt64, logical: Int, length: Int, block: Int, cryptoID: UInt64 = 0) -> NodeEntry {
        var key = APFSRecordKey.encode(objectID: streamID, type: APFS.RecordType.fileExtent); key += uint64(UInt64(logical))
        var value = Data(count: 24); value.put(0, UInt64(length), 8); value.put(8, UInt64(block), 8); value.put(16, cryptoID, 8)
        return NodeEntry(key: key, value: value)
    }

    /// The filesystem tree (one root leaf) for a state; data blocks are written for files that have none.
    func fsTreeEntries(_ state: inout SynthVolumeState, hashed: Bool) -> [NodeEntry] {
        var entries: [NodeEntry] = []
        let root = inodeValue(parent: APFS.rootParentID, privateID: APFS.rootDirectoryID, mode: 0o40755, name: "root", modified: 0, stream: nil)
        entries.append(NodeEntry(key: inodeKey(APFS.rootDirectoryID), value: root))
        let privateDir = inodeValue(parent: APFS.rootParentID, privateID: APFS.privateDirectoryID, mode: 0o40755, name: "private-dir", modified: 0, stream: nil)
        entries.append(NodeEntry(key: inodeKey(APFS.privateDirectoryID), value: privateDir))
        entries.append(directoryRecord(parent: APFS.rootParentID, name: "root", child: APFS.rootDirectoryID, isDirectory: true, hashed: hashed))
        entries.append(directoryRecord(parent: APFS.rootParentID, name: "private-dir", child: APFS.privateDirectoryID, isDirectory: true, hashed: hashed))
        for directory in state.directories {
            entries.append(NodeEntry(key: inodeKey(directory.id), value: inodeValue(parent: directory.parent, privateID: directory.id, mode: 0o40755, name: directory.name, modified: 0, stream: nil)))
            entries.append(directoryRecord(parent: directory.parent, name: directory.name, child: directory.id, isDirectory: true, hashed: hashed))
        }
        for index in state.files.indices {
            var file = state.files[index]
            let blockSize = Self.blockSize
            let allocated = (file.data.count + blockSize - 1) / blockSize * blockSize
            if file.firstBlock == nil, !file.data.isEmpty, file.cloneOf == nil, !file.compressed { file.firstBlock = writeData(file.data) }
            state.files[index] = file
            let size = file.leadingHole + file.data.count
            let streamID = file.cloneOf ?? file.id
            let flags: UInt64 = ((file.sparse ?? (file.leadingHole > 0)) ? APFS.inodeIsSparse : 0) | (file.compressed ? APFS.inodeHasUncompressedSize : 0)
            let stream: (Int, Int)? = file.compressed || size == 0 ? nil : (size, allocated + file.leadingHole)
            entries.append(NodeEntry(key: inodeKey(file.id), value: inodeValue(
                parent: file.parent, privateID: streamID, mode: 0o100644, name: file.name, modified: file.modified, stream: stream,
                flags: flags, bsdFlags: file.compressed ? APFS.bsdCompressed : 0, uncompressedSize: file.compressed ? UInt64(file.data.count) : 0)))
            entries.append(directoryRecord(parent: file.parent, name: file.name, child: file.id, isDirectory: false, hashed: hashed))
            if let block = file.firstBlock, file.cloneOf == nil, !file.compressed {
                entries.append(extentRecord(streamID: file.id, logical: file.leadingHole,
                                            length: allocated - file.extentShortfallBlocks * blockSize, block: block, cryptoID: file.cryptoID))
            }
        }
        let compare = makeAPFSRecordKeyComparator(hashedDirectoryKeys: hashed)
        return entries.sorted { compare($0.key, $1.key) < 0 }
    }

    /// Writes one volume at one transaction: tree root, volume omap, superblock. Returns the APSB block.
    func volume(_ volume: inout SynthVolume, xid: UInt64) -> Int {
        var state = volume.states[xid]!
        let hashed = volume.caseInsensitive
        let rootOID: UInt64 = 0x404, leafOIDs: [UInt64] = [0x405, 0x406]
        let rootBlock = allocate()
        let selfPointer = [NodeEntry(key: inodeKey(2), value: uint64(rootOID))]
        var omapEntries: [(oid: UInt64, xid: UInt64, address: Int)] = [(rootOID, xid, rootBlock)]
        let root: Data
        switch volume.hostileRoot {
        case .tooDeep:
            root = node(oid: rootOID, xid: xid, subtype: APFS.ObjectType.fsTree, level: 1, isRoot: true, entries: selfPointer, levelOverride: 17)
        case .selfCycle:
            // An interior node whose only child resolves (through the object map) to itself.
            root = node(oid: rootOID, xid: xid, subtype: APFS.ObjectType.fsTree, level: 1, isRoot: true, entries: selfPointer)
        case .ancestorCycle:
            // Root (level 2) → index node A (level 1) whose only child resolves back to A: a cycle
            // through an ancestor that isn't the root.
            let inner = allocate()
            let toInner = [NodeEntry(key: inodeKey(2), value: uint64(leafOIDs[0]))]
            write(inner, node(oid: leafOIDs[0], xid: xid, subtype: APFS.ObjectType.fsTree, level: 1, isRoot: false, entries: toInner))
            omapEntries.append((leafOIDs[0], xid, inner))
            root = node(oid: rootOID, xid: xid, subtype: APFS.ObjectType.fsTree, level: 2, isRoot: true, entries: toInner, nodeCount: 2)
        case .oversizedKey:
            root = node(oid: rootOID, xid: xid, subtype: APFS.ObjectType.fsTree, level: 0, isRoot: true,
                        entries: fsTreeEntries(&state, hashed: hashed), corruptKeyLength: true)
        case .wrongIdentity:
            // A well-formed root whose transaction isn't the one its object-map entry records.
            root = node(oid: rootOID, xid: xid + 100, subtype: APFS.ObjectType.fsTree, level: 0, isRoot: true,
                        entries: fsTreeEntries(&state, hashed: hashed), treeFlags: 0x40)
        case nil:
            let entries = fsTreeEntries(&state, hashed: hashed)
            if splitTrees, entries.count >= 2 {
                let halves = [Array(entries[..<(entries.count / 2)]), Array(entries[(entries.count / 2)...])]
                var index: [NodeEntry] = [], leaves: [Int] = []
                for (half, oid) in zip(halves, leafOIDs) {
                    let leaf = allocate()
                    write(leaf, node(oid: oid, xid: xid, subtype: APFS.ObjectType.fsTree, level: 0, isRoot: false, entries: half))
                    omapEntries.append((oid, xid, leaf)); leaves.append(leaf)
                    index.append(NodeEntry(key: half[0].key, value: uint64(oid)))
                }
                fsLeafBlocks["\(volume.fsOID)@\(xid)"] = leaves
                root = node(oid: rootOID, xid: xid, subtype: APFS.ObjectType.fsTree, level: 1, isRoot: true,
                            entries: index, treeFlags: 0x40, nodeCount: 3)
            } else {
                root = node(oid: rootOID, xid: xid, subtype: APFS.ObjectType.fsTree, level: 0, isRoot: true,
                            entries: entries, treeFlags: 0x40)
            }
        }
        write(rootBlock, root)
        volume.states[xid] = state
        fsRootBlocks["\(volume.fsOID)@\(xid)"] = rootBlock
        let omapBlock = omap(xid: xid, entries: omapEntries, flags: volume.omapFlags,
                             entryFlags: volume.omapEntriesEncrypted ? APFS.omapValueEncrypted : 0)
        let apsb = allocate()
        apsbBlocks["\(volume.fsOID)@\(xid)"] = apsb
        write(apsb, object(oid: volume.fsOID, xid: xid, type: APFS.ObjectType.fs, subtype: 0) { data in
            data.put(32, APFS.volumeMagic, 4)
            data.put(56, hashed ? APFS.incompatCaseInsensitive : 0, 8)
            data.put(116, UInt64(APFS.ObjectType.btree) | UInt64(APFS.objectPhysical), 4)
            data.put(128, UInt64(omapBlock), 8); data.put(136, rootOID, 8)
            data.put(152, 0, 8)
            data.replaceSubrange(240..<256, with: withUnsafeBytes(of: volume.uuid.uuid) { Data($0) })
            data.put(264, volume.encrypted ? 0 : APFS.fsUnencrypted, 8)
            data.replaceSubrange(704..<704 + volume.name.utf8.count, with: Data(volume.name.utf8))
        })
        return apsb
    }

    /// Bare volume image: the APSB at block 0 (Story 2.4's unlocked volume device).
    func bareVolume(_ target: inout SynthVolume, xid: UInt64) {
        let apsb = volume(&target, xid: xid)
        image.replaceSubrange(0..<Self.blockSize, with: image.subdata(in: apsb * Self.blockSize..<(apsb + 1) * Self.blockSize))
    }

    // Container

    /// Writes checkpoints for every transaction in the volumes' states (ascending) and block 0.
    /// `freeBlocks` are cleared in the bitmap after everything is placed.
    func container(_ volumes: inout [SynthVolume], descriptorBlocks: Int = 8, dataBlocks: Int = 16,
                   corruptOmaps: Bool = false, freeBlocks: [Int] = []) {
        let xids = Set(volumes.flatMap { $0.states.keys }).sorted()
        precondition(xids.count * 2 <= descriptorBlocks)
        let descriptorBase = 1, dataBase = 1 + descriptorBlocks
        var apsbs: [UInt64: [(UInt64, Int)]] = [:]
        for xid in xids {
            for index in volumes.indices where volumes[index].states[xid] != nil {
                apsbs[xid, default: []].append((volumes[index].fsOID, volume(&volumes[index], xid: xid)))
            }
        }
        for block in freeBlocks { used[block] = false }
        var latest = Data()
        for (slot, xid) in xids.enumerated() {
            let omapBlock = omap(xid: xid, entries: apsbs[xid]!.map { ($0.0, xid, $0.1) })
            if corruptOmaps { image[omapBlock * Self.blockSize + 40] ^= 1 }
            // Ephemeral objects for this checkpoint: spaceman (+ cib, bitmap) and the free queue tree.
            let dataSlot = dataBase + slot * 4
            let cib = allocate(), bitmap = allocate()
            var bits = Data(count: Self.blockSize)
            for block in 0..<blockCount where used[block] { bits[block / 8] |= 1 << (block % 8) }
            write(bitmap, bits)
            write(cib, object(oid: UInt64(cib), xid: xid, type: APFS.ObjectType.spacemanCIB, subtype: 0) { data in
                data.put(36, 1, 4); data.put(40, xid, 8); data.put(48, 0, 8)
                data.put(56, UInt64(self.blockCount), 4); data.put(60, UInt64(self.used.filter { !$0 }.count), 4); data.put(64, UInt64(bitmap), 8)
            })
            let frees = (freeQueueOverride[xid] ?? pendingFrees.filter { $0.xid <= xid }).sorted { ($0.xid, $0.block) < ($1.xid, $1.block) }
            spacemanBlocks[xid] = dataSlot
            write(dataSlot, object(oid: Self.spacemanOID, xid: xid, type: APFS.ObjectType.spaceman, subtype: 0) { data in
                data.put(32, UInt64(Self.blockSize), 4); data.put(36, UInt64(Self.blockSize * 8), 4); data.put(40, 126, 4); data.put(44, 507, 4)
                data.put(48, UInt64(self.blockCount), 8); data.put(56, 1, 8); data.put(64, 1, 4); data.put(68, 0, 4)
                data.put(80, 0x200, 4); data.put(0x200, UInt64(cib), 8)
                data.put(240, UInt64(frees.count), 8); data.put(248, frees.isEmpty ? 0 : Self.freeQueueOID, 8)
            })
            write(dataSlot + 1, node(oid: Self.freeQueueOID, xid: xid, subtype: APFS.ObjectType.spacemanFreeQueue, level: 0, isRoot: true,
                                     entries: frees.map { NodeEntry(key: pair($0.xid, UInt64($0.block)), value: $0.count == 1 ? nil : uint64(UInt64($0.count))) },
                                     fixed: (16, 8), treeFlags: 0xe))
            let mapBlock = descriptorBase + slot * 2, superblockBlock = mapBlock + 1
            checkpointMapBlocks[xid] = mapBlock
            write(mapBlock, object(oid: UInt64(mapBlock), xid: xid, type: APFS.ObjectType.checkpointMap, subtype: 0) { data in
                data.put(32, 1, 4); data.put(36, 2, 4)
                for (index, (type, oid, address)) in [(APFS.ObjectType.spaceman, Self.spacemanOID, dataSlot),
                                                      (APFS.ObjectType.btree, Self.freeQueueOID, dataSlot + 1)].enumerated() {
                    let base = 40 + index * 40
                    data.put(base, UInt64(type) | UInt64(APFS.objectEphemeral), 4); data.put(base + 8, UInt64(Self.blockSize), 4)
                    data.put(base + 24, oid, 8); data.put(base + 32, UInt64(address), 8)
                }
            })
            let superblock = object(oid: 1, xid: xid, type: APFS.ObjectType.nxSuperblock, subtype: 0) { data in
                data.put(32, APFS.nxMagic, 4); data.put(36, UInt64(Self.blockSize), 4)
                data.put(40, UInt64(self.claimedBlockCount ?? self.blockCount), 8)
                data.replaceSubrange(72..<88, with: withUnsafeBytes(of: self.containerUUID.uuid) { Data($0) })
                data.put(104, UInt64(descriptorBlocks), 4); data.put(108, UInt64(dataBlocks), 4)
                data.put(112, UInt64(descriptorBase), 8); data.put(120, UInt64(dataBase), 8)
                data.put(136, UInt64(slot * 2), 4); data.put(140, 2, 4)
                data.put(152, Self.spacemanOID, 8); data.put(160, UInt64(omapBlock), 8)
                data.put(180, UInt64(volumes.count), 4)
                for (index, volume) in volumes.enumerated() where volume.states[xid] != nil { data.put(184 + index * 8, volume.fsOID, 8) }
            }
            write(superblockBlock, superblock)
            latest = superblock
        }
        write(0, latest)
    }
}

private func simpleVolume(fsOID: UInt64 = 1026, name: String = "Synth", xid: UInt64 = 6) -> SynthVolume {
    SynthVolume(fsOID: fsOID, name: name, states: [xid: SynthVolumeState(
        files: [SynthFile(id: 18, parent: 2, name: "hello.txt", data: Data("hello apfs".utf8)),
                SynthFile(id: 19, parent: 16, name: "big.bin", data: Data((0..<9000).map { UInt8(truncatingIfNeeded: $0 &* 31) })),
                SynthFile(id: 20, parent: 17, name: "empty.txt", data: Data())],
        directories: [SynthDirectory(id: 16, parent: 2, name: "docs"), SynthDirectory(id: 17, parent: 16, name: "nested")])])
}

// MARK: - Synthetic container tests

@Suite("APFS synthetic containers")
struct APFSSyntheticTests {
    @Test func liveFilesWithPathsSizesTimestampsAndContent() async throws {
        let builder = APFSImageBuilder()
        var volumes = [simpleVolume()]
        builder.container(&volumes)
        let events = await scan(builder.image)
        #expect(events.last == .completed)
        let files = found(events)
        #expect(files.map(\.path) == ["/hello.txt", "/docs/big.bin", "/docs/nested/empty.txt"])
        #expect(files.map(\.sizeBytes) == [10, 9000, 0])
        #expect(files.allSatisfy { !$0.isDeleted && $0.sourceMetadata.filesystem == .apfs })
        #expect(files[0].modified == Date(timeIntervalSince1970: 1_730_000_000))
        #expect(files[0].sourceMetadata.allocationStart == 18)
        for (file, expected) in zip(files, volumes[0].states[6]!.files) {
            #expect(try await bytes(of: file, in: builder.image) == expected.data)
        }
        #expect(files[2].content == .runs([]))
        #expect(events.contains(.progress(bytesScanned: Int64(builder.image.count), totalBytes: Int64(builder.image.count))))
    }

    @Test func containerInsideMBRPartitionMapsDeviceAbsoluteRuns() async throws {
        let builder = APFSImageBuilder(blocks: 256)
        var volumes = [simpleVolume()]
        builder.container(&volumes)
        var image = Data(repeating: 0, count: 512 * 8) + builder.image
        image.put(446 + 4, 0xaf, 1); image.put(446 + 8, 8, 4); image.put(446 + 12, UInt64(builder.image.count / 512), 4)
        image.put(510, 0xaa55, 2)
        let events = await scan(image)
        #expect(events.last == .completed)
        let files = found(events)
        #expect(files.count == 3)
        #expect(files.allSatisfy { $0.sourceMetadata.volumeOffset == 4096 })
        let big = try #require(files.first { $0.name == "big.bin" })
        #expect(try await bytes(of: big, in: image) == volumes[0].states[6]!.files[1].data)
    }

    @Test func sparseCloneAndCompressedFiles() async throws {
        let builder = APFSImageBuilder()
        var volume = simpleVolume()
        volume.states[6]!.files += [
            SynthFile(id: 30, parent: 2, name: "sparse.bin", data: Data(repeating: 7, count: 100), leadingHole: 8192),
            SynthFile(id: 31, parent: 2, name: "clone.bin", data: volume.states[6]!.files[1].data, cloneOf: 19),
            SynthFile(id: 32, parent: 2, name: "packed.txt", data: Data(repeating: 1, count: 777), compressed: true),
        ]
        var volumes = [volume]
        builder.container(&volumes)
        let events = await scan(builder.image)
        #expect(events.last == .completed)
        let files = found(events)
        let sparse = try #require(files.first { $0.name == "sparse.bin" })
        #expect(sparse.sizeBytes == 8292)
        #expect(try await bytes(of: sparse, in: builder.image) == Data(count: 8192) + Data(repeating: 7, count: 100))
        if case .runs(let runs) = sparse.content { #expect(runs.first?.deviceOffset == nil && runs.count == 2) } else { Issue.record("sparse file has no runs") }
        let clone = try #require(files.first { $0.name == "clone.bin" })
        #expect(try await bytes(of: clone, in: builder.image) == volumes[0].states[6]!.files[1].data)
        let packed = try #require(files.first { $0.name == "packed.txt" })
        #expect(packed.sizeBytes == 777 && packed.content == .unmapped)
    }

    @Test func encryptedVolumeYieldsUnlockRequiredAndOthersAreScanned() async throws {
        let builder = APFSImageBuilder()
        var locked = SynthVolume(fsOID: 1030, name: "Vault", encrypted: true, states: [6: SynthVolumeState(files: [])])
        locked.uuid = UUID(uuidString: "0BADF00D-1234-4ABC-9DEF-00C0FFEE0001")!
        var volumes = [locked, simpleVolume()]
        builder.container(&volumes)
        let device = BlockDevice(bsdName: "disk9", displayName: "Test", sizeBytes: 1, isInternal: false, isBootVolume: false)
        let events = try await containerEvents(builder.image, device: device)
        let unlock = try #require(unlocks(events).first)
        #expect(unlock.bsdName == "disk9")
        #expect(unlock.encryptedVolumeUUID == "0BADF00D-1234-4ABC-9DEF-00C0FFEE0001")
        #expect(unlock.encryptedVolumeName == "Vault")
        #expect(found(events).count == 3)
        // Without a device, a placeholder carries the volume name.
        let placeholder = try #require(unlocks(try await containerEvents(builder.image)).first)
        #expect(placeholder.bsdName == "" && placeholder.displayName == "Vault")
        let session = await scan(builder.image)
        #expect(session.last == .completed && unlocks(session).count == 1)
    }

    @Test func badLiveObjectChecksumIsMalformedAndEarlierDiscoveriesSurvive() async throws {
        let builder = APFSImageBuilder()
        var volumes = [simpleVolume(fsOID: 1026, name: "Good"), simpleVolume(fsOID: 1027, name: "Bad")]
        builder.container(&volumes)
        var image = builder.image
        // Flip one byte of the second volume's live tree root: its checksum no longer verifies.
        image[builder.fsRootBlocks["1027@6"]! * APFSImageBuilder.blockSize + 200] ^= 1
        let events = await scan(image)
        #expect(found(events).count == 3)
        #expect(hasMalformed(events))
        #expect(!events.contains(.completed))
    }

    @Test func noValidCheckpointNeverSucceedsEmpty() async throws {
        let builder = APFSImageBuilder()
        var volumes = [simpleVolume()]
        builder.container(&volumes, corruptOmaps: true)
        let events = await scan(builder.image)
        #expect(hasMalformed(events) && found(events).isEmpty && !events.contains(.completed))
        var zeroed = builder.image
        zeroed[0] ^= 1
        #expect(hasMalformed(await scan(zeroed)))
        // A bare signature with nothing behind it is damage, not an empty volume.
        var stub = Data(repeating: 0, count: 16 * 512); stub.text(32, "NXSB")
        #expect(await scan(stub).contains { if case .error = $0 { true } else { false } })
    }

    @Test(arguments: [HostileRoot.tooDeep, .selfCycle, .ancestorCycle, .oversizedKey, .wrongIdentity])
    fileprivate func hostileTreesTerminateAsMalformed(_ hostile: HostileRoot) async throws {
        // Depth beyond 16, a child pointer that resolves to the root, one that resolves to an
        // ancestor index node below the root, a key length past the node's end, and a live root
        // whose transaction doesn't match its object-map entry all stop with `malformed`, with a
        // good volume's files already emitted.
        let builder = APFSImageBuilder()
        var bad = simpleVolume(fsOID: 1027, name: "Bad"); bad.hostileRoot = hostile
        var volumes = [simpleVolume(), bad]
        builder.container(&volumes)
        let events = await scan(builder.image)
        #expect(found(events).count == 3)
        #expect(hasMalformed(events))
        #expect(!events.contains(.completed))
    }

    @Test func bareVolumeDeviceIsParsedAsOneVolume() async throws {
        let builder = APFSImageBuilder(blocks: 256)
        var volume = simpleVolume()
        builder.bareVolume(&volume, xid: 6)
        let events = await scan(builder.image)
        #expect(events.last == .completed)
        let files = found(events)
        #expect(files.map(\.path) == ["/hello.txt", "/docs/big.bin", "/docs/nested/empty.txt"])
        #expect(try await bytes(of: files[1], in: builder.image) == volume.states[6]!.files[1].data)
    }

    @Test func encryptedBareVolumeDeviceIsReadAsPlaintext() async throws {
        // A bare volume device is the unlocked device (Story 2.4): its superblock still says
        // encrypted and its object-map entries are flagged encrypted, but what it serves is
        // plaintext. It is parsed, not reported as needing an unlock, through a split tree so
        // that child nodes are resolved through encrypted-flagged entries too.
        let builder = APFSImageBuilder(blocks: 256)
        builder.splitTrees = true
        var volume = simpleVolume()
        volume.name = "Unlocked"; volume.encrypted = true; volume.omapEntriesEncrypted = true
        volume.states[6]!.files[1].cryptoID = 7
        builder.bareVolume(&volume, xid: 6)
        let events = await scan(builder.image)
        #expect(events.last == .completed)
        #expect(unlocks(events).isEmpty)
        let files = found(events)
        #expect(files.map(\.path) == ["/hello.txt", "/docs/big.bin", "/docs/nested/empty.txt"])
        for (file, expected) in zip(files, volume.states[6]!.files) {
            #expect(try await bytes(of: file, in: builder.image) == expected.data)
        }
        // In a container the same entry flag means ciphertext, so the volume is refused.
        let contained = APFSImageBuilder()
        var flagged = simpleVolume(); flagged.omapEntriesEncrypted = true
        var volumes = [flagged]
        contained.container(&volumes)
        await #expect(throws: ScanError.unsupportedFilesystem) { _ = try await containerEvents(contained.image) }
        #expect(found(await scan(contained.image)).isEmpty)
    }

    @Test(arguments: [APFS.omapEncrypting, APFS.omapDecrypting])
    func volumeBeingEncryptedOrDecryptedIsUnmapped(_ flags: UInt32) async throws {
        // Mid-conversion, any block may be plaintext or ciphertext and nothing per extent says
        // which, so no file content is mapped; metadata is still reported.
        let builder = APFSImageBuilder()
        var volume = simpleVolume(); volume.omapFlags = flags
        var volumes = [volume]
        builder.container(&volumes)
        let events = await scan(builder.image)
        #expect(events.last == .completed)
        let files = found(events)
        #expect(files.map(\.path) == ["/hello.txt", "/docs/big.bin", "/docs/nested/empty.txt"])
        #expect(files.map(\.sizeBytes) == [10, 9000, 0])
        #expect(files[0].content == .unmapped && files[1].content == .unmapped)
        // The bare-volume path applies the same object-map check.
        let bare = APFSImageBuilder(blocks: 256)
        var bareVolume = simpleVolume(); bareVolume.omapFlags = flags
        bare.bareVolume(&bareVolume, xid: 6)
        let bareFiles = found(await scan(bare.image))
        #expect(bareFiles.count == 3 && bareFiles[0].content == .unmapped && bareFiles[1].content == .unmapped)
    }

    @Test func extentWithACryptoIDIsUnmappedInAContainerButReadOnABareVolume() async throws {
        let builder = APFSImageBuilder()
        var volume = simpleVolume(); volume.states[6]!.files[1].cryptoID = 3
        var volumes = [volume]
        builder.container(&volumes)
        let events = await scan(builder.image)
        #expect(events.last == .completed)
        let files = found(events)
        let big = try #require(files.first { $0.name == "big.bin" })
        #expect(big.sizeBytes == 9000 && big.content == .unmapped)
        let hello = try #require(files.first { $0.name == "hello.txt" })
        #expect(try await bytes(of: hello, in: builder.image) == Data("hello apfs".utf8))
        // On the unlocked device the same crypto_id is expected and the bytes are plaintext.
        let bare = APFSImageBuilder(blocks: 256)
        var bareVolume = simpleVolume(); bareVolume.states[6]!.files[1].cryptoID = 3
        bare.bareVolume(&bareVolume, xid: 6)
        let bareBig = try #require(found(await scan(bare.image)).first { $0.name == "big.bin" })
        #expect(try await bytes(of: bareBig, in: bare.image) == bareVolume.states[6]!.files[1].data)
    }

    @Test func gapsAndShortTailsInNonSparseFilesAreUnmapped() async throws {
        // Without the sparse flag, a missing extent means the list is incomplete, not zeros.
        let builder = APFSImageBuilder()
        var volume = simpleVolume()
        volume.states[6]!.files += [
            SynthFile(id: 33, parent: 2, name: "gap.bin", data: Data(repeating: 7, count: 100), leadingHole: 8192, sparse: false),
            SynthFile(id: 34, parent: 2, name: "short.bin", data: Data(repeating: 9, count: 9000), extentShortfallBlocks: 1),
            SynthFile(id: 35, parent: 2, name: "sparse-tail.bin", data: Data(repeating: 5, count: 9000), sparse: true, extentShortfallBlocks: 1),
        ]
        var volumes = [volume]
        builder.container(&volumes)
        let events = await scan(builder.image)
        #expect(events.last == .completed)
        let files = found(events)
        let gap = try #require(files.first { $0.name == "gap.bin" })
        #expect(gap.sizeBytes == 8292 && gap.content == .unmapped)
        let short = try #require(files.first { $0.name == "short.bin" })
        #expect(short.sizeBytes == 9000 && short.content == .unmapped)
        // A sparse inode's short tail is a hole.
        let sparseTail = try #require(files.first { $0.name == "sparse-tail.bin" })
        #expect(try await bytes(of: sparseTail, in: builder.image) == Data(repeating: 5, count: 8192) + Data(count: 808))
        let big = try #require(files.first { $0.name == "big.bin" })
        #expect(try await bytes(of: big, in: builder.image) == volume.states[6]!.files[1].data)
    }

    @Test func multiLevelTreesAreWalkedAndSearched() async throws {
        // Object maps (fixed-size records) and filesystem trees are each a root index node over
        // two leaves: lookups go through interior nodes and the walk climbs between leaves.
        let builder = APFSImageBuilder()
        builder.splitTrees = true
        var volumes = [simpleVolume(fsOID: 1026, name: "One"), simpleVolume(fsOID: 1027, name: "Two")]
        builder.container(&volumes)
        let fsRoot = builder.fsRootBlocks["1026@6"]!
        let root = try APFSBTreeNode(builder.block(fsRoot), address: Int64(fsRoot), inheritedInfo: nil)
        #expect(root.level == 1 && root.keyCount == 2 && builder.fsLeafBlocks["1026@6"]?.count == 2)
        let containerOmap = Int(try builder.block(0).number(160, 8))
        let omapRoot = Int(try builder.block(containerOmap).number(48, 8))
        let omapNode = try APFSBTreeNode(builder.block(omapRoot), address: Int64(omapRoot), inheritedInfo: nil)
        #expect(omapNode.level == 1 && omapNode.keyCount == 2)
        let events = await scan(builder.image)
        #expect(events.last == .completed)
        let files = found(events)
        #expect(files.map(\.path) == ["/hello.txt", "/docs/big.bin", "/docs/nested/empty.txt",
                                       "/hello.txt", "/docs/big.bin", "/docs/nested/empty.txt"])
        for (file, expected) in zip(files, volumes[0].states[6]!.files + volumes[1].states[6]!.files) {
            #expect(try await bytes(of: file, in: builder.image) == expected.data)
        }
    }
}

// MARK: - Deleted files

@Suite("APFS deleted files from older checkpoints")
struct APFSDeletedFileTests {
    /// Live state at xid 6 lacks `gone.txt` and `gone-big.bin`, which xid 5 still has.
    fileprivate func twoCheckpointVolume() -> SynthVolume {
        var volume = simpleVolume(xid: 6)
        var older = volume.states[6]!
        older.files += [SynthFile(id: 22, parent: 16, name: "gone.txt", data: Data("to be deleted".utf8)),
                        SynthFile(id: 23, parent: 17, name: "gone-big.bin", data: Data((0..<100_000).map { UInt8(truncatingIfNeeded: $0 ^ ($0 >> 7)) }))]
        volume.states[5] = older
        return volume
    }

    /// The deleted files' first blocks in `twoCheckpointVolume`'s xid-5 state (allocation is deterministic).
    fileprivate func deletedBlocks(splitTrees: Bool = false) -> (gone: Int, goneBig: Int) {
        let probe = APFSImageBuilder()
        probe.splitTrees = splitTrees
        var volumes = [twoCheckpointVolume()]
        probe.container(&volumes)
        let old = volumes[0].states[5]!.files
        return (old.first { $0.name == "gone.txt" }!.firstBlock!, old.first { $0.name == "gone-big.bin" }!.firstBlock!)
    }

    @Test func deletedFilesWithPendingFreesAreRecoveredByteIdentical() async throws {
        // Freed at xid 6, after the xid-5 checkpoint that still lists them; still allocated in the
        // bitmap and queued, so nothing can have reused them.
        let (gone, goneBig) = deletedBlocks()
        let rebuilt = APFSImageBuilder()
        rebuilt.pendingFrees = [(6, gone, 1), (6, goneBig, 25)]
        var again = [twoCheckpointVolume()]
        rebuilt.container(&again)
        let events = await scan(rebuilt.image)
        #expect(events.last == .completed)
        let deleted = found(events).filter(\.isDeleted)
        #expect(deleted.map(\.path) == ["/docs/gone.txt", "/docs/nested/gone-big.bin"])
        #expect(found(events).filter { !$0.isDeleted }.count == 3)
        for file in deleted {
            let expected = again[0].states[5]!.files.first { $0.name == file.name }!.data
            #expect(try await bytes(of: file, in: rebuilt.image) == expected)
            #expect(file.overwriteConfidence == 0 && file.sourceMetadata.allocationStart == (file.name == "gone.txt" ? 22 : 23))
        }
    }

    @Test func deletedFileWhoseBlocksAreInUseIsNotEmitted() async throws {
        let builder = APFSImageBuilder()
        var volumes = [twoCheckpointVolume()]
        builder.container(&volumes)
        let events = await scan(builder.image)
        #expect(events.last == .completed)
        #expect(found(events).filter(\.isDeleted).isEmpty)
    }

    @Test func blocksPendingInTheFreeQueueCountAsFree() async throws {
        let builder = APFSImageBuilder()
        var probe = [twoCheckpointVolume()]
        builder.container(&probe)
        let old = probe[0].states[5]!.files
        let gone = old.first { $0.name == "gone.txt" }!, goneBig = old.first { $0.name == "gone-big.bin" }!
        // Freed at xid 6 (after the xid-5 checkpoint that still lists them): recoverable.
        let queued = APFSImageBuilder()
        queued.pendingFrees = [(6, gone.firstBlock!, 1), (6, goneBig.firstBlock!, 25)]
        var volumes = [twoCheckpointVolume()]
        queued.container(&volumes)
        let events = await scan(queued.image)
        #expect(events.last == .completed)
        #expect(found(events).filter(\.isDeleted).map(\.name) == ["gone.txt", "gone-big.bin"])
        // Freed before the candidate's checkpoint: those blocks can't have held this file.
        let stale = APFSImageBuilder()
        stale.pendingFrees = [(4, gone.firstBlock!, 1), (4, goneBig.firstBlock!, 25)]
        var staleVolumes = [twoCheckpointVolume()]
        stale.container(&staleVolumes)
        #expect(found(await scan(stale.image)).filter(\.isDeleted).isEmpty)
    }

    @Test func overlappingDeletedCandidatesAreBothSkipped() async throws {
        let (gone, _) = deletedBlocks()
        let builder = APFSImageBuilder()
        builder.pendingFrees = [(6, gone, 1)]
        var volume = twoCheckpointVolume()
        // A second deleted file in the same old checkpoint claiming gone.txt's block.
        volume.states[5]!.files.append(SynthFile(id: 24, parent: 2, name: "alias.txt", data: Data("aliased".utf8), firstBlock: gone))
        var volumes = [volume]
        builder.container(&volumes)
        let events = await scan(builder.image)
        #expect(events.last == .completed)
        let deleted = found(events).filter(\.isDeleted).map(\.name)
        #expect(!deleted.contains("gone.txt") && !deleted.contains("alias.txt"))
        #expect(volumes[0].states[5]!.files.first { $0.name == "gone.txt" }!.firstBlock == gone)
    }

    @Test func overlapIsResolvedAcrossVolumes() async throws {
        // Volumes share the container's blocks: a deleted candidate in another volume claiming
        // gone.txt's block makes both suspect, so neither is emitted.
        let (gone, _) = deletedBlocks()
        let builder = APFSImageBuilder()
        builder.pendingFrees = [(6, gone, 1)]
        let other = SynthVolume(fsOID: 1027, name: "Other", states: [
            5: SynthVolumeState(files: [SynthFile(id: 40, parent: 2, name: "alias.txt", data: Data("aliased".utf8), firstBlock: gone)]),
            6: SynthVolumeState(files: [])])
        var volumes = [twoCheckpointVolume(), other]
        builder.container(&volumes)
        #expect(volumes[0].states[5]!.files.first { $0.name == "gone.txt" }!.firstBlock == gone)
        let events = await scan(builder.image)
        #expect(events.last == .completed)
        let deleted = found(events).filter(\.isDeleted).map(\.name)
        #expect(!deleted.contains("gone.txt") && !deleted.contains("alias.txt"))
        // Without the other volume's claim, gone.txt is recovered from the same layout.
        let alone = APFSImageBuilder()
        alone.pendingFrees = [(6, gone, 1)]
        var single = [twoCheckpointVolume()]
        alone.container(&single)
        #expect(found(await scan(alone.image)).filter(\.isDeleted).map(\.name) == ["gone.txt"])
    }

    @Test func exhaustedBudgetStopsDeletedRecoveryOnly() async throws {
        let (gone, _) = deletedBlocks()
        let builder = APFSImageBuilder()
        builder.pendingFrees = [(6, gone, 1)]
        var volumes = [twoCheckpointVolume()]
        builder.container(&volumes)
        let limited = try await containerEvents(builder.image, deletedBudget: 1)
        #expect(found(limited).count == 3 && found(limited).allSatisfy { !$0.isDeleted })
        let unlimited = try await containerEvents(builder.image)
        #expect(found(unlimited).filter(\.isDeleted).map(\.name) == ["gone.txt"])
    }

    @Test func blockReusedAndFreedAgainIsNotRecovered() async throws {
        // Each image keeps gone-big.bin properly pending (the control) and varies gone.txt's block.
        let (gone, goneBig) = deletedBlocks()
        func deletedNames(_ configure: (APFSImageBuilder) -> Void, freeBlocks: [Int] = []) async -> [String] {
            let builder = APFSImageBuilder()
            builder.pendingFrees = [(6, goneBig, 25)]
            configure(builder)
            var volumes = [twoCheckpointVolume()]
            builder.container(&volumes, freeBlocks: freeBlocks)
            // Whatever reused the block last left a metadata node there.
            if freeBlocks.contains(gone) {
                builder.write(gone, builder.node(oid: UInt64(gone), xid: 6, subtype: APFS.ObjectType.omap, level: 0,
                                                 isRoot: false, entries: [], fixed: (16, 16)))
            }
            return found(await scan(builder.image)).filter(\.isDeleted).map(\.name)
        }
        // Freed, reused by a metadata node, freed again: the bit is clear and the queue has no entry.
        #expect(await deletedNames({ _ in }, freeBlocks: [gone]) == ["gone-big.bin"])
        // Queued, but the bit is already clear: the free was processed, so it proves nothing.
        #expect(await deletedNames({ $0.pendingFrees.append((6, gone, 1)) }, freeBlocks: [gone]) == ["gone-big.bin"])
        // Freed in the candidate's own transaction: not the candidate's block.
        #expect(await deletedNames({ $0.pendingFrees.append((5, gone, 1)) }) == ["gone-big.bin"])
        // Freed by a transaction after the current checkpoint: not part of the state being read.
        #expect(await deletedNames({ $0.freeQueueOverride[6] = [(6, goneBig, 25), (7, gone, 1)] }) == ["gone-big.bin"])
        // Control: pending, bit set, freed between the two checkpoints.
        #expect(await deletedNames({ $0.pendingFrees.append((6, gone, 1)) }) == ["gone.txt", "gone-big.bin"])
    }

    @Test func spaceManagerWithAHugeBlockCountIsSkippedNotTrapped() async throws {
        let (gone, _) = deletedBlocks()
        let builder = APFSImageBuilder()
        builder.pendingFrees = [(6, gone, 1)]
        var volumes = [twoCheckpointVolume()]
        builder.container(&volumes)
        // Checksummed, so only its geometry is hostile: sm_block_count = Int64.max.
        builder.rewrite(builder.spacemanBlocks[6]!) { $0.put(48, UInt64(Int64.max), 8) }
        let (events, container) = try await containerScan(builder.image)
        #expect(found(events).count == 3 && found(events).allSatisfy { !$0.isDeleted })
        #expect(await container.deletedRecoverySkippedReason == "The space manager couldn't be read.")
    }

    @Test(arguments: [ReusedNode.rootWithAnotherOID, .rootWithAnotherXID, .leafWithAnotherXID])
    fileprivate func reusedNodeInAnOlderCheckpointTreeIsNotRead(_ reuse: ReusedNode) async throws {
        // A block of the xid-5 tree now holds a checksummed node that isn't the one referenced:
        // another identifier, or another transaction than the object map records. It lists an
        // "imposter" whose extent points at a block that is genuinely pending free.
        let (gone, _) = deletedBlocks(splitTrees: true)
        let builder = APFSImageBuilder()
        builder.splitTrees = true
        builder.pendingFrees = [(6, gone, 1)]
        var volumes = [twoCheckpointVolume()]
        builder.container(&volumes)
        let imposter = [APFSImageBuilder.NodeEntry(key: builder.inodeKey(40), value: builder.inodeValue(
                            parent: 2, privateID: 40, mode: 0o100644, name: "imposter.txt", modified: 1, stream: (13, 4096))),
                        builder.extentRecord(streamID: 40, logical: 0, length: 4096, block: gone)]
        let fsTree = APFS.ObjectType.fsTree
        switch reuse {
        case .rootWithAnotherOID:
            builder.write(builder.fsRootBlocks["1026@5"]!, builder.node(oid: 0x999, xid: 5, subtype: fsTree, level: 0, isRoot: true, entries: imposter))
        case .rootWithAnotherXID:
            builder.write(builder.fsRootBlocks["1026@5"]!, builder.node(oid: 0x404, xid: 4, subtype: fsTree, level: 0, isRoot: true, entries: imposter))
        case .leafWithAnotherXID:
            builder.write(builder.fsLeafBlocks["1026@5"]![1], builder.node(oid: 0x406, xid: 4, subtype: fsTree, level: 0, isRoot: false, entries: imposter))
        }
        let events = await scan(builder.image)
        #expect(events.last == .completed && found(events).filter { !$0.isDeleted }.count == 3)
        #expect(!found(events).contains { $0.name == "imposter.txt" })
    }

    @Test func staleCheckpointMapOrSpaceManagerDisablesDeletedRecovery() async throws {
        // gone.txt is in the xid-4 tree. It was freed at xid 5; by xid 6 that free has been
        // processed and the block handed out again, so xid 6's queue no longer lists it.
        func volume() -> SynthVolume {
            var volume = simpleVolume(xid: 6)
            volume.states[5] = volume.states[6]!
            var oldest = volume.states[6]!
            oldest.files.append(SynthFile(id: 22, parent: 16, name: "gone.txt", data: Data("to be deleted".utf8)))
            volume.states[4] = oldest
            return volume
        }
        let probe = APFSImageBuilder()
        var probeVolumes = [volume()]
        probe.container(&probeVolumes)
        let gone = probeVolumes[0].states[4]!.files.first { $0.name == "gone.txt" }!.firstBlock!
        func build() -> APFSImageBuilder {
            let builder = APFSImageBuilder()
            builder.freeQueueOverride = [5: [(5, gone, 1)], 6: []]
            var volumes = [volume()]
            builder.container(&volumes)
            return builder
        }
        let (honest, _) = try await containerScan(build().image)
        #expect(found(honest).count == 3 && found(honest).allSatisfy { !$0.isDeleted })

        // xid 5's checkpoint-map block in xid 6's slot (checksummed, o_xid 5): it maps xid 5's
        // space manager and free queue, which still list the block.
        let staleMap = build()
        let slot = staleMap.checkpointMapBlocks[6]!
        staleMap.write(slot, staleMap.block(staleMap.checkpointMapBlocks[5]!))
        staleMap.rewrite(slot) { $0.put(8, UInt64(slot), 8) }
        let (mapEvents, mapContainer) = try await containerScan(staleMap.image)
        #expect(found(mapEvents).count == 3 && found(mapEvents).allSatisfy { !$0.isDeleted })
        #expect(await mapContainer.deletedRecoverySkippedReason == "The space manager isn't in the checkpoint maps.")

        // xid 6's own map pointing at xid 5's space manager (o_xid 5) and free queue.
        let staleManager = build()
        let oldManager = staleManager.spacemanBlocks[5]!
        staleManager.rewrite(staleManager.checkpointMapBlocks[6]!) { data in
            data.put(40 + 32, UInt64(oldManager), 8); data.put(80 + 32, UInt64(oldManager + 1), 8)
        }
        let (managerEvents, managerContainer) = try await containerScan(staleManager.image)
        #expect(found(managerEvents).count == 3 && found(managerEvents).allSatisfy { !$0.isDeleted })
        #expect(await managerContainer.deletedRecoverySkippedReason == "The space manager couldn't be read.")
    }

    @Test func chunkInfoAddressBlocksAreBoundedAndNotRepeated() async throws {
        // The superblock claims four chunks; the live space manager is rewritten for one chunk per
        // CIB and one CIB per CAB, so it lists four CABs.
        let blocksPerChunk = APFSImageBuilder.blockSize * 8
        func build(_ listings: (APFSImageBuilder) -> [Int]) -> APFSImageBuilder {
            let builder = APFSImageBuilder()
            builder.claimedBlockCount = blocksPerChunk * 4
            var volumes = [simpleVolume()]
            builder.container(&volumes)
            let cabs = listings(builder)
            builder.rewrite(builder.spacemanBlocks[6]!) { data in
                data.put(40, 1, 4); data.put(44, 1, 4); data.put(48, UInt64(blocksPerChunk * 4), 8); data.put(56, 4, 8)
                data.put(64, 4, 4); data.put(68, UInt64(cabs.count), 4)
                for (index, cab) in cabs.enumerated() { data.put(0x200 + index * 8, UInt64(cab), 8) }
            }
            return builder
        }
        func cab(_ builder: APFSImageBuilder, listing count: Int) -> Int {
            let block = builder.allocate()
            builder.write(block, builder.object(oid: UInt64(block), xid: 6, type: APFS.ObjectType.spacemanCAB, subtype: 0) { data in
                data.put(36, UInt64(count), 4)
                for index in 0..<count { data.put(40 + index * 8, UInt64(900 + index), 8) }
            })
            return block
        }
        // One CAB repeated four times, each listing one CIB: the totals add up, but it's one block.
        let repeated = build { builder in let only = cab(builder, listing: 1); return [only, only, only, only] }
        let (repeatedEvents, repeatedContainer) = try await containerScan(repeated.image)
        #expect(found(repeatedEvents).count == 3)
        #expect(await repeatedContainer.deletedRecoverySkippedReason == "The space manager couldn't be read.")
        // Four CABs each listing 500 CIBs where one is allowed: rejected at the first, before the
        // others are read or anything from it is kept.
        var oversized: [Int] = []
        let crafted = build { builder in oversized = (0..<4).map { _ in cab(builder, listing: 500) }; return oversized }
        let reader = RecordingReader(data: crafted.image)
        let (craftedEvents, craftedContainer) = try await containerScan(crafted.image, reader: reader)
        #expect(found(craftedEvents).count == 3)
        #expect(await craftedContainer.deletedRecoverySkippedReason == "The space manager couldn't be read.")
        var cabReads = 0
        for block in oversized { cabReads += await reader.reads(ofBlock: block) }
        #expect(cabReads == 1)
    }

    @Test func deletedExtentWithACryptoIDIsSkipped() async throws {
        let (gone, goneBig) = deletedBlocks()
        let builder = APFSImageBuilder()
        builder.pendingFrees = [(6, gone, 1), (6, goneBig, 25)]
        var volume = twoCheckpointVolume()
        let index = volume.states[5]!.files.firstIndex { $0.name == "gone.txt" }!
        volume.states[5]!.files[index].cryptoID = 5
        var volumes = [volume]
        builder.container(&volumes)
        #expect(found(await scan(builder.image)).filter(\.isDeleted).map(\.name) == ["gone-big.bin"])
    }

    @Test func deletedFilesAreRecoveredThroughMultiLevelTrees() async throws {
        // The old tree is walked across two leaves, and the live tree and object maps are searched
        // through their index nodes (`inodeExists`, directory lookups, node resolution).
        let (gone, goneBig) = deletedBlocks(splitTrees: true)
        let builder = APFSImageBuilder()
        builder.splitTrees = true
        builder.pendingFrees = [(6, gone, 1), (6, goneBig, 25)]
        var volumes = [twoCheckpointVolume()]
        builder.container(&volumes)
        #expect(builder.fsLeafBlocks["1026@5"]?.count == 2 && builder.fsLeafBlocks["1026@6"]?.count == 2)
        let events = await scan(builder.image)
        #expect(events.last == .completed)
        let deleted = found(events).filter(\.isDeleted)
        #expect(deleted.map(\.path) == ["/docs/gone.txt", "/docs/nested/gone-big.bin"])
        for file in deleted {
            let expected = volumes[0].states[5]!.files.first { $0.name == file.name }!.data
            #expect(try await bytes(of: file, in: builder.image) == expected)
        }
    }

    @Test func olderCheckpointWithDamagedTreeIsSkippedNotFatal() async throws {
        let builder = APFSImageBuilder()
        var volumes = [twoCheckpointVolume()]
        builder.container(&volumes)
        // Corrupt the xid-5 volume superblock: the live scan must still complete.
        builder.image[builder.apsbBlocks["1026@5"]! * APFSImageBuilder.blockSize + 300] ^= 1
        let events = await scan(builder.image)
        #expect(events.last == .completed && found(events).count == 3)
    }

    /// Every APFS file, live and deleted, names the volume it came from, so two volumes sharing a
    /// container (and its offset) with the same paths can be told apart.
    @Test func everyFileCarriesItsVolumesNameAndUUID() async throws {
        var personal = twoCheckpointVolume()
        personal.name = "Personal"
        let work = SynthVolume(fsOID: 1027, name: "Work", states: simpleVolume(fsOID: 1027, name: "Work").states)
        let probe = APFSImageBuilder()
        var probed = [personal, work]
        probe.container(&probed)
        let gone = probed[0].states[5]!.files.first { $0.name == "gone.txt" }!.firstBlock!
        let builder = APFSImageBuilder()
        builder.pendingFrees = [(6, gone, 1)]
        var volumes = [personal, work]
        builder.container(&volumes)
        let events = await scan(builder.image)
        #expect(events.last == .completed)
        let files = found(events)
        let mine = files.filter { $0.sourceMetadata.volumeName == "Personal" }
        let theirs = files.filter { $0.sourceMetadata.volumeName == "Work" }
        #expect(mine.count + theirs.count == files.count)
        #expect(mine.filter { !$0.isDeleted }.count == 3 && theirs.count == 3)
        #expect(mine.filter(\.isDeleted).map(\.path) == ["/docs/gone.txt"])
        #expect(mine.allSatisfy { $0.sourceMetadata.volumeID == personal.uuid.uuidString.uppercased() })
        #expect(theirs.allSatisfy { $0.sourceMetadata.volumeID == work.uuid.uuidString.uppercased() })
        // Same paths, same container offset: only the volume identity separates them.
        #expect(Set(mine.filter { !$0.isDeleted }.map(\.path)) == Set(theirs.map(\.path)))
        #expect(Set(files.map(\.sourceMetadata.volumeOffset)) == [0])
    }
}

// MARK: - Real hdiutil images (Story 2.1 spike as a regression test)

private let hdiutilAvailable = FileManager.default.isExecutableFile(atPath: "/usr/bin/hdiutil")
    && ProcessInfo.processInfo.environment["SALVAGE_SKIP_HDIUTIL"] == nil

/// A disposable APFS disk image attached by this test, detached in `deinit`/`detach()`.
private final class ScratchImage {
    let directory: URL
    let imageURL: URL
    private(set) var device: String?
    private(set) var mountPoint: URL?

    init(sizeMiB: Int = 32, filesystem: String = "APFS", layout: String = "NONE") throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("salvage-apfs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        imageURL = directory.appendingPathComponent("image.dmg")
        _ = try Self.run("/usr/bin/hdiutil", ["create", "-size", "\(sizeMiB)m", "-fs", filesystem, "-volname", "SalvageSpike",
                                              "-layout", layout, "-type", "UDIF", imageURL.path])
    }

    func attach() throws {
        let output = try Self.run("/usr/bin/hdiutil", ["attach", "-nobrowse", imageURL.path])
        for line in output.split(separator: "\n") {
            let columns = line.split(separator: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
            if device == nil, let first = columns.first, first.hasPrefix("/dev/disk") { device = first }
            if let mount = columns.last, mount.hasPrefix("/Volumes/") { mountPoint = URL(fileURLWithPath: mount) }
        }
        guard device != nil, mountPoint != nil else { throw ScanError.io("hdiutil attach produced no mount point: \(output)") }
    }

    func detach() {
        if let device {
            _ = try? Self.run("/usr/bin/hdiutil", ["detach", device])
            self.device = nil; mountPoint = nil
        }
    }

    func destroy() {
        detach()
        try? FileManager.default.removeItem(at: directory)
    }

    deinit { destroy() }

    static func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else { throw ScanError.io("\(executable) \(arguments.joined(separator: " ")) failed: \(output)") }
        return output
    }
}

private func sync(_ url: URL) {
    _ = try? ScratchImage.run("/bin/sync", [])
    _ = url
}

/// Why the APFS real-image suite below can't run here (it then skips), or nil when it can: hdiutil
/// must exist, not be switched off with SALVAGE_SKIP_HDIUTIL, and actually create and attach an
/// APFS image -- a runner where attaching is denied would otherwise fail every test instead of
/// reporting one clear reason.
private let apfsRealImageUnavailableReason: String? = {
    guard hdiutilAvailable else {
        return ProcessInfo.processInfo.environment["SALVAGE_SKIP_HDIUTIL"] != nil
            ? "SALVAGE_SKIP_HDIUTIL is set" : "/usr/bin/hdiutil is not executable"
    }
    do {
        let image = try ScratchImage()
        defer { image.destroy() }
        try image.attach()
        return nil
    } catch {
        return "hdiutil could not create and attach an APFS test image: \(error)"
    }
}()

@Suite("APFS real-image availability")
struct APFSRealImageAvailabilityTests {
    /// Says explicitly when the real-image suite below is skipped, and fails the run instead when
    /// SALVAGE_REQUIRE_HDIUTIL=1 (as CI sets), so the suite can't silently skip there.
    @Test func realImageSuiteReportsWhyItIsSkipped() {
        guard let reason = apfsRealImageUnavailableReason else { return }
        print("APFS real-image tests skipped: \(reason)")
        if ProcessInfo.processInfo.environment["SALVAGE_REQUIRE_HDIUTIL"] == "1" {
            Issue.record("SALVAGE_REQUIRE_HDIUTIL=1 but the APFS real-image tests can't run: \(reason)")
        }
    }
}

@Suite("APFS real hdiutil images", .enabled(if: apfsRealImageUnavailableReason == nil, "hdiutil can't create and attach APFS images here"),
       .serialized)
struct APFSRealImageTests {
    struct Written { let path: String; let data: Data; let modified: Date }

    fileprivate func populate(_ image: ScratchImage) throws -> (kept: [Written], deleted: [Written]) {
        let root = try #require(image.mountPoint)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("docs/nested"), withIntermediateDirectories: true)
        var generator = SystemRandomNumberGenerator()
        func random(_ count: Int) -> Data { Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) }) }
        let kept: [(String, Data)] = [("hello.txt", Data("hello apfs\n".utf8)), ("docs/big.bin", random(3_000_000)),
                                      ("docs/empty.txt", Data()), ("docs/nested/mid.dat", random(5000))]
        let doomed: [(String, Data)] = [("docs/gone.txt", Data("to be deleted\n".utf8)), ("docs/nested/gone-big.bin", random(100_000))]
        func write(_ entries: [(String, Data)]) throws -> [Written] {
            try entries.map { path, data in
                let url = root.appendingPathComponent(path)
                try data.write(to: url)
                let modified = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate!
                return Written(path: "/" + path, data: data, modified: modified)
            }
        }
        let keptFiles = try write(kept), deletedFiles = try write(doomed)
        sync(root); Thread.sleep(forTimeInterval: 1.5)
        for file in deletedFiles { try FileManager.default.removeItem(at: root.appendingPathComponent(String(file.path.dropFirst()))) }
        sync(root); Thread.sleep(forTimeInterval: 1.5)
        return (keptFiles, deletedFiles)
    }

    @Test func liveAndDeletedFilesFromARealVolume() async throws {
        let image = try ScratchImage()
        defer { image.destroy() }
        try image.attach()
        let (kept, deleted) = try populate(image)
        image.detach()
        let data = try Data(contentsOf: image.imageURL)
        #expect(String(decoding: data[32..<36], as: UTF8.self) == "NXSB")
        let events = await scan(data)
        #expect(events.last == .completed)
        let files = found(events)
        let live = files.filter { !$0.isDeleted }
        #expect(Set(live.map(\.path)) == Set(kept.map(\.path)))
        for expected in kept {
            let file = try #require(live.first { $0.path == expected.path })
            #expect(file.sizeBytes == Int64(expected.data.count))
            #expect(abs((file.modified ?? .distantPast).timeIntervalSince(expected.modified)) < 1)
            #expect(try await bytes(of: file, in: data) == expected.data)
        }
        // Deleted files come from an older checkpoint still in the ring, with blocks pending in the
        // free queue; this is best effort, but a fresh image reliably keeps them.
        let recovered = files.filter(\.isDeleted)
        #expect(Set(recovered.map(\.path)) == Set(deleted.map(\.path)))
        for expected in deleted {
            let file = try #require(recovered.first { $0.path == expected.path })
            #expect(file.sizeBytes == Int64(expected.data.count))
            #expect(try await bytes(of: file, in: data) == expected.data)
        }
        #expect(data == (try Data(contentsOf: image.imageURL)))
    }

    @Test func caseSensitiveVolumeAndGPTLayout() async throws {
        let image = try ScratchImage(filesystem: "Case-sensitive APFS", layout: "GPTSPUD")
        defer { image.destroy() }
        try image.attach()
        let root = try #require(image.mountPoint)
        try Data("x\n".utf8).write(to: root.appendingPathComponent("File.txt"))
        try Data("yy\n".utf8).write(to: root.appendingPathComponent("file.txt"))
        sync(root); try await Task.sleep(for: .seconds(1))
        image.detach()
        let data = try Data(contentsOf: image.imageURL)
        let events = await scan(data)
        #expect(events.last == .completed)
        let files = found(events).filter { !$0.isDeleted }
        #expect(Set(files.map(\.name)) == ["File.txt", "file.txt"])
        #expect(files.allSatisfy { $0.sourceMetadata.volumeOffset > 0 })
        for file in files {
            #expect(try await bytes(of: file, in: data) == Data((file.name == "File.txt" ? "x\n" : "yy\n").utf8))
        }
    }
}
