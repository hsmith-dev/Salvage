import Foundation
import Testing

@testable import SalvageDiskIO

// Ported from Story 1.2's spike harness test target
// (scripts/spike-raw-device-access/Tests/spike-raw-device-accessTests/SpikeHarnessTests.swift),
// adapted only to `@testable import SalvageDiskIO` instead of the spike's executable target --
// same assertions, same meaning, per spec-1-3's acceptance criteria.

@Suite("wholeDiskBSDName")
struct WholeDiskBSDNameTests {
    @Test("valid raw and buffered device paths", arguments: [
        ("/dev/rdisk6", "disk6"),
        ("/dev/rdisk6s1", "disk6"),
        ("/dev/disk6", "disk6"),
        ("/dev/disk3s1s1", "disk3"),
        ("disk0s2", "disk0"),
        ("disk0", "disk0"),
        ("rdisk12", "disk12"),
    ])
    func validInputs(path: String, expected: String) {
        #expect(wholeDiskBSDName(fromDevicePath: path) == expected)
    }

    @Test("inputs that must fail clearly, never resolve to a guessed disk", arguments: [
        "",
        "/dev/r",
        "/dev/disk",
        "/dev/rfoo",
        "nodisk3",
        "/dev/notadisk6",
        "r",
    ])
    func invalidInputs(path: String) {
        #expect(wholeDiskBSDName(fromDevicePath: path) == nil)
    }
}

@Suite("isWithinBootDiskSet")
struct BootDiskMembershipTests {
    let bootDisks: Set<String> = ["disk0", "disk3"]

    @Test("boot disks are matched")
    func matchesBootDisk() {
        #expect(isWithinBootDiskSet("disk0", bootDisks: bootDisks))
        #expect(isWithinBootDiskSet("disk3", bootDisks: bootDisks))
    }

    @Test("non-boot disks are not matched")
    func doesNotMatchNonBootDisk() {
        #expect(!isWithinBootDiskSet("disk6", bootDisks: bootDisks))
        #expect(!isWithinBootDiskSet("disk1", bootDisks: bootDisks))
    }

    @Test("empty boot disk set matches nothing")
    func emptySetMatchesNothing() {
        #expect(!isWithinBootDiskSet("disk0", bootDisks: []))
    }
}

@Suite("physicalWholeDisks(fromDiskUtilInfoPlist:)")
struct PhysicalWholeDisksTests {
    @Test("APFS container resolves to its physical store's whole disk")
    func apfsContainerResolvesToPhysicalStore() {
        let plist: [String: Any] = [
            "APFSPhysicalStores": [
                ["APFSPhysicalStore": "disk0s2"]
            ],
            "WholeDisk": true,
        ]
        #expect(physicalWholeDisks(fromDiskUtilInfoPlist: plist, bsdName: "disk3") == ["disk0"])
    }

    @Test("multiple physical stores (e.g. a Fusion-style container) all resolve")
    func multiplePhysicalStoresAllResolve() {
        let plist: [String: Any] = [
            "APFSPhysicalStores": [
                ["APFSPhysicalStore": "disk0s2"],
                ["APFSPhysicalStore": "disk1s2"],
            ]
        ]
        #expect(physicalWholeDisks(fromDiskUtilInfoPlist: plist, bsdName: "disk5") == ["disk0", "disk1"])
    }

    @Test("a plain physical whole disk resolves to itself")
    func plainWholeDiskResolvesToItself() {
        let plist: [String: Any] = ["WholeDisk": true, "ParentWholeDisk": "disk0"]
        #expect(physicalWholeDisks(fromDiskUtilInfoPlist: plist, bsdName: "disk0") == ["disk0"])
    }

    @Test("falls back to ParentWholeDisk when not itself whole")
    func fallsBackToParentWholeDisk() {
        let plist: [String: Any] = ["WholeDisk": false, "ParentWholeDisk": "disk6"]
        #expect(physicalWholeDisks(fromDiskUtilInfoPlist: plist, bsdName: "disk6s1") == ["disk6"])
    }

    @Test("an unparseable physical store entry fails closed (nil), not a partial guess")
    func unparseableStoreFailsClosed() {
        let plist: [String: Any] = [
            "APFSPhysicalStores": [
                ["somethingElse": "nope"]
            ]
        ]
        #expect(physicalWholeDisks(fromDiskUtilInfoPlist: plist, bsdName: "disk3") == nil)
    }

    @Test("a malformed ParentWholeDisk fails closed (nil), never a trusted disk name", arguments: [
        "foo", "", "/dev/disk", "nodisk3", "/dev/rfoo", "r",
    ])
    func malformedParentWholeDiskFailsClosed(parent: String) {
        let plist: [String: Any] = ["WholeDisk": false, "ParentWholeDisk": parent]
        #expect(physicalWholeDisks(fromDiskUtilInfoPlist: plist, bsdName: "disk6s1") == nil)
    }

    @Test("a non-string ParentWholeDisk fails closed (nil)")
    func nonStringParentWholeDiskFailsClosed() {
        let plist: [String: Any] = ["WholeDisk": false, "ParentWholeDisk": 6]
        #expect(physicalWholeDisks(fromDiskUtilInfoPlist: plist, bsdName: "disk6s1") == nil)
    }

    @Test("a slice-shaped ParentWholeDisk is reduced to its whole disk, never passed through raw")
    func sliceParentWholeDiskIsNormalized() {
        // Current semantics: the shared chokepoint strips the slice suffix, so "disk6s2" protects
        // the whole physical disk6 rather than trusting the slice name as a whole-disk name.
        let plist: [String: Any] = ["WholeDisk": false, "ParentWholeDisk": "disk6s2"]
        #expect(physicalWholeDisks(fromDiskUtilInfoPlist: plist, bsdName: "disk6s1") == ["disk6"])
    }

    @Test("a hung metadata subprocess is terminated and fails closed within the deadline")
    func hungSubprocessTimesOut() {
        let started = Date()
        let result = plistFromProcess(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], timeout: 0.5)
        #expect(result == nil)
        #expect(Date().timeIntervalSince(started) < 10)
    }

    @Test("heavy stderr output cannot wedge the subprocess, and stdout still decodes")
    func noisyStderrDoesNotDeadlock() {
        let plist = #"<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>WholeDisk</key><true/></dict></plist>"#
        // 1 MiB of stderr overflows any pipe buffer; an undrained stderr pipe would block the child.
        let script = "head -c 1048576 /dev/zero >&2; printf '%s' '\(plist)'"
        let result = plistFromProcess(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script], timeout: 10)
        #expect(result?["WholeDisk"] as? Bool == true)
    }

    @Test("a failing subprocess fails closed (nil)")
    func failingSubprocessFailsClosed() {
        #expect(plistFromProcess(executable: URL(fileURLWithPath: "/usr/bin/false"), arguments: [], timeout: 5) == nil)
        #expect(plistFromProcess(executable: URL(fileURLWithPath: "/nonexistent/tool"), arguments: [], timeout: 5) == nil)
    }

    @Test("no usable key at all fails closed (nil)")
    func noUsableKeyFailsClosed() {
        let plist: [String: Any] = ["SomeUnrelatedKey": 1]
        #expect(physicalWholeDisks(fromDiskUtilInfoPlist: plist, bsdName: "disk3") == nil)
    }
}
