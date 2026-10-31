import Darwin
import Foundation
import SalvageCore
import Testing
import XPC
@testable import SalvageDiskIO

// Story 1.12: the privileged helper's request validation (shared HelperShared/ code the helper
// compiles), RawBlockReader's EACCES -> helper fallback, and the approval guidance.

@Suite("Helper request validation")
struct HelperRequestValidationTests {
    @Test(arguments: ["disk0", "disk4", "disk12", "disk999999"])
    func wholeDiskNamesAreAccepted(_ name: String) { #expect(isWholeDiskBSDName(name)) }

    @Test(arguments: ["", "disk", "disk01", "disk4s1", "rdisk4", "/dev/rdisk4", "disk4 ", " disk4", "Disk4",
                      "disk\u{0663}", "disk4\u{0}", "disk1234567", "disk-1", "disk4/../disk0", "../disk4"])
    func everythingElseIsRefused(_ name: String) { #expect(!isWholeDiskBSDName(name)) }

    private func validate(keyCount: Int = 5, version: Int64 = 1, operation: String? = "openWholeDiskReadOnly",
                          name: String? = "disk4", registryID: UInt64 = 77, deviceNumber: Int64 = 0x0100_0004) -> Result<PrivilegedOpenRequest, PrivilegedOpenRefusal> {
        validatePrivilegedOpenRequest(keyCount: keyCount, version: version, operation: operation, bsdName: name,
                                      registryID: registryID, deviceNumber: deviceNumber)
    }

    @Test func wellFormedRequestValidates() {
        #expect(validate() == .success(PrivilegedOpenRequest(bsdName: "disk4", registryID: 77, deviceNumber: 0x0100_0004)))
    }

    @Test func malformedRequestsAreRefused() {
        #expect(validate(keyCount: 6) == .failure(.malformedRequest))
        #expect(validate(keyCount: 4) == .failure(.malformedRequest))
        #expect(validate(version: 2) == .failure(.malformedRequest))
        #expect(validate(operation: nil) == .failure(.malformedRequest))
        #expect(validate(operation: "write") == .failure(.malformedRequest))
        #expect(validate(name: nil) == .failure(.malformedRequest))
        #expect(validate(registryID: 0) == .failure(.malformedRequest))
        #expect(validate(deviceNumber: Int64(Int32.max) + 1) == .failure(.malformedRequest))
        #expect(validate(deviceNumber: Int64(Int32.min) - 1) == .failure(.malformedRequest))
    }

    @Test(arguments: ["disk4s1", "rdisk4", "/dev/rdisk4", "disk0 ", ""])
    func nonWholeDiskNamesAreRefused(_ name: String) {
        #expect(validate(name: name) == .failure(.notWholeDisk))
    }

    @Test func protectedSetIncludesContainerAndPhysicalStores() {
        #expect(protectedBootDisks(containerWholeDisk: "disk3", ancestorMediaBSDNames: ["disk0s2", "disk0"]) == ["disk3", "disk0"])
        // A multi-store (Fusion) container protects every store.
        #expect(protectedBootDisks(containerWholeDisk: "disk3", ancestorMediaBSDNames: ["disk0s2", "disk0", "disk1s2", "disk1"]) == ["disk3", "disk0", "disk1"])
    }

    @Test func protectedSetFailsClosed() {
        #expect(protectedBootDisks(containerWholeDisk: nil, ancestorMediaBSDNames: ["disk0"]) == nil)
        #expect(protectedBootDisks(containerWholeDisk: "disk3", ancestorMediaBSDNames: nil) == nil)
        #expect(protectedBootDisks(containerWholeDisk: "disk3", ancestorMediaBSDNames: []) == nil)
        #expect(protectedBootDisks(containerWholeDisk: "disk3s1", ancestorMediaBSDNames: ["disk0"]) == nil)
        #expect(protectedBootDisks(containerWholeDisk: "disk3", ancestorMediaBSDNames: ["garbage"]) == nil)
    }

    @Test func bootRefusal() {
        let protected: Set<String> = ["disk3", "disk0"]
        #expect(bootDiskRefusal(requested: "disk0", requestedAncestorWholeDisks: [], protected: protected) == .bootDisk)
        #expect(bootDiskRefusal(requested: "disk3", requestedAncestorWholeDisks: ["disk0"], protected: protected) == .bootDisk)
        // Another container synthesized from the internal SSD (e.g. Recovery) is refused too.
        #expect(bootDiskRefusal(requested: "disk1", requestedAncestorWholeDisks: ["disk0"], protected: protected) == .bootDisk)
        #expect(bootDiskRefusal(requested: "disk6", requestedAncestorWholeDisks: [], protected: protected) == nil)
        #expect(bootDiskRefusal(requested: "disk7", requestedAncestorWholeDisks: ["disk6"], protected: protected) == nil)
        #expect(bootDiskRefusal(requested: "disk6", requestedAncestorWholeDisks: [], protected: nil) == .bootDiskUnresolved)
        #expect(bootDiskRefusal(requested: "disk6", requestedAncestorWholeDisks: [], protected: []) == .bootDiskUnresolved)
    }

    @Test func fstatCheckRequiresMatchingCharacterDevice() throws {
        var null = stat()
        #expect(stat("/dev/null", &null) == 0)
        #expect(isExpectedCharacterDevice(mode: null.st_mode, rdev: null.st_rdev, expected: null.st_rdev))
        #expect(!isExpectedCharacterDevice(mode: null.st_mode, rdev: null.st_rdev, expected: null.st_rdev &+ 1))
        let file = try TemporaryFile()
        defer { unlink(file.path) }
        var regular = stat()
        #expect(stat(file.path, &regular) == 0)
        #expect(!isExpectedCharacterDevice(mode: regular.st_mode, rdev: regular.st_rdev, expected: regular.st_rdev))
        #expect(!isExpectedCharacterDevice(mode: S_IFBLK | 0o640, rdev: 5, expected: 5))
    }

    @Test func mediaMustBeWholeWithMatchingMajorMinor() {
        let rdev = dev_t(bitPattern: (UInt32(1) << 24) | 4)
        #expect(mediaMatchesDeviceNumber(isWhole: true, major: 1, minor: 4, deviceNumber: rdev))
        #expect(!mediaMatchesDeviceNumber(isWhole: false, major: 1, minor: 4, deviceNumber: rdev))
        #expect(!mediaMatchesDeviceNumber(isWhole: true, major: 1, minor: 5, deviceNumber: rdev))
        #expect(!mediaMatchesDeviceNumber(isWhole: true, major: 2, minor: 4, deviceNumber: rdev))
        #expect(!mediaMatchesDeviceNumber(isWhole: true, major: -1, minor: 4, deviceNumber: rdev))
    }

    @Test func mountedDetection() {
        let noAncestry: (String) -> Set<String>? = { _ in [] }
        #expect(isMounted("disk4", sources: ["/dev/disk4s1"], ancestorWholeDisks: noAncestry))
        #expect(isMounted("disk4", sources: ["/dev/rdisk4"], ancestorWholeDisks: noAncestry))
        #expect(!isMounted("disk4", sources: ["/dev/disk40s1", "devfs", "map auto_home"], ancestorWholeDisks: noAncestry))
    }

    /// An APFS volume of a container synthesized from disk4s1 (disk5s1) keeps disk4 in use even
    /// though no mount source names disk4.
    @Test func apfsVolumeOnASynthesizedContainerCountsAsMounted() {
        let ancestry: [String: Set<String>] = ["disk5s1": ["disk5", "disk4"], "disk0s1": [], "disk3s1s1": ["disk3", "disk0"]]
        let lookup: (String) -> Set<String>? = { ancestry[$0] }
        #expect(isMounted("disk4", sources: ["/dev/disk3s1s1", "devfs", "/dev/disk5s1"], ancestorWholeDisks: lookup))
        #expect(isMounted("disk4", sources: ["com.apple.os.update-1@/dev/disk5s1"], ancestorWholeDisks: lookup))
        #expect(isMounted("disk5", sources: ["/dev/disk5s1"], ancestorWholeDisks: lookup))
        #expect(!isMounted("disk6", sources: ["/dev/disk5s1", "/dev/disk0s1", "/dev/disk3s1s1"], ancestorWholeDisks: lookup))
        // A disk-node source whose ancestry can't be resolved fails closed.
        #expect(isMounted("disk6", sources: ["/dev/disk9s1"], ancestorWholeDisks: lookup))
        // Non-disk sources are never looked up.
        #expect(!isMounted("disk6", sources: ["devfs", "map auto_home", "server:/export/disk5", "//u@host/disk5"],
                           ancestorWholeDisks: { _ in nil }))
    }

