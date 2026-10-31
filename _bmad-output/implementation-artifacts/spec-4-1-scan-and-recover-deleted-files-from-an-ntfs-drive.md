---
title: 'Scan and Recover Deleted Files from an NTFS Drive'
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

**Problem:** FR-5 includes NTFS. Discovery already recognizes NTFS volumes by OEM ID (`VolumeDiscovery.format(at:)`) and routes them to `NTFSVolume`. That parser is a placeholder with `isImplemented = false`, so NTFS volumes are skipped today.

**Approach:**
- Implement a bounded, read-only NTFS parser in original MIT-licensed Swift (AD-2). Community format documentation and the MIT/Apache `ntfs` Rust crate may be read as reference; no code is copied and no dependency is added.
- The parser emits live and deleted files as `RecoveredFile` values, filling the format-neutral `SourceMetadata` fields:
  - `filesystem: .ntfs`
  - `recordOffset` = the MFT record's byte offset in the volume
  - `allocationStart` = the MFT record number
  - `rawRecord` = the fixed-up record bytes
  - `contiguous` = the `$DATA` attribute has a single data run
- Then set `isImplemented = true`.

## Boundaries & Constraints

**Always:**
- **Boot sector:** validate `0xAA55`, the OEM ID, bytes per sector (512–4096, power of two) and sectors per cluster. That includes the negative-exponent encoding of cluster sizes above 64K. Also validate total sectors fitting the extent, the `$MFT` cluster within the volume, and the clusters-per-MFT-record encoding (positive count, or a negative power of two).
- **Fixups:** apply the update-sequence fixup to every MFT record and index buffer. On a mismatch, an in-use record makes the volume throw `ScanError.malformed`; a not-in-use (deleted) record is skipped silently.
- **`$MFT` itself:** read record 0 and parse its non-resident `$DATA` runs, so a fragmented MFT is supported.
- **Bounds:**
  - Bound every run by the volume's cluster count.
  - Cap run-list length and the attribute count per record.
  - Reject overlapping or overflowing arithmetic with the existing `checkedAdd`/`checkedMultiply` helpers.
  - Every read goes through a `read()` limited to the extent, like `FATVolume.read`.
- **Attributes:** parse `$STANDARD_INFORMATION` (modified time, from FILETIME to `Date`), `$FILE_NAME` and `$DATA`.
  - Choose the Win32 or Win32+DOS name over the DOS-only one.
  - Size comes from `$DATA`: the resident length or the non-resident real size.
  - Files with multiple `$DATA` streams report only the unnamed stream.
  - `$ATTRIBUTE_LIST` (attributes spread across several records) may be followed if it is bounded. Otherwise skip that file and record the limitation in Implementation Notes; never emit a wrong size.
- **Paths:** build each path from the `$FILE_NAME` parent reference, verifying the parent's sequence number.
  - A deleted file whose parent record has been reused, or whose parent is missing or isn't a directory, goes under `/Orphaned Files/`.
  - Detect cycles in the parent chain and stop at a bounded depth.
  - Skip system metafiles (records 0–15, and names starting with `$` at the root).
- **Deleted files:** a record whose in-use flag (flags & 0x01) is clear but whose `FILE` signature and fixup are valid, and which has a `$FILE_NAME`, is emitted with `isDeleted: true`. If its `$DATA` runs point at clusters now marked used in `$Bitmap`, the data has probably been overwritten: skip it.
- Directories are not emitted as files. Compressed, encrypted or sparse files are emitted with correct metadata; extracting them is not this story's job.
- Update the routing tests in `ScanSessionTests.swift`, changing only the NTFS parts: remove the NTFS partition from `recognizedButUnimplementedVolumesAreSkipped`, and remove `"ntfs"` from `wholeDiskUnimplementedFormatIsUnsupported`'s arguments. Add a positive routing test in your own test file.

**Never:** No edits to `FATVolume.swift`, `EXTVolume.swift`, `ScanSession.swift`, `ScanEvent.swift`, `VolumeDiscovery.swift`, the app, DiskIO or CI. Other stories own those files and are running in parallel. No writes, no external dependencies, no journal (`$LogFile`) replay.

## I/O & Edge-Case Matrix

| Scenario | Input | Expected | Error handling |
|---|---|---|---|
| Live files, nested folders | Valid synthetic NTFS | Paths, sizes, modified times streamed; `.completed` | — |
| Deleted file, intact record, free clusters | in-use flag clear | Emitted `isDeleted`, original path | — |
| Deleted file, parent reused | Sequence number mismatch | `/Orphaned Files/name` | — |
| Deleted, clusters reused | `$Bitmap` marks them used | Not emitted | Skip |
| Fragmented `$MFT` | Multiple runs | All records reachable | — |
| Bad fixup, in-use record | — | Error, earlier discoveries kept | `malformed` |
| Corrupt boot sector or MFT outside volume | — | Explicit error, no empty success | `malformed` |
| Run-list overflow or cycle | — | Bounded termination | `malformed` |

</frozen-after-approval>

## Code Map

