# Salvage user guide

This guide follows the app from opening it to getting your files back. Text in **bold** or in
quotes is what the app shows, taken from the Swift views in `Salvage/Views/`.

> **Pre-release note.** Nobody has yet tested the app's screens by hand, scanned a real USB drive
> through the administrator-password dialog, or run the signed privileged helper on one. The behavior described here comes from the code
> and its automated tests. See [Not yet verified](../README.md#not-yet-verified).

## Before you start

- **Stop using the drive.** Every new file written to it can overwrite a deleted one. Salvage itself
  never writes to the drive it scans.
- **Have somewhere else to put the files.** Recovered files must go to a folder on a different
  drive from the one you are recovering.

## Install

1. Download `Salvage-vX.Y.Z.zip` from the [GitHub Releases page](https://github.com/hsmith-dev/Salvage/releases).
   Each release has a `.sha256` file next to it. To check the download, run
   `shasum -a 256 -c Salvage-vX.Y.Z.zip.sha256` in the folder you downloaded it to.
2. Unzip it and move **Salvage** to your Applications folder. Release builds are signed with
   Developer ID and notarized by Apple.

If no release is published yet, see [Build from source](../README.md#build-from-source). A build you
make yourself reads drives the same way, after asking for your administrator password.

Salvage needs macOS 14 or later.

## Your administrator password for reading drives

USB drives, memory cards and external hard drives can only be read with an administrator's
permission. You never need Terminal for this. When you scan one, Salvage first shows:

> macOS will ask for an administrator password so Salvage can read this drive. Salvage only reads
> it — it never writes to it.

Then macOS shows its own password dialog. Enter the name and password of an administrator account
on this Mac. Salvage never sees the password: macOS's built-in `authopen` tool checks it, opens
the whole drive **read-only**, and hands only that read-only connection to Salvage. Salvage then
checks again that the connection is read-only and is the drive you picked before it reads
anything. It asks for the password for each scan, and again when you reconnect a saved scan's
drive.

If you click **Cancel** (or leave the dialog unanswered for three minutes), the scan stops and
Salvage shows:

> Salvage needs your administrator password to read this drive. Scanning is read-only.

Click **Try Again** to be asked again.

Your startup drive is refused before any password is asked for, as before.

### Skip the password next time (optional, release builds only)

A signed release of Salvage also includes a small read-only helper. Under **Try Again** it offers
**Skip the password next time**. Click it, then:

1. Click **Open System Settings**. It opens Login Items.
2. Turn on **Salvage** under **Allow in the Background**.

After that, Salvage reads drives without asking for your password. The helper does one thing. It
opens the selected whole drive read-only and hands it to Salvage. It never writes, mounts or
unmounts anything, never touches the network, and keeps no log. It refuses your startup drive.
When it has had no work for 60 seconds it exits, and macOS starts it again when it is next needed
(`SalvageHelper/main.swift`). Builds you make yourself don't offer it; they always use the
password dialog.

Other messages you may see:

- "Salvage's read-only disk access didn't respond. Retry the scan. If it keeps failing, restart
  your Mac and try again." (helper only; Salvage falls back to the password dialog when it can)
- "Allow Salvage in System Settings → Privacy & Security → Full Disk Access, then retry the scan.
  You may need to reopen Salvage." This appears when macOS denies a read after the drive was
  opened. Whether Full Disk Access is ever needed hasn't been tested on real hardware yet.

Disk images you attach yourself are opened directly, without a password.

## Choose a drive

The left column lists every drive. Your startup disk is included, and internal and external drives
appear together in one list. Under each drive its partitions, APFS containers and volumes are
nested, each with its format and size. They start expanded, and you can collapse them.

- **Only whole drives can be selected.** Clicking a drive starts a scan of the whole drive.
  Partition and volume rows are there for information.
- **Your startup drive is grayed out**, with the note "Your boot drive can't be scanned while macOS
  is running from it."
- A drive with a FileVault-encrypted volume shows **Locked** after its size, with a lock icon.
  Selecting it opens the unlock sheet first (see [FileVault volumes](#filevault-volumes)).
- While a scan runs, the other drives can't be selected. The drive being scanned says **In use
  by another scan**.

If Salvage can't see any drives at all, it says "No drives found." and suggests quitting and
reopening Salvage.

## Scan

Before reading, Salvage unmounts the drive so nothing else can change it, then opens it read-only
("Preparing the device for read-only scanning…"). **The drive stays unmounted after the scan.** To
use it in Finder again, disconnect it and plug it back in.

While it scans you see:

- a progress bar and "N% of supported volume bytes read";
- **Elapsed**, **Remaining** (an estimate that appears after a few seconds), and the count of
  files indexed so far;
- the list of files found so far. When the drive has more than one volume, each file shows its
  volume as "Volume 1", "Volume 2", and so on.

Under the list, Salvage says "Files listed here have been indexed from intact metadata. No files
have been copied or recovered." A scan only reads. It doesn't copy anything.

### Pause, resume and cancel

- **Pause** stops reading the drive without ending the scan ("Scan paused. Salvage is not reading
  the device. Resume continues from the same point."). Elapsed time doesn't count while paused.
- **Resume** continues from the same point.
- **Cancel scan** stops scanning and keeps the files already indexed.

### Resuming after an interruption

If you close the window or quit during a scan, Salvage saves where it got to. The next time you
select that drive it says the previous scan "stopped before it finished, at N% of supported volume
bytes", and offers **Resume scan** or **Start over**. Resume rebuilds the file list, then continues
reading from where the scan stopped.

The saved position holds only offsets and sizes, never file names. It is used only for the same
drive, unchanged in size, within the same startup of your Mac, and for at most 7 days. Completing
or cancelling a scan deletes it. If the scan stopped because of an error, it is kept, and **Retry
scan** offers to resume.

## Results

When the scan ends, the dashboard shows the drive's name and "Scan completed — N items found" (or
"Scan cancelled" / "Scan stopped early").

- **By type** has one tile per bucket: **Pictures**, **Videos**, **Audio**, **Documents**,
  **Archives** and **Other**, each with a file count and total size. A tile also notes how many of
  its files were reconstructed, for example "(3 reconstructed)". Click a tile to browse that type.
  The bucket comes from the file's extension.
- **Browse all files** opens everything.
- **Lost partitions** appears when some were found (see [Lost partitions](#lost-partitions)).
- **Can't be recovered** counts files Salvage found but whose contents it couldn't locate on the
  drive. They aren't counted in the tiles.
- **About this scan** lists anything the scan could not do (see below).
- **Show system files** includes macOS housekeeping files such as `._` files, `.DS_Store`,
  `.fseventsd`, `.Spotlight-V100` and `.Trashes`. They are hidden by default.

If nothing recoverable was found, the dashboard says "No recoverable files found on this device."
If only system files were found, it says "Only macOS system files were found. Show system files to
see them."

### About this scan

These notes are calm, factual and never block anything. Each one describes a scan that still ran.
The wording comes from `SalvageCore/Sources/SalvageCore/Entities/ScanNotice.swift`:

- The partition table was damaged, so Salvage ignored it and searched the whole drive for volumes.
- The search for lost partitions covered only the first part of the drive.
- Part of the drive couldn't be read, so some areas were skipped.
- Salvage stopped reconstructing files after its limit (250,000), so some aren't listed.
- Some file-type definitions couldn't be loaded, so those types weren't reconstructed.
- A resumed scan was stopped before it finished reconstructing files from the part it had already
  scanned. (When a resumed scan runs to the end, it goes back over that part, so this only appears
  if it was cancelled first.) Start the scan over to include them.
- A volume's metadata couldn't be read, so some of its files may be missing. The rest of the drive
  was still scanned.
- Damaged files or folders were skipped rather than listed with the wrong contents.

## Browse files

The file browser is a table with **Name**, **Path**, **Size**, **Modified** and **Confidence**
columns. Click a column header to sort. The search field matches names and paths. **All results**
goes back to the dashboard.

Next to a name you may see:

- **Deleted**: the filesystem marks it as deleted.
- **Reconstructed**: found by its contents, not by the filesystem (see
  [Reconstructed files](#reconstructed-files)).
- **Partial — may be incomplete**: a reconstructed file whose end wasn't found.

When reconstructed files are present, the table has two sections: **From the filesystem** and
**Reconstructed**.

### Confidence labels

Each file has a recovery confidence label. The labels differ in size and weight as well as color,
so you can tell them apart without relying on color. All scoring happens in one function,
`RecoveryConfidence.assess` in `SalvageCore/Sources/SalvageCore/Confidence/RecoveryConfidence.swift`.

| Label | Meaning |
| --- | --- |
| **High** | Found through the filesystem's own records, which say where its contents are. Deleted files count too. Their records still point at their contents, and the scan lists a deleted file only when that space isn't claimed by something else. |
| **Medium** | Reconstructed from raw bytes, in one piece, and its end was confirmed by the file's own structure. |
| **Low** | Reconstructed, but partial, cut short, or possibly overwritten. |
| **Can't be recovered** | Found, but its contents couldn't be located on the drive. It can't be previewed or recovered. |

A reconstructed file is never rated High.

## Preview

Select a file and the preview pane on the right shows it. **Hide Preview** / **Show Preview**
toggles the pane, and Space brings back a hidden one. The preview is built in memory from the
drive's bytes. Nothing is written to disk, and links in a PDF are never opened.

- **Images** (PNG, JPEG, GIF, TIFF, BMP, WebP, HEIC and others ImageIO can read) up to 32 MB, shown
  at most 2048 pixels on the long side.
- **PDFs** up to 32 MB.
- **Text** files. Only the first 1 MB is shown, with the note "Showing the first 1 MB."
- Anything else shows **No preview available** with a reason. Where possible it also offers
  **Show raw bytes**, a hex view of the first 4 KB.

Under the preview are the file's name, size, modified date, path and confidence. A reconstructed
file adds "Reconstructed from raw bytes by its file signature. No original name, folder or date
is available."

## File details and "why this confidence"

Select a file and press **⌘I**, or click **Show Details** in the file browser, to see everything
Salvage knows about it. The preview pane also has a **Details** disclosure with the same
information and the first few runs.

The panel starts with the confidence label and one sentence explaining it, for example:

- "High: found through the filesystem's own records; its data is in one piece."
- "Medium: reconstructed from raw data, not found through the filesystem's records, so it can't
  be rated higher; its data is in one piece and its end was confirmed."
- "Low: reconstructed from raw data, and the end of the file couldn't be confirmed."

The sentence comes from the same evidence the label is scored from, so the two always agree.
Below it are:

- **File**: the original path, size, modified date and status: live, deleted or reconstructed,
  and whether it's partial.
- **Source**: the filesystem, the volume (its name and where it starts on the drive) and how the
  file was found.
- **Evidence**: how many pieces its data is in, and Salvage's estimate of whether it was
  overwritten.
- **Reconstruction** (reconstructed files only): the file signature that matched, where its
  header is, and how its end was found: by a size field in its header, by its end marker
  (footer), by checking its internal structure, or cut short.
- **Where its bytes are**: each run's position on the drive and length. Holes, which read as
  zeros, and encrypted runs are marked. Positions are in bytes, with the hex value in brackets.

**Copy Details** copies all of this as plain text. It includes up to 10,000 runs; the panel shows
up to 500.

## Recover

1. **Tick the files you want.** Use the checkbox in each row, or the keyboard:
   - **Return** or **⌘K** ticks or unticks the selected rows;
   - **⌘A** (while the table has focus) ticks every recoverable file;
   - **⌥⌘A** unticks everything.
   The **Select** menu has the same commands. Files that can't be recovered can't be ticked. Ticked
   files hidden by the current filter or search aren't recovered, and the count says so, for
   example "5 selected (2 hidden)".
2. Click **Recover (N selected)**.
3. Click **Choose…** and pick a folder on a **different drive** from the one you're recovering.
   - If the folder is on the same drive, a red banner says "This folder is on the drive you're
     recovering from. Choose a folder on a different drive." and **Recover** stays disabled. The
     same happens when Salvage can't tell which drive the folder is on.
4. Click **Recover**.

Salvage creates a new folder inside the one you picked, named `Salvage Recovery <drive name>
<yyyy-MM-dd HH.mm.ss>`. Files keep their original folder structure, and their modified date is
restored when it is known. A name that's already taken gets " (2)", " (3)" and so on. Existing files
are never overwritten. Each file is written under a temporary `.partial` name and renamed once it
is complete and flushed to disk.

When the copy finishes, the summary says how many files were recovered and how many bytes were
written. It lists any files that couldn't be recovered, with the reason. **Show in Finder** opens
the folder. If you cancel partway, the summary also counts the files that weren't attempted.

## Recovery report

Each recovery also saves a record of what came back: `Salvage Recovery Report.csv` and
`Salvage Recovery Report.json`, inside the new recovery folder, next to the files. To skip it,
untick **Save a report with the recovered files** before you click **Recover**. It's on by default.

- The report starts with the Salvage version, the date, the drive you recovered from and the
  totals: files selected, recovered, failed and not attempted, and bytes written.
- Then there's one row for every file you selected, including any that couldn't be recovered or
  that weren't attempted because you cancelled. Each row has the file's original path, where it
  was saved inside the recovery folder, its size, and the SHA-256 checksum of the bytes written.
  It also has the confidence, how the file was found, whether it was deleted, reconstructed or
  possibly incomplete, and where it was on the drive (filesystem, volume and record offset).
- **Show Report** in the summary opens the CSV file. Spreadsheet apps open it directly.
- If one of your recovered files is already called `Salvage Recovery Report.csv`, the report is
  saved as `Salvage Recovery Report (2).csv` instead. Like recovered files, the report never
  overwrites anything.
- In the CSV, a value that starts with `=`, `+`, `-` or `@` gets a leading apostrophe, so a
  spreadsheet shows a file name like `=SUM(A1).txt` as text and never runs it as a formula. The
  JSON file keeps names exactly as they are.
- The report lists the names and paths of your files. It's saved only in the folder you chose and
  goes nowhere else.

## FileVault volumes

Salvage can read a software-encrypted (FileVault) APFS volume. It decrypts the volume itself,
from the drive's raw bytes, without mounting it and without `diskutil`.

The unlock sheet, **Unlock "<volume name>"**, appears:

- before the scan, when the drive list already knows the drive is locked; or
- after a scan that found encrypted volumes, once per volume.

Choose **Password** or **Recovery Key**, type it, and click **Unlock**. The sheet can say:

- "Wrong password." or "Wrong recovery key." The sheet stays open so you can try again.
- "Couldn't unlock this volume — try again or use your recovery key."
- "This volume's encryption is tied to the Mac it came from, so Salvage can't unlock it on this
  Mac. The rest of the drive can still be scanned." This is hardware-bound encryption.
- "Salvage unlocked this volume but its file list is damaged, so its files can't be listed. The
  rest of the drive can still be scanned."

A correct password or key closes the sheet and scans the drive again with that volume decrypted.
**Cancel** closes the sheet without unlocking, and the other results are kept. Each volume is
offered once per selection of the drive.

Your password or recovery key is never saved. See [PRIVACY.md](PRIVACY.md#passwords-and-recovery-keys).

## Save and reopen a scan

A finished scan (or one you cancelled, or one that stopped early with files found) can be saved,
so you can come back to its results without scanning again.

- **Save Scan…** (⌘S, in the File menu or at the top of the results) saves a `.salvagescan` file
  where you choose. The save panel says: "This file lists the names of the files Salvage found."
  The file holds the file list, where each file's bytes are on the drive, the scan's notices and
  lost partitions, and the drive's name, size and identity. Only your user account can read it.
  It never holds a password, recovery key or decryption key.
- **Open Scan…** (⇧⌘O) shows the saved results again. Until the drive is reconnected, the results
  say "Reconnect <drive name> to preview or recover these files." and Preview and Recover are off.

**Reconnecting.** When the same drive is attached, a **Reconnect** button appears next to that
message. Salvage then opens the drive read-only, as a scan does (its volumes are unmounted), and
checks it's the same drive before it reads any file from it: the same attachment, the same size,
and the same partition layout as when it was scanned. If the layout is different, the results say
the drive "has changed since this scan was saved", and Salvage won't read from it. Scan it again
instead.

Salvage recognises a drive by its current connection. If the drive was unplugged, or the Mac was
restarted, since the scan, the saved scan can't be reconnected: scan the drive again.

Files on encrypted (FileVault) volumes need the password again after reopening. Scan the drive
again and unlock the volume to preview or recover them.

A saved scan made by a different version of Salvage is refused: "This saved scan was made by a
different version of Salvage and can't be opened here."

## Lost partitions

Salvage also searches the drive's unallocated space, outside the current partition table, for
filesystems. Each one found appears in its own **Lost partitions** section on the dashboard, for
example "Lost partition — exFAT, 23.18 GB", with its file count and where it starts ("at 1 MB
(sector 2,048)"). Click a row to browse just that partition's files. A partition whose parser
stopped part-way is marked " (damaged)", and the files found before it stopped are kept.

Salvage reads lost partitions where they are. It never rewrites the partition table. The search
has limits on how much it reads and how many partitions it reports, and "About this scan" says
when a limit was reached.

## Reconstructed files

When the filesystem no longer records a file, Salvage can still find it by its contents. It looks
for known file headers at 512-byte boundaries and follows each one to the file's end. This is
called "carving". It covers the space of every volume Salvage scanned, skipping space that belongs
to files the filesystem already lists. A drive with no recognizable volume at all is carved end to
end.

Reconstructed files:

- are listed under **Reconstructed**, in folders such as `/Reconstructed/Pictures/`;
- have a generated name made of the type and where the file starts on the drive, such as
  `jpeg-000000002000.jpg`. Their original name, folder and date are gone;
- are rated **Medium** when complete and **Low** when partial (see [Confidence labels](#confidence-labels)).

The supported types are in the [README](../README.md#what-it-can-read). Office 2007+ files
(docx/xlsx/pptx) are ZIP containers, so they are reconstructed as `.zip`. Older Office files are
saved as `.doc`.

## Scan a disk-image file

You can scan a disk image file, such as a backup of a memory card or a copy of a failing drive,
without attaching it in Terminal first.

- Choose **File > Open Disk Image…** (⌘O), or drag the image file onto the list of drives.
- The image appears under **Disk images** with its file name and size. Click it to scan it, just
  like a drive.
- To take it off the list, Control-click it and choose **Remove from List**.

Salvage only reads the image and never changes it:

- **Raw images** (`.img`, `.dd`, `.bin`, `.iso`, `.raw` and similar) are read straight from the
  file.
- **`.dmg` and sparse images** are opened by macOS read-only and **without being mounted**, so
  nothing appears in the Finder. Salvage closes them again when you leave the results, start
  another scan or quit.

When you recover files from an image, choose a folder on a **different drive** from the one that
holds the image file. A folder on the same drive is refused ("Destination blocked"), for the same
reason as for a drive: writing there could overwrite the deleted data you are trying to get back.

## Limitations

- **Your startup disk can't be scanned** while macOS is running from it. Salvage refuses it, and
  refuses any drive it can't safely tell apart from it ("Couldn't identify your startup drive
  safely. The scan was refused.").
- **Hardware-encrypted volumes** (the internal storage of a Mac with a T2 or Apple silicon chip)
  can't be unlocked, because their keys are tied to that Mac.
- **Fragmented files.** Each reconstructed file is one contiguous run of bytes, so a file stored
  in pieces is reconstructed only up to the first break, as Partial and Low. Files found through
  filesystem records aren't affected, because the records say where every piece is.
- **Only whole drives** are scan targets, and they must use **512-byte logical sectors** ("Only
  devices with 512-byte logical sectors are supported in this version.").
- **Partition maps:** extended (logical) MBR partitions and hybrid MBR/GPT maps aren't supported.
  When a partition table is damaged, Salvage ignores it and searches the whole drive instead.
- **Free space between partitions** is searched for lost filesystems, but isn't carved for loose
  files. Carving covers the volumes Salvage reads.
- **Some file contents can't be mapped:** NTFS files that are compressed, encrypted or spread
  over several MFT records (`$ATTRIBUTE_LIST`), and ext4 files with filesystem-level encryption.
  These are listed as **Can't be recovered**.
- **Deleted-file recovery is best effort** on every filesystem. A deleted file whose space now
  overlaps another file, or that fails a consistency check, is left out rather than recovered with
  the wrong contents.
- **The drive stays unmounted** after a scan. Disconnect it and plug it back in to use it again.
- **Disk images attached by another user account** can't be read.
