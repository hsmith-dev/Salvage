---
title: 'Scan a FAT32/exFAT Device with Live Progress'
type: 'feature'
created: '2026-10-31'
status: 'done'
baseline_commit: 'b61bb2d0443772da491a7a8de9438f1f66525c7e'
route: 'dispatch'
review_loop_iteration: 0
context:
  - '{project-root}/_bmad-output/implementation-artifacts/epic-1-context.md'
  - '{project-root}/_bmad-output/planning-artifacts/architecture/architecture-DataRecoveryTool-2026-10-30/ARCHITECTURE-SPINE.md'
  - '{project-root}/_bmad-output/planning-artifacts/ux-designs/ux-DataRecoveryTool-2026-10-31/DESIGN.md'
  - '{project-root}/_bmad-output/planning-artifacts/ux-designs/ux-DataRecoveryTool-2026-10-31/EXPERIENCE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Story 1.3 lists devices but selection cannot start a scan. BMAD Story 1.4 requires live progress and streaming discoveries on FAT32/exFAT media.

**Approach:** Implement a read-only scanning engine behind Core's injectable `BlockReader`, a protected macOS raw-device adapter, and the scan-progress surface. Selecting an eligible device starts scanning immediately, following the existing UX plan. Show discovered intact file metadata as it arrives; deleted-file reconstruction remains Story 1.6.

## Boundaries & Constraints

**Always:**
- Preserve the existing uncommitted Story 1.3 work. Follow AD-1, AD-4, AD-5, AD-11 and the native utility design.
- Re-resolve boot protection before unmount and immediately before opening a raw device. Resolution failure refuses the scan. Unmount the whole disk successfully before opening `/dev/rdiskN` read-only. Hold an actor-owned device reservation through cleanup; reject duplicate sessions.
- Validate target identity across asynchronous preparation; reject disappearance/replacement. Close descriptors and release reservations on every terminal path, including cancellation and setup errors.
- Support unpartitioned FAT32/exFAT and supported volumes inside MBR/GPT devices. Bound every read by the actual device and partition extents; reject malformed arithmetic, cycles, truncated structures and unsupported layouts explicitly.
- Emit the exact AD-11 `ScanEvent` cases. Progress must represent measured work; never invent elapsed time, remaining time or completion. Keep the UI responsive during preparation and scanning. Unknown ETA is shown as calculating.
- Preserve filename/path/size and metadata source locations needed by later recovery. Discovered files appear before completion. Distinguish indexed files from files already copied/recovered.
- Permission errors explain how to grant Full Disk Access and retry; never grant it automatically. Make no network calls or source writes.

**Never:** No destination writes, carving, FileVault unlock, confidence scoring UI, file previews or result buckets in this story. Pause/checkpoint/resume belongs to Story 1.5; do not offer nonfunctional controls. A basic cancel action may terminate the task and retain discoveries for safety.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|---|---|---|---|
| FAT32/exFAT | Valid image with nested files | Stream discoveries, progress, completion | No source mutation |
| Partitioned disk | Valid MBR/GPT with supported volume | Scan within volume extents | Reject invalid partition bounds |
| Unsupported format | APFS, FAT12/16, unknown bytes | Explain unsupported filesystem | No successful empty scan |
| Unsafe target | Boot disk or unresolved protection | Refuse before raw access | Clear safety reason |
| Preparation fails | Unmount denied, permission denied, detached/replaced device | No scanning; release reservation | Actionable error |
| Duplicate session | Second scan of same BSD device | Reject second operation | First scan continues |
| Corrupt metadata | Bad offsets, overflow, truncated directory, cyclic chains | Bounded reads and termination | Error, retain prior discoveries |
| Cancellation | Cancel during preparation or reading | End without completed event; retain discoveries | Cleanup before reservation release |

</frozen-after-approval>

## Code Map

- `Salvage/ViewModels/DeviceListViewModel.swift` — canonical selection validation and cancellable watching; preserve its tests.
- `Salvage/Views/DeviceListView.swift`, `ContentView.swift` — connect selection to the session through the app composition root.
- `SalvageDiskIO/Sources/SalvageDiskIO/BootDiskSafety.swift`, `BSDDeviceNames.swift` — reuse validated naming and fail-closed boot resolution.
- `scripts/spike-raw-device-access/Sources/spike-raw-device-access/Unmount.swift`, `RawRead.swift` — proven API shape only; do not port polling, skipped-unmount or continue-after-failure behavior into production.
- `project.yml` — source of truth for app/test targets; regenerate the Xcode project after adding files.

