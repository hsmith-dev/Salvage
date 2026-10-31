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
