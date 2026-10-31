---
title: 'Unlock and Recover from a FileVault-Encrypted Volume'
type: 'feature'
created: '2026-10-31'
status: 'ready-for-dev'
baseline_commit: '4d050bd'
route: 'dispatch'
context:
  - '{project-root}/_bmad-output/planning-artifacts/architecture/architecture-DataRecoveryTool-2026-10-30/ARCHITECTURE-SPINE.md'
  - '{project-root}/_bmad-output/planning-artifacts/ux-designs/ux-DataRecoveryTool-2026-10-31/EXPERIENCE.md'
  - '{project-root}/_bmad-output/planning-artifacts/ux-designs/ux-DataRecoveryTool-2026-10-31/mockups/filevault-unlock-sheet.html'
  - '{project-root}/_bmad-output/implementation-artifacts/spec-1-12-read-physical-drives-via-a-read-only-privileged-helper.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** FR-6 / AD-3: unlock a FileVault (encrypted APFS) volume with a password or recovery key via `diskutil apfs unlockVolume <UUID> -nomount`, never mounting the source, credentials held only transiently, then read it through the same read-only raw path as any other device. The APFS parser (Story 2.1/2.2, in parallel) emits `.unlockRequired(device)` with `device.encryptedVolumeUUID` / `encryptedVolumeName` set when it meets an encrypted volume; `ScanViewModel` already collects these in `unlockRequests`.

**Approach:**
1. **Spike first, empirically:** on a disk image you create (`hdiutil create -fs APFS`, attach, `diskutil apfs addVolume <container> APFS Secret -passphrase <p>`, write files, `diskutil apfs lockVolume`), determine whether a raw read of the **unlocked volume's own device node** (`/dev/rdiskNsM`, after `unlockVolume -nomount`) returns the decrypted volume blocks (`APSB` at block 0). Record the answer in Implementation Notes with the exact commands. Everything below assumes yes; if no, implement only the unlock + guidance, document AD-3's alternatives explicitly, and report.
2. `SalvageDiskIO/FileVaultUnlocker.swift`: `unlock(volumeUUID:, credential:) async -> Result<UnlockedVolume, UnlockError>` running `diskutil apfs unlockVolume <UUID> -nomount -passphrase` or `-recoveryKey`, bounded by a timeout, stderr/stdout drained; distinguishes **wrong password** (`UnlockError.wrongPassword`, from diskutil's exit status/text) from **tool failure** (`.toolFailure`). The credential is passed via stdin or argument per diskutil's supported form (prefer `-stdinpassphrase` if available; verify) and is zeroed from memory after the call; it is never logged, persisted or put in `UserDefaults`. Returns the unlocked volume's BSD name (from `diskutil apfs list -plist`) and its `RawDeviceIdentity`.
3. Extend the raw-read policy so an **unlocked, unmounted APFS volume slice** can be scanned read-only: `RawBlockReader.prepare` accepts a `BlockDevice` whose `bsdName` is a slice (`diskNsM`) only when a `SalvageDiskIO` check confirms (a) it is an APFS volume whose container's physical stores are all non-boot, (b) it is unlocked, (c) it is not mounted. The whole-disk-only rule stays for everything else. If the slice node is root-owned, go through the privileged helper; the helper's whole-disk validation must then also accept this exact case with the same checks (coordinate by extending `HelperShared` validation narrowly: an APFS volume slice whose ancestors are non-boot and which is unmounted). Boot-disk refusal remains absolute.
4. UI: `FileVaultUnlockSheet` (native sheet, secure field, password vs recovery key toggle, explicit wrong-password vs tool-failure messages, VoiceOver labels). It appears when `scan.unlockRequests` is non-empty after the scan ends, or at device selection when the device is known-encrypted. On success, the app starts a scan of the unlocked volume device (as a second scan target, same `ScanViewModel.start`) and the APFS parser reads it as a bare volume (APSB). Declining leaves the rest of the results intact.
5. Device Picker: show a lock glyph plus "Locked" in the accessible label for devices whose APFS container has only locked volumes (DiskArbitration/`diskutil apfs list` query in `DeviceWatcher`'s producer path, read-only).

## Boundaries & Constraints

**Always:** Never mount. Credentials in memory only, zeroed after use; never in logs, crash reports or defaults. Unlock subprocess bounded (timeout, both pipes drained, as `BootDiskSafety.plistFromProcess` does; reuse it). Wrong password vs tool failure must be distinguished and tested with injected process output. The unlocked slice is read only via the existing `BlockReader` path (no new read API). Tests inject the process; no real `diskutil` in automated tests. Any manual check uses only images you created.

**Never:** No edits to `APFSContainer.swift` or any parser, `ScanSession.swift`, `ScanEvent.swift`, `BlockDevice.swift`, `ResultsViewModel.swift`, `FileBrowserView.swift`, `ResultsDashboardView.swift`, or CI. In `ScanViewModel.swift` you may add a method to start the follow-on scan and read `unlockRequests`; keep edits minimal and additive. In `ContentView.swift` only present the sheet. No network.

## I/O & Edge-Case Matrix

| Scenario | Input | Expected | Error handling |
|---|---|---|---|
| Encrypted volume found mid-scan | `.unlockRequired` | Sheet offered after scan ends; other results intact | — |
| Correct password | — | `unlockVolume -nomount` succeeds; follow-on scan of the unlocked slice; files recovered | — |
| Wrong password | — | "Wrong password." distinct message; retry allowed | — |
| diskutil missing/old/timeout | — | "Couldn't unlock this volume — try again or use your recovery key." tool-failure message | — |
| Decline | — | Scan results stand; no retry loop | — |
| Slice on boot container | — | Refused before any open | — |
| Slice still mounted | — | Refused | — |

</frozen-after-approval>

## Code Map

- New `SalvageDiskIO/Sources/SalvageDiskIO/FileVaultUnlocker.swift`, `APFSVolumePolicy.swift` (slice acceptance checks); edits to `RawBlockReader.swift` (slice path), `HelperShared/PrivilegedOpenProtocol.swift` and `PrivilegedDiskQueries.swift` (narrow slice acceptance), `SalvageHelper/main.swift` only if needed, `DeviceWatcher.swift` (locked state).
- New `Salvage/Views/FileVaultUnlockSheet.swift`, `Salvage/ViewModels/UnlockViewModel.swift`; minimal additive edits in `ScanViewModel.swift`, `ContentView.swift`, `DeviceListView.swift` (lock glyph).
- Tests: `SalvageDiskIO/Tests/SalvageDiskIOTests/FileVaultUnlockerTests.swift`, `APFSVolumePolicyTests.swift`; `SalvageTests/UnlockViewModelTests.swift`. Regenerate the project with `xcodegen generate`.

## Verification

- `swift test --package-path SalvageDiskIO`
- `./scripts/check-core-boundary.sh && ./scripts/check-no-network.sh && ./scripts/test-check-no-network.sh`
- `xcodebuild -project Salvage.xcodeproj -scheme Salvage -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:SalvageTests test`
- `xcodebuild -project Salvage.xcodeproj -scheme Salvage -configuration Debug -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build`