## Tasks & Acceptance

**Execution:**
- [x] `SalvageCore/Sources/SalvageCore/Ports/BlockReader.swift` — read-only injectable async reader.
- [x] `SalvageCore/Sources/SalvageCore/Entities/ScanEvent.swift` — shared event, error and discovered-file entities consistent with AD-11.
- [x] `SalvageCore/Sources/SalvageCore/Parsers/` — bounded partition discovery and FAT32/exFAT geometry, directory and allocation-chain parsing.
- [x] `SalvageCore/Sources/SalvageCore/ScanSession.swift` — cancellable engine streaming discoveries and measured progress.
- [x] `SalvageDiskIO/Sources/SalvageDiskIO/RawBlockReader.swift` — protected preparation, session reservation, read-only aligned I/O and cleanup.
- [x] `Salvage/ViewModels/ScanViewModel.swift`, `Salvage/Views/ScanProgressView.swift` — preparation, running, complete, cancelled and error states, live discoveries and timing.
- [x] `Salvage/Views/ContentView.swift`, `DeviceListView.swift`, `project.yml` — wire device selection to scanning and register files.
- [x] `SalvageCore/Tests/SalvageCoreTests/`, `SalvageDiskIO/Tests/SalvageDiskIOTests/`, `SalvageTests/` — matrix coverage with synthetic images and injected preparation failures; no real-device mutation in automated tests.

**Acceptance Criteria:**
- Given a supported device, when selected, then progress, elapsed time, estimated remaining time when meaningful, and file count update at least every approximately two seconds while work advances.
- Given an intact file, when discovered, then its metadata appears before the completed event.
- Given concurrent scan attempts, when targeting the same device, then only one owns the read session.

## Implementation Notes

Story 1.2's successful FDA-granted raw read is still unverified. Implement and test with synthetic images and injected adapters; keep real-device acceptance pending a human-granted FDA check. Unmounting plus an app-owned reservation cannot exclude every privileged external process; do not claim an OS-wide exclusive lock.

Format references: Microsoft's FAT specification and exFAT specification. Implement original Swift code; no external parser dependency.

## Spec Change Log

## Review Triage Log

Review pass 1: individual findings verified before grouping. B = blind hunter, E = edge-case hunter, V = verification-gap reviewer.

| Finding | Verdict | Route | Evidence |
|---|---|---|---|
| B1 unbounded discoveries | medium | patch | ScanViewModel creates an unbounded stream and Core yields without waiting; a slow consumer can accumulate every pending discovery. Bound the queue and preserve file/terminal events with producer backpressure. |
| B2 repeated FAT reads | medium | patch | next() requests four bytes for each link; RawBlockReader aligns every request to a sector. Adjacent links reread identical sectors, amplified further by directory validation/traversal. Add a bounded FAT page cache. |
| B3 benign exFAT secondaries | medium | patch | exfatEntry requires all remaining entries to be filenames and exact filename-only count, so valid vendor secondary extensions fail as corrupt. Preserve checksum validation and skip benign secondary entries. |
| B4 free exFAT allocations | medium | patch | Root bitmap entries are skipped and contiguous allocations are checked only against numeric bounds. Validate referenced clusters against the active bitmap before indexing intact files. |
| B5 shared allocations | medium | patch | Each validateFile invocation creates an independent seen set; two live entries referencing one cluster both succeed. Track ownership per volume and reject cross-links. |
| B6 backup exFAT recovery | low | reject | Main-region damage is explicitly rejected as the approved corruption behavior. Trying backup metadata is an additional recovery capability with substantial logic; this scan slice does not promise damaged-boot reconstruction. |
| B7 unsupported sector unmount | medium | patch | Raw preparation accepts sector sizes the scanner always refuses, causing a needless unmount/open. Reject known unsupported geometry before unmounting. |
| B8 malformed LFN terminator | medium | patch | fatName removes all NUL/FFFF units rather than stopping; A,NUL,B is returned as AB. Validate terminator/padding and use the short-name fallback. |
| B9 malformed UTF16 | medium | patch | String(decoding:as:) replaces isolated surrogates, changing source names. Reject invalid exFAT names and fall back to short FAT names on invalid LFN encoding. |
| B10 duplicate volume paths | medium | patch | ScanProgressView shows path and size only, making equal paths on separate supported volumes indistinguishable. Add a stable volume label when multiple volumes have discoveries. |
| E1 malformed LFN terminator | medium | patch | Same demonstrated decoding defect as B8; grouped only after this individual verdict. |
| E2 shared allocations | medium | patch | Same independent-chain ownership gap as B5, including directory overlaps. |
| E3 absent attachment identity | medium | patch | Public BlockDevice permits nil identity and prepare explicitly accepts it. A same-sized replacement cannot then be compared against the selected attachment. Refuse absent identity at production preparation. |
| E4 subprocess hang | medium | defer | diskUtilInfoPlist predates this story and synchronously drains stdout while stderr is undrained, with no timeout. Existing watcher startup already has the same hang; add a bounded, concurrently drained subprocess path in a follow-up. |
| E5 disk64 enumeration | low | reject | Existing Story 1.3 triage already rejected this uncommon fixed-slot limit; unchanged enumeration bounds predate this story. Dynamic enumeration is more than a direct correction. |
| V1 intermediate progress coverage | medium | patch | Filed test evidence is accepted: tests require final progress only; deleting periodic emissions would pass. Add an advancing-clock test requiring intermediate measured progress before completion. |
| V2 native remount coverage | high | patch | Filed evidence is accepted: all preparation fakes replace native open and its mount check. Inject mount sources into the native check and verify refusal without opening disks. |
| Root mount-table storage | medium | patch | getmntinfo returns shared mount-table storage while separate NativeRawDeviceOperations actors can execute concurrently. Enumerate into owned storage and test the same remount guard used by production. |

