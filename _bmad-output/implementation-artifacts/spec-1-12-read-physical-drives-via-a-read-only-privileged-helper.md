---
title: 'Read Physical Drives via a Read-Only Privileged Helper'
type: 'feature'
created: '2026-10-31'
status: 'ready-for-dev'
baseline_commit: '0654e86'
route: 'dispatch'
context:
  - '{project-root}/_bmad-output/planning-artifacts/architecture/architecture-DataRecoveryTool-2026-10-30/ARCHITECTURE-SPINE.md'
  - '{project-root}/_bmad-output/implementation-artifacts/spec-1-4-scan-a-fat32-exfat-device-with-live-progress.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Physical-drive raw nodes are `root:operator 0640` (AD-13). `RawBlockReader`'s direct `open("/dev/rdiskN")` gets EACCES for every real USB drive and SD card, so only user-owned disk images can be scanned.

**Approach:**
- Add a privileged helper: a launchd daemon target `SalvageHelper`.
  - It is embedded at `Contents/Library/LaunchDaemons/dev.hsmith.Salvage.Helper.plist` with its binary in `Contents/MacOS` (or `Contents/Library/HelperTools`).
  - The app registers it through `SMAppService.daemon(plistName:)`.
  - Over an XPC Mach service it exposes exactly one call: open a validated whole-disk raw node read-only and return the file descriptor (`xpc_dictionary_set_fd`, or `NSXPCConnection` with `FileHandle`).
- Change `RawBlockReader` so it tries a direct open first, which keeps user-owned devices and tests working. On EACCES/EPERM it asks the helper, through a `SalvageDiskIO`-owned client.
- Any scan error caused by a missing helper approval says how to approve it, and offers to open System Settings via `SMAppService.openSystemSettingsLoginItems()`.

## Boundaries & Constraints

**Always:**
- **Caller check:** the helper verifies the connecting client's code signature before serving any request. It requires the same Team ID and the bundle ID `dev.hsmith.Salvage`, using the audit token with `SecCodeCopyGuestWithAttributes` + `SecCodeCheckValidity` and a requirement string. On macOS 13+, `setCodeSigningRequirement` on the XPC connection is acceptable.
- **Requests are untrusted.** Before opening, the helper:
  - re-validates the BSD name as a whole disk (`diskN`), using the shared parsing logic, copied or moved into a tiny shared source file the helper target compiles;
  - refuses the boot disk and its APFS physical stores, failing closed if they can't be resolved;
  - opens only with `O_RDONLY | O_CLOEXEC | O_NOFOLLOW` and checks with `fstat` that it got a character device whose `st_rdev` matches the expected node.
- **What the helper never does:** write, unmount, mount, spawn processes, touch the network, or log file contents.
- **Unmounting** stays in the app via DiskArbitration (AD-4), before the open.
- **AD-12 still applies:** XPC is local IPC and allowed. Make sure `check-no-network.sh` doesn't flag it. If it does, adjust the checker narrowly (XPC is not network) and add a self-test case.
- **Signing:** this can't be fully verified without Developer ID signing on the user's machine. CI builds stay unsigned, so the helper target must build with `CODE_SIGNING_ALLOWED=NO`. Document the manual end-to-end verification steps in Implementation Notes: build signed in Xcode, approve, scan a USB stick.
- **`project.yml`:** add the helper target, the embed/copy phases and the launchd plist. Regenerate with `xcodegen generate`. Also update `release.yml` if its signing or notarization steps must cover the nested helper (sign inside-out).
- **Tests:**
  - helper request validation (names, boot refusal, fstat mismatch) as unit-testable pure functions;
  - client fallback logic in `RawBlockReader` (EACCES → helper), with an injected helper client;
  - plain-language approval guidance.

**Never:**
- Don't edit Core.
- Don't touch `DestinationSafety.swift` (Story 1.10 owns it), the parsers, `FileBrowserView`, `ResultsDashboardView`, `FilePreviewView` or `RecoverySheet`.
- In app UI, add only the approval guidance: a new `Salvage/Views/HelperApprovalView.swift`, plus mapping the new error in the existing `ScanProgressView` error copy. Change only that part.

