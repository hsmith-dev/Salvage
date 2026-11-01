- source_spec: `_bmad-output/implementation-artifacts/spec-1-1-project-foundation-trustworthy-module-scaffold.md`
  summary: Add automated test coverage for check-core-boundary.sh's transitive dependency-leak check (step 3), exercising a real forbidden-framework-requiring SwiftPM dependency.
  evidence: Current test-check-core-boundary.sh only exercises steps 1-2 (source-grep). Step 3's branch logic (the leaked_deps check) is only ever hit on the trivial "zero dependencies" path, so a regression there (e.g. a typo in the forbidden-framework pattern) would not be caught until a real violation occurs. Needs adding then removing a real dependency with network resolution -- not justified for a scaffold story with no real dependencies yet.
  status: resolved by spec-tech-ci-and-test-hygiene (test-check-core-boundary.sh plants offline local SwiftPM packages -- direct, transitive and module-map -- in a temp copy of SalvageCore; step 3 now scans every package in the resolved graph for forbidden imports/links, since name matching alone could not catch them).
- source_spec: `_bmad-output/implementation-artifacts/spec-1-1-project-foundation-trustworthy-module-scaffold.md`
  summary: Add a CI check that the committed Salvage.xcodeproj stays in sync with project.yml (xcodegen's source of truth).
  evidence: ci.yml builds the checked-in .xcodeproj directly; nothing verifies it still matches what `xcodegen generate` would currently produce from project.yml. Real drift risk as the project grows, but the fix requires installing xcodegen in CI and diffing output -- more than a trivial addition for this foundation story.
  status: resolved by spec-tech-ci-and-test-hygiene (scripts/check-xcodeproj-sync.sh + test-check-xcodeproj-sync.sh; CI installs xcodegen 2.46.0 from the release zip with a SHA-256 check).
- source_spec: `_bmad-output/implementation-artifacts/spec-1-1-project-foundation-trustworthy-module-scaffold.md`
  summary: Implement AD-12's zero-network CI enforcement (fail the build if any network-capable API appears outside the designated Check-for-Updates path).
  evidence: Architecture AD-12 documents this as a first-class requirement, and epic-1-context.md names it, but no story in Epic 1 besides 1.11 ("Verify the App's Privacy Guarantees Yourself") owns implementing it. Out of Story 1.1's committed scope (frozen Intent names only AD-1/AD-9/AD-10) -- flagged here so it isn't silently forgotten before Story 1.11 starts.
  status: resolved by Story 1.11 (scripts/check-no-network.sh + self-test, wired into CI).

- source_spec: `spec-1-4-scan-a-fat32-exfat-device-with-live-progress.md`
  summary: Bound boot-disk metadata subprocess execution and drain both output streams so watcher startup and scan preparation cannot hang indefinitely.
  evidence: Pre-existing diskUtilInfoPlist blocks on readDataToEndOfFile/waitUntilExit, leaves stderr undrained, and has no deadline. A hung diskutil delays cancellation and keeps scan reservations pending. Add injected process tests for timeout, stderr saturation and cancellation cleanup.
  status: resolved in orchestrator review patch P3 (stderr to null device, bounded timeout, reservation released on every failure path).

- source_spec: `spec-1-4-scan-a-fat32-exfat-device-with-live-progress.md`
  summary: Corruption-tolerant scanning, so one bad file chain or one bad partition no longer stops the whole scan.
  evidence: Orchestrator review (blind-hunter #1, #3). `FATVolume.validateFile` claims every cluster up to end-of-chain, ignoring the declared size, so a chain running past its size into another file's clusters raises "Cross-linked allocations." and `ScanSession.run()` stops the scan. The partition loop in `ScanSession` has no per-partition error isolation either, so a corrupt first partition hides a healthy second one. Both follow Story 1.4's fail-closed spec for intact metadata. Revisit with Epic 3 (damaged media): skip-and-report per file or per partition (a non-terminal `ScanEvent`), and stop claiming at the declared size.
- source_spec: `spec-1-3-select-and-list-scan-target-devices.md`
  summary: Direct tests for DiskWatchRegistration start/stop (DAUnregisterCallback context matching) and for List deselection clearing the selection.
  evidence: Verification-gap review. Both fixes are in the code but have no direct tests: `DeviceWatcherTests` never reaches `DASessionCreate`, and the SwiftUI `List` nil-selection path can't be driven from Swift Testing. Needs a DA-session seam or a UI test target.
  status: resolved by spec-tech-ci-and-test-hygiene (injected DiskArbitrationRegistrar seam; DiskWatchRegistrationTests prove matching unregister pairs and no callback after stop; DeviceListViewModelTests covers model-level deselection. The SwiftUI List binding itself is still not driven -- that needs a UI test target).

- source_spec: `spec-1-12-read-physical-drives-via-a-read-only-privileged-helper.md`
  summary: Run the signed end-to-end check of the privileged helper, and add a release.yml check that the bundled plist's SpawnConstraint team-identifier matches the app's team.
  evidence: The helper and its hardening are unit-tested only. Still unverified on a live launchd: Developer ID-only caller enforcement, that launchd accepts SpawnConstraint for an SMAppService daemon, idle exit, and whether TCC also gates a root helper's raw open of removable media (the open question in AD-13). The manual steps are in the spec's Implementation Notes. This needs a Developer ID build signed with the team and the user's approval, on the user's machine.
  status: partially resolved by spec-tech-ci-and-test-hygiene -- release.yml now fails closed unless the helper plist's SpawnConstraint team-identifier, the nested helper's Team ID and the app's signing Team ID all match (scripts/check-helper-signing-team.sh + self-test). Still open: the signed end-to-end run on a live launchd, which needs a Developer ID build on the user's machine.
- source_spec: `spec-1-7-1-8-browse-results-and-confidence.md`
  summary: Hands-on UI pass of scan → browse → preview → recover in the running app (keyboard shortcuts, Cmd-A precedence, pane layout).
  evidence: Every flow is unit-tested, and the app launches with 0 network sockets, but computer use wasn't available to drive the UI. The core path was validated headlessly on real macOS-created exFAT/FAT32 images: live and deleted files were recovered byte-identical.

- source_spec: `spec-3-1-3-2-carve-and-organize-reconstructed-files.md`
  summary: Fragmented carving (reassembly across non-contiguous runs) and format-aware end detection for MP3 (frame walk), OLE2 (sector allocation table) and gzip.
  evidence: v1 carves one contiguous run per file (Intent: fragmented reassembly out of scope). MP3, gzip, OLE and RAR5 have no end rule in the schema, so every such carve is partial/Low and ends at the next header or maxBytes. Needs either new `segments` capabilities (MP3 frame-size arithmetic from the header bitrate/sample-rate bits) or a format-specific walker, which AD-6 discourages; decide with real test files.
- source_spec: `spec-3-1-3-2-carve-and-organize-reconstructed-files.md`
  summary: Surface carving diagnostics in the app: skipped signature files (`SignatureLibrary.skipped`), the carved-file cap (`SignatureCarver.hitFileLimit`), and complete the dashboard wording for reconstructed files.
  evidence: Skipped signatures are only NSLogged; hitting maxCarvedFiles silently stops emission. `ResultsDashboardView`'s closing sentence ("indexed from intact metadata") and the tile accessibility label don't mention reconstructed files; the spec allowed only the "(n reconstructed)" caption line in that file.

- source_spec: `spec-3-3-3-4-discover-and-recover-lost-partitions.md`
  summary: Surface the lost-partition search's limits in the app: "Search for lost partitions was limited to the first N GB" (`VolumeDiscovery.Result.probesTruncated` / `searchedBytes`), skipped unreadable probes, and "the partition table is damaged and was ignored" (`Result.warnings`).
  evidence: Review patch P3 computes these in Core and unit-tests them, but `ScanSession` emits nothing for them. `ScanEvent` is closed (AD-11), and the alternatives (a fake `.lostPartitionFound` named "Search limited", an `.error` for a non-error) would mislead the app. Needs a non-terminal diagnostic event or a scan-summary value on `.completed`, an AD-11 change for the architect, then a dashboard line fed through `ScanViewModel` → `ResultsViewModel`.

- source_spec: `spec-3-1-3-2-carve-and-organize-reconstructed-files.md`
  summary: Surface the carver's file-limit flag (`hitFileLimit`) and the lost-partition search-limited/table-warning results in the UI, and decide how a resumed scan treats carving of already-swept bytes.
  evidence: These are computed and unit-tested in Core, but the app shows none of them. ScanEvent is closed (AD-11), so it needs a non-event channel or an AD-11 amendment. A resumed scan carves only the bytes after the checkpoint, so files that started earlier are missed or carved as partial.
