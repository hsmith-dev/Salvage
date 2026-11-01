import Foundation

// On-disk layouts from Apple's public *Apple File System Reference* (AD-2). Every structure here
// is parsed from a block whose Fletcher-64 checksum the caller has already verified. Original
// code; no GPL/LGPL implementation was consulted.

/// Constants from the reference. Values are little-endian on disk.
enum APFS {
    static let minBlockSize: Int64 = 4096, maxBlockSize: Int64 = 65536
    static let maxTreeDepth = 16
    static let maxPathDepth = 1024
    /// Checkpoint descriptor areas are small in practice (8–256 blocks); this bounds a hostile value.
    static let maxDescriptorBlocks: Int64 = 4096
    static let maxFileSystems = 100
    static let maxVolumeNameBytes = 256
    static let orphanedDirectory = "/Orphaned Files"

    static let nxMagic: UInt64 = 0x4253_584e      // "NXSB"
    static let volumeMagic: UInt64 = 0x4253_5041  // "APSB"

    enum ObjectType {
        static let nxSuperblock: UInt32 = 0x1, btree: UInt32 = 0x2, btreeNode: UInt32 = 0x3
        static let spaceman: UInt32 = 0x5, spacemanCAB: UInt32 = 0x6, spacemanCIB: UInt32 = 0x7
        static let spacemanFreeQueue: UInt32 = 0x9, omap: UInt32 = 0xb, checkpointMap: UInt32 = 0xc
        static let fs: UInt32 = 0xd, fsTree: UInt32 = 0xe, snapMetaTree: UInt32 = 0x10
    }
    static let objectTypeMask: UInt32 = 0x0000_ffff
    static let objectEphemeral: UInt32 = 0x8000_0000, objectPhysical: UInt32 = 0x4000_0000

    /// `nx_xp_desc_blocks` high bit: the descriptor area is a B-tree, not a contiguous ring.
    static let descriptorAreaIsTree: UInt64 = 0x8000_0000
    static let checkpointMapLast: UInt32 = 1

    static let omapValueDeleted: UInt32 = 0x1, omapValueEncrypted: UInt32 = 0x4, omapValueNoHeader: UInt32 = 0x8
    /// `om_flags`: the volume is being encrypted or decrypted, so any block may hold ciphertext.
    static let omapEncrypting: UInt32 = 0x2, omapDecrypting: UInt32 = 0x4

    static let fsUnencrypted: UInt64 = 0x1
    static let incompatCaseInsensitive: UInt64 = 0x1, incompatNormalizationInsensitive: UInt64 = 0x8

    static let objectIDMask: UInt64 = 0x0fff_ffff_ffff_ffff
    enum RecordType {
        static let snapMetadata: UInt8 = 1, physicalExtent: UInt8 = 2, inode: UInt8 = 3, xattr: UInt8 = 4
        static let siblingLink: UInt8 = 5, dstreamID: UInt8 = 6, cryptoState: UInt8 = 7, fileExtent: UInt8 = 8
        static let directoryRecord: UInt8 = 9, directoryStats: UInt8 = 10, snapName: UInt8 = 11, fileInfo: UInt8 = 13
    }
    static let rootParentID: UInt64 = 1, rootDirectoryID: UInt64 = 2, privateDirectoryID: UInt64 = 3
    static let minUserInodeID: UInt64 = 16

    static let modeTypeMask: UInt16 = 0xf000, modeRegular: UInt16 = 0x8000, modeDirectory: UInt16 = 0x4000
    static let inodeIsSparse: UInt64 = 0x200, inodeHasUncompressedSize: UInt64 = 0x40000
    static let bsdCompressed: UInt32 = 0x20
    static let xfieldName: UInt8 = 4, xfieldDataStream: UInt8 = 8
    static let fileExtentLengthMask: UInt64 = 0x00ff_ffff_ffff_ffff

