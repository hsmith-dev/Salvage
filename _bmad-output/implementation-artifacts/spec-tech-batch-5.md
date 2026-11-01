---
title: 'Batch 5: JPEG reassembly, resume carving, UI tests, performance, user docs'
type: 'tech'
created: '2026-10-31'
status: 'ready-for-dev'
baseline_commit: '3fd01cb'
route: 'dispatch'
context:
  - '{project-root}/_bmad-output/planning-artifacts/architecture/architecture-DataRecoveryTool-2026-10-30/ARCHITECTURE-SPINE.md'
  - '{project-root}/_bmad-output/implementation-artifacts/deferred-work.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

Five independent work items, one agent each. Each section lists the files that agent owns. Touching another section's files causes merge conflicts.

## A. Bifragment JPEG reassembly (owns `SalvageCore/Sources/SalvageCore/Carving/**`, `CarvingTests.swift`)

**Problem.** `deferred-work.md`: split JPEGs stay partial/Low. Checking marker syntax alone accepts foreign bytes, so reassembly needs a real baseline decoder.

**Approach.**
1. Write a **baseline (SOF0/SOF1) Huffman entropy decoder**. It parses DQT/DHT/SOF/SOS/DRI, then decodes every MCU's DC/AC coefficients. Output is a decode result: `MCUs decoded`, `valid up to byte N`, and `RST sequence ok`. No pixel output. Progressive (SOF2) and arithmetic coding are out of scope.
2. When a JPEG carve ends inconsistent, or at the next header inside the entropy data:
   - Find the **last offset where decoding was still valid**. The break is at or before the cluster/sector boundary preceding that offset.
   - Search **later, unclaimed, sector-aligned positions** within a bounded window (default 16 MiB, at most 4096 candidate starts) for a resume point. Decoding must continue from the saved decoder state, at the break's bit position, and reach exactly the frame's total MCU count, ending at `FFD9`.
   - Resolve the 2-D search by trying break candidates at each cluster boundary between the last valid RST marker and the first invalid byte. Bound the total decode work per candidate JPEG, e.g. 64 MiB of entropy bytes.
3. Emit a reassembled file only if decoding validates the full MCU count and RST order across the join. It gets two `DataRun`s, `fragmentCount 2`, `overwriteConfidence 0.3` (AD-7 gives Low) and `isPartial: false`. Otherwise keep today's partial carve.
4. **Tests:**
   - Synthetic baseline JPEGs encoded in-test, or real ones from `sips -s format jpeg`, with and without restart markers.
   - A two-fragment layout with an unrelated file between the fragments.
   - A decoy region that passes marker syntax but fails entropy decoding (must not be joined).
   - A progressive JPEG stays unreassembled.

## B. Carving the pre-checkpoint region on resume (owns `SalvageCore/Sources/SalvageCore/ScanSession.swift`, `ScanSessionTests.swift`, `ScanPauseTests.swift`, `ScanNoticeTests.swift`)

**Problem.** A resumed scan skips the bytes before its checkpoint, so it carves only the remaining bytes and emits `.resumedCarvingPartial`.

**Approach.**
- After the normal sweep completes on a resumed scan, run a **carve-only pass** over the covered-before-resume ranges.
- That pass reads the bytes again; reading is read-only and cheap compared to losing files. It feeds them to the carver with `beginExtent` per extent. It **does not** change measured progress, because those bytes are already counted. The progress UI shows the scan as still running until the pass ends.
- Respect pause, cancellation and checkpoints. The checkpoint gains `carveBackfillOffset` (bump the checkpoint version), so an interrupted backfill resumes too.
- Remove the `.resumedCarvingPartial` notice in the normal case. Keep it only if the backfill is cancelled.
- **Tests:**
  - A file whose header lies before the checkpoint is carved on resume.
  - Progress totals are unchanged.
  - Pause and cancel work during the backfill.
  - An interrupted backfill resumes.

## C. Automated UI tests (owns a new `SalvageUITests/` target, `project.yml` (adding that target only), `Salvage/SalvageApp.swift` and `Salvage/Views/ContentView.swift` (a DEBUG-only test-fixture hook only), a new `Salvage/Testing/UITestFixtures.swift`)

**Problem.** No one has driven the app's UI end to end. Computer use isn't available, and the user hasn't done a hands-on pass yet.