</frozen-after-approval>

## Code Map

- `SalvageDiskIO/Sources/SalvageDiskIO/RawBlockReader.swift`: direct-open fallback.
- New `SalvageDiskIO/Sources/SalvageDiskIO/PrivilegedOpenClient.swift`.
- New `SalvageHelper/` target sources.
- `project.yml`, `.github/workflows/release.yml` if needed, and `.github/workflows/ci.yml` to build the helper unsigned.
- Tests in `SalvageDiskIO/Tests/SalvageDiskIOTests/`.

## Verification

- `swift test --package-path SalvageDiskIO`
- `./scripts/check-core-boundary.sh && ./scripts/check-no-network.sh && ./scripts/test-check-no-network.sh`
- `xcodebuild -project Salvage.xcodeproj -scheme Salvage -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:SalvageTests test`
- `xcodebuild -project Salvage.xcodeproj -scheme Salvage -configuration Debug -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build`

## Implementation Notes

### What was built

- **Helper target `SalvageHelper`** (`SalvageHelper/main.swift`, xcodegen `type: tool`): a root launchd daemon serving one Mach service, `dev.hsmith.Salvage.Helper`, with one operation, `openWholeDiskReadOnly`, over the C XPC API. The fd goes back with `xpc_dictionary_set_fd`. It is embedded at `Salvage.app/Contents/MacOS/SalvageHelper`, and its plist (`SalvageHelper/dev.hsmith.Salvage.Helper.plist`) at `Contents/Library/LaunchDaemons/`. The plist uses `BundleProgram`, `MachServices` and `AssociatedBundleIdentifiers`. It has no `RunAtLoad`, `KeepAlive` or `ProgramArguments`, so the daemon only launches on demand. A unit test pins the plist's exact key set against the protocol constants.
- **Shared sources** in `SalvageDiskIO/Sources/SalvageDiskIO/HelperShared/`. They are compiled by both the package and the helper target, so both sides run the same code. They have no SalvageCore, DiskArbitration or Process dependency.
  - `BSDDeviceNames.swift`: moved here. It adds the strict `isWholeDiskBSDName`: `disk` + 1-6 ASCII digits, no leading zero. `RawBlockReader.prepare` now uses this too. Previously it accepted any number of digits and leading zeros.
  - `PrivilegedOpenProtocol.swift`: wire keys and pure rules. These are request validation (exact key count, version, operation, name, nonzero registry ID, `dev_t` range), the boot set, the boot refusal, the fstat check, the IOMedia major/minor match, mount detection, and the code-signing requirement builder.
  - `PrivilegedDiskQueries.swift`: live read-only queries. `statfs("/")` (`bootWholeDiskBSDName` moved here from `BootDiskSafety.swift`), an IORegistry walk for the IOMedia, getfsstat, and the process's own Team ID.
- **Client** `SalvageDiskIO/Sources/SalvageDiskIO/PrivilegedOpenClient.swift`:
  - `SMAppService.daemon(plistName:)` status and register, behind an injectable `HelperServiceControl`.
  - A short-lived XPC transport behind `PrivilegedOpenTransport`, with a 15 s timeout. Cancelling the connection on timeout or task cancellation guarantees the reply handler fires once.
  - Refusal-to-`ScanError` mapping, and public `PrivilegedHelperApproval` (guidance text, `isApprovalRequired`, `openSystemSettings()` → `SMAppService.openSystemSettingsLoginItems()`).
