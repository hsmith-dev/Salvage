import Foundation

/// APFS parser (AD-2: original Swift from Apple's public APFS Reference; no GPL/LGPL code).
/// Handles a container (NXSB at block 0) and a bare unlocked volume device (APSB at block 0).
/// All offsets are relative to one validated partition.
///
/// An encrypted (FileVault) volume in a container is read when `credentials` holds a password or
/// recovery key for its UUID that unwraps its key (Story 2.5, `APFSCrypto.swift`): its encrypted
/// metadata blocks are decrypted on read and its files map to `.encryptedRuns`. Without a working
/// credential it is reported with `.unlockRequired` and skipped, as before.
///
/// Live metadata is fail-closed: every object read is checksum-verified and any inconsistency is
/// `ScanError.malformed`. Deleted-file recovery (older checkpoints and snapshots) is best effort:
/// a candidate that doesn't validate is skipped, and the work is bounded by a per-volume budget.
actor APFSContainer {
    static let isImplemented = true
    /// Hard cap on live B-tree node visits per scan; strict level descent already makes traversal finite.
    static let maxLiveNodes = 1 << 23
    static let maxOlderCheckpoints = 64
    static let maxSnapshots = 64
    static let maxExtentsPerFile = 1 << 20
    static let maxDeletedCandidates = 200_000
    static let maxFreeQueueEntries = 1 << 20
    static let maxSpacemanBytes: Int64 = 1 << 20
    static let nodeCacheLimit = 512
    static let chunkInfoCacheLimit = 256
    static let bitmapCacheLimit = 64

    let reader: any BlockReader
    let extent: VolumeExtent
    /// The scanned device, annotated and emitted with `.unlockRequired` for an encrypted volume.
    let device: BlockDevice?
    let emit: @Sendable (ScanEvent) async throws -> Void
    /// Where an unlocked volume whose file tree is damaged is reported as skipped (`.volumeSkipped`).
    let notice: @Sendable (ScanNotice) -> Void
    /// Passwords or recovery keys by volume UUID (uppercased).
    let credentials: [String: VolumeCredential]
    let crypto: any APFSCryptoProvider

    /// The key of the encrypted volume being walked, and its identifier for `.encryptedRuns`; nil
    /// for an unencrypted volume. Set per volume by `scan()`.
    var activeCipher: APFSVolumeDecryptor?
    var activeKeyID: String?

    var blockSize: Int64 = APFS.minBlockSize
    var blockCount: Int64 = 0
    /// True when the extent is a bare volume device (APSB at block 0), which is read as plaintext.
    var isBareVolume = false
    /// The chosen checkpoint's transaction and `nx_block_count`.
    var currentXID: UInt64 = 0
    var containerBlockCount: Int64 = 0
    /// Keyed by address and whether the block was decrypted: one block is never read both ways.
    var nodeCache: [APFSNodeCacheKey: APFSBTreeNode] = [:]
    var nodesVisited = 0
    /// While set, node visits and bitmap checks are charged to the deleted-file budget.
    var spending = false
    var deletedWorkRemaining: Int64 = 0
    var deletedWorkOverride: Int64?

    var checkpointMappings: [UInt64: Int64] = [:]
    var checkpointMappingSizes: [UInt64: Int64] = [:]
    var spaceman: APFSSpaceManager?
    var cibAddresses: [Int64] = []
    var chunkInfoCache: [Int: [APFSChunkInfo]] = [:]
    var bitmapCache: [Int64: Data] = [:]
    /// Deferred frees from the main free queue, sorted by first block; disjoint.
    var freeQueue: [APFSFreeRange] = []
    /// Why deleted-file recovery was skipped for the scan, if it was (tests and notes).
    var deletedRecoverySkippedReason: String?

    let liveDirectories = APFSDirectoryIndex()
    /// Deleted candidates from every volume; overlaps are resolved container-wide before emitting.
    var deletedCandidates: [APFSDeletedCandidate] = []
    /// Inode ids already collected for the volume being walked (ids are per volume).
    var candidateIDs: Set<UInt64> = []
    /// Remaining deleted-file budget per volume index.
    var volumeBudgets: [Int: Int64] = [:]

    init(reader: any BlockReader, extent: VolumeExtent, device: BlockDevice?,
         credentials: [String: VolumeCredential] = [:], crypto: any APFSCryptoProvider = CommonCryptoProvider(),
         notice: @escaping @Sendable (ScanNotice) -> Void = { _ in },
         emit: @escaping @Sendable (ScanEvent) async throws -> Void) {
        self.reader = reader; self.extent = extent; self.device = device; self.emit = emit; self.notice = notice
        self.credentials = Dictionary(credentials.map { ($0.key.uppercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
        self.crypto = crypto
    }

    /// Test seam: replaces the default per-volume deleted-file budget (`100_000 + 4 × live nodes` units).
    func limitDeletedWork(to units: Int64) { deletedWorkOverride = units }

    // MARK: - Reads

    func read(_ offset: Int64, _ count: Int) async throws -> Data {
        try Task.checkCancellation()
        guard offset >= 0, count >= 0, offset <= extent.length, Int64(count) <= extent.length - offset else {
            throw ScanError.malformed("Read outside partition.")
        }
        let data = try await reader.read(at: checkedAdd(extent.offset, offset), count: count)
        guard data.count == count else { throw ScanError.malformed("Truncated structure.") }
        return data
    }

    func readBlocks(_ address: Int64, count: Int64 = 1) async throws -> Data {
        guard address >= 0, count > 0, address < blockCount, count <= blockCount - address else {
            throw ScanError.malformed("APFS block \(address) is outside the container.")
        }
        return try await read(checkedMultiply(address, blockSize), Int(checkedMultiply(count, blockSize)))
    }

    /// An object whose Fletcher-64 checksum verifies. `decrypting` reads it through the active
    /// volume key first; the checksum then covers the plaintext, so a wrong key never verifies.
    func object(at address: Int64, blocks: Int64 = 1, decrypting: Bool = false) async throws -> Data {
        var data = try await readBlocks(address, count: blocks)
        if decrypting {
            guard let cipher = activeCipher else { throw ScanError.unsupportedFilesystem }
            data = try decryptBlocks(data, at: address, with: cipher.xts)
        }
        guard apfsChecksumIsValid(data) else { throw ScanError.malformed("APFS object checksum mismatch at block \(address).") }
        return data
    }

    /// XTS data units are 512 bytes; a block's first unit is its address in those units.
    func dataUnit(ofBlock address: Int64) throws -> UInt64 {
        UInt64(try checkedMultiply(address, blockSize / Int64(AESXTS.dataUnitSize)))
    }

    func decryptBlocks(_ data: Data, at address: Int64, with cipher: AESXTS) throws -> Data {
        do { return try cipher.decrypt(data, firstDataUnit: try dataUnit(ofBlock: address)) } catch let error as ScanError { throw error } catch {
            throw ScanError.malformed("APFS block \(address) couldn't be decrypted.")
        }
    }

    /// Best-effort work: damaged or unsupported metadata yields nil; cancellation, device errors
    /// and budget exhaustion propagate.
    func attempt<T: Sendable>(_ body: () async throws -> T) async throws -> T? {
        do { return try await body() } catch let error as ScanError {
            switch error {
            case .malformed, .unsupportedFilesystem: return nil
            default: throw error
            }
        }
    }

    // MARK: - Scan

    func scan() async throws {
        guard extent.length >= APFS.minBlockSize else { throw ScanError.malformed("APFS partition is too small.") }
        let prefix = try await read(0, Int(APFS.minBlockSize))
        if try prefix.number(32, 4) == APFS.volumeMagic { try await scanBareVolume(); return }
        blockSize = try APFSContainerSuperblock.blockSize(of: prefix)
        blockCount = extent.length / blockSize
        let primary = try APFSContainerSuperblock(try await object(at: 0))
        blockCount = min(primary.blockCount, blockCount)
        let candidates = try await checkpointCandidates(primary)
        // The latest checkpoint whose superblock and object map both verify.
        var chosen: (superblock: APFSContainerSuperblock, omapTree: Int64)?
        for candidate in candidates {
            if let tree = try await attempt({ try await self.objectMapTree(at: candidate.omapAddress) }) {
                chosen = (candidate, tree); break
            }
        }
        guard let (superblock, omapTree) = chosen else { throw ScanError.malformed("No valid APFS checkpoint.") }
        currentXID = superblock.header.xid
        containerBlockCount = superblock.blockCount
        try await loadCheckpointMappings(superblock)
        try await loadSpaceManager(superblock)
        let older = candidates.filter { $0.header.xid < superblock.header.xid }
        deletedCandidates = []; volumeBudgets = [:]
        defer { activeCipher = nil; activeKeyID = nil }
        for (volumeIndex, fsOID) in superblock.fsOIDs.enumerated() {
            activeCipher = nil; activeKeyID = nil
            guard let volume = try await volumeSuperblock(fsOID: fsOID, omapTree: omapTree, xid: superblock.header.xid) else {
                throw ScanError.malformed("APFS volume \(fsOID) is missing from the object map.")
            }
            let context: APFSVolumeContext
            if volume.isEncrypted {
                guard let unlocked = try await unlockedContext(volume, superblock: superblock) else {
                    // Unlocked but its file tree is damaged: skipped with a notice, since asking for
                    // the password again can't help. Any other failure still asks for an unlock.
                    if credentials[volume.uuid.uuidString.uppercased()]?.failure == .damaged {
                        notice(.volumeSkipped(formatName: extent.formatName ?? extent.format.displayName,
                                              offset: extent.offset, reason: Self.damagedUnlockedVolumeReason))
                    } else {
                        try await emit(.unlockRequired(unlockDevice(volume)))
                    }
                    continue
                }
                context = unlocked
            } else {
                context = try await volumeContext(volume, xid: superblock.header.xid)
            }
            let liveNodes = try await scanLiveVolume(context)
            try await collectDeletedCandidates(in: context, volume: volumeIndex, fsOID: fsOID, older: older, liveNodes: liveNodes)
        }
        // Only once every volume's candidates are known can two of them be found claiming one block.
        try await emitDeletedCandidates()
        deletedCandidates = []; candidateIDs = []
    }

    /// A volume device read directly (Story 2.4's unlocked device): one volume, physical addresses
    /// relative to the device, no container and so no space manager.
    func scanBareVolume() async throws {
        // A volume superblock doesn't record the block size, but its checksum covers the whole
        // block, so only the right size verifies.
        var found: APFSVolumeSuperblock?
        var size = APFS.minBlockSize
        while size <= APFS.maxBlockSize, size <= extent.length, found == nil {
            blockSize = size; blockCount = extent.length / size; nodeCache = [:]
            found = try await attempt {
                let block = try await self.read(0, Int(size))
                guard apfsChecksumIsValid(block) else { throw ScanError.malformed("APFS volume superblock checksum mismatch.") }
                return try APFSVolumeSuperblock(block)
            }
            size *= 2
        }
        guard let volume = found else { throw ScanError.malformed("APFS volume superblock checksum mismatch.") }
        // An unlocked volume device read directly is already plaintext, whatever its superblock and
        // object map say about encryption: parse it rather than asking for an unlock.
        isBareVolume = true
        let context = try await volumeContext(volume, xid: volume.header.xid)
        _ = try await scanLiveVolume(context)
        deletedRecoverySkippedReason = "A bare volume has no space manager, so deleted files can't be verified free."
    }

    // MARK: - Encrypted volumes

    /// The live context of an encrypted volume, read through its key, when a credential for it
    /// unwraps that key and the key decrypts its root tree; nil (after recording why on the
    /// credential) otherwise. Leaves `activeCipher` set on success.
    func unlockedContext(_ volume: APFSVolumeSuperblock, superblock: APFSContainerSuperblock) async throws -> APFSVolumeContext? {
        guard let credential = credentials[volume.uuid.uuidString.uppercased()] else { return nil }
        let cipher: APFSVolumeDecryptor
        if let unwrapped = credential.decryptor as? APFSVolumeDecryptor {
            // Already unwrapped (by `EncryptedVolumeUnlock.verify` or an earlier scan): the secret
            // may be zeroed by now; the key is still checked against the root tree below.
            cipher = unwrapped
        } else {
            switch try await unlock(volume, superblock: superblock, credential: credential) {
            case .success(let unlocked): cipher = unlocked
            case .failure(let error): credential.record(.failure(error)); return nil
            }
        }
        activeCipher = cipher; activeKeyID = volume.uuid.uuidString
        // The VEK passed RFC 3394's integrity check under a KEK the credential opened, so it is the
        // volume's key: a root tree that then fails its checksum or structure check is damage, not
        // a hardware-bound key (those fail earlier, as `.unsupported`). Fail closed either way.
        guard let context = try await attempt({ try await self.volumeContext(volume, xid: superblock.header.xid) }) else {
            activeCipher = nil; activeKeyID = nil
            credential.record(.failure(.damaged))
            return nil
        }
        credential.record(.success(cipher))
        return context
    }

    /// The `.volumeSkipped` reason for an unlocked volume whose file tree is damaged.
    static let damagedUnlockedVolumeReason = "Salvage unlocked this volume but its file list is damaged, so its files can't be listed."

    /// Unwraps the volume's key with `credential` (see `APFSKeyUnwrapper` for what each failure means).
    func unlock(_ volume: APFSVolumeSuperblock, superblock: APFSContainerSuperblock,
                credential: VolumeCredential) async throws -> Result<APFSVolumeDecryptor, UnlockError> {
        // Per-file keys (no ONEKEY) are how hardware-encrypted volumes are laid out.
        guard volume.flags & APFS.fsOneKey != 0 else { return .failure(.unsupported) }
        let volumeUUID = withUnsafeBytes(of: volume.uuid.uuid) { Data($0) }
        do {
            let containerBag = try await keybag(start: superblock.keylockerStart, count: superblock.keylockerCount,
                                                uuid: superblock.uuid, type: APFSKeybag.containerType)
            let mine = containerBag.filter { $0.uuid == volumeUUID }
            guard let wrappedVEK = mine.first(where: { $0.tag == APFSKeybag.tagVolumeKey })?.data,
                  let location = mine.first(where: { $0.tag == APFSKeybag.tagUnlockRecords })?.data, location.count >= 16 else {
                return .failure(.unsupported)
            }
            let volumeBag = try await keybag(start: Int64(bitPattern: try location.number(0, 8)),
                                             count: Int64(bitPattern: try location.number(8, 8)),
                                             uuid: volumeUUID, type: APFSKeybag.volumeType)
            let records = volumeBag.filter { $0.tag == APFSKeybag.tagUnlockRecords }
            let unwrapper = APFSKeyUnwrapper(provider: crypto)
            let kek = try unwrapper.unwrapKEK(records: records, credential: credential)
            defer { kek.zero() }
            return .success(APFSVolumeDecryptor(xts: try unwrapper.unwrapVEK(wrappedVEK, kek: kek)))
        } catch let error as UnlockError {
            return .failure(error)
        } catch let error as ScanError {
            switch error {
            case .malformed: return .failure(.toolFailure)
            case .unsupportedFilesystem: return .failure(.unsupported)
            default: throw error
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .failure(.toolFailure)
        }
    }

    /// A keybag's entries: its blocks decrypted with `uuid` in both key halves, then verified.
    func keybag(start: Int64, count: Int64, uuid: Data, type: UInt32) async throws -> [APFSKeybagEntry] {
        guard start > 0, count > 0, count <= APFSKeybag.maxBlocks else { throw ScanError.unsupportedFilesystem }
        let ciphertext = try await readBlocks(start, count: count)
        let plaintext = try decryptBlocks(ciphertext, at: start, with: try apfsKeybagCipher(uuid: uuid, provider: crypto))
        return try APFSKeybag.entries(in: plaintext, type: type)
    }

    /// Checks `credential` against the encrypted volume `volumeUUID` in this container, reading only
    /// what an unlock needs (checkpoint, keybags, the volume's root tree). Nil when the container
    /// has no such encrypted volume.
    func verifyUnlock(volumeUUID: String) async throws -> Result<Void, UnlockError>? {
        let wanted = volumeUUID.uppercased()
        guard let credential = credentials[wanted], extent.length >= APFS.minBlockSize else { return nil }
        let prefix = try await read(0, Int(APFS.minBlockSize))
        guard try prefix.number(32, 4) == APFS.nxMagic else { return nil }
        blockSize = try APFSContainerSuperblock.blockSize(of: prefix)
        blockCount = extent.length / blockSize
        let primary = try APFSContainerSuperblock(try await object(at: 0))
        blockCount = min(primary.blockCount, blockCount)
        var chosen: (superblock: APFSContainerSuperblock, omapTree: Int64)?
        for candidate in try await checkpointCandidates(primary) {
            if let tree = try await attempt({ try await self.objectMapTree(at: candidate.omapAddress) }) { chosen = (candidate, tree); break }
        }
        guard let (superblock, omapTree) = chosen else { return .failure(.toolFailure) }
        defer { activeCipher = nil; activeKeyID = nil }
        for fsOID in superblock.fsOIDs {
            guard let volume = try await attempt({ try await self.volumeSuperblock(fsOID: fsOID, omapTree: omapTree, xid: superblock.header.xid) }) ?? nil,
                  volume.uuid.uuidString.uppercased() == wanted else { continue }
            guard volume.isEncrypted else { return .failure(.toolFailure) }
            if try await unlockedContext(volume, superblock: superblock) != nil { return .success(()) }
            return .failure(credential.failure ?? .toolFailure)
        }
        return nil
    }

    func unlockDevice(_ volume: APFSVolumeSuperblock) -> BlockDevice {
        let base = device ?? BlockDevice(bsdName: "", displayName: volume.name, sizeBytes: 0, isInternal: false, isBootVolume: false)
        return base.requiringUnlock(volumeUUID: volume.uuid.uuidString, volumeName: volume.name)
    }

    // MARK: - Checkpoints

    /// Every verified container superblock in the descriptor ring plus block 0, newest first.
    func checkpointCandidates(_ primary: APFSContainerSuperblock) async throws -> [APFSContainerSuperblock] {
        var found: [UInt64: APFSContainerSuperblock] = [primary.header.xid: primary]
        for index in 0..<primary.descriptorBlocks {
            let address = primary.descriptorBase + index
            let superblock: APFSContainerSuperblock? = try await attempt {
                let block = try await self.object(at: address)
                guard try APFSObjectHeader(block).type == APFS.ObjectType.nxSuperblock else { return nil }
                return try APFSContainerSuperblock(block)
            } ?? nil
            guard let superblock, superblock.blockSize == primary.blockSize, superblock.uuid == primary.uuid,
                  superblock.blockCount == primary.blockCount, found[superblock.header.xid] == nil else { continue }
            found[superblock.header.xid] = superblock
        }
        return found.values.sorted { $0.header.xid > $1.header.xid }
    }

    /// Ephemeral object locations (space manager, free queues) from the checkpoint's map blocks.
    func loadCheckpointMappings(_ superblock: APFSContainerSuperblock) async throws {
        checkpointMappings = [:]; checkpointMappingSizes = [:]
        for index in 0..<superblock.descriptorLength {
            let address = superblock.descriptorBase + (superblock.descriptorIndex + index) % superblock.descriptorBlocks
            let mappings: [APFSCheckpointMapping]? = try await attempt {
                let block = try await self.object(at: address)
                let header = try APFSObjectHeader(block)
                // A map block left over from another checkpoint describes that checkpoint's objects.
                guard header.type == APFS.ObjectType.checkpointMap, header.xid == superblock.header.xid else { return nil }
                return try APFSCheckpointMapping.mappings(in: block).mappings
            } ?? nil
            for mapping in mappings ?? [] {
                checkpointMappings[mapping.oid] = mapping.address
                checkpointMappingSizes[mapping.oid] = mapping.size
            }
        }
    }

    /// Reads the space manager and its free queue. Failure disables deleted-file recovery; it never
    /// fails the live scan.
    func loadSpaceManager(_ superblock: APFSContainerSuperblock) async throws {
        spaceman = nil; cibAddresses = []; freeQueue = []
        guard let address = checkpointMappings[superblock.spacemanOID] else {
            deletedRecoverySkippedReason = "The space manager isn't in the checkpoint maps."; return
        }
        let size = min(max(checkpointMappingSizes[superblock.spacemanOID] ?? blockSize, blockSize), Self.maxSpacemanBytes)
        let loaded: (APFSSpaceManager, [Int64])? = try await attempt {
            let data = try await self.object(at: address, blocks: (size + self.blockSize - 1) / self.blockSize)
            let manager = try APFSSpaceManager(data, containerBlockSize: self.blockSize, containerBlockCount: superblock.blockCount)
            guard manager.header.oid == superblock.spacemanOID, manager.header.xid == superblock.header.xid else {
                throw ScanError.malformed("APFS space manager doesn't belong to the chosen checkpoint.")
            }
            guard manager.blockCount == superblock.blockCount, manager.tier2BlockCount == 0 else {
                throw ScanError.unsupportedFilesystem
            }
            var cibs = manager.addresses
            if manager.cabCount > 0 {
                guard Set(manager.addresses).count == manager.addresses.count else { throw ScanError.malformed("APFS chunk-info address blocks repeat.") }
                cibs = []
                for cab in manager.addresses {
                    let block = try await self.object(at: cab)
                    guard try APFSObjectHeader(block).type == APFS.ObjectType.spacemanCAB else { throw ScanError.malformed("APFS chunk-info address block has the wrong type.") }
                    // Each block holds at most `cibsPerCAB` entries and the total at most `cibCount`,
                    // checked before anything is appended.
                    let limit = min(manager.cibsPerCAB, manager.cibCount - Int64(cibs.count))
                    cibs += try APFSChunkInfo.cibAddresses(in: block, limit: limit)
                }
            }
            guard Int64(cibs.count) == manager.cibCount, Set(cibs).count == cibs.count else {
                throw ScanError.malformed("APFS chunk-info block list is inconsistent.")
            }
            return (manager, cibs)
        }
        guard let (manager, cibs) = loaded else {
            deletedRecoverySkippedReason = "The space manager couldn't be read."; return
        }
        spaceman = manager; cibAddresses = cibs
        try await loadFreeQueue(manager)
    }

    /// Blocks freed in recent transactions stay allocated in the bitmaps until every checkpoint that
    /// referenced them has left the ring; the main free queue lists them with the freeing transaction.
    func loadFreeQueue(_ manager: APFSSpaceManager) async throws {
        freeQueue = []
        guard manager.mainFreeQueueCount > 0 else { return }
        guard let root = checkpointMappings[manager.mainFreeQueueTreeOID] else { return }
        let tree = APFSTree(root: root, rootReference: APFSObjectReference(oid: manager.mainFreeQueueTreeOID, xid: nil),
                            kind: .ephemeral(checkpointMappings), compare: compareAPFSPairKeys)
        let ranges: [APFSFreeRange]? = try await attempt {
            var result: [APFSFreeRange] = []
            var cursor = try await self.seek(nil, in: tree)
            while let record = try await self.next(&cursor, in: tree) {
                guard record.key.count == 16 else { throw ScanError.malformed("APFS free-queue key has the wrong size.") }
                let xid = try record.key.number(0, 8), start = try signed(record.key.number(8, 8))
                // A ghost entry (no value) frees one block.
                let count = record.value.isEmpty ? 1 : try signed(record.value.number(0, 8))
                guard count > 0, start >= 0, count <= self.blockCount - start, result.count < Self.maxFreeQueueEntries else {
                    throw ScanError.malformed("APFS free-queue entry is invalid.")
                }
                result.append(APFSFreeRange(start: start, end: start + count, xid: xid))
            }
            return result
        }
        guard let ranges else { return }
        let sorted = ranges.sorted { $0.start < $1.start }
        for index in sorted.indices.dropFirst() where sorted[index - 1].end > sorted[index].start { return }
        freeQueue = sorted
    }

    // MARK: - Object maps and volumes

    /// Verifies an object map and its tree root, returning the root node's address.
    func objectMapTree(at address: Int64) async throws -> Int64 {
        try await objectMap(at: address).treeAddress
    }

    /// Verifies an object map (a physical object, so its identifier is its address) and its tree root.
    func objectMap(at address: Int64) async throws -> APFSObjectMap {
        let omap = try APFSObjectMap(try await object(at: address))
        guard omap.header.oid == UInt64(address) else { throw ScanError.malformed("APFS object map at block \(address) doesn't match its reference.") }
        let root = try await node(at: omap.treeAddress, expecting: .physical(omap.treeAddress), inheritedInfo: nil)
        guard root.isRoot, root.header.subtype == APFS.ObjectType.omap else { throw ScanError.malformed("APFS object map tree is invalid.") }
        return omap
    }

    /// The mapping for `oid` with the greatest transaction not after `xid`.
    func omapLookup(oid: UInt64, xid: UInt64, tree: Int64) async throws -> APFSObjectMapEntry? {
        var key = Data(count: 16)
        for index in 0..<8 { key[index] = UInt8(truncatingIfNeeded: oid >> (index * 8)); key[8 + index] = UInt8(truncatingIfNeeded: xid >> (index * 8)) }
        let omapTree = APFSTree(root: tree, rootReference: .physical(tree), kind: .physical, compare: compareAPFSPairKeys)
        guard let record = try await floorRecord(key, in: omapTree), record.key.count == 16, record.value.count >= 16,
              try record.key.number(0, 8) == oid else { return nil }
        let entry = APFSObjectMapEntry(xid: try record.key.number(8, 8), flags: UInt32(try record.value.number(0, 4)),
                                       size: UInt32(try record.value.number(4, 4)), address: try signed(record.value.number(8, 8)))
        return entry.flags & APFS.omapValueDeleted == 0 ? entry : nil
    }

    func volumeSuperblock(fsOID: UInt64, omapTree: Int64, xid: UInt64) async throws -> APFSVolumeSuperblock? {
        guard let entry = try await omapLookup(oid: fsOID, xid: xid, tree: omapTree) else { return nil }
        guard entry.flags & (APFS.omapValueEncrypted | APFS.omapValueNoHeader) == 0 else { throw ScanError.unsupportedFilesystem }
        let volume = try APFSVolumeSuperblock(try await object(at: entry.address))
        guard volume.header.oid == fsOID, volume.header.xid == entry.xid else { throw ScanError.malformed("APFS volume superblock doesn't match its object-map entry.") }
        return volume
    }

    /// Resolves a volume's object map and root tree at `xid`.
    func volumeContext(_ volume: APFSVolumeSuperblock, xid: UInt64) async throws -> APFSVolumeContext {
        let omap = try await objectMap(at: volume.omapAddress)
        let converting = omap.flags & (APFS.omapEncrypting | APFS.omapDecrypting) != 0
        return try await volumeContext(volume, xid: xid, omapTree: omap.treeAddress, converting: converting)
    }

    /// `converting` is the object map's encrypting/decrypting state (see `content(of:…)`).
    func volumeContext(_ volume: APFSVolumeSuperblock, xid: UInt64, omapTree: Int64, converting: Bool) async throws -> APFSVolumeContext {
        guard let entry = try await omapLookup(oid: volume.rootTreeOID, xid: xid, tree: omapTree) else {
            throw ScanError.malformed("APFS root tree is missing from the volume's object map.")
        }
        let encrypted = try checkEntryIsReadable(entry)
        let reference = APFSObjectReference(oid: volume.rootTreeOID, xid: entry.xid)
        let root = try await node(at: entry.address, expecting: reference, inheritedInfo: nil, decrypting: encrypted)
        guard root.isRoot, root.header.subtype == APFS.ObjectType.fsTree else { throw ScanError.malformed("APFS root tree is invalid.") }
        let compare = makeAPFSRecordKeyComparator(hashedDirectoryKeys: volume.hashedDirectoryKeys)
        return APFSVolumeContext(superblock: volume, xid: xid, omapTree: omapTree, root: entry.address, converting: converting,
                                 tree: APFSTree(root: entry.address, rootReference: reference,
                                                kind: .virtual(omapTree: omapTree, xid: xid), compare: compare,
                                                rootIsEncrypted: encrypted))
    }

    /// An object-map entry flagged encrypted names a block of ciphertext in a container, readable
    /// only through the active volume key; on a bare volume device (already unlocked) that flag is
    /// the normal case and the block reads as plaintext. Returns whether the block must be decrypted.
    func checkEntryIsReadable(_ entry: APFSObjectMapEntry) throws -> Bool {
        guard entry.flags & APFS.omapValueNoHeader == 0 else { throw ScanError.unsupportedFilesystem }
        guard entry.flags & APFS.omapValueEncrypted != 0, !isBareVolume else { return false }
        guard activeCipher != nil else { throw ScanError.unsupportedFilesystem }
        return true
    }

    // MARK: - B-tree access

    func charge() throws {
        if spending {
            guard deletedWorkRemaining > 0 else { throw APFSBudgetExhausted() }
            deletedWorkRemaining -= 1
        } else {
            nodesVisited += 1
            guard nodesVisited <= Self.maxLiveNodes else { throw ScanError.malformed("APFS metadata is too large to scan.") }
        }
    }

    func spend(_ units: Int64) throws {
        guard units <= deletedWorkRemaining else { deletedWorkRemaining = 0; throw APFSBudgetExhausted() }
        deletedWorkRemaining -= units
    }

    /// The node at `address`, which must be the object `reference` names: a block that checksums
    /// but carries another identifier or transaction was reused and is never read as this node.
    func node(at address: Int64, expecting reference: APFSObjectReference, inheritedInfo: APFSBTreeInfo?,
              decrypting: Bool = false) async throws -> APFSBTreeNode {
        try charge()
        let node: APFSBTreeNode
        let key = APFSNodeCacheKey(address: address, decrypted: decrypting)
        if let cached = nodeCache[key] {
            node = cached
        } else {
            node = try APFSBTreeNode(try await object(at: address, decrypting: decrypting), address: address, inheritedInfo: inheritedInfo)
            if nodeCache.count >= Self.nodeCacheLimit { nodeCache.removeAll(keepingCapacity: true) }
            nodeCache[key] = node
        }
        guard reference.matches(node.header) else {
            throw ScanError.malformed("APFS B-tree node at block \(address) doesn't match its reference.")
        }
        return node
    }

    func child(of parent: APFSBTreeNode, index: Int, in tree: APFSTree, rootInfo: APFSBTreeInfo?) async throws -> APFSBTreeNode {
        let identifier = try parent.childIdentifier(index)
        let address: Int64, reference: APFSObjectReference
        var encrypted = false
        switch tree.kind {
        case .physical:
            address = try signed(identifier)
            reference = .physical(address)
        case .virtual(let omapTree, let xid):
            guard let entry = try await omapLookup(oid: identifier, xid: xid, tree: omapTree) else {
                throw ScanError.malformed("APFS B-tree node \(identifier) is missing from the object map.")
            }
            encrypted = try checkEntryIsReadable(entry)
            address = entry.address
            reference = APFSObjectReference(oid: identifier, xid: entry.xid)
        case .ephemeral(let mappings):
            guard let mapped = mappings[identifier] else { throw ScanError.malformed("APFS ephemeral node \(identifier) isn't in the checkpoint maps.") }
            address = mapped
            reference = APFSObjectReference(oid: identifier, xid: nil)
        }
        let child = try await node(at: address, expecting: reference, inheritedInfo: rootInfo, decrypting: encrypted)
        // Levels strictly decrease toward the leaves, so no path can revisit a node.
        guard child.level == parent.level - 1, child.header.subtype == parent.header.subtype, !child.isRoot else {
            throw ScanError.malformed("APFS B-tree structure is inconsistent.")
        }
        return child
    }

    /// Index of the last key not greater than `key`, or -1.
    func floorIndex(_ key: Data, in node: APFSBTreeNode, compare: (Data, Data) -> Int) throws -> Int {
        var low = 0, high = node.keyCount, found = -1
        while low < high {
            let middle = (low + high) / 2
            if compare(try node.key(middle).data, key) <= 0 { found = middle; low = middle + 1 } else { high = middle }
        }
        return found
    }

    /// The record with the greatest key not greater than `key`, if any.
    func floorRecord(_ key: Data, in tree: APFSTree) async throws -> APFSRecord? {
        var current = try await node(at: tree.root, expecting: tree.rootReference, inheritedInfo: nil, decrypting: tree.rootIsEncrypted)
        guard current.isRoot else { throw ScanError.malformed("APFS B-tree root isn't a root node.") }
        let info = current.info
        for _ in 0...APFS.maxTreeDepth {
            let index = try floorIndex(key, in: current, compare: tree.compare)
            guard index >= 0 else { return nil }
            if current.isLeaf {
                let (_, keyData) = try current.key(index), (offset, value) = try current.value(index)
                return APFSRecord(key: keyData, value: value, nodeAddress: current.address, valueOffset: offset)
            }
            current = try await child(of: current, index: index, in: tree, rootInfo: info)
        }
        throw ScanError.malformed("APFS B-tree is too deep.")
    }

    /// A cursor at the greatest record not greater than `key` (or the first record when `key` is
    /// nil or below every key). Callers skip records before their range.
    func seek(_ key: Data?, in tree: APFSTree) async throws -> APFSTreeCursor {
        var cursor = APFSTreeCursor()
        var current = try await node(at: tree.root, expecting: tree.rootReference, inheritedInfo: nil, decrypting: tree.rootIsEncrypted)
        guard current.isRoot else { throw ScanError.malformed("APFS B-tree root isn't a root node.") }
        let info = current.info
        for _ in 0...APFS.maxTreeDepth {
            let index = try key.map { max(try floorIndex($0, in: current, compare: tree.compare), 0) } ?? 0
            cursor.path.append((current, index))
            if current.isLeaf { return cursor }
            guard current.keyCount > 0 else { throw ScanError.malformed("APFS B-tree interior node is empty.") }
            current = try await child(of: current, index: index, in: tree, rootInfo: info)
        }
        throw ScanError.malformed("APFS B-tree is too deep.")
    }

    /// The record at the cursor, advancing it; nil at the end. Keys must never decrease.
    func next(_ cursor: inout APFSTreeCursor, in tree: APFSTree) async throws -> APFSRecord? {
        guard !cursor.finished, let info = cursor.path.first?.node.info else { cursor.finished = true; return nil }
        while true {
            let depth = cursor.path.count - 1
            let (leaf, index) = cursor.path[depth]
            if index < leaf.keyCount {
                let (_, key) = try leaf.key(index), (offset, value) = try leaf.value(index)
                cursor.path[depth].index = index + 1
                if let last = cursor.lastKey, tree.compare(last, key) > 0 { throw ScanError.malformed("APFS B-tree keys are out of order.") }
                cursor.lastKey = key
                return APFSRecord(key: key, value: value, nodeAddress: leaf.address, valueOffset: offset)
            }
            // This leaf is exhausted: climb to the nearest ancestor with another child, then go leftmost.
            cursor.path.removeLast()
            while let top = cursor.path.last {
                let nextIndex = top.index + 1
                if nextIndex < top.node.keyCount {
                    cursor.path[cursor.path.count - 1].index = nextIndex
                    var current = try await child(of: top.node, index: nextIndex, in: tree, rootInfo: info)
                    while !current.isLeaf {
                        guard current.keyCount > 0 else { throw ScanError.malformed("APFS B-tree interior node is empty.") }
                        cursor.path.append((current, 0))
                        current = try await child(of: current, index: 0, in: tree, rootInfo: info)
                    }
                    cursor.path.append((current, 0))
                    break
                }
                cursor.path.removeLast()
            }
            if cursor.path.isEmpty { cursor.finished = true; return nil }
        }
    }

    // MARK: - Live files

    /// Walks the filesystem tree in key order. Records of one object (its inode, then its file
    /// extents) are adjacent, so each file is emitted when its identifier's group ends.
    func scanLiveVolume(_ context: APFSVolumeContext) async throws -> Int {
        let before = nodesVisited
        liveDirectories.reset()
        var cursor = try await seek(nil, in: context.tree)
        var group: APFSRecordGroup?
        while let record = try await next(&cursor, in: context.tree) {
            let key = try APFSRecordKey(record.key)
            if let current = group, current.id != key.objectID {
                try await finishLiveGroup(current, context)
                group = nil
            }
            var current = group ?? APFSRecordGroup(id: key.objectID)
            try Self.accumulate(record, key, into: &current, strict: true)
            group = current
        }
        if let current = group { try await finishLiveGroup(current, context) }
        return nodesVisited - before
    }

    static func accumulate(_ record: APFSRecord, _ key: APFSRecordKey, into group: inout APFSRecordGroup, strict: Bool) throws {
        switch key.type {
        case APFS.RecordType.inode:
            guard group.inode == nil else { throw ScanError.malformed("APFS inode \(key.objectID) appears twice.") }
            group.inode = try APFSInode(record.value)
            group.record = record
        case APFS.RecordType.fileExtent:
            if group.extents.count < maxExtentsPerFile {
                group.extents.append(try APFSFileExtent(key: record.key, value: record.value))
            } else {
                group.extentOverflow = true
            }
        default:
            break
        }
    }

    func finishLiveGroup(_ group: APFSRecordGroup, _ context: APFSVolumeContext) async throws {
        guard let inode = group.inode, let record = group.record else { return }
        if inode.isDirectory {
            if let name = inode.name { liveDirectories.entries[group.id] = APFSDirectoryEntry(parent: inode.parentID, name: name) }
            return
        }
        guard inode.isRegularFile, group.id >= APFS.minUserInodeID else { return }
        guard let name = inode.name else { throw ScanError.malformed("APFS inode \(group.id) has no name.") }
        guard let directory = try await path(of: inode.parentID, in: context, index: liveDirectories, fallback: nil) else { return }
        let extents = try await extents(for: inode, group: group, in: context)
        guard let content = try content(of: inode, extents: extents, deleted: false, converting: context.converting, keyID: activeKeyID) else { return }
        try await emit(.found(file(name: name, path: directory + "/" + name, inode: inode, id: group.id,
                                   record: record, content: content, deleted: false)))
    }

    /// The file's extents: the group's when the inode owns its data stream, otherwise (a clone) the
    /// records keyed by the shared stream's identifier. Nil when there are too many to hold.
    func extents(for inode: APFSInode, group: APFSRecordGroup, in context: APFSVolumeContext) async throws -> [APFSFileExtent]? {
        if inode.privateID == group.id { return group.extentOverflow ? nil : group.extents }
        var result: [APFSFileExtent] = []
        let start = APFSRecordKey.encode(objectID: inode.privateID, type: APFS.RecordType.fileExtent)
        var cursor = try await seek(start, in: context.tree)
        while let record = try await next(&cursor, in: context.tree) {
            let key = try APFSRecordKey(record.key)
            if key.objectID < inode.privateID || (key.objectID == inode.privateID && key.type < APFS.RecordType.fileExtent) { continue }
            guard key.objectID == inode.privateID, key.type == APFS.RecordType.fileExtent else { break }
            guard result.count < Self.maxExtentsPerFile else { return nil }
            result.append(try APFSFileExtent(key: record.key, value: record.value))
        }
        return result
    }

    /// The directory's path ("" for the root), `/Orphaned Files…` when the chain is broken, or nil
    /// when it leads into the private directory or another reserved object.
    func path(of directory: UInt64, in context: APFSVolumeContext, index: APFSDirectoryIndex,
              fallback: APFSVolumeContext?) async throws -> String? {
        var chain: [(UInt64, String)] = [], visited: Set<UInt64> = []
        var current = directory
        var prefix: String
        while true {
            if current == APFS.rootDirectoryID { prefix = ""; break }
            if current < APFS.minUserInodeID { return nil }
            if let cached = index.paths[current] { prefix = cached; break }
            guard visited.insert(current).inserted else { throw ScanError.malformed("APFS directory cycle.") }
            guard chain.count < APFS.maxPathDepth else { throw ScanError.malformed("APFS directory tree is too deep.") }
            if index.entries[current] == nil {
                var entry = try await lookupDirectory(current, in: context)
                if entry == nil, let fallback {
                    entry = liveDirectories.entries[current]
                    if entry == nil { entry = try await lookupDirectory(current, in: fallback) }
                }
                index.entries[current] = entry
            }
            guard let entry = index.entries[current] else { prefix = APFS.orphanedDirectory; break }
            chain.append((current, entry.name))
            current = entry.parent
        }
        for (id, name) in chain.reversed() {
            prefix += "/" + name
            index.paths[id] = prefix
        }
        return prefix
    }

    func lookupDirectory(_ id: UInt64, in context: APFSVolumeContext) async throws -> APFSDirectoryEntry? {
        let key = APFSRecordKey.encode(objectID: id, type: APFS.RecordType.inode)
        guard let record = try await floorRecord(key, in: context.tree), record.key == key else { return nil }
        let inode = try APFSInode(record.value)
        guard inode.isDirectory, let name = inode.name else { return nil }
        return APFSDirectoryEntry(parent: inode.parentID, name: name)
    }

    func inodeExists(_ id: UInt64, in tree: APFSTree) async throws -> Bool {
        let key = APFSRecordKey.encode(objectID: id, type: APFS.RecordType.inode)
        guard let record = try await floorRecord(key, in: tree) else { return false }
        return record.key == key
    }

    // MARK: - Content

    /// Device-absolute runs for the file's bytes. A live file's invalid extents are `malformed`;
    /// a deleted candidate's return nil (skip). Compressed files are left unmapped for now.
    ///
    /// Bytes that may be ciphertext are never mapped as plaintext: a live file is `.unmapped` (a
    /// deleted one is skipped) when the volume's object map is mid-encryption or mid-decryption
    /// (`converting`: either kind of block may be on disk, and nothing per extent says which), or, in
    /// a container, when any extent has a non-zero `crypto_id` and the volume isn't unlocked. On a
    /// bare volume device the platform has already unlocked the volume, so a `crypto_id` is
    /// expected there and only `converting` applies.
    ///
    /// In an unlocked encrypted volume (`keyID` set) every placed extent must carry its `crypto_id`,
    /// the XTS tweak base of its first block; the file maps to `.encryptedRuns`, one run per extent
    /// so each keeps its own tweak. An extent without one can't be decrypted: the file is unmapped.
    ///
    /// Holes are only accepted where the format declares them: an inode marked sparse, or an
    /// extent with `phys_block_num == 0`. A gap or short tail in a non-sparse live file means the
    /// extent list is incomplete, so its content is `.unmapped` rather than zero-filled.
    func content(of inode: APFSInode, extents: [APFSFileExtent]?, deleted: Bool, converting: Bool,
                 keyID: String? = nil) throws -> FileContent? {
        let unmapped: FileContent? = deleted ? nil : .unmapped
        if inode.isCompressed { return unmapped }
        let size = try signed(inode.size)
        if size == 0 { return keyID.map { .encryptedRuns([], keyID: $0) } ?? .runs([]) }
        guard let extents, inode.dataStream != nil else { return unmapped }
        if converting { return unmapped }
        let encrypted = keyID != nil && !isBareVolume
        if !isBareVolume, !encrypted, extents.contains(where: { $0.cryptoID != 0 }) { return unmapped }
        let unitsPerBlock = UInt64(blockSize) / UInt64(AESXTS.dataUnitSize)
        var runs: [DataRun] = [], cursor: Int64 = 0
        for extent in extents {
            let logical = try signed(extent.logicalAddress), length = try signed(extent.length), block = try signed(extent.physicalBlock)
            if logical >= size { break }
            guard length > 0, length % blockSize == 0, logical % blockSize == 0, logical >= cursor else {
                if deleted { return nil }
                throw ScanError.malformed("APFS file extent is invalid.")
            }
            if logical > cursor {
                guard inode.isSparse else { return unmapped }
                runs.append(DataRun(deviceOffset: nil, length: logical - cursor))
            }
            let mapped = min(length, size - logical)
            if block == 0 {
                // Block 0 holds the container superblock, so this can only mean "no blocks here".
                if deleted { return nil }
                runs.append(DataRun(deviceOffset: nil, length: mapped))
            } else {
                guard block < blockCount, length / blockSize <= blockCount - block else {
                    if deleted { return nil }
                    throw ScanError.malformed("APFS file extent is outside the container.")
                }
                let offset = try checkedAdd(self.extent.offset, checkedMultiply(block, blockSize))
                if encrypted {
                    let (unit, overflow) = extent.cryptoID.multipliedReportingOverflow(by: unitsPerBlock)
                    guard extent.cryptoID != 0, !overflow else { return unmapped }
                    runs.append(DataRun(deviceOffset: offset, length: mapped, firstDataUnit: unit))
                } else {
                    runs.append(DataRun(deviceOffset: offset, length: mapped))
                }
            }
            cursor = try checkedAdd(logical, length)
        }
        if cursor < size {
            guard inode.isSparse else { return unmapped }
            runs.append(DataRun(deviceOffset: nil, length: size - cursor))
        }
        if encrypted, let keyID { return .encryptedRuns(Self.coalesce(runs), keyID: keyID) }
        return .runs(Self.coalesce(runs))
    }

    /// Merges runs that continue one another on the device, and consecutive holes. Encrypted runs
    /// merge only when the tweak continues too and the first ends on a data-unit boundary.
    static func coalesce(_ runs: [DataRun]) -> [DataRun] {
        var result: [DataRun] = []
        let unit = Int64(AESXTS.dataUnitSize)
        for run in runs where run.length > 0 {
            if let last = result.last {
                let adjacent: Bool
                switch (last.deviceOffset, run.deviceOffset) {
                case (nil, nil): adjacent = true
                case let (a?, b?):
                    switch (last.firstDataUnit, run.firstDataUnit) {
                    case (nil, nil): adjacent = a + last.length == b
                    case let (first?, next?):
                        adjacent = a + last.length == b && last.length % unit == 0
                            && first.addingReportingOverflow(UInt64(last.length / unit)) == (next, false)
                    default: adjacent = false
                    }
                default: adjacent = false
                }
                if adjacent {
                    result[result.count - 1] = DataRun(deviceOffset: last.deviceOffset, length: last.length + run.length,
                                                       firstDataUnit: last.firstDataUnit)
                    continue
                }
            }
            result.append(run)
        }
        return result
    }

    func file(name: String, path: String, inode: APFSInode, id: UInt64, record: APFSRecord,
              content: FileContent, deleted: Bool) throws -> RecoveredFile {
        let placed: Int
        switch content {
        case .runs(let runs), .encryptedRuns(let runs, _): placed = runs.filter { $0.deviceOffset != nil }.count
        default: placed = 0
        }
        let recordOffset = try checkedAdd(extent.offset, checkedAdd(checkedMultiply(record.nodeAddress, blockSize), Int64(record.valueOffset)))
        return RecoveredFile(name: name, path: path, sizeBytes: try signed(inode.size), modified: inode.modified, isDeleted: deleted,
                             sourceMetadata: SourceMetadata(filesystem: .apfs, volumeOffset: extent.offset, recordOffset: recordOffset,
                                                            allocationStart: id, contiguous: placed <= 1, rawRecord: record.value),
                             content: content)
    }

    // MARK: - Deleted files

    /// Collects the volume's files present in an older checkpoint or a snapshot but absent from the
    /// live tree. Nothing is emitted here: `emitDeletedCandidates` runs once for the container.
    func collectDeletedCandidates(in live: APFSVolumeContext, volume: Int, fsOID: UInt64,
                                  older: [APFSContainerSuperblock], liveNodes: Int) async throws {
        guard spaceman != nil else { return }
        deletedWorkRemaining = deletedWorkOverride ?? (100_000 + 4 * Int64(liveNodes))
        candidateIDs = []
        spending = true
        defer { spending = false; volumeBudgets[volume] = deletedWorkRemaining; candidateIDs = [] }
        do {
            for superblock in older.prefix(Self.maxOlderCheckpoints) {
                try Task.checkCancellation()
                _ = try await attempt { try await self.collectCandidates(fromCheckpoint: superblock, fsOID: fsOID, live: live, volume: volume) }
            }
            try await collectCandidatesFromSnapshots(live, volume: volume)
        } catch is APFSBudgetExhausted {
            // The volume's budget is spent. What was collected still takes part in overlap checks,
            // but with no budget left none of it is emitted.
            deletedWorkRemaining = 0
        }
    }

    func collectCandidates(fromCheckpoint superblock: APFSContainerSuperblock, fsOID: UInt64, live: APFSVolumeContext, volume index: Int) async throws {
        let omapTree = try await objectMapTree(at: superblock.omapAddress)
        // An encrypted volume's older trees are read with the same key, which never changes.
        guard let volume = try await volumeSuperblock(fsOID: fsOID, omapTree: omapTree, xid: superblock.header.xid),
              volume.uuid == live.superblock.uuid, !volume.isEncrypted || activeCipher != nil else { return }
        let context = try await volumeContext(volume, xid: superblock.header.xid)
        // An unchanged root means an identical tree.
        guard context.root != live.root else { return }
        try await collectCandidates(from: context, live: live, volume: index)
    }

    func collectCandidatesFromSnapshots(_ live: APFSVolumeContext, volume index: Int) async throws {
        guard live.superblock.snapMetaTreeAddress > 0 else { return }
        let tree = APFSTree(root: live.superblock.snapMetaTreeAddress, rootReference: .physical(live.superblock.snapMetaTreeAddress),
                            kind: .physical, compare: live.tree.compare)
        let snapshots: [APFSSnapshot]? = try await attempt {
            var result: [APFSSnapshot] = []
            var cursor = try await self.seek(nil, in: tree)
            while let record = try await self.next(&cursor, in: tree), result.count < Self.maxSnapshots {
                let key = try APFSRecordKey(record.key)
                guard key.type == APFS.RecordType.snapMetadata else { continue }
                result.append(try APFSSnapshot(key: key, value: record.value))
            }
            return result
        }
        for snapshot in (snapshots ?? []).sorted(by: { $0.xid > $1.xid }) {
            try Task.checkCancellation()
            _ = try await attempt {
                let volume = try APFSVolumeSuperblock(try await self.object(at: snapshot.superblockAddress))
                guard volume.uuid == live.superblock.uuid, !volume.isEncrypted || self.activeCipher != nil,
                      volume.header.xid <= snapshot.xid else { return }
                // The snapshot's trees resolve through the current object map at the snapshot's transaction.
                let context = try await self.volumeContext(volume, xid: snapshot.xid, omapTree: live.omapTree, converting: live.converting)
                guard context.root != live.root else { return }
                try await self.collectCandidates(from: context, live: live, volume: index)
            }
        }
    }

    func collectCandidates(from old: APFSVolumeContext, live: APFSVolumeContext, volume: Int) async throws {
        let directories = APFSDirectoryIndex()
        var cursor = try await seek(nil, in: old.tree)
        var group: APFSRecordGroup?
        while let record = try await next(&cursor, in: old.tree) {
            let key = try APFSRecordKey(record.key)
            if let current = group, current.id != key.objectID {
                try await considerCandidate(current, old: old, live: live, directories: directories, volume: volume)
                group = nil
            }
            var current = group ?? APFSRecordGroup(id: key.objectID)
            try Self.accumulate(record, key, into: &current, strict: false)
            group = current
        }
        if let current = group { try await considerCandidate(current, old: old, live: live, directories: directories, volume: volume) }
    }

    func considerCandidate(_ group: APFSRecordGroup, old: APFSVolumeContext, live: APFSVolumeContext,
                           directories: APFSDirectoryIndex, volume: Int) async throws {
        guard let inode = group.inode, let record = group.record, inode.isRegularFile, group.id >= APFS.minUserInodeID,
              !inode.isCompressed, let name = inode.name, !candidateIDs.contains(group.id),
              deletedCandidates.count < Self.maxDeletedCandidates else { return }
        // An inode still in the live tree isn't deleted, whatever changed about it.
        guard try await !inodeExists(group.id, in: live.tree) else { return }
        guard let extents = try await extents(for: inode, group: group, in: old) else { return }
        guard let directory = try await path(of: inode.parentID, in: old, index: directories, fallback: live) else { return }
        candidateIDs.insert(group.id)
        deletedCandidates.append(APFSDeletedCandidate(id: group.id, volume: volume, inode: inode, record: record, name: name,
                                                      path: directory + "/" + name, extents: extents, xid: old.xid,
                                                      converting: old.converting || live.converting, keyID: activeKeyID))
    }

    /// Emits every candidate, from every volume, whose blocks are all provably still the
    /// candidate's (see `blocksAreFree`) and which no other candidate claims.
    func emitDeletedCandidates() async throws {
        struct Claim { let start: Int64; let end: Int64; let owner: Int }
        var contents: [FileContent?] = [], claims: [Claim] = []
        for (owner, candidate) in deletedCandidates.enumerated() {
            let content = try await attempt {
                try self.content(of: candidate.inode, extents: candidate.extents, deleted: true, converting: candidate.converting,
                                 keyID: candidate.keyID)
            } ?? nil
            contents.append(content)
            guard content != nil else { continue }
            let size = try signed(candidate.inode.size)
            for extent in candidate.extents where extent.logicalAddress < UInt64(size) {
                // `content` has validated each extent: block-aligned, non-zero, inside the container.
                let start = try signed(extent.physicalBlock)
                let needed = (try checkedAdd(min(try signed(extent.length), size - Int64(extent.logicalAddress)), blockSize - 1)) / blockSize
                claims.append(Claim(start: start, end: try checkedAdd(start, needed), owner: owner))
            }
        }
        // Two candidates claiming the same blocks can't both be right; neither is emitted. Claims
        // come from every volume, since volumes share the container's blocks.
        var overlapping: Set<Int> = [], furthest: Claim?
        for claim in claims.sorted(by: { $0.start < $1.start }) {
            if let reach = furthest, claim.start < reach.end, claim.owner != reach.owner {
                overlapping.insert(claim.owner); overlapping.insert(reach.owner)
            }
            if furthest.map({ claim.end > $0.end }) ?? true { furthest = claim }
        }
        spending = true
        defer { spending = false }
        for (owner, candidate) in deletedCandidates.enumerated() where !overlapping.contains(owner) {
            guard let content = contents[owner], let budget = volumeBudgets[candidate.volume], budget > 0 else { continue }
            let ranges = claims.filter { $0.owner == owner }.map { ($0.start, $0.end) }
            deletedWorkRemaining = budget
            let free: Bool
            do { free = try await blocksAreFree(ranges, since: candidate.xid) } catch is APFSBudgetExhausted {
                deletedWorkRemaining = 0; free = false
            }
            volumeBudgets[candidate.volume] = deletedWorkRemaining
            guard free else { continue }
            try await emit(.found(file(name: candidate.name, path: candidate.path, inode: candidate.inode, id: candidate.id,
                                       record: candidate.record, content: content, deleted: true)))
        }
    }

    // MARK: - Space manager

    /// Whether every block in `ranges` is provably still the candidate's at the current checkpoint.
    ///
    /// A block qualifies only while its free is still pending: it is in the main free queue with a
    /// freeing transaction after the candidate's checkpoint (`xid`) and no later than the current
    /// one, and its bitmap bit is still set. APFS keeps a freed block allocated until the free is
    /// processed, so a set bit plus a queue entry means the block hasn't been handed out since the
    /// free. A clear bit proves nothing: the block may have been reallocated (to a metadata node or
    /// another file) and freed again since the candidate's checkpoint, so it is rejected. This
    /// deliberately under-recovers: a file whose frees have already been processed isn't emitted.
    func blocksAreFree(_ ranges: [(Int64, Int64)], since xid: UInt64) async throws -> Bool {
        guard let manager = spaceman else { return false }
        for (start, end) in ranges {
            var block = start
            while block < end {
                try Task.checkCancellation()
                let chunk = block / manager.blocksPerChunk
                let chunkEnd = min(end, (chunk + 1) * manager.blocksPerChunk)
                try spend((chunkEnd - block) / 64 + 1)
                guard let info = try await chunkInfo(chunk), info.address == chunk * manager.blocksPerChunk,
                      info.blockCount > 0, info.blockCount <= manager.blocksPerChunk, info.freeCount >= 0,
                      info.freeCount <= info.blockCount, chunkEnd - info.address <= info.blockCount else { return false }
                // A wholly free chunk has every bit clear.
                guard info.freeCount < info.blockCount else { return false }
                var bitmap: Data?
                if info.freeCount > 0 {
                    guard info.bitmapAddress > 0, let page = try await attempt({ try await self.bitmapBlock(info.bitmapAddress) }) else { return false }
                    bitmap = page
                }
                while block < chunkEnd {
                    let bit = Int(block - info.address)
                    // No bitmap is needed for a chunk with no free blocks: every bit is set.
                    let allocated = bitmap.map { ($0[bit / 8] >> (bit % 8)) & 1 == 1 } ?? true
                    guard allocated, isPendingFree(block, since: xid) else { return false }
                    block += 1
                }
            }
        }
        return true
    }

    func chunkInfo(_ chunk: Int64) async throws -> APFSChunkInfo? {
        guard let manager = spaceman else { return nil }
        let cibIndex = Int(chunk / manager.chunksPerCIB)
        guard cibIndex < cibAddresses.count else { return nil }
        if chunkInfoCache[cibIndex] == nil {
            let infos: [APFSChunkInfo]? = try await attempt {
                let block = try await self.object(at: self.cibAddresses[cibIndex])
                guard try APFSObjectHeader(block).type == APFS.ObjectType.spacemanCIB else { throw ScanError.malformed("APFS chunk-info block has the wrong type.") }
                return try APFSChunkInfo.chunkInfos(in: block)
            }
            guard let infos else { return nil }
            if chunkInfoCache.count >= Self.chunkInfoCacheLimit { chunkInfoCache.removeAll(keepingCapacity: true) }
            chunkInfoCache[cibIndex] = infos
        }
        let within = Int(chunk % manager.chunksPerCIB)
        guard let infos = chunkInfoCache[cibIndex], within < infos.count else { return nil }
        return infos[within]
    }

    /// A chunk's allocation bitmap; raw bits with no object header.
    func bitmapBlock(_ address: Int64) async throws -> Data {
        if let cached = bitmapCache[address] { return cached }
        let page = try await readBlocks(address)
        if bitmapCache.count >= Self.bitmapCacheLimit { bitmapCache.removeAll(keepingCapacity: true) }
        bitmapCache[address] = page
        return page
    }

    /// Whether the main free queue holds `block`, freed after the candidate's checkpoint `xid` (a
    /// block freed in or before that transaction can't have been the candidate's) and no later
    /// than the current checkpoint (a later transaction isn't part of the state being read).
    func isPendingFree(_ block: Int64, since xid: UInt64) -> Bool {
        var low = 0, high = freeQueue.count
        while low < high {
            let middle = (low + high) / 2
            if freeQueue[middle].start <= block { low = middle + 1 } else { high = middle }
        }
        guard low > 0 else { return false }
        let range = freeQueue[low - 1]
        return block < range.end && range.xid > xid && range.xid <= currentXID
    }
}

/// A volume's trees resolved at one transaction (the live checkpoint, an older one, or a snapshot).
struct APFSVolumeContext: Sendable {
    let superblock: APFSVolumeSuperblock
    let xid: UInt64
    let omapTree: Int64
    let root: Int64
    /// The object map has `OMAP_ENCRYPTING` or `OMAP_DECRYPTING` set: blocks may be ciphertext.
    let converting: Bool
    let tree: APFSTree
}

struct APFSDirectoryEntry: Sendable { let parent: UInt64; let name: String }

/// Directory names and resolved paths for one tree. Owned by the actor; never shared.
final class APFSDirectoryIndex {
    var entries: [UInt64: APFSDirectoryEntry] = [:]
    var paths: [UInt64: String] = [:]
    func reset() { entries = [:]; paths = [:] }
}

/// The records of one object identifier, gathered while walking a tree in key order.
struct APFSRecordGroup {
    let id: UInt64
    var inode: APFSInode?
    var record: APFSRecord?
    var extents: [APFSFileExtent] = []
    var extentOverflow = false
    init(id: UInt64) { self.id = id }
}

struct APFSDeletedCandidate: Sendable {
    let id: UInt64
    /// Index of the volume in `nx_fs_oid`, for its budget.
    let volume: Int
    let inode: APFSInode
    let record: APFSRecord
    let name: String
    let path: String
    let extents: [APFSFileExtent]
    let xid: UInt64
    let converting: Bool
    /// The volume's key identifier when it is an unlocked encrypted volume.
    let keyID: String?
}

struct APFSNodeCacheKey: Hashable, Sendable { let address: Int64; let decrypted: Bool }

struct APFSFreeRange: Sendable { let start: Int64; let end: Int64; let xid: UInt64 }
