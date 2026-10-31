---
title: 'Scan and Recover Deleted Files from an EXT2/3/4 Drive'
type: 'feature'
created: '2026-10-31'
status: 'ready-for-dev'
baseline_commit: 'c1b21a3'
route: 'dispatch'
review_loop_iteration: 0
context:
  - '{project-root}/_bmad-output/planning-artifacts/architecture/architecture-DataRecoveryTool-2026-10-30/ARCHITECTURE-SPINE.md'
  - '{project-root}/_bmad-output/implementation-artifacts/spec-1-4-scan-a-fat32-exfat-device-with-live-progress.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** FR-5 includes EXT2/3/4. Discovery already recognizes ext volumes by the superblock magic `0xEF53` and routes them to `EXTVolume`. That parser is a placeholder with `isImplemented = false`, so ext volumes are skipped today.

**Approach:**
- Implement a bounded, read-only ext2/3/4 parser in original MIT-licensed Swift (AD-2). Kernel documentation and the MIT/Apache `ext4-view` Rust crate may be read as reference; no code is copied and no dependency is added.
- The parser emits live and deleted regular files as `RecoveredFile` values, filling the format-neutral `SourceMetadata` fields:
  - `filesystem: .ext`
  - `recordOffset` = the inode's byte offset in the volume
  - `allocationStart` = the inode number
  - `rawRecord` = the inode bytes, plus the directory entry
  - `contiguous` = the file has a single extent or a single run of block-map blocks
- Then set `isImplemented = true`.
- For deleted files the epic explicitly accepts under-recovery over incorrect results.

## Boundaries & Constraints

**Always:**
- **Superblock:** validate magic, `s_log_block_size` (block size 1K–64K), inodes/blocks per group, inode size (128, or ≥128 and a power of two up to the block size), a group count consistent with the block count, and that the block count fits the extent.
  - `feature_incompat` must be a subset of a supported set: `filetype`, `extents`, `64bit`, `flex_bg`, `meta_bg` (only if implemented), `huge_file`, `dir_nlink`, `extra_isize`, `large_dir`.
  - Any other incompat bit (`inline_data`, `encrypt`, `casefold`, `journal_dev`, compression and so on) fails with `ScanError.unsupportedFilesystem` or `malformed`. Never parse it partially.
  - `RO_COMPAT` bits are fine, because this parser only reads.
  - If `metadata_csum` is set, verify the superblock CRC32C and fail on mismatch. Implement CRC32C in the parser files; checking group descriptors and inodes is optional.
- **Group descriptors:** 32- or 64-byte, depending on `64bit`. Every inode table and bitmap location must lie within the volume.
- **Inode data:**
  - Ext4 extent trees: header magic `0xF30A`, bounded depth (≤5), entry counts within the node, logical order, and uninitialized extents treated as zeros/sparse.
  - Ext2/3 block maps: direct, indirect, double and triple, with every block number bounds-checked.
  - Detect cycles and cap the total blocks visited.
- **Directories:** linear `ext4_dir_entry_2` walking, with `rec_len` and `name_len` validation. Htree directories stay readable linearly: treat the `dx_root`/`dx_node` blocks as entries spanning the block, and don't follow the index. Recurse from inode 2, with a visited set and bounded depth.
- **Timestamps:** `modified` = `i_mtime`, plus the extra epoch/nanosecond bits when the inode is large enough.
- **Size:** `i_size_lo | i_size_high << 32`. Symlinks, devices and FIFOs are not emitted; regular files only.
- **Deleted files (best effort):**
  - Scan the gap after each live entry's real length inside `rec_len` for plausible deleted dirents: a valid name length, an inode number in range and a sane `file_type`.
  - For each, read the inode. It counts as deleted if `i_dtime != 0` or `i_links_count == 0`. Emit it with `isDeleted: true` only if its extent tree or block map is still intact (passes validation), its blocks are free in the block bitmap and its size is greater than zero.
  - Ext3/ext4 usually zero those pointers on delete. Such files are skipped, and that is expected.
  - Also skip a deleted inode that a live entry has since reused.
- **Journal:** the journal is not replayed. A volume whose `needs_recovery` incompat bit is set is still scanned read-only. Report it in Implementation Notes; don't fail.
- **Live-metadata corruption** stays fail-closed (`ScanError.malformed`), consistent with FAT. An implausible deleted candidate is skipped and never aborts the scan.
- Update the routing tests in `ScanSessionTests.swift`, changing only the ext parts: remove the ext partition from `recognizedButUnimplementedVolumesAreSkipped`, and remove `"ext"` from `wholeDiskUnimplementedFormatIsUnsupported`'s arguments. Add a positive routing test in your own test file.

**Never:** No edits to `FATVolume.swift`, `NTFSVolume.swift`, `ScanSession.swift`, `ScanEvent.swift`, `VolumeDiscovery.swift`, the app, DiskIO or CI. Other stories own those files and are running in parallel. No writes, no external dependencies, no journal replay.

## I/O & Edge-Case Matrix

| Scenario | Input | Expected | Error handling |
|---|---|---|---|
| ext2 live files, block map incl. indirect | Synthetic image | Paths, sizes, mtime; `.completed` | — |
| ext4 live files, extents depth 0 and 1 | Synthetic image | Same | — |
| 64bit group descriptors | — | Parsed correctly | — |
| Deleted file, intact pointers, free blocks | Dirent in `rec_len` gap | Emitted `isDeleted` | — |
| Deleted file, zeroed extents (ext4 typical) | — | Not emitted | Skip, no error |
| Unsupported incompat (`inline_data`/`encrypt`) | — | Explicit unsupported error | No partial results claimed |
| `metadata_csum` superblock mismatch | — | Error | `malformed` |
| Extent or block-map cycle, out-of-range block | — | Bounded termination | `malformed` |
| Htree directory | — | Entries found linearly | — |

</frozen-after-approval>

## Code Map

- `SalvageCore/Sources/SalvageCore/Parsers/EXTVolume.swift`: the implementation. Keep the existing `init` and `scan()` signatures.
- You may add helper files `SalvageCore/Sources/SalvageCore/Parsers/EXT*.swift`.
- Existing helpers: `Data.number(_:_:)` and `checkedAdd`/`checkedMultiply`/`signed` in `VolumeDiscovery.swift`, which you use but must not edit.
- Tests: a new `SalvageCore/Tests/SalvageCoreTests/EXTVolumeTests.swift`. Build tiny synthetic images in Swift; macOS has no `mke2fs`. Reuse `ImageReader` and `scan` from `ScanSessionTests.swift`.

## Tasks & Acceptance

- [ ] Superblock, feature gating, CRC32C and group descriptors.
- [ ] Inode reading, extent trees and block maps.
- [ ] Directory walking (linear, htree-tolerant) and path building.
- [ ] Best-effort deleted-dirent recovery.
- [ ] Set `isImplemented = true` and update the routing tests.
- [ ] Synthetic-image tests covering the matrix.

**Acceptance criteria:**
- Given an ext2/3/4 device with deleted-but-not-overwritten files, those files appear with their original filename, path and timestamp.
- Given an ext device, it is scanned through the same unified flow.
- Given ext4 journal or extent complexity, recovery succeeds for the common case. It under-recovers rather than producing incorrect results.

## Verification

- `swift test --package-path SalvageCore`
- `./scripts/check-core-boundary.sh`
- `xcodebuild -project Salvage.xcodeproj -scheme Salvage -configuration Debug -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build`
