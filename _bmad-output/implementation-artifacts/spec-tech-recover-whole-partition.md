---
title: 'Recover All Files from a Partition'
type: 'feature'
created: '2026-10-31'
status: 'ready-for-dev'
baseline_commit: 'e226518'
route: 'dispatch'
context:
  - '{project-root}/_bmad-output/implementation-artifacts/spec-1-10-recover-selected-files-to-a-safe-destination.md'
  - '{project-root}/_bmad-output/implementation-artifacts/spec-3-3-3-4-discover-and-recover-lost-partitions.md'
  - '{project-root}/_bmad-output/planning-artifacts/ux-designs/ux-DataRecoveryTool-2026-10-31/EXPERIENCE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** The user asked to "recover a full partition onto a new drive" and chose *Recover all its files*. One action copies every recoverable file from one partition to a folder on another drive, keeping the folder structure. Today the user must tick files by hand, and nothing in the results names partitions other than lost ones.

**Approach:**
1. **Partitions in the results.** After a scan, the dashboard gets a **Partitions** section, listing:
   - Each mapped volume that produced files, as one row. Name it from the device tree when possible, matching the partition by its start offset, e.g. "Photos (exFAT), 63.8 GB". Otherwise use the format name and offset.
   - Lost partitions, which keep their existing card.
   - Each row shows: recoverable files count, of which deleted, of which reconstructed.
   - Each row has a **Recover all files…** button.
   - Reconstructed (carved) files count toward the partition whose extent contains their offset. Files outside every partition, such as a raw whole-device sweep, appear under "Unpartitioned space".
2. **Offsets.** To name mapped partitions, `DevicePartition` gains `offsetBytes: Int64?`. It is read from the IOMedia `Base` property or the DA description in `DeviceTree.swift`; nil when unknown. Mapped volumes in the scan carry their start offset in `RecoveredFile.sourceMetadata.volumeOffset`. Match on equality; if nothing matches, use the fallback name.
3. **Recover all.** The button opens the existing `RecoverySheet` with:
   - **files:** every *recoverable* file (`!isUnmapped`) whose `volumeOffset` matches, live **and** deleted. Reconstructed files are included only via a checkbox "Include reconstructed files (N)", **off by default** because they can be partial and have generated names.
   - **root folder name:** "<partition name> (recovered <date>)" instead of the device name. Add an optional `rootName:` parameter to `RecoverySheet` and `RecoveryCoordinator`; existing callers are unchanged.
   - **System-file toggle:** follows the dashboard's current "Show system files" setting.
   - **Deleted files:** go into the same structure, with the existing collision handling; their names are kept.
   - **Live progress** in the sheet, as today. The summary says "Recovered N of M files from Photos (exFAT)".
4. **Safety (unchanged rules, explicitly re-tested):**
   - The destination must not be on the source drive (`DestinationSafety`), using the existing red banner.
   - Recovery writes only files under the chosen folder; nothing writes to any disk device.
   - **Space check:** before starting, compare the selected bytes to the destination's free space (`URLResourceValues.volumeAvailableCapacityForImportantUsage`). If short, say so plainly and let the user continue or cancel. Per-file disk-full failures are still reported as today.
5. **Device tree tie-in.** In the sidebar, partition rows stay informational, but once a scan of that drive has finished, a partition row's context menu offers "Recover all files…". It opens the same flow.

## Boundaries & Constraints

**Always:**
- Reuse `RecoveryCoordinator`. Keep its path safety, no-overwrite and per-file results.
- Tests:
  - files grouped by partition, including carved files by containment and the unpartitioned bucket;
  - recover-all selects exactly the right files, with reconstructed excluded by default and included with the toggle;
  - the root name;
  - the free-space warning;
  - the destination-on-source block for this flow;
  - partition naming by offset with fallback;
  - the context-menu action is only available after a scan of that drive.

**Never:**
- No raw-device writes, no imaging, no change to the read-only helper.
- Don't edit parsers, carving, `ScanSession` or the helper.
- Other agents are working in parallel:
  - The UI-test agent adds one-line `.accessibilityIdentifier`s and a DEBUG fixture hook in `ContentView.swift` / `SalvageApp.swift`; don't edit those two files beyond what this feature needs, keeping it to minimal, separate lines.
  - The performance agent may edit `ResultsViewModel.swift`; keep your changes there additive, as separate methods/properties.

</frozen-after-approval>

## Implementation Notes

