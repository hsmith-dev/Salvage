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
