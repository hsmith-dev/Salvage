import Darwin
import Foundation
import SalvageCore
import Testing
@testable import SalvageDiskIO

// Story 3.4: nothing may ever write to a source disk, least of all its partition table. The only
// output of lost-partition recovery is file copies through the recovery flow.
//
// The probe protocol below declares a `write` requirement with a default implementation that
// records being called. Conforming `RawBlockReader` to it retroactively makes the compiler pick the
// type's own `write(_:at:)` as the witness if one exists; the default runs only when the type
// declares none. This is a type-level check of the shipped DiskIO conformer, not a grep.
private protocol SourceWriteProbe {
    func write(_ data: Data, at offset: Int64) async throws
}
private extension SourceWriteProbe {
    func write(_ data: Data, at offset: Int64) async throws { await ProbeLog.shared.markDefaultWitness() }
}
extension RawBlockReader: SourceWriteProbe {}

private actor ProbeLog {
    static let shared = ProbeLog()
    private(set) var defaultWitnessCalls = 0
    func markDefaultWitness() { defaultWitnessCalls += 1 }
}

/// Opens `/dev/null` read-only in place of a device, so no real disk is touched.
private actor NullDeviceOperations: RawDeviceOperations {
    static let identity = RawDeviceIdentity(registryID: 7, sizeBytes: 65536, blockSize: 512, deviceNumber: 42)
    func protectedDisks() async throws -> Set<String> { ["disk0"] }
    func identity(_ name: String) async throws -> RawDeviceIdentity { Self.identity }
    func mountSources() async throws -> [String] { [] }
    nonisolated func ancestorWholeDisks(ofMediaNamed name: String) -> Set<String>? { [] }
    func unmount(_ name: String) async throws {}
    func openReadOnly(_ name: String, expected: RawDeviceIdentity) async throws -> Int32 { open("/dev/null", O_RDONLY) }
    func closeDescriptor(_ descriptor: Int32) async { _ = close(descriptor) }
}

@Suite("Source devices are read-only (Story 3.4)", .serialized)
struct ReadOnlySourceTests {
    @Test func diskIOBlockReaderExposesNoWriteMethod() async throws {
        let device = BlockDevice(bsdName: "disk42", displayName: "Fixture", sizeBytes: 65536,
                                 isInternal: false, isBootVolume: false, mediaIdentity: 7)
        let reader = try await RawBlockReader.prepare(device: device, operations: NullDeviceOperations(),
                                                      reservations: DeviceReadReservations())
        let before = await ProbeLog.shared.defaultWitnessCalls
        try await (reader as any SourceWriteProbe).write(Data([0x55, 0xaa]), at: 510)
        let after = await ProbeLog.shared.defaultWitnessCalls
        #expect(after == before + 1, "RawBlockReader must not declare a write(_:at:) method")
        await reader.close()
    }

    @Test func blockReaderPortIsReadOnly() async throws {
        // The Core port that every adapter satisfies has exactly one I/O requirement: `read`. A
        // conformer declaring nothing else compiles, and the probe's default `write` is its witness
        // too, so the port itself contributes no write method that an adapter could be reached through.
        struct ReadOnly: BlockReader, SourceWriteProbe {
            let sizeBytes: Int64 = 512
            func read(at offset: Int64, count: Int) async throws -> Data { Data(count: count) }
        }
        let reader: any BlockReader = ReadOnly()
        #expect(try await reader.read(at: 0, count: 4) == Data(count: 4))
        let before = await ProbeLog.shared.defaultWitnessCalls
        try await (reader as? any SourceWriteProbe)?.write(Data([0]), at: 0)
        #expect(await ProbeLog.shared.defaultWitnessCalls == before + 1)
    }
}
