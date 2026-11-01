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

## Implementation Notes — D

**What was built.**
- `SalvageCore/Tests/SalvageCoreTests/PerformanceTests.swift` holds one suite, gated on `SALVAGE_BENCHMARK=1`, so the default `swift test` run reports it as skipped. It builds a 2 GiB image with `hdiutil` in a temp dir: exFAT on GPT (4 KiB clusters, `-fsargs "-c 8"`), or FAT32 on MBR. The image gets 50,000 files across 1,000 nested folders (`Folder N/Album M/…`). Sizes run from 1 KiB to 4 MiB (about 1.5 GB in total). Names mix 8.3 and long names. 10% of the files are deleted. The image is attached with `-nobrowse` at a private mount point, then detached. The test then:
  - scans the detached image *file* (pread, no device node) through `ScanSession`;
  - recovers every metadata-found file to a temp folder;
  - re-reads all of them through `FileContentReader` alone (the source-side throughput);
  - checks 200 sampled files byte for byte.

  It reports wall time, CPU time, the device reads issued, throughput, peak physical footprint (sampled every 20 ms) and peak RSS. Knobs: `SALVAGE_BENCHMARK_FS/FILES/SIZE_MIB/DIR/SCAN_REPEATS/SKIP_RECOVERY/REPORT`.
- `scripts/benchmark-scan.sh [all|scan|results]` runs one Release `swift test` process per image, so peak RSS is per scan. It also builds the app's own `ResultsViewModel.swift`, unmodified, into a throwaway Release executable against SalvageCore. That executable times row building, the aggregates, and 26 filter/sort queries over 100k rows. Each query also runs through a verbatim copy of the pre-batch-5 `apply`. The script fails unless both versions return the same rows in the same order. Images are deleted on exit unless `SALVAGE_BENCHMARK_DIR` is given. No sudo is used.
- A large NTFS/EXT image was **not feasible**. `hdiutil` cannot format either. This host has no `mke2fs`/`mkntfs`. The in-test builders (`EXTImage`, `NTFSImage`) are fixed at 1–2 groups and a few hundred blocks. So `EXTVolume.swift` and `NTFSRecord.swift` were neither profiled at scale nor changed.

**Host caveat.** Apple M5 Max (18 cores). Up to five other agents were building and testing on the same machine (load average 15 → 230 during the runs). Wall times varied up to 5× between identical runs. The figures below are best-of-6 warm-cache Release scans, with before and after interleaved in the same session (before = `HEAD` versions of the four optimizable Core files). CPU time and device-read counts are the stable comparisons. The read counts are deterministic.

**Scan, 2 GiB image, 50k files (91,050 live entries including macOS `._` AppleDouble files, 10,000 deleted, 0 carved; identical before/after):**

| | exFAT before | exFAT after | FAT32 before | FAT32 after |
|---|---|---|---|---|
| wall (best of 6, quietest round) | 0.873 s | 0.728 s (−17%) | 1.063 s | 0.681 s (−36%) |
| throughput | 2,343 MiB/s | 2,810 MiB/s | 1,926 MiB/s | 3,006 MiB/s |
| CPU (user+sys) | 1.053 s | 0.896 s (−15%) | 1.282 s | 0.827 s (−35%) |
| device reads | 31,159 | 7,156 (−77%) | 38,234 | 5,842 (−85%) |
| bytes read from device (2 GiB image) | 2.69 GB | 2.16 GB | 4.28 GB | 2.16 GB |
| peak footprint during scan | 121.8 MiB | 112.6 MiB | 118.1 MiB | 112.3 MiB |
| process peak RSS | 229 MiB | 225 MiB | 230 MiB | 219 MiB |

On FAT32, half of all bytes read were the same 64 KiB FAT pages read again. A first, cold-cache scan right after the image was built took 2.0 s (exFAT) and 2.8 s (FAT32), before the change.

