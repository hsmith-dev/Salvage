import Foundation

extension Data {
    func number(_ offset: Int, _ width: Int) throws -> UInt64 {
        guard offset >= 0, width > 0, width <= 8, offset <= count, width <= count - offset else {
            throw ScanError.malformed("Truncated structure.")
        }
        return (0..<width).reduce(0) { $0 | UInt64(self[startIndex + offset + $1]) << ($1 * 8) }
    }
    /// Big-endian counterpart of `number`, for HFS+ headers.
    func bigEndian(_ offset: Int, _ width: Int) throws -> UInt64 {
        guard offset >= 0, width > 0, width <= 8, offset <= count, width <= count - offset else {
            throw ScanError.malformed("Truncated structure.")
        }
        return (0..<width).reduce(0) { $0 << 8 | UInt64(self[startIndex + offset + $1]) }
    }
}

func checkedAdd(_ a: Int64, _ b: Int64) throws -> Int64 {
    let (value, overflow) = a.addingReportingOverflow(b)
    guard !overflow, value >= 0 else { throw ScanError.malformed("Offset overflow.") }
    return value
}
func checkedMultiply(_ a: Int64, _ b: Int64) throws -> Int64 {
    let (value, overflow) = a.multipliedReportingOverflow(by: b)
    guard !overflow, value >= 0 else { throw ScanError.malformed("Size overflow.") }
    return value
}
func signed(_ value: UInt64) throws -> Int64 {
    guard value <= UInt64(Int64.max) else { throw ScanError.malformed("Size overflow.") }
    return Int64(value)
}

struct VolumeExtent: Sendable {
    let offset: Int64
    let length: Int64
    var format: VolumeFormat = .fat
    /// A filesystem found in unallocated space (FR-9). It is read in place like any other extent;
    /// nothing is ever written back to the partition table.
    var isLost: Bool = false
    /// Plain-language name of the signature that revealed a lost volume (e.g. "exFAT"); nil means
    /// `format.displayName`.
    var formatName: String? = nil
}

struct VolumeDiscovery {
    let reader: any BlockReader
    /// Bounds for the unallocated-space search: header probes and header bytes read per device.
    /// Probing is sparse (one or two 512-byte reads per probe), so the byte cap mostly guards the
    /// header-length reads that follow a hit.
    var maxProbes = 16384
    var maxProbeBytes: Int64 = 64 << 20
    /// Candidate offsets: every MiB; 4 KiB steps across the first 64 MiB of the device and the
    /// first MiB after each known or found extent; and the classic first-partition sectors (GPT's
    /// first usable LBA 34, CHS's sector 63) that none of those alignments reach.
    static let fineStride: Int64 = 4096, coarseStride: Int64 = 1 << 20, fineRegion: Int64 = 64 << 20
    static let classicStarts: [Int64] = [34 * 512, 63 * 512]

    func read(_ offset: Int64, _ count: Int) async throws -> Data {
        try Task.checkCancellation()
        guard offset >= 0, count >= 0, offset <= reader.sizeBytes,
              Int64(count) <= reader.sizeBytes - offset else { throw ScanError.malformed("Read outside device.") }
        var data = Data()
        while data.count < count {
            try Task.checkCancellation()
            let chunkCount = min(1024 * 1024, count - data.count)
            let chunk = try await reader.read(at: checkedAdd(offset, Int64(data.count)), count: chunkCount)
            guard chunk.count == chunkCount else { throw ScanError.malformed("Truncated device.") }
            data.append(chunk)
        }
        return data
    }
    func discover() async throws -> [VolumeExtent] {
        guard reader.logicalBlockSize == 512 else {
            throw ScanError.malformed("Only devices with 512-byte logical sectors are supported in this version.")
        }
        let boot = try await read(0, 512)
        if let format = try await format(boot: boot, at: 0, length: reader.sizeBytes) {
            guard format.isScannable else { throw ScanError.unsupportedFilesystem }
            return [VolumeExtent(offset: 0, length: reader.sizeBytes, format: format)]
        }
        // Every table entry is a known extent, supported or not: the unallocated-space search never
        // probes inside one, so a mapped partition always wins over a stale header within it.
        var known: [VolumeExtent] = []
        if try boot.number(510, 2) == 0xaa55 { known = try await partitions(boot) }
        var supported: [VolumeExtent] = []
        for extent in known {
            if let format = try await format(at: extent.offset, length: extent.length), format.isScannable {
                supported.append(VolumeExtent(offset: extent.offset, length: extent.length, format: format))
            }
        }
        let lost = try await lostVolumes(excluding: known)
        let result = (supported + lost).sorted { $0.offset < $1.offset }
        if result.isEmpty {
            // A table whose volumes are all recognized but unsupported keeps the honest "not supported"
            // answer. With no table and no signature anywhere, one raw extent lets the sweep and the
            // carver still run, so completion reports carved files or none, never a silent skip.
            guard known.isEmpty else { throw ScanError.unsupportedFilesystem }
            return [VolumeExtent(offset: 0, length: reader.sizeBytes, format: .raw)]
        }
        return result
    }