- `SalvageCore/Sources/SalvageCore/Parsers/NTFSVolume.swift`: the implementation. Keep the existing `init` and `scan()` signatures.
- You may add helper files `SalvageCore/Sources/SalvageCore/Parsers/NTFS*.swift`.
- Existing helpers: `Data.number(_:_:)` and `checkedAdd`/`checkedMultiply`/`signed` in `VolumeDiscovery.swift`, which you use but must not edit.
- Tests: a new `SalvageCore/Tests/SalvageCoreTests/NTFSVolumeTests.swift`. Build tiny synthetic NTFS images in Swift; macOS has no `mkntfs`. Reuse `ImageReader` and `scan` from `ScanSessionTests.swift`.

## Tasks & Acceptance

- [x] Boot sector and `$MFT` bootstrap with fixups.
- [x] Attribute parsing (`$SI`, `$FN`, `$DATA` resident and non-resident, run lists).
- [x] Path reconstruction with orphan handling.
- [x] Deleted-record detection with the `$Bitmap` check.
- [x] Set `isImplemented = true` and update the routing tests.
- [x] Synthetic-image tests covering the matrix.

**Acceptance criteria:**
- Given an NTFS device with deleted-but-not-overwritten files, when scanned, those files appear with their original filename, path and timestamp.
- Given an NTFS device, it appears in the same unified device list and scan flow.
- Given a corrupted or unsupported NTFS structure, the scan reports it rather than silently producing wrong results.

## Verification

- `swift test --package-path SalvageCore`
- `./scripts/check-core-boundary.sh`
- `xcodebuild -project Salvage.xcodeproj -scheme Salvage -configuration Debug -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build`

## Implementation Notes

Format references: community NTFS on-disk documentation (boot sector, FILE record, attribute and run-list layouts). Original Swift; no code copied, no dependency added. Code lives in `Parsers/NTFSVolume.swift` (scan, MFT streaming, paths, `$Bitmap`) and `Parsers/NTFSRecord.swift` (pure geometry, fixup, record and run-list parsing).

Judgment calls:
- **Two passes over the MFT.** Pass 1 indexes directories (live and deleted) and `$Bitmap`; pass 2 emits files in MFT order. An in-use record that fails its fixup or parse in pass 1 is remembered and reported when pass 2 reaches it, or when a file's parent chain passes through it, so discoveries before it are kept and no child is shown under a wrong or orphaned path. Damage to records 5 (root) or 6 (`$Bitmap`) fails immediately.
- **Deleted parents.** NTFS increments a record's sequence number when it frees the record. A parent matches when its sequence equals the reference, or when the parent is itself deleted and its sequence is the reference plus one. So a file deleted together with its folder keeps its original path. Anything else (reused, missing, or not a directory) goes under `/Orphaned Files/`. When the break is higher up the chain, the intact lower part is kept, e.g. `/Orphaned Files/Dir/file.txt`.
- **Live files with a broken parent chain** also go under `/Orphaned Files/` rather than failing the scan. A cycle or a chain deeper than 1024 is `malformed` for any record.
- **`$ATTRIBUTE_LIST` is not followed.** A file is emitted only when its unnamed `$DATA` is complete in the base record (VCN 0 extent whose runs cover the full allocated size). Otherwise it is skipped, so a wrong size is never emitted. If `$MFT` itself needs an attribute list, the scan reports `unsupportedFilesystem`. Extension records are never emitted on their own. A directory whose `$FILE_NAME` lives only in an extension record isn't indexed, so its children go under `/Orphaned Files/`. Hard links: the first name in the preferred namespace (Win32/Win32+DOS, then POSIX, then DOS) decides the path.
- **Names.** A `$FILE_NAME` with invalid UTF-16, an empty name, `/` or NUL is ignored rather than decoded lossily. If no usable name remains, the file is skipped. An in-use base record with no `$FILE_NAME` attribute at all (and no attribute list) is `malformed`.
- **Damaged deleted records.** A deleted record whose fixup or attribute/run-list structure is invalid is skipped silently. The same damage in an in-use record is `malformed`.
- **`contiguous`** is true only for exactly one non-sparse run, so resident files report `false`. Runs inside one attribute must not overlap. Cross-file overlap isn't tracked.
- **Record count** is the `$MFT` `$DATA` *initialized* size divided by the record size. Bytes beyond it were never written as records.
- **`$Bitmap` check** reads one cached page (up to 64 KiB) at a time. Any used cluster in any non-sparse run of a deleted file skips it.
- **Index buffers** (`INDX`) are not read: paths come from `$FILE_NAME` parent references. The shared `applyNTFSFixup` handles them and is tested on one.
- **Bounds:** at most 512 attributes per record and 16384 runs per attribute. Cluster size is capped at 2 MiB (negative-exponent encodings up to 2^12 sectors). MFT records must be 512 B to 64 KiB, a power of two.
- **Routing tests.** In `ScanSessionTests.swift`, the NTFS partition was removed from `recognizedButUnimplementedVolumesAreSkipped`, so the ext partition moved up to start right after the exFAT one. `"ntfs"` was removed from `wholeDiskUnimplementedFormatIsUnsupported`'s arguments; its body still has an `ntfs` branch, left in place to keep the diff minimal. The positive routing test is `NTFSRoutesThroughDiscoveryWholeDiskAndPartitioned` in `NTFSVolumeTests.swift`.
- The worktree branch was fast-forwarded from `efbcc71` to `main` (`96f165f`) before starting, because the spec and its `c1b21a3` baseline weren't on the branch.
