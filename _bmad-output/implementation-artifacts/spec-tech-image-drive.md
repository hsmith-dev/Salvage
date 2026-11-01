---
title: 'Image This Drive (byte-for-byte copy into a .img file)'
type: 'feature'
created: '2026-11-01'
status: 'done'
baseline_commit: '3333c88'
context:
  - '{project-root}/_bmad-output/implementation-artifacts/spec-1-12-read-physical-drives-via-a-read-only-privileged-helper.md'
  - '{project-root}/_bmad-output/implementation-artifacts/spec-tech-batch-7.md'
  - '{project-root}/_bmad-output/planning-artifacts/ux-designs/ux-DataRecoveryTool-2026-10-31/DESIGN.md'
---

## Intent

Recovery best practice for a failing drive is to read it once into an image and scan the image
as often as needed. Until now that took `sudo dd` in Terminal. **Image This Drive…** does it in the
app: a byte-for-byte copy of a whole drive into a new `.img` file on a different drive. The app
already opens raw images (File > Open Disk Image…), so the result can be scanned right away.

## Design

**Entry points.** The drive row's context menu in the sidebar, **File > Image This Drive…** (the
window's current drive: the one last selected or scanned), and an **Image This Drive…** button
beside **Save Scan…** on the results dashboard. All three call `DriveImagingCenter.begin`, one per
window, presented as a sheet by `ContentView`. Not offered for the boot drive or an opened image
file, nor while that drive is being scanned.

**Source.** Opened only through `RawBlockReader.prepare(device:)` (boot-disk refusal, unmount,
read-only descriptor validation, the privileged helper and its fallbacks). When the window's
finished scan session is of the same drive (same id and media identity) it already holds the
drive's read reservation, so its reader is reused through `SessionImagingReader`, which refuses to
read once that session closes (so a closed session ends the copy instead of reading as bad blocks).
Nothing is ever written to the source: `BlockReader` has no write operation.

**Destination.** `NSSavePanel`, `.img`. Its own replace prompt is the only way an existing file is
replaced; a name to which `.img` had to be appended is never treated as confirmed. Before the drive
is opened:

- `DestinationSafety.live.assess(folder, drive)` must be `.safe`. `.sameDevice` shows the red
  destination-blocked banner (DESIGN.md's one blocking state); `.undetermined` is refused too.
- A FAT ("msdos") destination is refused for a drive over 4 GiB − 1.
- Free space (`RecoveryCoordinator.availableCapacity`, plus a confirmed file's own size) must be
  at least the drive's size; unknown free space refuses.

`ImageOutputFile` (SalvageDiskIO) then opens the folder (`O_DIRECTORY`), checks with `fstatfs` that
it is the volume that was assessed, removes a confirmed existing *regular file* only, and creates
the image with `O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW`; the descriptor must be a regular file.
Writes are `pwrite` in order; the end is `F_FULLFSYNC` (falling back to `fsync`).

**Copy loop.** `DriveImager` (SalvageDiskIO), against any `BlockReader` and `ImageSink`:

- 4 MiB chunks (the raw reader's limit). A chunk failing with `ScanError.io` is re-read as 64 KiB
  pieces, failed pieces as 4 KiB, then 512-byte blocks. A range where no piece reads is marked
  unreadable as a whole without descending further: a single bad sector costs about 89 reads, a
  fully dead 4 MiB chunk 65.
- Unreadable bytes are written as zeros and recorded as merged `ImagingBadRange`s.
- Any other error (device removed, permission, a closed session) ends the copy (`.stopped`), and
  so does a write failure.
- **Timeout.** `pread(2)` on a raw device can't be interrupted, so each read runs in its own task
  raced against a timer (`TimedRead`, default 120 s). On timeout the copy stops with "The drive
  stopped responding…"; the stuck read is abandoned, not killed. Copying doesn't continue past it
  because later reads of the same reader actor would queue behind the stuck one.
- Cancellation (Task cancel) stops after the current read; the image keeps the prefix written.
- SHA-256 of the image (zeros included) is computed while copying; reported only when complete.
- Progress is reported at most every 100 ms; the model derives speed (5 s window) and ETA.

**Sidecar.** `<name>.img.badblocks.json` (`ImagingReport`, JSON, ISO-8601 dates): status
(complete / cancelled / stopped), a plain-language note, bytes copied, unreadable bytes, bad
ranges (byte offsets on the drive), SHA-256, source name and BSD name, block size, start and end.
Metadata only. Written for every run that created the image file, including cancel and stop.

**Summary.** Title (Image complete / Imaging canceled / Imaging stopped), the note (for an
incomplete copy: "The image file holds only the first X of Y…"), the image path, bytes copied and
time, unreadable areas (the first 20 listed, the rest in the sidecar), the SHA-256, and **Show in
Finder**, **Done** and **Open Image** (`DiskImageLibrary.shared.open`, the existing open-image path).

## Files

- `SalvageDiskIO/Sources/SalvageDiskIO/DriveImager.swift`: copy loop, retry splitting, `TimedRead`.
- `SalvageDiskIO/Sources/SalvageDiskIO/ImageOutputFile.swift`: output file, sidecar, `ImagingReport`.
- `Salvage/ViewModels/DriveImaging.swift`: `DriveImagingModel`, environment, summary, formatting.
- `Salvage/Views/ImageDriveSheet.swift`: center, sheet, dashboard button, menu command.
- Small edits: `ContentView` (sheet, environment, focused value), `DeviceListView` (context menu),
  `ResultsDashboardView` (one button), `SalvageApp` (command), `RecoverySheet`
  (`DestinationBlockBanner` takes a message), `SourceSession` (`isClosed`).

## Tests

- `SalvageDiskIOTests/DriveImagerTests.swift`: clean copy and hash, short last chunk, bad blocks
  zeroed and merged with neighbours intact, a solid bad chunk in 65 reads, a hung read stopping
  within the timeout, cancel keeping the prefix, device removal not counted as bad, write failure,
  progress; output file: new-file creation, sidecar round trip, existing file refused unless
  confirmed, symlink never followed, unsafe or mismatched assessment refused, FAT limit.
- `SalvageDiskIOTests/LiveDriveImagingTests.swift`: a random raw file attached with
  `hdiutil attach -nomount -readonly`, checked by `hdiutil info` to be that file before it is opened
  and before it is detached, opened through `RawBlockReader.prepare`, imaged and compared byte for
  byte. Skipped with `SALVAGE_SKIP_HDIUTIL=1`.
- `SalvageTests/DriveImagingTests.swift`: the model end to end with an in-memory drive into a temp
  folder: blocked and undetermined destinations, free space and FAT refusals (drive never opened),
  bad sectors and sidecar, cancel and sidecar, replace only when confirmed, drive in use, a closed
  scan session, eligibility, formatting.

## Not verified

- No real failing drive was imaged; the timeout and retry behavior on real bad sectors (how long
  macOS's own retries take, whether EIO arrives as `ScanError.io`) is tested only with fakes.
- The sheet, context menu, menu command and dashboard button weren't exercised by hand or by UI
  tests (UI tests weren't run); the UI test target builds.
- A physical drive through the privileged helper wasn't imaged (no signed helper here).
