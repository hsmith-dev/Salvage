# The `salvage` command-line tool

`salvage` scans a drive or a disk image file and recovers files from it, without the app. It uses
the app's scanning code (SalvageCore), the app's device access and safety checks (SalvageDiskIO),
and an exact copy of the app's recovery engine. The safety rules are the same:

- **The source is only read.** A drive is opened read-only through `RawBlockReader`, which
  checks the descriptor really is read-only. An image file is opened `O_RDONLY` and read with
  `pread`.
- **Your startup disk is refused.** The tool refuses it before opening anything, and
  `RawBlockReader` refuses it again.
- **A destination on the source is refused.** The tool checks this before the source is
  opened, checks again right before writing, and the engine then confirms the folder it opened
  is on the volume that was checked. A destination whose drive can't be determined is refused
  too.
- **No file is ever overwritten.** Each file is written under a temporary `.partial` name created
  with `O_EXCL`. It gets a free final name (`name (2).ext` …) inside a new recovery folder.
- **No network.** The tool has no network code. `scripts/check-no-network.sh` scans
  `SalvageCLI/` in CI.

## Build

```sh
swift build -c release --package-path SalvageCLI
SalvageCLI/.build/release/salvage --version
```

The tool is a SwiftPM package (`SalvageCLI/Package.swift`). It depends on `SalvageCore` and
`SalvageDiskIO` by path. It isn't part of the Xcode project or the app bundle.

## Commands

### `salvage list [--json]`

Prints the device tree, as in the app's device picker. Each drive is listed with its partitions,
any APFS container and its volumes. The output marks the startup disk ("can't be scanned") and
locked FileVault volumes. Partition offsets are shown in bytes. `--json` prints one object per
drive.

```
disk4  SanDisk Ultra  64 GB  (external)
   └ disk4s1  PHOTOS  exFAT  63.8 GB  at offset 1048576
disk0  APPLE SSD AP0512Z  500.3 GB  (internal, startup disk, can't be scanned)
   ...
```

### `salvage scan <diskN | /path/to/image> [options]`

Scans the whole source and prints one line per file found. Progress goes to stderr, results go
to stdout.

Each output line has four tab-separated columns:

1. The state: `live`, `deleted`, or `rebuilt` (reconstructed by carving).
2. The size in bytes.
3. The confidence: `high`, `medium` or `low`, or `unrecoverable`. `,partial` is appended when
   the file is known to be incomplete.
4. The path.

At the end, stderr shows the totals and every volume's byte offset (`recover --partition` uses
these offsets).

| Option | Meaning |
|---|---|
| `--json` | One JSON object per line on stdout, described below. |
| `--deleted-only` | Only deleted files. |
| `--format <type>[,…]` | Only these types. A type is a category (`pictures`, `videos`, `audio`, `documents`, `archives`, `other`) or a file extension (`jpg`). The option can be repeated. |
| `--limit <n>` | Stop the scan after `n` matching files. |
| `--quiet`, `-q` | No progress. |

With `--json`, every line is one of these objects:

- `{"type":"file", "path", "name", "size", "modified" (ISO 8601 or null), "deleted",
  "method" ("metadata"|"carved"), "partial", "recoverable", "confidence" ("high"|"medium"|"low"|null),
  "category", "filesystem", "volumeOffset", "volumeName", "encrypted"}`
- `{"type":"notice", "kind", "message", …}`: something the scan couldn't do, such as a skipped
  volume, a damaged partition table, or the carving limit being reached. The notice's fields are
  included. Notices come after the files.
- `{"type":"lostPartition", "offset", "size", "format"}`

Keys are sorted, so the output is stable.

### `salvage recover <diskN | /path/to/image> --to <folder> <selection> [options]`

Scans the source, then copies the selected files into a new folder named
`Salvage Recovery <source> <date>` inside `<folder>`. The files keep their folder paths. A
deleted file goes in the same folder as the live files, under its own name (`name (2).ext` when
that name is taken). `<folder>` must already exist and must be on a different drive from the
source. Choose exactly one selection:

| Selection | Files |
|---|---|
| `--all` | Every recoverable file. |
| `--path <glob>` (repeatable) | Files whose path matches. Uses `fnmatch(3)`; `*` also crosses folders, so `/DCIM/*` is everything under `/DCIM`. A glob without a leading `/` is matched from the root. |
| `--partition <offset>` (repeatable) | Files of the volume starting at that byte offset (decimal, or hex such as `0x100000`), as shown by `scan` or `list`. |

| Option | Meaning |
|---|---|
| `--include-reconstructed` | Also copy matching reconstructed (carved) files. They are left out by default because they have generated names and may be incomplete, as in the app. |
| `--json` | Per-file results as JSON lines: `{"type":"recovered","source","destination","size","sha256"}` and `{"type":"failed","source","name","reason"}`, then one `{"type":"summary",…}`. |
| `--quiet`, `-q` | No progress. |

Without `--json`, each file gets one tab-separated stdout line:

- `recovered  <source path>  <written path>  <bytes>  <sha256>`
- `failed  <source path>  <reason>`

A summary sentence goes to stderr. Only recoverable files are selected: files whose contents
could be located. If the scan stops part-way, the files found before it stopped are still
recovered, and the exit code is 4.

