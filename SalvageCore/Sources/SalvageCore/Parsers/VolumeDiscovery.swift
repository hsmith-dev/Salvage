import Foundation

extension Data {
    func number(_ offset: Int, _ width: Int) throws -> UInt64 {
        guard offset >= 0, width > 0, width <= 8, offset <= count, width <= count - offset else {
            throw ScanError.malformed("Truncated structure.")
        }
        return (0..<width).reduce(0) { $0 | UInt64(self[startIndex + offset + $1]) << ($1 * 8) }
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

struct VolumeExtent: Sendable { let offset: Int64; let length: Int64 }

struct VolumeDiscovery {
    let reader: any BlockReader
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
        if isSupported(boot) { return [VolumeExtent(offset: 0, length: reader.sizeBytes)] }
        guard try boot.number(510, 2) == 0xaa55 else { throw ScanError.unsupportedFilesystem }
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
        var supported: [VolumeExtent] = []
        for extent in sorted {
            let boot = try await read(extent.offset, 512)
            if isSupported(boot) { supported.append(extent) }
        }
        guard !supported.isEmpty else { throw ScanError.unsupportedFilesystem }
        return supported
    }
    func isSupported(_ data: Data) -> Bool {
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
