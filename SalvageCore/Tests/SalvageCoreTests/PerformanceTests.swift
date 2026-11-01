import Darwin
import Foundation
import Testing
@testable import SalvageCore

// Scan / recovery benchmark (batch 5, item D). Off by default: it builds multi-GB disk images
// with hdiutil, so it runs only with SALVAGE_BENCHMARK=1, normally through
// `scripts/benchmark-scan.sh` (Release build, one process per image so peak RSS is per scan).
//
// Knobs (environment):
//   SALVAGE_BENCHMARK=1                 enable the suite
//   SALVAGE_BENCHMARK_FS=exfat|fat32    which image the `scan` test builds (default exfat)
//   SALVAGE_BENCHMARK_FILES=50000       files written into nested folders
//   SALVAGE_BENCHMARK_SIZE_MIB=2048     image size
//   SALVAGE_BENCHMARK_DIR=<dir>         keep the built image there and reuse it on the next run
//                                       (the caller deletes it); default: a fresh temp dir,
//                                       removed when the test ends
//   SALVAGE_BENCHMARK_REPORT=<file>     append a one-line JSON result there
//   SALVAGE_BENCHMARK_SCAN_REPEATS=1    scan the image this many times, report the fastest
//   SALVAGE_BENCHMARK_SKIP_RECOVERY=1   scans only (for profiling the scan)
//
// Images are created, attached (no browse, own mount point) and detached by hdiutil only; the
// scan reads the detached image *file* through `ImageFileReader`, never a device node.

enum Benchmark {
    static let enabled = ProcessInfo.processInfo.environment["SALVAGE_BENCHMARK"] == "1"
    static func env(_ key: String) -> String? { ProcessInfo.processInfo.environment[key] }
    static var fileCount: Int { env("SALVAGE_BENCHMARK_FILES").flatMap(Int.init) ?? 50_000 }
    static var sizeMiB: Int { env("SALVAGE_BENCHMARK_SIZE_MIB").flatMap(Int.init) ?? 2048 }
    static var filesystem: String { env("SALVAGE_BENCHMARK_FS") ?? "exfat" }

    /// Peak resident set size of this process so far (macOS reports ru_maxrss in bytes).
    static func peakRSS() -> Int64 {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Int64(usage.ru_maxrss)
    }
    /// Current physical footprint (what Activity Monitor shows as Memory).
    static func footprint() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
    }
    /// User + system CPU time of this process so far. Less sensitive than wall time to other
    /// work on the machine, so it is the better before/after figure on a busy host.
    static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func s(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
        return s(usage.ru_utime) + s(usage.ru_stime)
    }
    static func mib(_ bytes: Int64) -> String { String(format: "%.1f MiB", Double(bytes) / 1_048_576) }
    static func rate(_ bytes: Int64, _ seconds: Double) -> String { String(format: "%.1f MiB/s", Double(bytes) / 1_048_576 / seconds) }
    static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    static func report(_ fields: [String: Any]) {
        let line = fields.keys.sorted().map { key -> String in
            let value = fields[key]!
            if let text = value as? String { return "\"\(key)\":\"\(text)\"" }
            return "\"\(key)\":\(value)"
        }.joined(separator: ",")
        print("BENCHMARK {\(line)}")
        if let path = env("SALVAGE_BENCHMARK_REPORT"), let data = "{\(line)}\n".data(using: .utf8) {
            if let handle = FileHandle(forWritingAtPath: path) {
                handle.seekToEndOfFile(); handle.write(data); try? handle.close()
            } else {
                FileManager.default.createFile(atPath: path, contents: data)
            }
        }
    }
}

/// Reads a detached raw (UDRW) image file with pread. The UDIF trailer ("koly" block), when
/// present, is not part of the device.
final class ImageFileReader: BlockReader, @unchecked Sendable {
    let descriptor: Int32
    let sizeBytes: Int64
    init(path: String) throws {
        descriptor = open(path, O_RDONLY)
        guard descriptor >= 0 else { throw ScanError.io("open \(path) failed") }
        var size = lseek(descriptor, 0, SEEK_END)
        if size >= 512 {
            var trailer = [UInt8](repeating: 0, count: 4)
            if pread(descriptor, &trailer, 4, size - 512) == 4, trailer == Array("koly".utf8) { size -= 512 }
        }
        sizeBytes = size
    }
    deinit { close(descriptor) }
    private let lock = NSLock()
    private var counts: (reads: Int, bytes: Int64) = (0, 0)
    /// Reads issued and bytes returned since the last call (then reset).
    func takeCounts() -> (reads: Int, bytes: Int64) {
        lock.withLock { defer { counts = (0, 0) }; return counts }
    }
    func read(at offset: Int64, count: Int) async throws -> Data {
        guard offset >= 0, count >= 0, offset <= sizeBytes, Int64(count) <= sizeBytes - offset else {
            throw ScanError.io("Out of bounds")
        }
        var data = Data(count: count)
        let read = data.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, count, offset) }
        guard read == count else { throw ScanError.io("Short read") }
        lock.withLock { counts.reads += 1; counts.bytes += Int64(count) }
        return data
    }
}