- **`RawBlockReader`**: `openRawDevice(_:expected:directOpen:helper:)` tries `open()` directly. Only EACCES/EPERM go to the helper. Both paths then run `validateRawDescriptor`: fstat must show a char device with the expected `st_rdev`, then `F_NOCACHE` is set, and on mismatch the fd is closed and the error is `deviceChanged`. A helper fd is therefore never trusted blindly.
- **App UI**: new `Salvage/Views/HelperApprovalView.swift` (guidance + "Open System Settings"). `ScanProgressView` shows it in place of the error text for the approval error, and offers Retry for it. Nothing else in the app changed.
- **Checks/CI**:
  - `check-no-network.sh` now also scans `SalvageHelper/`.
  - `test-check-no-network.sh` adds two helper violation cases, plus a no-false-positive case showing XPC calls (`xpc_connection_*`, `NSXPCConnection`) aren't flagged. The checker itself needed no pattern change.
  - `ci.yml` builds into a known DerivedData path and asserts the embedded helper and plist layout.
  - `release.yml` adds `--timestamp` to the codesign flags, which notarization needs on every nested binary. It also verifies the nested helper's signature, identifier `dev.hsmith.Salvage.Helper`, matching Team ID, hardened runtime and timestamp.

### Judgment calls

1. **Caller check uses `xpc_connection_set_peer_code_signing_requirement`.** This is the C-API equivalent of `NSXPCConnection.setCodeSigningRequirement`, which the spec allows on macOS 13+ (deployment target is 14). It is set on each peer before activation, so XPC enforces it on every message, and a mismatch is delivered as `XPC_ERROR_PEER_CODE_SIGNING_REQUIREMENT`, which drops the peer. I didn't add the audit-token path: the C API's `xpc_connection_get_audit_token` is not public.
2. **No Team ID is hard-coded** (project.yml deliberately has no `DEVELOPMENT_TEAM`). Each side reads its *own* Team ID from its signature and pins the peer to the same team, the exact identifier, and `anchor apple generic`. That is "same Team ID" by construction. Malformed team or identifier strings produce no requirement at all, so nothing can be injected. An unsigned, ad-hoc or team-less helper exits without serving anyone, and an unsigned app never connects. Both fail closed.
3. **The app also authenticates the helper.** Its client connection carries a peer requirement for `dev.hsmith.Salvage.Helper`, so a spoofed Mach service can't hand the app an fd. The app's fstat check runs either way.
4. **Boot refusal without spawning anything.** The app's resolution runs `diskutil`, which the helper must never do. The helper uses statfs("/") for the container plus an IORegistry walk over *all* IOService-plane parents (bounded) to find the physical stores. The walk fails closed: if no physical store is found, the boot set is unresolved and every request is refused. It is resolved fresh for every request.
   - A live unit test (`registryBootResolutionMatchesDiskutil`) asserts that the walk equals the diskutil result on the test machine. It passes here ({disk3, disk0}).
   - **Stricter than the app:** the helper also refuses any disk whose IOMedia ancestry includes a protected disk. Examples are the internal SSD's other synthesized containers, such as `disk1` Recovery and `disk2` ISC, which the app's own check doesn't cover.
5. **More helper re-checks than the spec lists.**
   - The IOMedia found by BSD name must be whole, and its registry ID must equal the app's observed ID.
   - Its BSD major/minor must equal the requested `st_rdev`.
   - `lstat` before the open must show a char device with that `st_rdev`, and `fstat` after it must too.
   - The registry ID is re-checked after the open.
   - A disk with any mounted slice is refused (getfsstat).
   - The request dictionary must have exactly 5 keys.
6. **How the approval error is represented without editing Core.** It is `ScanError.io(PrivilegedHelperApproval.guidance)`, recognised by exact equality through `PrivilegedHelperApproval.isApprovalRequired`. `ScanViewModel` already carries any `ScanError` through unchanged. If Core later gains a dedicated case, only `PrivilegedOpenClient.swift` and that predicate change.
7. **When registration happens.** The client calls `SMAppService.register()` lazily, on the first EACCES, if the status is `.notRegistered`. Every non-`enabled` status ends in guidance and never in a connection attempt. A registration that fails and stays unregistered (typical for an unsigned build) gives the "component missing" message. The guidance text is tested for having no jargon (XPC, daemon, helper, root, …).
8. **Idle exit (superseded by the security-review patch below):** the helper now exits after 60 s with no open connection. It holds no state, logs nothing (so it can never log file contents), and has no `os_log`. The built binary's undefined symbols were inspected: there is no spawn, socket, connect, mount or write API.
9. **The helper fd path suspends** between the actor's identity check and the open, unlike the direct path. The helper's own registry ID, `st_rdev` and mount checks cover that window, and `prepare` already re-validates identity after the open.