    @Test func mountSourceMediaNames() {
        #expect(mountSourceMediaName("/dev/disk5s1") == "disk5s1")
        #expect(mountSourceMediaName("/dev/rdisk5s1") == "disk5s1")
        #expect(mountSourceMediaName("disk3s1s1") == "disk3s1s1")
        #expect(mountSourceMediaName("com.apple.os.update-ABC@/dev/disk3s1s1") == "disk3s1s1")
        for other in ["devfs", "map auto_home", "server:/export/disk5", "/dev/disk5s", "/dev/disks1", "/dev/disk5s1/x", "/dev/fd"] {
            #expect(mountSourceMediaName(other) == nil, "\(other)")
        }
    }

    @Test func strictCodeSigningRequirementDemandsDeveloperID() {
        #expect(codeSigningRequirement(identifier: "dev.hsmith.Salvage", teamID: "AB12CD34EF", allowDevelopmentCertificates: false)
            == #"anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "AB12CD34EF" and identifier "dev.hsmith.Salvage""#)
    }

    @Test func developmentCodeSigningRequirementPinsIdentifierAppleAnchorAndTeam() {
        #expect(codeSigningRequirement(identifier: "dev.hsmith.Salvage", teamID: "AB12CD34EF", allowDevelopmentCertificates: true)
            == #"identifier "dev.hsmith.Salvage" and anchor apple generic and certificate leaf[subject.OU] = "AB12CD34EF""#)
    }

    /// Development signing is a debug-build-only relaxation; a release build is always strict.
    @Test func signingModeFollowsBuildConfiguration() {
        #if DEBUG
        #expect(PrivilegedOpenProtocol.allowsDevelopmentSigning)
        #else
        #expect(!PrivilegedOpenProtocol.allowsDevelopmentSigning)
        #endif
    }

    @Test(arguments: [("dev.hsmith.Salvage", ""), ("dev.hsmith.Salvage", "ab12cd34ef"), ("dev.hsmith.Salvage", "AB12CD34E"),
                      ("dev.hsmith.Salvage", #"AB12" or "1""#), ("dev.hsmith.Salvage\" or true", "AB12CD34EF"),
                      ("", "AB12CD34EF"), (".hidden", "AB12CD34EF")])
    func codeSigningRequirementRefusesInjection(_ identifier: String, _ team: String) {
        #expect(codeSigningRequirement(identifier: identifier, teamID: team, allowDevelopmentCertificates: false) == nil)
        #expect(codeSigningRequirement(identifier: identifier, teamID: team, allowDevelopmentCertificates: true) == nil)
    }

    @Test func helperProtocolMatchesTheEmbeddedLaunchdPlist() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(
            "../../../SalvageHelper/\(PrivilegedOpenProtocol.launchdPlistName)").standardizedFileURL
        let plist = try #require(try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
        #expect(plist["Label"] as? String == PrivilegedOpenProtocol.machServiceName)
        #expect((plist["MachServices"] as? [String: Bool]) == [PrivilegedOpenProtocol.machServiceName: true])
        #expect(plist["BundleProgram"] as? String == "Contents/MacOS/SalvageHelper")
        #expect(plist["AssociatedBundleIdentifiers"] as? [String] == [PrivilegedOpenProtocol.appIdentifier])
        // launchd only spawns a binary signed as the helper. The team is added at build time
        // from DEVELOPMENT_TEAM (project.yml), never hardcoded here.
        #expect(plist["SpawnConstraint"] as? [String: String] == ["signing-identifier": PrivilegedOpenProtocol.helperIdentifier])
        // On demand only: never started at load or kept alive, no arbitrary program arguments.
        #expect(Set(plist.keys) == ["Label", "BundleProgram", "MachServices", "AssociatedBundleIdentifiers", "SpawnConstraint"])
    }