**Approach.**
- Add an XCUITest target. Add a **DEBUG-only** launch argument `-SalvageUITestFixture <name>`. It replaces the device watcher and the scan runner with in-memory fakes: a fake device list, and a fake `RawBlockReader` over a synthetic exFAT image that is built in memory, using the same FAT test-image construction approach. It also points recovery at a temp destination.
- The hook must compile out of Release builds entirely (`#if DEBUG`). No network.
- Write UI tests for:
  - (1) The device tree is shown, the boot drive is disabled, and selecting the fixture drive starts a scan.
  - (2) Progress, pause, resume, then completion.
  - (3) Dashboard tiles and counts, then open the Pictures bucket, select a file, and see its preview.
  - (4) Tick files with the keyboard (Cmd-A and Return), choose Recover, and choose a destination. Use a fixture-injected destination URL so no NSOpenPanel is needed. Recover, check the summary counts, and check the files exist byte-identical in the temp dir.
  - (5) A destination on the source shows the red block banner and Recover is disabled.
  - (6) The Trust Panel opens and its text is present.
  - (7) The FileVault sheet with a fixture encrypted volume: wrong password, then the correct one.
- Use accessibility identifiers for stable queries. Add them to views only where needed, as one-line `.accessibilityIdentifier` modifiers. Those modifiers are the only edits allowed in other view files.
- CI: add an xcodebuild UI-test step (unsigned Debug). If CI can't run UI tests (no GUI session), document that and gate the step on an env var instead of breaking CI.

## D. Performance (owns new `SalvageCore/Tests/SalvageCoreTests/PerformanceTests.swift`, `scripts/benchmark-scan.sh`; may optimize `Parsers/FATVolume.swift`, `Parsers/NTFSRecord.swift`, `Parsers/EXTVolume.swift`, `FileContentReader.swift` and `Salvage/ViewModels/ResultsViewModel.swift`; must NOT touch ScanSession, Carving, APFS or HFS+, which other items own)

**Approach.**
- Build a benchmark. It creates large realistic images in a temp dir with `hdiutil`: 2 GB exFAT and FAT32 images with about 50k files in nested folders, plus deleted files. It also creates a large synthetic NTFS/EXT image if feasible. It measures scan wall time, throughput and peak RSS, results-browser filter/sort time at 100k rows, and recovery throughput.
- Profile with `xcrun xctrace` or Instruments CLI, or `sample`, and fix the top hotspots that don't change behaviour, for example per-read allocations, actor hops per cluster, and repeated Data slicing. Report before/after numbers.
- Any hotspot inside ScanSession/MeasuredReader/carving is reported, not changed.
- Release-build numbers only.
- Keep the benchmark out of the default `swift test` run: enable it with `SALVAGE_BENCHMARK=1`.

## E. User documentation (owns `README.md`, new `docs/` folder)

**Approach.**
- `README.md`: what Salvage is, the trust promises (no network except the manual update check, read-only, open source), supported formats, a build-from-source quickstart, and links.
- `docs/USER-GUIDE.md`: install, the privileged helper approval, scan, the device tree, results, confidence labels, preview, recover, FileVault, lost partitions, reconstructed files, the "About this scan" notes, and limitations (boot disk, hardware-encrypted volumes, fragmented files). Write it in plain language that matches the app's copy. Read the real strings in the Swift views; don't invent UI.
- `docs/PRIVACY.md`: exactly what is read and written, the single network call and what it sends, and that credentials are never stored.
- `docs/CONTRIBUTING-SIGNATURES.md`: the AD-6 JSON signature schema (read `SignatureLibrary.swift` and the existing JSON files), with an example and how to test.
- `docs/ARCHITECTURE.md`: a short overview linking to the `_bmad-output` planning docs.
- Every factual claim must match the code; cite file paths in the docs where useful.

</frozen-after-approval>

## Implementation Notes — B

- **Carve backfill** (`ScanSession.carveBackfill`): after the sweep of a resumed scan, and before `carver.finish()`, every byte before the resume point is carved again with `beginExtent` per extent. It reads straight from the source reader, not `MeasuredReader`, so no progress event is emitted and measured bytes don't move. `.completed` comes only after the pass. Each chunk checks for cancellation and waits on the pause gate. A lost extent the device couldn't read is skipped, as in the sweep.
- **Straddling files**: on the extent the sweep resumed inside, the backfill reads on for up to `backfillOverrunBytes` (256 MiB) past the resume point, so a file that starts before the point is carved whole. Carves that start at or after the point were already reported by the sweep. A `CarveDropRange` filter on the carver's emit closure drops them. The carver API was not changed (Carving belongs to A). Known limits: a straddling file that runs more than 256 MiB past the point is still cut there. Dropped duplicates still count toward the carver's `maxCarvedFiles` cap.
- **Checkpoint v3** (`Entities/ScanCheckpoint.swift`): adds the optional `carveBackfillOffset`, which is left out of the JSON when nil. `currentVersion` is now 3, so v2 checkpoints are rejected and the scan starts from zero. Backfill checkpoints keep the sweep fields at the sweep's end, so `sweepOffset` still means what it did. `carveBackfillOffset` is the carving progress, as a position in the concatenated extents. `sweepStart` rejects a backfill checkpoint whose sweep had not finished. `isWellFormed` bounds the offset to `0...totalBytes`.
- **Resuming an interrupted backfill**: a cold resume skips the sweep (all bytes are counted) and carves the whole device again, from 0 rather than from `carveBackfillOffset`. The reason is that carved files don't survive a cold start: `ScanViewModel.reset` clears `files`. Resuming from the stored offset would therefore lose everything carved before it. The field records progress and marks the phase. It is not used as the restart point.
- **Notice**: `.resumedCarvingPartial` is no longer emitted when the backfill finishes. It is emitted only when a resumed scan is cancelled before its backfill ends. The notice text in `ScanNotice.swift` is unchanged.
- **Outside the owned files**: `SalvageTests/ScanViewModelTests.swift` `staleCheckpointsAreDiscarded` hard-codes checkpoint JSON with `"version":2`. The version bump broke it, so its fixture now uses 3, and its old-version case uses 2 instead of 1. No other batch-5 section owns that file.
- **Tests**: `ScanPauseTests` adds tests for these cases: a header before the checkpoint is carved, with progress unchanged; a straddling file is carved whole once (this test fails with the overrun set to 0); a file after the resume point is not reported twice; pause during the backfill; a cancelled backfill raises the notice, and its checkpoint resumes. The existing resume tests now expect the backfill reads, and the mismatched-checkpoint cases now include v2 checkpoints and malformed backfill checkpoints. `ScanNoticeTests` checks that a resumed scan that finishes has no notice.

