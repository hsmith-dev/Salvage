---
title: 'Scan and Recover Deleted Files from an EXT2/3/4 Drive'
type: 'feature'
created: '2026-10-31'
status: 'done'
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

- [x] Superblock, feature gating, CRC32C and group descriptors.
- [x] Inode reading, extent trees and block maps.
- [x] Directory walking (linear, htree-tolerant) and path building.
- [x] Best-effort deleted-dirent recovery.
- [x] Set `isImplemented = true` and update the routing tests.
- [x] Synthetic-image tests covering the matrix.

**Acceptance criteria:**
- Given an ext2/3/4 device with deleted-but-not-overwritten files, those files appear with their original filename, path and timestamp.
- Given an ext device, it is scanned through the same unified flow.
- Given ext4 journal or extent complexity, recovery succeeds for the common case. It under-recovers rather than producing incorrect results.

## Verification

- `swift test --package-path SalvageCore`
- `./scripts/check-core-boundary.sh`
- `xcodebuild -project Salvage.xcodeproj -scheme Salvage -configuration Debug -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build`

## Implementation Notes

- **Journal / `needs_recovery`:** the journal is never replayed. A volume with the `needs_recovery` (RECOVER, 0x4) incompat bit is scanned read-only from on-disk metadata as it stands, so changes still only in the journal are not visible. It is not reported as an error (covered by `needsRecoveryIsScannedReadOnly`). Two consequences:
  - Its bitmaps may be stale, so deleted-file recovery is skipped entirely on such a volume (no slack mining, no candidates); live scanning continues (`needsRecoverySkipsDeletedRecovery`).
  - A committed live entry whose inode reads mode 0 is skipped there, because the inode table can lag the directory until the journal is replayed. On a clean volume the same entry is still `malformed` (`freeInodeLiveEntryIsSkippedOnlyWhenJournalNeedsRecovery`).
- **Feature gating:** supported incompat bits are `filetype`, `needs_recovery`, `extents`, `64bit`, `flex_bg` and `large_dir`. `meta_bg` is not implemented, so it is refused with `unsupportedFilesystem`. `huge_file`, `dir_nlink` and `extra_isize` are RO_COMPAT bits on disk (the spec lists them under incompat), so they are accepted along with every other RO_COMPAT bit. `csum_seed` (0x2000) and `mmp` (0x100) are not in the supported set and are refused, as the spec requires. Superblock revisions above 1 are refused. `bigalloc` (RO_COMPAT 0x200) is the one refused RO_COMPAT bit: its bitmaps count clusters rather than blocks, so it fails with `unsupportedFilesystem` instead of being misread (`bigallocIsRefused`).
- **CRC32C:** ext4 stores the raw CRC32C register (seed `~0`, no final inversion) over superblock bytes 0..<1020. `crc32c()` is the standard (inverted) form and is checked against the `123456789` vector and the RFC 3720 B.4 vectors (32 zero bytes = `0x8A9136AA`, 32 `0xFF` bytes = `0x62A8AB43`, bytes 0..31 = `0x46DD794E`); the superblock compares `crc32cUpdate(~0, …)`. `superblockChecksumMatchesAnIndependentlyComputedValue` hardcodes the stored value (`0x979B67C8`) for a fixed superblock, computed with a separate table-driven implementation that reproduces those vectors. Group descriptor and inode checksums are not verified (optional per spec).
- **Uninit groups:** when `gdt_csum` or `metadata_csum` is set, a group flagged `INODE_UNINIT` or `BLOCK_UNINIT` has a bitmap that can't be trusted. Deleted candidates that need such a bitmap are skipped (under-recovery).
- **`recordOffset`:** the inode's byte offset on the device (device-absolute: partition offset plus the inode's offset in the volume), matching FAT and NTFS and the `SourceMetadata` doc comment since commit `eb52230`. The frozen intent's "byte offset in the volume" predates that change.
- **`contiguous`:** true when the file's mapped blocks merge into one logical+physical run, covering both a single extent and a single block-map run. An empty file (no blocks) counts as contiguous.
- **Deleted-file rules:** candidates are collected during the live walk and evaluated after it, grouped by inode number. That way an inode referenced by any live entry (renames, hard links, reuse) is never emitted as deleted, even when its bitmap bit says free (`liveEntryOnAnInodeMarkedFreeIsNeverAlsoDeleted`). An inode is skipped entirely when its stale entries disagree on name or containing directory, for example mv then rm (`staleEntriesThatDisagreeOn{Name,Path}AreSkipped`). A candidate is emitted only if all of these hold:
  - its dirent `file_type` is regular (or 0 without `filetype`), and its name is valid UTF-8;
  - it is a regular-mode inode with `i_dtime != 0` or `i_links_count == 0`, its size is > 0, and it is free in the inode bitmap;
  - `i_dtime` is not later than its containing directory's last change (the later of that directory's mtime and ctime). The unlink that left the entry stale would have changed the directory, so a later dtime means the inode was reused and deleted again after the entry went stale (`deletionLaterThanTheDirectoryChangeIsSkipped`). This also skips a file that stayed open after unlink and was evicted later, and, because dtime has only second resolution, a deletion that crossed a second boundary. Both are accepted under-recovery;
  - its extent tree or block map validates, and maps (data plus tree/indirect blocks) no more than the size needs plus `16 + needed/16` blocks of slack (`deletedMappingFarLargerThanTheSizeIsSkipped`);
  - its mapping covers every logical block up to its size (sparse deleted files are skipped), and every data and tree/indirect block is free in the block bitmap;
  - no other accepted deleted candidate (and no other part of its own mapping) claims any of the same blocks. Overlapping candidates are all skipped, so data is never attributed to the wrong file (`overlappingDeletedCandidatesAreAllSkipped`).

  Any `malformed` result while evaluating a candidate skips it. Other errors (I/O, cancellation) still propagate.