### `salvage --version`, `salvage --help`

## Sources

- **A drive**: `disk4`, `/dev/disk4` or `/dev/rdisk4`. Always a whole drive; a partition
  (`disk4s1`) is refused, and its files are found by scanning the drive. The drive is looked up
  in the device tree and opened with `RawBlockReader.prepare`, as the app does. The tool
  **unmounts the drive's volumes** first (the drive stays connected and is never written). They
  stay unmounted afterwards, as with the app; `diskutil mountDisk diskN` mounts them again.
  Reading a physical drive as a normal user needs the privileged read-only helper. The helper
  only accepts the signed Salvage app, so the command-line tool can read user-owned devices
  (attached disk images) but not USB drives or memory cards. For those, use the app, or make an
  image of the drive with the app or with `dd` and scan the image.
- **An image file**: any other argument, such as `./disk4` for a file with that name. Raw images
  (`.img`, `.dd`, `.cdr`, read-write `.dmg`) are read directly. A trailing UDIF block is
  skipped when it describes raw data. A compressed or encoded image (UDZO, sparse) is refused
  with a `hdiutil convert … -format UDTO` hint. A device node given as a path, or a link to one,
  is refused: name the drive as `diskN` so the drive checks apply.

## Destination safety

- **For a drive**, the rule is the app's: `DestinationSafety` compares the destination
  volume's physical drives (APFS physical stores and disk images followed to their host drives)
  with the source's.
- **For an image file**, the source is the image itself. A destination is on the source when
  its volume is backed by that same image file. This holds directly or through further images.
  The file is compared by device and inode, so another path to it doesn't hide it. A folder on
  the volume that stores the image file is allowed, as it is for an attached image in the app:
  writing other files there never changes the image's bytes. This check is
  `ImageFileDestinationSafety` in SalvageDiskIO.

In both cases, anything that can't be determined is refused: an unknown mount, a network share,
or an unidentifiable virtual disk.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Done: the scan ran to the end (or stopped at `--limit`), or every selected file was recovered intact. |
| 1 | Failed: the source couldn't be opened or read, the scan failed before finding anything, the destination couldn't be written, or the named drive doesn't exist. |
| 2 | Usage error: unknown command or option, missing argument, `--to` folder doesn't exist. |
| 3 | Refused for safety: the startup disk, a destination on the source (or on an undetermined drive), a partition or synthesized container instead of a whole drive, a device node given as an image path. Nothing was read or written. |
| 4 | Finished with problems: some files couldn't be recovered, or the scan stopped part-way so only the files found before then were recovered. |
| 5 | Nothing matched: no recoverable file matched the selection. A hint says when reconstructed files would match with `--include-reconstructed`. |
| 130 | Interrupted (Ctrl-C). A file being written is removed, never left half-written. |

## Not supported

- **FileVault volumes**: they can't be unlocked from the command line. Locked volumes are
  reported, and their files aren't listed. Use the app.
- **Pause and resume**: not available from the command line.

## Example

```
$ salvage scan ~/card.dmg --deleted-only
deleted	70000	high	/DCIM/IMG_0002.JPG
Scanning: 100% (14.7 MB of 14.7 MB)
Found 7 files (2 deleted, 0 reconstructed); 2 shown.
  volume at offset 1048576 (exfat): 7 files

$ salvage recover ~/card.dmg --to /Volumes/Backup --path '/DCIM/*' -q
recovered	/DCIM/IMG_0001.JPG	/Volumes/Backup/Salvage Recovery card.dmg 2026-10-31 23.40.37/DCIM/IMG_0001.JPG	300000	d91e80…
recovered	/DCIM/IMG_0002.JPG	/Volumes/Backup/Salvage Recovery card.dmg 2026-10-31 23.40.37/DCIM/IMG_0002.JPG	70000	582649…
Recovered 2 of 2 files (370 KB written) into /Volumes/Backup/Salvage Recovery card.dmg 2026-10-31 23.40.37.
```

## Maintenance

`SalvageCLI/Sources/SalvageCLIKit/RecoveryEngine.swift` is a **verbatim copy** of the app's
recovery engine. It copies everything in `Salvage/ViewModels/RecoveryCoordinator.swift` above
`// MARK: - Coordinator`. The engine lives in the app target, which a SwiftPM package can't
depend on. The test `engineCopyMatchesTheApp` fails when the two differ. After changing the
app's engine, re-copy it:

```sh
f=Salvage/ViewModels/RecoveryCoordinator.swift
out=SalvageCLI/Sources/SalvageCLIKit/RecoveryEngine.swift
head="$(sed -n '1,/^\/\/ BEGIN VERBATIM COPY$/p' "$out")"
{ printf '%s\n' "$head"; sed -n '/^\/\/ MARK: - Results$/,/^\/\/ MARK: - Coordinator$/p' "$f" | sed '$d'; } > "$out.new" && mv "$out.new" "$out"
```

Tests: `swift test --package-path SalvageCLI`. The tests build small exFAT images in a temp
folder with `hdiutil`, then detach and delete them. Drives are always injected fakes; no real
device is listed or opened. Set `SALVAGE_SKIP_HDIUTIL=1` to skip the image tests where `hdiutil`
can't attach images.
