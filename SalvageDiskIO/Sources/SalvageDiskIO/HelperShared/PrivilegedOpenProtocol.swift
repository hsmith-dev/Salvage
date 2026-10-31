import Darwin

// Story 1.12 / AD-13: the wire contract and the pure validation rules of the privileged
// read-only helper. Compiled into both SalvageDiskIO (client side, unit-tested there) and the
// `SalvageHelper` launchd daemon, so both sides apply byte-for-byte the same rules. Everything
// here is a pure function of its inputs: no I/O, no logging, no SalvageCore types.

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

/// Whether any mount source belongs to `name` (raw or buffered node, whole disk or slice).
func isMounted(_ name: String, sources: [String]) -> Bool {
    sources.contains { wholeDiskBSDName(fromDevicePath: $0) == name }
}

/// A code-signing requirement pinning an exact identifier, an Apple-issued certificate chain and
/// a Team ID. Returns `nil` (never a weaker requirement) if either input could inject syntax.
func codeSigningRequirement(identifier: String, teamID: String) -> String? {
    let teamBytes = Array(teamID.utf8)
    guard teamBytes.count == 10,
          teamBytes.allSatisfy({ (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains($0) || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }) else { return nil }
    let idBytes = Array(identifier.utf8)
    guard !idBytes.isEmpty, idBytes.count <= 128, idBytes.first != UInt8(ascii: "."),
          idBytes.allSatisfy({ byte in
              (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
                  || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || byte == UInt8(ascii: ".") || byte == UInt8(ascii: "-")
          }) else { return nil }
    return "identifier \"\(identifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\""
}