    /// The helper's IORegistry walk must agree with the app's diskutil-based resolution, because
    /// the helper may not spawn diskutil.
    @Test func registryBootResolutionMatchesDiskutil() throws {
        guard case .success(let viaDiskutil) = resolveBootDisks() else {
            Issue.record("diskutil-based resolution failed on this machine"); return
        }
        #expect(registryProtectedBootDisks() == viaDiskutil)
        let container = try #require(bootWholeDiskBSDName())
        let media = try #require(registryDiskMedia(bsdName: container))
        #expect(media.isWhole)
        #expect(!media.ancestorWholeDisks.isEmpty)
        #expect(bootDiskRefusal(requested: container, requestedAncestorWholeDisks: media.ancestorWholeDisks,
                                protected: registryProtectedBootDisks()) == .bootDisk)
        #expect(registryDiskMedia(bsdName: "disk99999") == nil)
        #expect(registryDiskMedia(bsdName: "\(container)s1") == nil)
        #expect(media.isDiskImage == false)
    }

    /// Live: every mount source on this machine resolves its IORegistry ancestry (so the
    /// fail-closed rule doesn't refuse every scan), and the boot container's own volumes keep
    /// its physical store in use.
    @Test func liveMountAncestryResolves() throws {
        let sources = try #require(mountSourcesSnapshot())
        for source in sources {
            guard let media = mountSourceMediaName(source) else { continue }
            #expect(registryAncestorWholeDisks(ofMediaNamed: media) != nil, "\(source)")
        }
        let protected = try #require(registryProtectedBootDisks())
        let container = try #require(bootWholeDiskBSDName())
        for store in protected.subtracting([container]) {
            #expect(isMounted(store, sources: sources, ancestorWholeDisks: registryAncestorWholeDisks(ofMediaNamed:)))
        }
        #expect(registryAncestorWholeDisks(ofMediaNamed: "disk99999s1") == nil)
        #expect(registryAncestorWholeDisks(ofMediaNamed: "../disk0") == nil)
    }

    /// Live: whatever disk images are attached on this machine are recognised as such, including
    /// APFS containers synthesized from them; physical boot disks are not.
    @Test func liveDiskImagesAreRecognised() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["list"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        let images = output.split(separator: "\n").compactMap { line -> String? in
            guard line.hasPrefix("/dev/disk"), line.contains("(disk image") else { return nil }
            return wholeDiskBSDName(fromDevicePath: String(line.split(separator: " ")[0]))
        }
        for image in images {
            let media = try #require(registryDiskMedia(bsdName: image))
            #expect(media.isDiskImage, "\(image)")
        }
        for disk in try #require(registryProtectedBootDisks()) {
            #expect(registryDiskMedia(bsdName: disk)?.isDiskImage == false, "\(disk)")
        }
    }

    @Test func liveSystemReportsNodeOwner() throws {
        let null = try #require(LivePrivilegedOpenSystem().nodeStatus(atPath: "/dev/null"))
        #expect(null.uid == 0)
        #expect(null.mode & S_IFMT == S_IFCHR)
    }
}

// MARK: - Request decoding

@Suite("Helper request decoding")
struct HelperRequestDecodingTests {
    private func message(_ build: (xpc_object_t) -> Void = { _ in }, omit: String? = nil) -> xpc_object_t {
        let dictionary = xpc_dictionary_create(nil, nil, 0)
        typealias Key = PrivilegedOpenProtocol.Key
        if omit != Key.version { xpc_dictionary_set_int64(dictionary, Key.version, 1) }
        if omit != Key.operation { xpc_dictionary_set_string(dictionary, Key.operation, "openWholeDiskReadOnly") }
        if omit != Key.bsdName { xpc_dictionary_set_string(dictionary, Key.bsdName, "disk4") }
        if omit != Key.registryID { xpc_dictionary_set_uint64(dictionary, Key.registryID, 77) }
        if omit != Key.deviceNumber { xpc_dictionary_set_int64(dictionary, Key.deviceNumber, 0x0100_0004) }
        build(dictionary)
        return dictionary
    }

