---
title: 'Recover Selected Files to a Safe Destination'
type: 'feature'
created: '2026-10-31'
status: 'done'
baseline_commit: '0654e86'
route: 'dispatch'
context:
  - '{project-root}/_bmad-output/planning-artifacts/architecture/architecture-DataRecoveryTool-2026-10-30/ARCHITECTURE-SPINE.md'
  - '{project-root}/_bmad-output/planning-artifacts/ux-designs/ux-DataRecoveryTool-2026-10-31/DESIGN.md'
  - '{project-root}/_bmad-output/planning-artifacts/ux-designs/ux-DataRecoveryTool-2026-10-31/EXPERIENCE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** FR-14–FR-16 and AD-8 require three things:
- copying selected files byte-identically to a destination folder the user picks;
- refusing any destination on the same physical device as the source;
- a summary showing what was actually written.

**Approach:**
- **`SalvageDiskIO` — `DestinationSafety`:** decides whether a destination URL lives on the same physical device as the source `BlockDevice`. It resolves the destination volume via `statfs` (`f_mntfromname`), reduces it to a whole disk, and expands APFS physical stores. It reuses the existing `BootDiskSafety`/`BSDDeviceNames` helpers.
- **App — `RecoveryCoordinator`:** streams each file through `source.content` (`FileContentReader`) into the destination, one file at a time, and reports a result per file.
- **App — `RecoverySheet(files: [RecoveredFile], source: SourceSession, onDone: () -> Void)`:** the destination picker, a red block banner for an unsafe destination, progress, and a summary with "Show in Finder". Story 1.7, running in parallel, will present this sheet from its "Recover" button.

## Boundaries & Constraints

**Always:**
- **Destination check:** if it is the same device or can't be determined, Recover is disabled, with the banner "This folder is on the drive you're recovering from. Choose a folder on a different drive." There is no "proceed anyway". The banner is the only place the `blocking` color is used.
- **Path safety:**
  - Sanitize every name and path component, removing NUL, `/`, `:` (Finder) and leading dots, and replacing a lone `.` or `..` component with `_`.
  - Rebuild the original folder structure under one root folder, e.g. "Salvage Recovery <device> <date>".
  - Refuse any path that resolves outside that root. Check this after symlink resolution and use `O_NOFOLLOW`.
  - Never overwrite an existing file; add a " (2)"-style suffix instead.
- **Writing:**
  - Write to a temporary `.partial` file in the same folder, `fsync`, then rename atomically.
  - Set the modification date from `RecoveredFile.modified` when present.
  - On failure (disk full, permission, read error, unmapped), remove the partial file and record why. Never abort the whole batch.
- **Byte-identical:** compute SHA-256 while streaming and record it. Tests verify the written bytes equal the source bytes.
- **Summary:** the actual count and bytes written, which may be below the selection. List failed files by name with their reason. "Show in Finder" uses `NSWorkspace.activateFileViewerSelecting`.
- **Cancel:** the user can cancel mid-run. Files already written stay; the file in progress is cleaned up.
- **Security-scoped access** to the chosen folder isn't needed, because the app isn't sandboxed (see `project.yml`); confirm this.
- **Destination volumes:** the app may write only under the folder the user chose. It never writes to the source device.

**Never:**
- Don't edit `FileBrowserView.swift`, `ResultsDashboardView.swift`, `ContentView.swift`, `ScanViewModel.swift`, `RawBlockReader.swift`, the parsers or Core.
- No network APIs.

</frozen-after-approval>

## Code Map

- **New:**
  - `SalvageDiskIO/Sources/SalvageDiskIO/DestinationSafety.swift`, with an injectable mount-source resolver for tests.
  - `SalvageDiskIO/Tests/SalvageDiskIOTests/DestinationSafetyTests.swift`.
  - `Salvage/ViewModels/RecoveryCoordinator.swift` (testable with a temp directory and an in-memory `BlockReader`).
  - `Salvage/Views/RecoverySheet.swift`.
  - `SalvageTests/RecoveryCoordinatorTests.swift`.
- **Test cases:** traversal names, collisions, partial failure, an unmapped file, cancellation, byte equality and mtime.
- **Project:** regenerate with `xcodegen generate`.

## Verification

- `swift test --package-path SalvageDiskIO`
- `./scripts/check-core-boundary.sh && ./scripts/check-no-network.sh`
- `xcodebuild -project Salvage.xcodeproj -scheme Salvage -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:SalvageTests test`
- `xcodebuild -project Salvage.xcodeproj -scheme Salvage -configuration Debug -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build`

## Implementation Notes

