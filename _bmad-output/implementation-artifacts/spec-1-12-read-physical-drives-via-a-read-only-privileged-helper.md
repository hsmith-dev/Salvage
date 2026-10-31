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
