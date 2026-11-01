import Foundation
import Testing
@testable import SalvageCore

/// spec-tech-batch-7 §B: a saved scan reconnects only to a device whose fresh fingerprint equals
/// the one its scan recorded, so the two must be computed the same way.
@Suite("Extent fingerprint")
struct ExtentFingerprintTests {
    @Test func equalsTheFingerprintTheScanRecorded() async throws {
        var image = Data(repeating: 0, count: 512) + exfatImage() + fatImage()
        image.put(446+4, 7, 1); image.put(446+8, 1, 4); image.put(446+12, 128, 4)
        image.put(446+16+4, 0x0c, 1); image.put(446+16+8, 129, 4); image.put(446+16+12, 66560, 4)
        image.put(510, 0xaa55, 2)
        let (stream, events) = AsyncStream<ScanEvent>.makeStream()
        let (checkpointStream, checkpoints) = AsyncStream<ScanCheckpoint>.makeStream()
        await ScanSession(reader: ImageReader(data: image)).run(events: events, checkpoints: checkpoints)
        for await _ in stream {}
        var last: ScanCheckpoint?
        for await point in checkpointStream { last = point }
        let recorded = try #require(last).extents
        #expect(try await ExtentFingerprint.of(ImageReader(data: image)) == recorded)
        #expect(recorded.count == 2)
    }

    @Test func changesWhenTheLayoutChanges() async throws {
        let volume = exfatImage(), padding = Data(repeating: 0, count: 8 * 512)
        func layout(volumeFirst: Bool) -> Data {
            var image = Data(repeating: 0, count: 512) + (volumeFirst ? volume + padding : padding + volume)
            image.put(446+4, 7, 1); image.put(446+8, volumeFirst ? 1 : 9, 4); image.put(446+12, 128, 4)
            image.put(510, 0xaa55, 2)
            return image
        }
        let first = try await ExtentFingerprint.of(ImageReader(data: layout(volumeFirst: true)))
        let moved = try await ExtentFingerprint.of(ImageReader(data: layout(volumeFirst: false)))
        #expect(first != moved)
    }

    // MARK: Resident data located in its MFT record

    /// A 1 KiB FILE record (fixups applied on disk) whose one attribute is an unnamed resident
    /// `$DATA` value placed at record offset `start`.
    func record(valueAt start: Int, value: Data) -> (raw: Data, fixed: Data) {
        var fixed = Data(count: 1024)
        fixed.replaceSubrange(0..<4, with: Data("FILE".utf8))
        fixed.put(4, 0x30, 2); fixed.put(6, 3, 2); fixed.put(0x14, 0x38, 2); fixed.put(0x16, 1, 2)
        let valueOffset = start - 0x38
        let length = (valueOffset + value.count + 7) & ~7
        fixed.put(0x38, 0x80, 4); fixed.put(0x38 + 4, UInt64(length), 4)
        fixed.put(0x38 + 0x10, UInt64(value.count), 4); fixed.put(0x38 + 0x14, UInt64(valueOffset), 2)
        fixed.replaceSubrange(start..<start + value.count, with: value)
        fixed.put(0x38 + length, 0xffff_ffff, 4)
        fixed.put(0x18, UInt64(0x38 + length + 8), 4)
        var raw = fixed
        raw.put(0x30, 0x0102, 2)
        for stride in 1...2 {
            let tail = stride * 512 - 2
            raw.put(0x30 + stride * 2, UInt64(fixed[tail]) | UInt64(fixed[tail + 1]) << 8, 2)
            raw.put(tail, 0x0102, 2)
        }
        fixed.replaceSubrange(0x30..<0x36, with: raw[0x30..<0x36])
        return (raw, fixed)
    }

    @Test(arguments: [(0x60, 100), (0x100, 300), (0x1f8, 420), (0x1ff, 3), (0x200, 20)])
    func residentRunsReadTheFixedUpValueFromTheRawRecord(start: Int, count: Int) throws {
        let value = Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ 1) })
        let (raw, fixed) = record(valueAt: start, value: value)
        var check = raw
        #expect(applyNTFSFixup(&check) && check == fixed)
        let base: Int64 = 1_000_000
        let runs = try #require(NTFSResidentData.runs(inRecord: fixed, at: base))
        var served = Data()
        for run in runs {
            let offset = Int(try #require(run.deviceOffset) - base)
            served += raw[offset..<offset + Int(run.length)]
        }
        #expect(served == value)
        #expect(runs.reduce(0) { $0 + $1.length } == Int64(count))
        let crossesTail = start < 510 && start + count > 510
        if crossesTail { #expect(runs.count == 3) }
    }

    @Test func nonResidentOrDamagedRecordsHaveNoResidentRuns() {
        let (_, fixed) = record(valueAt: 0x60, value: Data(repeating: 1, count: 10))
        var nonResident = fixed; nonResident[0x38 + 8] = 1
        var named = fixed; named[0x38 + 9] = 1
        var notFile = fixed; notFile[0] = 0
        var badArray = fixed; badArray.put(6, 2, 2)
        for record in [nonResident, named, notFile, badArray, fixed.prefix(600), Data()] {
            #expect(NTFSResidentData.runs(inRecord: record, at: 0) == nil)
        }
        #expect(NTFSResidentData.runs(inRecord: fixed, at: -1) == nil)
    }
}
