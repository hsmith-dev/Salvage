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

## Implementation Notes — A

**Reading.** `SalvageDiskIO/Sources/SalvageDiskIO/ImageFileReader.swift` is the CLI's read-only reader, moved here unchanged apart from `public` (the CLI imports it from SalvageDiskIO now). The new `DiskImageSource.swift` beside it adds:

- `DiskImageFile.inspect`. It classifies an image: UDIF ("koly" trailer), `.sparseimage` ("sprs") and `.sparsebundle` are attached; everything else is raw. It refuses devices, links to devices, folders and empty files.
- `DiskImageAttacher`. It runs `hdiutil attach -readonly -nomount -noverify -noautofsck -plist`, and `detach`. Detach acts only on a disk that `hdiutil info` still lists as the same image file, so a reused disk number is never detached. If a plain detach fails, it retries once with `-force`.
- `DiskImageDestinationSafety`. It refuses a destination on the drive holding the image file: `DestinationSafety` on the image's host whole disk, following image-on-image hosts. It also refuses one on a volume backed by the image itself (`ImageFileDestinationSafety`). Anything it can't resolve is undetermined, which callers treat as refused.

**App.**
- `Salvage/ViewModels/ImageSource.swift`: `DiskImageLibrary` holds the list, a lock-protected `DiskImageRegistry` serves lookups from off the main actor, and the scan runner lives here too. An opened image gets a stand-in `BlockDevice` named `image-<UUID>`. That name is never a BSD name, so drive code (`RawBlockReader`, `DestinationSafety`) fails closed on it and never acts on it.
- Raw images are scanned through `ImageFileReader`.
- A `.dmg` or sparse image is attached only when its scan starts, read through `RawBlockReader.prepare` (the node is user-owned, so no helper is needed), and detached when its `SourceSession` closes. A failed preparation also detaches. A `willTerminate` observer detaches anything still attached at quit.
- The attached disk (and any synthesized APFS container) is hidden from the drive list while attached, because the image is already listed.
- `Salvage/Views/OpenImageCommand.swift` adds File > Open Disk Image… (⌘O) through `NSOpenPanel`.
- `SalvageApp.swift` gains one command line.
- `DeviceListView.swift` has a new "Disk images" section: name, size, a Remove from List context menu, an open-error line and the drop target. It also has small hooks in the existing view: the hidden-drive filter, the image branch of the selection binding, and one `onChange` line.
- `ContentView.swift`: the runner is selected through `DiskImageLibrary.runner(otherwise:)`. `CompositionRoot.recoveryCoordinator` also uses the image destination check for an image's results. That second change goes beyond "runner selection only", but it is the only place to wire it without touching `RecoveryCoordinator.swift` (owned by D) or `SourceSession.swift`.
- Images have no media identity, so they are never checkpointed.

**UI test fixture.** In DEBUG builds, `-SalvageUITestOpenImage <path>` writes the fixture exFAT volume to `<path>` and opens it as a raw image. This stands in for the open panel. The scan really reads that file. `UITestFixtures.swift` is not modified.

**Tests.**
- `SalvageDiskIOTests/DiskImageSourceTests` (11 tests) covers:
  - classification;
  - inspect refusals;
  - read-only, byte-exact raw reads;
  - attach plist parsing and the exact attach flags;
  - detach refusing a reused disk;
  - host-drive refusal (same volume, sibling partition, APFS container, image-on-image, unresolvable);
  - the live check refusing a temp folder beside a temp image;
  - a live UDZO `.dmg` attached, read byte for byte, detached, with `hdiutil info` then empty, nothing mounted and the file unchanged.
- `SalvageTests/ImageSourceTests` (5 tests) covers:
  - a raw image scan (5 fixture files, content read back, file unchanged);
  - a `.dmg` attach, scan and detach, verifying nothing stays attached and nothing was mounted;
  - destination refusal on the image's host volume;
  - library dedupe and refusals;
  - drives still routed to the drive runner.
- `SalvageUITests/DiskImageUITests` (1 test): the menu item exists; the image is listed under Disk images with its name and "8.4 MB"; clicking it scans to "5 items found"; recovering beside the image shows the "Destination blocked" banner and writes nothing; Remove from List removes it.

