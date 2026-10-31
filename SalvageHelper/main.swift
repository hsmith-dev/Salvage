import Darwin
import Dispatch
import XPC

// SalvageHelper -- Salvage's privileged read-only helper (Story 1.12, Architecture AD-13).
//
// A launchd daemon (embedded at Contents/Library/LaunchDaemons/dev.hsmith.Salvage.Helper.plist,
// registered by the app through SMAppService.daemon) that runs as root and serves exactly one
// request over its Mach service: open a validated whole-disk /dev/rdiskN read-only and pass the
// file descriptor back. Everything else stays in the unprivileged app, including unmounting
// (DiskArbitration, AD-4) and every byte of parsing.
//
// Attack surface, deliberately minimal:
// - Only a client signed with this helper's own Team ID and the identifier "dev.hsmith.Salvage"
//   is served; XPC enforces that requirement on every message. An unsigned or team-less helper
//   serves nobody.
// - Requests are untrusted: exact key count, version and operation; strict "diskN" name (shared
//   HelperShared/ code with the app); IORegistry identity and device number must match; the boot
//   disk, its physical stores and anything layered on them are refused, failing closed; a
//   mounted disk is refused.
// - The node is opened O_RDONLY | O_CLOEXEC | O_NOFOLLOW and checked with fstat.
// - It never writes, mounts, unmounts, spawns a process, touches the network, or logs (so it
//   can never log file contents). It reads no device bytes itself.
//
// Shared sources compiled into this target (see project.yml):
//   SalvageDiskIO/Sources/SalvageDiskIO/HelperShared/*.swift

/// Handles one decoded request and returns either a descriptor (owned by the caller) or a refusal.
func serve(_ message: xpc_object_t) -> Result<Int32, PrivilegedOpenRefusal> {
    let bsdName = xpc_dictionary_get_string(message, PrivilegedOpenProtocol.Key.bsdName).map { String(cString: $0) }
    let operation = xpc_dictionary_get_string(message, PrivilegedOpenProtocol.Key.operation).map { String(cString: $0) }
    let validated = validatePrivilegedOpenRequest(
        keyCount: xpc_dictionary_get_count(message),
        version: xpc_dictionary_get_int64(message, PrivilegedOpenProtocol.Key.version),
        operation: operation, bsdName: bsdName,
        registryID: xpc_dictionary_get_uint64(message, PrivilegedOpenProtocol.Key.registryID),
        deviceNumber: xpc_dictionary_get_int64(message, PrivilegedOpenProtocol.Key.deviceNumber))
    guard case .success(let request) = validated else {
        if case .failure(let refusal) = validated { return .failure(refusal) }
        return .failure(.malformedRequest)
    }

    // Boot refusal is resolved fresh for every request, without spawning anything.
    guard let media = registryDiskMedia(bsdName: request.bsdName) else { return .failure(.deviceNotFound) }
    if let refusal = bootDiskRefusal(requested: request.bsdName, requestedAncestorWholeDisks: media.ancestorWholeDisks,
                                     protected: registryProtectedBootDisks()) {
        return .failure(refusal)
    }
    guard media.isWhole else { return .failure(.notWholeDisk) }
    guard media.registryID == request.registryID,
          mediaMatchesDeviceNumber(isWhole: media.isWhole, major: media.major, minor: media.minor,
                                   deviceNumber: request.deviceNumber) else { return .failure(.deviceChanged) }
    guard let sources = mountSourcesSnapshot() else { return .failure(.mountStateUnknown) }
    guard !isMounted(request.bsdName, sources: sources) else { return .failure(.mounted) }

    let path = "/dev/r\(request.bsdName)"
    var before = stat()
    guard lstat(path, &before) == 0,
          isExpectedCharacterDevice(mode: before.st_mode, rdev: before.st_rdev, expected: request.deviceNumber) else {
        return .failure(.deviceChanged)
    }
    let descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else {
        return .failure(errno == EACCES || errno == EPERM ? .permissionDenied : .openFailed)
    }
    var after = stat()
    guard fstat(descriptor, &after) == 0,
          isExpectedCharacterDevice(mode: after.st_mode, rdev: after.st_rdev, expected: request.deviceNumber),
          registryDiskMedia(bsdName: request.bsdName)?.registryID == request.registryID else {
        close(descriptor)
        return .failure(.deviceChanged)
    }
    return .success(descriptor)
}

func runHelper() -> Never {
    // The only client this helper serves: the Salvage app signed by the same team. No Team ID
    // (unsigned or ad-hoc build) means no requirement, so the helper refuses to start serving.
    guard let team = currentProcessTeamIdentifier(),
          let requirement = codeSigningRequirement(identifier: PrivilegedOpenProtocol.appIdentifier, teamID: team) else {
        exit(EXIT_FAILURE)
    }
    let queue = DispatchQueue(label: "dev.hsmith.Salvage.Helper.requests")
    let listener = xpc_connection_create_mach_service(PrivilegedOpenProtocol.machServiceName, queue,
                                                      UInt64(XPC_CONNECTION_MACH_SERVICE_LISTENER))
    xpc_connection_set_event_handler(listener) { peer in
        guard xpc_get_type(peer) == XPC_TYPE_CONNECTION else { return }
        // Set before activation, so no message from a non-matching client is ever delivered.
        guard xpc_connection_set_peer_code_signing_requirement(peer, requirement) == 0 else {
            xpc_connection_cancel(peer)
            return
        }
        xpc_connection_set_target_queue(peer, queue)
        let connection = PeerBox(peer)
        xpc_connection_set_event_handler(peer) { message in
            let peer = connection.value
            // Errors include XPC_ERROR_PEER_CODE_SIGNING_REQUIREMENT: drop the peer.
            guard xpc_get_type(message) == XPC_TYPE_DICTIONARY else {
                xpc_connection_cancel(peer)
                return
            }
            guard let reply = xpc_dictionary_create_reply(message) else { return }
            switch serve(message) {
            case .success(let descriptor):
                xpc_dictionary_set_fd(reply, PrivilegedOpenProtocol.Key.descriptor, descriptor)
                close(descriptor) // XPC duplicated it into the reply.
            case .failure(let refusal):
                xpc_dictionary_set_string(reply, PrivilegedOpenProtocol.Key.refusal, refusal.rawValue)
            }
            xpc_connection_send_message(peer, reply)
        }
        xpc_connection_activate(peer)
    }
    xpc_connection_activate(listener)
    dispatchMain()
}

/// XPC connections are thread-safe; the box only lets the peer's handler capture its connection.
final class PeerBox: @unchecked Sendable {
    let value: xpc_connection_t
    init(_ value: xpc_connection_t) { self.value = value }
}

runHelper()