## Verification (each agent runs what applies)

- `swift test --package-path SalvageCore`
- `swift test --package-path SalvageDiskIO`
- `./scripts/check-core-boundary.sh && ./scripts/check-no-network.sh && ./scripts/check-xcodeproj-sync.sh`
- `xcodebuild -project Salvage.xcodeproj -scheme Salvage -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:SalvageTests test`
- `xcodebuild -project Salvage.xcodeproj -scheme Salvage -configuration Release -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build`

## Implementation Notes — E

**Files:**
- `README.md`, rewritten. It covers what Salvage is, the trust promises, supported formats, the
  build-from-source quickstart, the project layout, links, and a "Not yet verified" section.
- New `docs/USER-GUIDE.md`, `docs/PRIVACY.md`, `docs/CONTRIBUTING-SIGNATURES.md` and
  `docs/ARCHITECTURE.md`.

**Method:**
- Every UI string quoted in the docs was copied from the Swift sources on `main` at `6e13fef`:
  `Salvage/Views/*`, `UnlockViewModel.Copy`, `PrivilegedHelperApproval`, `ScanNotice.text`,
  `ScanError.description`, `RecoveryCoordinator` and `TrustPanelCopy`.
- The supported formats come from `VolumeFormat`, `VolumeDiscovery` and the 19 bundled signature
  JSON files.
- The signature schema comes from `SignatureLibrary.swift`'s decoder.
- The network facts come from `UpdateChecker.swift` and `check-no-network.sh`.
- The written-data facts come from `ScanCheckpointStore` and `RecoveryCoordinator`.

**Marked as unverified** (README "Not yet verified", plus a banner at the top of the user guide):
- the signed privileged helper end to end on real USB drives and SD cards, including the TCC
  question from AD-13;
- hands-on and VoiceOver testing of the UI.

**Code/doc mismatches found** (documented in `docs/ARCHITECTURE.md`, code not changed):
1. **AD-3 in the spine puts FileVault unlock in SalvageDiskIO.** The app actually unlocks and
   decrypts in SalvageCore (`APFSCrypto` / `EncryptedVolumeUnlock`).
   `SalvageDiskIO/FileVaultUnlocker.swift`, the Story 2.4 `diskutil apfs unlockVolume` path, is
   still in the package but unused by the app. It looks like dead code worth removing.
2. **AD-11 says the scan pauses on `.unlockRequired`.** The code skips the locked volume, offers
   the sheet after the scan, and re-scans.
3. **The planning `ARCHITECTURE.md` says the app "prompts for Full Disk Access".** There is no
   such prompt. FDA appears only in the `ScanError.permissionDenied` text, and whether FDA is ever
   needed alongside the helper is still unverified.
4. **The old README's planning-doc link list named only AD-1 to AD-12.** The spine now has AD-13.

**Depends on parallel items A and B.** The docs describe `main` before batch 5. When A and B
merge, update these places:
- **A (bifragment JPEG):**
  - the USER-GUIDE "Fragmented files" limitation;
  - the CONTRIBUTING-SIGNATURES "Every carved file is one contiguous run" line.
  A reassembled JPEG has two runs and stays Low.
- **B (resume backfill):** the USER-GUIDE "About this scan" bullet for
  `.resumedCarvingPartial`. After B, it appears only if the backfill is cancelled.
- **C (UI tests):** if it lands with a passing run, soften the "hands-on UI testing" caveat.
  Automated XCUITests aren't the same as a hands-on pass.

**Not verified by this item:** whether a GitHub release exists. No local tags exist, so the
README and the guide say to build from source if none is listed. No code or tests were run for
this docs-only change.
