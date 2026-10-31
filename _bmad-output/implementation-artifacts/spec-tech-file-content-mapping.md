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

## Implementation Notes

### EXT: Section C (EXT2/3/4)

- EXT: Runs are built from the same `EXTMapping` the parser already validated (live: `liveMapping`, so hard links still map once; deleted: the mapping `evaluate` checked against the free bitmaps, carried to emission rather than re-mapped). No second mapping pass, no new trust.
- EXT: Runs are clipped to the blocks `sizeBytes` needs (`ceil(size / blockSize)`). Preallocated or stale blocks past EOF are never part of the content; the last run may still exceed `sizeBytes` by less than one block, which `FileContentReader` truncates.
- EXT: Unmapped logical blocks (zero block-map pointers, extent gaps) and uninitialized extents become `deviceOffset: nil` holes. A mapping that ends before the size needs gets a trailing hole sized exactly to `sizeBytes`, so the runs always cover the file.
- EXT: Coalescing merges physically adjacent data runs and consecutive holes. A data run next to an uninitialized extent stays separate even when the blocks are physically adjacent, because the uninitialized one must read as zeros.
- EXT: Size-0 files are `.runs([])`, even when the inode still names blocks.
- EXT: Judgment call: an inode with `EXT4_ENCRYPT_FL` (0x800) is `.unmapped`. The superblock `encrypt` feature is already refused and deleted candidates with the flag are already skipped, but a hostile live inode could still carry it; its blocks would be ciphertext, so mapping them would hand preview/recovery the wrong bytes.
- EXT: Building the runs uses checked arithmetic; any overflow (not reachable after geometry validation) yields `.unmapped` instead of aborting the scan. A mapping whose runs are not in strictly increasing logical order (also not reachable) does the same.
- EXT: Inline data is unchanged: it is still refused as malformed in `mapping`.