    /// MBR (or protective-MBR + GPT) entries as bare extents, sorted and non-overlapping.
    func partitions(_ boot: Data) async throws -> [VolumeExtent] {
        var extents: [VolumeExtent] = []
        var protective = false
        for n in 0..<4 {
            let p = 446 + n * 16
            let type = try boot.number(p + 4, 1)
            if type == 0 { continue }
            if type == 0xee { protective = true; continue }
            guard ![0x05, 0x0f, 0x85].contains(type) else { throw ScanError.malformed("Extended partitions aren't supported.") }
            let start = try signed(boot.number(p + 8, 4))
            let sectors = try signed(boot.number(p + 12, 4))
            extents.append(try extent(start: start, sectors: sectors))
        }
        if protective {
            guard extents.isEmpty else { throw ScanError.malformed("Hybrid partition maps aren't supported.") }
            extents = try await gpt()
        }
        let sorted = extents.sorted { $0.offset < $1.offset }
        for n in sorted.indices.dropFirst() {
            guard try checkedAdd(sorted[n-1].offset, sorted[n-1].length) <= sorted[n].offset else {
                throw ScanError.malformed("Overlapping partitions.")
            }
        }
        return sorted
    }

    // MARK: Unallocated space (FR-9)

    /// Unallocated byte ranges: the device minus `known` (sorted, non-overlapping).
    static func gaps(in sizeBytes: Int64, excluding known: [VolumeExtent]) -> [Range<Int64>] {
        var gaps: [Range<Int64>] = [], cursor: Int64 = 0
        for extent in known {
            if extent.offset > cursor { gaps.append(cursor..<extent.offset) }
            cursor = max(cursor, extent.offset + extent.length)
        }
        if cursor < sizeBytes { gaps.append(cursor..<sizeBytes) }
        return gaps
    }

    struct ProbeState {
        var found: [VolumeExtent] = []
        var probed: Set<Int64> = []
        var probes = 0
        var bytes: Int64 = 0
    }

    /// Filesystem headers in unallocated space. Two bounded passes in device order, the likelier
    /// starts first: every gap's own start, the classic first-partition sectors, 4 KiB steps for the
    /// first MiB after each known or found extent, and every MiB; then 4 KiB steps across the first
    /// 64 MiB. A hit's span (from its own header geometry) is skipped, and a candidate that would
    /// run into a known extent or an earlier hit is dropped: known extents and earlier hits win.
    func lostVolumes(excluding known: [VolumeExtent]) async throws -> [VolumeExtent] {
        let gaps = Self.gaps(in: reader.sizeBytes, excluding: known)
        // `discover()` has already checked offset 0 against the whole device.
        var state = ProbeState(probed: [0])
        for pass in 0..<2 {
            // The first pass keeps a quarter of the budget for the fine pass.
            let cap = pass == 0 ? maxProbes - maxProbes / 4 : maxProbes
            for gap in gaps where pass == 0 || gap.lowerBound < Self.fineRegion {
                var offset = gap.lowerBound, fineUntil = gap.lowerBound + Self.coarseStride
                while offset < gap.upperBound, state.probes < cap, state.bytes < maxProbeBytes {
                    try Task.checkCancellation()
                    if let hit = state.found.first(where: { $0.offset <= offset && offset < $0.offset + $0.length }) {
                        // Probe finely right after a found volume, as after a known extent.
                        offset = hit.offset + hit.length; fineUntil = offset + Self.coarseStride; continue
                    }
                    if pass == 1, offset >= Self.fineRegion { break }
                    if !state.probed.contains(offset) {
                        if let extent = try await probe(at: offset, gapEnd: gap.upperBound, state: &state) {
                            state.found.append(extent); continue
                        }
                    }
                    guard let next = Self.nextCandidate(after: offset, fineUntil: fineUntil, pass: pass) else { break }
                    offset = next
                }
            }
        }
        return state.found
    }

    /// The next candidate offset after `offset`, or nil when the pass has none left in this gap.
    static func nextCandidate(after offset: Int64, fineUntil: Int64, pass: Int) -> Int64? {
        func aligned(_ stride: Int64) -> Int64 { (offset / stride + 1) * stride }
        if pass == 1 { return offset < fineRegion ? aligned(fineStride) : nil }
        var next = aligned(coarseStride)
        if offset + 1 < fineUntil { next = min(next, aligned(fineStride)) }
        if let classic = classicStarts.first(where: { $0 > offset }) { next = min(next, classic) }
        return next
    }

