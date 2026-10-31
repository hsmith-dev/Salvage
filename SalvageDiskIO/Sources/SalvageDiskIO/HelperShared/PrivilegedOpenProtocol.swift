import Darwin
import XPC

// Story 1.12 / AD-13: the wire contract and the pure validation rules of the privileged
// read-only helper. Compiled into both SalvageDiskIO (client side, unit-tested there) and the
// `SalvageHelper` launchd daemon, so both sides apply byte-for-byte the same rules. Everything
// here is a pure function of its inputs: no I/O, no logging, no SalvageCore types. The helper's
// request handling (`servePrivilegedOpen`) reaches the system only through the injected
// `PrivilegedOpenSystem`, so its refusal ordering is unit-tested without root or real disks.

enum PrivilegedOpenProtocol {
    /// The launchd Mach service name, also the daemon's launchd label.
    static let machServiceName = "dev.hsmith.Salvage.Helper"
    /// File name of the launchd plist embedded at Contents/Library/LaunchDaemons.
    static let launchdPlistName = "dev.hsmith.Salvage.Helper.plist"
    /// Code-signing identifier the helper requires of its only permitted client.
    static let appIdentifier = "dev.hsmith.Salvage"
    /// Code-signing identifier the app requires of the helper it talks to.
    static let helperIdentifier = "dev.hsmith.Salvage.Helper"

    static let version: Int64 = 1
    /// The one and only operation the helper serves.
    static let openOperation = "openWholeDiskReadOnly"

    enum Key {
        static let version = "version"
        static let operation = "operation"
        static let bsdName = "bsdName"
        static let registryID = "registryID"
        static let deviceNumber = "deviceNumber"
        // Reply keys.
        static let descriptor = "descriptor"
        static let refusal = "refusal"
    }
    /// A request carries exactly these keys; anything more or less is refused as malformed.
    static let requestKeyCount = 5

    /// Whether this build's peer requirements also accept Apple Development / Apple Distribution
    /// certificates (so a Debug build signed in Xcode can be tested end to end). Release builds
    /// are always strict: Developer ID only.
    /// - The helper target gets `SALVAGE_HELPER_ALLOW_DEVELOPMENT` from project.yml, Debug only.
    /// - The SalvageDiskIO package can't see app-target settings, so it keys off SwiftPM's own
    ///   `DEBUG` define, which Xcode and SwiftPM set only for the debug configuration. Requiring
    ///   `SWIFT_PACKAGE` keeps a stray `DEBUG` from relaxing the helper.
    #if SALVAGE_HELPER_ALLOW_DEVELOPMENT || (SWIFT_PACKAGE && DEBUG)
    static let allowsDevelopmentSigning = true
    #else
    static let allowsDevelopmentSigning = false
    #endif

    /// Idle time after which the helper exits when no connection is open. launchd restarts it on
    /// demand through its MachService.
    static let idleExitNanoseconds: UInt64 = 60 * 1_000_000_000
}

/// Why the helper declined to open a device. Sent over the wire by raw value.
enum PrivilegedOpenRefusal: String, Error, Sendable, Equatable, CaseIterable {
    case malformedRequest
    case notWholeDisk
    case bootDiskUnresolved
    case bootDisk
    case deviceNotFound
    case deviceChanged
    case mountStateUnknown
    case mounted
    case permissionDenied
    case openFailed
    /// The node isn't owned by root. Physical-disk nodes always are; anything else (for example
    /// another user's attached disk image) is never opened on someone's behalf.
    case notRootOwned
    /// The media is (or is layered on) an attached disk image. A user's own images open directly
    /// without the helper, so the helper never serves one.
    case diskImage
}

/// A validated request: a whole-disk BSD name plus the identity the app observed for it.
struct PrivilegedOpenRequest: Sendable, Equatable {
    let bsdName: String
    let registryID: UInt64
    let deviceNumber: dev_t
}

