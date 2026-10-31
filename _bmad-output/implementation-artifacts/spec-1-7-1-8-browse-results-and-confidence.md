---
title: 'Browse Results by File Type, with the Recovery-Confidence Indicator (Stories 1.7 + 1.8)'
type: 'feature'
created: '2026-10-31'
status: 'review'
baseline_commit: '0654e86'
route: 'dispatch'
context:
  - '{project-root}/_bmad-output/planning-artifacts/architecture/architecture-DataRecoveryTool-2026-10-30/ARCHITECTURE-SPINE.md'
  - '{project-root}/_bmad-output/planning-artifacts/ux-designs/ux-DataRecoveryTool-2026-10-31/DESIGN.md'
  - '{project-root}/_bmad-output/planning-artifacts/ux-designs/ux-DataRecoveryTool-2026-10-31/EXPERIENCE.md'
  - '{project-root}/_bmad-output/planning-artifacts/ux-designs/ux-DataRecoveryTool-2026-10-31/mockups/scan-results-dashboard.html'
  - '{project-root}/_bmad-output/planning-artifacts/ux-designs/ux-DataRecoveryTool-2026-10-31/mockups/file-browser.html'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Discovered files appear only as a flat list in `ScanProgressView`. Users need a Scan Results Dashboard of type buckets (Pictures, Videos, Audio, Documents, Archives, Other), each with a count and aggregate size (FR-11). They also need a File Browser showing each file's recovery confidence (FR-12, AD-7).

**Approach:**
- **Core:**
  - `FileCategory` classification (by extension, with a magic-byte hook left for later).
  - The single pure `RecoveryConfidence` function from AD-7: `RecoveryMethod` (`.metadata` / `.carved`) plus graduated evidence goes in, `.high` / `.medium` / `.low` comes out.
- **App:**
  - `ResultsDashboardView` (bucket tiles).
  - `FileBrowserView`: rows with checkbox, name, path, size, modified date and the confidence label, plus a preview pane slot and a persistent "Recover (n selected)" button.
  - `ResultsViewModel`.
  - `ContentView` shows the dashboard once a scan has ended with files (completed, cancelled or failed). It keeps showing `ScanProgressView` while the scan is running or paused.

## Boundaries & Constraints

**Always:**
- **Categories:** classified by file extension, case-insensitive. Unknown types go under Other and are never dropped. Each category has its own `RecoveryMethod` floor. For v1, every `RecoveredFile` from a parser is recovered via `.metadata`.
- **AD-7 evidence:** `fragmentCount: Int` (number of non-hole runs) and `overwriteConfidence: Double` in 0...1.
  - Live and deleted files from intact metadata both give `overwriteConfidence = 0`. Deleted files already passed the free-space check.
  - **Floor rule:** metadata-recovered is High. A carved file is never High, whatever its evidence (Medium when `fragmentCount <= 1` and `overwriteConfidence < 0.5`, otherwise Low).
  - Add tests proving the carved floor, using a hypothetical carved input.
- **Unmapped files:** a file whose `content` is `.unmapped` shows "Can't be recovered" in place of a confidence label. It can't be selected for recovery. It does not count toward the recoverable totals; show it separately.
- **macOS AppleDouble files:** names starting with `._`, plus `.fseventsd`, `.Spotlight-V100`, `.Trashes` and `.DS_Store` paths. Hide them by default behind a "Show system files" toggle.
- **Confidence label:** text only, never color, with the size/weight/tone triple from `DESIGN.md`. VoiceOver announces the word.
- **File Browser:**
  - Columns: name (with a "Deleted" text tag), path, size, modified.
  - Sortable, with a search field.
  - Checkbox multi-select and a "Recover (n selected)" button that shows the live count, with no select mode.
  - Single click selects and previews; Space previews.
- **Integration slots.** Stories 1.9 and 1.10 are being built in parallel and will provide these views. Put a placeholder in each slot, and keep the slot code in one obvious place so it is trivial to swap.
  - **Preview pane:** call `FilePreviewView(file: RecoveredFile, source: SourceSession?)` (1.9). Until it exists, use a placeholder file `Salvage/Views/PreviewSlot.swift` with `struct PreviewSlot: View` showing "No preview available".
  - **Recover button:** present `RecoverySheet(files: [RecoveredFile], source: SourceSession, onDone: () -> Void)` (1.10). Until it exists, use a placeholder `RecoverySlot.swift` with `struct RecoverySlot: View`.
- **Dashboard:** shows count and size per bucket and a total. When a scan finished with nothing recoverable, it says "No recoverable files found on this device." plainly.
- **Large result sets:** the browser must stay responsive at 100k files. Use `List`/`Table`, which are lazy, and do filtering and sorting off the render path.

