---
title: 'Full Disk Access / Raw Device Access Spike'
type: 'feature'
created: '2026-10-31'
status: 'done'
route: 'dispatch'
review_loop_iteration: 0
baseline_commit: '9d565d5c1a196cb41781a07740c47dd31eac307d'
context:
  - '{project-root}/_bmad-output/implementation-artifacts/epic-1-context.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Epic 1's raw-read path (Architecture AD-4) rests on an unverified assumption — Full Disk Access + Developer ID signing is sufficient for raw block-device reads — carried as PRD Open Question 4. Every later Epic 1 story depends on this being right.

**Approach:** Confirm or refute the assumption with real, hands-on evidence rather than more research. Split cleanly into what's verifiable from a terminal right now (no FDA granted, as a baseline) versus what requires granting Full Disk Access to a real process via System Settings — a GUI action only the human can perform.

**Already confirmed this session, empirically, against real local hardware (boot disk0, a non-boot built-in SD-reader disk6, both buffered `/dev/diskN` and raw `/dev/rdiskN` device nodes):**
- Without Full Disk Access: `open()`/`read()` on any raw device node fails ("Operation not permitted" / "Permission denied"), on both internal and external devices, both device-node variants.
- Device enumeration/metadata (the `diskutil info` equivalent — what `DiskArbitration`'s description-reading calls use) works fine without FDA. Only byte-level reads are gated.
- This confirms the *shape* of the existing assumption (raw reads need something beyond default permissions) but not the specific remedy (does granting FDA actually unblock it) — that needs a real, human-granted FDA test.

**Resolved decision:** build a standalone SwiftPM CLI harness (outside `Salvage.app` — a full signed app isn't required to test raw device access, only FDA matters). The human runs it from Terminal, grants it Full Disk Access via System Settings when it first fails, re-runs, and reports the result.

## Boundaries & Constraints

**Always:**
- Keep the harness as a small, disposable command-line tool (not wired into the shipping app) — this story's output is a verified answer plus updated documentation, not production code.
- Test against a real non-boot device (internal or external — what matters is "not the boot volume," not the device's internal/external classification) — never attempt a raw read against the live internal boot volume, consistent with AD-4's boot-volume exception.
- Document findings directly in `ARCHITECTURE-SPINE.md` (Open Question 4 / AD-4's Deferred note) and `prd.md` (Open Question 4) once confirmed — this story's whole point is closing those out with real evidence, not leaving them open.

**Never:**
- Do not weaken or bypass AD-4's unmount-before-read sequence to make the test "pass" — if raw access still fails even after FDA + unmount, that is the real answer and gets reported as such.
- Do not grant Full Disk Access via any automated/scripted mechanism — this is a deliberate macOS security gate; it requires the human's own System Settings action, every time, for every app. No workaround is legitimate or possible.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| No FDA granted, raw read attempted | Harness run without FDA | `open()`/`read()` fails with a permission error | Harness reports the exact errno/message, does not crash |
| FDA granted to the harness's host app, raw read attempted | Harness run after human grants FDA via System Settings | Read succeeds and returns real bytes from the device | N/A |
| FDA granted, but device still mounted (not unmounted first) | Harness skips the `DADiskUnmount` step | Document actual observed behavior — succeeds, fails, or returns stale data | Harness reports what actually happened, not an assumption |
| Device unmounted via `DADiskUnmount`, then raw read | Harness follows the full AD-4 sequence | Read succeeds (if FDA granted) | N/A |

</frozen-after-approval>

## Code Map

- `SalvageDiskIO/Sources/SalvageDiskIO/SalvageDiskIO.swift` — current placeholder; this is where the real `RawBlockReader` (AD-4) eventually lives, but this story's harness stays separate/disposable per Boundaries.
- `_bmad-output/planning-artifacts/architecture/architecture-DataRecoveryTool-2026-10-30/ARCHITECTURE-SPINE.md` — AD-4 (the exact Rule this spike verifies), Deferred section (where the FDA/TCC open item is currently recorded).
- `_bmad-output/planning-artifacts/prds/prd-DataRecoveryTool-2026-10-30/prd.md` — Open Question 4, the PRD-level record of this same unresolved assumption.
- Confirmed this session (not yet in Code Map form, now recorded here): `diskutil list` shows a real non-boot device at `/dev/disk6` (`Built In SDXC Reader` — internal per DiskArbitration, but not the boot disk) usable as the test target; `ps` confirms the current shell's parent process is the `claude` binary, not a traditional Terminal.app — whichever app ends up hosting the harness binary is the one that needs FDA granted to it specifically.

## Tasks & Acceptance

**Execution:**
- [x] `scripts/spike-raw-device-access/main.swift` (or a small SwiftPM executable target) -- standalone CLI harness: enumerate devices via DiskArbitration, unmount the chosen target via `DADiskUnmount`, attempt raw `open()`/`read()` on `/dev/rdiskN`, print exact success/failure and errno -- the actual test instrument
- [x] Run the harness without FDA granted -- confirm it fails the same way the `dd` baseline already did -- sanity-checks the harness itself before the real test matters
- [ ] **Human action required:** grant Full Disk Access to the harness's host app via System Settings → Privacy & Security → Full Disk Access, then re-run and report the result
- [ ] `ARCHITECTURE-SPINE.md` -- update AD-4's Deferred/open-item note (and the FDA/FSKit spike note) with the confirmed result -- closes the loop Architecture left open
- [ ] `prd.md` -- resolve Open Question 4 with the confirmed result, matching how Open Questions 9/10 were resolved after Architecture -- keeps PRD and Architecture in sync

**Acceptance Criteria:**
- Given the harness run without FDA, when it attempts a raw read, then it fails with a permission error it can name (not a crash).
- Given the harness run with FDA granted to its host app, when it attempts a raw read following AD-4's unmount-first sequence, then it either succeeds (confirming the assumption) or fails with a specific, reported reason (refuting it) — either outcome is an acceptable, real answer.
- Given a confirmed result, when `ARCHITECTURE-SPINE.md` and `prd.md` are checked, then both reflect the same confirmed (not assumed) access model, with Open Question 4 closed in both.

## Implementation Notes

**Harness built and sanity-checked (no FDA granted):**

- Standalone SwiftPM executable at `scripts/spike-raw-device-access/` (`Package.swift` +
  `Sources/spike-raw-device-access/main.swift`), run via `swift run spike-raw-device-access
  <args>` from that directory. Not wired into `Salvage.app`, `SalvageCore`, or `SalvageDiskIO`
  (its `import DiskArbitration` is explicitly excluded from `scripts/check-core-boundary.sh`'s
  repo-wide grep, with a comment explaining why — see that script's updated header and step
  [2/3]; `scripts/test-check-core-boundary.sh` still passes unmodified).
- `swift run spike-raw-device-access --list` enumerates whole disks via DiskArbitration with no
  FDA required, and correctly tags the live boot disks (`disk0`, physical; `disk3`, the
  synthesized APFS container backing the running boot volume) as `BOOT -- this harness refuses
  --read against this disk`. It also correctly identified the session's non-boot test target,
  `/dev/disk6` ("Built In SDXC Reader", 1 TB, currently holding an NTFS volume) as a safe,
  non-boot target.
- `swift run spike-raw-device-access --read /dev/rdisk6` (no FDA granted): `DADiskUnmount`
  **succeeded** (unmounting does not require FDA), then `open("/dev/rdisk6", O_RDONLY)` **failed
  with errno 13 (`Permission denied`)**. This matches the `dd`-based baseline already recorded
  in this spec's frozen Intent section exactly — the harness itself is confirmed working and
  reports a real, non-generic errno rather than crashing or guessing.
- The boot-volume safety refusal was independently verified: `--read /dev/rdisk0` and `--read
  /dev/rdisk3s1` both refuse outright with `REFUSED: ... hosts the live, running boot volume`,
  before any unmount or open attempt — confirmed never bypassable via `--no-unmount` or any
  other flag (no override exists in the code).
- `--no-unmount` (I/O matrix row 3, device still mounted) exists in the harness but has not yet
  been exercised against a real, still-mounted FDA-granted run — that's part of the still-open
  human step below.

Review pass 1 found a real safety gap in the boot-disk detection logic (see Review Triage Log)
and 8 hygiene/robustness issues. All 9 fixed and independently re-verified: boot-disk resolution
is now fail-closed with real physical-parent-disk resolution (confirmed live: refusing `/dev/rdisk0`
now correctly names the resolved set `(disk0, disk3)`, not a hardcoded guess), re-validated
immediately before `open()`, the unmount callback's lifetime is fixed, path parsing is guarded,
a 21-assertion test target now exists and passes, CI builds+tests the package, the boundary-check
exclusion itself is now covered by `test-check-core-boundary.sh`, and `README.md` documents the
harness's existence.

**Still blocked on human action (per this spec's Boundaries & Constraints -- "Never grant FDA
via any automated/scripted mechanism"):**

1. Run `swift run spike-raw-device-access --list` once to confirm the current non-boot external
   device name (it may differ from `/dev/disk6` by the time this runs).
2. Grant Full Disk Access via System Settings → Privacy & Security → Full Disk Access to
   whichever process actually calls `open()` — i.e. the terminal/shell/IDE that runs `swift run`
   directly (not a wrapper), since that is the process macOS attributes the raw `open()` call to.
3. Re-run `swift run spike-raw-device-access --read /dev/rdiskN` (substituting the real device)
   from inside that now-FDA-granted process.
4. Optionally also run with `--no-unmount` once, to produce a real answer for I/O matrix row 3
   (today it's undocumented).
5. Report the exact output (success + hex dump, or failure + errno) back so `ARCHITECTURE-SPINE.md`
   and `prd.md` can be updated with the confirmed (not assumed) result, closing PRD Open Question
   4 and Architecture's Deferred FDA/FSKit item for real. Until that human-granted run happens,
   those two docs have deliberately **not** been touched — the Boundaries & Constraints and
   Acceptance Criteria both require a *confirmed* result before closing the loop, and no FDA-on
   branch of the I/O matrix has been observed yet.

## Spec Change Log

## Review Triage Log

Review pass 1 — 3 layers (blind-hunter, edge-case-hunter, verification-gap), 16 raw findings grouped into 11 entries.

| # | Verdict | Route | Finding | Evidence |
|---|---|---|---|---|
| 1 | high | patch | Boot-disk safety logic is incomplete and fails open, not closed (verification-gap main finding + blind-hunter #8 + edge-case #1/#2, same root cause, merged) | Confirmed by reading the code: `physicalBootWholeDiskBSDNames` hardcodes a `disk0` fallback with no real DiskArbitration-based resolution of the physical parent disk; `bootWholeDiskBSDName()` returning `nil` on a `statfs`/parse failure is never checked by the caller, so a failure to determine the boot disk silently proceeds as if nothing is boot-protected; `wholeDiskBSDName(fromDevicePath:)` doesn't guard against a malformed path. **Overriding verification-gap's filed `defer` disposition**: three independent reviewers converged on the same safety-critical gap from different angles, and this is literally the one piece of code standing between the harness and a raw read against the live, running boot volume — exactly the hazard AD-4's boot-volume exception and PRD SM-4 ("zero confirmed reports of writing to or corrupting a source disk") exist to prevent. "Disposable spike tooling" doesn't lower the bar for a safety gate whose failure mode is real disk corruption. *Fix:* fail closed (refuse and exit non-zero) if the boot disk can't be positively determined; resolve the physical parent disk for real rather than guessing `disk0`; guard the path parser; add a real test target asserting the parsing/detection functions. |
| 2 | medium | patch | TOCTOU: the target device isn't re-validated as non-boot immediately before `open()`, after the up-to-20s unmount wait (edge-case #4) | Confirmed: a device swap during the wait (same BSD name reused) would mean `open()` runs against an unchecked device. Low likelihood but direct to fix now that the boot-check logic is already being hardened for #1. |
| 3 | medium | patch | `DADiskUnmount` callback/`UnmountContext` lifetime risk if the callback fires after a ~20s polling deadline (edge-case #3) | Confirmed by reading the unmount wait logic. Real crash/UB risk, not just a style nit. |
| 4 | low | patch | Dead, empty code branch in `physicalBootWholeDiskBSDNames` (verification-gap other finding + blind-hunter #1, duplicate) | Confirmed: an `if let ... as? Bool, devName { }` block with an empty body — vestigial, confusing in safety-critical code. Removed as part of fixing #1 (the function is being rewritten anyway). |
| 5 | low-medium | patch | `scripts/spike-raw-device-access` is never built or tested by `ci.yml` (blind-hunter #2) | Confirmed: `ci.yml` has no step referencing this package at all. Add a build step (and a test step, once #1 adds a real test target). |
| 6 | low | patch | New package omits `swiftLanguageMode(.v6)`, inconsistent with `SalvageCore`/`SalvageDiskIO`'s explicit setting (blind-hunter #3) | Confirmed by reading `Package.swift`. Trivial, direct correction. |
| 7 | low-medium | patch | `test-check-core-boundary.sh` doesn't cover the new `spike-raw-device-access` exclusion carve-out in `check-core-boundary.sh` (blind-hunter #5) | Confirmed: the exclusion pattern itself is untested, so a future typo or over-broad pattern (one that also swallows a real leak in `SalvageCore`/`Salvage`) would go undetected. I manually spot-checked this during my own review (a `DiskArbitration` import in `Salvage/` is still caught) but that check isn't committed as a repeatable test. *Fix:* add that exact scenario to `test-check-core-boundary.sh`. |
| 8 | low | patch | `README.md` doesn't mention `scripts/spike-raw-device-access/` at all (blind-hunter #6) | Confirmed: the directory imports `DiskArbitration` and required a CI boundary-checker carve-out, but nothing tells a reader it exists or why. |
| 9 | low | patch | Spec's own Boundaries/Implementation Notes call `/dev/disk6` an "external" device, but the harness's own output reports it `[internal, whole-disk]` (built-in SD reader) (blind-hunter #7) | Confirmed by re-reading my own `--list` output from this session. The actual safety property that matters is "non-boot," not "external" — the spec's wording was imprecise, not the testing. *Fix (mine, not dispatched):* correct the spec's own Boundaries/Implementation Notes wording from "external" to "non-boot," since this is documentation accuracy, not a code or behavior change. |
| 10 | low | patch | `--read` followed only by `--no-unmount` (no real path) is misparsed as the device path, producing a confusing failure instead of a usage error (edge-case #5) | Confirmed by reading the argument-parsing logic. Trivial guard. |
| 11 | low | reject | Hardcoded `0...63` disk-enumeration loop would miss `disk64`+ (edge-case #6) | Real but requires an unrealistic 64+ attached disks for this local, human-run spike tool; fix (switching enumeration strategy) is more than a direct correction — rejected per the low-finding rule. |

## Design Notes

The harness should be a plain `swift run` executable (SwiftPM `executableTarget`, not an Xcode app target) — a signed `.app` isn't required to test raw device access; only Full Disk Access matters, and that can be granted to whatever process actually calls `open()` on the device (commonly the terminal/IDE hosting the process, or the compiled binary itself if run directly). This keeps the test fast to iterate on without needing a full Xcode build/run/sign cycle for every attempt.

## Verification

**Commands:**
- `swift run spike-raw-device-access --list` -- expected: enumerates real attached devices without requiring FDA
- `swift run spike-raw-device-access --read /dev/rdisk6` (or whichever non-boot device is attached at test time), before FDA granted -- expected: fails, names the error
- Same command, after FDA granted to the host app -- expected: either succeeds (prints real bytes/hex dump) or fails with a specific, non-generic reason

**Manual checks (if no CLI):**
- Confirm via System Settings → Privacy & Security → Full Disk Access that the correct app/binary was actually granted access before concluding the "still fails" branch.