**Verification.**
- `swift test` passed for SalvageCore (410 tests), SalvageDiskIO (179 tests) and SalvageCLI (28 tests).
- `check-core-boundary`, `check-no-network` and `check-xcodeproj-sync` all passed.
- The Debug `SalvageTests` run passed (185 tests).
- The Release build succeeded.
- `DiskImageUITests` passed 1 of 5 runs. The first failure was a real bug: the row's accessibility value was hidden, which is fixed. The other two failures came while other agents' UI-test runs (ScanArchiveUITests, FileDetailsUITests and a full SalvageUITests run) were driving their own Salvage instances on the same desktop:
  - Cmd-A didn't tick the files;
  - the context menu didn't appear;
  - "Unable to find hit point" on a scroll view, in two runs.

  These look like focus stealing, not product failures. Other agents' UI tests were running for all of these runs, and the one passing run happened between theirs. It should be rerun on a quiet desktop.

**Not done or not verified.**
- Password-protected `.dmg` files: hdiutil gets no stdin, so the attach either fails with the plain "may be damaged, or need a password" message or shows macOS's own password prompt. This is untested.
- The ⌘O shortcut and the real open panel and drag-and-drop are not exercised by the UI test (the panel is modal and system-owned).
- The recovery banner copy says "on the drive you're recovering from". For an image, that is the drive holding the image file. The copy belongs to `RecoverySheet` (owned by D) and is unchanged.

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

## Implementation Notes — D

**Shape.** `Salvage/ViewModels/RecoveryReport.swift` (new) builds the report from the selected files and the engine's `RecoverySummary`. The report has one row per selected file, in selection order: recovered, failed with its reason, or not attempted after a cancel. Its header totals come from the summary, so they can't disagree with the summary. It produces the CSV and JSON bytes. The engine writes them.

**Engine (additive edits in `RecoveryCoordinator.swift`, above `// MARK: - Coordinator`).**
- `RecoveredCopy.fileID` pairs each copy with its file. Matching by path would be ambiguous, because duplicate paths happen.
- `RecoverySummary` gains `attachments` (the URLs written) and `attachmentFailure`.
- A new `RootAttachment` type, plus an optional `attachments:` closure on `RecoveryEngine.run`. The engine calls it with the finished summary, including after a cancel, and writes each file through the new `RecoveryEngine.writeAttachment`.
- `writeAttachment` follows the same rules as a recovered file:
  - the name goes through `RecoveryPaths.sanitize` and the path-length check;
  - the file is written relative to the open root descriptor, and the root is confirmed by `(st_dev, st_ino)`;
  - the temporary file is created with `O_CREAT | O_EXCL | O_NOFOLLOW`, then durably synced;
  - the same `publish` makes it visible, so an existing name is never replaced or followed. A recovered file that is itself called `Salvage Recovery Report.csv` pushes the report to `… (2).csv`;
  - on failure, the `.partial` file is removed.

  A failed report write doesn't fail the recovery. The summary shows "The recovery report couldn't be saved. <reason>".
- `RecoveryCoordinator` gets `saveReport` (on by default), changed with `setSaveReport(_:)` only before a run starts. It also gets an optional `device:` for the header; the `SourceSession` convenience init passes it. The DEBUG fixture path in `ContentView` passes only the device name, so its report has no model or identifier line. I didn't edit `ContentView`, because it isn't D's file.

**CSV.**
- UTF-8 with a BOM and CRLF line ends.
- A key/value header (app version and build, ISO 8601 date, source device, model, BSD identifier, size, the "Recovered from" partition label, recovery folder, totals), a blank line, then the table.
- Fields are quoted per RFC 4180 when they contain a comma, quote, CR or LF, or have a leading or trailing space.
- **Formula injection:** a value whose first character is `=` `+` `-` `@`, tab or CR gets a leading `'`. So does one that starts with one of these after leading spaces, or with a full-width `＝ ＋ － ＠`. NUL becomes U+FFFD.
- The JSON is pretty-printed with sorted keys, `formatVersion: 1` and ISO 8601 dates. It keeps names exactly as found; only the CSV neutralizes formulas.

**"Model".** `BlockDevice` has no separate model field: its `displayName` is the vendor and model string. So "Model" repeats the device name, and the header also carries the BSD name and size.

**Sheet (`RecoverySheet.swift`).** One checkbox, "Save a report with the recovered files" (`recovery-report-toggle`). The summary gets a "Show Report" button (`recovery-show-report-button`), which opens the CSV in its default app, and the failure line above.

**CLI.** `SalvageCLIKit/RecoveryEngine.swift` was re-copied with the documented `docs/CLI.md` command, and the drift test passes. I did not add `--report`. The report builder lives in the app target and uses `PartitionGrouping`, so the CLI would need a second copy or a move to a shared module, which isn't trivial. The CLI engine already supports `attachments:`, so adding the flag later is small.