    @Test func wellFormedMessageDecodes() {
        #expect(decodePrivilegedOpenRequest(message())
            == .success(PrivilegedOpenRequest(bsdName: "disk4", registryID: 77, deviceNumber: 0x0100_0004)))
    }

    @Test(arguments: ["version", "operation", "bsdName", "registryID", "deviceNumber"])
    func missingKeyIsMalformed(_ key: String) {
        #expect(decodePrivilegedOpenRequest(message(omit: key)) == .failure(.malformedRequest))
    }

    /// A wrong-typed value must not be read as 0 / nil and carried on: the old decoder turned a
    /// string `deviceNumber` into dev_t 0 and went on to the registry.
    @Test(arguments: ["version", "operation", "bsdName", "registryID", "deviceNumber"])
    func wrongTypedKeyIsMalformed(_ key: String) {
        let decoded = decodePrivilegedOpenRequest(message({ dictionary in
            switch key {
            case "operation", "bsdName": xpc_dictionary_set_int64(dictionary, key, 4)
            case "registryID": xpc_dictionary_set_int64(dictionary, key, 77)
            case "version", "deviceNumber": xpc_dictionary_set_uint64(dictionary, key, 1)
            default: Issue.record("unexpected key")
            }
        }))
        #expect(decoded == .failure(.malformedRequest))
        #expect(servePrivilegedOpen(decoded, peerEUID: 501, system: SystemFake()) == .failure(.malformedRequest))
    }

    @Test func extraKeyAndNonDictionaryAreMalformed() {
        #expect(decodePrivilegedOpenRequest(message({ xpc_dictionary_set_bool($0, "write", true) })) == .failure(.malformedRequest))
        #expect(decodePrivilegedOpenRequest(xpc_string_create("disk4")) == .failure(.malformedRequest))
    }

    @Test func invalidUTF8NameIsMalformed() {
        let bytes: [CChar] = [0x64, 0x69, 0x73, 0x6b, CChar(bitPattern: 0xff), 0]
        let decoded = decodePrivilegedOpenRequest(message({ dictionary in
            bytes.withUnsafeBufferPointer { xpc_dictionary_set_string(dictionary, PrivilegedOpenProtocol.Key.bsdName, $0.baseAddress!) }
        }))
        #expect(decoded == .failure(.malformedRequest))
    }

    @Test func sliceNameIsNotWholeDisk() {
        #expect(decodePrivilegedOpenRequest(message({ xpc_dictionary_set_string($0, PrivilegedOpenProtocol.Key.bsdName, "disk4s1") }))
            == .failure(.notWholeDisk))
    }
}

// MARK: - The helper's serve core

/// Records every system call `servePrivilegedOpen` makes, in order.
final class SystemFake: PrivilegedOpenSystem, @unchecked Sendable {
    static let rdev = dev_t(bitPattern: (UInt32(1) << 24) | 4)
    var media: RegistryDiskMedia? = RegistryDiskMedia(registryID: 77, isWhole: true, major: 1, minor: 4,
                                                      ancestorWholeDisks: [], isDiskImage: false)
    var mediaAfterOpen: RegistryDiskMedia??
    var protected: Set<String>? = ["disk3", "disk0"]
    var sources: [String]? = ["/dev/disk3s1s1", "devfs"]
    var ancestry: [String: Set<String>] = ["disk3s1s1": ["disk3", "disk0"]]
    var before: NodeStatus? = NodeStatus(mode: S_IFCHR | 0o640, rdev: SystemFake.rdev, uid: 0)
    var after: NodeStatus? = NodeStatus(mode: S_IFCHR | 0o640, rdev: SystemFake.rdev, uid: 0)
    var openResult: PrivilegedOpenAttempt = .opened(55)
    private(set) var calls: [String] = []
    private(set) var closed: [Int32] = []

    func diskMedia(bsdName: String) -> RegistryDiskMedia? {
        let afterOpen = calls.contains("open")
        calls.append("media")
        if afterOpen, let mediaAfterOpen { return mediaAfterOpen }
        return media
    }
    func protectedBootDisks() -> Set<String>? { calls.append("boot"); return protected }
    func mountSources() -> [String]? { calls.append("mounts"); return sources }
    func ancestorWholeDisks(ofMediaNamed name: String) -> Set<String>? { calls.append("ancestry:\(name)"); return ancestry[name] }
    func nodeStatus(atPath path: String) -> NodeStatus? { calls.append("lstat:\(path)"); return before }
    func openReadOnly(path: String) -> PrivilegedOpenAttempt { calls.append("open"); return openResult }
    func nodeStatus(ofDescriptor descriptor: Int32) -> NodeStatus? { calls.append("fstat"); return after }
    func closeDescriptor(_ descriptor: Int32) { calls.append("close"); closed.append(descriptor) }

    var opened: Bool { calls.contains("open") }
}

@Suite("Helper serve core")
struct HelperServeCoreTests {
    private let request = Result<PrivilegedOpenRequest, PrivilegedOpenRefusal>.success(
        PrivilegedOpenRequest(bsdName: "disk4", registryID: 77, deviceNumber: SystemFake.rdev))

    private func serve(_ system: SystemFake) -> Result<Int32, PrivilegedOpenRefusal> {
        servePrivilegedOpen(request, peerEUID: 501, system: system)
    }

    @Test func validRequestOpensInOrder() {
        let system = SystemFake()
        #expect(serve(system) == .success(55))
        #expect(system.calls == ["media", "boot", "mounts", "ancestry:disk3s1s1", "lstat:/dev/rdisk4", "open", "fstat", "media"])
        #expect(system.closed.isEmpty)
    }

    @Test(arguments: [PrivilegedOpenRefusal.malformedRequest, .notWholeDisk])
    func decodeRefusalsTouchNothing(_ refusal: PrivilegedOpenRefusal) {
        let system = SystemFake()
        #expect(servePrivilegedOpen(.failure(refusal), peerEUID: 501, system: system) == .failure(refusal))
        #expect(system.calls.isEmpty)
    }

    @Test func unknownDeviceIsRefusedFirst() {
        let system = SystemFake(); system.media = nil
        #expect(serve(system) == .failure(.deviceNotFound))
        #expect(system.calls == ["media"])
    }

