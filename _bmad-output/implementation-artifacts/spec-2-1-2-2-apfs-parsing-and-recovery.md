---
title: 'APFS Parsing Spike and Recovery (Stories 2.1 + 2.2)'
type: 'feature'
created: '2026-10-31'
status: 'ready-for-dev'
baseline_commit: '4d050bd'
route: 'dispatch'
context:
  - '{project-root}/_bmad-output/planning-artifacts/architecture/architecture-DataRecoveryTool-2026-10-30/ARCHITECTURE-SPINE.md'
  - '{project-root}/_bmad-output/implementation-artifacts/spec-tech-file-content-mapping.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** FR-5 includes APFS, the format of every modern Mac drive. Discovery already recognizes APFS by signature and routes it to `APFSContainer`, a placeholder with `isImplemented = false`. AD-2 is now ADOPTED: the parser is original MIT-licensed Swift written from Apple's public *Apple File System Reference* (2018+), with no GPL/LGPL code read or copied (not apfs-fuse, libfsapfs, Sleuth Kit, or any port of them).

**Approach:**
1. **Spike first (Story 2.1), on a real volume.** Create an APFS disk image with `hdiutil create -fs APFS` (no sudo), write files with known contents, delete some, unmount, and read the raw device (`/dev/rdiskN`, user-owned) through the parser. Record in Implementation Notes: what was enumerated, what wasn't, and the go/no-go. If the approach is infeasible in reasonable time, stop, document the fallback options explicitly (shelling out to a GPL tool with a FUSE dependency; LGPL linking risk), and report.
2. **Then the parser (Story 2.2):** live files and deleted-but-not-overwritten files with original name, path and timestamp, plus content mapping, through the same unified scan flow.

## Boundaries & Constraints

