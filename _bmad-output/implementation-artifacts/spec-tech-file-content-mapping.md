---
title: 'Map Discovered Files to Their On-Disk Bytes (FAT, NTFS, EXT)'
type: 'tech'
created: '2026-10-31'
status: 'ready-for-dev'
baseline_commit: '0654e86'
route: 'dispatch'
context:
  - '{project-root}/_bmad-output/planning-artifacts/architecture/architecture-DataRecoveryTool-2026-10-30/ARCHITECTURE-SPINE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Preview (1.9) and recovery (1.10) need a discovered file's actual bytes. Commit `113d279` added `RecoveredFile.content` (`FileContent`: `.unmapped`, `.resident(Data)`, `.runs([DataRun])`) and `FileContentReader`, but no parser fills in `content` yet.

**Approach:** Every parser sets `content` on every emitted file, both live and deleted.
- The runs are **device-absolute** byte ranges in file order. `deviceOffset == nil` marks a sparse hole.
- The runs must cover at least `sizeBytes`; `FileContentReader` truncates at `sizeBytes`.
- Use the mapping the parser already validated. Never invent a mapping.
- Where the bytes can't be mapped faithfully, use `.unmapped`. A wrong mapping is worse than none.

This work is split across three agents, one per section below. Each agent edits only its own parser files and tests.

## Boundaries & Constraints

**Always:**
- Coalesce physically adjacent runs.
- Bounds are already enforced by each parser: never emit a run outside the volume extent.
- Add tests that read files back through `FileContentReader(reader: ImageReader(data: image))` and compare with the bytes the test wrote. Cover fragmented, contiguous, empty and deleted files.

### Section A: FAT32 / exFAT (agent A). Files: `Parsers/FATVolume.swift`, new `Tests/SalvageCoreTests/FATContentTests.swift`
- **FAT32 live file:** follow the FAT chain. Each cluster becomes `heapOffset + (cluster-2)*clusterBytes` plus `extent.offset`.
- **exFAT live file:** NoFatChain means one contiguous run; otherwise follow the chain.
- **Deleted file (both formats):** the assumed contiguous run that the free-cluster check already validated.
- **Size-0 file:** `.runs([])`.

### Section B: NTFS (agent B). Files: `Parsers/NTFSVolume.swift`, `Parsers/NTFSRecord.swift`, `Tests/SalvageCoreTests/NTFSVolumeTests.swift`
- **Resident unnamed `$DATA`:** `.resident(value)`.
- **Non-resident `$DATA`:** `.runs` from the run list. LCN × clusterBytes + `extent.offset`; a sparse run (LCN nil) becomes `deviceOffset: nil`.
- **Compressed or encrypted streams** (attribute flags 0x0001 / 0x4000), or files with `$ATTRIBUTE_LIST`: `.unmapped`.
- **Initialized size below the real size:** the bytes past the initialized size are zeros. Express them as a trailing hole.

### Section C: EXT2/3/4 (agent C). Files: `Parsers/EXTVolume.swift`, `Tests/SalvageCoreTests/EXTVolumeTests.swift`
- **Mapping:** the existing `EXTMapping` becomes runs. Block × blockSize + `extent.offset`.
- **Holes:** sparse (unmapped) logical blocks and uninitialized extents become holes.
- **Out of scope:** inline data is already refused.

**Never:**
- No edits to `ScanEvent.swift`, `FileContentReader.swift`, `ScanSession.swift`, `VolumeDiscovery.swift`, or another section's parser.
- No app, DiskIO or CI changes.
- No writes.

</frozen-after-approval>

## Verification

- `swift test --package-path SalvageCore`
- `./scripts/check-core-boundary.sh`

## Implementation Notes — Section A (FAT32/exFAT)

- **Single source of truth for live runs.** `validateFile` now returns the coalesced device-absolute runs it built while claiming clusters, so the mapping is exactly the chain (or NoFatChain run) the parser validated and cross-link checked; no second chain walk.
- **Clusters chained past the size** are still claimed (cross-link detection is unchanged) but are not included in the runs; runs are cut to the file's bytes.
- **exFAT `ValidDataLength` < `DataLength`** (live and deleted): runs are cut at the valid length and followed by a trailing hole (`deviceOffset: nil`) up to the size, because exFAT defines bytes past the valid length as zeros and the clusters there may hold stale data. Not called out in the frozen section; mirrors the NTFS initialized-size rule.
- **Deleted files** map only the assumed contiguous run `[first, first + required)` that `freeRun` already proved free and in-heap. Deleted exFAT FAT-chained files remain limited to one cluster (existing rule), so their single run is also contiguous.
- **Size-0 files** (live or deleted, any first cluster) map to `.runs([])`.
- **Defensive fallback:** if the runs ever fail to cover the valid length (should be impossible after validation), the file is emitted `.unmapped` rather than with a partial mapping.
- Tests: `Tests/SalvageCoreTests/FATContentTests.swift` (15 tests) read every case back through `FileContentReader(reader: ImageReader(data:))`: fixture files, contiguous, fragmented out-of-order with coalescing, over-long chain, empty, deleted, deleted empty, VDL holes, and volumes placed at a non-zero partition offset.