    @Test func bootRefusalsComeBeforeAnyNodeAccess() {
        let unresolved = SystemFake(); unresolved.protected = nil
        #expect(serve(unresolved) == .failure(.bootDiskUnresolved))
        let layered = SystemFake()
        layered.media = RegistryDiskMedia(registryID: 77, isWhole: true, major: 1, minor: 4, ancestorWholeDisks: ["disk0"], isDiskImage: false)
        #expect(serve(layered) == .failure(.bootDisk))
        for system in [unresolved, layered] { #expect(system.calls == ["media", "boot"]) }
    }

    @Test func identityMismatchIsRefusedBeforeMountsOrOpen() {
        let partition = SystemFake()
        partition.media = RegistryDiskMedia(registryID: 77, isWhole: false, major: 1, minor: 4, ancestorWholeDisks: [], isDiskImage: false)
        #expect(serve(partition) == .failure(.notWholeDisk))
        let replaced = SystemFake()
        replaced.media = RegistryDiskMedia(registryID: 78, isWhole: true, major: 1, minor: 4, ancestorWholeDisks: [], isDiskImage: false)
        #expect(serve(replaced) == .failure(.deviceChanged))
        let otherMinor = SystemFake()
        otherMinor.media = RegistryDiskMedia(registryID: 77, isWhole: true, major: 1, minor: 5, ancestorWholeDisks: [], isDiskImage: false)
        #expect(serve(otherMinor) == .failure(.deviceChanged))
        for system in [partition, replaced, otherMinor] { #expect(system.calls == ["media", "boot"]) }
    }

    /// Finding 1: disk-image media (for example another user's attached image) is never opened.
    @Test func diskImageMediaIsRefused() {
        let system = SystemFake()
        system.media = RegistryDiskMedia(registryID: 77, isWhole: true, major: 1, minor: 4, ancestorWholeDisks: [], isDiskImage: true)
        #expect(serve(system) == .failure(.diskImage))
        #expect(system.calls == ["media", "boot"])
        #expect(!system.opened)
    }

    @Test func diskBecomingAnImageAfterOpenIsClosed() {
        let system = SystemFake()
        system.mediaAfterOpen = RegistryDiskMedia(registryID: 77, isWhole: true, major: 1, minor: 4, ancestorWholeDisks: [], isDiskImage: true)
        #expect(serve(system) == .failure(.deviceChanged))
        #expect(system.closed == [55])
    }

    /// Finding 1: a node not owned by root is refused before it is opened.
    @Test func nonRootOwnedNodeIsRefused() {
        let system = SystemFake()
        system.before = NodeStatus(mode: S_IFCHR | 0o640, rdev: SystemFake.rdev, uid: 501)
        #expect(serve(system) == .failure(.notRootOwned))
        #expect(!system.opened)
        #expect(system.calls.last == "lstat:/dev/rdisk4")
    }

    @Test func nodeChangingOwnerAfterOpenIsClosed() {
        let system = SystemFake()
        system.after = NodeStatus(mode: S_IFCHR | 0o640, rdev: SystemFake.rdev, uid: 501)
        #expect(serve(system) == .failure(.notRootOwned))
        #expect(system.closed == [55])
    }

    @Test func mountStateIsCheckedBeforeTheNode() {
        let unknown = SystemFake(); unknown.sources = nil
        #expect(serve(unknown) == .failure(.mountStateUnknown))
        let mounted = SystemFake(); mounted.sources = ["/dev/disk4s2"]
        #expect(serve(mounted) == .failure(.mounted))
        for system in [unknown, mounted] { #expect(!system.calls.contains { $0.hasPrefix("lstat") }) }
    }

    /// Finding 2: disk4 is refused while disk5s1, an APFS volume of a container on disk4, is mounted.
    @Test func apfsVolumeLayeredOnTheDiskIsRefusedAsMounted() {
        let system = SystemFake()
        system.sources = ["/dev/disk3s1s1", "/dev/disk5s1"]
        system.ancestry = ["disk3s1s1": ["disk3", "disk0"], "disk5s1": ["disk5", "disk4"]]
        #expect(serve(system) == .failure(.mounted))
        #expect(!system.opened)
    }

    @Test func unresolvableMountAncestryFailsClosed() {
        let system = SystemFake()
        system.sources = ["/dev/disk9s1"]
        system.ancestry = [:]
        #expect(serve(system) == .failure(.mounted))
        #expect(!system.opened)
    }

    @Test func wrongNodeBeforeOpenIsRefused() {
        let missing = SystemFake(); missing.before = nil
        let block = SystemFake(); block.before = NodeStatus(mode: S_IFBLK | 0o640, rdev: SystemFake.rdev, uid: 0)
        let other = SystemFake(); other.before = NodeStatus(mode: S_IFCHR | 0o640, rdev: SystemFake.rdev &+ 1, uid: 0)
        for system in [missing, block, other] {
            #expect(serve(system) == .failure(.deviceChanged))
            #expect(!system.opened)
        }
    }

    @Test(arguments: [(EACCES, PrivilegedOpenRefusal.permissionDenied), (EPERM, .permissionDenied), (ENOENT, .openFailed), (EBUSY, .openFailed)])
    func openFailuresMapToRefusals(_ code: Int32, _ refusal: PrivilegedOpenRefusal) {
        let system = SystemFake(); system.openResult = .failed(errno: code)
        #expect(serve(system) == .failure(refusal))
        #expect(system.closed.isEmpty)
    }

    @Test func postOpenMismatchesCloseTheDescriptor() {
        let noStat = SystemFake(); noStat.after = nil
        let otherNode = SystemFake(); otherNode.after = NodeStatus(mode: S_IFCHR | 0o640, rdev: SystemFake.rdev &+ 1, uid: 0)
        let replaced = SystemFake()
        replaced.mediaAfterOpen = RegistryDiskMedia(registryID: 78, isWhole: true, major: 1, minor: 4, ancestorWholeDisks: [], isDiskImage: false)
        let vanished = SystemFake(); vanished.mediaAfterOpen = .some(nil)
        for system in [noStat, otherNode, replaced, vanished] {
            #expect(serve(system) == .failure(.deviceChanged))
            #expect(system.closed == [55])
        }
    }

    /// The caller's euid doesn't change the answer: root-only ownership decides.
    @Test func peerEUIDDoesNotWidenOrNarrowAccess() {
        for euid: uid_t in [0, 501, 502] {
            #expect(servePrivilegedOpen(request, peerEUID: euid, system: SystemFake()) == .success(55))
            let foreign = SystemFake()
            foreign.before = NodeStatus(mode: S_IFCHR | 0o640, rdev: SystemFake.rdev, uid: euid == 0 ? 501 : euid)
            #expect(servePrivilegedOpen(request, peerEUID: euid, system: foreign) == .failure(.notRootOwned))
        }
    }
}

// MARK: - Idle exit

@Suite("Helper idle exit")
struct HelperIdleExitTests {
    private let second: UInt64 = 1_000_000_000

    @Test func exitsOnlyAfterTheIdleTimeWithNoConnection() {
        var tracker = HelperIdleTracker(now: 1_000)
        #expect(tracker.idleNanoseconds == 60 * second)
        #expect(!tracker.shouldExit(at: 1_000 + 59 * second))
        #expect(tracker.shouldExit(at: 1_000 + 60 * second))
        tracker.connectionOpened(at: 2_000)
        #expect(!tracker.shouldExit(at: 2_000 + 600 * second))
        tracker.connectionClosed(at: 2_000 + 10 * second)
        #expect(!tracker.shouldExit(at: 2_000 + 69 * second))
        #expect(tracker.shouldExit(at: 2_000 + 70 * second))
    }

    @Test func eachMessageResetsTheTimer() {
        var tracker = HelperIdleTracker(now: 0)
        tracker.messageReceived(at: 50 * second)
        #expect(tracker.deadline == 110 * second)
        #expect(!tracker.shouldExit(at: 100 * second))
        #expect(tracker.shouldExit(at: 110 * second))
    }

    @Test func connectionCountNeverGoesNegative() {
        var tracker = HelperIdleTracker(now: 0)
        tracker.connectionOpened(at: 0); tracker.connectionOpened(at: 0)
        tracker.connectionClosed(at: 0); tracker.connectionClosed(at: 0); tracker.connectionClosed(at: 0)
        #expect(tracker.activeConnections == 0)
        tracker.connectionOpened(at: 0)
        #expect(!tracker.shouldExit(at: 1_000 * second))
    }

    @Test func timeGoingBackwardsNeverExitsEarly() {
        var tracker = HelperIdleTracker(now: 100 * second)
        tracker.messageReceived(at: 10 * second)
        #expect(tracker.lastActivity == 100 * second)
        #expect(!tracker.shouldExit(at: 50 * second))
    }
}

// MARK: - RawBlockReader fallback

actor HelperFake: PrivilegedOpening {
    /// - devNull: a read-only /dev/null descriptor, marked O_NONBLOCK. That status flag belongs
    ///   to this open file description, so `wasClosed` can tell "our descriptor was closed" from
    ///   "closed, then its number reused by a parallel test's fresh open".
    /// - pipe: the read end of a pipe (a FIFO, so the wrong node type). The fake keeps the write
    ///   end; writing to it fails with EPIPE exactly when the handed-out read end was closed.
    enum Behavior: Sendable { case devNull, pipe, fail(ScanError) }
    let behavior: Behavior
    private(set) var requests: [PrivilegedOpenRequest] = []
    private(set) var handedOut: [Int32] = []
    private var pipeWriteEnd: Int32?
    init(_ behavior: Behavior) { self.behavior = behavior }
    deinit { if let pipeWriteEnd { close(pipeWriteEnd) } }
    func openWholeDiskReadOnly(_ request: PrivilegedOpenRequest) async throws -> Int32 {
        requests.append(request)
        switch behavior {
        case .devNull:
            let fd = open("/dev/null", O_RDONLY | O_CLOEXEC | O_NONBLOCK); handedOut.append(fd); return fd
        case .pipe:
            var ends: [Int32] = [-1, -1]
            guard pipe(&ends) == 0 else { throw ScanError.io("pipe failed") }
            // No SIGPIPE for the probe write; EPIPE is the signal we want.
            _ = fcntl(ends[1], F_SETNOSIGPIPE, 1)
            pipeWriteEnd = ends[1]; handedOut.append(ends[0]); return ends[0]
        case .fail(let error): throw error
        }
    }

    /// Whether the descriptor this fake handed out was closed (robust against number reuse).
    func wasClosed(_ fd: Int32) -> Bool {
        switch behavior {
        case .pipe:
            guard let pipeWriteEnd else { return false }
            var byte: UInt8 = 0
            return write(pipeWriteEnd, &byte, 1) == -1 && errno == EPIPE
        case .devNull:
            // Gone, or reused by an open that isn't ours (no O_NONBLOCK, or not /dev/null).
            let flags = fcntl(fd, F_GETFL)
            guard flags != -1 else { return true }
            var node = stat(), null = stat()
            guard fstat(fd, &node) == 0, stat("/dev/null", &null) == 0 else { return true }
            return flags & O_NONBLOCK == 0 || node.st_rdev != null.st_rdev
        case .fail:
            return false
        }
    }
}

private func devNullIdentity() -> RawDeviceIdentity {
    var node = stat()
    _ = stat("/dev/null", &node)
    return RawDeviceIdentity(registryID: 77, sizeBytes: 65536, blockSize: 512, deviceNumber: node.st_rdev)
}

// Serialized: the O_NONBLOCK marker on HelperFake's /dev/null descriptors is only unique if no
// sibling test in this suite holds another one while a closed number gets reused.
@Suite("Raw open falls back to the helper", .serialized)
struct RawOpenFallbackTests {
    @Test func directOpenSucceedsWithoutHelper() async throws {
        let helper = HelperFake(.fail(.io("must not be called"))), expected = devNullIdentity()
        var paths: [String] = []
        let fd = try await openRawDevice("disk42", expected: expected, directOpen: { path in
            paths.append(path); return .opened(open("/dev/null", O_RDONLY | O_CLOEXEC))
        }, helper: helper)
        defer { close(fd) }
        #expect(paths == ["/dev/rdisk42"])
        #expect(await helper.requests.isEmpty)
    }

    @Test(arguments: [EACCES, EPERM])
    func permissionErrorAsksTheHelper(_ code: Int32) async throws {
        let helper = HelperFake(.devNull), expected = devNullIdentity()
        let fd = try await openRawDevice("disk42", expected: expected, directOpen: { _ in .failed(errno: code) }, helper: helper)
        defer { close(fd) }
        #expect(!(await helper.wasClosed(fd)))
        #expect(await helper.requests == [PrivilegedOpenRequest(bsdName: "disk42", registryID: 77, deviceNumber: expected.deviceNumber)])
        #expect(await helper.handedOut == [fd])
    }

    @Test(arguments: [ENOENT, EBUSY, ENXIO])
    func otherErrorsNeverReachTheHelper(_ code: Int32) async {
        let helper = HelperFake(.devNull)
        await #expect(throws: ScanError.io(String(cString: strerror(code)))) {
            _ = try await openRawDevice("disk42", expected: devNullIdentity(), directOpen: { _ in .failed(errno: code) }, helper: helper)
        }
        #expect(await helper.requests.isEmpty)
    }

    @Test func helperErrorsPropagate() async {
        let helper = HelperFake(.fail(PrivilegedHelperApproval.approvalRequiredError))
        await #expect(throws: PrivilegedHelperApproval.approvalRequiredError) {
            _ = try await openRawDevice("disk42", expected: devNullIdentity(), directOpen: { _ in .failed(errno: EACCES) }, helper: helper)
        }
    }

    @Test func helperDescriptorForTheWrongNodeIsClosedAndRefused() async throws {
        let helper = HelperFake(.pipe)
        await #expect(throws: ScanError.deviceChanged) {
            _ = try await openRawDevice("disk42", expected: devNullIdentity(), directOpen: { _ in .failed(errno: EACCES) }, helper: helper)
        }
        let fd = try #require(await helper.handedOut.first)
        #expect(await helper.wasClosed(fd))
    }