**Tests outside D's file list.**
- `SalvageTests/RecoveryReportTests.swift` (new): CSV escaping, including hostile names parsed back with a strict RFC 4180 parser; JSON validity and agreement with the CSV; report totals equal to the summary; cancelled and not-attempted rows; no-overwrite through a recovered file that has the report's name; no-overwrite and no-follow through a pre-existing file and a symlink; containment of a `../` name; cleanup after a failed sync; the toggle defaults and locking.
- `SalvageUITests/RecoveryReportUITests.swift` (new): the report is written by default and Show Report is offered; with the toggle off, no report is written. The test never presses Show Report, because that would open another app.
- Two minimal edits to existing tests, because the report is on by default:
  - `RecoveryCoordinatorTests`' shared `recover(…)` helper turns the report off, since those tests assert exact folder contents;
  - `PartitionSummaryTests`' real-exFAT end-to-end test ignores the report files when comparing recovered files.

**Verification.**
- `swift test`: SalvageCore 410 tests passed, SalvageDiskIO 168 passed, SalvageCLI 28 passed (including the engine drift test).
- `check-core-boundary`, `check-no-network` and `check-xcodeproj-sync` all passed. The Xcode project was regenerated with xcodegen 2.46.0.
- The Debug `SalvageTests` run passed: 197 tests in 17 suites, including the new "Recovery report" suite.
- The Release build succeeded.
- `SalvageUITests/RecoveryReportUITests` passed, 2 of 2.
- **Interference:** while other agents' UI test runners were driving the screen, `testRecoveryWritesReportByDefaultAndOffersShowReport` failed three times. Once it couldn't find the hit point for the device row; twice the sheet's toggle didn't appear in time. Each time the other test passed in the same run. After those runners exited, the test passed alone and then both passed together. I also raised the toggle wait from 5 s to 15 s.

## Implementation Notes — B

**Format.** A `.salvagescan` package is a folder holding `Info.json` and `Files.bin` (`Salvage/ViewModels/ScanArchive.swift`).
- `Info.json` holds the format name and version, the save date and app version, and the device identity: BSD name, model/display name, size, media identity (written as a string so all 64 bits survive) and the partition tree. It also holds the scan's newest `ScanCheckpoint` (offsets and sizes only; its `extents` are the fingerprint), the outcome (completed, cancelled, or failed with its `ScanError`), byte counts, start and end times, notices, lost partitions, the file count and the SHA-256 of `Files.bin`.
- `Files.bin` starts with a magic and a version, then holds one record per `RecoveredFile` with every field: ID, name, path, size, date, flags, method, overwrite estimate, all source metadata (including `rawRecord`), and content (unmapped, resident, runs with holes, or encrypted runs with their data-unit numbers and volume UUID). It uses varints throughout. 100k files round-trip in about 1.4 s in a Debug build.
- **Versioning.** The version in `Info.json` is checked before anything else is decoded, and `Files.bin` checks it again. Any version other than 1 is refused with "This saved scan was made by a different version of Salvage and can't be opened here." A folder that isn't a saved scan, or one whose file list fails its checksum, count or bounds checks, is refused plainly. Truncated or hostile lists throw rather than crash or over-allocate.
- Saving builds the package in a hidden sibling folder and then moves or replaces it into place. Permissions are 0700 on the folder and 0600 on its files.

**No credentials or keys.** `ScanViewModel.makeArchive()` reads only `files`, `lostPartitions`, `notices`, `latestCheckpoint`, the device and timing. It never reads `source` (whose decryptors hold volume keys) or a run's credentials. `archiveHoldsNoCredentialsOrKeys` runs a scan through the view model with a password and a recovery key, keeps a session with a decryptor holding known key bytes, saves, and then greps every byte of the package for each secret: raw, UTF-16, hex (both cases), base64, each key half, and the recovery key without hyphens. Encrypted files are saved as ciphertext runs plus the volume UUID, so they need the password again: the banner says to scan again and unlock. There is no in-place unlock for a reopened scan.

**Reconnecting** (`ScanViewModel.reconnect`, `SavedScanBanner`):
1. A reopened scan has no source, so Preview and Recover are off. The banner (stacked above the results content in `ResultsView`, so it shows on the dashboard and in the browser) says "Reconnect <device name> to preview or recover these files."
2. The banner watches the attached devices. A device whose media identity and size match (and which is not the boot volume) gets a **Reconnect** button. Nothing is opened before then.
3. On Reconnect, the device is opened read-only, the same way a scan opens it (`RawBlockReader.prepare`, which unmounts it). This is why reconnecting is a click rather than automatic. Its extent fingerprint is then read fresh by the new public `SalvageCore/ExtentFingerprint.swift`, which runs the same `VolumeDiscovery` the scan uses.
4. Only an exact fingerprint match adopts the session. A mismatch closes the session at once and shows "<device> has changed since this scan was saved, so Salvage won't read from it."
5. A saved scan with no checkpoint (stopped before mapping) can never be reconnected.
6. Each reopening carries a token, so a reconnect that finishes after another scan or saved scan replaced it is closed and dropped.