/// Deterministic file set: names, folders and contents are a pure function of the index, so
/// recovered bytes can be checked without keeping the originals.
struct BenchmarkCorpus {
    let count: Int
    static let extensions = ["JPG", "png", "docx", "pdf", "txt", "mp3", "mov", "zip", "heic", "csv"]

    /// 50 top folders x 20 subfolders, files spread across the 1000 leaves.
    func relativePath(_ index: Int) -> String {
        let leaf = index % 1000
        let ext = Self.extensions[index % Self.extensions.count]
        let name = index % 3 == 0 ? "IMG_\(String(format: "%05d", index)).\(ext)"
                                  : "Holiday photo \(index) - edited copy.\(ext)"
        return "Folder \(leaf / 20)/Album \(leaf % 20)/\(name)"
    }
    /// Mostly small files with a long tail: ~80% 1-16 KiB, ~19.5% 16-64 KiB, ~0.5% 1-4 MiB.
    func size(_ index: Int) -> Int {
        var x = UInt64(truncatingIfNeeded: index) &* 0x9E3779B97F4A7C15
        x ^= x >> 29; x = x &* 0xBF58476D1CE4E5B9; x ^= x >> 32
        let bucket = Int(x % 1000), r = Int((x >> 10) % 1_000_000)
        if bucket < 800 { return 1024 + r % (15 * 1024) }
        if bucket < 995 { return 16 * 1024 + r % (48 * 1024) }
        return 1_048_576 + Int((x >> 20) % UInt64(3 * 1_048_576))
    }
    /// Every tenth file is deleted after the image is populated.
    func isDeleted(_ index: Int) -> Bool { index % 10 == 7 }

    /// One shared pseudo-random pool; each file is a window into it with its index stamped first.
    static let pool: [UInt8] = {
        var state: UInt64 = 0x1234_5678_9abc_def0
        return (0..<(5 * 1_048_576)).map { _ in
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return UInt8(truncatingIfNeeded: state)
        }
    }()
    func content(_ index: Int) -> Data {
        let size = size(index), start = (index &* 7919) % (Self.pool.count - size)
        var data = Data(Self.pool[start..<(start + size)])
        withUnsafeBytes(of: UInt64(index).littleEndian) { data.replaceSubrange(0..<8, with: $0) }
        return data
    }
}