    @Test func helperDescriptorWithWrongDeviceNumberIsClosedAndRefused() async throws {
        let helper = HelperFake(.devNull)
        let identity = devNullIdentity()
        let wrong = RawDeviceIdentity(registryID: 77, sizeBytes: 65536, blockSize: 512, deviceNumber: identity.deviceNumber &+ 1)
        await #expect(throws: ScanError.deviceChanged) {
            _ = try await openRawDevice("disk42", expected: wrong, directOpen: { _ in .failed(errno: EACCES) }, helper: helper)
        }
        let fd = try #require(await helper.handedOut.first)
        #expect(await helper.wasClosed(fd))
    }

    @Test func malformedNameIsRefusedBeforeAnyOpen() async {
        let helper = HelperFake(.devNull)
        var called = false
        await #expect(throws: ScanError.unsafeTarget(RawBlockReader.notWholeDriveReason)) {
            _ = try await openRawDevice("disk4s1", expected: devNullIdentity(), directOpen: { _ in called = true; return .failed(errno: EACCES) }, helper: helper)
        }
        #expect(!called)
        #expect(await helper.requests.isEmpty)
    }
}

// MARK: - Client registration and approval

actor ControlFake: HelperServiceControl {
    var current: HelperRegistrationStatus
    let afterRegister: HelperRegistrationStatus
    let registerThrows: Bool
    private(set) var registrations = 0
    init(_ status: HelperRegistrationStatus, afterRegister: HelperRegistrationStatus = .requiresApproval, registerThrows: Bool = false) {
        current = status; self.afterRegister = afterRegister; self.registerThrows = registerThrows
    }
    func status() async -> HelperRegistrationStatus { current }
    func register() async throws {
        registrations += 1
        current = afterRegister
        if registerThrows { throw CocoaError(.featureUnsupported) }
    }
    func set(_ status: HelperRegistrationStatus) { current = status }
}

