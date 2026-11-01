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
