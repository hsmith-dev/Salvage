---
title: 'Discover a Lost Partition and Recover Files from It (Stories 3.3 + 3.4)'
type: 'feature'
created: '2026-10-31'
status: 'ready-for-dev'
baseline_commit: '4d050bd'
route: 'dispatch'
context:
  - '{project-root}/_bmad-output/planning-artifacts/architecture/architecture-DataRecoveryTool-2026-10-30/ARCHITECTURE-SPINE.md'
  - '{project-root}/_bmad-output/planning-artifacts/ux-designs/ux-DataRecoveryTool-2026-10-31/EXPERIENCE.md'
  - '{project-root}/_bmad-output/planning-artifacts/ux-designs/ux-DataRecoveryTool-2026-10-31/mockups/scan-results-dashboard.html'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** FR-9/FR-10: a disk whose partition table is missing or damaged still holds filesystems. Today `VolumeDiscovery` throws `unsupportedFilesystem` when no partition table or no recognizable volume is found, and gaps between partitions are never examined.

**Approach:**
- **Discovery (3.3):** in `VolumeDiscovery`, after normal partition parsing (or when it fails), search the **unallocated space** (gaps between known extents, and the whole device when no table or no supported volume exists) for filesystem signatures using the existing `format(at:length:)` detector at aligned candidate offsets (every 1 MiB, plus 4 KiB-aligned probing in the first 64 MiB and immediately after each known extent; bounded total probes). For each hit, derive the volume's length from its own metadata (FAT BPB total sectors, NTFS total sectors, ext blocks count × block size, APFS `nx_block_count`, HFS+ `totalBlocks`) via a new `volumeLength(format:at:)` helper that reads only the header; clamp to the device; reject overlaps with known extents or with each other (earlier wins); return them as additional `VolumeExtent`s flagged `isLost: true`.
- **Reporting:** `ScanSession` emits `.lostPartitionFound(LostPartitionCandidate(offset:, sizeBytes:, formatName:))` for each lost extent before scanning it, then scans and sweeps it exactly like a normal extent (metadata parsers + carving). Files from a lost partition carry `sourceMetadata.volumeOffset == candidate.offset`, which is how the UI groups them.
- **Never write (3.4):** no code path anywhere writes a partition table; the only output is file copies through the existing recovery flow. Add a test asserting `BlockReader` conformers in DiskIO still expose no write method (type-level), and grep-based CI is unchanged.
- **Fallback for fully damaged media:** if nothing is recognized anywhere, return one `.raw` extent spanning the device so the sweep and carver still run, and emit no `.completed`-with-nothing lie: completion is honest, with carved files or none.
- **UI:** a `LostPartitionsCard` on the dashboard (new file), visually and positionally distinct from the bucket grid, listing each lost partition (format, size, offset) with file counts; clicking opens the File Browser scoped to that partition's files. Scoping is a `volumeFilter: Int64?` on `ResultsViewModel` (minimal additive edit). Lost-partition files never appear inside the mounted-volume results list when a card is selected, and the "All results" view labels them.

## Boundaries & Constraints

**Always:** Probing is bounded (cap probes and bytes read; e.g. ≤ 64 MiB of header reads per device, ≤ 4096 probes) and cancellation-aware. A candidate whose header geometry is implausible (length 0, exceeds the device, overlaps) is dropped. Known extents always take precedence. Checkpoint fingerprints include lost extents (they're just extents). Tests: a device with no partition table and a FAT volume at 1 MiB; an MBR whose entry was zeroed; two candidates overlapping (one kept); a whole-garbage device (one `.raw` extent, `.completed`, no files); a lost APFS/HFS+/NTFS/ext header each giving the right length.

**Never:** No edits to any `Parsers/*Volume.swift` or `APFSContainer.swift`, `Carving/`, `RecoveryConfidence.swift`, `FileBrowserView.swift` (another agent owns it; the scoped view is reached via `ResultsViewModel.volumeFilter` which the browser already filters through if you route it via the existing category/filter pipeline — if a one-line hook in `FileBrowserView` is unavoidable, make it a single line and note it), DiskIO, or CI. You own `VolumeDiscovery.swift`, `VolumeScanners.swift` (only to add `isLost` plumbing if needed), `ScanSession.swift`, `ResultsDashboardView.swift` (card insertion), `ResultsViewModel.swift` (additive `volumeFilter`), `ScanViewModel.swift` (read `lostPartitions`).

## I/O & Edge-Case Matrix

| Scenario | Input | Expected |
|---|---|---|
| No partition table, FAT volume at 1 MiB | synthetic | `.lostPartitionFound` (exFAT/FAT32, right size), files found, `.completed` |
| MBR entry zeroed, volume intact | synthetic | Lost partition found at the old offset |
| Gap between partitions holding an NTFS header | synthetic | Found, scanned if implemented |
| Overlapping candidates | synthetic | First kept, second dropped |
| Garbage device | random | One `.raw` extent; `.completed`; carver runs |
| Candidate overlapping a known extent | synthetic | Dropped |

</frozen-after-approval>

## Code Map

- `SalvageCore/Sources/SalvageCore/Parsers/VolumeDiscovery.swift` (gap search, `volumeLength`), `VolumeExtent.isLost`, `ScanSession.swift` (emit candidates; include lost extents in fingerprint/sweep).
- App: new `Salvage/Views/LostPartitionsCard.swift`; additive edits to `ResultsDashboardView.swift`, `ResultsViewModel.swift`, `ScanViewModel.swift` as above.
- Tests: `SalvageCore/Tests/SalvageCoreTests/LostPartitionTests.swift`; `SalvageTests/ResultsViewModelTests.swift` additions. Regenerate the project with `xcodegen generate` if you add app files.

## Verification

- `swift test --package-path SalvageCore`
- `swift test --package-path SalvageDiskIO`
- `./scripts/check-core-boundary.sh && ./scripts/check-no-network.sh`
- `xcodebuild -project Salvage.xcodeproj -scheme Salvage -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:SalvageTests test`
- `xcodebuild -project Salvage.xcodeproj -scheme Salvage -configuration Debug -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build`
