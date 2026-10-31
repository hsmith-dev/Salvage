import Foundation

/// Geometry from a validated NTFS boot sector. Pure, so every encoding can be checked without an image.
struct NTFSGeometry: Equatable {
    let bytesPerSector: Int64
    let clusterBytes: Int64
    let clusterCount: Int64
    let mftCluster: Int64
    let recordBytes: Int64

    static let maxClusterBytes: Int64 = 2 * 1024 * 1024

    init(boot b: Data, volumeLength: Int64) throws {
        guard b.count >= 512, try b.number(510, 2) == 0xaa55 else { throw ScanError.malformed("Missing NTFS boot signature.") }
        guard String(decoding: b.subdata(in: b.startIndex + 3..<b.startIndex + 11), as: UTF8.self) == "NTFS    " else {
            throw ScanError.malformed("Missing NTFS OEM ID.")
        }
        let bps = try signed(b.number(11, 2))
        guard (512...4096).contains(bps), bps & (bps - 1) == 0 else {
            throw ScanError.malformed("Unsupported NTFS bytes per sector.")
        }
        // Values up to 0x80 are a direct sector count; larger values are a negative power-of-two
        // exponent, used for clusters above 64K.
        let encoded = try b.number(13, 1)
        let sectorsPerCluster: Int64
        if encoded >= 1, encoded <= 0x80 {
            sectorsPerCluster = Int64(encoded)
            guard sectorsPerCluster & (sectorsPerCluster - 1) == 0 else {
                throw ScanError.malformed("Invalid NTFS sectors per cluster.")
            }
        } else if encoded > 0x80 {
            let shift = 256 - Int64(encoded)
            guard shift <= 12 else { throw ScanError.malformed("Invalid NTFS sectors per cluster.") }
            sectorsPerCluster = 1 << shift
        } else {
            throw ScanError.malformed("Invalid NTFS sectors per cluster.")
        }
        let clusterBytes = try checkedMultiply(bps, sectorsPerCluster)
        guard clusterBytes <= Self.maxClusterBytes else { throw ScanError.malformed("NTFS cluster size is too large.") }

        let totalSectors = try signed(b.number(0x28, 8))
        guard totalSectors > 0, try checkedMultiply(totalSectors, bps) <= volumeLength else {
            throw ScanError.malformed("NTFS volume size exceeds partition.")
        }
        let clusterCount = totalSectors / sectorsPerCluster
        guard clusterCount > 0 else { throw ScanError.malformed("NTFS volume has no clusters.") }

        // Clusters per MFT record: positive is a cluster count, negative is a byte-size exponent.
        let perRecord = Int64(Int8(bitPattern: UInt8(try b.number(0x40, 1))))
        let recordBytes: Int64
        if perRecord > 0 {
            recordBytes = try checkedMultiply(perRecord, clusterBytes)
        } else if perRecord < 0, -perRecord <= 16 {
            recordBytes = 1 << -perRecord
        } else {
            throw ScanError.malformed("Invalid NTFS MFT record size.")
        }
        guard (512...65536).contains(recordBytes), recordBytes & (recordBytes - 1) == 0 else {
            throw ScanError.malformed("Unsupported NTFS MFT record size.")
        }

        let mftCluster = try signed(b.number(0x30, 8))
        guard mftCluster < clusterCount,
              try checkedAdd(checkedMultiply(mftCluster, clusterBytes), recordBytes) <= checkedMultiply(clusterCount, clusterBytes) else {
            throw ScanError.malformed("NTFS $MFT lies outside the volume.")
        }
        self.bytesPerSector = bps; self.clusterBytes = clusterBytes; self.clusterCount = clusterCount
        self.mftCluster = mftCluster; self.recordBytes = recordBytes
    }
}