- **Offsets.** The DiskArbitration description carries no offset (checked on an attached GPT image), so `offsetBytes` comes from the IOMedia `Base` property: `ioMediaBaseOffset(_:)` in `DeviceTree.swift`, read per slice by `DeviceWatcher.readDiskDescriptions` into `RawDiskDescription.baseOffset`. An APFS store partition gets its container's offset; volumes inside a container stay nil, because their `Base` is relative to the synthesized container disk and their files carry the store's offset. A negative or missing `Base` is nil.
- **Grouping** (`Salvage/ViewModels/PartitionSummary.swift`, `PartitionGrouping`). Metadata files group by `volumeOffset`. A carved file's `volumeOffset` is the start of the sweep extent it came from, and the sweep extents are the volumes, so a carve whose `volumeOffset` names a known volume (one with metadata files, a lost partition, or a device-tree offset) lies inside that volume. Any other carve, such as a raw whole-device sweep, is placed by whether its start (`recordOffset`) falls in a known extent: lost partitions and device-tree partitions with sizes, innermost first. Otherwise it goes under "Unpartitioned space". Counts and the recover-all selection follow "Show system files". Unmapped files are never counted or selected.
- **Naming.** A device-tree match gives "Photos (exFAT)". The row title adds the size ("Photos (exFAT), 63.8 GB"). An unnamed partition is just its format, never "exFAT (exFAT)". With no match, the name is "exFAT volume at 1 MB" ("exFAT volume (whole drive)" at offset 0). A lost partition is "Lost partition — FAT32", and the existing Lost partitions card is unchanged.
- **ResultsViewModel.swift is untouched.** The additions are an extension in `PartitionSummary.swift` (`partitionSummaries`, `recoverAllPlan`). The grouping is memoized in a `PartitionSectionCache` owned by `ResultsView`, so the performance agent's file has no edits from this feature.
- **Coordinator.** `RecoveryCoordinator` and `RecoverySheet` take optional `rootName:` and `reconstructedFiles:` (the coordinator also takes `sourceLabel:`). All three default to the old behaviour. The folder name is `rootFolderName(partition:date:)`, "Photos (exFAT) (recovered yyyy-MM-dd HH.mm.ss)". `files` and `totalBytes` follow the reconstructed toggle (stored, see Review fixes), and the reconstructed toggle (`setIncludeReconstructed`) is ignored once a run starts. The engine, its path safety, the no-overwrite publishing and per-file results are unchanged.
- **Free space.** The coordinator reads the destination's free space when the folder is chosen, via an injectable `freeSpace` that defaults to `availableCapacity(at:)` (see Review fixes for its fallbacks). When the selection is larger, the sheet shows a plain warning (not the red block) and the button reads "Recover Anyway". Cancel stays available. The warning applies to every recovery, since it is advisory only. A blocked destination shows the block and no warning.
- **Sidebar.** `DeviceListView` takes `finishedScanDevice` and `onRecoverPartition`. `ContentView` passes `scan.deviceWithFinishedResults` (a scan that ended with results and an open source session) and a `PartitionRecoveryRequest` binding to `ResultsView`, which opens the same sheet. `DeviceListViewModel.recoverAllTarget(for:)` returns a target only for partitions of that drive, matched by BSD name and media identity. A container's volume is its own target (see Review fixes). A partition with no files in the scan opens an empty plan that says so.
- **End to end** (`PartitionSummaryTests.endToEndRecoversAWholeRealExFATPartitionByteForByte`). The test creates a 64 MB GPT exFAT image ("Photos") in its own temp dir, attaches it `-nobrowse` at a private mount point, and writes six files in nested folders. It then writes one more file, deletes it, and detaches. It scans the image file, never a device node, with `ScanSession`, then runs `PartitionSummary`, then `RecoveryCoordinator` into a temp folder. Result: "Recovered 7 of 7 files from Photos (exFAT)", with the same folder tree and every file byte-identical, the deleted one included. The source image is unchanged. The live `Base` read is checked on a separately attached image in `DeviceTreeTests` (`LivePartitionOffsetTests`), and it is 1 MiB for hdiutil's GPTSPUD layout.
- **Review fixes (batch 5 partition patch).**
  - *Free space.* `availableCapacity(at:)` uses `volumeAvailableCapacityForImportantUsage` only when it is > 0 (FAT32 and exFAT report 0), then `volumeAvailableCapacity`, then `statfs` (`f_bavail × f_bsize`). All unknown is nil, so no warning. Tested on real 64 MB exFAT and FAT32 temp images.
  - *APFS volumes.* `SourceMetadata` gains optional `volumeName` and `volumeID` (the volume UUID, uppercased), defaulted nil. `APFSContainer` sets them on every emitted file, live and deleted (the deleted candidate keeps its live volume superblock). The only parser change is that identity. Groups are keyed `PartitionKey.volume(offset, volumeID:)`. An APFS volume is named by its own name ("Personal (APFS)"), with no size of its own. Carves inside a container can't be told apart between its volumes, which share its blocks, so they form the container's own `volumeID == nil` group. A display name that is or starts with its format keeps it alone ("APFS container", never "APFS container (APFS)").
  - *Sidebar.* `recoverAllTarget(for:)` now returns a container's volume itself. `PartitionGrouping.groups(for:…)` matches the volume to the one group with its name at the container's offset, and falls back to the whole container (all its volumes plus its carves) when the name is ambiguous.
  - *Carved-only areas.* When a plan has only reconstructed files, the coordinator starts with them ticked, and the sheet says "This area only has reconstructed files…". The row's count is what a default run copies: "10 files, of which 3 deleted (+2 reconstructed)", or "2 reconstructed files".
  - *Unknown offsets.* A top-level partition with `offsetBytes == nil` is matched to a group the tree couldn't place by offset, using the same format and either the APFS volume name, the size, or being the only partition of that format. It is never guessed when ambiguous. Sizes come from the scan's extents (`ScanViewModel.latestCheckpoint`, the only place the app sees them).
  - *Skipped volumes.* `.volumeSkipped` notice offsets count as known volumes, so their carves (whose `volumeOffset` is the skipped extent) belong to them, named "NTFS volume at 5 MB" with the extent's size. Only extents of volumes known by other means are used for containment: a whole-device sweep stays "Unpartitioned space". Both come in through `PartitionScanContext` (`scan.partitionScanContext`). `ResultsDashboardView.swift` passes it in four call sites, and that file has no other edits. Without a checkpoint (a scan too short to write one), sizes stay unknown, and only carves whose `volumeOffset` is the skipped offset are assigned.
  - *Naming.* A filesystem at offset 0 is "exFAT volume (whole drive)". Root folder names are cut on the label before " (recovered …)" is appended. The engine sanitizes the root with `RecoveryPaths.sanitizeFolderName`, which keeps no "extension", so the date is never lost.
  - *Unfinished scans.* For a cancelled or failed scan, the row reads "Recover all files found so far…", the sheet title reads "Recover all files found so far from …", and a note says the scan didn't finish. The sidebar menu item keeps its label, because `DeviceListView.swift` was out of scope.
  - *Coordinator.* `files` and `totalBytes` are stored and rebuilt only when the checkbox changes. `filesBuildCount` counts the rebuilds for the tests.
  - *End to end.* The test reads the image through a file-backed `pread` reader, checks the image's SHA-256 before and after, and uses the real `DestinationSafety.live` check. The image is attached again read-only and unmounted as the source drive. A destination on the temp folder's own drive is checked to be blocked. The test fails rather than skipping when hdiutil can't run, unless `SALVAGE_SKIP_HDIUTIL` is set. With `SALVAGE_REQUIRE_HDIUTIL=1`, `realImageTestReportsWhyItIsSkipped` records an issue for a skip.

