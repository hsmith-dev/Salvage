---
title: 'Unlock and Recover from a FileVault-Encrypted Volume'
type: 'feature'
created: '2026-10-31'
status: 'review'
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

## Implementation Notes

### Spike result: the unlocked volume node is NOT raw-readable from user space (answer: no)

Run 2026-10-31 on macOS 27.2 (26B123), on a sparse APFS disk image created for the spike, never with `sudo`, never touching a real drive. Exact commands and results:

```
hdiutil create -size 1g -type SPARSE -fs APFS -volname SpikePlain fv-spike      # 100 MB was too small: addVolume failed -69493
hdiutil attach -nomount fv-spike.sparseimage
  /dev/disk18 GUID_partition_scheme, /dev/disk18s1 Apple_APFS (physical store), /dev/disk19 (synthesized container), /dev/disk19s1 (SpikePlain)
diskutil apfs addVolume disk19 APFS Secret -passphrase spike-pass-123           # -> disk19s2, FileVault: Yes (Unlocked), mounted at /Volumes/Secret
mkdir /Volumes/Secret/docs; printf '...' > /Volumes/Secret/docs/secret-note.txt; head -c 65536 /dev/urandom > /Volumes/Secret/docs/blob.bin; sync
diskutil apfs lockVolume disk19s2                                               # "APFS Volume is now unmounted and locked"; nothing from disk19 mounted
ls -l /dev/rdisk19s2                                                            # crw-r----- harrisonsmith staff  (user-owned, like every node of a user-attached image)
dd if=/dev/rdisk19s2 bs=4096 count=1 of=/dev/null                               # LOCKED:   dd: /dev/rdisk19s2: Permission denied
printf 'not-the-password' | diskutil apfs unlockVolume disk19s2 -nomount -stdinpassphrase -plist
                                                                                # exit 1; plist Success=false, DiskManagementErrorCode=-69591; stderr "Passphrase incorrect or user does not exist"
printf 'spike-pass-123' | diskutil apfs unlockVolume disk19s2 -nomount -stdinpassphrase -plist
                                                                                # exit 0; Success=true; "Unlocked but did not mount APFS Volume"; FileVault: Yes (Unlocked), Mount Point: Not Mounted
dd if=/dev/rdisk19s2 bs=4096 count=1 of=/dev/null                               # UNLOCKED: dd: /dev/rdisk19s2: Permission denied
python3 -I probe.py /dev/rdisk19s2 /dev/disk19s2 /dev/rdisk19s1 /dev/rdisk19 /dev/rdisk18s1   # open(O_RDONLY) + pread(4096, 0):
  /dev/rdisk19s2: open ok, pread failed errno=13 (EACCES)      <- unlocked encrypted volume
  /dev/disk19s2:  open ok, pread failed errno=13 (EACCES)      <- buffered node, same
  /dev/rdisk19s1: open ok, pread failed errno=13 (EACCES)      <- plain, UNencrypted volume: same refusal
  /dev/rdisk19:   open ok, pread ok, magic@0x20 = 'NXSB'       <- container reads fine (ciphertext for the encrypted volume's blocks)
  /dev/rdisk18s1: open ok, pread ok, magic@0x20 = 'NXSB'       <- physical store reads fine
diskutil apfs unlockVolume 34CFAFFA-3ECE-46A6-937D-93E622EAA34B -nomount -stdinpassphrase -plist   # a volume UUID is accepted as the identifier too
diskutil apfs unlockVolume disk19s2 ... (already unlocked)  -> exit 1, "The given APFS Volume is not locked (-69589)"
diskutil apfs unlockVolume disk19s1 ... (unencrypted)       -> exit 1, "not encrypted (-69593)";  disk99s9 -> exit 1, "Could not find APFS Volume"
hdiutil detach disk18; rm fv-spike.sparseimage
```

Conclusion: `open()` on an APFS *volume* node succeeds but every `read()` fails with EACCES at read time, for locked, unlocked and even unencrypted volumes; the APFS driver refuses raw reads of volume devices from user space regardless of node ownership. Only the container and physical-store nodes are readable, and they hold the ciphertext. So "read the decrypted blocks through the unlocked volume's own node via the existing raw path" is not available to the app. Whether a root process (the privileged helper) can read a volume node was **not** tested (no `sudo`, per the brief) and is assumed no; and because the EACCES is raised at read time, a root-opened fd read by the app would most likely be refused too, so the AD-13 helper (which never reads bytes itself) would not help without widening its charter.