/// Applies the update-sequence fixup in place. Returns false when the header is invalid or any
/// 512-byte stride's tail doesn't match the update sequence number. Used for MFT records and
/// index buffers alike.
func applyNTFSFixup(_ record: inout Data) -> Bool {
    guard record.startIndex == 0, record.count >= 512, record.count % 512 == 0,
          let usaOffset = try? Int(record.number(4, 2)), let usaCount = try? Int(record.number(6, 2)),
          usaOffset >= 8, usaOffset % 2 == 0, usaCount == record.count / 512 + 1,
          usaOffset + usaCount * 2 <= 510 else { return false }
    let usn0 = record[usaOffset], usn1 = record[usaOffset + 1]
    for stride in 1..<usaCount {
        let tail = stride * 512 - 2
        guard record[tail] == usn0, record[tail + 1] == usn1 else { return false }
        record[tail] = record[usaOffset + stride * 2]
        record[tail + 1] = record[usaOffset + stride * 2 + 1]
    }
    return true
}

struct NTFSRun: Equatable {
    /// Nil for a sparse run.
    let lcn: Int64?
    let length: Int64
}

struct NTFSDataStream {
    let size: Int64
    /// Bytes NTFS has actually written; the rest of `size` reads as zeros.
    let initialized: Int64
    let runs: [NTFSRun]
    let residentValue: Data?
    /// The attribute header's flags (compression mask 0x00FF, encrypted 0x4000, sparse 0x8000).
    var attributeFlags: UInt16 = 0

    /// Compressed or encrypted bytes on disk aren't the file's bytes, so they can't be mapped as-is.
    var isCompressedOrEncrypted: Bool { attributeFlags & 0x40ff != 0 }
}

struct NTFSFileName {
    let parent: UInt64
    let parentSequence: UInt16
    let namespace: UInt8
    let name: String
}

struct NTFSRecord {
    static let maxAttributes = 512
    static let maxRuns = 16384

    let inUse: Bool
    let isDirectory: Bool
    let sequence: UInt16
    let baseReference: UInt64
    let modified: Date?
    let names: [NTFSFileName]
    /// `$FILE_NAME` attributes present, including ones whose name couldn't be decoded faithfully.
    let fileNameAttributes: Int
    /// The unnamed `$DATA` stream, present only when it is complete in this record.
    let data: NTFSDataStream?
    /// The unnamed `$DATA` stream continues in extension records listed by `$ATTRIBUTE_LIST`.
    let dataInExtensionRecords: Bool
    let hasAttributeList: Bool

    /// Win32 or Win32+DOS names win over POSIX, which wins over a DOS-only short name.
    var bestName: NTFSFileName? {
        for preferred: Set<UInt8> in [[1, 3], [0], [2]] {
            if let match = names.first(where: { preferred.contains($0.namespace) }) { return match }
        }
        return nil
    }

    static func flags(of raw: Data) -> UInt64 { (try? raw.number(0x16, 2)) ?? 0 }