- **Not sandboxed (confirmed):** `project.yml` sets no `ENABLE_APP_SANDBOX`/entitlements file, only the hardened runtime, so the `NSOpenPanel` URL is used directly with no security-scoped bookmark or `startAccessingSecurityScopedResource`.
- **`DestinationSafety` API:** `DestinationSafety(mountSource:physicalDisks:backing:mediaIdentity:)` with `.live` (statfs + `diskutil info -plist` via the existing `physicalWholeDisks(backing:)`, `hdiutil info -plist` only for virtual disks, and the IORegistry); `check(destination:source:) -> DestinationVerdict` (`.safe`, `.sameDevice`, `.undetermined`) and `assess(destination:source:) -> DestinationAssessment` (the verdict plus the checked volume's `f_mntfromname`). Both the destination and the source are expanded to their physical stores, so an APFS container and the disk carrying it count as one device in either direction. Only a mount source starting with `/dev/` (compared on UTF-8 bytes) is accepted; network shares (`//host/...`), autofs maps, a non-file URL, a failed `statfs` or a failed physical-store lookup all return `.undetermined`, which blocks exactly like `.sameDevice`.
- **Virtual destinations:** every whole disk in the destination's set is classified (`DiskBacking`). A disk is virtual when `BusProtocol == "Disk Image"`, or `VirtualOrPhysical == "Virtual"` with no `APFSPhysicalStores` (a synthesized APFS container is not virtual; its stores are expanded instead). A disk image is mapped to its `image-path` through `hdiutil info -plist` (`system-entities[].dev-entry`), `statfs` of that path gives the host volume, and the host is evaluated the same way, at most `maxVirtualDepth` (4) hops deep. Any other virtual disk (AppleRAID, CoreStorage), an image missing from `hdiutil`, an image file on a network share, or a cycle is `.undetermined`.
- **Source identity:** when the scanned `BlockDevice` carries a `mediaIdentity` (the IORegistry entry ID `DeviceWatcher` records), the IOMedia now named by its BSD name must have the same ID; a reused or renumbered BSD name, or a lookup failure, is `.undetermined`. Without an identity, the source's current whole-disk and physical-store resolution is used, and a failure blocks.
- **Checked twice, then confirmed on the descriptor:** the coordinator checks when the folder is chosen (off the main thread, since `diskutil` can take seconds) and again immediately before writing; a changed verdict returns the sheet to the blocked state with nothing written. After the engine opens the destination folder it `fstatfs`es the descriptor, and its `f_mntfromname` must equal the volume the second check assessed; otherwise it's treated as undetermined (blocked, nothing written).
- **Start failure:** if the run can't start (e.g. the folder vanished), the sheet stays on the confirmation with the reason. Choosing another folder clears the failure (back to `.ready`), and Recover becomes "Try Again" for the same folder.
- **Path safety:** every directory and file is created with `mkdirat`/`openat(... O_NOFOLLOW)` relative to an open directory descriptor. Containment is verified without path strings: from each target folder's descriptor the engine walks `..` (relative `O_NOFOLLOW` opens) and must meet the root's `(st_dev, st_ino)` within as many levels as the file has folder components; anything else is `outsideRoot`. This works at any depth (the old `F_GETPATH` + `MAXPATHLEN` check failed on deep trees and misreported them as outside the root). A file whose final absolute path would reach `PATH_MAX` is refused before any folder is created and reported as too long (`ENAMETOOLONG`), not as outside the root. Sanitizing works on Unicode scalars: it removes C0 control characters and DEL, strips leading dots together with leading combining marks and format / default-ignorable characters (so ".\u{301}x" can't become a hidden file), and caps each component at 200 UTF-8 bytes (keeping a short extension), leaving room under NAME_MAX for the suffix and the `.partial` name (whose stem is cut to 40 UTF-8 bytes on a scalar boundary). The folder structure comes from `RecoveredFile.path` minus its last component when that matches `name`.
- **Collisions and publishing:** final names are published with `renameatx_np(..., RENAME_EXCL)`, so an existing file is never replaced even under a race; `EEXIST` moves on to "name (2).ext". FAT32 and exFAT return `ENOTSUP` for `RENAME_EXCL` and for `linkat` (verified on real images), so publishing falls back in order: on `ENOTSUP`/`EOPNOTSUPP`/`EINVAL`, `linkat(partial → final)` (atomic, never replaces) then `unlinkat(partial)`; if links are unsupported too, an exclusive placeholder (`O_CREAT|O_EXCL|O_NOFOLLOW`) claims the final name and `renameat(partial, final)` replaces only that placeholder. Copying the bytes a second time was rejected as doubling the I/O for no safety gain; the residual race (another process deleting the placeholder and creating its own file in the instant before the rename) is accepted on these permission-less volumes. A failed rename removes the placeholder. Case-insensitive collisions on FAT ("a.txt" vs "A.TXT") get suffixes like any other. The root folder also gets a suffix if a folder with its name already exists. A folder whose name is taken by a file or a symlink becomes "name (2)" and is reused consistently for the rest of the batch; a folder replaced by a symlink mid-run fails the later files destined for it (`ELOOP`) rather than following it.
- **Root folder name:** "Salvage Recovery <device display name> yyyy-MM-dd HH.mm.ss" (dots instead of colons, which Finder shows as slashes).
- **Write order:** `.partial` (`O_EXCL`) → stream + SHA-256 → byte count must equal `sizeBytes` → `futimens` (mtime only; atime left as is) → `fcntl(F_FULLFSYNC)` (falling back to `fsync` only on `ENOTSUP`/`EOPNOTSUPP`/`ENOTTY`/`EINVAL`) → publish (above) → `fsync` of the folder. Any failure or cancellation closes and unlinks the partial file.
- **Streaming the source:** `FileContentReader.chunks(of:limit:)` returns `FileContentChunks`, a pull-based `AsyncSequence` of `Data`: no producer task and no buffer; each `next()` reads (or, for a sparse hole, slices one reused zero buffer for) exactly one chunk, so memory is bounded by one chunk however large the file or its holes are. `prefix(of:limit:)` and every `for try await` caller are source-compatible.
- **Cancel:** files already published stay; the file in progress is removed; it and the files after it are reported as `notAttempted` (not as failures) in the summary.
- **Blocking colors:** DESIGN.md's starting hexes measure about 3.9:1 (light, `#D64545` on `#FCEEED`) and 4.3:1 (dark, `#E0685F` on `#3A2422`), below the required AA 4.5:1. The banner text uses `#BF3434` (about 4.9:1) and `#E87870` (about 5.1:1) on the unchanged surfaces. `DestinationBlockBanner` is the only place they're used.
- **Interface for Story 1.7:** `RecoverySheet(files:source:onDone:)` as contracted. `onDone` is called from Cancel (before a run) and Done (on the summary); the presenter dismisses the sheet. The sheet doesn't close the `SourceSession`.
