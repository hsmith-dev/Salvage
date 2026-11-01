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