    /// One header probe. A hit returns a lost extent whose length comes from the header and fits the
    /// gap (clamped to the device end); a header with implausible geometry, or one that overlaps a
    /// known extent or an earlier hit, is dropped.
    func probe(at offset: Int64, gapEnd: Int64, state: inout ProbeState) async throws -> VolumeExtent? {
        state.probes += 1; state.probed.insert(offset)
        let remaining = gapEnd - offset
        guard remaining >= 512 else { return nil }
        let boot = try await read(offset, 512)
        state.bytes += 1024
        guard let format = try await format(boot: boot, at: offset, length: remaining) else { return nil }
        state.bytes += 2048
        let length: Int64?
        do { length = try await volumeLength(format: format, boot: boot, at: offset) }
        catch ScanError.malformed { return nil } catch ScanError.unsupportedFilesystem { return nil }
        guard let length, length > 0 else { return nil }
        // A header running past the device end is clamped (a short image or an overwritten tail);
        // one running into a known extent is dropped, since the mapped partition wins.
        let end = min(offset + length, reader.sizeBytes)
        guard end > offset, end <= gapEnd else { return nil }
        guard !state.found.contains(where: { $0.offset < end && offset < $0.offset + $0.length }) else { return nil }
        let name = format == .fat ? (String(decoding: boot[3..<11], as: UTF8.self) == "EXFAT   " ? "exFAT" : "FAT32") : format.displayName
        return VolumeExtent(offset: offset, length: end - offset, format: format, isLost: true, formatName: name)
    }

    /// A volume's byte length from its own header only: FAT BPB total sectors, NTFS total sectors
    /// (plus the backup boot sector), ext blocks count × block size, APFS container block count ×
    /// block size, HFS+ total blocks × block size. Nil when the header carries no size (a bare
    /// APFS volume superblock, a raw region). Not clamped; the caller fits it to the device.
    func volumeLength(format: VolumeFormat, at offset: Int64) async throws -> Int64? {
        try await volumeLength(format: format, boot: read(offset, 512), at: offset)
    }
    func volumeLength(format: VolumeFormat, boot: Data, at offset: Int64) async throws -> Int64? {
        switch format {
        case .fat:
            if String(decoding: boot[3..<11], as: UTF8.self) == "EXFAT   " {
                let shift = try boot.number(108, 1)
                guard (9...12).contains(shift) else { throw ScanError.malformed("Unsupported exFAT sector size.") }
                return try checkedMultiply(signed(boot.number(72, 8)), Int64(1) << shift)
            }
            let sector = try signed(boot.number(11, 2))
            var total = try signed(boot.number(32, 4))
            if total == 0 { total = try signed(boot.number(19, 2)) }
            return try checkedMultiply(total, sector)
        case .ntfs:
            let sector = try signed(boot.number(11, 2))
            guard (512...4096).contains(sector), sector & (sector - 1) == 0 else { throw ScanError.malformed("Unsupported NTFS sector size.") }
            return try checkedMultiply(checkedAdd(signed(boot.number(0x28, 8)), 1), sector)
        case .apfs:
            guard String(decoding: boot[32..<36], as: UTF8.self) == "NXSB" else { return nil }
            let blockSize = try signed(boot.number(36, 4))
            guard (4096...65536).contains(blockSize), blockSize & (blockSize - 1) == 0 else { throw ScanError.malformed("Unsupported APFS block size.") }
            return try checkedMultiply(signed(boot.number(40, 8)), blockSize)
        case .ext:
            let sb = try await read(checkedAdd(offset, 1024), 1024)
            let logBlock = try sb.number(24, 4)
            guard logBlock <= 6 else { throw ScanError.malformed("Invalid ext block size.") }
            let wide = try sb.number(76, 4) >= 1 && sb.number(96, 4) & 0x80 != 0
            let blocks = try sb.number(4, 4) | (wide ? sb.number(336, 4) << 32 : 0)
            return try checkedMultiply(signed(blocks), Int64(1024) << logBlock)
        case .hfsPlus:
            let header = try await read(checkedAdd(offset, 1024), 512)
            return try checkedMultiply(signed(header.bigEndian(44, 4)), signed(header.bigEndian(40, 4)))
        case .raw:
            return nil
        }
    }

