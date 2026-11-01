import Foundation

/// The layout fingerprint a scan records (spec-tech-batch-7 §B): the ordered volume extents that
/// volume discovery finds on a device, exactly as `ScanCheckpoint.extents` holds them. A saved
/// scan is reconnected to a device only when the device's fingerprint, taken fresh here, equals the
/// one the scan recorded, so a drive that was re-partitioned or reformatted since is refused.
///
/// Discovery reads only partition tables, filesystem headers and the bounded lost-partition probes
/// (`VolumeDiscovery`); it never sweeps file contents.
public enum ExtentFingerprint {
    public static func of(_ reader: any BlockReader) async throws -> [ScanCheckpoint.Extent] {
        try await VolumeDiscovery(reader: reader).discover().extents
            .map { ScanCheckpoint.Extent(offset: $0.offset, length: $0.length) }
    }
}

/// Where an NTFS file's resident `$DATA` lives on the device, so a saved scan can keep only offsets
/// and lengths instead of the file's bytes (spec-tech-batch-7 §B, privacy), and the check that
/// re-reads it from a reconnected device before any of it is used.
///
/// A resident value sits inside its MFT record, but not byte for byte: NTFS's update-sequence
/// fixup replaces the last two bytes of every 512-byte stride with the sequence number and keeps
/// the originals in the record's update-sequence array. The runs here point at those array slots
/// for the stride tails, so reading them from the device yields exactly the fixed-up value.
public enum NTFSResidentData {
    /// The device runs that reproduce the unnamed resident `$DATA` value of `record`, a fixed-up
    /// MFT record located at `recordOffset` on the device. Nil when `record` isn't a consistent
    /// FILE record whose unnamed `$DATA` is resident.
    public static func runs(inRecord record: Data, at recordOffset: Int64) -> [DataRun]? {
        let r = Data(record)
        guard r.count >= 512, r.count % 512 == 0, recordOffset >= 0,
              String(decoding: r.prefix(4), as: UTF8.self) == "FILE",
              let usaOffset = try? Int(r.number(4, 2)), let usaCount = try? Int(r.number(6, 2)),
              usaOffset >= 8, usaOffset % 2 == 0, usaCount == r.count / 512 + 1, usaOffset + usaCount * 2 <= 510,
              let (start, length) = residentValueRange(r) else { return nil }
        var runs: [DataRun] = []
        func append(_ deviceOffset: Int64, _ count: Int) {
            if let last = runs.last, let lastOffset = last.deviceOffset, lastOffset + last.length == deviceOffset {
                runs[runs.count - 1] = DataRun(deviceOffset: lastOffset, length: last.length + Int64(count))
            } else {
                runs.append(DataRun(deviceOffset: deviceOffset, length: Int64(count)))
            }
        }
        var position = start
        let end = start + length
        while position < end {
            let stride = position / 512
            let tail = stride * 512 + 510
            if position < tail {
                let count = min(end, tail) - position
                append(recordOffset + Int64(position), count)
                position += count
            } else {
                // A stride tail: its real bytes are the array slot for this stride (1-based).
                let within = position - tail
                let count = min(end - position, 2 - within)
                append(recordOffset + Int64(usaOffset + (stride + 1) * 2 + within), count)
                position += count
            }
        }
        return runs
    }

    /// The record-relative start and length of the unnamed `$DATA` value, walking the attributes
    /// with the same bounds `NTFSRecord` enforces. Nil when that stream is missing or non-resident.
    static func residentValueRange(_ r: Data) -> (Int, Int)? {
        guard let used = try? Int(r.number(0x18, 4)), var offset = try? Int(r.number(0x14, 2)),
              used <= r.count, offset >= 0x18, offset % 8 == 0, offset < used else { return nil }
        for _ in 0..<NTFSRecord.maxAttributes {
            guard offset + 4 <= used, let type = try? r.number(offset, 4) else { return nil }
            if type == 0xffff_ffff { return nil }
            guard offset + 16 <= used, let length = try? Int(r.number(offset + 4, 4)),
                  length >= 0x18, length % 8 == 0, length <= used - offset else { return nil }
            if type == 0x80, r[offset + 9] == 0 {
                guard r[offset + 8] == 0, let valueLength = try? Int(r.number(offset + 0x10, 4)),
                      let valueOffset = try? Int(r.number(offset + 0x14, 2)),
                      valueOffset >= 0x18, valueOffset <= length, valueLength <= length - valueOffset else { return nil }
                return (offset + valueOffset, valueLength)
            }
            offset += length
        }
        return nil
    }

    /// Re-reads `file`'s MFT record from `reader` and checks it still holds this file: the same
    /// record number, name, date, deleted state and size, a resident unnamed `$DATA` that the
    /// file's runs (`runs(inRecord:at:)`) map exactly, and bytes at those runs equal to the value
    /// the existing parser reads. Reads only the volume's boot sector and the one record.
    public static func revalidate(_ file: RecoveredFile, recordBytes: Int, reader: any BlockReader) async -> Bool {
        let meta = file.sourceMetadata
        guard meta.filesystem == .ntfs, case .runs(let runs) = file.content, !runs.isEmpty,
              (512...65536).contains(recordBytes), recordBytes & (recordBytes - 1) == 0,
              meta.volumeOffset >= 0, meta.volumeOffset < reader.sizeBytes, meta.recordOffset >= meta.volumeOffset,
              meta.recordOffset <= reader.sizeBytes - Int64(recordBytes) else { return false }
        do {
            let boot = try await reader.read(at: meta.volumeOffset, count: 512)
            let geometry = try NTFSGeometry(boot: Data(boot), volumeLength: reader.sizeBytes - meta.volumeOffset)
            guard geometry.recordBytes == Int64(recordBytes) else { return false }
            let raw = Data(try await reader.read(at: meta.recordOffset, count: recordBytes))
            guard raw.count == recordBytes, String(decoding: raw.prefix(4), as: UTF8.self) == "FILE" else { return false }
            var fixed = raw
            guard applyNTFSFixup(&fixed) else { return false }
            // NTFS 3.1 records carry their own number (a 3.0 record's array starts before that field).
            if try fixed.number(4, 2) >= 0x30, try fixed.number(0x2c, 4) != meta.allocationStart & 0xffff_ffff { return false }
            let record = try NTFSRecord(fixed, geometry: geometry)
            guard record.baseReference == 0, !record.isDirectory, !record.hasAttributeList,
                  record.inUse == !file.isDeleted, record.bestName?.name == file.name, record.modified == file.modified,
                  let data = record.data, let value = data.residentValue, !data.isCompressedOrEncrypted,
                  Int64(value.count) == file.sizeBytes,
                  NTFSResidentData.runs(inRecord: fixed, at: meta.recordOffset) == runs else { return false }
            var served = Data()
            for run in runs {
                guard let deviceOffset = run.deviceOffset else { return false }
                let start = Int(deviceOffset - meta.recordOffset)
                served += raw[start..<start + Int(run.length)]
            }
            return served == value
        } catch {
            return false
        }
    }
}