/// Re-validates an untrusted request decoded from the wire. `keyCount` is the number of keys in
/// the received dictionary; `deviceNumber` arrives as a 64-bit integer and must fit `dev_t`.
func validatePrivilegedOpenRequest(keyCount: Int, version: Int64, operation: String?, bsdName: String?,
                                   registryID: UInt64, deviceNumber: Int64) -> Result<PrivilegedOpenRequest, PrivilegedOpenRefusal> {
    guard keyCount == PrivilegedOpenProtocol.requestKeyCount, version == PrivilegedOpenProtocol.version,
          operation == PrivilegedOpenProtocol.openOperation, registryID != 0,
          let bsdName, let rdev = dev_t(exactly: deviceNumber) else { return .failure(.malformedRequest) }
    guard isWholeDiskBSDName(bsdName) else { return .failure(.notWholeDisk) }
    return .success(PrivilegedOpenRequest(bsdName: bsdName, registryID: registryID, deviceNumber: rdev))
}

/// Decodes an untrusted request dictionary. Every key must be present with exactly its wire type
/// (a wrong-typed value is not silently read as 0 or nil), the strings must be valid UTF-8, and
/// the result then goes through `validatePrivilegedOpenRequest`.
func decodePrivilegedOpenRequest(_ message: xpc_object_t) -> Result<PrivilegedOpenRequest, PrivilegedOpenRefusal> {
    guard xpc_get_type(message) == XPC_TYPE_DICTIONARY else { return .failure(.malformedRequest) }
    func value(_ key: String, _ type: xpc_type_t) -> xpc_object_t? {
        guard let value = xpc_dictionary_get_value(message, key), xpc_get_type(value) == type else { return nil }
        return value
    }
    func string(_ key: String) -> String? {
        guard let value = value(key, XPC_TYPE_STRING), let pointer = xpc_string_get_string_ptr(value) else { return nil }
        return String(validatingCString: pointer)
    }
    typealias Key = PrivilegedOpenProtocol.Key
    guard let version = value(Key.version, XPC_TYPE_INT64),
          let operation = string(Key.operation),
          let bsdName = string(Key.bsdName),
          let registryID = value(Key.registryID, XPC_TYPE_UINT64),
          let deviceNumber = value(Key.deviceNumber, XPC_TYPE_INT64) else { return .failure(.malformedRequest) }
    return validatePrivilegedOpenRequest(
        keyCount: xpc_dictionary_get_count(message), version: xpc_int64_get_value(version),
        operation: operation, bsdName: bsdName, registryID: xpc_uint64_get_value(registryID),
        deviceNumber: xpc_int64_get_value(deviceNumber))
}

/// The disks a raw read must never touch: the whole disk "/" is mounted from (the APFS container
/// on any supported macOS) plus every physical whole disk backing it. `nil` means "couldn't
/// resolve", which callers MUST treat as a refusal.
///
/// - `containerWholeDisk`: whole-disk name derived from statfs("/").
/// - `ancestorMediaBSDNames`: BSD names of every IOMedia above the container in the IOService
///   plane (e.g. "disk0s2", "disk0"); `nil` if the registry walk failed.
///
/// Fails closed when no physical ancestor is found: every macOS this app supports boots from an
/// APFS container, which always has at least one physical store.
func protectedBootDisks(containerWholeDisk: String?, ancestorMediaBSDNames: [String]?) -> Set<String>? {
    guard let container = containerWholeDisk, isWholeDiskBSDName(container),
          let ancestors = ancestorMediaBSDNames else { return nil }
    var physical: Set<String> = []
    for ancestor in ancestors {
        guard let whole = wholeDiskBSDName(fromDevicePath: ancestor), isWholeDiskBSDName(whole) else { return nil }
        if whole != container { physical.insert(whole) }
    }
    guard !physical.isEmpty else { return nil }
    return physical.union([container])
}