**Recovery (101,050 files, 1.54 GB):** 139–208 MiB/s in the quietest round (7.1–10.6 s), 32–71 MiB/s under peak load, with no consistent before/after difference; the recovery path was not changed. Profiling (`sample`) puts almost all of it in destination `open`/`write`/`close`, and in rename/fstat in the harness's first version. The source side alone (`FileContentReader` with no destination) runs at 3.7–10 GB/s on a warm cache, so `FileContentReader.swift` has no hotspot to fix and was left unchanged.

**Results browser, 100k rows (Release; `before_ms` is the verbatim pre-batch-5 `apply` in the same process; quieter run):**

| query | before | after |
|---|---|---|
| default (name asc, system files hidden) | 681 ms | 412 ms |
| name desc | 614 ms | 576 ms (375 ms with system files) |
| path asc | 247 ms | 78 ms |
| size asc / desc | 103 / 95 ms | 18 / 18 ms |
| modified asc / desc | 139 / 230 ms | 20 / 36 ms |
| search "photo 12" (ASCII) | 137 ms | 13 ms |
| search, no match | 118 ms | 13 ms |
| search "café" / "写真" (non-ASCII, Foundation path) | 119 / 203 ms | ~same |
| category Pictures, name sort | 107 ms | 80 ms |
| build 100k rows / both aggregates | 99 ms / 35 ms | unchanged |

The second run, under load average 230, showed the same ratios at 3–10× the absolute times: for example, default sort 4,227 → 2,276 ms and "no match" 677 → 12 ms. All 26 queries returned identical results in both runs.

**Hotspots found and fixed (no behaviour change):**
1. `FATVolume.fatEntry`, and the exFAT `allocatedInBitmap`, kept a single cached page. Chain lookups alternate between a directory's chain and its files' chains, so the same 64 KiB FAT page was read again thousands of times, each read going through the `MeasuredReader` actor. They now use `PageCache`: an LRU of 64 pages (at most 4 MiB of FAT and 256 KiB of bitmap per volume). The source is read-only, so a cached page holds exactly the bytes a re-read would return. A failed read is still not cached, so the read-error tests see the same failures.
2. `FATVolume.validName` took 17% of FAT32 scan samples and 10% of exFAT: Foundation's `String.contains("/")` / `contains("\0")` → `range(of:options:range:locale:)`, called for every entry. For an ASCII name it is now a UTF-8 byte test. Any non-ASCII name still goes through the original Foundation calls, which match whole characters: `"a/\u{301}b".contains("/")` is false. A randomized check over 300k ASCII strings showed the two agree.
3. FAT `lfnName` decoded each UTF-16 unit through the generic `Data.number`. It now reads the bytes directly; the slots were already checked to be 32 bytes. exFAT `decodeExfatSet` computed its checksum by enumerating a concatenated copy of the entry set. It now walks the entries. `rawRecord` values are built in one allocation (`joined`) instead of `reduce(Data(), +)`. The bytes are identical.
4. `ResultsViewModel.apply` copied whole `Row` values (each holding a full `RecoveredFile`) through the filter, the sort and the reconstructed-section split, and read `name`/`path` through them in every comparison. It now filters and sorts row indices against per-query key arrays and bridges names to `NSString` once per query. The comparisons, their order (so ties land the same way) and the cancellation checks are unchanged. Search uses a byte substring test when the search text and key are ASCII and the needle does not start with LF or end with CR. That test matches Foundation's character-wise result; it was checked over random ASCII strings including CR/LF. Everything else goes through `String.contains` as before.

