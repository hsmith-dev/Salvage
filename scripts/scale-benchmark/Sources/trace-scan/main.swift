// Runs one ScanSession over a disk image file (read-only, through SalvageDiskIO's ImageFileReader)
// and reports what it read and kept (docs/PERFORMANCE.md):
//   - reads, reads under 64 KiB, and seeks (a read that doesn't start within 1 MiB after the
//     previous one ended), with a modelled USB hard-drive time: transfer at 130 MB/s (USB 3) or
//     35 MB/s (USB 2) plus 12 ms per seek;
//   - wall time, when the last metadata file arrived, and memory held per found file;
//   - the checkpoint count and the size of the last one as JSON.
// THROTTLE=<MB/s> makes every read take as long as a drive of that speed would (the read blocks
// its thread, as pread on a device does), to time how carving overlaps with reading.
// usage: trace-scan <image>
import Darwin
import Foundation
import SalvageCore
import SalvageDiskIO

final class Tracer: BlockReader, @unchecked Sendable {
    let base: any BlockReader
    var sizeBytes: Int64 { base.sizeBytes }
    let throttle = ProcessInfo.processInfo.environment["THROTTLE"].flatMap(Double.init)
    private let lock = NSLock()
    private var counts = (reads: 0, small: 0, seeks: 0, bytes: Int64(0), lastEnd: Int64(-1))
    var totals: (reads: Int, small: Int, seeks: Int, bytes: Int64) {
        lock.withLock { (counts.reads, counts.small, counts.seeks, counts.bytes) }
    }
    init(_ base: any BlockReader) { self.base = base }
    func read(at offset: Int64, count: Int) async throws -> Data {
        lock.withLock {
            counts.reads += 1; counts.bytes += Int64(count)
            if count < 65536 { counts.small += 1 }
            if counts.lastEnd < 0 || offset < counts.lastEnd || offset > counts.lastEnd + 1_048_576 { counts.seeks += 1 }
            counts.lastEnd = offset + Int64(count)
        }
        let data = try await base.read(at: offset, count: count)
        if let throttle { usleep(UInt32(Double(count) / throttle)) }
        return data
    }
}

func mallocInUse() -> Int { var stats = malloc_statistics_t(); malloc_zone_statistics(nil, &stats); return stats.size_in_use }
func seconds(_ d: Duration) -> Double { Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18 }

guard CommandLine.arguments.count == 2 else { print("usage: trace-scan <image>"); exit(2) }
let tracer = Tracer(try ImageFileReader(path: CommandLine.arguments[1]))
let (events, eventsIn) = AsyncStream<ScanEvent>.makeStream(bufferingPolicy: .bufferingOldest(1024))
let (checkpoints, checkpointsIn) = AsyncStream<ScanCheckpoint>.makeStream(bufferingPolicy: .bufferingNewest(1))
let started = ContinuousClock.now
let scan = Task { await ScanSession(reader: tracer).run(events: eventsIn, checkpoints: checkpointsIn) }
let lastCheckpoint = Task { var count = 0, last: ScanCheckpoint?; for await point in checkpoints { count += 1; last = point }; return (count, last) }
let before = mallocInUse()
var kept: [RecoveredFile] = []
var carved = 0, metadataDone: Duration?
for await event in events {
    switch event {
    case .found(let file):
        kept.append(file)
        if file.recoveryMethod == .carved { carved += 1 } else { metadataDone = started.duration(to: .now) }
    case .error(let error): print("scan error: \(error)")
    default: break
    }
}
await scan.value
let wall = started.duration(to: .now)
let held = mallocInUse() - before
let (checkpointCount, last) = await lastCheckpoint.value
let t = tracer.totals
func hdd(_ mbps: Double) -> Double { Double(t.bytes) / (mbps * 1_000_000) + Double(t.seeks) * 0.012 }
print(String(format: "files %d (carved %d), wall %.1f s, metadata files done at %.1f s, %.0f MiB/s",
             kept.count, carved, seconds(wall), metadataDone.map(seconds) ?? 0, Double(t.bytes) / 1_048_576 / seconds(wall)))
print("reads \(t.reads), under 64 KiB \(t.small), seeks \(t.seeks), read \(t.bytes >> 20) MiB of \(tracer.sizeBytes >> 20) MiB")
print("memory held per found file \(held / max(kept.count, 1)) B (\(held >> 20) MiB)")
print("checkpoints \(checkpointCount), last \((try? JSONEncoder().encode(last))?.count ?? 0) B of JSON")
print(String(format: "modelled hard drive: USB 3 %.0f s, USB 2 %.0f s (of which seeks %.0f s)", hdd(130), hdd(35), Double(t.seeks) * 0.012))