actor TransportFake: PrivilegedOpenTransport {
    let reply: PrivilegedOpenReply
    private(set) var sent = 0
    init(_ reply: PrivilegedOpenReply) { self.reply = reply }
    func send(_ request: PrivilegedOpenRequest) async -> PrivilegedOpenReply { sent += 1; return reply }
}

@Suite("Helper client")
struct PrivilegedOpenClientTests {
    private let request = PrivilegedOpenRequest(bsdName: "disk4", registryID: 77, deviceNumber: 3)

    @Test func enabledHelperIsAsked() async throws {
        let control = ControlFake(.enabled), transport = TransportFake(.descriptor(9))
        let fd = try await PrivilegedOpenClient(control: control, transport: transport).openWholeDiskReadOnly(request)
        #expect(fd == 9)
        #expect(await control.registrations == 0)
    }

    @Test func firstUseRegistersAndAsksForApprovalWithoutConnecting() async {
        let control = ControlFake(.notRegistered), transport = TransportFake(.descriptor(9))
        await #expect(throws: PrivilegedHelperApproval.approvalRequiredError) {
            _ = try await PrivilegedOpenClient(control: control, transport: transport).openWholeDiskReadOnly(request)
        }
        #expect(await control.registrations == 1)
        #expect(await transport.sent == 0)
    }

    @Test func registrationThatThrowsButNeedsApprovalStillGuides() async {
        let control = ControlFake(.notRegistered, afterRegister: .requiresApproval, registerThrows: true)
        await #expect(throws: PrivilegedHelperApproval.approvalRequiredError) {
            _ = try await PrivilegedOpenClient(control: control, transport: TransportFake(.descriptor(9))).openWholeDiskReadOnly(request)
        }
    }

    @Test func failedRegistrationReportsMissingHelper() async {
        let control = ControlFake(.notRegistered, afterRegister: .notRegistered, registerThrows: true)
        await #expect(throws: PrivilegedHelperApproval.missingError) {
            _ = try await PrivilegedOpenClient(control: control, transport: TransportFake(.descriptor(9))).openWholeDiskReadOnly(request)
        }
    }

    @Test func registrationThatEnablesProceeds() async throws {
        let control = ControlFake(.notRegistered, afterRegister: .enabled)
        let fd = try await PrivilegedOpenClient(control: control, transport: TransportFake(.descriptor(9))).openWholeDiskReadOnly(request)
        #expect(fd == 9)
    }

    @Test func pendingApprovalAndMissingHelperNeverConnect() async {
        let transport = TransportFake(.descriptor(9))
        await #expect(throws: PrivilegedHelperApproval.approvalRequiredError) {
            _ = try await PrivilegedOpenClient(control: ControlFake(.requiresApproval), transport: transport).openWholeDiskReadOnly(request)
        }
        await #expect(throws: PrivilegedHelperApproval.missingError) {
            _ = try await PrivilegedOpenClient(control: ControlFake(.notFound), transport: transport).openWholeDiskReadOnly(request)
        }
        #expect(await transport.sent == 0)
    }

    @Test func unavailableHelperReportsPlainError() async {
        await #expect(throws: PrivilegedHelperApproval.unavailableError) {
            _ = try await PrivilegedOpenClient(control: ControlFake(.enabled), transport: TransportFake(.unavailable)).openWholeDiskReadOnly(request)
        }
    }

    /// Expected values are written out, not computed with `scanError(for:)`.
    static let refusalTable: [(PrivilegedOpenRefusal, ScanError)] = [
        (.malformedRequest, .io("Salvage's read-only disk access couldn't open this device.")),
        (.notWholeDisk, .unsafeTarget("This device can't be scanned because its system name isn't a whole drive.")),
        (.bootDiskUnresolved, .unsafeTarget("Couldn't identify your startup drive safely. The scan was refused.")),
        (.bootDisk, .unsafeTarget("Your boot drive can't be scanned while macOS is running from it.")),
        (.deviceNotFound, .deviceChanged),
        (.deviceChanged, .deviceChanged),
        (.mountStateUnknown, .io("Couldn't verify the device is unmounted.")),
        (.mounted, .io("The device was mounted again. Close files on it and retry.")),
        (.permissionDenied, .permissionDenied),
        (.openFailed, .io("Salvage's read-only disk access couldn't open this device.")),
        (.notRootOwned, .unsafeTarget("This device or disk image wasn't attached by you, so Salvage can't read it. Attach it from your own account and try again.")),
        (.diskImage, .unsafeTarget("This device or disk image wasn't attached by you, so Salvage can't read it. Attach it from your own account and try again.")),
    ]

    @Test func refusalTableCoversEveryRefusal() {
        #expect(Self.refusalTable.map(\.0) == PrivilegedOpenRefusal.allCases)
    }

    @Test(arguments: refusalTable)
    func refusalsMapToScanErrors(_ refusal: PrivilegedOpenRefusal, _ expected: ScanError) async {
        #expect(PrivilegedOpenClient.scanError(for: refusal) == expected)
        await #expect(throws: expected) {
            _ = try await PrivilegedOpenClient(control: ControlFake(.enabled), transport: TransportFake(.refused(refusal))).openWholeDiskReadOnly(request)
        }
        #expect(!PrivilegedHelperApproval.isApprovalRequired(expected))
    }

    @Test func bootRefusalsUseTheAppsOwnWording() {
        #expect(PrivilegedOpenClient.scanError(for: .bootDisk) == .unsafeTarget(RawBlockReader.bootDriveReason))
        #expect(PrivilegedOpenClient.scanError(for: .bootDiskUnresolved) == .unsafeTarget(RawBlockReader.bootUnresolvedReason))
        #expect(PrivilegedOpenClient.scanError(for: .notWholeDisk) == .unsafeTarget(RawBlockReader.notWholeDriveReason))
        #expect(PrivilegedOpenClient.scanError(for: .deviceChanged) == .deviceChanged)
        #expect(PrivilegedOpenClient.scanError(for: .permissionDenied) == .permissionDenied)
    }
}

