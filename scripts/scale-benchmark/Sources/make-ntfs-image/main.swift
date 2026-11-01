// Synthetic MBR + NTFS disk image for scale testing (docs/PERFORMANCE.md). Writes a new sparse
// raw image file; it never opens a device. Layout: MBR, NTFS volume 1 (4 KiB clusters, 1 KiB MFT
// records, a directory tree up to 10 deep plus one 64-deep chain, 10% resident files, 10% deleted,
// 5% fragmented), NTFS volume 2 ("RECOVERY"-sized), and in volume 1 an unallocated carving zone
// of real JPEGs (from <jpegDir>) between noise. File contents start with the file's index (little
// endian), so recovered copies can be checked. SHUFFLE=1 numbers MFT records in random order
// relative to the data, as on a long-used drive.
// usage: make-ntfs-image <out.img> <files> <dirs> <vol1GiB> <vol2GiB> <vol2files> <carveMiB> <jpegDir>
import Foundation
import Darwin

let args = CommandLine.arguments
guard args.count >= 9 else { print("usage: make-ntfs-image out.img files dirs vol1GiB vol2GiB vol2files carveMiB jpegDir"); exit(2) }
let outPath = args[1]
let fileCount = Int(args[2])!, dirCount = Int(args[3])!
let p1GiB = Int64(args[4])!, p2GiB = Int64(args[5])!, p2Files = Int(args[6])!
let carveMiB = Int64(args[7])!
let jpegDir = args[8]

let sector: Int64 = 512, cluster: Int64 = 4096, recordSize = 1024
let modifiedBase: UInt64 = (1_600_000_000 + 11_644_473_600) * 10_000_000

// O_EXCL: never overwrite an existing file (or write through a device node).
let fd = open(outPath, O_RDWR | O_CREAT | O_EXCL, 0o644)
guard fd >= 0 else { perror("open"); exit(1) }
func pw(_ data: Data, _ offset: Int64) {
    data.withUnsafeBytes { buf in
        var done = 0
        while done < buf.count {
            let n = pwrite(fd, buf.baseAddress! + done, buf.count - done, offset + Int64(done))
            precondition(n > 0, "pwrite failed")
            done += n
        }
    }
}

extension Data {
    mutating func put(_ offset: Int, _ value: UInt64, _ width: Int) {
        for i in 0..<width { self[offset + i] = UInt8(truncatingIfNeeded: value >> (8 * UInt64(i))) }
    }
    mutating func text(_ offset: Int, _ s: String) { replaceSubrange(offset..<offset + s.utf8.count, with: Array(s.utf8)) }
}
func align8(_ v: Int) -> Int { (v + 7) & ~7 }

struct RNG { var s: UInt64; mutating func next() -> UInt64 { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return s } }
var rng = RNG(s: 0x9E37_79B9_7F4A_7C15)

let pool: Data = {
    var r = RNG(s: 0x1234_5678_9abc_def0)
    var d = Data(count: 16 * 1_048_576)
    d.withUnsafeMutableBytes { b in
        let p = b.bindMemory(to: UInt64.self)
        for i in 0..<p.count { p[i] = r.next() }
    }
    return d
}()