    /// Parses a fixed-up FILE record. Throws `malformed` on any structural inconsistency; callers
    /// decide whether that is fatal (in-use record) or skippable (deleted record).
    init(_ r: Data, geometry g: NTFSGeometry) throws {
        let flags = try r.number(0x16, 2)
        inUse = flags & 0x01 != 0
        sequence = UInt16(try r.number(0x10, 2))
        baseReference = try r.number(0x20, 8) & 0x0000_ffff_ffff_ffff
        let used = Int(try r.number(0x18, 4))
        var offset = Int(try r.number(0x14, 2))
        guard used <= r.count, offset >= 0x18, offset % 8 == 0, offset < used else {
            throw ScanError.malformed("Invalid NTFS record layout.")
        }
        var modified: Date?, names: [NTFSFileName] = [], data: NTFSDataStream?
        var dataInExtensions = false, attributeList = false, indexRoot = false, attributes = 0, fileNames = 0
        while true {
            guard offset + 4 <= used else { throw ScanError.malformed("NTFS attribute list is unterminated.") }
            let type = try r.number(offset, 4)
            if type == 0xffff_ffff { break }
            attributes += 1
            guard attributes <= Self.maxAttributes, offset + 16 <= used else {
                throw ScanError.malformed("Too many or truncated NTFS attributes.")
            }
            let length = Int(try r.number(offset + 4, 4))
            guard length >= 0x18, length % 8 == 0, length <= used - offset else {
                throw ScanError.malformed("Invalid NTFS attribute length.")
            }
            let a = r.subdata(in: offset..<offset + length)
            let nonResident = a[8] != 0
            let nameLength = Int(a[9]), nameOffset = Int(try a.number(10, 2))
            guard nameLength == 0 || nameOffset + nameLength * 2 <= length else {
                throw ScanError.malformed("Invalid NTFS attribute name.")
            }
            switch type {
            case 0x10:
                let value = try Self.residentValue(a, nonResident)
                guard value.count >= 0x10 else { throw ScanError.malformed("Truncated $STANDARD_INFORMATION.") }
                modified = Self.date(fromFiletime: try value.number(8, 8))
            case 0x20:
                attributeList = true
            case 0x30:
                fileNames += 1
                if let name = try Self.fileName(Self.residentValue(a, nonResident)) { names.append(name) }
            case 0x80 where nameLength == 0:
                let attributeFlags = UInt16(try a.number(0x0c, 2))
                if nonResident {
                    let startVCN = try a.number(0x10, 8)
                    guard startVCN == 0 else { dataInExtensions = true; break }
                    guard data == nil else { throw ScanError.malformed("Duplicate NTFS $DATA.") }
                    if var stream = try Self.nonResidentStream(a, geometry: g) {
                        stream.attributeFlags = attributeFlags; data = stream
                    } else { dataInExtensions = true }
                } else {
                    guard data == nil else { throw ScanError.malformed("Duplicate NTFS $DATA.") }
                    let value = try Self.residentValue(a, false)
                    data = NTFSDataStream(size: Int64(value.count), initialized: Int64(value.count), runs: [], residentValue: value,
                                          attributeFlags: attributeFlags)
                }
            case 0x90:
                indexRoot = true
            default:
                break
            }
            offset += length
        }
        if dataInExtensions { data = nil }
        guard !dataInExtensions || attributeList else {
            throw ScanError.malformed("NTFS $DATA is incomplete without an attribute list.")
        }
        isDirectory = flags & 0x02 != 0 || indexRoot
        self.modified = modified; self.names = names; self.fileNameAttributes = fileNames; self.data = data
        self.dataInExtensionRecords = dataInExtensions; self.hasAttributeList = attributeList
    }

    static func residentValue(_ a: Data, _ nonResident: Bool) throws -> Data {
        guard !nonResident else { throw ScanError.malformed("Expected a resident NTFS attribute.") }
        let length = Int(try a.number(0x10, 4)), offset = Int(try a.number(0x14, 2))
        guard offset >= 0x18, offset <= a.count, length <= a.count - offset else {
            throw ScanError.malformed("Resident NTFS attribute exceeds its record.")
        }
        return a.subdata(in: offset..<offset + length)
    }

