---
title: 'FAT32/exFAT: Skip a Damaged File Instead of Failing the Volume'
type: 'tech'
created: '2026-10-31'
status: 'done'
baseline_commit: 'd04d613'
route: 'dispatch'
context:
  - '{project-root}/_bmad-output/implementation-artifacts/spec-1-4-scan-a-fat32-exfat-device-with-live-progress.md'
  - '{project-root}/_bmad-output/implementation-artifacts/spec-1-6-recover-deleted-files-via-intact-metadata.md'
  - '{project-root}/_bmad-output/implementation-artifacts/deferred-work.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Deferred from Story 1.4 (blind-hunter #1). On damaged cards, which is the app's core use case, one bad file aborts the whole volume:
- a chain running past its declared size into another file's clusters raises "Cross-linked allocations";
- a cycle in one file's chain, a truncated chain, or a bad entry does the same.

All files not yet found on that volume are lost.

**Approach:** In `FATVolume`, separate **structural** damage from **per-file** damage.
- **Structural damage stays fail-closed:** boot sector, geometry, the FAT region, the root directory's own chain, the allocation bitmap, the up-case table.
- **Per-file damage:**
  - **Live files:** an allocation cycle, a truncated chain, a chain claiming clusters already owned, or an invalid first cluster means that file is **skipped** (not emitted), counted, and the scan continues.
  - **Cross-links:** both owners of a cross-linked cluster are untrustworthy. Skip the later one, and retract nothing already emitted. Validate a file's whole chain *before* emitting it (already done) and stop claiming at the declared size: clusters past the size that collide aren't an error for this file. Clusters past the size that collide with an earlier file are evidence the earlier file is suspect; record it in `skippedCount` with a reason.
  - **Directories:** a damaged subdirectory (cycle, bad chain, malformed entry set) means skip that subdirectory's subtree, count it, and continue with its siblings.
  - **Entries:** a live entry with malformed name encoding falls back to the 8.3 name when one exists (FAT32), otherwise it is skipped.
- Expose `FATVolume.skipped: [(path: String, reason: String)]`, capped at 1000 entries, plus a count. Another agent adds scan notices in parallel. Don't emit notices yourself; document the accessor in Implementation Notes so the lead can wire it.

## Boundaries & Constraints

**Always:**
- A skipped file must never be emitted with partial or wrong content.
- Deleted-entry handling (Story 1.6) is unchanged.
- Update the existing tests that asserted whole-volume failure for per-file damage (e.g. `crossLinkedFilesAndDirectoryAreRejected`, cycle and truncation tests). Each now expects the good files found, the bad one skipped, and `.completed`. Keep tests that assert structural damage fails.
- Add tests:
  - a chain running past its size into another file;
  - a cycle in one file among good siblings;
  - a broken subdirectory among good siblings, with its siblings still found;
  - the same three on exFAT.

**Never:** Edit only `SalvageCore/Sources/SalvageCore/Parsers/FATVolume.swift` and its tests (`ScanSessionTests.swift` FAT cases, `DeletedFileTests.swift`, `FATContentTests.swift`). No changes to `ScanSession.swift`; other agents are editing it.

</frozen-after-approval>

## Verification

- `swift test --package-path SalvageCore`
- `./scripts/check-core-boundary.sh`

## Implementation Notes