Per the Approach's step 1, this story therefore ships **unlock + guidance** (plus the picker's locked state) and **not** the slice read path: no edits to `RawBlockReader.swift`, `HelperShared/*`, `SalvageHelper/main.swift`, and no `APFSVolumePolicy.swift`. The IORegistry (`AppleAPFSVolume`) exposes `UUID`, `Role`, `Open`, `Content` but not Locked/Encrypted, so the picker's lock state comes from `diskutil apfs list -plist` (metadata only, read-only), as the Approach allows.

### AD-3's alternatives for actually reading the decrypted data (for the human to choose; none built here)

1. **Decrypt in `SalvageCore` from the container's raw bytes** (recommended; keeps AD-3 "never mount" and AD-4 "same raw path" intact). Apple's APFS Reference documents it: container keybag (`nx_keylocker`) -> volume keybag -> unwrap the KEK from the password with PBKDF2 and RFC 3394 AES key-wrap -> VEK -> AES-XTS decrypt of file-system and file-data blocks with the block number as tweak. CommonCrypto has PBKDF2 and XTS. The credential then never leaves the app (no `diskutil` needed for the read; `unlockVolume` could stay only as a password check), still zeroized after key derivation. Substantial SalvageCore work (its own story); `FileVaultUnlocker` as built remains useful as the credential-verification step and for the "already unlocked" detection.
2. **Mount read-only** (`unlockVolume` without `-nomount`, or `mount -t apfs -o rdonly`) and recover through the live filesystem. Violates AD-3/FR-15's "never mount the source" as written and recovers no deleted files (the whole point of parsing raw structures), so it needs a human renegotiation; not recommended.
3. **Have the root helper read the volume node** (or open it and hand the fd back). Untested whether root is allowed to read APFS volume devices at all; would widen the helper beyond "open one validated whole disk, read nothing" (spec 1.12's security review), so it would need its own review and spec.

### What was built

- `SalvageDiskIO/FileVaultUnlocker.swift`: `FileVaultUnlocker.unlock(volumeUUID:credential:) async -> Result<UnlockedVolume, UnlockError>`. Validates the UUID shape strictly (so no option or path can be smuggled to `diskutil`), resolves the volume's BSD name/name/state from `diskutil apfs list -plist`, returns success without touching the credential when the volume is already unlocked, otherwise runs `diskutil apfs unlockVolume <diskNsM> -nomount -stdinpassphrase -plist` with the secret on **stdin** (verified available in the spike; never an argument, never in the process table). `interpretUnlockOutput` distinguishes wrong password (`DiskManagementErrorCode -69591`, or the "Passphrase incorrect" text for a diskutil without `-plist`) from tool failure (anything else, including timeout); `-69589` "not locked" counts as success. `lock(bsdName:)` runs `diskutil apfs lockVolume` to leave the volume as found. `UnlockedVolume` carries the UUID, BSD name and name; it does not carry a `RawDeviceIdentity` because nothing can read the slice (see spike) and `RawDeviceIdentity` is defined for whole disks only.
- Credentials: `SensitiveBytes` (in `BootDiskSafety.swift`, next to the process runner) holds the UTF-8 bytes, is read in place by the stdin writer (never copied into a `Data`), and is erased with `memset_s` on `zero()` and on `deinit`; `UnlockCredential` wraps it with a kind. `unlock` zeroes it on every path (`defer`), and `UnlockViewModel` zeroes it again after the call and clears the bound `secret` string the moment an attempt starts. Limit, stated honestly: the `String` the user typed lives in SwiftUI's text storage until it is cleared/freed and can't be scrubbed from Swift; what this guarantees is that the copy handed to the subprocess is erased. Nothing logs, prints, or persists the credential; no `UserDefaults` are touched.
- `runBoundedProcess` (refactored out of `plistFromProcess`, which now calls it): hard deadline, stdout and stderr both drained concurrently, optional stdin bytes written on a worker with `F_SETNOSIGPIPE` so a child that exits early can't SIGPIPE the app, terminate-then-kill on timeout. Unlock gets 60 s (key derivation), listings keep 10 s.
- `SalvageDiskIO/APFSVolumeListing.swift`: pure decoding of `diskutil apfs list -plist` (`apfsContainers`, `apfsVolume(uuid:)`, `lockedVolume(onWholeDisk:)`, `isAPFSVolumeUUID`) plus the live query. A disk is "Locked" when every volume of every container it takes part in (as synthesized container disk or as physical store) is locked and there is at least one.
- `DeviceWatcher`: after each emission of the plain device set, a detached task runs the listing off the main thread and, if any device is fully locked, re-emits the full set with those devices annotated via the existing `BlockDevice.requiringUnlock(volumeUUID:volumeName:)` (a generation counter drops stale annotations). `BlockDevice.swift` is frozen for this story, so `encryptedVolumeUUID != nil` is the picker's "known-encrypted" signal; its doc comment says "set only on the value carried by `.unlockRequired`", and this story extends that meaning to the picker's locked devices (follow-up: widen the comment or add an explicit field when `BlockDevice.swift` is editable). Injectable `lockStateResolver` keeps `DeviceWatcher`'s tests free of diskutil.
- `Salvage/ViewModels/UnlockViewModel.swift` and `Salvage/Views/FileVaultUnlockSheet.swift`: native sheet, `SecureField`, segmented Password / Recovery Key toggle, "Wrong password." / "Wrong recovery key." vs "Couldn't unlock this volume — try again or use your recovery key.", VoiceOver labels and an explicit error announcement, Escape = Cancel, `interactiveDismissDisabled`. Offered (a) at device selection for a picker-locked device, with the scan starting after the sheet resolves either way, and (b) after a scan ends, once per encrypted volume in `scan.unlockRequests`. Each volume is offered once per session (no retry loop after a decline). On success the volume is **re-locked** and the sheet shows the guidance that this version can't read it without mounting; a recovery key is whitespace-trimmed, a password is not.
- `ContentView.swift`: only presents the sheet and routes its resolution to `scan.start`. `DeviceListView.swift`: `lock.fill` glyph, "· Locked" in the row subtitle, and "Locked, <size>" in the accessibility value. `ScanViewModel.swift` was not edited: with no follow-on scan there was no method to add.
- Tests: `FileVaultUnlockerTests` (injected diskutil: stdin delivery, argument hygiene, wrong-password by code and text, tool failures, listing failures, already-unlocked, malformed UUID, relock, zeroing; live `/bin/cat`, `/bin/sh`, `/bin/sleep` for the bounded runner), `APFSVolumeListingTests` (plist decoding, lock rule, UUID shape, device annotation), `UnlockViewModelTests` (offers, messages, retry, success/relock, cancel-while-unlocking, copy). No real `diskutil` runs in any automated test.

### Judgment calls

- Re-locking after a successful unlock: since nothing can read the unlocked volume, leaving it unlocked (keys in the kernel) would benefit no one; `lockVolume` on an unmounted volume is a metadata operation and restores the state Salvage found. The guidance says plainly whether the re-lock succeeded.
- The scan still proceeds after a pre-scan unlock sheet (declined or not): the container's unencrypted volumes and carving results are reachable; the parser's `.unlockRequired` for the same volume is not re-offered because the UUID is already handled.
- `Encryption == true` is required before an unlock is attempted; an unencrypted volume is reported as a tool failure without spending the credential.

### Verification (all passed, 2026-10-31)

- `swift test --package-path SalvageDiskIO`: `Test run with 148 tests in 20 suites passed`.
- `./scripts/check-core-boundary.sh && ./scripts/check-no-network.sh && ./scripts/test-check-no-network.sh`: all PASSED.
- `xcodebuild ... -only-testing:SalvageTests test`: `Test run with 122 tests in 11 suites passed`, `** TEST SUCCEEDED **`.
- `xcodebuild ... build`: `** BUILD SUCCEEDED **`.

### Review fixes (2026-10-31, branch p3-filevault)

These supersede the matching sentences in "What was built" and "Judgment calls" above.

1. **Already unlocked is its own outcome.** `FileVaultUnlocker.unlock` now returns `Result<UnlockOutcome, UnlockError>`. `UnlockOutcome.unlocked` means Salvage unlocked the volume in this call, so diskutil verified the credential. `.alreadyUnlocked` means the listing showed it unlocked, or diskutil answered "not locked" (-69589) to the attempt. In that case no credential was verified, success is never reported, and `UnlockViewModel` never relocks it. Only `.unlocked` is relocked. `interpretUnlockOutput` returns `UnlockInterpretation` (`.unlocked` / `.alreadyUnlocked` / `.failed`).
2. **Cancel during "Unlocking…" no longer drops the attempt.** The unlock task is never cancelled. If it ends `.unlocked`, it is relocked, even after the sheet closed, and a late result lands in `abandonedOutcomes`. Every scan start in `ContentView` (picker selection, sheet resolution, system dismissal) goes through `startAfterPendingUnlock`, which awaits `waitForPendingUnlock()` first. An attempt submitted while an older one is still running is chained after it.
3. **The sheet is withheld.** `FileVaultUnlockFeature.canReadUnlockedVolumes` (in `UnlockViewModel.swift`) is `false`, with a doc comment pointing at AD-3 and the follow-on story. While it is off, the model never raises a request on either path. A locked picker row shows an inline note, which is also in its accessibility value, and the detail column shows a bottom note (`EncryptedVolumeNote`) whenever the flow met an encrypted volume. Both use: "This drive has a FileVault-encrypted volume. Salvage can't recover files from encrypted volumes yet; its unencrypted volumes are scanned as usual." The unlocker, view model, sheet and their tests are kept and run with `presentsSheet: true`.
4. **Picker lock state refreshes.** `DARegisterDiskDescriptionChangedCallback` (no match or watch filter) is registered and unregistered alongside appeared/disappeared. The publish flow moved into `DeviceSetPublisher` (main actor, unit-tested without a `DASession`). It publishes the plain set only when the set of disks changed, re-resolves lock state on every change, and publishes the annotation whenever it differs from what was **last published**. The old code compared against the plain set, so a volume unlocked outside Salvage kept a stale "Locked". Only one resolver runs at a time: a change during a run queues one re-run, and a stale generation's answer is dropped.
5. **Cancel is per flow, not per session.** A flow is one device selection plus its scan. `offerBeforeScan` starts a new flow, so selecting the locked row again offers again, while that scan's `.unlockRequired` for the same volume is not re-asked.
6. **The listing is off the cooperative pool.** `DeviceWatcher.annotateLockedDevices` runs `liveAPFSContainers()` through `offCooperativePool` (now internal and shared with the unlocker), so it never runs on the main actor or a cooperative-pool thread.
7. **Every scan volume is offered once.** `offer(fromScan:)` queues every unhandled volume and presents them in turn, also when a sheet was already open when the scan ended. `ContentView` triggers it on `scan.endedAt`. With the sheet withheld, each volume is recorded once in `guidanceVolumeUUIDs`.
8. **Tests.** `DeviceWatcherLockStateTests` covers an injected resolver, a second emission clearing a stale Locked state, generation drop plus one-at-a-time, and the GCD hop. The cancel-while-unlocking tests now await a signal (`CountSignal`, cancellation-aware, so the suites' `.timeLimit(.minutes(1))` fails a regression instead of hanging) and cover a late `.success` (relocked before the scan starts) and a late `.alreadyUnlocked` (never relocked). `childThatIgnoresStdinStillCompletes` writes 256 KB, more than the 64 KB pipe buffer, to a child that exits at once. Mutation-checked: restoring the old stale-lock comparison and the inline listing makes the new DeviceWatcher tests fail.
9. **Secret lifetime.** `submit()` takes the bound `secret`, clears it in the same step, and builds `UnlockCredential(kind:secret:trimmingWhitespace:)`. The new initializer trims a recovery key on the UTF-8 bytes, so no trimmed `String` copy is made. A blank key is zeroed and never submitted. Two copies can't be zeroed: the `String` storage the `SecureField` binding held while the user typed (Swift strings are immutable and are freed, not scrubbed), and whatever AppKit's secure field editor keeps internally.

Verification (2026-10-31): `swift test --package-path SalvageDiskIO`: 155 tests in 21 suites passed. `check-core-boundary.sh`, `check-no-network.sh` and `test-check-no-network.sh`: passed. `xcodebuild ... -only-testing:SalvageTests test`: 133 tests in 12 suites passed, `** TEST SUCCEEDED **`. `xcodebuild ... build`: `** BUILD SUCCEEDED **`.
