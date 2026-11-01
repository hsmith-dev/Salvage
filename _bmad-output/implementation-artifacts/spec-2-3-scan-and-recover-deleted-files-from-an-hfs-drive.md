---
title: 'Scan and Recover Deleted Files from an HFS+ Drive'
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

**Problem:** FR-5 includes HFS+ (older Mac drives and Time Machine backups). Discovery recognizes "H+"/"HX" at offset 1024 and routes to `HFSPlusVolume`, a placeholder with `isImplemented = false`.

**Approach:** A bounded, read-only HFS+/HFSX parser in original Swift from Apple's public TN1150, emitting live and deleted regular files with name, path, timestamp and content mapping. Validate against a real `hdiutil create -fs HFS+` image (no sudo) with known live and deleted files.

## Boundaries & Constraints

**Always:**
- **Volume header** (offset 1024, big-endian): signature, version (4 or 5), `blockSize` (512–1 MiB power of two), `totalBlocks` fitting the extent, the fork data of the catalog, extents overflow and allocation files. Reject HFS wrapper volumes ("BD" at 1024) with `unsupportedFilesystem`.
- **B-trees:** parse header node (node size 512–32 KiB, root, leaf links), walk leaves via `fLink` with a visited set and a node-count bound; validate record offsets against the node. Catalog keys: parent CNID + HFS Unicode name (UTF-16BE, decomposed; present as precomposed NFC). HFSX case-sensitive flag is informational.
- **Files:** catalog file records: data fork size and the first 8 extents; **extents overflow B-tree** for more (bounded). Build paths from parent CNIDs with cycle and depth bounds. Emit regular files only (skip folders, symlinks, hard-link indirect nodes under `␀␀␀␀HFS+ Private Data` beyond resolving hard-link files to their indirect node). Timestamps: HFS epoch (1904-01-01 UTC) seconds → `Date`; `contentModDate`.
- **Content:** data fork extents → device-absolute `DataRun`s (`extent.offset + startBlock*blockSize`), truncated at logical size. Resource forks are not emitted. Compressed files (`UF_COMPRESSED` in `bsdInfo.ownerFlags` with decmpfs attribute) → `.unmapped`, noted.
- **Deleted files (best effort, never wrong):** HFS+ deletes remove the catalog record and free the blocks, leaving no catalog trace. Recover from **the journal** (`journalInfoBlock` → journal buffer → transaction blocks that contain older catalog leaf nodes) and from **unused space inside live catalog nodes** (records past `numRecords` that still contain valid catalog file records). A candidate is emitted `isDeleted: true` only if its extents are valid, within the volume, **free in the allocation file bitmap**, and not overlapping another candidate. Bounded work budget per volume. If the journal is absent or unreadable, skip journal recovery and note it.
- Bounds and checked arithmetic as in the other parsers; live corruption fail-closed, candidates skipped.
- Set `isImplemented = true`; update `hfsPlusAndHfsxAreRecognised` in `ScanSessionTests.swift` (that test only) and add positive routing tests in your own file.

**Never:** No edits to other parsers, `ScanSession.swift`, `ScanEvent.swift`, `VolumeDiscovery.swift`, `VolumeScanners.swift`, `Carving/`, the app, DiskIO or CI. No external dependencies. No writes.

## I/O & Edge-Case Matrix

| Scenario | Input | Expected | Error handling |
|---|---|---|---|
| Real hdiutil HFS+ image, live nested files | — | Paths, sizes, mtime; byte-identical content; `.completed` | — |
| File with > 8 extents | fragmented | All extents via overflow tree | — |
| Deleted file from journal / stale node records, blocks free | — | Emitted `isDeleted`, byte-identical | — |
| Deleted, blocks reused | — | Not emitted | Skip |
| HFS wrapper ("BD") | — | `unsupportedFilesystem` | — |
| Bad header / B-tree cycle / oversized node | crafted | `malformed`, bounded | — |

</frozen-after-approval>

## Code Map

- `SalvageCore/Sources/SalvageCore/Parsers/HFSPlusVolume.swift` (keep `init`/`scan()` signatures); you may add `Parsers/HFSPlus*.swift`.
- Tests: new `SalvageCore/Tests/SalvageCoreTests/HFSPlusVolumeTests.swift` (synthetic images for hostile cases; real `hdiutil` images for the end-to-end case, skipping cleanly if unavailable; detach in teardown).

## Verification

- `swift test --package-path SalvageCore`
- `./scripts/check-core-boundary.sh`
- `xcodebuild -project Salvage.xcodeproj -scheme Salvage -configuration Debug -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build`

## Implementation Notes

