---
title: 'Discover a Lost Partition and Recover Files from It (Stories 3.3 + 3.4)'
type: 'feature'
created: '2026-10-31'
status: 'done'
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

1. **Probe budget** (revised in review patch P3). The frozen example bounds (≤ 64 MiB of header reads, ≤ 4096 probes) are inconsistent with the candidate set (4 KiB probing of the first 64 MiB alone is 16,384 probes) and can't cover a large disk. `VolumeDiscovery` uses `maxProbes = 524,288` and `maxProbeBytes = 512 MiB` (every byte the search requests is counted through a wrapping reader), both injectable. Two passes in device order: the **fine** pass runs first and in full — every gap's own start, LBA 34 and 63, 4 KiB steps across the first 64 MiB and across the first MiB after each known or found extent; then the **coarse** pass walks every MiB to 64 GiB and every 8 MiB beyond (8 MiB is the documented granularity past 64 GiB: 1 MiB end to end on 2 TB would be 2M probes). A probe is one or two 512-byte reads, so a 2 TB device is about 312k probes and ~320 MB of reads, inside the budget. A hit's span is skipped. When the budget, the failure limit (note 10) or the candidate cap (note 12) stops the search, `Result.probesTruncated` is true, `searchedBytes` says how far it got, and a plain-language warning is recorded ("The search for lost partitions was limited to the first N GB of the device."). Surfacing that in the dashboard is deferred (deferred-work.md): `ScanEvent` is closed (AD-11) and no non-hacky route exists today.
2. **Clamp vs. drop.** The frozen text both says "clamp to the device" and lists "exceeds the device" as implausible. A header whose length runs past the *device end* is clamped (a short image or an overwritten tail is a real recovery case; the parser then decides); one that runs into a *known extent* or an earlier hit is dropped. Zero, overflowing (`offset + length` checked with `addingReportingOverflow`; a crafted exFAT VolumeLength near 2^54 sectors used to trap) or sub-64 KiB lengths are dropped.
3. **Damaged lost partitions don't stop the scan.** A lost partition is detected, not confirmed, and a stale header in a gap must never turn a previously working scan of a mapped device into `.error`. `ScanSession` contains `.malformed`, `.unsupportedFilesystem` **and `.io`** from a lost extent's parser: files it emitted so far stay, other volumes are unaffected. After a metadata failure the lost extent is still swept (and carved); after an I/O failure nothing more is read from it. An I/O error in a lost extent's sweep ends that extent's sweep only. Device removal, permission errors and cancellation still propagate. Mapped volumes keep the existing fail-closed behavior, I/O errors included. Covered by `damagedLostPartitionStopsOnlyItsOwnParser`, `unreadableLostExtentStopsOnlyItselfAndTheScanCompletes`.
4. **Lost APFS/HFS+ extents** are announced, their parser failures contained per note 3, and swept for the carver. With the APFS and HFS+ parsers and the signature carver all implemented, the earlier "unsupported parser" special case is gone: every lost extent is swept unless unreadable. (A rule "don't sweep an unparsed lost extent when there is no carver" was considered; `SignatureCarver.isImplemented` is true in the merged tree, so it would be dead code and was not added.) A bare APFS volume superblock (`APSB`) has no container size, so `volumeLength` returns nil and it is dropped; `NXSB` uses `nx_block_count × nx_block_size`. Covered by `lostAPFSAndHFSPlusAreAnnouncedContainedAndSwept`.
5. **Raw fallback scope.** The single `.raw` extent is returned only when there is no usable partition table (none, all-zero, or damaged per note 11) *and* no signature anywhere. A table whose partitions are all recognized-but-unsupported still answers `unsupportedFilesystem`, as before. Existing tests changed accordingly: a 512-byte zero image and a 0x5a-filled image complete with a raw sweep instead of erroring.
6. **"All results" labelling.** In the app, "All results" is the dashboard (the browser's back button). Lost-partition files are labelled there by the `LostPartitionsCard` (format, size, offset, file counts); the scoped browser leads its title with the partition ("Lost partition — exFAT, 64 KB · Pictures — 3 files"). No edit to `FileBrowserView.swift` was needed; in the unscoped all-files list, files from a lost partition are not visually tagged per row (same as files from any second volume today).
7. **Type-level no-write test lives in `SalvageTests`**, not DiskIO (DiskIO is off limits). `ReadOnlySourceTests` conforms `RawBlockReader` retroactively to a probe protocol whose `write(_:at:)` has a default implementation; the default is the witness only when the type declares no such method, which the test asserts against a reader prepared on `/dev/null`. The Core port's read-only shape is checked by a conformer with only `read` that is also a probe conformer, whose write call reaches the default witness (the earlier `conformers.count == 2` assertion was vacuous and is gone). The suite is serialized because both tests share the probe counter.
8. **Candidates are announced after their own parser finishes** (revised in P3; previously all were announced before any scanning). The candidate's `formatName` gets a " (damaged)" suffix when its parser stopped part-way (metadata or I/O), so the card says so. Announce-before-scan had no consumer (`ScanViewModel` only collects candidates for the dashboard, built after the scan), so nothing was lost.
9. **File counts on the card** come from the existing aggregate pass (one extra dictionary increment per row, only when lost partitions exist) and respect the "Show system files" toggle like the tiles. A partition whose files are all unrecoverable or hidden stays enabled and says so ("2 files can't be recovered", "No recoverable files, 1 system file hidden"), so its scoped browser is reachable; only a partition with no files at all is disabled.
10. **Probe I/O errors are contained.** A probe whose read fails with `.io` is skipped and counted (`Result.failedProbes`); 64 consecutive failures (`maxConsecutiveProbeFailures`) end the search, marked truncated. Reads of mapped partitions' headers during discovery still propagate. Covered by `unreadableGapIsSkippedAndTheMappedVolumeStillScanned`.
11. **A damaged partition table is searched, not refused.** Any `.malformed` from `partitions(boot)` (GPT header/table CRC, geometry, overlapping or out-of-device entries, extended or hybrid maps) makes discovery treat the table as absent: nothing is known and the whole device is searched. The reason is recorded in `VolumeDiscovery.Result.warnings`; `ScanSession` emits nothing extra (AD-11). Three ScanSessionTests changed from fail-closed to search-anyway: `GPTPartitionWithChecksumsScansWithinExtent` (corrupt entry array → same volume found as lost), `invalidGPTChecksumIsIgnoredAndTheDeviceSearched` (was `invalidGPTChecksumFails`), and `MBRPartitionIsBounded` (an entry past the device end; the volume sits at sector 1, which no probe alignment reaches, so the scan completes with a raw sweep and the partition is never read past the end). New: `damagedGPTHeaderIsReportedAndTheVolumeStillFound`, `damagedPartitionTableIsIgnoredAndTheDeviceSearched`.
12. **Candidate cap and complexity.** At most 256 lost volumes per device (`maxCandidates`); a header under 64 KiB is dropped. Found extents are kept sorted by sorted insertion, so containment and overlap checks are binary searches (O(log n) per probe). The card is a `LazyVStack` capped at 50 rows (`lostPartitionRowLimit`) with an "and N more lost partitions" line.
