---
title: 'Select and List Scan-Target Devices'
type: 'feature'
created: '2026-10-31'
status: 'done'
route: 'dispatch'
review_loop_iteration: 0
baseline_commit: 'b61bb2d0443772da491a7a8de9438f1f66525c7e'
context:
  - '{project-root}/_bmad-output/implementation-artifacts/epic-1-context.md'
  - '{project-root}/_bmad-output/planning-artifacts/ux-designs/ux-DataRecoveryTool-2026-10-31/DESIGN.md'
  - '{project-root}/_bmad-output/planning-artifacts/ux-designs/ux-DataRecoveryTool-2026-10-31/EXPERIENCE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** `Salvage` currently shows a static placeholder window. FR-1 requires a live device picker — the entry point to every recovery session — and nothing exists yet.

**Approach:** Add a `BlockDevice` entity (`SalvageCore`), a DiskArbitration-backed device watcher that emits live updates (`SalvageDiskIO`), and a SwiftUI list view (`Salvage`) consuming it. Story 1.2's spike harness already prototyped and unit-tested the hard parts (BSD-name parsing, boot-disk resolution) — port that logic into production code here rather than re-deriving it, now that it's proven correct against real hardware.

**Resolved decision:** `BlockDevice` models whole disks only, not individual volumes — matches Architecture's ERD (`ScanSession` targets a whole `BlockDevice` or a `LostPartitionCandidate`, never an arbitrary volume) and UJ-1 ("selects the external SSD from the device list"). Live updates use DiskArbitration's appear/disappear callbacks (not polling), scheduled on the app's main run loop, published as `AsyncStream<[BlockDevice]>` per AD-5's structured-concurrency-only rule.

**Scope boundary with Story 1.4:** this story lists devices and captures which one is selected — it does not start a scan. FR-2 (live scan progress) is Story 1.4's.

**Resolved decision:** port Story 1.2's tested BSD-name-parsing and boot-disk-resolution logic into `SalvageDiskIO` close to verbatim (adapted to produce `BlockDevice` values instead of printing), rather than re-deriving equivalent logic fresh — that logic is proven against real hardware and was hardened through a safety-focused review pass; re-deriving it risks reintroducing the same fail-open bugs that review caught. The live-watching mechanism (DiskArbitration appear/disappear callbacks) is new work regardless, since the spike only ever did one-shot enumeration.

## Boundaries & Constraints

