import Darwin
import Dispatch
import Foundation
import SalvageCore
import ServiceManagement
import XPC

// Story 1.12 / AD-13: the app side of the privileged read-only helper. `RawBlockReader` is the
// only caller; the app never talks to the helper's XPC service directly. Since
// spec-tech-authopen it is asked only once it is enabled; otherwise physical drives open through
// the administrator-password dialog (AuthopenClient.swift), and the helper is the optional
// "skip the password next time" path of signed builds. The helper itself is a
// separate target (SalvageHelper/) that shares HelperShared/ with this module.

/// Asks something privileged to open a validated whole disk read-only and hand back the fd.
protocol PrivilegedOpening: Sendable {
    func openWholeDiskReadOnly(_ request: PrivilegedOpenRequest) async throws -> Int32
}

enum HelperRegistrationStatus: Sendable, Equatable { case enabled, requiresApproval, notRegistered, notFound }

/// The `SMAppService` surface the client needs, injectable for tests.
protocol HelperServiceControl: Sendable {
    func status() async -> HelperRegistrationStatus
    func register() async throws
}

enum PrivilegedOpenReply: Sendable, Equatable {
    case descriptor(Int32)
    case refused(PrivilegedOpenRefusal)
    /// Connection failed, peer code signature didn't match, timed out, or the reply was garbage.
    case unavailable
}

/// The XPC round trip, injectable for tests.
protocol PrivilegedOpenTransport: Sendable {
    func send(_ request: PrivilegedOpenRequest) async -> PrivilegedOpenReply
}

/// Plain-language guidance for the one-time approval the helper needs, plus the System Settings
/// shortcut. Public so the app's approval view can show it; the app never reaches the helper.
public enum PrivilegedHelperApproval {
    public static let guidance = "Open System Settings, go to General, then Login Items (called Login Items & Extensions on newer macOS), and turn on Salvage under \u{201C}Allow in the Background\u{201D}. After that, Salvage reads USB drives and memory cards without asking for your password. It only ever reads the drive; it never changes it."
    public static let missingGuidance = "This copy of Salvage can't read USB drives or memory cards because its read-only disk access part is missing or isn't signed. Install Salvage from its official release. Disk images you own can still be scanned."
    public static let unavailableGuidance = "Salvage's read-only disk access didn't respond. Retry the scan. If it keeps failing, restart your Mac and try again."

    /// The scan error shown when approval is still needed.
    public static let approvalRequiredError = ScanError.io(guidance)
    static let missingError = ScanError.io(missingGuidance)
    static let unavailableError = ScanError.io(unavailableGuidance)

    /// Whether a scan failed only because the user hasn't approved the helper yet.
    public static func isApprovalRequired(_ error: ScanError) -> Bool { error == approvalRequiredError }

    /// The helper's errors that mean "couldn't be reached" rather than a safety refusal; only
    /// these let `openRawDevice` fall back to the administrator-password dialog.
    static func isUnavailability(_ error: ScanError) -> Bool {
        error == approvalRequiredError || error == missingError || error == unavailableError
    }

    // MARK: Optional "Skip the password next time" (signed builds)

    /// Shown under the password explanation when the helper can be turned on.
    public static let skipPasswordGuidance = "To skip the password next time, allow Salvage's read-only disk access once in System Settings. It stays read-only."

    /// What the optional helper can do for this copy of Salvage.
    public enum Offer: Sendable, Equatable {
        /// Not offered: unsigned or development build, or the helper isn't embedded.
        case unavailable
        /// Can be registered; the user then approves it in System Settings.
        case canRegister
        /// Registered, waiting for the user's approval in System Settings.
        case awaitingApproval
        /// Approved: physical drives open without a password.
        case enabled
    }