// MARK: NTFS record builders (same layout as SalvageCore's NTFSVolumeTests).
func runList(_ runs: [(lcn: Int64?, length: Int64)]) -> Data {
    func minimal(_ value: Int64, signed: Bool) -> [UInt8] {
        var bytes: [UInt8] = []; var v = value
        repeat { bytes.append(UInt8(truncatingIfNeeded: v)); v >>= 8 }
        while signed ? !((v == 0 && bytes.last! & 0x80 == 0) || (v == -1 && bytes.last! & 0x80 != 0)) : v != 0
        return bytes
    }
    var d = Data(), prev: Int64 = 0
    for run in runs {
        let l = minimal(run.length, signed: false)
        if let lcn = run.lcn {
            let o = minimal(lcn - prev, signed: true)
            d.append(UInt8(o.count << 4 | l.count)); d.append(contentsOf: l + o); prev = lcn
        } else { d.append(UInt8(l.count)); d.append(contentsOf: l) }
    }
    d.append(0)
    return d
}
func resident(_ type: UInt32, _ value: Data) -> Data {
    let valueOffset = 0x18
    var a = Data(count: align8(valueOffset + value.count))
    a.put(0, UInt64(type), 4); a.put(4, UInt64(a.count), 4); a.put(8, 0, 1); a.put(9, 0, 1); a.put(10, 0x18, 2)
    a.put(0x10, UInt64(value.count), 4); a.put(0x14, UInt64(valueOffset), 2)
    a.replaceSubrange(valueOffset..<valueOffset + value.count, with: value)
    return a
}
func nonResident(_ type: UInt32, _ runs: [(lcn: Int64?, length: Int64)], size: Int64, initialized: Int64? = nil) -> Data {
    let rl = runList(runs)
    let clusters = runs.reduce(Int64(0)) { $0 + $1.length }
    let runsOffset = 0x40
    var a = Data(count: align8(runsOffset + rl.count))
    a.put(0, UInt64(type), 4); a.put(4, UInt64(a.count), 4); a.put(8, 1, 1); a.put(9, 0, 1); a.put(10, 0x40, 2)
    a.put(0x10, 0, 8); a.put(0x18, UInt64(bitPattern: clusters - 1), 8); a.put(0x20, UInt64(runsOffset), 2)
    a.put(0x28, UInt64(clusters * cluster), 8); a.put(0x30, UInt64(size), 8); a.put(0x38, UInt64(initialized ?? size), 8)
    a.replaceSubrange(runsOffset..<runsOffset + rl.count, with: rl)
    return a
}
func standardInformation(_ modified: UInt64) -> Data { var v = Data(count: 0x48); v.put(8, modified, 8); return resident(0x10, v) }
func fileName(_ name: String, parent: Int, sequence: Int, namespace: UInt8 = 1) -> Data {
    let units = Array(name.utf16)
    var v = Data(count: 0x42 + units.count * 2)
    v.put(0, UInt64(sequence) << 48 | UInt64(parent), 8)
    v.put(0x40, UInt64(units.count), 1); v.put(0x41, UInt64(namespace), 1)
    for (i, u) in units.enumerated() { v.put(0x42 + i * 2, UInt64(u), 2) }
    return resident(0x30, v)
}
func record(sequence: Int, flags: Int, _ attributes: [Data]) -> Data {
    var r = Data(count: recordSize)
    r.text(0, "FILE"); r.put(4, 0x30, 2); r.put(6, UInt64(recordSize / 512 + 1), 2)
    r.put(0x10, UInt64(sequence), 2); r.put(0x12, 1, 2); r.put(0x14, 0x38, 2); r.put(0x16, UInt64(flags), 2)
    var offset = 0x38
    for a in attributes { r.replaceSubrange(offset..<offset + a.count, with: a); offset += a.count }
    r.put(offset, 0xffff_ffff, 4); offset += 8
    precondition(offset <= recordSize)
    r.put(0x18, UInt64(offset), 4); r.put(0x1c, UInt64(recordSize), 4); r.put(0x20, 0, 8)
    let usn: UInt64 = 0x4b1d
    r.put(0x30, usn, 2)
    for stride in 1...recordSize / 512 {
        let tail = stride * 512 - 2
        r.put(0x30 + stride * 2, UInt64(r[tail]) | UInt64(r[tail + 1]) << 8, 2); r.put(tail, usn, 2)
    }
    return r
}

let jpegs: [Data] = (try? FileManager.default.contentsOfDirectory(atPath: jpegDir))?.sorted()
    .compactMap { FileManager.default.contents(atPath: jpegDir + "/" + $0) } ?? []
print("jpegs available: \(jpegs.count)")