/// Boot refusal for a requested disk. Refuses the protected disks themselves and also any disk
/// that sits on top of one (for example the other APFS containers synthesized from the internal
/// SSD's partitions), so a root helper can never hand out a raw view of startup-drive data.
func bootDiskRefusal(requested: String, requestedAncestorWholeDisks: Set<String>,
                     protected: Set<String>?) -> PrivilegedOpenRefusal? {
    guard let protected, !protected.isEmpty else { return .bootDiskUnresolved }
    if protected.contains(requested) || !protected.isDisjoint(with: requestedAncestorWholeDisks) { return .bootDisk }
    return nil
}

/// The fstat / lstat check: the node must be a character device with exactly the expected
/// device number.
func isExpectedCharacterDevice(mode: mode_t, rdev: dev_t, expected: dev_t) -> Bool {
    mode & S_IFMT == S_IFCHR && rdev == expected
}

/// The IOMedia the helper looked up must be a whole disk whose BSD major/minor are the device
/// number the request (and the node on disk) carries.
func mediaMatchesDeviceNumber(isWhole: Bool, major: Int32, minor: Int32, deviceNumber: dev_t) -> Bool {
    guard isWhole, major >= 0, minor >= 0 else { return false }
    // <sys/types.h>'s major()/minor() macros, which Swift doesn't import.
    let bits = UInt32(bitPattern: deviceNumber)
    return Int32((bits >> 24) & 0xff) == major && Int32(bits & 0xff_ffff) == minor
}

/// The BSD media name behind a mount source ("/dev/disk5s1" -> "disk5s1", also raw nodes,
/// bare names and APFS snapshots such as "com.apple.os.update-...@/dev/disk3s1s1"), or `nil` when
/// the source isn't a local disk node ("devfs", "map auto_home", "server:/export", ...).
func mountSourceMediaName(_ source: String) -> String? {
    var node = Substring(source)
    if let at = node.lastIndex(of: "@") { node = node[node.index(after: at)...] }
    if node.hasPrefix("/dev/") { node = node.dropFirst("/dev/".count) }
    if node.hasPrefix("rdisk") { node = node.dropFirst() }
    return isDiskNodeBSDName(String(node)) ? String(node) : nil
}

/// "disk" + digits, optionally followed by any number of "s" + digits (slices, APFS volumes and
/// snapshots), ASCII only.
func isDiskNodeBSDName(_ name: String) -> Bool {
    let bytes = Array(name.utf8)
    guard bytes.count <= 64, bytes.starts(with: Array("disk".utf8)) else { return false }
    var expectDigit = true, index = 4
    while index < bytes.count {
        let byte = bytes[index]
        if byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9") {
            expectDigit = false
        } else if byte == UInt8(ascii: "s") && !expectDigit {
            expectDigit = true
        } else {
            return false
        }
        index += 1
    }
    return !expectDigit
}

/// Whether `name` (a whole disk) is in use by any mounted filesystem:
/// - a mount source on the disk itself (raw or buffered node, whole disk or slice), or
/// - a mount source whose media has `name` as an IORegistry ancestor, such as an APFS volume
///   "disk5s1" of a container synthesized from "disk4s1" while "disk4" is requested.
///
/// `ancestorWholeDisks` returns the whole-disk names above a media name (`nil` when the registry
/// lookup failed). A disk-node source whose ancestry can't be resolved counts as mounted: fail
/// closed.
func isMounted(_ name: String, sources: [String], ancestorWholeDisks: (String) -> Set<String>?) -> Bool {
    for source in sources {
        if wholeDiskBSDName(fromDevicePath: source) == name { return true }
        guard let media = mountSourceMediaName(source) else { continue }
        guard let ancestors = ancestorWholeDisks(media) else { return true }
        if ancestors.contains(name) { return true }
    }
    return false
}