Grouped fixes: B8/E1 and B5/E2 share root causes. All other patch findings remain independent. No frozen intent change or new public API is needed. Keep the working contracts, filesystem boundaries, measured-byte semantics, and existing failure/cancellation checks.

Review pass 2 (orchestrator, independent): pass 1 above was produced outside the orchestrated pipeline, so it was treated as unverified. A fresh blind hunter, edge-case hunter and verification-gap reviewer ran against the combined Story 1.3+1.4 diff from `b61bb2d`. The verification-gap reviewer traced each pass-1 "patch" item to the code and confirmed them all as genuinely fixed with non-vacuous tests. Its other findings were wrong test counts (corrected below) and three test gaps.

| Finding | Verdict | Route | Evidence / resolution |
|---|---|---|---|
| R1 orphaned FAT32 LFN run | medium | patch | An unterminated LFN run was dropped silently at the end marker or when the chain ran out. It now throws `malformed`; deleted 0xE5 slots are still tolerated. Tests: `orphanedLongFilenameRunIsMalformed`, `deletedLongFilenameSlotsAreStillTolerated`. |
| R2 up-case table unclaimed | medium | patch | Clusters of the exFAT 0x82 entry were never claimed, so a file overlapping the up-case table passed. They are now validated and claimed. Test: `exFATUpcaseTableIsClaimedAgainstCrossLinks`. |
| R3 reservation held forever | high | patch | Two reviewers found it independently: an unread stderr pipe and no timeout on `diskutil`, plus an unbounded `DADiskUnmount` wait. Overrides pass-1 E4's defer. Fix: stderr to the null device, 10s subprocess deadline, a one-shot unmount completion with a 30s timeout and cancellation. Tests: `hungSubprocessTimesOut`, `noisyStderrDoesNotDeadlock`, `OneShotCompletionTests`, `failedPreparationLeavesDeviceReacquirable`, `cancelledHangingUnmountReleasesAndDeviceIsReacquirable`. |
| R4 error overwritten by Cancel | medium | patch | When an `.error` event raced Cancel, the scan was shown as `.cancelled`. `.failed` now wins. Test: `deliveredErrorSurvivesRacingCancel`. |
| R5 boot message for malformed name | low | patch | Refusal messages split. Tests assert the exact text. |
| R6 progress range merge O(n²) | low | patch | Binary-search insertion point. Test: `measuredCoverageStaysExactAcrossManyDisjointReads`. |
| R7 empty list looks benign | low | patch | Distinct anomaly copy, because the startup disk always enumerates. Tests: `emptySnapshotIsAnomalous`, `watchErrorIsNotEmptyAnomaly`. |
| R8 malformed `ParentWholeDisk` untested | low | patch | Fail-closed tests added. A slice-shaped value (`disk6s2`) normalizes to `disk6`, which still protects the physical disk. |
| R9 chain claimed past declared size / one bad partition stops scan | medium | defer | Consistent with this story's fail-closed behaviour for intact metadata. Logged in `deferred-work.md` for Epic 3 corruption tolerance. |
| R10 watcher cancel leaks DASession | — | reject | `watchTask.cancel()` ends the `for await` over `AsyncStream`, which runs `onTermination` and so `DiskWatchRegistration.stop()`. |