    static let btreeNodeRoot: UInt16 = 0x1, btreeNodeLeaf: UInt16 = 0x2, btreeNodeFixedKV: UInt16 = 0x4
    static let btreeNodeNoHeader: UInt16 = 0x10
    static let btreeOffsetInvalid: UInt64 = 0xffff
    static let btreeInfoSize = 40
    static let btreeNodeHeaderSize = 56
    static let objectHeaderSize = 32
}

/// Fletcher's checksum as APFS stores it: the object is read as 32-bit little-endian words after
/// its 8-byte checksum field, summed modulo 2^32 - 1, and the stored 64-bit value is the pair that
/// completes the sum. Independently verified against real `hdiutil` images (Story 2.1 spike).
func apfsFletcher64(_ data: Data) -> UInt64 {
    let modulus: UInt64 = 0xffff_ffff
    var sum1: UInt64 = 0, sum2: UInt64 = 0
    data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
        var index = 8
        // Sums are reduced only when they approach overflow; modular reduction commutes with addition.
        while index + 4 <= buffer.count {
            sum1 += UInt64(buffer.loadUnaligned(fromByteOffset: index, as: UInt32.self).littleEndian)
            sum2 += sum1
            if sum2 >= 1 << 62 { sum1 %= modulus; sum2 %= modulus }
            index += 4
        }
    }
    sum1 %= modulus; sum2 %= modulus
    let check1 = modulus - ((sum1 + sum2) % modulus)
    let check2 = modulus - ((sum1 + check1) % modulus)
    return check1 | (check2 << 32)
}

/// True when the object's stored checksum matches its contents. An all-zero block never verifies.
func apfsChecksumIsValid(_ object: Data) -> Bool {
    guard object.count >= APFS.objectHeaderSize, object.count % 4 == 0 else { return false }
    return (try? object.number(0, 8)) == apfsFletcher64(object)
}

/// `obj_phys_t` without the checksum, which `apfsChecksumIsValid` covers.
struct APFSObjectHeader: Sendable {
    let oid: UInt64
    let xid: UInt64
    let type: UInt32
    let flags: UInt32
    let subtype: UInt32

    init(_ data: Data) throws {
        oid = try data.number(8, 8)
        xid = try data.number(16, 8)
        let typeAndFlags = UInt32(try data.number(24, 4))
        type = typeAndFlags & APFS.objectTypeMask
        flags = typeAndFlags & ~APFS.objectTypeMask
        subtype = UInt32(try data.number(28, 4))
    }
}

/// `nx_superblock_t`.
struct APFSContainerSuperblock: Sendable {
    let header: APFSObjectHeader
    let blockSize: Int64
    let blockCount: Int64
    let uuid: Data
    let descriptorBlocks: Int64
    let descriptorBase: Int64
    let dataBlocks: Int64
    let dataBase: Int64
    let descriptorIndex: Int64
    let descriptorLength: Int64
    let spacemanOID: UInt64
    let omapAddress: Int64
    let fsOIDs: [UInt64]
    /// `nx_keylocker`: the container keybag's first block and block count (0 when there is none).
    let keylockerStart: Int64
    let keylockerCount: Int64

    /// The block size from the first 4096 bytes, validated before the whole block is read.
    static func blockSize(of prefix: Data) throws -> Int64 {
        guard try prefix.number(32, 4) == APFS.nxMagic else { throw ScanError.malformed("Not an APFS container.") }
        let size = try signed(prefix.number(36, 4))
        guard size >= APFS.minBlockSize, size <= APFS.maxBlockSize, size & (size - 1) == 0 else {
            throw ScanError.malformed("Unsupported APFS block size.")
        }
        return size
    }

