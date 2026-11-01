---
title: 'Scan Notices: Tell the User What a Scan Could Not Do'
type: 'tech'
created: '2026-10-31'
status: 'done'
baseline_commit: 'd04d613'
route: 'dispatch'
context:
  - '{project-root}/_bmad-output/planning-artifacts/architecture/architecture-DataRecoveryTool-2026-10-30/ARCHITECTURE-SPINE.md'
  - '{project-root}/_bmad-output/implementation-artifacts/deferred-work.md'
  - '{project-root}/_bmad-output/planning-artifacts/ux-designs/ux-DataRecoveryTool-2026-10-31/EXPERIENCE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Core already computes facts the user needs, but the app can't show them, because `ScanEvent` is closed (AD-11):
- the lost-partition search was limited (`VolumeDiscovery.Result.probesTruncated` / `searchedBytes`), or skipped unreadable probes;
- a damaged partition table was ignored (`Result.warnings`);
- the carver hit its file cap (`SignatureCarver.hitFileLimit`), or signature files were skipped (`SignatureLibrary.skipped`);
- a resumed scan carved only the remaining bytes;
- a mapped volume's parser failed.

The last one also ends the scan today, so files on the device's *other* volumes are never scanned (deferred from Story 1.4).

**Approach:**
- Add a side channel exactly like checkpoints: `ScanSession.run(..., notices: AsyncStream<ScanNotice>.Continuation? = nil)`. `ScanEvent` stays closed (AD-11). Record the side channel in AD-11's text with one sentence.
- `ScanNotice` is a small closed Core enum, each case with plain-language text:
  - `.partitionTableIgnored(reason:)`
  - `.lostPartitionSearchLimited(searchedBytes:, deviceBytes:)`
  - `.unreadableAreasSkipped(count:)`
  - `.carvingLimitReached(count:)`
  - `.signaturesSkipped([String])`
  - `.resumedCarvingPartial`
  - `.volumeSkipped(formatName:, offset:, reason:)`
- **Per-volume isolation for mapped volumes.** A mapped volume's parser failing with `.malformed` / `.unsupportedFilesystem` no longer ends the scan. Emit `.volumeSkipped`, keep the files already emitted, and continue with the remaining volumes and the sweep and carving. I/O errors on a mapped volume and cancellation still end the scan, as today. A single-volume device whose only volume fails still reports `.error(.malformed)` (unchanged).
- **App:** `ScanViewModel` collects notices into `notices: [ScanNotice]` (reset per scan). `ResultsDashboardView` shows them in one calm "About this scan" section below the tiles, text only, with no alarm color (DESIGN.md). Also fix the dashboard wording that says results are "indexed from intact metadata" when reconstructed files exist, and the tile accessibility label.

## Boundaries & Constraints

**Always:**
- Notices never duplicate an `.error`.
- Text is plain language (EXPERIENCE.md voice), e.g. "The search for lost partitions covered the first 512 GB of this 2 TB drive." and "Part of this drive couldn't be read, so 3 areas were skipped."
- Tests cover each notice's producer, the per-volume isolation (two-volume device with the first corrupt → second volume's files found, `.completed`, one `.volumeSkipped`), and the app's collection and rendering model.

**Never:**
- No new `ScanEvent` case.
- In `ScanSession.swift`, add only the `notices` plumbing, the mapped-volume isolation, and producer calls. Another agent adds a `credentials` parameter there in parallel; keep your edits to separate lines.
- Don't edit any parser or the carving engine beyond reading the already-exposed `hitFileLimit` / `skipped` / discovery result.
- Don't edit `FileBrowserView.swift`.

</frozen-after-approval>

## Code Map

- **New:** `SalvageCore/Sources/SalvageCore/Entities/ScanNotice.swift`.
- **Core:** `ScanSession.swift`.
- **App:** `Salvage/ViewModels/ScanViewModel.swift` (notices only), `Salvage/Views/ResultsDashboardView.swift`, `Salvage/Views/ContentView.swift` (the `runScan` notices stream only).
- **Tests:**
  - New `SalvageCore/Tests/SalvageCoreTests/ScanNoticeTests.swift`.
  - Update existing ScanSession tests that asserted fail-the-whole-scan behaviour for a corrupt volume among several.
  - `SalvageTests/ScanViewModelTests.swift` additions.
- **Docs:** AD-11 one sentence; mark the corresponding `deferred-work.md` entries resolved.

## Verification

- `swift test --package-path SalvageCore`
- `./scripts/check-core-boundary.sh && ./scripts/check-no-network.sh`
- `xcodebuild -project Salvage.xcodeproj -scheme Salvage -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:SalvageTests test`
- `xcodebuild -project Salvage.xcodeproj -scheme Salvage -configuration Debug -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build`

## Implementation Notes

- **Single-volume rule.** A mapped volume's `.malformed` / `.unsupportedFilesystem` failure is isolated only when discovery returned more than one extent (mapped or lost). With exactly one extent the error is rethrown unchanged, so a one-volume device still reports `.error(.malformed)` and emits no `.volumeSkipped` (notices never duplicate an error). If every volume of a multi-volume device fails, each gets a `.volumeSkipped` and the scan still sweeps, carves and completes.
- **Skipped volume is still swept.** A skipped mapped volume stays in the sweep, so the carver can reconstruct files from its bytes. Files that its parser emitted before failing keep their claimed runs.
- **`volumeSkipped.formatName`** is `extent.formatName ?? format.displayName`. For a mapped FAT volume that reads "FAT32/exFAT", because discovery does not tell the two apart for mapped extents and parsers were out of scope. `reason` is `ScanError.description`.
- **`partitionTableIgnored(reason:)`** comes from `VolumeDiscovery.Result.warnings`, which is a list of strings. The parser could not be edited, so `ScanSession.discoveryNotices` recognises the ignored-table sentence by its fixed prefix and suffix and pulls out the reason. The reason is kept on the value but left out of the user-facing text, because it is technical (e.g. "Invalid GPT header checksum or backup location.").
- **Search-limit and unreadable notices** come from the structured fields (`probesTruncated` + `searchedBytes`, `failedProbes`), not the warning strings. When the search stopped after repeated read failures, both `.lostPartitionSearchLimited` and `.unreadableAreasSkipped` are emitted.
- **`carvingLimitReached(count:)`** reports `carverLimits.maxCarvedFiles`, since the cap is only reached at that count. `.resumedCarvingPartial` is emitted only when the accepted checkpoint is past the very start of the sweep.
- **Test seams.** `ScanSession` has two internal stored vars with defaults, `signatureLibrary` (`.bundled`) and `carverLimits` (`.default`), so tests can reach the signature-skipped and carving-limit producers. The public API and the inits are unchanged.
- **App.** `ScanViewModel` drops an exact repeat of a notice and exposes `noticeLines` as the rendering model. The dashboard section sits below the tiles, the lost-partition card and the "Can't be recovered" section, using secondary text only. `ResultsDashboardView.closingNote` / `tileAccessibilityLabel` are static so they can be tested.