### Manual end-to-end verification (needs a Developer ID / Apple Development team; NOT done here)

Nothing was installed, registered or run on the build machine. To verify on a Mac you control:

1. In Xcode, open `Salvage.xcodeproj` and set the **same Team** for the `Salvage` and `SalvageHelper` targets (Signing & Capabilities). Build and Run the `Salvage` scheme **in Debug**: only Debug builds accept Apple Development certificates (see "Security-review patch", item 3). A Release build must be signed with Developer ID Application, or the helper and app refuse each other. Then copy the built `Salvage.app` to `/Applications`, because SMAppService daemons are most reliable from there, and launch that copy.
2. Check the signatures:
   - `codesign -dv --verbose=4 /Applications/Salvage.app/Contents/MacOS/SalvageHelper` should show `Identifier=dev.hsmith.Salvage.Helper`, the same `TeamIdentifier` as the app, and `flags=…runtime`.
   - `codesign --verify --deep --strict /Applications/Salvage.app` should pass.
3. Insert a USB stick or SD card that holds disposable FAT32/exFAT test data. In Salvage, select it and start a scan.
   - **Expected:** the scan stops with the approval guidance and an "Open System Settings" button, and macOS posts a "Background Items Added" notification.
4. Click **Open System Settings**. System Settings should open at General → Login Items (& Extensions). Turn on **Salvage** under "Allow in the Background" and authenticate.
5. Back in Salvage, click **Retry scan**.
   - **Expected:** the device unmounts, the scan runs and files are listed.
   - `sudo launchctl print system/dev.hsmith.Salvage.Helper` should show the service as loaded/running.
   - `log show --last 5m --predicate 'process == "SalvageHelper"'` shows no content.
6. **Negative checks:**
   1. Select the internal boot disk (if listed). It must be refused before any open.
   2. Turn the toggle off again and retry. It must return to the approval guidance (the client re-checks status when the connection fails).
   3. Run an ad-hoc-signed copy of the app (`codesign -s - -f --deep` on a copy) against the registered helper. The connection must be refused and the error must say disk access "didn't respond"; no fd is returned.
   4. Scan an attached user-owned disk image (`hdiutil attach -nomount`). It must work without the helper being involved; it is opened directly.
7. **Open question from AD-13:** whether TCC also gates a root daemon's raw open of removable media. If step 5 fails with the Full Disk Access message (`permissionDenied`, which the helper maps from EACCES/EPERM), grant Full Disk Access to `SalvageHelper` (or Salvage) and retry. Record the result in AD-13.
8. Cleanup: turn the Login Items toggle off, or delete the app. SMAppService removes the daemon registration when the app is deleted.

### Verification run (this machine, unsigned)

- `swift test --package-path SalvageDiskIO`: `Test run with 70 tests in 11 suites passed`.
- `./scripts/check-core-boundary.sh && ./scripts/check-no-network.sh && ./scripts/test-check-no-network.sh`: all PASSED.
- `xcodebuild … CODE_SIGNING_ALLOWED=NO -only-testing:SalvageTests test`: `Test run with 50 tests in 7 suites passed`, `** TEST SUCCEEDED **`.
- `xcodebuild … CODE_SIGNING_ALLOWED=NO build`: `** BUILD SUCCEEDED **`, with no warnings from the new code. The bundle contains `Contents/MacOS/SalvageHelper` and `Contents/Library/LaunchDaemons/dev.hsmith.Salvage.Helper.plist`.

### Security-review patch (branch `p2-helper`)