    init(_ data: Data) throws {
        header = try APFSObjectHeader(data)
        guard header.type == APFS.ObjectType.nxSuperblock else { throw ScanError.malformed("APFS superblock has the wrong object type.") }
        blockSize = try Self.blockSize(of: data)
        guard Int64(data.count) == blockSize else { throw ScanError.malformed("Truncated APFS superblock.") }
        blockCount = try signed(data.number(40, 8))
        guard blockCount > 0 else { throw ScanError.malformed("APFS container has no blocks.") }
        uuid = data.subdata(in: 72..<88)
        let rawDescriptorBlocks = try data.number(104, 4)
        guard rawDescriptorBlocks & APFS.descriptorAreaIsTree == 0 else { throw ScanError.unsupportedFilesystem }
        descriptorBlocks = Int64(rawDescriptorBlocks)
        dataBlocks = Int64(try data.number(108, 4))
        descriptorBase = try signed(data.number(112, 8))
        dataBase = try signed(data.number(120, 8))
        descriptorIndex = Int64(try data.number(136, 4))
        descriptorLength = Int64(try data.number(140, 4))
        guard descriptorBlocks > 0, descriptorBlocks <= APFS.maxDescriptorBlocks, descriptorBase > 0,
              try checkedAdd(descriptorBase, descriptorBlocks) <= blockCount,
              descriptorIndex < descriptorBlocks, descriptorLength <= descriptorBlocks else {
            throw ScanError.malformed("Invalid APFS checkpoint descriptor area.")
        }
        spacemanOID = try data.number(152, 8)
        omapAddress = try signed(data.number(160, 8))
        guard omapAddress > 0, omapAddress < blockCount else { throw ScanError.malformed("APFS container object map is outside the container.") }
        let maxFileSystems = Int(try data.number(180, 4))
        guard maxFileSystems <= APFS.maxFileSystems else { throw ScanError.malformed("Invalid APFS volume count.") }
        var oids: [UInt64] = []
        for index in 0..<APFS.maxFileSystems {
            let oid = try data.number(184 + index * 8, 8)
            if oid != 0 { oids.append(oid) }
        }
        fsOIDs = oids
        // Validated where it's used (only an encrypted volume's unlock reads it).
        keylockerStart = Int64(bitPattern: try data.number(APFS.keylockerOffset, 8))
        keylockerCount = Int64(bitPattern: try data.number(APFS.keylockerOffset + 8, 8))
    }
}

/// One `checkpoint_mapping_t` from a `checkpoint_map_phys_t`.
struct APFSCheckpointMapping: Sendable {
    let type: UInt32
    let subtype: UInt32
    let size: Int64
    let oid: UInt64
    let address: Int64

    /// The mappings in one checkpoint-map block.
    static func mappings(in block: Data) throws -> (isLast: Bool, mappings: [APFSCheckpointMapping]) {
        let flags = UInt32(try block.number(32, 4))
        let count = Int(try block.number(36, 4))
        guard count <= (block.count - 40) / 40 else { throw ScanError.malformed("APFS checkpoint map overflows its block.") }
        var result: [APFSCheckpointMapping] = []
        for index in 0..<count {
            let base = 40 + index * 40
            result.append(APFSCheckpointMapping(type: UInt32(try block.number(base, 4)),
                                                subtype: UInt32(try block.number(base + 4, 4)),
                                                size: try signed(block.number(base + 8, 4)),
                                                oid: try block.number(base + 24, 8),
                                                address: try signed(block.number(base + 32, 8))))
        }
        return (flags & APFS.checkpointMapLast != 0, result)
    }
}

/// `omap_phys_t`.
struct APFSObjectMap: Sendable {
    let header: APFSObjectHeader
    let flags: UInt32
    let treeAddress: Int64

    init(_ data: Data) throws {
        header = try APFSObjectHeader(data)
        guard header.type == APFS.ObjectType.omap else { throw ScanError.malformed("APFS object map has the wrong object type.") }
        flags = UInt32(try data.number(32, 4))
        treeAddress = try signed(data.number(48, 8))
    }
}

/// `omap_val_t` with its key's transaction identifier.
struct APFSObjectMapEntry: Sendable {
    let xid: UInt64
    let flags: UInt32
    let size: UInt32
    let address: Int64
}

/// `apfs_superblock_t`.
struct APFSVolumeSuperblock: Sendable {
    let header: APFSObjectHeader
    let incompatibleFeatures: UInt64
    let omapAddress: Int64
    let rootTreeOID: UInt64
    let snapMetaTreeAddress: Int64
    let uuid: UUID
    let flags: UInt64
    let name: String

