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

## Implementation Notes

Judgment calls made while implementing, each outside the frozen intent or resolving an ambiguity in it:

1. **Probe budget.** The frozen example bounds (≤ 64 MiB of header reads, ≤ 4096 probes) are inconsistent with each other and with the candidate set: 4 KiB-aligned probing across the first 64 MiB alone is 16,384 probes. `VolumeDiscovery` uses `maxProbes = 16384` and `maxProbeBytes = 64 MiB` (both injectable for tests). Probes run in two passes so the likeliest offsets spend the budget first: pass 1 (three quarters of the budget) takes every gap's own start, the classic first-partition sectors (LBA 34 and 63, which no 4 KiB or 1 MiB alignment reaches), 4 KiB steps across the first MiB after each known *or found* extent, and every MiB; pass 2 takes 4 KiB steps across the first 64 MiB. A hit's span is skipped, so a wiped table whose volumes abut costs one probe per volume. A probe is one or two 512-byte reads; the byte cap mainly bounds the header reads that follow a hit.
2. **Clamp vs. drop.** The frozen text both says "clamp to the device" and lists "exceeds the device" as implausible. A header whose length runs past the *device end* is clamped (a short image or an overwritten tail is a real recovery case; the parser then decides); one that runs into a *known extent* or an earlier hit is dropped. Zero or overflowing lengths are dropped.
3. **Damaged lost partitions don't stop the scan.** A lost partition is detected, not confirmed, and a stale header in a gap must never turn a previously working scan of a mapped device into `.error`. `ScanSession` contains `.malformed`/`.unsupportedFilesystem` from a lost extent's parser (files it emitted so far stay; mapped volumes and the sweep/carve of the lost extent itself are unaffected). I/O errors and cancellation still propagate. Mapped volumes keep the existing fail-closed behavior. Covered by `damagedLostPartitionStopsOnlyItsOwnParser`.
4. **Unsupported formats in lost space are still reported and swept.** A lost APFS/HFS+ extent (parsers pending in this branch) is announced, included in the sweep so the carver reads it, and its parser's `unsupportedFilesystem` is contained per note 3. Known partitions of pending formats keep the existing "skipped, not swept" behavior; this spec doesn't change it. A bare APFS volume superblock (`APSB`) has no container size, so `volumeLength` returns nil and it is dropped; `NXSB` uses `nx_block_count × nx_block_size`.
5. **Raw fallback scope.** The single `.raw` extent is returned only when there is no partition table (or an all-zero one) *and* no signature anywhere. A table whose partitions are all recognized-but-unsupported still answers `unsupportedFilesystem`, as before. Two existing tests changed accordingly: a 512-byte zero image and a 0x5a-filled image now complete with a raw sweep instead of erroring.
6. **"All results" labelling.** In the app, "All results" is the dashboard (the browser's back button). Lost-partition files are labelled there by the `LostPartitionsCard` (format, size, offset, recoverable count); the scoped browser leads its title with the partition ("Lost partition — exFAT, 64 KB · Pictures — 3 files"). No edit to `FileBrowserView.swift` was needed; in the unscoped all-files list, files from a lost partition are not visually tagged per row (same as files from any second volume today).
7. **Type-level no-write test lives in `SalvageTests`**, not DiskIO (DiskIO is off limits). `ReadOnlySourceTests` conforms `RawBlockReader` retroactively to a probe protocol whose `write(_:at:)` has a default implementation; the default is the witness only when the type declares no such method, which the test asserts against a reader prepared on `/dev/null`. The Core port's read-only shape is checked by compiling a conformer with only `read`.
8. **Candidates are announced up front**, all before any volume is scanned, so the card can appear while files stream in. `ScanViewModel` already collected them; no change there.
9. **File counts on the card** come from the existing aggregate pass (one extra dictionary increment per recoverable row, only when lost partitions exist) and respect the "Show system files" toggle like the tiles.