1. **Cross-user disclosure (medium).** `serve` is now `servePrivilegedOpen` in `HelperShared/PrivilegedOpenProtocol.swift`: a pure core over an injectable `PrivilegedOpenSystem` (IORegistry, getfsstat, lstat, open, fstat, close). The live implementation is `LivePrivilegedOpenSystem` in `PrivilegedDiskQueries.swift`. `main.swift` only decodes, passes `xpc_connection_get_euid(peer)`, and replies.
   - The node must be owned by root, both at `lstat` before the open and at `fstat` after it. Every physical-disk node is `root:operator 0640`. A non-root node gets the new refusal `notRootOwned`.
   - Disk-image media is refused with the new `diskImage`. Media counts as a disk image when any IOService ancestor, or the media itself, matches one of these. Erring towards "image" only ever refuses.
     - a disk-image driver class: `AppleDiskImageDevice`, `AppleDiskImagesController` or the `IOHDIX*` family;
     - `Protocol Characteristics` with `Physical Interconnect` = "Disk Image", or `Physical Interconnect Location` = "File";
     - `Device Characteristics` with `Product Name` = "Disk Image".
   - On this machine (macOS 27.2) images show `AppleDiskImageDevice` with "Virtual Interface"/"File", or `IOHDIXHDDriveInKernel`. APFS containers synthesized from an image inherit the flag through the ancestor walk.
   - The peer euid is passed into the core and documented there, but not compared. Root-only ownership already makes the answer independent of the caller.
   - Wire decoding (`decodePrivilegedOpenRequest`) now requires every key with its exact XPC type. Before, a wrong-typed `deviceNumber` was read as 0, and a wrong-typed `registryID` or `version` as 0.
   - Both new refusals map to one plain-language `unsafeTarget` message (`PrivilegedOpenClient.otherUsersDeviceReason`).
   - Order: decode → media lookup → boot → whole → identity → disk image → mounts → lstat (char device, rdev, root) → open → fstat (same checks) → registry re-check (ID, not an image).
2. **APFS-layered mounts (medium).** `isMounted(_:sources:ancestorWholeDisks:)` (shared) also counts a disk as mounted when any mount source's media has it as an IORegistry ancestor. For example, disk4 is in use while disk5s1 is mounted from the container synthesized on disk4s1.
   - Mount sources are parsed strictly: `/dev/[r]diskN[sM...]`, a bare name, or `snapshot@/dev/...`. NFS and SMB sources are never looked up.
   - A disk-node source whose ancestry can't be resolved counts as mounted (fail closed). A live test asserts that every mount on the test machine resolves.
   - The ancestor walk is the existing one, generalised (`registryAncestry`), exposed as `registryAncestorWholeDisks(ofMediaNamed:)`.
   - It is applied in the helper and in both of RawBlockReader's pre-open checks (`prepare` and `NativeRawDeviceOperations.openReadOnly`), through a new `RawDeviceOperations.ancestorWholeDisks(ofMediaNamed:)`.
   - Side effect: selecting a disk image whose APFS volumes are still mounted is now refused with "mounted again". DiskArbitration's whole-disk unmount of disk4 doesn't unmount disk5's volumes.
3. **Developer ID only in Release (medium/low).** `codeSigningRequirement(identifier:teamID:allowDevelopmentCertificates:)` has two modes.
   - Strict: `anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "<TEAM>" and identifier "<id>"`.
   - Development: the previous requirement.
   - Both sides (the helper checking the app, the app checking the helper) use `PrivilegedOpenProtocol.allowsDevelopmentSigning`, which is true only when:
     - the helper target is built with `SALVAGE_HELPER_ALLOW_DEVELOPMENT`, which project.yml sets for Debug only;
     - or the SalvageDiskIO package is built with `SWIFT_PACKAGE && DEBUG`. The package can't see app-target settings, and Package.swift was out of scope. Xcode and SwiftPM set `DEBUG` only in the debug configuration.
   - Verified in the build logs: Release compiles SalvageDiskIO with `-DSWIFT_PACKAGE` and no `-DDEBUG`, and the helper's Release conditions are empty.
   - **Manual-test implications:**
     - A Debug build signed with Apple Development works end to end, as before.
     - A Release build signed with anything other than Developer ID Application fails closed. That includes Apple Development, Apple Distribution and Mac App Store certificates: the helper drops the app's connection, and the app shows "didn't respond". This is intended.
     - Test Release only with a Developer ID-signed build, such as the release workflow's artifact.
     - Don't mix a Debug app with a Release helper: both halves come from one build anyway.
