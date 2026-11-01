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
- Free space (`volumeAvailableCapacity`, falling back to `statfs`; not the "important usage"
  figure, which counts purgeable space macOS may not free in time) must be at least the drive's
  size. A file being replaced isn't counted as freed. Unknown free space refuses.
- Protected files: every attached disk image's backing file (`hdiutil info -plist`, by
  `(st_dev, st_ino)`; one of them may be the drive being imaged) and every image open in Salvage
  are never replaced, whether or not replacing was confirmed. When that list can't be read, no
  existing file is replaced.

`ImageOutputFile` (SalvageDiskIO) then opens the folder (`O_DIRECTORY`), checks with `fstatfs` that
it is the volume that was assessed, removes a confirmed, unprotected existing *regular file* only
(the `.badblocks.json` too, only when replacing was confirmed), and creates
the image with `O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW`; the descriptor must be a regular file.
Writes are `pwrite` in order (a 0-byte write fails). Every image, partial ones too, ends with
`F_FULLFSYNC`, falling back to `fsync` only on ENOTSUP/EINVAL; any other failure is reported. The
sidecar's flush and close results are checked.

**Copy loop.** `DriveImager` (SalvageDiskIO), against any `BlockReader` and `ImageSink`:

- 4 MiB chunks (the raw reader's limit). A chunk failing with `ScanError.io` is re-read as 64 KiB
  pieces, and every failed piece is split again, depth first, as 4 KiB and then 512-byte reads.
  A single bad sector costs 89 reads.
- Bounded cost: the run of consecutive unreadable bytes since the last good read. Past 32 KiB a
  failed piece isn't split any more (a failed chunk is still split once into 64 KiB pieces, so
  good data after a bad area is found again); a good read ends the run. A fully dead first chunk
  costs 145 reads, each later one 65.
- Past 64 MiB of consecutive unreadable bytes the copy stops ("The drive stopped returning
  data…") after re-checking that the device is still present (IORegistry media identity), rather
  than "completing" an image of a drive that returns only errors.
- A 0-byte read ("Short raw-device read.") counts as unreadable only while the device is still
  present; a read from a closed session always stops the copy.
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

**Closing the source.** After a timeout or a cancel a read may still be stuck in the kernel, and
`RawBlockReader.close()` would queue behind it on the reader's actor. So only a completed copy
awaits the close; otherwise the sidecar is written, the summary shown, and the close runs detached
whenever the stuck read returns.

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

Review follow-up tests: scattered bad sectors split to single sectors, a drive returning only
errors stopping (with the presence re-check and the read budget), 0-byte reads with the drive
present or gone, a closed session; protected backing files (also a hard link, and live against
the attached test image), an unknown protected list, stale sidecars; and in the app an actor
reader whose read blocks its thread synchronously, like `pread`: after a timeout and after a cancel
the run finishes and writes its sidecar while the close still waits, and the close happens once
the read returns.

## Not verified

- No real failing drive was imaged; the timeout and retry behavior on real bad sectors (how long
  macOS's own retries take, whether EIO arrives as `ScanError.io`) is tested only with fakes.
- The sheet, context menu, menu command and dashboard button weren't exercised by hand or by UI
  tests (UI tests weren't run); the UI test target builds.
- A physical drive through the privileged helper wasn't imaged (no signed helper here).