**Never:**
- No color-coded confidence.
- No edits to the parsers, `FileContentReader.swift`, `ScanSession.swift`, `ScanViewModel.swift`, `ScanProgressView.swift` or DiskIO.
- In `ContentView.swift`, edit only the `detail:` content switch.
- Don't create `FilePreviewView.swift` or `RecoverySheet.swift`; parallel stories own them.

</frozen-after-approval>

## Code Map

- **New Core files:**
  - `SalvageCore/Sources/SalvageCore/Entities/FileCategory.swift`
  - `SalvageCore/Sources/SalvageCore/Confidence/RecoveryConfidence.swift`
  - `SalvageCore/Tests/SalvageCoreTests/RecoveryConfidenceTests.swift`
  - `SalvageCore/Tests/SalvageCoreTests/FileCategoryTests.swift`
- **New app files:**
  - `Salvage/ViewModels/ResultsViewModel.swift`
  - `Salvage/Views/ResultsDashboardView.swift`
  - `Salvage/Views/FileBrowserView.swift`
  - `Salvage/Views/ConfidenceLabel.swift`
  - `Salvage/Views/PreviewSlot.swift`
  - `Salvage/Views/RecoverySlot.swift`
  - `SalvageTests/ResultsViewModelTests.swift`
- **Existing file:** `ContentView.swift`, the detail switch only. `ScanViewModel` exposes `files`, `state` and `source`.
- **Project:** regenerate with `xcodegen generate`.

## Verification

- `swift test --package-path SalvageCore`
- `./scripts/check-core-boundary.sh && ./scripts/check-no-network.sh`
- `xcodebuild -project Salvage.xcodeproj -scheme Salvage -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:SalvageTests test`
- `xcodebuild -project Salvage.xcodeproj -scheme Salvage -configuration Debug -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build`

## Implementation Notes

The spec has no task list, so there was nothing to tick. Judgment calls:

- **"Each category has its own `RecoveryMethod` floor":** read as "each `RecoveryMethod` has its own confidence floor", which is AD-7's floor rule. `FileCategory` has no method of its own. `RecoveredFile.recoveryMethod` is always `.metadata` in v1.
- **Evidence derivation (`RecoveredFile.recoveryEvidence`):** `fragmentCount` counts the non-hole `.runs` entries. `.resident` counts as 1 and `.unmapped` as 0. `overwriteConfidence` is always 0. In the carved branch, a NaN or negative `overwriteConfidence` gives Low; it is never trusted as safe.
- **Magic-byte hook:** `FileCategory.classify(fileName:signature:)` checks the signature only when the extension is unknown. `fromSignature` returns nil until carving needs it.
- **When results replace progress (`ResultsViewModel.showsResults`):**
  - A completed scan always shows the dashboard, even with zero files, so it can say "No recoverable files found on this device."
  - A cancelled or failed scan shows the dashboard only when files were found.
  - A failed scan with no files stays on `ScanProgressView`, which keeps its error and Retry.
  - The dashboard repeats the failure text and the Retry button, using the same condition as `ScanProgressView`.
  - `ResultsView` is keyed by `scan.endedAt`, so each finished scan gets a fresh model.
- **System files:** the "Show system files" toggle sits on both the dashboard and the browser, and one model flag drives both. While hidden, system files are also left out of the bucket counts and totals, and a caption states how many are hidden. A path counts as a system file when any component is `._*`, `.DS_Store`, `.fseventsd`, `.Spotlight-V100` or `.Trashes`.
- **Unmapped files:**
  - They are kept out of the bucket counts and totals and shown in their own "Can't be recovered" section on the dashboard.
  - In the browser they are listed with a disabled checkbox. `setChecked` refuses them.
- **Responsiveness:**
  - Per-file data (category, confidence, system flag, lowercased search key) is computed once, off the main actor, in `ResultsViewModel.build`.
  - Filtering and sorting run in a detached task from `.task(id: model.query)`. A stale result is dropped by a generation check.
  - The `Table` is lazy (NSTableView), and the table sort comparators map to the model's own `Sort`.
  - A test covers 100k files.
- **Space key:** Space toggles the preview pane for the selected row, like Quick Look. A single click selects and previews.
- **Integration slots:** each slot has the exact signature of the view that will replace it. The call sites are marked `INTEGRATION SLOT` in `FileBrowserView` (`previewPane` and `recoverySheet(_:)`), so swapping is a rename plus deleting the placeholder file.
- **Recover button:** disabled when nothing is ticked or when `scan.source` is nil. The sheet's `onDone` only dismisses it and keeps the ticked files.
- **Accent color:** there is no asset catalog, so `Color.salvageAccent` is a dynamic `NSColor` built from the DESIGN.md hex values. It is used only on the Recover button.
