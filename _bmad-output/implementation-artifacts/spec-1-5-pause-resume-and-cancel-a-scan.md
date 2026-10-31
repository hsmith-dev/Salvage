---
title: 'Pause, Resume, and Cancel a Scan'
type: 'feature'
created: '2026-10-31'
status: 'in-review'
baseline_commit: 'c1b21a3'
route: 'dispatch'
review_loop_iteration: 0
context:
  - '{project-root}/_bmad-output/implementation-artifacts/epic-1-context.md'
  - '{project-root}/_bmad-output/planning-artifacts/architecture/architecture-DataRecoveryTool-2026-10-30/ARCHITECTURE-SPINE.md'
  - '{project-root}/_bmad-output/planning-artifacts/ux-designs/ux-DataRecoveryTool-2026-10-31/EXPERIENCE.md'
  - '{project-root}/_bmad-output/implementation-artifacts/spec-1-4-scan-a-fat32-exfat-device-with-live-progress.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Story 1.4 scans can only be cancelled. Users need to pause a long scan and resume it in the same run, and to resume after relaunching the app instead of restarting from zero (FR-3, AD-11).

**Approach:**
- **In-process pause** follows AD-11. `ScanSession` awaits an actor-held resumable gate between units of work, with no Task cancellation, so the same Task continues on resume.
- **Cold-start resume:**
  - `ScanSession` publishes a `ScanCheckpoint` after each unit of work, through an optional `AsyncStream<ScanCheckpoint>.Continuation` passed to `run`. `ScanEvent` stays closed; no new case is added.
  - The app persists the latest checkpoint per device identity and offers resume on relaunch.
  - Resume re-runs metadata traversal, which is cheap and bounded, so discoveries are rebuilt. It skips sweep bytes the checkpoint already covered, counting them as already scanned.

## Boundaries & Constraints

**Always:**
- Keep the AD-11 `ScanEvent` cases exactly as they are.
- Pause must never cancel the Task, close the descriptor or release the device reservation.
- Cancel stays terminal Task cancellation. It also cancels a paused scan: a gated wait must respond to cancellation immediately. Results found so far stay visible.
- The pause gate sits in `MeasuredReader.read` and the sweep loop. Parsers stay unchanged, and no read is issued while paused.
- Paused time is excluded from the elapsed time used for ETA. The UI shows a distinct Paused state with Resume and Cancel.
- A checkpoint is bound to the device's `mediaIdentity` and size, plus a format version. On mismatch, or if the checkpoint is corrupt or unreadable, discard it and scan from zero; never apply a checkpoint to a different device.
- Checkpoints live in the app's Application Support directory. They contain only offsets and identifiers, never file names, paths or file contents.
- A completed or cancelled scan deletes its checkpoint. Only an interrupted run (app quit or crash mid-scan) leaves one.
- When resuming, a file is never shown twice: de-duplicate by `(volumeOffset, recordOffset)`.
- No network, no source writes, structured concurrency only (AD-5).

**Never:** No new `ScanEvent` case. No edits to `FATVolume.swift`, `VolumeDiscovery.swift`, `VolumeScanners.swift`, `NTFSVolume.swift` or `EXTVolume.swift`. Other stories own those files and are running in parallel. In `ContentView.swift`, edit only `runScan` and the `ScanViewModel` construction; the trust sheet and toolbar belong to Story 1.11. Don't edit `.github/workflows/ci.yml`.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected | Error handling |
|---|---|---|---|
| Pause | Running scan | No further reads; state Paused; progress frozen | — |
| Resume | Paused | Same Task continues from the same point | — |
| Cancel while paused | Paused | Terminates promptly, keeps discoveries, removes checkpoint | Reservation released |
| Relaunch mid-scan | Checkpoint for an attached device with the same identity | Offer Resume; progress starts at the checkpoint offset; no duplicate files | — |
| Stale checkpoint | Identity or size mismatch, corrupt JSON, unknown version | Ignore and delete; full scan | No crash |
| Device removed while paused | Paused, then the device disappears | On resume the read fails with `deviceChanged`, shown as an error | Discoveries kept |
| Pause before running | Preparing state | Pause disabled until running | — |

</frozen-after-approval>

## Code Map

- `SalvageCore/Sources/SalvageCore/ScanSession.swift`: add the pause gate (an actor), checkpoint emission, a `resume(from:)` start point, and the gate in `MeasuredReader.read` and the sweep loop.
- New `SalvageCore/Sources/SalvageCore/Entities/ScanCheckpoint.swift`: a public `Codable`/`Sendable` value with fields such as `version`, `sweepVolumeIndex`, `sweepOffset`, `bytesScanned` and `totalBytes`.
- `Salvage/ViewModels/ScanViewModel.swift`: `pause()`, `resume()`, a `.paused` state, paused-time accounting and de-duplication.
- New `Salvage/ViewModels/ScanCheckpointStore.swift`: JSON persistence keyed by `mediaIdentity`, injectable for tests.
- `Salvage/Views/ScanProgressView.swift`: Pause, Resume and Cancel controls, and the paused copy.
- `Salvage/Views/ContentView.swift`, `runScan` only: thread the checkpoint stream and the resume point.
- Tests:
  - New file `SalvageCore/Tests/SalvageCoreTests/ScanPauseTests.swift`. Reuse `ImageReader`, `fatImage` and `exfatImage` from `ScanSessionTests.swift`.
  - `SalvageTests/ScanViewModelTests.swift`.