- **Files:** `Parsers/HFSPlusVolume.swift` (actor; `init`/`scan()` signatures unchanged, `isImplemented = true`), `Parsers/HFSPlusStructures.swift` (on-disk structures, fork map, node parsing, limits, stats), `Parsers/HFSPlusJournal.swift` (journal walk). Tests in `Tests/SalvageCoreTests/HFSPlusVolumeTests.swift`: 22 synthetic-image tests plus 3 real-image tests built with `hdiutil` in a temporary directory (attached only while populated, detached in a `defer`-style step, directory removed; skipped via `.enabled(if:)` when `hdiutil` cannot create and attach an image). `hfsPlusAndHfsxAreRecognised` in `ScanSessionTests.swift` now expects the signature-only stub to reach the parser and fail as `malformed` (empty header), not `unsupportedFilesystem`.
- **Empirical check against TN1150:** a real `hdiutil create -fs HFS+J` image confirmed the journal is in the creating system's byte order (little-endian here, `endian` marker 0x12345678), `bnum` is in `jhdr_size` sectors (512) relative to the volume, the block list header checksum covers its first 32 bytes with the checksum field zeroed, and `binfo[0]` is a sequence-number slot rather than a data block. Modern macOS zeroes the slack of a catalog node when a record is removed, so on real volumes the journal (older copies of catalog leaf nodes) is the productive source; node slack and freed nodes still work and are covered synthetically.
- **Live walk:** two passes over the catalog leaf chain (`firstLeafNode` → `fLink`, visited bitmap, every node must be a height-1 leaf). Pass 1 collects folders (CNID → parent, name), the `␀␀␀␀HFS+ Private Data` folder's CNID, and which leaf holds each `iNodeNNN` record; pass 2 emits files. Index nodes are not descended, so key ordering is not verified; a duplicate folder CNID, an unknown record type, a broken parent chain, a chain deeper than `maxPathDepth` (2048), invalid UTF-16 in a live name, or a "/" in a catalog name is `malformed`.
- **What is emitted:** regular files (`fileMode & S_IFMT == S_IFREG`, or mode 0 for records written without BSD info). Skipped: folders, symlinks, directory hard-link aliases (`fdrp`/`MACS`), the hidden `.journal`/`.journal_info_block` files (`jrnl`/`hfs+`), block/char devices, and the indirect-node files themselves. A hard link (`hlnk`/`hfs+`) is emitted under its own name and path with the indirect node's size, modification time, fork and CNID (`allocationStart`); `rawRecord` is the link record followed by the indirect node's record. A link whose indirect node is missing is skipped and counted (`stats.unresolvedHardLinks`), not failed.
- **Names:** decoded from UTF-16BE and presented precomposed (`precomposedStringWithCanonicalMapping`). Catalog colons are kept as ":" (the POSIX layer shows them as "/"); NULs are allowed because the private-data folder name contains them. The HFSX case-sensitivity flag is read into the tree header and otherwise unused.
- **Content:** data fork extents (record plus extents-overflow records keyed by file ID and first logical block, loaded once from the overflow tree's leaf chain, capped at `maxOverflowRecords`) → device-absolute runs, coalesced, clipped to the logical size; a size-0 file is `.runs([])`. Extents shorter than the size, outside the volume, or a missing overflow record are `malformed` for live files; if the overflow tree hit its cap, affected files are `.unmapped` instead. `UF_COMPRESSED` files are `.unmapped`; their size comes from the inline `com.apple.decmpfs` header (read once from the attributes tree, little-endian `uncompressed_size`), falling back to the data fork's logical size (usually 0) when no attribute is found. An unreadable attributes tree is noted in `stats.notes`, not failed, because it only supplies sizes. Resource forks are never emitted.
- **Deleted candidates** come from three places: the journal, catalog nodes outside the live leaf chain that still parse as leaves (freed nodes), and the slack between a live node's last record and its offset table (scanned at 2-byte stride for an intact key + 248-byte file record). Folder records found the same way become fallback parents for paths only when no live folder has that CNID. A candidate must be a regular, non-link, non-compressed file with size > 0, CNID in `16..<nextCatalogID`, a parent that is not root's parent or the private-data folder, extents that are non-overlapping, inside the volume and that account for every block the record claims (`extentBlocks == totalBlocks`, so a deleted file that needed overflow records is skipped rather than mapped partially). One candidate per CNID is kept: the latest `contentModDate`; copies with equal times that disagree are ambiguous and skipped; a CNID that is still live is skipped. Then every block must be free in the allocation bitmap and no two accepted candidates may share a block (both are dropped). Caps: 100,000 candidates / 64 MiB of record bytes, 200,000 stale folders, work budget `4 × totalBlocks + 1,000,000` bitmap checks and stale nodes examined (`stats.deletedBudgetExhausted` when hit).
- **Recovery is disabled** (live scan still runs, `stats.deletedRecoveryDisabled` says why) when the volume header's `kHFSCatalogNodeIDsReusedBit` is set (CNIDs may now point at different folders) or when the journal header's `start != end` (unreplayed transactions mean the bitmap may be stale). A journal that is absent, external, uninitialized, outside the volume, larger than 1 GiB, or with a bad magic/endian/header is skipped and recorded in `stats.journal` (`"absent"`, `"unreadable: …"`, `"skipped: …"`); stale-node and slack recovery still proceed in that case.
- **Journal walk:** every `jhdr_size`-aligned position in the buffer is probed for a block list header (`max_blocks`, `num_blocks`, `bytes_used`, checksum and the sum of block sizes must all agree), so stale transactions past `end` are harvested as well as current ones. Blocks whose `bnum × jhdr_size` lands on a node boundary inside the catalog file's extents and whose size is a multiple of the node size are parsed as leaf nodes; wrap-around at the end of the buffer is handled; reads go through a two-chunk (1 MiB) cache. Both byte orders are supported and tested.
- **`recordOffset`** is device-absolute: the record's key inside the catalog node for live files, or its position inside the journal buffer / stale node for deleted ones. `allocationStart` is the CNID.
- **Real-image coverage:** nested live files, hard links and symlinks (non-journaled image); a 12-extent file produced by filling a journaled 16 MiB image, freeing single blocks and writing into the holes (8 catalog extents + 4 overflow); three deleted files (one in a deleted folder) recovered byte-identical from the journal, while a deleted file whose blocks were reallocated by a filler is not emitted.