- **Kernel deletions rarely qualify:** Linux ext2/3/4 eviction sets `i_size = 0` and zeroes the block pointers or extents of a deleted inode, so files deleted by a running kernel almost never pass the rules above. Real-world deleted yield from metadata is expected to be low; carving (Epic 3, Story 3.1) is the path for those files. The positive deleted-file tests model an inode that was not zeroed, for example after a crash before truncation, or from another ext implementation.
- **Htree:** gap mining is skipped inside the dx_root's `..` entry and inside dx_node blocks (an inode-0 entry spanning the block), so index bytes are never treated as deleted entries.
- **Live names that aren't UTF-8:** Linux names are arbitrary bytes. Rather than fail the scan or replace bytes silently, non-UTF-8 live names render with ASCII kept and other bytes escaped as `\xNN`. `rawRecord` keeps the original dirent bytes.
- **Live-metadata checks (fail-closed):** a directory whose size is not a positive multiple of the block size, holes or uninitialized extents in a directory, a live entry pointing at a mode-0 inode (except on a `needs_recovery` volume, see above), a revisited directory inode (cycle or hard-linked directory), nesting deeper than 2048 (`directoryDepthIsCapped`, `directoryCyclesAndHardLinkedDirectoriesTerminate`), and an extent inode on a volume without `extents` all throw `malformed`.
- **Bounds:** the extent depth is ≤ 5, with an exact depth decrease per level. Every live file's mapped plus metadata blocks are capped at the volume's block count. Block-map and extent-tree nodes use visited sets. There are at most 2^22 groups. Bitmap blocks use a small capped cache, and inode reads reuse a one-block cache. The limits live in `EXTLimits`; tests may lower them through `setLimits`.
- **Memory:** the live walk queues only (inode number, directory index, depth) per pending directory. Each directory reached is recorded once as (parent index, own name, last change), and a path is built only when a file is emitted, so queued state grows with the number of directories in the image, not with depth times count (`deepChainAndWideFanOutKeepQueuedStateLinear`). A deleted candidate keeps its 8 dirent header bytes and its name, not a raw copy; the exact entry bytes are rebuilt when it is emitted. Candidates are capped at 200,000 and 16 MiB of names. Past either cap, further entries are dropped, but an entry for an inode already kept still marks that inode as conflicting, so a dropped second name can't let a wrong one through (`candidateCapsBoundMemoryAndStillDetectConflicts`). The overlap check keeps at most 2,000,000 claimed ranges, and evaluation stops when that is reached.
- **Work:** live file mappings are cached per inode number (up to 1,000,000 runs plus tree blocks), so hard links are mapped once (`hardLinksAreMappedOnce`). Deleted-candidate work has a per-volume budget of 4 × blocks + 1,000,000 units: each mapping charges its block limit up front and is refunded what it did not use, and each bitmap check costs one unit. Once the budget is exhausted, the remaining candidates are skipped (`deletedWorkBudgetSkipsRemainingCandidates`).
- **Tests added in the review patch:** 64-bit descriptors with non-zero `_hi` halves and `s_blocks_count_hi` on a sparse 256 TiB virtual device (`sixtyFourBitHighHalvesAreRead`); 4 KiB blocks with `s_first_data_block = 0` and a final entry ending at the block end (`fourKiBBlocksWithFirstDataBlockZero`); a double-indirect mapping (`doubleIndirectBlockMapResolves`); uninitialized group bitmaps (`uninitializedGroupBitmapsSkipDeletedCandidates`); and a non-UTF-8 live name (`nonUTF8LiveNameIsEscaped`).
- **Branch baseline:** this worktree was created at `efbcc71` and fast-forwarded to `main` (`96f165f`, which contains this spec and the `c1b21a3` baseline) before implementation.
