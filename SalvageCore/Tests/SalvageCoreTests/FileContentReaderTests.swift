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
}
