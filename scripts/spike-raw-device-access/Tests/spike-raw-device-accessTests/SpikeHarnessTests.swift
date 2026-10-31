import Testing

@testable import spike_raw_device_access

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

    @Test("no usable key at all fails closed (nil)")
    func noUsableKeyFailsClosed() {
        let plist: [String: Any] = ["SomeUnrelatedKey": 1]
        #expect(physicalWholeDisks(fromDiskUtilInfoPlist: plist, bsdName: "disk3") == nil)
    }
}

@Suite("parseArguments")
struct ParseArgumentsTests {
    @Test("no arguments is a usage error")
    func noArguments() {
        #expect(parseArguments([]) == .usageError(message: "no arguments given"))
    }

    @Test("--help and -h")
    func help() {
        #expect(parseArguments(["--help"]) == .help(exitCode: 0))
        #expect(parseArguments(["-h"]) == .help(exitCode: 0))
    }

    @Test("--list with no extra arguments")
    func list() {
        #expect(parseArguments(["--list"]) == .list)
    }

    @Test("--list rejects trailing arguments")
    func listRejectsTrailingArguments() {
        #expect(parseArguments(["--list", "extra"]) == .usageError(message: "--list takes no further arguments (got: extra)"))
    }

    @Test("--read with a path")
    func readWithPath() {
        #expect(parseArguments(["--read", "/dev/rdisk6"]) == .read(path: "/dev/rdisk6", skipUnmount: false))
    }

    @Test("--read with a path and --no-unmount")
    func readWithPathAndNoUnmount() {
        #expect(parseArguments(["--read", "/dev/rdisk6", "--no-unmount"]) == .read(path: "/dev/rdisk6", skipUnmount: true))
    }

    @Test("--read with no path at all is a usage error")
    func readWithNoPath() {
        #expect(parseArguments(["--read"]) == .usageError(message: "--read requires a device path, e.g. --read /dev/rdisk6 (got: nothing)"))
    }

    @Test("--read --no-unmount with the path omitted must not misparse --no-unmount as the path")
    func readWithOnlyNoUnmountFlag() {
        #expect(parseArguments(["--read", "--no-unmount"]) == .usageError(message: "--read requires a device path, e.g. --read /dev/rdisk6 (got: --no-unmount)"))
    }

    @Test("--read with an unrecognized trailing argument")
    func readWithUnrecognizedTrailingArgument() {
        #expect(parseArguments(["--read", "/dev/rdisk6", "--bogus"]) == .usageError(message: "unrecognized argument(s) after --read <path>: --bogus"))
    }

    @Test("unrecognized top-level argument")
    func unrecognizedArgument() {
        #expect(parseArguments(["--bogus"]) == .usageError(message: "unrecognized argument \"--bogus\""))
    }
}
