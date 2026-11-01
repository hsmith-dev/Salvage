import Foundation

// APFS B-trees (`btree_node_phys_t`, `btree_info_t`) from Apple's public APFS Reference. A node's
// table of contents sits at the start of its data area, keys grow upward from the end of the table,
// and values grow downward from the end of the node (minus the tree info in a root node).

/// `btree_info_t`, stored at the end of a root node.
struct APFSBTreeInfo: Sendable {
    let flags: UInt32
    let nodeSize: Int64
    let keySize: Int
    let valueSize: Int
    let nodeCount: UInt64

    init(_ node: Data) throws {
        let base = node.count - APFS.btreeInfoSize
        flags = UInt32(try node.number(base, 4))
        nodeSize = try signed(node.number(base + 4, 4))
        keySize = Int(try node.number(base + 8, 4))
        valueSize = Int(try node.number(base + 12, 4))
        nodeCount = try node.number(base + 32, 8)
    }
}

/// One parsed, checksum-verified B-tree node.
struct APFSBTreeNode: Sendable {
    let header: APFSObjectHeader
    let address: Int64
    let flags: UInt16
    let level: Int
    let keyCount: Int
    let data: Data
    let info: APFSBTreeInfo?
    private let tableStart: Int
    private let keyAreaStart: Int
    private let valueAreaEnd: Int

    var isRoot: Bool { flags & APFS.btreeNodeRoot != 0 }
    var isLeaf: Bool { level == 0 }
    private var fixedKV: Bool { flags & APFS.btreeNodeFixedKV != 0 }

    /// `inheritedInfo` is the root's tree info, needed to size fixed keys and values in a child.
    init(_ data: Data, address: Int64, inheritedInfo: APFSBTreeInfo?) throws {
        header = try APFSObjectHeader(data)
        guard header.type == APFS.ObjectType.btree || header.type == APFS.ObjectType.btreeNode else {
            throw ScanError.malformed("APFS B-tree node has the wrong object type.")
        }
        self.address = address
        self.data = data
        flags = UInt16(try data.number(32, 2))
        guard flags & APFS.btreeNodeNoHeader == 0 else { throw ScanError.unsupportedFilesystem }
        level = Int(try data.number(34, 2))
        guard level <= APFS.maxTreeDepth, (level == 0) == (flags & APFS.btreeNodeLeaf != 0) else {
            throw ScanError.malformed("APFS B-tree node level is invalid.")
        }
        keyCount = Int(try data.number(36, 4))
        let tableOffset = Int(try data.number(40, 2)), tableLength = Int(try data.number(42, 2))
        let isRoot = flags & APFS.btreeNodeRoot != 0
        valueAreaEnd = data.count - (isRoot ? APFS.btreeInfoSize : 0)
        tableStart = APFS.btreeNodeHeaderSize + tableOffset
        keyAreaStart = tableStart + tableLength
        guard keyAreaStart <= valueAreaEnd else { throw ScanError.malformed("APFS B-tree table of contents overflows its node.") }
        if isRoot {
            let info = try APFSBTreeInfo(data)
            guard info.nodeSize == Int64(data.count) else { throw ScanError.malformed("APFS B-tree node size doesn't match the block size.") }
            self.info = info
        } else {
            guard header.type == APFS.ObjectType.btreeNode else { throw ScanError.malformed("APFS B-tree root is referenced as a child.") }
            info = inheritedInfo
        }
        let entrySize = fixedKV ? 4 : 8
        guard keyCount <= tableLength / entrySize else { throw ScanError.malformed("APFS B-tree node has more keys than its table holds.") }
        if fixedKV { guard info != nil else { throw ScanError.malformed("APFS fixed-size B-tree node has no tree info.") } }
    }

    /// The key at `index` as a copy, with its offset within the node.
    func key(_ index: Int) throws -> (offset: Int, data: Data) {
        guard index >= 0, index < keyCount else { throw ScanError.malformed("APFS B-tree index out of range.") }
        let offset: Int, length: Int
        if fixedKV {
            offset = Int(try data.number(tableStart + index * 4, 2)); length = info?.keySize ?? 0
        } else {
            offset = Int(try data.number(tableStart + index * 8, 2)); length = Int(try data.number(tableStart + index * 8 + 2, 2))
        }
        let start = keyAreaStart + offset
        guard length > 0, start + length <= valueAreaEnd else { throw ScanError.malformed("APFS B-tree key overflows its node.") }
        return (start, data.subdata(in: start..<start + length))
    }

    /// The value at `index` as a copy, with its offset within the node. A ghost entry is empty.
    func value(_ index: Int) throws -> (offset: Int, data: Data) {
        guard index >= 0, index < keyCount else { throw ScanError.malformed("APFS B-tree index out of range.") }
        let rawOffset: UInt64, length: Int
        if fixedKV {
            rawOffset = try data.number(tableStart + index * 4 + 2, 2)
            length = isLeaf ? (info?.valueSize ?? 0) : 8
        } else {
            rawOffset = try data.number(tableStart + index * 8 + 4, 2)
            length = Int(try data.number(tableStart + index * 8 + 6, 2))
        }
        if rawOffset == APFS.btreeOffsetInvalid { return (valueAreaEnd, Data()) }
        let start = valueAreaEnd - Int(rawOffset)
        guard start >= keyAreaStart, length <= Int(rawOffset) else { throw ScanError.malformed("APFS B-tree value overflows its node.") }
        return (start, data.subdata(in: start..<start + length))
    }

