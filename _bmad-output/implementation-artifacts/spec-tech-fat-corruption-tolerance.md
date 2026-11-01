---
title: 'FAT32/exFAT: Skip a Damaged File Instead of Failing the Volume'
type: 'tech'
created: '2026-10-31'
status: 'ready-for-dev'
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