## Tasks & Acceptance

- [x] Core pause gate plus tests: no reads while paused (use a counting reader); resume continues; cancel while paused ends promptly without `.completed`.
- [x] Checkpoints plus tests: they advance monotonically; resuming from a mid-sweep checkpoint reaches `.completed` with correct totals and the same discoveries.
- [x] App state, persistence and UI plus tests: pause/resume states, ETA excludes paused time, stale checkpoints are discarded, de-duplication works, and the checkpoint is deleted on completion and on cancel.

**Acceptance criteria:**
- Given an active scan, when the user taps Pause, the scan suspends without cancelling and continues from the same point on Resume.
- Given an active scan, when the user taps Cancel, it terminates and the results found so far stay visible.
- Given a relaunch after the app closed mid-scan, when the user returns to that device, the scan can resume from the last checkpoint rather than from zero.

## Verification

- `swift test --package-path SalvageCore`
- `swift test --package-path SalvageDiskIO`
- `./scripts/check-core-boundary.sh`
- `xcodebuild -project Salvage.xcodeproj -scheme Salvage -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:SalvageTests test`
- `xcodebuild -project Salvage.xcodeproj -scheme Salvage -configuration Debug -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build`

## Implementation Notes

- **Gate is a lock-backed `Sendable` class, not a Swift `actor`.** `ScanPauseGate` (new file `SalvageCore/Sources/SalvageCore/ScanPauseGate.swift`, kept out of `ScanSession.swift` to keep that shared file's diff small) holds its state under an `NSLock`. That makes `pause()`/`resume()` synchronous from the main actor, so rapid Pause/Resume can't reorder across actor hops. It also lets the cancellation handler release a parked waiter without spawning an unstructured `Task` (AD-5). The behavior matches AD-11's "actor-held resumable gate": the same Task suspends and continues, and cancellation wakes a waiter immediately.
- **API shape.** `ScanSession.run(events:pauseGate:checkpoints:resumingFrom:)` takes all three new parameters as optional, so existing callers are unchanged. The core finishes the checkpoint continuation, and consumers should use `bufferingNewest(1)`. A checkpoint is emitted after every 1 MiB sweep chunk. Metadata traversal emits none, because it is always re-run on resume.
- **Core re-validates the checkpoint.** Even after the app's checks, `ScanSession` ignores a checkpoint (and scans from zero) unless its version, device size and total bytes match, the volume index exists, and the offset fits that volume.
- **Device binding.** `ScanCheckpoint` carries `version` and `deviceSizeBytes`. The app's JSON record wraps it with a `formatVersion` and the `mediaIdentity`. A checkpoint is discarded on any mismatch, decode failure or unknown version. Devices without a `mediaIdentity` are never checkpointed. `mediaIdentity` is the IORegistry entry ID, so a checkpoint survives an app relaunch while the device stays attached, but not a re-plug or reboot. That follows "an attached device with the same identity".
- **"Offer Resume" UX.** Choosing a device that has a valid checkpoint moves the model to a new `.resumable` state instead of starting. `ScanProgressView` then shows "Resume scan" (the default action) and "Start over". This needed no change to `DeviceListView` or to `ContentView`'s other code.
- **Write throttling.** Checkpoints are persisted at most once per second, plus immediately on Pause, to avoid a disk write per MiB. A crash can lose up to about 1 s of sweep progress.
- **Checkpoint deletion.** The checkpoint is deleted on every terminal outcome: completed, cancelled and failed. Only a quit or crash mid-scan leaves one behind. The existing `ContentView.onDisappear { scan.cancel() }` (which this story may not edit) means closing the window mid-scan counts as a cancel and discards the checkpoint. On Cmd-Q the process exits before that async cleanup runs, so the checkpoint survives.
- **Time accounting.** Paused time is excluded from both the displayed elapsed time and the ETA. A resumed scan measures its rate from bytes read since resuming, because the checkpoint's bytes count as scanned but took no time in this run. While paused, Remaining shows "Paused".
- **De-duplication key.** The key is `(volumeOffset, directoryEntryOffset)`, which is the current `SourceMetadata` record offset.
- **Project file.** `Salvage.xcodeproj` was regenerated with `xcodegen generate` so it picks up `ScanCheckpointStore.swift`. The project diff is 4 lines.
- **Not verified.** Real-device pause and resume is unverified, still pending Story 1.2's FDA-granted hardware check. All tests use synthetic images or injected runners.