    /// Returns nil when the name is unusable (invalid UTF-16, empty, "." or "..", or containing a
    /// separator), so a different namespace's name can be chosen instead of a silently altered one.
    static func fileName(_ v: Data) throws -> NTFSFileName? {
        guard v.count >= 0x42 else { throw ScanError.malformed("Truncated $FILE_NAME.") }
        let count = Int(v[0x40]), namespace = v[0x41]
        guard namespace <= 3, 0x42 + count * 2 <= v.count else { throw ScanError.malformed("Invalid $FILE_NAME.") }
        let units = try (0..<count).map { UInt16(try v.number(0x42 + $0 * 2, 2)) }
        let invalid = transcode(units.makeIterator(), from: UTF16.self, to: UTF32.self, stoppingOnError: true) { _ in }
        let reference = try v.number(0, 8)
        let name = String(decoding: units, as: UTF16.self)
        guard !invalid, !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
            return nil
        }
        return NTFSFileName(parent: reference & 0x0000_ffff_ffff_ffff, parentSequence: UInt16(reference >> 48),
                            namespace: namespace, name: name)
    }

    /// Decodes the first (VCN 0) extent of a non-resident attribute. Returns nil when the attribute
    /// continues in other records.
    static func nonResidentStream(_ a: Data, geometry g: NTFSGeometry) throws -> NTFSDataStream? {
        guard a.count >= 0x40 else { throw ScanError.malformed("Truncated non-resident NTFS attribute.") }
        // Both VCNs come from disk. An empty extent has lastVCN == startVCN - 1, and no extent can map
        // more clusters than the volume holds, so both stay well inside Int64 before any arithmetic.
        let startVCN = try signed(a.number(0x10, 8))
        let lastVCN = Int64(bitPattern: try a.number(0x18, 8))
        guard startVCN < g.clusterCount, lastVCN >= startVCN - 1, lastVCN < g.clusterCount else {
            throw ScanError.malformed("Invalid NTFS VCN range.")
        }
        let vcnCount = try checkedAdd(lastVCN - startVCN, 1)
        let runsOffset = Int(try a.number(0x20, 2))
        let allocated = try signed(a.number(0x28, 8)), real = try signed(a.number(0x30, 8))
        let initialized = try signed(a.number(0x38, 8))
        guard real <= allocated, initialized <= real, runsOffset >= 0x40, runsOffset <= a.count else {
            throw ScanError.malformed("Invalid NTFS attribute sizes.")
        }
        let covered = try checkedMultiply(vcnCount, g.clusterBytes)
        guard covered <= allocated else { throw ScanError.malformed("NTFS runs exceed the allocated size.") }
        let runs = try decodeRuns(a, from: runsOffset, clusters: vcnCount, geometry: g)
        guard covered == allocated else { return nil }
        return NTFSDataStream(size: real, initialized: initialized, runs: runs, residentValue: nil)
    }

    static func decodeRuns(_ a: Data, from start: Int, clusters expected: Int64, geometry g: NTFSGeometry) throws -> [NTFSRun] {
        var position = start, lcn: Int64 = 0, vcn: Int64 = 0
        var runs: [NTFSRun] = []
        while true {
            guard position < a.count else { throw ScanError.malformed("Unterminated NTFS run list.") }
            let header = a[position]
            if header == 0 { break }
            let lengthBytes = Int(header & 0x0f), offsetBytes = Int(header >> 4)
            guard lengthBytes >= 1, lengthBytes <= 8, offsetBytes <= 8,
                  1 + lengthBytes + offsetBytes <= a.count - position else {
                throw ScanError.malformed("Invalid NTFS run header.")
            }
            let length = try signed(a.number(position + 1, lengthBytes))
            guard length > 0 else { throw ScanError.malformed("Empty NTFS run.") }
            if offsetBytes > 0 {
                var raw = try a.number(position + 1 + lengthBytes, offsetBytes)
                if offsetBytes < 8, raw & (1 << (offsetBytes * 8 - 1)) != 0 { raw |= ~UInt64(0) << (offsetBytes * 8) }
                let (next, overflow) = lcn.addingReportingOverflow(Int64(bitPattern: raw))
                guard !overflow, next >= 0, try checkedAdd(next, length) <= g.clusterCount else {
                    throw ScanError.malformed("NTFS run lies outside the volume.")
                }
                lcn = next
                runs.append(NTFSRun(lcn: lcn, length: length))
            } else {
                runs.append(NTFSRun(lcn: nil, length: length))
            }
            vcn = try checkedAdd(vcn, length)
            guard vcn <= expected, runs.count <= maxRuns else { throw ScanError.malformed("NTFS run list overflows its VCN range.") }
            position += 1 + lengthBytes + offsetBytes
        }
        guard vcn == expected else { throw ScanError.malformed("NTFS run list doesn't match its VCN range.") }
        let placed = runs.compactMap { run in run.lcn.map { ($0, $0 + run.length) } }.sorted { $0.0 < $1.0 }
        for (previous, next) in zip(placed, placed.dropFirst()) where previous.1 > next.0 {
            throw ScanError.malformed("Overlapping NTFS runs.")
        }
        return runs
    }

    /// FILETIME counts 100 ns intervals since 1601-01-01 UTC. Zero means "not set".
    static func date(fromFiletime value: UInt64) -> Date? {
        guard value != 0 else { return nil }
        let seconds = Int64(value / 10_000_000) - 11_644_473_600
        return Date(timeIntervalSince1970: Double(seconds) + Double(value % 10_000_000) / 10_000_000)
    }
}
