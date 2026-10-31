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
//   is served; XPC enforces that requirement on every message. Release builds require a
//   Developer ID Application certificate; only Debug builds (SALVAGE_HELPER_ALLOW_DEVELOPMENT)
//   also accept Apple Development / Distribution. An unsigned or team-less helper serves nobody.
// - Requests are untrusted: every key present with its exact type, exact key count, version and
//   operation; strict "diskN" name (shared HelperShared/ code with the app); IORegistry identity
//   and device number must match; the boot disk, its physical stores and anything layered on
//   them are refused, failing closed; disk images (and anything layered on one) are refused; a
//   disk with a mounted filesystem on it or on media layered on it is refused; a node not owned
//   by root is refused, so another user's attached device is never opened on anyone's behalf.
// - The node is opened O_RDONLY | O_CLOEXEC | O_NOFOLLOW and checked with fstat.
// - It never writes, mounts, unmounts, spawns a process, touches the network, or logs (so it
//   can never log file contents). It reads no device bytes itself.
// - It exits after PrivilegedOpenProtocol.idleExitNanoseconds (60 s) with no open connection;
//   launchd starts it again on demand through the MachService.
//
// The request logic is `servePrivilegedOpen` (HelperShared/PrivilegedOpenProtocol.swift), a pure
// core over an injectable `PrivilegedOpenSystem`, unit-tested in SalvageDiskIOTests.
//
// Shared sources compiled into this target (see project.yml):
//   SalvageDiskIO/Sources/SalvageDiskIO/HelperShared/*.swift

/// Handles one received request from `peer` and returns either a descriptor (owned by the
/// caller) or a refusal. The peer's effective UID is passed through for the record; see
/// `servePrivilegedOpen` for why it isn't compared with the node's owner.
func serve(_ message: xpc_object_t, peer: xpc_connection_t) -> Result<Int32, PrivilegedOpenRefusal> {
    servePrivilegedOpen(decodePrivilegedOpenRequest(message), peerEUID: xpc_connection_get_euid(peer),
                        system: LivePrivilegedOpenSystem())
}

func monotonicNow() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

/// Idle-exit state. Only ever touched on the helper's one serial queue.
final class IdleExit: @unchecked Sendable {
    private var tracker = HelperIdleTracker(now: monotonicNow())
    private let timer: DispatchSourceTimer

    init(queue: DispatchQueue) {
        timer = DispatchSource.makeTimerSource(queue: queue)
        timer.setEventHandler { [unowned self] in fire() }
        arm()
        timer.activate()
    }

    func connectionOpened() { tracker.connectionOpened(at: monotonicNow()); arm() }
    func connectionClosed() { tracker.connectionClosed(at: monotonicNow()); arm() }
    func messageReceived() { tracker.messageReceived(at: monotonicNow()); arm() }

    /// (Re)schedules the timer for the tracker's current deadline.
    private func arm() {
        timer.schedule(deadline: DispatchTime(uptimeNanoseconds: tracker.deadline), leeway: .seconds(1))
    }

    private func fire() {
        // No connection is open, so no request or reply is in flight.
        if tracker.shouldExit(at: monotonicNow()) { exit(EXIT_SUCCESS) }
        arm()
    }
}

func runHelper() -> Never {
    // The only client this helper serves: the Salvage app signed by the same team. No Team ID
    // (unsigned or ad-hoc build) means no requirement, so the helper refuses to start serving.
    guard let team = currentProcessTeamIdentifier(),
          let requirement = codeSigningRequirement(identifier: PrivilegedOpenProtocol.appIdentifier, teamID: team,
                                                   allowDevelopmentCertificates: PrivilegedOpenProtocol.allowsDevelopmentSigning) else {
        exit(EXIT_FAILURE)
    }
    let queue = DispatchQueue(label: "dev.hsmith.Salvage.Helper.requests")
    let idle = IdleExit(queue: queue)
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
        idle.connectionOpened()
        xpc_connection_set_event_handler(peer) { message in
            let peer = connection.value
            // Errors include XPC_ERROR_PEER_CODE_SIGNING_REQUIREMENT and the final
            // XPC_ERROR_CONNECTION_INVALID: drop the peer, and count it closed exactly once.
            guard xpc_get_type(message) == XPC_TYPE_DICTIONARY else {
                xpc_connection_cancel(peer)
                if !connection.closed {
                    connection.closed = true
                    idle.connectionClosed()
                }
                return
            }
            idle.messageReceived()
            guard let reply = xpc_dictionary_create_reply(message) else { return }
            switch serve(message, peer: peer) {
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

/// XPC connections are thread-safe; the box lets the peer's handler capture its connection and
/// remember (on the serial queue) whether it was already counted as closed.
final class PeerBox: @unchecked Sendable {
    let value: xpc_connection_t
    var closed = false
    init(_ value: xpc_connection_t) { self.value = value }
}

runHelper()