    /// The offer for this build. Only a build signed with a Team ID can run the helper (XPC
    /// requires the same team on both ends), so ad-hoc and unsigned builds never see it.
    public static func currentOffer() async -> Offer {
        await offer(teamID: currentProcessTeamIdentifier(), status: SMAppServiceDaemonControl().status())
    }

    /// Registers the helper (which needs the user's approval in System Settings next).
    public static func register() async -> Offer {
        let control = SMAppServiceDaemonControl()
        try? await control.register()
        return await offer(teamID: currentProcessTeamIdentifier(), status: control.status())
    }

    static func offer(teamID: String?, status: HelperRegistrationStatus) -> Offer {
        guard let teamID, !teamID.isEmpty else { return .unavailable }
        switch status {
        case .notFound: return .unavailable
        case .notRegistered: return .canRegister
        case .requiresApproval: return .awaitingApproval
        case .enabled: return .enabled
        }
    }

    /// Opens System Settings at Login Items, where the helper is approved.
    @MainActor public static func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}

struct PrivilegedOpenClient: PrivilegedOpening {
    let control: any HelperServiceControl
    let transport: any PrivilegedOpenTransport

    static let live = PrivilegedOpenClient(control: SMAppServiceDaemonControl(), transport: XPCPrivilegedOpenTransport())

    func openWholeDiskReadOnly(_ request: PrivilegedOpenRequest) async throws -> Int32 {
        try await ensureEnabled()
        try Task.checkCancellation()
        switch await transport.send(request) {
        case .descriptor(let descriptor):
            return descriptor
        case .refused(let refusal):
            throw Self.scanError(for: refusal)
        case .unavailable:
            // Approval can be revoked in System Settings while the app runs.
            if await control.status() == .requiresApproval { throw PrivilegedHelperApproval.approvalRequiredError }
            throw PrivilegedHelperApproval.unavailableError
        }
    }

    /// Registers the daemon on first use; any state short of enabled ends in guidance, never in
    /// an attempted connection.
    private func ensureEnabled() async throws {
        switch await control.status() {
        case .enabled: return
        case .requiresApproval: throw PrivilegedHelperApproval.approvalRequiredError
        case .notFound: throw PrivilegedHelperApproval.missingError
        case .notRegistered:
            var registerFailed = false
            do { try await control.register() } catch { registerFailed = true }
            switch await control.status() {
            case .enabled: return
            case .requiresApproval: throw PrivilegedHelperApproval.approvalRequiredError
            case .notFound: throw PrivilegedHelperApproval.missingError
            // Registration silently not taking effect is treated like a failed one.
            case .notRegistered:
                throw registerFailed ? PrivilegedHelperApproval.missingError : PrivilegedHelperApproval.approvalRequiredError
            }
        }
    }

    static func scanError(for refusal: PrivilegedOpenRefusal) -> ScanError {
        switch refusal {
        case .notWholeDisk: .unsafeTarget(RawBlockReader.notWholeDriveReason)
        case .bootDisk: .unsafeTarget(RawBlockReader.bootDriveReason)
        case .bootDiskUnresolved: .unsafeTarget(RawBlockReader.bootUnresolvedReason)
        case .deviceNotFound, .deviceChanged: .deviceChanged
        case .mountStateUnknown: .io("Couldn't verify the device is unmounted.")
        case .mounted: .io("The device was mounted again. Close files on it and retry.")
        case .permissionDenied: .permissionDenied
        case .malformedRequest, .openFailed: .io("Salvage's read-only disk access couldn't open this device.")
        case .notRootOwned, .diskImage: .unsafeTarget(otherUsersDeviceReason)
        }
    }

    /// A user's own disk images and devices open directly; anything the helper is asked for
    /// that isn't a root-owned physical disk belongs to someone else.
    static let otherUsersDeviceReason = "This device or disk image wasn't attached by you, so Salvage can't read it. Attach it from your own account and try again."
}