    var isEncrypted: Bool { flags & APFS.fsUnencrypted == 0 }
    /// Directory-record keys carry a name hash on case- or normalization-insensitive volumes.
    var hashedDirectoryKeys: Bool {
        incompatibleFeatures & (APFS.incompatCaseInsensitive | APFS.incompatNormalizationInsensitive) != 0
    }

    init(_ data: Data) throws {
        header = try APFSObjectHeader(data)
        guard header.type == APFS.ObjectType.fs, try data.number(32, 4) == APFS.volumeMagic else {
            throw ScanError.malformed("Not an APFS volume superblock.")
        }
        incompatibleFeatures = try data.number(56, 8)
        omapAddress = try signed(data.number(128, 8))
        rootTreeOID = try data.number(136, 8)
        snapMetaTreeAddress = try signed(data.number(152, 8))
        var bytes = uuid_t(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        withUnsafeMutableBytes(of: &bytes) { $0.copyBytes(from: data.subdata(in: 240..<256)) }
        uuid = UUID(uuid: bytes)
        flags = try data.number(264, 8)
        let nameBytes = data.subdata(in: 704..<704 + APFS.maxVolumeNameBytes).prefix { $0 != 0 }
        name = String(decoding: nameBytes, as: UTF8.self)
    }
}

/// `j_key_t`: the object identifier and record type that start every filesystem-tree key.
struct APFSRecordKey: Sendable {
    let objectID: UInt64
    let type: UInt8
    let raw: Data

    init(_ raw: Data) throws {
        let idAndType = try raw.number(0, 8)
        objectID = idAndType & APFS.objectIDMask
        type = UInt8(idAndType >> 60)
        self.raw = raw
    }

    static func encode(objectID: UInt64, type: UInt8) -> Data {
        var data = Data(count: 8)
        let value = (objectID & APFS.objectIDMask) | UInt64(type) << 60
        for index in 0..<8 { data[index] = UInt8(truncatingIfNeeded: value >> (index * 8)) }
        return data
    }
}

/// `j_dstream_t`.
struct APFSDataStream: Sendable, Equatable {
    let size: UInt64
    let allocatedSize: UInt64
}

/// `j_inode_val_t` with the extended fields the parser needs.
struct APFSInode: Sendable {
    let parentID: UInt64
    let privateID: UInt64
    let modificationTime: UInt64
    let internalFlags: UInt64
    let bsdFlags: UInt32
    let mode: UInt16
    let uncompressedSize: UInt64
    let name: String?
    let dataStream: APFSDataStream?

    var isRegularFile: Bool { mode & APFS.modeTypeMask == APFS.modeRegular }
    var isDirectory: Bool { mode & APFS.modeTypeMask == APFS.modeDirectory }
    var isCompressed: Bool {
        internalFlags & APFS.inodeHasUncompressedSize != 0 || bsdFlags & APFS.bsdCompressed != 0
    }
    var isSparse: Bool { internalFlags & APFS.inodeIsSparse != 0 }
    /// Logical size: the data stream's, or the recorded uncompressed size for a compressed file.
    var size: UInt64 {
        if internalFlags & APFS.inodeHasUncompressedSize != 0 { return uncompressedSize }
        return dataStream?.size ?? 0
    }
    var modified: Date? {
        modificationTime == 0 ? nil : Date(timeIntervalSince1970: Double(modificationTime) / 1_000_000_000)
    }