    /// A child's object identifier (physical address, virtual, or ephemeral, by tree kind).
    func childIdentifier(_ index: Int) throws -> UInt64 {
        let (_, value) = try value(index)
        guard value.count >= 8 else { throw ScanError.malformed("APFS B-tree child pointer is truncated.") }
        return try value.number(0, 8)
    }
}

/// How a tree's child pointers are resolved to block addresses.
enum APFSTreeKind: Sendable {
    /// Pointers are block addresses (object maps, snapshot metadata, spaceman structures).
    case physical
    /// Pointers are virtual object identifiers, resolved through an object map at a transaction.
    case virtual(omapTree: Int64, xid: UInt64)
    /// Pointers are ephemeral identifiers listed in the checkpoint maps.
    case ephemeral([UInt64: Int64])
}

/// What a reference says the object it points at must be: its `o_oid`, and, for a virtual object,
/// the `o_xid` its object-map entry records. A block that checksums but doesn't match was reused
/// (or never belonged to this tree), so it is never read as the referenced object.
struct APFSObjectReference: Sendable, Equatable {
    let oid: UInt64
    let xid: UInt64?

    /// A physical object's identifier is its own block address.
    static func physical(_ address: Int64) -> APFSObjectReference { APFSObjectReference(oid: UInt64(address), xid: nil) }

    func matches(_ header: APFSObjectHeader) -> Bool {
        header.oid == oid && (xid.map { $0 == header.xid } ?? true)
    }
}

struct APFSTree: Sendable {
    let root: Int64
    /// The identity the root node must carry.
    let rootReference: APFSObjectReference
    let kind: APFSTreeKind
    let compare: @Sendable (Data, Data) -> Int
}

/// A record at a leaf position: key, value, and where the value sits for `recordOffset`.
struct APFSRecord: Sendable {
    let key: Data
    let value: Data
    let nodeAddress: Int64
    let valueOffset: Int
}

/// Keys made of two little-endian 64-bit fields compared in order (`omap_key_t`, free-queue keys).
func compareAPFSPairKeys(_ a: Data, _ b: Data) -> Int {
    guard let a0 = try? a.number(0, 8), let b0 = try? b.number(0, 8) else { return a.count < b.count ? -1 : (a.count > b.count ? 1 : 0) }
    if a0 != b0 { return a0 < b0 ? -1 : 1 }
    guard let a1 = try? a.number(8, 8), let b1 = try? b.number(8, 8) else { return a.count < b.count ? -1 : (a.count > b.count ? 1 : 0) }
    return a1 == b1 ? 0 : (a1 < b1 ? -1 : 1)
}

/// Filesystem-tree key order: object identifier, then record type, then the type's own fields.
/// A key that ends after a field the other continues compares lower, so an 8-byte search key
/// `(id, type)` sorts before every real record of that identifier and type.
func makeAPFSRecordKeyComparator(hashedDirectoryKeys: Bool) -> @Sendable (Data, Data) -> Int {
    { a, b in
        guard let ha = try? a.number(0, 8), let hb = try? b.number(0, 8) else { return a.count < b.count ? -1 : (a.count > b.count ? 1 : 0) }
        let (ida, idb) = (ha & APFS.objectIDMask, hb & APFS.objectIDMask)
        if ida != idb { return ida < idb ? -1 : 1 }
        let (ta, tb) = (ha >> 60, hb >> 60)
        if ta != tb { return ta < tb ? -1 : 1 }
        switch UInt8(ta) {
        case APFS.RecordType.fileExtent, APFS.RecordType.siblingLink, APFS.RecordType.fileInfo:
            return compareNumbers(a, b, at: 8, width: 8)
        case APFS.RecordType.directoryRecord where hashedDirectoryKeys:
            let hashed = compareNumbers(a, b, at: 8, width: 4)
            return hashed != 0 ? hashed : compareBytes(a, b, from: 12)
        case APFS.RecordType.directoryRecord:
            return compareBytes(a, b, from: 10)
        case APFS.RecordType.xattr, APFS.RecordType.snapName:
            return compareBytes(a, b, from: 10)
        default:
            return 0
        }
    }
}

private func compareNumbers(_ a: Data, _ b: Data, at offset: Int, width: Int) -> Int {
    let va = try? a.number(offset, width), vb = try? b.number(offset, width)
    switch (va, vb) {
    case let (x?, y?): return x == y ? 0 : (x < y ? -1 : 1)
    case (nil, nil): return 0
    case (nil, _): return -1
    default: return 1
    }
}

private func compareBytes(_ a: Data, _ b: Data, from offset: Int) -> Int {
    let sa = a.count > offset ? a.dropFirst(offset) : Data(), sb = b.count > offset ? b.dropFirst(offset) : Data()
    for (x, y) in zip(sa, sb) where x != y { return x < y ? -1 : 1 }
    return sa.count == sb.count ? 0 : (sa.count < sb.count ? -1 : 1)
}

/// A position in a tree: the path of nodes from the root with the index taken at each level.
struct APFSTreeCursor {
    var path: [(node: APFSBTreeNode, index: Int)] = []
    var lastKey: Data?
    var finished = false
}

/// Thrown when deleted-file work exceeds the per-volume budget; never fails the live scan.
struct APFSBudgetExhausted: Error {}