**Mechanism.** Per-file checks in `FATVolume` now throw a private `FATVolume.FileDamage(reason)` instead of `ScanError.malformed`. It is caught at three boundaries: a file entry (FAT32 short entry / exFAT set) → that file is skipped; a subdirectory popped from the traversal stack → that subtree is skipped; anything escaping to `scan()` (boot/geometry, the root directory's own chain, the allocation bitmap, the up-case table) is mapped back to `ScanError.malformed(reason)` and fails the volume as before. I/O errors and cancellation are never `FileDamage`, so they still propagate.

- **Live files:** the whole chain is walked and claimed before emit (unchanged), so a skipped file is never emitted. Cycles, truncated chains, invalid first/next clusters, clusters free in the exFAT bitmap and in-size cross-links skip the file.
- **Past the declared size:** clusters chained past a file's size are no longer claimed. They are noted in `tailOwners` and the walk stops when the tail reaches clusters another file owns or another tail already walked, so the total work stays bounded. A tail running into an earlier file's clusters, or a later file claiming a cluster in an earlier tail, flags the *earlier, already-emitted* file. FAT32 directories (which have no size) still claim their whole chain.
- **In-size cross-link:** the later claimant is skipped (`"Cross-linked allocations with <path>."`), and the earlier owner is flagged if it is a file. Nothing is retracted.
- **Directories:** a subdirectory's chain is validated and claimed before any of its entries is read, so a damaged subdirectory (cycle, bad or truncated chain, cross-link, shared with or looping back to another directory, invalid exFAT directory size) is skipped with its whole subtree and nothing in it gets emitted. Its siblings carry on.
- **Entries:** an entry that is damaged on its own (exFAT set checksum/stream/name encoding, a primary with fewer than 2 secondaries, a set cut short by the end marker, the chain end or a non-secondary entry, an unsupported critical primary, a FAT32 orphaned LFN run, an unusable name) is recorded and dropped, and the rest of the directory is still read. A FAT32 long name that fails validation falls back to the 8.3 name. Stray exFAT secondaries left behind by a dropped primary are ignored.
- Deleted-entry handling (Story 1.6) is untouched.

**Accessor for the lead (scan notices).** `FATVolume` is an actor exposing:
- `skipped: [(path: String, reason: String)]`, in discovery order, capped at `FATVolume.maxSkippedRecords` (1000);
- `skippedCount: Int`, the total including records past the cap.

There are two kinds of record. A skipped file or subtree is never emitted; directory records have reasons starting with `"Directory skipped with its contents: "`. A suspect record refers to a file that **was** emitted. Its reason mentions a cross-link or "runs past its size", and each file is flagged at most once. Paths are volume-relative (`/DIR/NAME`). An entry with no usable name is recorded as `<dir>/<entry at byte N>`, where N is the device-absolute byte offset.

Wiring: in `scanVolume` (`VolumeScanners.swift`), replace `case .fat: try await FATVolume(...).scan()` with something like:
```swift
case .fat:
    let volume = FATVolume(reader: reader, extent: extent, emit: found)
    do { try await volume.scan() } catch { await report(volume); throw error }
    await report(volume)
```
Here `report` reads `await volume.skippedCount` / `await volume.skipped` and emits the scan notice. Read both after `scan()` returns *or throws*: a structural failure late in a traversal still leaves valid records. Don't emit a notice when `skippedCount == 0`. I didn't touch `ScanSession.swift` or `VolumeScanners.swift`.

**Tests.** Updated tests that asserted whole-volume failure for per-file damage, so they now expect the good files, the bad one skipped and `.completed`:
- `ScanSessionTests`: `laterDamagedFileIsSkippedAndTheScanCompletes` (was `priorDiscoveriesSurviveLaterCorruption`), `crossLinkedFileAndDirectoryAreSkipped`, `activeBitmapSkipsFreeAndPartiallyAllocatedStreams`, `malformedFilenameEncodingsAreNotSilentlyReplaced` (exFAT half, plus an LFN-with-`/` fallback case), `corruptExFATEntryChecksumSkipsOnlyThatEntry`, `fileAllocationCycleIsSkipped`, `orphanedLongFilenameRunIsSkipped`, and the overlap case of `exFATUpcaseTableIsClaimedAgainstCrossLinks` (the table is claimed first, so the file is the later owner and is skipped; the truncated up-case case still fails).
- `boundedConsumerReceivesErrorAndFullQueueCancellationTerminates` now gets its error from an injected I/O failure, because a per-file cycle no longer produces one.
- New `structuralDamageStillFailsTheVolume` (root chain cycle, bad bitmap length).
- New in `FATContentTests`: past-size-into-another-file, damaged file among good siblings (cycle, truncated, invalid first cluster, in-size cross-link), and broken subdirectory among good siblings (chain cycle, directory pointing back at root, bad exFAT directory size), each on FAT32 and exFAT, plus the 1000-record cap.
- **Outside the listed files:** `LostPartitionTests.damagedLostPartitionStopsOnlyItsOwnParser` used a root entry-set checksum flip as its "damaged metadata", which is now per-entry and no longer stops the parser. That one line now corrupts the allocation bitmap length (structural damage) instead; the test's intent is unchanged.