struct SMAppServiceDaemonControl: HelperServiceControl {
    private var service: SMAppService { SMAppService.daemon(plistName: PrivilegedOpenProtocol.launchdPlistName) }
    func status() async -> HelperRegistrationStatus {
        switch service.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notRegistered: .notRegistered
        case .notFound: .notFound
        @unknown default: .notFound
        }
    }
    func register() async throws { try service.register() }
}

/// One short-lived XPC connection per open request. The helper must carry the same Team ID as
/// this app and the helper's exact identifier, enforced by XPC on every message. Release builds
/// also require the helper to be signed with Developer ID (see `codeSigningRequirement`).
struct XPCPrivilegedOpenTransport: PrivilegedOpenTransport {
    var timeout: Duration = .seconds(15)

    func send(_ request: PrivilegedOpenRequest) async -> PrivilegedOpenReply {
        guard let team = currentProcessTeamIdentifier(),
              let requirement = codeSigningRequirement(identifier: PrivilegedOpenProtocol.helperIdentifier, teamID: team,
                                                   allowDevelopmentCertificates: PrivilegedOpenProtocol.allowsDevelopmentSigning) else {
            return .unavailable
        }
        let queue = DispatchQueue(label: "dev.hsmith.Salvage.PrivilegedOpenClient")
        let connection = ConnectionBox(xpc_connection_create_mach_service(
            PrivilegedOpenProtocol.machServiceName, queue, UInt64(XPC_CONNECTION_MACH_SERVICE_PRIVILEGED)))
        guard xpc_connection_set_peer_code_signing_requirement(connection.value, requirement) == 0 else {
            xpc_connection_cancel(connection.value)
            return .unavailable
        }
        xpc_connection_set_event_handler(connection.value) { _ in }
        xpc_connection_activate(connection.value)
        defer { xpc_connection_cancel(connection.value) }

        let message = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_int64(message, PrivilegedOpenProtocol.Key.version, PrivilegedOpenProtocol.version)
        xpc_dictionary_set_string(message, PrivilegedOpenProtocol.Key.operation, PrivilegedOpenProtocol.openOperation)
        xpc_dictionary_set_string(message, PrivilegedOpenProtocol.Key.bsdName, request.bsdName)
        xpc_dictionary_set_uint64(message, PrivilegedOpenProtocol.Key.registryID, request.registryID)
        xpc_dictionary_set_int64(message, PrivilegedOpenProtocol.Key.deviceNumber, Int64(request.deviceNumber))

        // Cancelling the connection (timeout or task cancellation) makes XPC deliver
        // XPC_ERROR_CONNECTION_INVALID to the reply handler, so it always runs exactly once.
        let timer = Task { [connection, timeout] in
            do { try await Task.sleep(for: timeout) } catch { return }
            xpc_connection_cancel(connection.value)
        }
        defer { timer.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<PrivilegedOpenReply, Never>) in
                xpc_connection_send_message_with_reply(connection.value, message, queue) { reply in
                    continuation.resume(returning: Self.decode(reply))
                }
            }
        } onCancel: {
            xpc_connection_cancel(connection.value)
        }
    }

    private static func decode(_ reply: xpc_object_t) -> PrivilegedOpenReply {
        guard xpc_get_type(reply) == XPC_TYPE_DICTIONARY else { return .unavailable }
        let descriptor = xpc_dictionary_dup_fd(reply, PrivilegedOpenProtocol.Key.descriptor)
        if descriptor >= 0 { return .descriptor(descriptor) }
        guard let raw = xpc_dictionary_get_string(reply, PrivilegedOpenProtocol.Key.refusal),
              let refusal = PrivilegedOpenRefusal(rawValue: String(cString: raw)) else { return .unavailable }
        return .refused(refusal)
    }
}

private final class ConnectionBox: @unchecked Sendable {
    // XPC connections are thread-safe; the box only lets Sendable closures carry one.
    let value: xpc_connection_t
    init(_ value: xpc_connection_t) { self.value = value }
}