**Always:**
- **Container (NXSB at block 0):** validate the Fletcher-64 checksum of every object read; reject on mismatch (`ScanError.malformed`). Read `nx_block_size` (4096 typical; accept 4K–64K powers of two), the checkpoint descriptor area, and pick the **latest valid checkpoint** (highest `xid` whose superblock checksums and whose object map is readable). Resolve the container object map (B-tree) to physical blocks. Enumerate `nx_fs_oid[]` volumes.
- **Volume (APSB):** per volume: object map → root tree. Walk the filesystem B-tree: `j_inode_val` (ids, parent, mode, timestamps, size via `INODE_EXT_TYPE_DSTREAM`), `j_drec_val` (directory records, names, hashed variants), `j_file_extent_val` (extents → `DataRun`s, device-absolute: `extent.offset + paddr * blockSize`). Build paths from parent ids with cycle and depth bounds. Emit regular files only; skip directories, symlinks, and the private-dir (`private-dir`, id 3).
- **Bare volume device (APSB at block 0):** when the extent starts with `APSB` (an unlocked volume device read directly, Story 2.4's path), parse it as one volume whose object-map physical addresses are relative to the volume device. Test with a synthetic image; note that a real check depends on 2.4.
- **Encrypted volumes:** if `apfs_fs_flags` lacks `APFS_FS_UNENCRYPTED` (and the container isn't a bare volume), do not try to parse the encrypted trees. Emit `.unlockRequired(device.requiringUnlock(volumeUUID: <apfs_vol_uuid>, volumeName: <apfs_volname>))` where `device` is the init parameter (if nil, build a placeholder `BlockDevice(bsdName: "", displayName: volumeName, sizeBytes: 0, isInternal: false, isBootVolume: false)`), then continue with the next volume. Never fail the scan because a volume is encrypted.
- **Deleted files (best effort, never wrong):** APFS is copy-on-write, so older checkpoints still reference deleted files. Walk **older valid checkpoints** in the descriptor ring (bounded, newest first) and the volume's **snapshots** (`apfs_snap_meta` tree) for inode/drec records absent from the current tree. Emit such a file with `isDeleted: true` only if (a) its full extent list is present and valid, (b) every extent lies within the volume's allocated range, and (c) its blocks are **not in use** by the current checkpoint's space manager bitmaps (parse `nx_spaceman_oid` → chunk-info bitmaps; if the bitmaps can't be read, skip deleted recovery entirely and note it). Two deleted candidates whose extents overlap are both skipped. Use a per-volume work budget as the other parsers do.
- **Timestamps:** nanoseconds since 1970 → `Date`. Size from the dstream's `size` (logical), extents truncated at it; hole regions as `deviceOffset: nil` runs.
- **Compressed files** (`INODE_HAS_UNCOMPRESSED_SIZE` / `UF_COMPRESSED`, decmpfs xattr): emit with correct metadata and `.unmapped` content for now; note it. **Clones** share extents: emit each name; do not treat shared extents as cross-links (reference counts are via the extent-ref tree).
- Bounds: every read through a `read()` limited to the extent, like `FATVolume.read`; cap B-tree depth (≤ 16), node count, key/value sizes; checked arithmetic (`checkedAdd`/`checkedMultiply`/`signed`). Live-tree corruption is fail-closed; deleted-candidate problems are skipped.
- Set `isImplemented = true`; update the routing test `apfsContainerAndBareVolumeAreRecognised` in `ScanSessionTests.swift` (only that test and `pendingFormatPartitionsAreSkippedNotFailed`'s APFS partition), and add positive routing tests in your own file.
- Update `ARCHITECTURE-SPINE.md` AD-2's text to record the spike outcome in one sentence (keep the `[ADOPTED 2026-10-31]` tag). Update PRD Open Question 9's resolution note if the spike changes anything.

**Never:** No edits to `FATVolume.swift`, `NTFSVolume.swift`, `EXTVolume.swift`, `HFSPlusVolume.swift`, `ScanSession.swift`, `ScanEvent.swift`, `VolumeDiscovery.swift`, `VolumeScanners.swift`, `Carving/`, the app, DiskIO or CI. Other stories own those files and run in parallel. No external dependencies. No writes.

## I/O & Edge-Case Matrix

| Scenario | Input | Expected | Error handling |
|---|---|---|---|
| Real hdiutil APFS image, live files | Nested folders, sizes 0 to several MiB | Paths, sizes, mtime; content byte-identical via `FileContentReader`; `.completed` | — |
| Deleted file, older checkpoint/snapshot, blocks free | — | Emitted `isDeleted` with original path, byte-identical | — |
| Deleted, blocks reused | — | Not emitted | Skip |
| Encrypted volume in container | fs flags encrypted | `.unlockRequired` with UUID/name; other volumes scanned | — |
| Bad object checksum (live) | — | `malformed`, earlier discoveries kept | — |
| No valid checkpoint | — | `malformed` or `unsupportedFilesystem`, never empty success | — |
| B-tree cycle / depth / oversized key | crafted | Bounded termination, `malformed` | — |
| Bare volume (APSB) image | synthetic | Parsed as one volume | — |

</frozen-after-approval>

## Code Map

- `SalvageCore/Sources/SalvageCore/Parsers/APFSContainer.swift` (keep `init`/`scan()` signatures); you may add `Parsers/APFS*.swift` helpers (objects/checksum, B-tree, spaceman).
- Tests: new `SalvageCore/Tests/SalvageCoreTests/APFSVolumeTests.swift`. Build synthetic images in Swift for the hostile cases; for the spike use real `hdiutil` images in a temp dir (skip cleanly if `hdiutil` is unavailable; only ever touch images you created; detach in teardown). Reuse `ImageReader` and `scan` from `ScanSessionTests.swift`.

## Verification

- `swift test --package-path SalvageCore`
- `./scripts/check-core-boundary.sh`
- `xcodebuild -project Salvage.xcodeproj -scheme Salvage -configuration Debug -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build`
