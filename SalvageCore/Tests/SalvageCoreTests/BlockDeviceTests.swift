import Testing
@testable import SalvageCore

@Suite("BlockDevice")
struct BlockDeviceTests {
    private func makeDevice(
        bsdName: String = "disk6",
        displayName: String = "External SSD",
        sizeBytes: Int64 = 1_000_000_000,
        isInternal: Bool = false,
        isBootVolume: Bool = false
    ) -> BlockDevice {
        BlockDevice(
            bsdName: bsdName,
            displayName: displayName,
            sizeBytes: sizeBytes,
            isInternal: isInternal,
            isBootVolume: isBootVolume
        )
    }

    @Test("id mirrors bsdName")
    func idMirrorsBSDName() {
        #expect(makeDevice(bsdName: "disk6").id == "disk6")
    }

    @Test("equal field values compare equal")
    func equatableEqualValues() {
        #expect(makeDevice() == makeDevice())
    }

    @Test("a differing bsdName compares unequal")
    func equatableDiffersOnBSDName() {
        #expect(makeDevice(bsdName: "disk6") != makeDevice(bsdName: "disk7"))
    }

    @Test("a differing displayName compares unequal")
    func equatableDiffersOnDisplayName() {
        #expect(makeDevice(displayName: "External SSD") != makeDevice(displayName: "Other Name"))
    }

    @Test("a differing sizeBytes compares unequal")
    func equatableDiffersOnSizeBytes() {
        #expect(makeDevice(sizeBytes: 1) != makeDevice(sizeBytes: 2))
    }

    @Test("a differing isInternal compares unequal")
    func equatableDiffersOnIsInternal() {
        #expect(makeDevice(isInternal: false) != makeDevice(isInternal: true))
    }

    @Test("a differing isBootVolume compares unequal")
    func equatableDiffersOnIsBootVolume() {
        #expect(makeDevice(isBootVolume: false) != makeDevice(isBootVolume: true))
    }

    @Test("distinct devices in a collection keep distinct identity")
    func identifiableDistinctIDs() {
        let devices = [
            makeDevice(bsdName: "disk0", displayName: "Boot Disk", isInternal: true, isBootVolume: true),
            makeDevice(bsdName: "disk6", displayName: "External SSD"),
        ]
        #expect(Set(devices.map(\.id)).count == devices.count)
    }
}
