import Foundation
import SalvageCore
import Testing
@testable import SalvageDiskIO

// Story 2.4: pure interpretation of `diskutil apfs list -plist` and the Device Picker's "Locked"
// annotation, against fabricated plists shaped like the spike's real output.

private let secretUUID = "34CFAFFA-3ECE-46A6-937D-93E622EAA34B"

private func secondContainer(locked: Bool) -> [String: Any] {
    ["ContainerReference": "disk21",
     "PhysicalStores": [["DeviceIdentifier": "disk20s2"]],
     "Volumes": [["APFSVolumeUUID": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE", "DeviceIdentifier": "disk21s1", "Name": "Vault",
                  "Encryption": true, "Locked": locked]]]
}

@Suite("APFS volume listing")
struct APFSVolumeListingTests {
    @Test func decodesContainersStoresAndVolumes() throws {
        let containers = try #require(apfsContainers(fromListPlist: sampleListPlist()))
        #expect(containers.count == 1)
        let container = containers[0]
        #expect(container.reference == "disk19")
        #expect(container.physicalStoreWholeDisks == ["disk18"])
        #expect(container.volumes == [
            APFSListedVolume(uuid: "C4B7686F-BBB2-4B3E-813B-94F5A1AD9C28", bsdName: "disk19s1", name: "SpikePlain", isEncrypted: false, isLocked: false),
            APFSListedVolume(uuid: secretUUID, bsdName: "disk19s2", name: "Secret", isEncrypted: true, isLocked: true),
        ])
        // Missing optional fields default to "not encrypted, not locked"; the name may be absent.
        let sparse = try #require(apfsContainers(fromListPlist: ["Containers": [["Volumes": [["APFSVolumeUUID": secretUUID, "DeviceIdentifier": "disk5s1"]]]]]))
        #expect(sparse == [APFSListedContainer(reference: nil, physicalStoreWholeDisks: [],
                                               volumes: [APFSListedVolume(uuid: secretUUID, bsdName: "disk5s1", name: nil, isEncrypted: false, isLocked: false)])])
        #expect(apfsContainers(fromListPlist: ["Containers": []]) == [])
    }

    @Test func malformedListingsAreRefused() {
        #expect(apfsContainers(fromListPlist: [:]) == nil)
        #expect(apfsContainers(fromListPlist: ["Containers": "disk19"]) == nil)
        var missingUUID = sampleListPlist()
        var containers = missingUUID["Containers"] as! [[String: Any]]
        var volumes = containers[0]["Volumes"] as! [[String: Any]]
        volumes[1]["APFSVolumeUUID"] = "not-a-uuid"
        containers[0]["Volumes"] = volumes
        missingUUID["Containers"] = containers
        #expect(apfsContainers(fromListPlist: missingUUID) == nil)
        volumes[1]["APFSVolumeUUID"] = secretUUID
        volumes[1]["DeviceIdentifier"] = "/dev/disk19s2"
        containers[0]["Volumes"] = volumes
        missingUUID["Containers"] = containers
        #expect(apfsContainers(fromListPlist: missingUUID) == nil)
        containers[0]["Volumes"] = sampleListPlist()["Containers"].flatMap { ($0 as? [[String: Any]])?[0]["Volumes"] }
        containers[0]["PhysicalStores"] = [["DeviceIdentifier": "garbage"]]
        missingUUID["Containers"] = containers
        #expect(apfsContainers(fromListPlist: missingUUID) == nil)
    }

    @Test func volumeLookupIgnoresCase() throws {
        let containers = try #require(apfsContainers(fromListPlist: sampleListPlist()))
        #expect(apfsVolume(uuid: secretUUID.lowercased(), in: containers)?.bsdName == "disk19s2")
        #expect(apfsVolume(uuid: secretUUID, in: containers)?.name == "Secret")
        #expect(apfsVolume(uuid: "11111111-2222-3333-4444-555555555555", in: containers) == nil)
    }

    @Test func lockedStateNeedsEveryVolumeLocked() throws {
        var plist = sampleListPlist()
        plist["Containers"] = (plist["Containers"] as! [[String: Any]]) + [secondContainer(locked: true)]
        let containers = try #require(apfsContainers(fromListPlist: plist))
        // disk18/disk19: a plain unlocked volume sits next to the locked one.
        #expect(lockedVolume(onWholeDisk: "disk18", containers: containers) == nil)
        #expect(lockedVolume(onWholeDisk: "disk19", containers: containers) == nil)
        // disk20/disk21: the only volume is locked; both the store and the container disk count.
        #expect(lockedVolume(onWholeDisk: "disk20", containers: containers)?.bsdName == "disk21s1")
        #expect(lockedVolume(onWholeDisk: "disk21", containers: containers)?.uuid == "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
        // No container at all, or a container with no volumes, is not "locked".
        #expect(lockedVolume(onWholeDisk: "disk7", containers: containers) == nil)
        #expect(lockedVolume(onWholeDisk: "disk21", containers: [APFSListedContainer(reference: "disk21", physicalStoreWholeDisks: [], volumes: [])]) == nil)
        // A disk backing two containers is locked only if every volume of both is.
        let twoContainers = [
            APFSListedContainer(reference: "disk21", physicalStoreWholeDisks: ["disk20"], volumes: containers[1].volumes),
            APFSListedContainer(reference: "disk22", physicalStoreWholeDisks: ["disk20"], volumes: containers[0].volumes),
        ]
        #expect(lockedVolume(onWholeDisk: "disk20", containers: twoContainers) == nil)
    }

    @Test(arguments: ["34CFAFFA-3ECE-46A6-937D-93E622EAA34B", "34cfaffa-3ece-46a6-937d-93e622eaa34b", "00000000-0000-0000-0000-000000000000"])
    func uuidShapeIsAccepted(_ value: String) { #expect(isAPFSVolumeUUID(value)) }

    @Test(arguments: ["", "34CFAFFA3ECE46A6937D93E622EAA34B", "34CFAFFA-3ECE-46A6-937D-93E622EAA34", "34CFAFFA-3ECE-46A6-937D-93E622EAA34BB",
                      "34CFAFFA_3ECE-46A6-937D-93E622EAA34B", "34CFAFFA-3ECE-46A6-937D-93E622EAA34G", "-nomount", "disk19s2",
                      "34CFAFFA-3ECE-46A6-937D-93E622EAA34B\n", "\u{0663}4CFAFFA-3ECE-46A6-937D-93E622EAA34B"])
    func everythingElseIsRefused(_ value: String) { #expect(!isAPFSVolumeUUID(value)) }

    @Test func annotationMarksOnlyFullyLockedNonBootDevices() throws {
        var plist = sampleListPlist()
        plist["Containers"] = (plist["Containers"] as! [[String: Any]]) + [secondContainer(locked: true)]
        let containers = try #require(apfsContainers(fromListPlist: plist))
        let boot = BlockDevice(bsdName: "disk20", displayName: "Boot", sizeBytes: 1, isInternal: true, isBootVolume: true, mediaIdentity: 1)
        let mixed = BlockDevice(bsdName: "disk18", displayName: "Image", sizeBytes: 2, isInternal: false, isBootVolume: false, mediaIdentity: 2)
        let locked = BlockDevice(bsdName: "disk21", displayName: "Vault disk", sizeBytes: 3, isInternal: false, isBootVolume: false, mediaIdentity: 3)
        let other = BlockDevice(bsdName: "disk9", displayName: "FAT stick", sizeBytes: 4, isInternal: false, isBootVolume: false, mediaIdentity: 4)
        let annotated = annotateLocked([boot, mixed, locked, other], containers: containers)
        #expect(annotated[0] == boot)
        #expect(annotated[1] == mixed)
        #expect(annotated[2] == locked.requiringUnlock(volumeUUID: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE", volumeName: "Vault"))
        #expect(annotated[2].mediaIdentity == 3 && annotated[2].sizeBytes == 3)
        #expect(annotated[3] == other)
        // Re-annotating an annotated set changes nothing.
        #expect(annotateLocked(annotated, containers: containers) == annotated)
        #expect(annotateLocked([boot, mixed, locked, other], containers: []) == [boot, mixed, locked, other])
    }
}