/// Builds one NTFS volume at `base` (device offset) of `bytes`.
func buildVolume(base: Int64, bytes: Int64, files: Int, dirs: Int, carveBytes: Int64, label: String) -> (live: Int, deleted: Int, dataBytes: Int64) {
    let clusterCount = bytes / cluster
    let rootRecord = 5
    let firstDir = 16, firstFile = 16 + dirs
    let recordCount = firstFile + files + 64
    let mftLCN: Int64 = 16
    let mftClusters = (Int64(recordCount * recordSize) + cluster - 1) / cluster
    let bitmapBytes = (clusterCount + 7) / 8
    let bitmapLCN = mftLCN + mftClusters + 16
    let bitmapClusters = (bitmapBytes + cluster - 1) / cluster
    var bitmap = Data(count: Int(bitmapClusters * cluster))
    func mark(_ lcn: Int64, _ n: Int64) {
        for c in lcn..<lcn + n { bitmap[Int(c / 8)] |= UInt8(1) << UInt8(c % 8) }
    }
    mark(0, bitmapLCN + bitmapClusters)
    var mft = Data(count: recordCount * recordSize)
    func setRecord(_ n: Int, _ r: Data) { mft.replaceSubrange(n * recordSize..<(n + 1) * recordSize, with: r) }

    // Boot sector.
    var boot = Data(count: 512)
    boot[0] = 0xeb; boot[1] = 0x52; boot[2] = 0x90
    boot.text(3, "NTFS    "); boot.put(11, 512, 2); boot.put(13, UInt64(cluster / sector), 1)
    boot.put(0x15, 0xf8, 1)
    boot.put(0x28, UInt64(bytes / sector - 1), 8); boot.put(0x30, UInt64(mftLCN), 8); boot.put(0x38, 2, 8)
    boot.put(0x40, 0xf6, 1); boot.put(0x44, 0x01, 1); boot.put(510, 0xaa55, 2)
    pw(boot, base)

    // System records.
    setRecord(0, record(sequence: 1, flags: 1, [standardInformation(modifiedBase), fileName("$MFT", parent: 5, sequence: 5, namespace: 3),
                                                 nonResident(0x80, [(mftLCN, mftClusters)], size: Int64(recordCount * recordSize))]))
    setRecord(rootRecord, record(sequence: 5, flags: 3, [standardInformation(modifiedBase), fileName(".", parent: 5, sequence: 5, namespace: 3)]))
    setRecord(6, record(sequence: 6, flags: 1, [fileName("$Bitmap", parent: 5, sequence: 5, namespace: 3),
                                                nonResident(0x80, [(bitmapLCN, bitmapClusters)], size: bitmapBytes)]))

    // Directory tree: 24 top-level folders, then random parents with bounded depth, plus one deep chain.
    var depth = [Int](repeating: 0, count: dirs)
    let topNames = ["Documents", "Pictures", "Music", "Videos", "Downloads", "Projects", "Backup 2019", "Backup 2021",
                    "Users", "Program Files", "Games", "Work", "School", "Photos", "Scans", "Taxes", "Recipes",
                    "Café Notes", "東京 旅行", "Archive", "Old Laptop", "Phone Dump", "Camera Roll", "Misc"]
    for d in 0..<dirs {
        let number = firstDir + d
        var parent = rootRecord, name: String
        if d < topNames.count { name = topNames[d] }
        else if d < topNames.count + 64 { parent = firstDir + d - 1; depth[d] = d - topNames.count + 1; name = "deep \(depth[d])" }
        else {
            var p = Int(rng.next() % UInt64(d))
            while depth[p] >= 9 || (p >= topNames.count && p < topNames.count + 64) { p = Int(rng.next() % UInt64(d)) }
            parent = firstDir + p; depth[d] = depth[p] + 1
            name = ["Folder \(d)", "Album \(d % 300)", "Event \(d) – Summer", "Sub \(d)"][d % 4]
        }
        let deleted = d >= topNames.count + 64 && d % 50 == 13
        setRecord(number, record(sequence: deleted ? 2 : 1, flags: deleted ? 2 : 3,
                                 [standardInformation(modifiedBase + UInt64(d) * 10_000_000),
                                  fileName(name, parent: parent, sequence: parent == rootRecord ? 5 : 1)]))
    }

    // Files and their data, laid out sequentially after the system area with a carving zone in the middle.
    var nextLCN = bitmapLCN + bitmapClusters + 256
    let carveAt = clusterCount / 3
    var carveWritten = false
    let exts = ["JPG", "png", "docx", "pdf", "txt", "mp3", "mov", "zip", "heic", "csv", "xlsx", "dll"]
    var live = 0, deletedCount = 0, dataBytes: Int64 = 0
    func writeCarveZone() {
        // Unallocated area with real JPEGs (no MFT records), noise between them, to exercise the carver.
        var offset = carveAt * cluster
        let end = offset + carveBytes
        var j = 0
        while offset < end, !jpegs.isEmpty {
            let jpeg = jpegs[j % jpegs.count]; j += 1
            pw(jpeg, base + offset)
            offset += (Int64(jpeg.count) + sector - 1) / sector * sector
            let noise = Int64(rng.next() % (256 * 1024)) / sector * sector
            let start = Int(rng.next() % UInt64(pool.count - Int(noise) - 1))
            pw(pool.subdata(in: start..<start + Int(noise)), base + offset)
            offset += noise
        }
        print("  carve zone: \(j) jpegs, \(carveBytes >> 20) MiB at cluster \(carveAt)")
    }
    // SHUFFLE=1: MFT record numbers in random order relative to where the data lies, as on a
    // drive that has been in use for years, so deleted files' clusters are scattered in MFT order.
    var order = Array(0..<files)
    if ProcessInfo.processInfo.environment["SHUFFLE"] == "1" {
        for i in stride(from: files - 1, to: 0, by: -1) { order.swapAt(i, Int(rng.next() % UInt64(i + 1))) }
    }
    for f in 0..<files {
        let number = firstFile + order[f]
        if !carveWritten, nextLCN >= carveAt { writeCarveZone(); carveWritten = true; nextLCN = carveAt + (carveBytes + cluster - 1) / cluster + 16 }
        let x = rng.next()
        let bucket = Int(x % 1000)
        var size: Int64
        if bucket < 100 { size = Int64(1 + (x >> 12) % 600) }               // resident
        else if bucket < 900 { size = 1024 + Int64((x >> 12) % (31 * 1024)) }
        else if bucket < 995 { size = 32 * 1024 + Int64((x >> 12) % (224 * 1024)) }
        else { size = 1_048_576 + Int64((x >> 12) % (4 * 1_048_576)) }
        let deleted = f % 10 == 7
        let ext = exts[f % exts.count]
        let name = f % 3 == 0 ? String(format: "IMG_%06d.%@", f, ext) : "Document \(f) - final copy.\(ext)"
        let parentDir = Int(x >> 40) % dirs
        let parent = firstDir + parentDir
        var attrs = [standardInformation(modifiedBase + UInt64(f) * 1_000_000_000), fileName(name, parent: parent, sequence: 1)]
        let start = Int((x >> 8) % UInt64(pool.count - 6 * 1_048_576))
        if size <= 600 {
            attrs.append(resident(0x80, pool.subdata(in: start..<start + Int(size))))
        } else {
            let clusters = (size + cluster - 1) / cluster
            var runs: [(lcn: Int64?, length: Int64)] = []
            if f % 20 == 3, clusters >= 4 {
                // Fragmented: two pieces with a gap of free space between them.
                let a = clusters / 2
                runs = [(nextLCN, a), (nextLCN + a + 8, clusters - a)]
                nextLCN += clusters + 8
            } else {
                runs = [(nextLCN, clusters)]; nextLCN += clusters
            }
            if f % 7 == 0 { nextLCN += Int64(rng.next() % 32) }  // free gaps
            precondition(nextLCN < clusterCount, "volume too small")
            var written: Int64 = 0
            for run in runs {
                let n = min(run.length * cluster, size - written)
                var chunk = pool.subdata(in: start + Int(written)..<start + Int(written + n))
                if written == 0 { withUnsafeBytes(of: UInt64(f).littleEndian) { chunk.replaceSubrange(0..<8, with: $0) } }
                pw(chunk, base + run.lcn! * cluster)
                written += n
                if !deleted { mark(run.lcn!, run.length) }
            }
            dataBytes += size
            attrs.append(nonResident(0x80, runs, size: size))
        }
        if deleted { deletedCount += 1 } else { live += 1 }
        setRecord(number, record(sequence: deleted ? 2 : 1, flags: deleted ? 0 : 1, attrs))
        if f % 50_000 == 0 && f > 0 { print("  \(label): \(f) files, next cluster \(nextLCN)") }
    }
    if !carveWritten, carveBytes > 0 { writeCarveZone() }
    pw(mft, base + mftLCN * cluster)
    pw(bitmap.prefix(Int(bitmapBytes)), base + bitmapLCN * cluster)
    // Backup boot sector at the last sector.
    pw(boot, base + bytes - sector)
    return (live, deletedCount, dataBytes)
}

