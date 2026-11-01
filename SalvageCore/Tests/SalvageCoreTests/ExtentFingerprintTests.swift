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
}
