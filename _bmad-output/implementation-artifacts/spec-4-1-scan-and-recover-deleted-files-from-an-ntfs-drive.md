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

- [ ] Boot sector and `$MFT` bootstrap with fixups.
- [ ] Attribute parsing (`$SI`, `$FN`, `$DATA` resident and non-resident, run lists).
- [ ] Path reconstruction with orphan handling.
- [ ] Deleted-record detection with the `$Bitmap` check.
- [ ] Set `isImplemented = true` and update the routing tests.
- [ ] Synthetic-image tests covering the matrix.

**Acceptance criteria:**
- Given an NTFS device with deleted-but-not-overwritten files, when scanned, those files appear with their original filename, path and timestamp.
- Given an NTFS device, it appears in the same unified device list and scan flow.
- Given a corrupted or unsupported NTFS structure, the scan reports it rather than silently producing wrong results.

## Verification

- `swift test --package-path SalvageCore`
- `./scripts/check-core-boundary.sh`
- `xcodebuild -project Salvage.xcodeproj -scheme Salvage -configuration Debug -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build`
