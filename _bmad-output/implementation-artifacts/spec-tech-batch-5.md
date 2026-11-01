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

## Verification (each agent runs what applies)

- `swift test --package-path SalvageCore`
- `swift test --package-path SalvageDiskIO`
- `./scripts/check-core-boundary.sh && ./scripts/check-no-network.sh && ./scripts/check-xcodeproj-sync.sh`
- `xcodebuild -project Salvage.xcodeproj -scheme Salvage -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:SalvageTests test`
- `xcodebuild -project Salvage.xcodeproj -scheme Salvage -configuration Release -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build`

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
