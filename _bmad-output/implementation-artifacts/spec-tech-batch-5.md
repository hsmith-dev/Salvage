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