## Code Map

- **Core:** `SalvageCore/Sources/SalvageCore/Entities/DevicePartition.swift` (`offsetBytes`).
- **DiskIO:** `SalvageDiskIO/Sources/SalvageDiskIO/DeviceTree.swift` (offset).
- **App:**
  - new `Salvage/ViewModels/PartitionSummary.swift` (grouping and naming);
  - `ResultsViewModel.swift` (additive);
  - new `Salvage/Views/PartitionsSection.swift`;
  - `ResultsDashboardView.swift` (insert the section);
  - `RecoverySheet.swift` and `RecoveryCoordinator.swift` (the optional `rootName`, the include-reconstructed toggle, the free-space check);
  - `DeviceListView.swift` (context menu);
  - `DeviceListViewModel.swift` (knows which drive has finished results; take this from `ScanViewModel` via the composition root).
- **Tests:** `SalvageTests/PartitionSummaryTests.swift`, `RecoveryCoordinatorTests.swift` additions, DiskIO `DeviceTreeTests.swift` additions.
- Regenerate the project with `xcodegen generate`.

## Verification

- `swift test --package-path SalvageCore`
- `swift test --package-path SalvageDiskIO`
- `./scripts/check-core-boundary.sh && ./scripts/check-no-network.sh && ./scripts/check-xcodeproj-sync.sh`
- `xcodebuild -project Salvage.xcodeproj -scheme Salvage -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:SalvageTests test`
- `xcodebuild -project Salvage.xcodeproj -scheme Salvage -configuration Debug -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build`
- **Manual end to end:** create a real exFAT disk image with nested folders and a deleted file, scan it through the headless realscan-style path or a unit test that runs `ScanSession` → `PartitionSummary` → `RecoveryCoordinator` into a temp folder. Verify every recovered file is byte-identical and the folder structure matches.