@Suite("Approval guidance")
struct HelperApprovalGuidanceTests {
    @Test func guidanceSaysWhereToApproveInPlainLanguage() {
        let text = PrivilegedHelperApproval.guidance
        for phrase in ["System Settings", "General", "Login Items", "Allow in the Background", "Salvage", "retry the scan", "never changes"] {
            #expect(text.contains(phrase), "missing: \(phrase)")
        }
    }

    @Test(arguments: [PrivilegedHelperApproval.guidance, PrivilegedHelperApproval.missingGuidance, PrivilegedHelperApproval.unavailableGuidance])
    func guidanceHasNoJargon(_ text: String) {
        for jargon in ["XPC", "daemon", "launchd", "SMAppService", "helper", "EACCES", "EPERM", "errno", "root", "rdisk", "privileged", "Mach"] {
            #expect(!text.localizedCaseInsensitiveContains(jargon), "jargon: \(jargon)")
        }
    }

    @Test func onlyTheApprovalErrorIsRecognized() {
        #expect(PrivilegedHelperApproval.isApprovalRequired(PrivilegedHelperApproval.approvalRequiredError))
        #expect(!PrivilegedHelperApproval.isApprovalRequired(.permissionDenied))
        #expect(!PrivilegedHelperApproval.isApprovalRequired(PrivilegedHelperApproval.missingError))
        #expect(!PrivilegedHelperApproval.isApprovalRequired(PrivilegedHelperApproval.unavailableError))
        #expect(!PrivilegedHelperApproval.isApprovalRequired(.io("Busy")))
    }
}

private struct TemporaryFile {
    let path: String
    init() throws {
        path = NSTemporaryDirectory() + "salvage-helper-test-\(UUID().uuidString)"
        guard FileManager.default.createFile(atPath: path, contents: Data([1, 2, 3])) else { throw CocoaError(.fileWriteUnknown) }
    }
}