enum BenchmarkImage {
    static func hdiutil(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output; process.standardError = output
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ScanError.io("hdiutil \(arguments.first ?? "") failed: \(text)") }
    }

    /// Builds (or reuses) `<directory>/<fs>-<files>-<size>.dmg` and returns its path.
    static func build(filesystem: String, corpus: BenchmarkCorpus, sizeMiB: Int, in directory: URL) throws -> (path: String, seconds: Double) {
        let image = directory.appendingPathComponent("\(filesystem)-\(corpus.count)-\(sizeMiB).dmg")
        if FileManager.default.fileExists(atPath: image.path) { return (image.path, 0) }
        let started = ContinuousClock.now
        let mount = directory.appendingPathComponent("mnt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: mount) }
        let partial = directory.appendingPathComponent("building-\(UUID().uuidString).dmg")
        // exFAT's default cluster for 2 GB is 32 KiB, which 50k small files would overflow; 4 KiB
        // clusters (8 sectors) match FAT32's default and SD-card-sized exFAT layouts.
        let (fs, layout, args) = filesystem == "fat32" ? ("MS-DOS FAT32", "MBRSPUD", [String]())
                                                       : ("ExFAT", "GPTSPUD", ["-fsargs", "-c 8"])
        try hdiutil(["create", "-size", "\(sizeMiB)m", "-type", "UDIF", "-fs", fs, "-volname", "BENCH",
                     "-layout", layout] + args + ["-quiet", partial.path])
        do {
            try hdiutil(["attach", "-nobrowse", "-noverify", "-noautofsck", "-mountpoint", mount.path, partial.path])
            var populateError: (any Error)?
            do { try populate(mount, corpus: corpus) } catch { populateError = error }
            try hdiutil(["detach", mount.path, "-force"])
            if let populateError { throw populateError }
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
        try FileManager.default.moveItem(at: partial, to: image)
        return (image.path, seconds(ContinuousClock.now - started))
    }

    static func populate(_ root: URL, corpus: BenchmarkCorpus) throws {
        var created = Set<String>()
        for index in 0..<corpus.count {
            let url = root.appendingPathComponent(corpus.relativePath(index))
            let folder = url.deletingLastPathComponent().path
            if created.insert(folder).inserted {
                try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            }
            try corpus.content(index).write(to: url)
        }
        for index in 0..<corpus.count where corpus.isDeleted(index) {
            try FileManager.default.removeItem(at: root.appendingPathComponent(corpus.relativePath(index)))
        }
        sync()
    }
    static func seconds(_ d: Duration) -> Double { Benchmark.seconds(d) }
}

actor BenchmarkCollector {
    var files: [RecoveredFile] = []
    var scanned: Int64 = 0, total: Int64 = 0
    var error: ScanError?
    var completed = false
    func handle(_ event: ScanEvent) {
        switch event {
        case .found(let file): files.append(file)
        case .progress(let bytes, let totalBytes): scanned = bytes; total = totalBytes
        case .error(let failure): error = failure
        case .completed: completed = true
        default: break
        }
    }
}

/// Samples the physical footprint while `body` runs and returns its peak.
func peakFootprint<T>(during body: () async throws -> T) async rethrows -> (T, Int64) {
    let peak = ManagedPeak()
    let sampler = Task.detached {
        while !Task.isCancelled {
            peak.note(Benchmark.footprint())
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
    let result = try await body()
    sampler.cancel()
    peak.note(Benchmark.footprint())
    return (result, peak.value)
}

final class ManagedPeak: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: Int64 = 0
    func note(_ value: Int64) { lock.withLock { peak = max(peak, value) } }
    var value: Int64 { lock.withLock { peak } }
}

@Suite("Performance benchmark (SALVAGE_BENCHMARK=1)", .enabled(if: Benchmark.enabled, "set SALVAGE_BENCHMARK=1"), .serialized)
struct PerformanceTests {
    /// Builds one image, scans it end to end through `ScanSession`, then recovers every
    /// metadata-found file to a temp folder and checks a sample of them byte for byte.
    @Test func scan() async throws {
        let corpus = BenchmarkCorpus(count: Benchmark.fileCount)
        let filesystem = Benchmark.filesystem
        let keep = Benchmark.env("SALVAGE_BENCHMARK_DIR").map { URL(fileURLWithPath: $0) }
        let directory = keep ?? FileManager.default.temporaryDirectory.appendingPathComponent("salvage-bench-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { if keep == nil { try? FileManager.default.removeItem(at: directory) } }

        let (path, buildSeconds) = try BenchmarkImage.build(filesystem: filesystem, corpus: corpus, sizeMiB: Benchmark.sizeMiB, in: directory)
        let reader = try ImageFileReader(path: path)

        // Scan (SALVAGE_BENCHMARK_SCAN_REPEATS times; the fastest run is reported).
        let repeats = max(1, Benchmark.env("SALVAGE_BENCHMARK_SCAN_REPEATS").flatMap(Int.init) ?? 1)
        var collector = BenchmarkCollector()
        let rssBefore = Benchmark.peakRSS()
        let footprintBefore = Benchmark.footprint()
        let clock = ContinuousClock()
        var scanSeconds = Double.infinity, scanPeak: Int64 = 0, allScans: [String] = []
        var scanCPU = Double.infinity, scanReads = 0, scanReadBytes: Int64 = 0
        _ = reader.takeCounts()
        for _ in 0..<repeats {
            collector = BenchmarkCollector()
            let started = clock.now, cpuStarted = Benchmark.cpuSeconds()
            let (_, peak) = await peakFootprint { [collector] in
                let (stream, continuation) = AsyncStream<ScanEvent>.makeStream(bufferingPolicy: .bufferingOldest(4096))
                let session = ScanSession(reader: reader)
                let producer = Task { await session.run(events: continuation) }
                for await event in stream { await collector.handle(event) }
                await producer.value
            }
            let elapsed = Benchmark.seconds(clock.now - started)
            scanCPU = min(scanCPU, Benchmark.cpuSeconds() - cpuStarted)
            (scanReads, scanReadBytes) = reader.takeCounts()
            allScans.append(String(format: "%.3f", elapsed))
            scanSeconds = min(scanSeconds, elapsed); scanPeak = max(scanPeak, peak)
        }
        let files = await collector.files
        #expect(await collector.error == nil)
        #expect(await collector.completed)
        let metadata = files.filter { $0.recoveryMethod == .metadata }
        let live = metadata.filter { !$0.isDeleted }, deleted = metadata.filter(\.isDeleted)
        let carved = files.count - metadata.count
        let expectedLive = (0..<corpus.count).filter { !corpus.isDeleted($0) }.count
        #expect(live.filter { !$0.name.hasPrefix(".") }.count >= expectedLive)
        let scanned = await collector.scanned

        // Recover every mapped metadata file (live and deleted) to a temp folder.
        let destination = directory.appendingPathComponent("recovered-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: destination) }
        let content = FileContentReader(reader: reader)
        let skipRecovery = Benchmark.env("SALVAGE_BENCHMARK_SKIP_RECOVERY") == "1"
        let recoverable = skipRecovery ? [] : metadata.filter { (try? content.validate($0)) != nil }
        // Two passes: the whole recovery (source reads through FileContentReader plus a plain
        // open/write/close per file at the destination), then the source side alone, since on a
        // fast SSD the destination's per-file create cost dominates the first.
        let recoverStarted = clock.now, recoverCPUStarted = Benchmark.cpuSeconds()
        var recoveredBytes: Int64 = 0
        let (_, recoverPeak) = try await peakFootprint {
            for (index, file) in recoverable.enumerated() {
                let path = destination.appendingPathComponent("\(index)").path
                let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
                guard descriptor >= 0 else { throw ScanError.io("create \(path) failed") }
                defer { close(descriptor) }
                for try await chunk in content.chunks(of: file) {
                    let written = chunk.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
                    guard written == chunk.count else { throw ScanError.io("short write") }
                    recoveredBytes += Int64(chunk.count)
                }
            }
        }
        let recoverSeconds = Benchmark.seconds(clock.now - recoverStarted)
        let recoverCPU = Benchmark.cpuSeconds() - recoverCPUStarted
        let readStarted = clock.now
        var readBytes: Int64 = 0
        for file in recoverable {
            for try await chunk in content.chunks(of: file) { readBytes += Int64(chunk.count) }
        }
        let readSeconds = Benchmark.seconds(clock.now - readStarted)
        #expect(readBytes == recoveredBytes)

        // Byte-for-byte check of a sample of live files against the corpus.
        let byPath = Dictionary(live.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        var checked = 0
        for index in stride(from: 0, to: corpus.count, by: max(1, corpus.count / 200)) where !corpus.isDeleted(index) {
            guard let file = byPath["/" + corpus.relativePath(index)] else {
                Issue.record("missing \(corpus.relativePath(index))"); continue
            }
            #expect(try await content.prefix(of: file, limit: file.sizeBytes) == corpus.content(index))
            checked += 1
        }

        Benchmark.report([
            "fs": filesystem, "files_written": corpus.count, "image_mib": Benchmark.sizeMiB,
            "image_build_s": String(format: "%.1f", buildSeconds),
            "scan_s": String(format: "%.3f", scanSeconds), "scan_cpu_s": String(format: "%.3f", scanCPU),
            "scan_device_reads": scanReads, "scan_device_read_bytes": scanReadBytes, "scan_runs_s": allScans.joined(separator: " "), "scanned_bytes": scanned,
            "scan_mib_per_s": String(format: "%.1f", Double(scanned) / 1_048_576 / scanSeconds),
            "found_live": live.count, "found_deleted": deleted.count, "found_carved": carved,
            "scan_peak_footprint_mib": String(format: "%.1f", Double(scanPeak) / 1_048_576),
            "scan_footprint_growth_mib": String(format: "%.1f", Double(scanPeak - footprintBefore) / 1_048_576),
            "peak_rss_mib": String(format: "%.1f", Double(Benchmark.peakRSS()) / 1_048_576),
            "peak_rss_before_scan_mib": String(format: "%.1f", Double(rssBefore) / 1_048_576),
            "recover_files": recoverable.count, "recover_bytes": recoveredBytes,
            "recover_s": String(format: "%.3f", recoverSeconds), "recover_cpu_s": String(format: "%.3f", recoverCPU),
            "recover_mib_per_s": String(format: "%.1f", Double(recoveredBytes) / 1_048_576 / recoverSeconds),
            "source_read_s": String(format: "%.3f", readSeconds),
            "source_read_mib_per_s": String(format: "%.1f", Double(readBytes) / 1_048_576 / max(readSeconds, 1e-9)),
            "recover_peak_footprint_mib": String(format: "%.1f", Double(recoverPeak) / 1_048_576),
            "verified_files": checked,
        ])
    }
}