    init(_ value: Data) throws {
        guard value.count >= 92 else { throw ScanError.malformed("Truncated APFS inode.") }
        parentID = try value.number(0, 8)
        privateID = try value.number(8, 8)
        modificationTime = try value.number(24, 8)
        internalFlags = try value.number(48, 8)
        bsdFlags = UInt32(try value.number(68, 4))
        mode = UInt16(try value.number(80, 2))
        uncompressedSize = try value.number(84, 8)
        var name: String?, stream: APFSDataStream?
        if value.count > 92 {
            // xf_blob_t: a count, the used size, then x_field_t descriptors and 8-byte aligned payloads.
            let count = Int(try value.number(92, 2))
            var payload = 96 + count * 4
            for index in 0..<count {
                let descriptor = 96 + index * 4
                let type = UInt8(try value.number(descriptor, 1))
                let size = Int(try value.number(descriptor + 2, 2))
                guard payload + size <= value.count else { throw ScanError.malformed("APFS inode extended field overflows its record.") }
                let field = value.subdata(in: payload..<payload + size)
                switch type {
                case APFS.xfieldName:
                    guard let decoded = APFSInode.decodeName(field) else { throw ScanError.malformed("APFS inode name is not valid UTF-8.") }
                    name = decoded
                case APFS.xfieldDataStream:
                    guard size >= 40 else { throw ScanError.malformed("Truncated APFS data stream.") }
                    stream = APFSDataStream(size: try field.number(0, 8), allocatedSize: try field.number(8, 8))
                default: break
                }
                payload += (size + 7) / 8 * 8
            }
        }
        self.name = name
        dataStream = stream
    }

    /// A NUL-terminated UTF-8 name, or nil when it isn't valid UTF-8 or can't be a path component.
    static func decodeName(_ bytes: Data) -> String? {
        let body = bytes.prefix { $0 != 0 }
        guard !body.isEmpty else { return nil }
        // Strict decoding: a name that would need replacement characters isn't shown altered.
        var iterator = body.makeIterator(), decoder = UTF8(), scalars = String.UnicodeScalarView()
        while true {
            switch decoder.decode(&iterator) {
            case .scalarValue(let scalar): scalars.append(scalar)
            case .emptyInput:
                let name = String(scalars)
                guard !name.contains("/"), name != ".", name != ".." else { return nil }
                return name
            case .error: return nil
            }
        }
    }
}

/// `j_file_extent_key_t` + `j_file_extent_val_t`.
struct APFSFileExtent: Sendable, Equatable {
    let logicalAddress: UInt64
    let length: UInt64
    let physicalBlock: UInt64
    /// `crypto_id`: non-zero when the extent's blocks are encrypted with a per-file or volume key.
    let cryptoID: UInt64

    init(key: Data, value: Data) throws {
        guard key.count >= 16, value.count >= 24 else { throw ScanError.malformed("Truncated APFS file extent.") }
        logicalAddress = try key.number(8, 8)
        length = try value.number(0, 8) & APFS.fileExtentLengthMask
        physicalBlock = try value.number(8, 8)
        cryptoID = try value.number(16, 8)
    }
    init(logicalAddress: UInt64, length: UInt64, physicalBlock: UInt64, cryptoID: UInt64 = 0) {
        self.logicalAddress = logicalAddress; self.length = length; self.physicalBlock = physicalBlock; self.cryptoID = cryptoID
    }
}

/// `j_snap_metadata_val_t`: what the parser needs to open a snapshot.
struct APFSSnapshot: Sendable {
    let xid: UInt64
    let superblockAddress: Int64

    init(key: APFSRecordKey, value: Data) throws {
        guard value.count >= 50 else { throw ScanError.malformed("Truncated APFS snapshot record.") }
        xid = key.objectID
        superblockAddress = try signed(value.number(8, 8))
    }
}

/// `spaceman_phys_t` for the main device.
struct APFSSpaceManager: Sendable {
    let header: APFSObjectHeader
    let blockSize: Int64
    let blocksPerChunk: Int64
    let chunksPerCIB: Int64
    let cibsPerCAB: Int64
    let blockCount: Int64
    let chunkCount: Int64
    let cibCount: Int64
    let cabCount: Int64
    /// Chunk-info block addresses, or chunk-info address block addresses when `cabCount > 0`.
    let addresses: [Int64]
    let tier2BlockCount: Int64
    let mainFreeQueueCount: UInt64
    let mainFreeQueueTreeOID: UInt64