**Hotspots reported, not changed (owned by other items or outside D's files):**
- **ScanSession per-file emit** (`closure #6 in ScanSession.run`): 13% of FAT32 and 18% of exFAT scan samples. Every found file costs an `await claimed.add(runs)` hop to the `ClaimedRuns` actor plus `AsyncStream.send`. Batching claims, or keeping them in the session's own task, would remove one actor hop per file.
- **MeasuredReader**: every parser read hops to this actor, scans `extents.contains(where:)` and calls `now()`. After fix 1 this matters far less, because reads dropped by 77–85%. A per-volume read-through, or skipping the clock check on small reads, would cut it further.
- **SignatureCarver.consume/scan**: 15–18% of scan samples on these mostly-claimed images. That share would grow on images with more unclaimed space. `claimedRange(containing:)` showed up separately.
- **`Data.number`** (VolumeDiscovery.swift) uses a generic `reduce` closure per field. It is used by every parser; a fixed-width load would help all of them.
- **FAT/exFAT timestamps**: `FATVolume.timestamp` builds a `Calendar` and calls `date(from:)` for every file, about 3% of samples. A cached calendar per zone would help, but was left alone to keep the date semantics untouched.
- **Results name sort**: after fix 4, `localizedStandardCompare` itself (CFString/ICU collation) is about 60% of the default sort. Precomputed collation keys would change comparison semantics, so it was not attempted.
- **Recovery**: destination file creation dominates (see above). That is RecoveryCoordinator and the filesystem, not the source read path.

**Verification (D branch):**
- `swift test --package-path SalvageCore`: 385 tests in 30 suites. All passed, with the benchmark suite skipped. In one full run under load average ~230, `HFSPlusRealImageTests.deletedFilesAreRecoveredFromTheJournalUnlessTheirBlocksWereReused` failed: an hdiutil journal-timing test that touches no D file. Its suite then failed once and passed once with D's changes, and passed on unmodified sources. It is load-dependent, not a regression.
- `swift test --package-path SalvageDiskIO`: 174 tests in 24 suites, all passed.
- The three check scripts pass.
- `xcodebuild … -only-testing:SalvageTests test` (Debug): 149 tests in 13 suites, TEST SUCCEEDED.
- The Release build succeeded.

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

## Implementation Notes — C

**What was built**
- `Salvage/Testing/UITestFixtures.swift` (whole file inside `#if DEBUG`): `UITestFixture`, enabled by `-SalvageUITestFixture <standard|slowScan|destinationOnSource|fileVault>`. It provides a fake `DeviceWatching` (a grayed boot drive `disk990`, the fixture drive `disk991` and, for `fileVault`, a locked drive `disk992`). It also provides a scan runner that drives the real `ScanSession` over an in-memory `BlockReader` holding a synthetic exFAT image built the same way as `exfatImage()` in `ScanSessionTests.swift`: 4 KiB clusters, bitmap, contiguous files in `/DCIM`, `/Documents` and the root, two pictures encoded with ImageIO and three documents. The image is 8 MiB, or 64 MiB with a 400 ms delay per 1 MiB sweep read for `slowScan` (about 26 s, so pausing is reliable even on a loaded machine). The rest of the fixture covers recovery and unlock: a recovery destination preset from `-SalvageUITestDestination <dir>`, a destination verdict (`.safe`, or `.sameDevice` for `destinationOnSource`) carrying the real `statfs` mount source so the engine's opened-folder check still runs, and a fake FileVault check. `-SalvageUITestExpected <dir>` writes the fixture files' exact bytes for the byte-identical comparison. In fixture mode no checkpoints are saved and nothing touches Application Support.
- `ContentView.swift`: a `#if DEBUG` branch in `init` swaps in the fixture runner and unlock check. It also adds `CompositionRoot` (`deviceWatcher()`, `recoveryCoordinator(files:source:)`, `presetDestination`). These return the live adapters, and only their `#if DEBUG` lines consult the fixture. `SalvageApp.swift` needed no change.
- `SalvageUITests/SalvageUITests.swift`: the 7 tests (1)–(7). Tests write only to a per-test folder under the runner's temporary directory, which is deleted in `tearDown`. They never press Check for Updates.
- `project.yml`: a new `SalvageUITests` (`bundle.ui-testing`) target, added to the `Salvage` scheme's test targets so `-only-testing:SalvageUITests` works. The xcodeproj was regenerated with xcodegen 2.46.0.
- CI (`.github/workflows/ci.yml`): `build-for-testing` (unsigned) always runs. The UI-test run is gated on the repository variable `SALVAGE_RUN_UI_TESTS == '1'`, because XCUITest needs a GUI session plus automation permission, which hosted runners don't reliably provide. That step ad-hoc signs (`CODE_SIGN_IDENTITY="-"`).

**Deviation (needs a human ack).** Section C allows only one-line `.accessibilityIdentifier` additions in other view files. However, the device watcher and the recovery destination are created *inside* `DeviceListView` and `RecoverySheet`, not in `ContentView`, so a fake can't be injected without touching them. Three one-line seam calls were added, and in Release builds they resolve to exactly the previous live behavior:
- `DeviceListView.swift`: `DeviceListViewModel(watcher: CompositionRoot.deviceWatcher())`
- `RecoverySheet.swift`: `CompositionRoot.recoveryCoordinator(files:source:)` in `init`
- `RecoverySheet.swift`: the first line of `chooseDestination()` uses `CompositionRoot.presetDestination`, which is always nil in Release, instead of `NSOpenPanel`.
Every other edit in view files is a one-line `.accessibilityIdentifier`: `device-row-<bsd>`, `scan-title`, `scan-progress-percent`, `results-status`, `bucket-<category>`, `file-table`, `recover-button`, `file-preview`, `preview-image`, `recovery-confirm-button`, `destination-blocked-banner` and `recovery-summary-headline`.

**Limits of the fakes**
- `VolumeCredential` exposes no way to read its secret outside SalvageCore. The fixture's unlock check therefore accepts a password by kind and byte length (`fixture-vault-pass`, 18 bytes) and rejects others such as `wrong`. It tests the sheet's flow, not decryption.
- Test (5) checks the UI's handling of a `.sameDevice` verdict. The real `DestinationSafety` resolution of fake BSD names can't be exercised; its own unit tests cover that.
- Test (3) checks that the image renders by sampling the preview pane's pixels for the fixture picture's saturated colours, because SwiftUI's decorative `Image` isn't exposed to accessibility.
- SwiftUI repeats a merged row's identifier (`device-row-disk991-device-row-disk991`), so the tests also match the identifier as a prefix.

**Release check.** A Release build was made with the Verification command. `strings` and `nm` on `Salvage.app/Contents/MacOS/Salvage` and on the Release `UITestFixtures.o`/`ContentView.o` show 0 occurrences of `UITestFixture`, `SalvageUITestFixture`, `SalvageUITestDestination`, `SalvageUITestExpected`, `ExFATFixtureImage`, `FixtureReader`, `FixtureDeviceWatcher`, `fixture-vault-pass` and `Salvage Fixture Drive`. The Debug `Salvage.debug.dylib` does contain `SalvageUITestFixture` (positive control).

## Implementation Notes — A

**Outcome: the decoder ships and is used; reassembly is built and tested but off by default, because entropy validation turned out not to be reliable enough.** Today's behaviour for split JPEGs (partial, Low) is kept, with one honesty fix (below).

**What shipped** (`SalvageCore/Sources/SalvageCore/Carving/`):
- `JPEGEntropyDecoder.swift`: a baseline (SOF0) / extended Huffman (SOF1, 8 or 12-bit) decoder. It parses DQT/DHT/SOF/DRI/SOS and decodes every MCU's DC/AC coefficients. It checks Huffman codes (all-ones codes are rejected, as libjpeg does), coefficient positions (k ≤ 63, ZRL room, size categories), the DC range the DC quantizer allows, the restart-marker placement, numbering and one-bit padding, and EOI after exactly the frame's MCU count. It produces no pixels. `JPEGBaselineDecoder.decode(Data)` returns the outcome, `mcusDecoded`/`totalMCUs`, `validUpTo` and `restartSequenceOK`. Progressive, lossless, arithmetic, hierarchical, multi-scan and DNL files are reported as `unsupported`, never as `invalid`. `JPEGScanDecoder` is a value-type streaming decoder; a copy is a snapshot at a byte boundary.
- Every JPEG carve now runs its scan data through the decoder while it looks for the footer (new signature field `"entropy": "jpegBaseline"` in `jpeg.json`, parsed and validated in `SignatureLibrary.swift`; it requires `segments` with `stopAt` and a `footer`). **Behaviour change:** if the scan data stops decoding, a later `FFD9` no longer validates the carve. It is reported as partial with overwrite 1.0 (`.inconsistent`, Low) instead of complete and Medium. The bytes emitted are unchanged. Files the decoder can't judge, including the existing fake test JPEGs that have no DHT/SOF, behave exactly as before.
- `JPEGReassembly.swift` implements the spec's search, gated by `SignatureCarver.Limits.reassembleFragmentedJPEGs` (default `false`):
  - Break candidates are the decoder snapshots at sector boundaries since the last valid RST, up to the failure point or the cut. At most `maxJoinBreaks` = 16 are kept; on real JPEGs, random bytes after a break failed within a median of 52 and a maximum of 591 bytes.
  - Resume candidates are later, sector-aligned positions within 16 MiB, at most 4096 of them. A position is skipped if it is claimed, holds a header, or lies inside another carve's validated or validly-decoding range.
  - Total decode work is capped at 64 MiB per JPEG, and at most 4 JPEGs search at once.
  - A join is emitted only when exactly one (break, resume) pair decodes the full MCU count and RST order to EOI. It gets two runs, `isPartial: false`, overwrite 0.3 and Low confidence. If two pairs validate, the result is ambiguous and nothing is joined.

**Why reassembly is off.** I measured with layouts where the true second fragment is gone. The orphaned tail of another JPEG with the same Huffman tables and dimensions (sibling photos from one camera) often passes full validation. Huffman codes self-synchronize, and among the thousands of (break, resume) pairs tried, one lands the tail on exactly the right MCU index. From there it decodes to EOI with the right count, and with RST markers it also has the right restart numbers, because the indices line up.
- With tiles of a real photo re-encoded by ImageIO, wrong joins came out in 4/37 layouts at 320×240, 4/17 at 640×480 and 1/5 at 1024×768. Synthetic JPEGs gave 2/210.
- I prototyped a vertical luma-DC seam-continuity test. Wrong joins scored a seam/reference ratio of 2.2–47, and true joins up to 6.2, so the two overlap. I removed the test rather than ship a heuristic that both lets wrong joins through and drops true ones.
- Since a wrong picture is worse than a partial one, the default keeps today's behaviour. `aSameSizeSiblingsOrphanedTailCanPassEntropyValidationWhichIsWhyJoiningIsOff` pins this hazard down.
- Two further recall limits when the flag is on:
  - If the gap holds zeros and the tables code `00` bits as DC-0 + EOB (ImageIO's do), a join shifted through the zeros validates as well as the true one, so the tie is refused.
  - Joined results are held back until the search window has passed. A scan cancelled or checkpointed in that window loses the held partial, just as open carves are lost today.
- Making joins reliable likely needs pixel-domain boundary matching (IDCT plus edge continuity), which this spec puts out of scope.

**Tests** (`CarvingTests.swift`, new suite "Baseline JPEG entropy decoding and bifragment reassembly", 14 tests):
- Decoding: in-test T.81 encoder output (4:2:0, 4:2:2 SOF1, 4:4:4, gray; with and without restart markers), ImageIO baseline JPEGs, and ImageIO progressive JPEGs (unsupported). Broken, out-of-sequence-RST, truncated and early-EOI data.
- Carving: contiguous real JPEGs still give one validated run. A two-fragment layout with an unrelated PNG between the fragments is joined with the flag on, at four chunk sizes, with and without RST. A headerless gap with a stray `FFD9`, and a claimed live file between the fragments, are also joined.
- Not joined: decoys (FF-free filler, stuffed random bytes, the true tail with one corrupted byte); two valid continuations (ambiguous); a progressive JPEG; a fragment outside the search window.
- With the defaults, a split JPEG stays partial, and a stray footer no longer validates broken scan data.
- I also checked the decoder offline against 300 JPEGs on this Mac: 294 decoded `complete`, 6 progressive were `unsupported`, 0 were wrongly invalid, and 160 of them use restart markers.

**Performance:** always-on decoding of carved JPEG scan data measured about 90–110 MB/s of JPEG bytes in a release build, on a loaded machine. This only touches unclaimed JPEG regions. It is a possible scan bottleneck on fast drives full of deleted photos, and is reported here for D rather than tuned further.