**Always:**
- `BlockDevice` lives in `SalvageCore/Entities/` as a plain value type — no DiskArbitration/Foundation-beyond-basics dependency, per AD-1.
- Device watching/enumeration lives in `SalvageDiskIO` — the exclusive DiskArbitration owner (AD-1, AD-9's CI-enforced boundary).
- The boot volume appears in the list, grayed, with its one-line reason stated — never silently omitted (DESIGN.md Components → Device row; EXPERIENCE.md State Patterns → "Boot volume present").
- Internal and external devices appear in one unified list, not separate sections/modes (FR-1, EXPERIENCE.md Component Patterns → Device row).
- The list updates live when a device is attached or removed, without restarting the app (FR-1's own Consequence).
- Reuse Story 1.2's already-tested BSD-name-parsing and boot-disk-resolution logic (port it into `SalvageDiskIO`, don't re-derive it) — that logic is unit-tested and was hardened through a real safety-focused review pass; re-deriving it from scratch risks reintroducing the same fail-open bugs that review caught.

**Never:**
- No scan start, no scan progress, no raw reads in this story — selecting a row captures selection state only; Story 1.4 wires the actual scan.
- No volume-level sub-targeting (per Architecture's Resolved scope) — one row per whole disk, not per partition/volume.
- No FileVault-lock UI yet (`DESIGN.md`'s "locked device" treatment) — that's Epic 2 Story 2.4, once FileVault detection exists.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| No devices beyond boot volume | Fresh app launch, nothing external attached | List shows only the boot volume, grayed, with its reason | N/A |
| External device attached while app is running | User plugs in a USB drive | Row appears in the list within a short, bounded time — no restart needed | N/A |
| External device removed while app is running | User unplugs a drive | Its row disappears from the list promptly | N/A |
| Boot volume present | Always true on a running Mac | Shown, grayed, with a stated reason; not selectable/clickable as a scan target | Attempting to select it is a no-op, not a crash |
| Internal + external devices both present | Normal multi-device state | All appear together in one list, no separate sections | N/A |
| DiskArbitration session fails to register | Rare system-level failure | List shows a clear error state, not a silently empty/frozen list | N/A |

</frozen-after-approval>

## Code Map

- `SalvageCore/Sources/SalvageCore/SalvageCore.swift` — placeholder; `Entities/` subdirectory already exists (empty, `.gitkeep`) per Story 1.1's scaffold, ready for `BlockDevice.swift`.
- `SalvageDiskIO/Sources/SalvageDiskIO/SalvageDiskIO.swift` — placeholder; this story adds its first real adapter code.
- `scripts/spike-raw-device-access/Sources/spike-raw-device-access/BSDDeviceNames.swift` — `wholeDiskBSDName(fromDevicePath:)`, tested, parses raw/buffered device paths to a whole-disk BSD name. Port the logic (not the CLI-specific wrapper) into `SalvageDiskIO`.
- `scripts/spike-raw-device-access/Sources/spike-raw-device-access/BootDiskSafety.swift` — `resolveBootDisks()` (fail-closed, real physical-store resolution via `diskutil info -plist`) and `isWithinBootDiskSet`. Port this logic too — it's exactly what "mark the boot volume, don't omit it" needs.
- `scripts/spike-raw-device-access/Sources/spike-raw-device-access/DeviceEnumeration.swift` — one-shot `DADiskCreateFromBSDName`/`DACopyDiskDescription`-based enumeration; this story's watcher needs the *continuous* (callback-based) equivalent, which doesn't exist yet anywhere in the repo.
- `_bmad-output/planning-artifacts/ux-designs/ux-DataRecoveryTool-2026-10-31/DESIGN.md` — `components.device-row` (frontmatter + Components section) for the exact visual spec.
- `_bmad-output/planning-artifacts/ux-designs/ux-DataRecoveryTool-2026-10-31/EXPERIENCE.md` — Component Patterns → Device row; State Patterns → "Boot volume present", "No devices attached".
- `_bmad-output/planning-artifacts/architecture/architecture-DataRecoveryTool-2026-10-30/ARCHITECTURE-SPINE.md` — AD-1 (module boundary), AD-5/AD-11 (structured concurrency, `AsyncStream` convention), ERD (`BlockDevice` relationships).

## Tasks & Acceptance

**Execution:**
- [x] `SalvageCore/Sources/SalvageCore/Entities/BlockDevice.swift` -- `struct BlockDevice: Identifiable, Equatable, Sendable` with `bsdName`, `displayName`, `sizeBytes`, `isInternal`, `isBootVolume` -- the pure data model, per AD-1 (no DiskArbitration import)
- [x] `SalvageDiskIO/Sources/SalvageDiskIO/BSDDeviceNames.swift` + `BootDiskSafety.swift` -- port the tested parsing/boot-resolution logic from `scripts/spike-raw-device-access`, adapted to produce `BlockDevice` values instead of printing to stdout
- [x] `SalvageDiskIO/Sources/SalvageDiskIO/DeviceWatcher.swift` -- new: registers `DARegisterDiskAppearedCallback`/`DARegisterDiskDisappearedCallback` on a `DASession` scheduled on the main run loop; exposes `func watch() throws -> AsyncStream<[BlockDevice]>` (throws to signal DiskArbitration session registration failure distinctly from an empty device set) emitting the full current device set on every change
- [x] `Salvage/ViewModels/DeviceListViewModel.swift` -- `@Observable` (or `ObservableObject`) consuming `DeviceWatcher.watch()`, publishing the current `[BlockDevice]` and the selected device, if any
- [x] `Salvage/Views/DeviceListView.swift` -- SwiftUI list per `DESIGN.md`'s device-row spec: one row per device, boot volume grayed with its reason, click selects (captures selection, does not start a scan)
- [x] `Salvage/Views/ContentView.swift` -- replace the placeholder blank-shell body with `DeviceListView`
- [x] `SalvageCore/Tests/SalvageCoreTests/BlockDeviceTests.swift` -- basic `Equatable`/`Identifiable` sanity tests
- [x] `SalvageDiskIO/Tests/SalvageDiskIOTests/` -- port the 11 BSD-name/boot-disk assertions from the spike's 21-test target (the other 10 are CLI-argument-parsing tests, not ported here), adapted to the production code's shape

**Acceptance Criteria:**
- Given one or more non-boot block devices attached, when the device list view appears, then all are listed without an app restart.
- Given the live boot volume, when the list renders, then it appears grayed with a one-line reason, never omitted, and is not selectable as a scan target.
- Given internal and external devices both present, when the list renders, then they appear together in one list.
- Given a device is attached or removed while the app is running, when that happens, then the list updates without a restart.
- Given the boot-disk-resolution logic from Story 1.2, when reused here, then it is the ported/adapted version (not re-derived), confirmed by the carried-forward test assertions passing unchanged in meaning.

## Implementation Notes

**Entity and ported logic:**

- `BlockDevice` (`SalvageCore/Sources/SalvageCore/Entities/BlockDevice.swift`) is a plain
  `Identifiable`/`Equatable`/`Sendable` struct, `id` mirrors `bsdName`. No DiskArbitration or
  platform import -- confirmed by `scripts/check-core-boundary.sh`, which still passes.
- `BSDDeviceNames.swift` and `BootDiskSafety.swift` are ported into `SalvageDiskIO` effectively
  verbatim from the spike (`scripts/spike-raw-device-access`), only dropping the CLI-specific
  wrapper -- `wholeDiskBSDName`, `resolveBootDisks`, `isWithinBootDiskSet`,
  `physicalWholeDisks(fromDiskUtilInfoPlist:)`, etc. are byte-for-byte the same logic. Manually
  re-verified against this machine's real disk layout (not just unit tests): `resolveBootDisks()`
  correctly returns `{disk0, disk3}` (the physical SSD + its synthesized APFS container), matching
  `diskutil`'s real output on this host.

**`DeviceWatcher` (new):**

- Registers `DARegisterDiskAppearedCallback`/`DARegisterDiskDisappearedCallback` on a `DASession`
  scheduled on `CFRunLoopGetMain()`, and emits the entire current device set (not a diff) on
  every appear/disappear event, per this story's Design Notes. Enumeration logic (the `0...63`
  `DADiskCreateFromBSDName`/`DACopyDiskDescription` loop) is adapted from the spike's one-shot
  `listDevices()`, with one deliberate addition: it filters to `kDADiskDescriptionMediaWholeKey
  == true` so only whole disks become `BlockDevice` values, matching this story's "whole disks
  only, never a partition/volume" boundary (the spike's CLI listing printed partitions too, just
  tagged differently).
- `watch() throws -> AsyncStream<[BlockDevice]>`: kept the exact `AsyncStream<[BlockDevice]>`
  element type the spec's task line specifies (so the stream's contract stays "full current set,
  every time," per Design Notes), but made `watch()` itself `throws`, surfacing
  `DeviceWatcherError.sessionRegistrationFailed` synchronously if `DASessionCreate` returns `nil`.
  That is the I/O matrix's "DiskArbitration session fails to register" row -- it needs a signal
  distinct from "zero devices currently attached," and folding an error case into the stream's
  element type would have broken the "always the full device set" contract. `DeviceListViewModel`
  catches this and renders a distinct error state rather than an empty list.
- A boot-disk-*resolution* failure (`resolveBootDisks()` returning `.failure`, e.g. `diskutil`
  itself fails) is handled differently from a DASession registration failure: watching still
  starts, with an empty boot-disk set, rather than refusing outright. This mirrors the spike's own
  stated rationale for its (CLI, stderr-warning-based) `--list` path: listing is read-only/
  informational, unlike a raw read, so a resolution failure there doesn't need AD-4's full
  fail-closed treatment. **Flagging as a known residual risk** (see end of this section) since
  there is no UI-visible warning equivalent to the spike's stderr line if this ever happens.
- Verified the underlying enumeration keys/behavior against this machine's real, attached disks
  (a small standalone harness, not committed) before wiring them into `DeviceWatcher` -- internal
  SSD/APFS containers, the internal SD reader, and several external disk images all enumerated
  with correct `isInternal`/`sizeBytes`/model values.

**View layer:**

- `DeviceListViewModel` (`@MainActor @Observable`) wraps `DeviceWatcher.watch()` in a `Task`,
  republishing `devices`/`watchError`, and owns `selectDevice(_:)`, which no-ops (never a crash)
  for the boot volume or for a device no longer in the current set.
- `DeviceListView` renders one unified `List` (no internal/external sections), routes macOS's
  native list `selection:` binding through `selectDevice(_:)` so the boot-volume no-op guard
  applies there too, and additionally marks the boot volume's row `.disabled(...)` as
  view-layer defense in depth. Three states: the list itself, the "No storage devices found."
  empty state, and the DiskArbitration-registration-failure error state -- copy for the former
  matches EXPERIENCE.md's State Patterns table verbatim; the boot-volume row's reason text
  matches its Voice and Tone table verbatim ("Your boot drive can't be scanned while macOS is
  running from it."). `ContentView` now renders `DeviceListView` directly, replacing Story 1.1's
  placeholder body.
- Registered the two new files (`DeviceListView.swift`, `DeviceListViewModel.swift`) in
  `Salvage.xcodeproj/project.pbxproj` by hand (this project uses explicit `PBXFileReference`/
  `PBXBuildFile` entries, not a filesystem-synchronized group) and removed the now-stale
  `Salvage/ViewModels/.gitkeep` file and its project reference.

**Verification performed:**

- `swift test --package-path SalvageCore` -- 9 tests pass (1 scaffold + 8 new `BlockDevice`
  tests).
- `swift test --package-path SalvageDiskIO` -- 12 tests pass (1 scaffold + 11 ported
  BSD-name/boot-disk tests). Note on the spec's "21 existing...assertions": the spike's test
  target has 21 `@Test` functions total, but 10 of those are `ArgumentParsing`/CLI-specific
  (`parseArguments` usage-error cases) with no production-code equivalent and correctly excluded
  from this port; the 11 that are actually about BSD-name parsing and boot-disk resolution
  (`wholeDiskBSDName`: 2, `isWithinBootDiskSet`: 3, `physicalWholeDisks(fromDiskUtilInfoPlist:)`:
  6) are all ported with the same assertions, unchanged in meaning.
- `swift test --package-path scripts/spike-raw-device-access` -- unaffected, still 21/21 passing
  (regression check; the spike itself wasn't touched).
- `./scripts/check-core-boundary.sh` -- passes (AD-9): `DiskArbitration` only appears under
  `SalvageDiskIO/` (plus the pre-existing spike exclusion); `SalvageCore` has no forbidden
  imports.
- `xcodebuild -project Salvage.xcodeproj -scheme Salvage -configuration Debug build` (unsigned,
  matching `ci.yml`'s invocation) -- **BUILD SUCCEEDED**, no warnings.
- Manually re-ran the live DiskArbitration enumeration this story's `DeviceWatcher` is built on
  against this machine's real attached disks (internal SSD + APFS container, internal SD-card
  reader, several external disk images) and confirmed `resolveBootDisks()` correctly identifies
  the real boot-disk set -- see Implementation Notes above.

**Known residual risks / left incomplete:**

- **Not manually verified end-to-end on a running app with a physical device plug/unplug**
  (this story's own "Manual checks (if no CLI)" item) -- no spare USB/SD device was inserted or
  removed against a running build of `Salvage.app` during this session. The appear/disappear
  callback wiring was verified correct by API/contract (DiskArbitration requires exactly this
  registration shape to fire at all) and the one-shot enumeration it reuses was verified against
  real hardware, but the live-update path itself (attach while running → row appears; detach →
  row disappears) has not been observed first-hand. Recommend a human runs the app, plugs in and
  then removes a real external drive, and confirms both directions before this story is
  considered fully closed.
- **Boot-disk-resolution failure during watching has no user-visible signal** (see Implementation
  Notes above) -- if `diskutil`/`statfs` fail at the moment `DeviceWatcher` starts, the boot
  volume would render as an ordinary, selectable device rather than grayed, with nothing in the
  UI indicating why. The I/O matrix doesn't have an explicit row for this sub-case (only for
  DASession registration itself failing, which *is* handled), so this wasn't treated as a blocking
  gap, but it's a real edge case worth a human second look -- especially since `selectDevice`'s
  only defense against ever reading the live boot volume is "don't select it in this picker,"
  not a lower-level refusal (that lower-level refusal is AD-4's raw-read-path responsibility in
  Story 1.4+, not this story's).
- No automated test exercises `DeviceWatcher`/`DiskWatchRegistration` directly (live
  DiskArbitration callback wiring, `DeviceWatcherError.sessionRegistrationFailed`, or
  `DeviceListViewModel`'s stream-consumption/no-op-selection logic) -- Architecture's Deferred
  section leaves the overall testing strategy open, and nothing here is file-backed/mockable the
  way `SalvageCore`'s ports are designed to be (Architecture AD-1/AD-8's rationale for
  `BlockReader`-style injectable ports). `BlockDeviceTests` and the ported BSD-name/boot-disk
  tests are the two targets this story explicitly asked for; the live-callback plumbing itself
  relies on the manual hardware verification above plus the Xcode build succeeding, not a unit
  test.

## Spec Change Log

## Review Triage Log

Review pass 1 — 3 layers (blind-hunter, edge-case-hunter, verification-gap), 23 raw findings grouped into 14 entries.

| # | Verdict | Route | Finding | Evidence |
|---|---|---|---|---|
| 1 | high | patch | Boot-volume-selection safety is weakly protected and almost entirely untested (verification-gap A+D + blind-hunter #2/#12 + edge-case #4, merged) | Confirmed: `selectDevice` trusts the caller-supplied `device.isBootVolume` instead of re-deriving it from the canonical `devices` array by id; `physicalWholeDisks`/`resolveBootDisks` accept `ParentWholeDisk` from `diskutil`'s plist without validating it through `wholeDiskBSDName()` first, undermining the documented fail-closed guarantee; no protocol/seam exists to inject a fake `DeviceWatcher`, so none of this is testable, and no test target even exists for the `Salvage` app module. **Overriding verification-gap's filed `defer` on its 4th finding**: same pattern as Story 1.2 — three reviewers converged on the same safety-critical gap, and this is the one piece of code standing between the app and letting a user select the live boot volume as a scan target. *Fix:* re-derive `isBootVolume` from the canonical device list in `selectDevice`; validate `ParentWholeDisk` through `wholeDiskBSDName()` before accepting it; add a `DeviceWatching` protocol seam and a `SalvageTests` target with tests for the boot-volume-rejection guard, stale-selection clearing, and the error-mapping path. |
| 2 | high | patch | `DAUnregisterCallback` is called with `context: nil` but registration used `Unmanaged.passUnretained(self).toOpaque()` — DiskArbitration matches by callback *and* context, so unregistration likely silently fails | Confirmed by reading `DeviceWatcher.swift`. Real risk: callbacks could keep firing after `stop()`, dereferencing a stale unretained pointer to a deallocated `self`. |
| 3 | medium | patch | `resolveBootDisks()`'s `diskutil info -plist` subprocess call runs synchronously on `@MainActor` from `startWatching()` | Confirmed: a slow/hung subprocess blocks the UI thread at every watch start. Dispatch off the main actor or add a timeout. |
| 4 | medium | patch | Device deselection doesn't work — the `List` selection binding's setter has no path for `newID == nil` | Confirmed by reading `DeviceListView`'s binding. Real UX bug: clicking empty space / pressing Escape can't clear a selection. |
| 5 | low-medium | patch | `stat.f_mntfromname` decoded via `String(cString:)` with no bound on the fixed-size buffer | Confirmed pattern (classic C-buffer risk); low probability in practice but a genuine defensive-coding gap in safety-relevant boot-detection code. Bound the decode. |
| 6 | low | patch | `@unchecked Sendable` on `DiskWatchRegistration` has no comment explaining the "everything runs on the main run loop" safety invariant at the declaration itself | Confirmed. Direct, trivial fix — add the comment where the unchecked conformance is, not only elsewhere. |
| 7 | low-medium | patch | Empty-device-list state and enumeration-failure state show the same reassuring copy, but an empty list is actually anomalous (the boot volume should always be enumerated) | Confirmed against the spec's own I/O matrix. Distinguish the two states instead of conflating them. |
| 8 | low | patch | Transient flash of the empty-state view before the first (already-buffered) stream element is consumed, since `startWatching()` runs from an async `.task` | Confirmed: a normal launch can briefly show "No storage devices found" before real data arrives. Show a neutral loading state instead of the empty-state copy during that window. |
| 9 | low | patch | DiskArbitration-session-failure error copy leaks the internal term "DiskArbitration" into user-facing text, and wasn't cross-checked against `EXPERIENCE.md`'s Voice and Tone table the way the other copy was | Confirmed by reading the string. Direct text fix, matching the plain-language bar the rest of this story's copy already meets. |
| 10 | low | patch | `.disabled(device.isBootVolume)` on the boot-volume row may affect whether VoiceOver can focus/announce its stated reason — not confirmed either way | Plausible, not verified (no VoiceOver testing performed). *Fix:* add an explicit `.accessibilityLabel`/`.accessibilityValue` carrying the boot-volume reason regardless of disabled state, so the information reaches VoiceOver users even if `.disabled()` affects focus — belt-and-suspenders rather than relying on disabled-row announcement behavior. |
| 11 | low | reject | Hardcoded `0...63` disk-slot enumeration range would miss `disk64`+ (blind-hunter #11 + edge-case #2, duplicate; also carried forward from Story 1.2) | Already triaged and accepted as low-priority once in Story 1.2's review (unrealistic in practice, fix is more than a direct correction) — same judgment stands, not re-opening it. |
| 12 | low | patch (self) | Spec's Tasks & Acceptance says "port the 21 existing BSD-name/boot-disk assertions," but only 11 of the spike's 21 tests were actually BSD-name/boot-disk tests (the other 10 were CLI-argument-parsing-only) — confirmed independently by both blind-hunter and edge-case-hunter (high confidence) | Documentation accuracy, not a code change — corrected directly in this spec rather than dispatched. |
| 13 | false | — | Implementation Notes' "12 tests pass" allegedly undercounts actual executed test cases | Refuted on my own independent verification: `swift test --package-path SalvageDiskIO` genuinely prints "Test run with 12 tests in 4 suites passed" — that's Swift Testing's own reported summary line, not a miscount introduced by this spec. The spec faithfully reports the tool's own output. |
| 14 | low | patch (self) | `DeviceWatcher.watch()` is `throws`, but the spec's own Tasks line states the signature without `throws` (low-confidence claim finding) | Minor documentation drift — corrected directly in this spec's task line while fixing #12/#13. |

## Design Notes

`DeviceWatcher`'s `AsyncStream` should emit the *entire current device set* on every appear/disappear event (not an incremental diff) — simplest consumer contract for the view model (`devices = newSet`), and the full-rescan cost is low (device counts are small, enumeration is already fast per Story 1.2's measurements). A finer-grained add/remove event stream can be a later refinement if it's ever needed; nothing in FR-1 requires it.

## Verification

**Commands:**
- `swift test --package-path SalvageCore` -- expected: `BlockDevice` tests pass
- `swift test --package-path SalvageDiskIO` -- expected: ported BSD-name/boot-disk tests pass with the same assertions as the spike's 21
- `xcodebuild -project Salvage.xcodeproj -scheme Salvage build` -- expected: success

**Manual checks (if no CLI):**
- Launch the app; confirm the boot volume appears grayed with a reason. Attach and then remove a real external device (USB/SD) while the app is running; confirm the list updates both ways without a restart.

## Codex continuation — 2026-10-31

The continuation supersedes the earlier residual-risk notes about boot resolution and missing
view-model coverage. `DeviceWatching.watch()` is now `@MainActor async throws`: boot-disk
resolution runs off the main actor before any device snapshot is published. Failure or an empty
protected set produces a plain-language error and no selectable devices. Cancellation is checked
before registering callbacks. Full snapshots use a newest-one buffer.

Callback teardown retains the registration until main-run-loop unregistration finishes, using
matching callback/context pairs. View-model tasks hold the model weakly, discard cancelled
updates, clear stale data on restart, and invalidate selection when its device becomes protected.
`project.yml` now defines the app test target so project regeneration preserves it.

Regression coverage includes startup resolution failure, an empty boot set, canonical boot
selection rejection, removal, changed protection status, restart clearing, and error presentation.
Physical USB/SD attach/remove and VoiceOver checks still require manual verification.

Continuation validation: Xcode build and all 29 tests passed (6 app, 9 Core, 14 DiskIO).
The module-boundary checker and `git diff --check` passed. CI now runs the app tests as well
as package tests. Swift 6.0 compatibility is preserved with a compiler-conditional `@concurrent`
annotation; older toolchains use the nonisolated async executor behavior.