## Verification

- `swift test --package-path SalvageCore`
- `swift test --package-path SalvageDiskIO`
- `./scripts/check-core-boundary.sh`
- `xcodebuild -project Salvage.xcodeproj -scheme Salvage -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test`
- Manual: approved non-boot disposable FAT32/exFAT media, FDA refusal/retry, live progress, removal and cancellation; confirm source stays unmounted during reading. Record unperformed checks explicitly.

### Implementation verification — 2026-10-31

Implemented the read-only port and exact AD-11 event cases, bounded FAT32/exFAT parsers, MBR/GPT discovery, measured unique-byte progress, protected raw-device preparation/cleanup, and the native scan surface. Directory traversal streams intact files first; a subsequent read-only pass finishes scanning the supported partition extents. The UI labels progress as supported-volume bytes read and files as indexed, never copied or recovered. Existing device-selection validation and Story 1.3 tests remain in place. `project.yml` already includes application/test source directories; `xcodegen generate` registered the added files in the committed project.

Automated checks passed:

- `swift test --package-path SalvageCore`: 24 tests, including FAT32 and exFAT nested directories, long-name checksum/fallback, contiguous exFAT streams, metadata-source offsets, pre-completion discovery delivery, measured full extent reads, MBR/GPT bounds and CRCs, unsupported/truncated/corrupt metadata, allocation cycles, cancellation, and retained discoveries after corruption.
- `swift test --package-path SalvageDiskIO`: 21 tests, including duplicate reservations, stale attachment identity, boot/protection/unmount/permission/setup failures, identity change after open, cancellation while unmount is pending, descriptor cleanup, aligned regular-file reads with unaligned requested slices, short reads, bounds, and closed-session refusal. No real devices were opened or unmounted by these tests.
- `./scripts/check-core-boundary.sh`: passed.
- `xcodebuild -project Salvage.xcodeproj -scheme Salvage -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test`: passed, 56 tests across app (11), Core (24), and DiskIO (21). App tests cover preparation/cancellation, live metadata retention on failure, completion, unknown ETA, deterministic measured-rate ETA, and FDA retry, alongside all existing device-list tests.
- **Correction (orchestrator, pass 2):** the counts above were wrong. Re-run before pass 2 they were Core 32, DiskIO 24 and app 12. After the pass-2 patches, re-run by the orchestrator: Core **36** tests in 3 suites, DiskIO **36** tests in 7 suites, app **15** tests in 2 suites, spike harness 21. Both boundary checks pass and the full app build succeeds.
- **Not yet performed:** the manual check on real removable FAT32/exFAT media. It needs Full Disk Access granted by hand, which is still outstanding from Story 1.2.
- Independent regular-file fixtures: a macOS `newfs_msdos` FAT32 image and a separate exFAT image with main/backup boot checksums, allocation bitmap and upcase table both streamed their intact test file before measured completion. These did not use raw-device access.

Intentional unsupported layouts are reported explicitly: non-512-byte logical-sector devices, MBR extended partitions, hybrid partition maps, and unsupported filesystems. GPT primary header/table CRCs and exFAT main boot/entry-set checksums are validated. Full Disk Access remains a manual user action; the error explains how to grant it and offers retry.

Manual checks **not performed**: FDA-granted raw reads on disposable non-boot FAT32/exFAT hardware, live device removal, hardware cancellation, source-unmounted verification while reading, and VoiceOver/keyboard checks. These remain pending human-approved disposable media and FDA access. No real source device was modified or unmounted during automated verification.

Residual platform limitation: cancellation of an already submitted DiskArbitration unmount waits for its completion callback before releasing the reservation; a hung OS operation can therefore delay cancellation. Boot-resolution subprocesses also finish before cancellation is observed. The reservation protects app-owned sessions only; it is not an OS-wide exclusive lock and cannot exclude privileged external processes that remount or alter a source after preparation.