4. **Access mode (low).** `validateRawDescriptor` checks `fcntl(F_GETFL) & O_ACCMODE == O_RDONLY` first. Otherwise it closes the fd and throws `unsafeTarget(RawBlockReader.writableDescriptorReason)`.
5. **SpawnConstraint (low).**
   - The source plist pins `SpawnConstraint` = `{signing-identifier: dev.hsmith.Salvage.Helper}`.
   - The Team ID isn't in the source plist, because it is never hardcoded. Instead a post-build script on the `Salvage` target (project.yml, "Pin helper SpawnConstraint team") adds `team-identifier` from `DEVELOPMENT_TEAM` to the *bundled* copy. It runs before the app is sealed, and only when `DEVELOPMENT_TEAM` is a valid 10-character Team ID.
   - `DEVELOPMENT_TEAM` comes from Xcode's team picker locally, and `release.yml` already passes it.
   - Unsigned CI builds keep the identifier-only constraint, and their helper can't serve anyway.
   - Verified by building with `DEVELOPMENT_TEAM=ABCDE12345`: the bundled plist got the team and the source plist was unchanged.
   - **Release follow-up:** after the first signed release, confirm on a real Mac that launchd spawns the helper (`sudo launchctl print system/dev.hsmith.Salvage.Helper`). If launchd rejects the constraint, `log show --predicate 'subsystem == "com.apple.xpc.launchd"'` will say so. Optionally have `release.yml` assert `plutil -extract SpawnConstraint.team-identifier raw` equals the app's team (release.yml was out of scope for this patch).
6. **Idle exit (low).** `HelperIdleTracker` (shared, pure) counts open peer connections and the last activity. A dispatch timer on the helper's serial queue is re-armed on every connection open, close and message. When it fires with no connection open and 60 s idle, the helper calls `exit(EXIT_SUCCESS)`, and launchd relaunches it on demand. Each peer is counted closed exactly once, on its first error event.
7. **Tests.**
   - New suites cover the serve core's refusal ordering (wrong-typed and missing keys included), request decoding over real XPC dictionaries, and idle exit.
   - `refusalsMapToScanErrors` now runs on a table of literal expected `ScanError`s.
   - The APFS-layered mounted case is tested in the helper core, the shared rule and `RawBlockReader.prepare`.
8. **Flaky fd-closed checks.**
   - Before: `helperDescriptorForTheWrongNodeIsClosedAndRefused` and `…WrongDeviceNumber…` used `fcntl(F_GETFD)`, which can't tell "closed" from "closed and the number reused by a parallel test".
   - The wrong-node fake now hands out a pipe's read end and probes the kept write end. Writing gets EPIPE only when our read end was closed.
   - The /dev/null fake opens with `O_NONBLOCK`, a per-open-file-description flag. "Closed" means the number is gone, or now refers to something without that flag or isn't /dev/null.
   - The suite is `.serialized`. Production checks are unchanged.

### Not done / follow-ups

- No end-to-end run with a real signed helper (see the manual steps above). That includes the security-review patch: Developer ID enforcement, SpawnConstraint and idle exit are untested on a live launchd.
- `check-core-boundary.sh` doesn't yet assert that `HelperShared/` stays free of `SalvageCore`, `DiskArbitration` and `Process`. If any of those crept in, the helper target build would fail on the first two, but not on `Process`. A narrow follow-up check would be worthwhile.