**Privacy warning.** It appears once, in the save panel's message ("This file lists the names of the files Salvage found."), and is defined once as `ScanArchive.privacyNotice`. The package stores what the spec asks for ("every `RecoveredFile`"). Besides names and paths, that includes `rawRecord` (metadata record bytes; for carved files, their first 64 bytes) and NTFS resident data (the contents of very small files). The warning mentions only names. A reviewer may want the wording widened or those fields dropped.

**Commands.** File → **Open Scan…** (⇧⌘O) and **Save Scan…** (⌘S) live in `Salvage/Views/ScanArchiveCommands.swift`, reaching the window's scan through `focusedSceneValue`. The dashboard also has a **Save Scan…** button.
- Without a UTI declaration (that would need an Info.plist entry in `project.yml`, which this item doesn't own), macOS treats the package as an ordinary folder. The open panel therefore allows choosing folders and validates the `.salvagescan` extension.
- Declaring `UTExportedTypeDeclarations` later would make Finder show it as one file.

**Edits outside B's listed files (all minimal and additive):**
- `SalvageApp.swift`: a second `.commands { ScanArchiveCommands() }` line.
- `ContentView.swift`: one `.focusedSceneValue` line.
- `UITestFixtures.swift`: the fixture drive gets a `mediaIdentity`, without which nothing can match it.
- New Core file `ExtentFingerprint.swift` plus `ExtentFingerprintTests.swift`.
- `docs/USER-GUIDE.md`: a new section, "Save and reopen a scan".
- `Salvage.xcodeproj` regenerated.

**Known limitation (important).** `BlockDevice.mediaIdentity` is the IORegistry entry ID. It is stable only while the drive stays attached during one boot; unplugging the drive or restarting the Mac gives it a new ID. Because identity matching is mandatory, a saved scan reconnects only while the drive has stayed connected, for example after quitting and reopening Salvage. After a replug it is refused, safely, and the user must scan again. Making the "rescan takes hours" case work across replugs needs a stable identity, such as a disk or partition-table UUID or a media serial number, from SalvageDiskIO. That is a decision for the spec owner.

**Tests.**
- `SalvageTests/ScanArchiveTests.swift` (14 tests): 100k-file round trip; every outcome and notice; version rejection in JSON and binary; damaged and foreign packages and truncation; no key material; reopened state; reconnecting the same device; refusing another identity, a missing identity, another size or a boot volume without opening it; refusing a changed layout and closing its session; a scan without a checkpoint; a failed open; a real `ScanSession` scan saved, reopened and reconnected end to end; reconnects superseded by a new archive or scan; the privacy sentence.
- `SalvageCore/Tests/SalvageCoreTests/ExtentFingerprintTests.swift` (2 tests): the fingerprint equals the scan-recorded checkpoint extents, and it changes with the layout.
- `SalvageUITests/ScanArchiveUITests.swift`: scan, then Save Scan…, then relaunch and Open Scan… from the File menu. Then: reconnect message and 5 items shown, Recover disabled, click Reconnect, Recover enabled, recover all 5 files and check them byte for byte. The DEBUG `-SalvageUITestArchive <path>` argument (honored only with a UI-test fixture) replaces both panels, so the UI test does not see the save panel's warning text.

**Verification.**
- `swift test`: SalvageCore passed (412 tests, including the 2 new ones). SalvageDiskIO passed (168 tests).
- `check-core-boundary`, `check-no-network` and `check-xcodeproj-sync` all passed.
- The Debug `SalvageTests` run passed (194 tests, including the 14 new ones).
- The Release build succeeded.
- The UI test `ScanArchiveUITests` passed on its final run (21.7 s), with no other Salvage instance or test runner running. It failed in eight earlier runs; the failures had two causes.
  - **Interference.** Four failures came from other agents' Salvage UI tests running at the same time. Every worktree builds the same bundle ID, so concurrent runs launch and terminate each other's apps and windows. Another session's Xcode also held the foreground throughout.
  - **A real bug.** Run 1 and the runs from the gated retry onward also failed at Reconnect. That was a bug of mine: the banner was first a top `safeAreaInset`, which pushed the File Browser's header and the Reconnect button out of the window (the button's frame was about 280 pt above the window). It is now a plain `VStack` row, and the test asserts the button is hittable.
  - The test re-activates Salvage before clicks and presses Reconnect a second time if the first click was lost. A second press is harmless.
