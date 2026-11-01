---
title: 'Batch 7: disk-image scanning, saved scans, file details, recovery report, app icon'
type: 'feature'
created: '2026-10-31'
status: 'ready-for-dev'
baseline_commit: '3836be8'
route: 'dispatch'
context:
  - '{project-root}/_bmad-output/planning-artifacts/architecture/architecture-DataRecoveryTool-2026-10-30/ARCHITECTURE-SPINE.md'
  - '{project-root}/_bmad-output/planning-artifacts/ux-designs/ux-DataRecoveryTool-2026-10-31/DESIGN.md'
  - '{project-root}/_bmad-output/planning-artifacts/ux-designs/ux-DataRecoveryTool-2026-10-31/EXPERIENCE.md'
  - '{project-root}/docs/USER-GUIDE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

Five independent items, one agent each. Each lists the files it owns. Global rules:
- No network.
- No writes to any disk device; the source is always read-only.
- No sudo.
- Disk images only in temp dirs, detached and deleted afterwards.
- Don't interfere with other apps or sessions.
- Plain-language copy in the app's existing voice.
- Every feature gets unit tests. UI-facing items also add a UI test to `SalvageUITests` in a **new file**, using the existing DEBUG fixture approach.
- Update `docs/USER-GUIDE.md` **only in your own new section**, with a heading named after your item.

## A. Scan a disk-image file (owns new `Salvage/ViewModels/ImageSource.swift`, `Salvage/Views/OpenImageCommand.swift`; minimal edits to `ContentView.swift` (runner selection only) and `SalvageApp.swift` (one menu command), and a new section in `DeviceListView.swift` for "Disk images")

**Problem:** users have `.dmg`/`.img`/`.iso`/`.dd` backups or images of failing drives. Today they must attach them with `hdiutil` first, and macOS may mount them.

**Approach:**
- Add **File → Open Disk Image…** (⌘O) and drag-and-drop onto the device list.
- **Reading:**
  - Raw images (`.img`, `.dd`, `.bin`, `.iso`, `.raw`, or anything not recognised as UDIF) are read directly with read-only `open()` and `pread` through a file-backed `BlockReader`. If the CLI agent's file reader is merged by then, reuse it.
  - UDIF `.dmg` and sparse images are attached **read-only and unmounted** (`hdiutil attach -readonly -nomount -noverify -noautofsck`). The resulting `/dev/diskN` is scanned like any device and detached when the session closes.
- **Device list:** the opened image appears in a "Disk images" section with its file name and size. Remove it with a context menu.
- **Recovery safety:** the destination check refuses a destination on the drive that holds the image file, using `DestinationSafety` on the image's host volume.
- **Tests:**
  - raw-image scan;
  - `.dmg` attach / scan / detach, verifying nothing stays attached;
  - refusing a destination on the image's host volume;
  - a UI test that opens an image through the DEBUG fixture.

## B. Save and reopen a scan (owns new `Salvage/ViewModels/ScanArchive.swift`, `Salvage/Views/ScanArchiveCommands.swift`; minimal additive edits to `ScanViewModel.swift` (export/import entry points only) and `ResultsDashboardView.swift` (a "Save Scan…" button))

**Problem:** rescanning a 2 TB drive to finish recovery takes hours.

**Approach:**
- **File → Save Scan…** writes a `.salvagescan` package: JSON metadata plus a compact binary file list. It contains every `RecoveredFile`, including content runs, notices, lost partitions, the device identity (media identity, size and model) and the extent fingerprint.
- **Open Scan…** restores the results view with no source session.
- **Reconnecting the source:** Preview and Recover become available once the same device or image is attached again, matched by media identity, size and extent fingerprint. Until then, show "Reconnect <device name> to preview or recover these files." Never read from a device that doesn't match.
- **Privacy:** the file lists file names and paths, so warn once, plainly ("This file lists the names of the files Salvage found.") and save only where the user chooses. No credentials or decryption keys are ever saved. Encrypted volumes' files need the password again after reopening.
- **Format:** versioned. Reject unknown versions plainly.
- **Tests:**
  - round-trip of 100k files;
  - mismatched device refused;
  - no key material in the archive (grep the bytes);
  - version rejection;
  - a UI test for save → open → reconnect.

## C. File details and "why this confidence" (owns new `Salvage/Views/FileDetailsView.swift`, `Salvage/ViewModels/FileDetails.swift`; a minimal edit to `FileBrowserView.swift` (Show Details action, ⌘I) and `FilePreviewView.swift` (a "Details" disclosure))

**Problem:** the product promises verifiable trust, but a confidence label alone doesn't explain itself.