/// A code-signing requirement pinning an exact identifier, an Apple-issued certificate chain and
/// a Team ID. Returns `nil` (never a weaker requirement) if either input could inject syntax.
///
/// - Strict (always in Release): a Developer ID Application certificate. The intermediate must
///   be Apple's Developer ID CA (OID 1.2.840.113635.100.6.2.6) and the leaf must carry the
///   Developer ID Application marker (OID 1.2.840.113635.100.6.1.13), so Apple Development and
///   Apple Distribution certificates of the same team are refused.
/// - Development (`allowDevelopmentCertificates`, Debug builds only): any Apple-issued
///   certificate of the team, so a build signed in Xcode with Apple Development can be tested.
func codeSigningRequirement(identifier: String, teamID: String, allowDevelopmentCertificates: Bool) -> String? {
    let teamBytes = Array(teamID.utf8)
    guard teamBytes.count == 10,
          teamBytes.allSatisfy({ (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains($0) || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }) else { return nil }
    let idBytes = Array(identifier.utf8)
    guard !idBytes.isEmpty, idBytes.count <= 128, idBytes.first != UInt8(ascii: "."),
          idBytes.allSatisfy({ byte in
              (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
                  || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || byte == UInt8(ascii: ".") || byte == UInt8(ascii: "-")
          }) else { return nil }
    if allowDevelopmentCertificates {
        return "identifier \"\(identifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\""
    }
    return "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
        + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
        + " and certificate leaf[subject.OU] = \"\(teamID)\" and identifier \"\(identifier)\""
}

// MARK: - The helper's request handling

/// What `lstat`/`fstat` report about a node, reduced to what the helper checks.
struct NodeStatus: Sendable, Equatable {
    let mode: mode_t
    let rdev: dev_t
    let uid: uid_t
}

/// Outcome of the helper's `open(2)`.
enum PrivilegedOpenAttempt: Sendable, Equatable { case opened(Int32), failed(errno: Int32) }

/// Every syscall and IORegistry query `servePrivilegedOpen` makes, injectable so the refusal
/// ordering is testable. The live implementation is `LivePrivilegedOpenSystem`
/// (PrivilegedDiskQueries.swift). Every query returns `nil` on failure, which is a refusal.
protocol PrivilegedOpenSystem {
    func diskMedia(bsdName: String) -> RegistryDiskMedia?
    func protectedBootDisks() -> Set<String>?
    func mountSources() -> [String]?
    func ancestorWholeDisks(ofMediaNamed name: String) -> Set<String>?
    /// `lstat`: never follows a symlink.
    func nodeStatus(atPath path: String) -> NodeStatus?
    /// `open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)`, nothing else.
    func openReadOnly(path: String) -> PrivilegedOpenAttempt
    /// `fstat`.
    func nodeStatus(ofDescriptor descriptor: Int32) -> NodeStatus?
    func closeDescriptor(_ descriptor: Int32)
}

/// The helper's pure request core. On success the caller owns the returned descriptor; on any
/// refusal after the open, the descriptor has already been closed.
///
/// Order (each step refuses before anything later runs):
/// 1. decoded request (version, operation, keys, strict "diskN" name);
/// 2. IOMedia lookup; boot disk / physical store / anything layered on them (fail closed);
///    whole disk; registry ID and BSD major/minor equal what the app observed;
/// 3. not a disk image and not layered on one;
/// 4. mount table readable, and no mount on the disk or on media layered on it;
/// 5. `lstat`: character device, expected `st_rdev`, owned by root;
/// 6. `open` read-only;
/// 7. `fstat`: same checks again, then the registry ID once more.
///
/// `peerEUID` is the client's effective UID (`xpc_connection_get_euid`). It is deliberately not
/// compared with the node's owner: only root-owned nodes are served at all (step 5), and every
/// physical-disk node is `root:operator 0640`, so the answer doesn't depend on which user asks.
/// The parameter keeps the caller's identity explicit at the trust boundary, for a future rule
/// that needs it.
func servePrivilegedOpen(_ decoded: Result<PrivilegedOpenRequest, PrivilegedOpenRefusal>, peerEUID: uid_t,
                         system: some PrivilegedOpenSystem) -> Result<Int32, PrivilegedOpenRefusal> {
    let request: PrivilegedOpenRequest
    switch decoded {
    case .success(let value): request = value
    case .failure(let refusal): return .failure(refusal)
    }
    guard let media = system.diskMedia(bsdName: request.bsdName) else { return .failure(.deviceNotFound) }
    if let refusal = bootDiskRefusal(requested: request.bsdName, requestedAncestorWholeDisks: media.ancestorWholeDisks,
                                     protected: system.protectedBootDisks()) {
        return .failure(refusal)
    }
    guard media.isWhole else { return .failure(.notWholeDisk) }
    guard media.registryID == request.registryID,
          mediaMatchesDeviceNumber(isWhole: media.isWhole, major: media.major, minor: media.minor,
                                   deviceNumber: request.deviceNumber) else { return .failure(.deviceChanged) }
    guard !media.isDiskImage else { return .failure(.diskImage) }
    guard let sources = system.mountSources() else { return .failure(.mountStateUnknown) }
    guard !isMounted(request.bsdName, sources: sources, ancestorWholeDisks: system.ancestorWholeDisks(ofMediaNamed:)) else {
        return .failure(.mounted)
    }

    let path = "/dev/r\(request.bsdName)"
    guard let before = system.nodeStatus(atPath: path),
          isExpectedCharacterDevice(mode: before.mode, rdev: before.rdev, expected: request.deviceNumber) else {
        return .failure(.deviceChanged)
    }
    guard before.uid == 0 else { return .failure(.notRootOwned) }
    let descriptor: Int32
    switch system.openReadOnly(path: path) {
    case .opened(let fd): descriptor = fd
    case .failed(let code): return .failure(code == EACCES || code == EPERM ? .permissionDenied : .openFailed)
    }
    guard let after = system.nodeStatus(ofDescriptor: descriptor),
          isExpectedCharacterDevice(mode: after.mode, rdev: after.rdev, expected: request.deviceNumber) else {
        system.closeDescriptor(descriptor)
        return .failure(.deviceChanged)
    }
    guard after.uid == 0 else {
        system.closeDescriptor(descriptor)
        return .failure(.notRootOwned)
    }
    guard let reopened = system.diskMedia(bsdName: request.bsdName), reopened.registryID == request.registryID,
          !reopened.isDiskImage else {
        system.closeDescriptor(descriptor)
        return .failure(.deviceChanged)
    }
    return .success(descriptor)
}

// MARK: - Idle exit

/// When the helper may exit: no open connection and `idleNanoseconds` since the last activity
/// (a connection opening or closing, or a message). Times are monotonic nanoseconds.
struct HelperIdleTracker: Sendable, Equatable {
    let idleNanoseconds: UInt64
    private(set) var activeConnections = 0
    private(set) var lastActivity: UInt64

    init(idleNanoseconds: UInt64 = PrivilegedOpenProtocol.idleExitNanoseconds, now: UInt64) {
        self.idleNanoseconds = idleNanoseconds
        lastActivity = now
    }

    mutating func connectionOpened(at now: UInt64) { activeConnections += 1; touch(now) }
    mutating func connectionClosed(at now: UInt64) { activeConnections = max(0, activeConnections - 1); touch(now) }
    mutating func messageReceived(at now: UInt64) { touch(now) }

    /// When the idle timer should next fire.
    var deadline: UInt64 { lastActivity &+ idleNanoseconds }

    func shouldExit(at now: UInt64) -> Bool {
        activeConnections == 0 && now >= lastActivity && now - lastActivity >= idleNanoseconds
    }

    private mutating func touch(_ now: UInt64) { lastActivity = max(lastActivity, now) }
}
