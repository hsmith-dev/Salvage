import Foundation
import Testing
@testable import SalvageCore

@Suite("File content reader")
struct FileContentReaderTests {
    let device = Data((0..<4096).map { UInt8($0 % 251) })
    func file(_ size: Int64, _ content: FileContent) -> RecoveredFile {
        RecoveredFile(name: "f", path: "/f", sizeBytes: size,
                      sourceMetadata: SourceMetadata(filesystem: .fat32, volumeOffset: 0, recordOffset: 0,
                                                     allocationStart: 0, contiguous: false, rawRecord: Data()),
                      content: content)
    }

    @Test func runsAreReadInFileOrderAndTruncatedToSize() async throws {
        let reader = FileContentReader(reader: ImageReader(data: device), chunkSize: 512)
        let f = file(1300, .runs([DataRun(deviceOffset: 2048, length: 1024), DataRun(deviceOffset: 0, length: 1024)]))
        let bytes = try await reader.prefix(of: f, limit: .max)
        #expect(bytes == device[2048..<3072] + device[0..<276])
    }

    @Test func sparseHolesReadAsZeros() async throws {
        let reader = FileContentReader(reader: ImageReader(data: device))
        let f = file(1536, .runs([DataRun(deviceOffset: 512, length: 512), DataRun(deviceOffset: nil, length: 512),
                                  DataRun(deviceOffset: 0, length: 512)]))
        let bytes = try await reader.prefix(of: f, limit: .max)
        #expect(bytes == device[512..<1024] + Data(count: 512) + device[0..<512])
    }

    @Test func residentDataAndPrefixLimit() async throws {
        let reader = FileContentReader(reader: ImageReader(data: device))
        #expect(try await reader.prefix(of: file(5, .resident(Data("hello!".utf8))), limit: .max) == Data("hello".utf8))
        let f = file(3000, .runs([DataRun(deviceOffset: 0, length: 4096)]))
        #expect(try await reader.prefix(of: f, limit: 100) == device[0..<100])
    }

    @Test(arguments: [
        FileContent.unmapped,
        .runs([DataRun(deviceOffset: 0, length: 100)]),
        .runs([DataRun(deviceOffset: 4000, length: 512)]),
        .runs([DataRun(deviceOffset: -1, length: 512)]),
        .resident(Data(count: 10)),
    ]) func invalidMappingsAreRefused(_ content: FileContent) async {
        let reader = FileContentReader(reader: ImageReader(data: device))
        await #expect(throws: (any Error).self) { _ = try await reader.prefix(of: file(512, content), limit: .max) }
    }

    /// 10 GiB of mapped content, consumed slowly: the reader must only touch the device when the
    /// consumer asks for the next chunk, never race ahead of it.
    @Test func mappedChunksAreReadOnlyOnDemand() async throws {
        let device = CountingReader(sizeBytes: 10 << 30)
        let reader = FileContentReader(reader: device, chunkSize: 4096)
        let f = file(10 << 30, .runs([DataRun(deviceOffset: 0, length: 10 << 30)]))
        var iterator = reader.chunks(of: f).makeAsyncIterator()
        for consumed in 1...5 {
            let chunk = try await iterator.next()
            #expect(chunk?.count == 4096)
            try await Task.sleep(for: .milliseconds(20))
            #expect(device.reads <= consumed + Self.maxAhead, "read \(device.reads) chunks for \(consumed) consumed")
        }
    }

    /// A 10 GiB sparse hole, consumed slowly: zero chunks are produced one per `next()`.
    @Test func sparseHolesAreProducedLazily() async throws {
        let produced = ChunkCounter()
        var reader = FileContentReader(reader: ImageReader(data: device), chunkSize: 4096)
        reader.chunkObserver = { produced.increment() }
        let f = file(10 << 30, .runs([DataRun(deviceOffset: nil, length: 10 << 30)]))
        var iterator = reader.chunks(of: f).makeAsyncIterator()
        for consumed in 1...5 {
            let chunk = try await iterator.next()
            #expect(chunk == Data(count: 4096))
            try await Task.sleep(for: .milliseconds(20))
            #expect(produced.value <= consumed + Self.maxAhead, "produced \(produced.value) chunks for \(consumed) consumed")
        }
    }

    @Test func iterationEndsAndRestartsCleanly() async throws {
        let reader = FileContentReader(reader: ImageReader(data: device), chunkSize: 512)
        let f = file(1100, .runs([DataRun(deviceOffset: 0, length: 600), DataRun(deviceOffset: nil, length: 600)]))
        let sequence = reader.chunks(of: f)
        var sizes: [Int] = []
        for try await chunk in sequence { sizes.append(chunk.count) }
        #expect(sizes == [512, 88, 500])
        var again = Data()
        for try await chunk in sequence { again.append(chunk) }
        #expect(again == device[0..<600] + Data(count: 500))
        var iterator = sequence.makeAsyncIterator()
        while try await iterator.next() != nil {}
        #expect(try await iterator.next() == nil)
    }

    /// At most this many chunks may exist ahead of the consumer.
    static let maxAhead = 1
}

/// A device of any size that returns zeros and counts reads.
private final class CountingReader: BlockReader, @unchecked Sendable {
    let sizeBytes: Int64
    private let lock = NSLock()
    private var count = 0
    init(sizeBytes: Int64) { self.sizeBytes = sizeBytes }
    var reads: Int { lock.withLock { count } }
    func read(at offset: Int64, count: Int) async throws -> Data {
        lock.withLock { self.count += 1 }
        return Data(count: count)
    }
}

private final class ChunkCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