    /// Identifies a volume by its on-disk signature; the format's own parser validates the rest.
    func format(at offset: Int64, length: Int64) async throws -> VolumeFormat? {
        try await format(boot: read(offset, 512), at: offset, length: length)
    }
    func format(boot: Data, at offset: Int64, length: Int64) async throws -> VolumeFormat? {
        if isFAT(boot) { return .fat }
        if String(decoding: boot[3..<11], as: UTF8.self) == "NTFS    " { return .ntfs }
        // APFS: nx_superblock (container) or apfs_superblock (bare unlocked volume), magic at 32.
        let apfsMagic = String(decoding: boot[32..<36], as: UTF8.self)
        if apfsMagic == "NXSB" || apfsMagic == "APSB" { return .apfs }
        // ext superblock and the HFS+ volume header both sit 1024 bytes into the volume.
        guard length >= 2048 else { return nil }
        let block = try await read(checkedAdd(offset, 1024), 512)
        if try block.number(56, 2) == 0xef53 { return .ext }
        // HFS+ signature is big-endian "H+" (0x482B) or "HX" (HFSX, 0x4858).
        if block[0] == 0x48, block[1] == 0x2B || block[1] == 0x58 { return .hfsPlus }
        return nil
    }
    func isFAT(_ data: Data) -> Bool {
        guard data.count >= 90 else { return false }
        if String(decoding: data[3..<11], as: UTF8.self) == "EXFAT   " { return true }
        // The FAT label is informational. Identify a FAT32 BPB from its structure; geometry
        // validation derives the FAT type from the data-cluster count.
        return (try? data.number(11, 2)).map { [512, 1024, 2048, 4096].contains($0) } == true &&
            (try? data.number(13, 1)) != 0 && (try? data.number(14, 2)) != 0 &&
            (try? data.number(17, 2)) == 0 && (try? data.number(22, 2)) == 0 &&
            (try? data.number(36, 4)) != 0
    }
    func extent(start: Int64, sectors: Int64) throws -> VolumeExtent {
        let offset = try checkedMultiply(start, 512)
        let length = try checkedMultiply(sectors, 512)
        guard start > 0, sectors > 0, offset <= reader.sizeBytes, length <= reader.sizeBytes - offset else {
            throw ScanError.malformed("Partition outside device.")
        }
        return VolumeExtent(offset: offset, length: length)
    }
    func gpt() async throws -> [VolumeExtent] {
        let header = try await read(512, 512)
        guard String(decoding: header[0..<8], as: UTF8.self) == "EFI PART",
              try header.number(12, 4) >= 92, try header.number(12, 4) <= 512,
              try header.number(24, 8) == 1 else { throw ScanError.malformed("Invalid GPT header.") }
        let headerSize = Int(try header.number(12, 4))
        var checksumHeader = header.subdata(in: 0..<headerSize)
        checksumHeader.replaceSubrange(16..<20, with: [0, 0, 0, 0])
        guard UInt64(crc32(checksumHeader)) == (try header.number(16, 4)),
              try header.number(8, 4) == 0x10000, try header.number(20, 4) == 0,
              try header.number(32, 8) == UInt64(reader.sizeBytes / 512 - 1) else {
            throw ScanError.malformed("Invalid GPT header checksum or backup location.")
        }
        let first = try signed(header.number(40, 8)), last = try signed(header.number(48, 8))
        let tableLBA = try signed(header.number(72, 8))
        let count = try signed(header.number(80, 4)), stride = try signed(header.number(84, 4))
        guard first <= last, last < reader.sizeBytes / 512, count > 0, count <= 16384,
              stride >= 128, stride <= 4096, stride % 8 == 0, tableLBA >= 2 else {
            throw ScanError.malformed("Unsupported GPT geometry.")
        }
        let tableOffset = try checkedMultiply(tableLBA, 512)
        let tableSize = try checkedMultiply(count, stride)
        guard try checkedAdd(tableOffset, tableSize) <= checkedMultiply(first, 512) else {
            throw ScanError.malformed("GPT table overlaps usable space.")
        }
        let backupTableSectors = (tableSize + 511) / 512
        guard last < reader.sizeBytes / 512 - 1 - backupTableSectors else {
            throw ScanError.malformed("GPT usable space overlaps backup metadata.")
        }
        guard tableSize <= 64 * 1024 * 1024 else { throw ScanError.malformed("GPT table is too large.") }
        let table = try await read(tableOffset, Int(tableSize))
        guard UInt64(crc32(table)) == (try header.number(88, 4)) else { throw ScanError.malformed("Invalid GPT partition-table checksum.") }
        var result: [VolumeExtent] = []
        for n in 0..<count {
            let entry = table.subdata(in: Int(n * stride)..<Int((n + 1) * stride))
            if entry[0..<16].allSatisfy({ $0 == 0 }) { continue }
            let start = try signed(entry.number(32, 8)), end = try signed(entry.number(40, 8))
            guard start >= first, end <= last, start <= end else { throw ScanError.malformed("Invalid GPT partition bounds.") }
            result.append(try extent(start: start, sectors: checkedAdd(end - start, 1)))
        }
        return result
    }
}

func crc32(_ data: Data) -> UInt32 {
    var crc: UInt32 = 0xffffffff
    for byte in data {
        crc ^= UInt32(byte)
        for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xedb88320 : 0) }
    }
    return ~crc
}