let gib: Int64 = 1 << 30
let p1Start: Int64 = 1 << 20
let p1Bytes = p1GiB * gib
let p2Start = p1Start + p1Bytes
let p2Bytes = p2GiB * gib
let total = p2Start + p2Bytes + (1 << 20)
precondition(ftruncate(fd, total) == 0)
var mbr = Data(count: 512)
func entry(_ i: Int, _ start: Int64, _ len: Int64) {
    let p = 446 + i * 16
    mbr.put(p, 0, 1); mbr.put(p + 4, 0x07, 1); mbr.put(p + 8, UInt64(start / sector), 4); mbr.put(p + 12, UInt64(len / sector), 4)
}
entry(0, p1Start, p1Bytes); entry(1, p2Start, p2Bytes)
mbr.put(510, 0xaa55, 2)
pw(mbr, 0)
let started = Date()
let a = buildVolume(base: p1Start, bytes: p1Bytes, files: fileCount, dirs: dirCount, carveBytes: carveMiB << 20, label: "p1")
let b = buildVolume(base: p2Start, bytes: p2Bytes, files: p2Files, dirs: max(30, p2Files / 50), carveBytes: 0, label: "RECOVERY")
close(fd)
print("p1: live \(a.live) deleted \(a.deleted) dirs \(dirCount) data \(a.dataBytes >> 20) MiB; p2: live \(b.live) deleted \(b.deleted) data \(b.dataBytes >> 20) MiB")
print("image \(total >> 30) GiB at \(outPath) in \(Int(Date().timeIntervalSince(started)))s")