    /// `containerBlockCount` is `nx_block_count`; the space manager may not describe more blocks.
    init(_ data: Data, containerBlockSize: Int64, containerBlockCount: Int64) throws {
        header = try APFSObjectHeader(data)
        guard header.type == APFS.ObjectType.spaceman else { throw ScanError.malformed("APFS space manager has the wrong object type.") }
        blockSize = try signed(data.number(32, 4))
        blocksPerChunk = try signed(data.number(36, 4))
        chunksPerCIB = try signed(data.number(40, 4))
        cibsPerCAB = try signed(data.number(44, 4))
        blockCount = try signed(data.number(48, 8))
        chunkCount = try signed(data.number(56, 8))
        cibCount = try signed(data.number(64, 4))
        cabCount = try signed(data.number(68, 4))
        let addressOffset = Int(try data.number(80, 4))
        tier2BlockCount = try signed(data.number(96, 8))
        mainFreeQueueCount = try data.number(240, 8)
        mainFreeQueueTreeOID = try data.number(248, 8)
        let invalid = ScanError.malformed("Invalid APFS space manager geometry.")
        // Every count is bounded before it takes part in arithmetic, and the arithmetic is checked:
        // these are on-disk values. One bitmap block covers one chunk, so the chunk size is fixed
        // by the block size.
        guard blockSize == containerBlockSize, blocksPerChunk == blockSize * 8,
              chunksPerCIB > 0, cibsPerCAB > 0, blockCount > 0, blockCount <= containerBlockCount else { throw invalid }
        let expectedChunks = try checkedAdd(blockCount, blocksPerChunk - 1) / blocksPerChunk
        guard chunkCount == expectedChunks else { throw invalid }
        let expectedCIBs = try checkedAdd(chunkCount, chunksPerCIB - 1) / chunksPerCIB
        guard cibCount == expectedCIBs else { throw invalid }
        let expectedCABs = try checkedAdd(cibCount, cibsPerCAB - 1) / cibsPerCAB
        guard cabCount == 0 || cabCount == expectedCABs else { throw invalid }
        let addressCount = cabCount > 0 ? cabCount : cibCount
        guard addressCount <= 1 << 16, addressOffset >= 32, addressOffset <= data.count,
              Int(addressCount) * 8 <= data.count - addressOffset else {
            throw ScanError.malformed("APFS space manager address table overflows its object.")
        }
        var addresses: [Int64] = []
        for index in 0..<Int(addressCount) { addresses.append(try signed(data.number(addressOffset + index * 8, 8))) }
        self.addresses = addresses
    }
}

/// `chunk_info_t`.
struct APFSChunkInfo: Sendable {
    let address: Int64
    let blockCount: Int64
    let freeCount: Int64
    let bitmapAddress: Int64

    /// The chunk descriptors of one chunk-info block (`cib_addr_block`).
    static func chunkInfos(in block: Data) throws -> [APFSChunkInfo] {
        let count = Int(try block.number(36, 4))
        guard count <= (block.count - 40) / 32 else { throw ScanError.malformed("APFS chunk-info block overflows.") }
        var result: [APFSChunkInfo] = []
        for index in 0..<count {
            let base = 40 + index * 32
            result.append(APFSChunkInfo(address: try signed(block.number(base + 8, 8)),
                                        blockCount: try signed(block.number(base + 16, 4)),
                                        freeCount: try signed(block.number(base + 20, 4)),
                                        bitmapAddress: try signed(block.number(base + 24, 8))))
        }
        return result
    }

    /// The chunk-info block addresses listed in one chunk-info address block (`cab_addr_block`),
    /// at most `limit` of them (`sm_cibs_per_cab`, or fewer when the running total is near `sm_cib_count`).
    static func cibAddresses(in block: Data, limit: Int64) throws -> [Int64] {
        let count = Int(try block.number(36, 4))
        guard count <= (block.count - 40) / 8 else { throw ScanError.malformed("APFS chunk-info address block overflows.") }
        guard Int64(count) <= limit else { throw ScanError.malformed("APFS chunk-info address block lists too many blocks.") }
        return try (0..<count).map { try signed(block.number(40 + $0 * 8, 8)) }
    }
}