**Approach:**
- A details panel for the selected file:
  - original path, size, modified date;
  - status: live, deleted, or reconstructed, and partial if so;
  - filesystem and volume (name and offset);
  - recovery method;
  - the AD-7 evidence: fragment count and overwrite estimate, explained in words;
  - where its bytes are (each run's device offset and length; holes shown; encrypted runs marked);
  - for reconstructed files, the signature that matched and how its end was found (validated, size field, footer, cut short).
- **One plain sentence explaining the confidence,** produced by a single pure function in Core next to `RecoveryConfidence`, so the UI never re-derives it (AD-7). Examples: "High: found through the filesystem's own records; its data is in one piece and wasn't overwritten." and "Low: reconstructed from raw data, and the end of the file couldn't be confirmed."
- **Copy Details** copies the details as text.
- **Tests:** the explanation function for every method/evidence combination, the details model, and a UI test.

## D. Recovery report (owns `Salvage/ViewModels/RecoveryReport.swift`, plus additive edits to `RecoveryCoordinator.swift` (report emission) and `RecoverySheet.swift` (one toggle and a "Show Report" button))

**Problem:** after recovering thousands of files, users need a record of what came back, from where, and whether it was complete.

**Approach:**
- Each recovery writes `Salvage Recovery Report.csv` and `.json` into the recovery root folder. A toggle "Save a report with the recovered files" is on by default.
- One row per selected file:
  - original path and recovered relative path;
  - size and SHA-256 of the written bytes;
  - status: recovered, failed with reason, or not attempted;
  - confidence and method;
  - deleted / reconstructed / partial;
  - source device, volume and record offset.
- A header with the app version, date, source device name and model, and totals.
- **Privacy:** the report lives only in the user's chosen destination folder, next to the files.
- **Constraints:**
  - Escape CSV properly, including formula injection: prefix values starting with `=` `+` `-` `@` with an apostrophe.
  - Write the report with the same no-overwrite and containment rules as the files.
- **Tests:** CSV escaping, including hostile names; JSON validity; the report matches the summary counts; no-overwrite.

## E. App icon and branding (owns `Salvage/Assets.xcassets/**` (new), `project.yml` (the asset catalog and `ASSETCATALOG_COMPILER_APPICON_NAME` lines only), `docs/brand/` (new))

**Approach:**
- Design an original app icon matching `DESIGN.md`: a restrained native-utility look, with the single muted teal accent (`#2E6E6E` / `#5FA3A3`) and no SaaS gloss. A suggested motif is a drive or platter with a recovery arrow, or a lifebuoy. Avoid any resemblance to Apple's Disk Utility icon or competitors' marks.
- Produce it as SVG in `docs/brand/icon.svg`, rendered to all macOS AppIcon sizes (16 to 1024 at @1x and @2x) with a reproducible script (`scripts/render-icon.sh`). Use only system tools: `qlmanage`/`sips`, or a small Swift CoreGraphics renderer. No downloads.
- Wire up `AppIcon` in the asset catalog. Verify the built app's `Info.plist` and `Assets.car` contain it.
- Add a monochrome menu/template variant only if used.
- Send the rendered 1024px PNG for review: put it at `docs/brand/icon-1024.png`.

</frozen-after-approval>

## Verification

- `swift test --package-path SalvageCore`
- `swift test --package-path SalvageDiskIO`
- `./scripts/check-core-boundary.sh && ./scripts/check-no-network.sh && ./scripts/check-xcodeproj-sync.sh`
- `xcodebuild -project Salvage.xcodeproj -scheme Salvage -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:SalvageTests test`
- `xcodebuild -project Salvage.xcodeproj -scheme Salvage -configuration Release -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build`
- UI tests for your item: `xcodebuild … CODE_SIGN_IDENTITY="-" test -only-testing:SalvageUITests/<YourTestClass>`. Report results honestly, including focus-stealing interference from other apps.

## Implementation Notes — E

**Design.** A disk platter that is also a lifebuoy: a white ring with faint concentric tracks and a spindle hub reads as a platter, and four teal bands on the diagonals turn the same ring into a lifebuoy (rescue, the app's name). It sits on a graphite tile on the standard macOS grid (1024 canvas, 824 tile, radius 185) with a soft drop shadow and a faint rim light. Teal (`#2E6E6E`, lightening to `#438A89` at the top of each band) is the only chromatic colour, as in `DESIGN.md`. The graphite tile follows the Console/Terminal family of system utilities rather than a coloured SaaS tile. There is no arrow, text or gloss. I chose the graphite tile over a teal one after rendering both: on teal, the accent fights the tile for attention, and the bands lose contrast at 16 px. At 16 and 32 px the icon reads as a white ring with four teal quarters, which is distinct and legible. I did not hand-tune separate small sizes. The design avoids Disk Utility's drive and stethoscope and Time Machine's clock and arrow. Lifebuoy glyphs are common as "help" symbols, so before release a human should check the mark against competitors' current marks.

**Files.**
- `docs/brand/icon.svg` is the master artwork, written by hand with shapes only. It uses no filters, because the system SVG renderer ignores them, so the shadows are layered fills.
- `scripts/render-icon.sh` and `scripts/render-icon.swift` render the SVG through AppKit's built-in SVG support (CoreSVG) into an sRGB CoreGraphics context. The script writes the 10 AppIcon PNGs (16 to 512 pt, @1x and @2x) and `docs/brand/icon-1024.png`. Output is deterministic: re-running it on the same SVG gives byte-identical PNGs, which I verified. It also fails if a render comes out empty.
- `Salvage/Assets.xcassets` holds the `AppIcon.appiconset` with a committed `Contents.json`.
- `project.yml` adds `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon`. No separate catalog line is needed because the `Salvage` source path already picks the catalog up. `Salvage.xcodeproj` is regenerated.
- `SalvageTests/AppIconTests.swift` is new. It covers the Info.plist keys, the `.icns` fallback and the 1024 px rendition from the asset catalog. I added this file under the global "every feature gets unit tests" rule; it is outside E's listed files.

**No template variant.** The app has no menu-bar extra, so no monochrome or template icon is used, and none was added.

**Built-app check.** In the Release build, `Info.plist` has `CFBundleIconFile = AppIcon` and `CFBundleIconName = AppIcon`. `Resources/` contains `AppIcon.icns` and `Assets.car`. `assetutil --info` lists all 10 `AppIcon` renditions, 16 to 1024 px. actool puts only the 16 to 128 pt sizes into the `.icns` and keeps the larger ones in `Assets.car`, which is normal.

**Verification.**
- `swift test` passed for SalvageCore (406 tests) and SalvageDiskIO (168 tests).
- `check-core-boundary`, `check-no-network` and `check-xcodeproj-sync` all passed.
- The Debug `SalvageTests` run passed (180 tests, including the 3 new ones).
- The Release build succeeded.
- No UI test was added, because the icon has no in-app UI.
- The first SalvageCore run had one failure while a Release build was running in parallel. An isolated rerun passed, so it looks like a timing-sensitive test under load and is not related to this change, which touches no Swift package code.

## Implementation Notes — C

**Explanation (AD-7).** `SalvageCore/Sources/SalvageCore/Confidence/ConfidenceExplanation.swift` is the one pure function, `ConfidenceExplanation.sentence(method:evidence:isDeleted:isPartial:)`, and `RecoveredFile.confidenceExplanation` calls it with the file's own `recoveryEvidence`. The level always comes from `RecoveryConfidence.assess`. The reasons a carved file isn't rated higher also come from `assess`: the function asks it again with one piece of evidence improved (treated as one piece, or with a 0 overwrite estimate), and a change that raises the level marks that evidence as a reason. When neither change raises it alone, both are reasons. "Can't be rated higher" appears only when the level equals what `assess` gives the best possible carved evidence. No threshold is copied from `assess`, so retuning it changes the sentences with it. `RecoveryConfidence.swift` is unchanged.

**Truth rules.** The sentence claims only what the reported evidence says:
- "In one piece" appears only when the fragment count is 1.
- A deleted file is never called intact. With a 0 estimate it gets "nothing suggests it was overwritten". The user guide explains why: the scan lists a deleted file only when its space isn't claimed.
- A live file gets no claim about overwriting at all.
- A percentage appears only for an estimate strictly between 0 and 1. Exactly 1 is "almost certainly overwritten". NaN, infinite, negative or above-1 values are "no usable estimate".
- "Its end was confirmed" appears only for a file that isn't partial. A partial file always says its end couldn't be confirmed or that it may be incomplete.
- An unmapped file, or one whose mapping doesn't cover its size, says why it can't be recovered.

**Samples.**
- "High: found through the filesystem's own records; its data is in one piece."
- "High: found through the filesystem's own records of this deleted file; its data is in one piece and nothing suggests it was overwritten."
- "High: found through the filesystem's own records; its data is in 3 pieces, all mapped by the filesystem."
- "Medium: reconstructed from raw data, not found through the filesystem's records, so it can't be rated higher; its data is in one piece and its end was confirmed."
- "Low: reconstructed from raw data, and the end of the file couldn't be confirmed." (the carver's 0.6 cut)
- "Low: reconstructed from raw data; the end of the file couldn't be confirmed and part of it was almost certainly overwritten." (the carver's 1.0 cut)
- "Low: reconstructed from raw data, and its data is in 2 pieces that Salvage joined itself, with no filesystem record of how they fit; its end was confirmed." (a reassembled JPEG)
- "Low: reconstructed from raw data, and Salvage has no usable estimate of whether it was overwritten."
- "Can't be recovered: Salvage couldn't locate this file's contents on the device."

The spec's sample High sentence ended "and wasn't overwritten". I didn't use that wording, because nothing proves it for a deleted file, and for a live file it says nothing.

**Details model.** `Salvage/ViewModels/FileDetails.swift` builds the panel's sections, run list and Copy Details text from a `RecoveredFile`, plus the session's `BlockDevice` when there is one (for the partition name).
- **Volume name.** It is the APFS `volumeName`, else the device-tree partition at the volume's offset (`PartitionGrouping`), else "Unnamed volume". The preview disclosure and the sheet both pass `source?.device`.
- **Offsets.** Shown as decimal with the hex value in brackets.
- **Runs.** Listed with their file offsets. Holes say they read as zeros, and placed runs in `.encryptedRuns` are marked encrypted. Resident data and unmapped files get one line instead.
- **Copy Details limits.** Copy Details lists up to 10,000 runs and says how many it left out. The sheet draws 500, and the preview disclosure draws 5.

**Reconstruction facts are derived, not recorded.** `RecoveredFile` doesn't carry the carve's signature or how its end was found, and adding them would mean editing `ScanEvent.swift` and `CarvingEngine.swift`, which §C doesn't own. They are derived instead:
- **Signature.** Parsed from the engine's name format `<id>-<12 hex>[-n].<ext>` and looked up in `SignatureLibrary.bundled`. When two signatures share an id (the two `mp3` files), the one whose header matches the kept `rawRecord` bytes wins. An unrecognised name shows "Not identified".
- **End found, not partial.** Taken from the matched signature's end rule: a size field, else a footer (this covers JPEG's segment walk to EOI), else "Validated" for a segment walk or structure walker. This follows `makeCarve`'s precedence.
- **End found, partial.** "Cut short". The engine's documented overwrite values add the likely cause: 0.6 for a limit, the next header, the end of the extent or an untrusted size, and 1.0 for a claimed run or an inconsistent structure. Any other value gets the generic line.
- **Risk.** If the engine's naming or values change, these lines fall back to the generic wording. They never fall back to a wrong specific one.
- **Better long-term fix.** An explicit `endRule` field on `RecoveredFile`, which would also suit B's archive.

**Views.**
- `Salvage/Views/FileDetailsView.swift` holds the panel and the `FileDetailsSheet` (Copy Details, Done).
- `FileBrowserView.swift` gets 6 added lines: the state, the sheet, and a **Show Details** button with ⌘I that is disabled with no focused row.
- `FilePreviewView.swift` gets 2 added lines: the state, and a **Details** `DisclosureGroup` whose content sits in a 160 to 240 pt scroll view. Its label is a plain button that toggles it, because on macOS clicking a `DisclosureGroup`'s label does nothing, and the UI test confirmed that clicks on the triangle didn't toggle it either.
- No existing line was changed, and no accessibility modifiers were touched.

**Tests.**
- `SalvageCore/Tests/SalvageCoreTests/ConfidenceExplanationTests.swift` has 15 tests. They cover exact sentences for every case scans produce, plus a grid over both methods, fragments {0, 1, 2, 5}, 12 overwrite values (including NaN, infinity, negative and above 1), deleted and partial. The grid checks each sentence against its evidence, and checks that the prefix is `assess`'s level.
- `SalvageTests/FileDetailsTests.swift` has 11 tests for the details model and copy text.
- `SalvageUITests/FileDetailsUITests.swift` covers ⌘I, the sentence, the fields, Done, and the preview disclosure. It deliberately doesn't press Copy Details, because that would overwrite the user's clipboard. The copy text is unit-tested instead.
- The test files and the `docs/USER-GUIDE.md` section are outside the listed files, under the global rules. `Salvage.xcodeproj` is regenerated for the new files.

**Verification.**
- `swift test` passed for SalvageCore (425 tests, 15 of them new) and SalvageDiskIO (168 tests).
- `check-core-boundary`, `check-no-network` and `check-xcodeproj-sync` all passed.
- The Debug `SalvageTests` run passed (191 tests, 11 of them new).
- The Release build succeeded.
- **UI test.** `SalvageUITests/FileDetailsUITests` passed on the last run (1 test, 16.9 s), after earlier runs failed.
  - **Interference.** Other agents ran UI tests for the same bundle ID (`dev.hsmith.Salvage`) at the same time, with load averages near 50. In those runs XCUITest reported other Salvage windows as interrupting elements. Clicks took up to 19 s to synthesize, one runner restarted after a timeout, and one scan didn't finish within 90 s.
  - **Real bug found.** Three consecutive failures at the preview step were not interference: clicking the disclosure didn't open it. That was fixed with the button label described above.
  - **Passing run.** The passing run waited until no other Salvage or UI-test runner process was alive. It still reported one interrupting Salvage window at the start.
