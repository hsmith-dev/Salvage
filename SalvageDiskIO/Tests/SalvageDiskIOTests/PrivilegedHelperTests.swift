import Darwin
import Foundation
import SalvageCore
import Testing
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
        #expect(isMounted("disk4", sources: ["/dev/disk4s1"]))
        #expect(isMounted("disk4", sources: ["/dev/rdisk4"]))
        #expect(!isMounted("disk4", sources: ["/dev/disk40s1", "devfs", "map auto_home"]))
    }

    @Test func codeSigningRequirementPinsIdentifierAppleAnchorAndTeam() {
        #expect(codeSigningRequirement(identifier: "dev.hsmith.Salvage", teamID: "AB12CD34EF")
            == #"identifier "dev.hsmith.Salvage" and anchor apple generic and certificate leaf[subject.OU] = "AB12CD34EF""#)
    }

    @Test(arguments: [("dev.hsmith.Salvage", ""), ("dev.hsmith.Salvage", "ab12cd34ef"), ("dev.hsmith.Salvage", "AB12CD34E"),
                      ("dev.hsmith.Salvage", #"AB12" or "1""#), ("dev.hsmith.Salvage\" or true", "AB12CD34EF"),
                      ("", "AB12CD34EF"), (".hidden", "AB12CD34EF")])
    func codeSigningRequirementRefusesInjection(_ identifier: String, _ team: String) {
        #expect(codeSigningRequirement(identifier: identifier, teamID: team) == nil)
    }

    @Test func helperProtocolMatchesTheEmbeddedLaunchdPlist() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(
            "../../../SalvageHelper/\(PrivilegedOpenProtocol.launchdPlistName)").standardizedFileURL
        let plist = try #require(try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
        #expect(plist["Label"] as? String == PrivilegedOpenProtocol.machServiceName)
        #expect((plist["MachServices"] as? [String: Bool]) == [PrivilegedOpenProtocol.machServiceName: true])
        #expect(plist["BundleProgram"] as? String == "Contents/MacOS/SalvageHelper")
        #expect(plist["AssociatedBundleIdentifiers"] as? [String] == [PrivilegedOpenProtocol.appIdentifier])
        // On demand only: never started at load or kept alive, no arbitrary program arguments.
        #expect(Set(plist.keys) == ["Label", "BundleProgram", "MachServices", "AssociatedBundleIdentifiers"])
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
    }
}

// MARK: - RawBlockReader fallback

actor HelperFake: PrivilegedOpening {
    enum Behavior: Sendable { case devNull, regularFile, fail(ScanError) }
    let behavior: Behavior
    private(set) var requests: [PrivilegedOpenRequest] = []
    private(set) var handedOut: [Int32] = []
    init(_ behavior: Behavior) { self.behavior = behavior }
    func openWholeDiskReadOnly(_ request: PrivilegedOpenRequest) async throws -> Int32 {
        requests.append(request)
        switch behavior {
        case .devNull:
            let fd = open("/dev/null", O_RDONLY | O_CLOEXEC); handedOut.append(fd); return fd
        case .regularFile:
            let fd = open("/bin/ls", O_RDONLY | O_CLOEXEC); handedOut.append(fd); return fd
        case .fail(let error): throw error
        }
    }
}

private func devNullIdentity() -> RawDeviceIdentity {
    var node = stat()
    _ = stat("/dev/null", &node)
    return RawDeviceIdentity(registryID: 77, sizeBytes: 65536, blockSize: 512, deviceNumber: node.st_rdev)
}

private func isOpen(_ fd: Int32) -> Bool { fcntl(fd, F_GETFD) != -1 }

@Suite("Raw open falls back to the helper")
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
        let helper = HelperFake(.regularFile)
        await #expect(throws: ScanError.deviceChanged) {
            _ = try await openRawDevice("disk42", expected: devNullIdentity(), directOpen: { _ in .failed(errno: EACCES) }, helper: helper)
        }
        let fd = try #require(await helper.handedOut.first)
        #expect(!isOpen(fd))
    }

    @Test func helperDescriptorWithWrongDeviceNumberIsClosedAndRefused() async throws {
        let helper = HelperFake(.devNull)
        let identity = devNullIdentity()
        let wrong = RawDeviceIdentity(registryID: 77, sizeBytes: 65536, blockSize: 512, deviceNumber: identity.deviceNumber &+ 1)
        await #expect(throws: ScanError.deviceChanged) {
            _ = try await openRawDevice("disk42", expected: wrong, directOpen: { _ in .failed(errno: EACCES) }, helper: helper)
        }
        let fd = try #require(await helper.handedOut.first)
        #expect(!isOpen(fd))
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

    @Test(arguments: PrivilegedOpenRefusal.allCases)
    func refusalsMapToScanErrors(_ refusal: PrivilegedOpenRefusal) async {
        let expected = PrivilegedOpenClient.scanError(for: refusal)
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
