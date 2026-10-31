- source_spec: `_bmad-output/implementation-artifacts/spec-1-1-project-foundation-trustworthy-module-scaffold.md`
  summary: Add automated test coverage for check-core-boundary.sh's transitive dependency-leak check (step 3), exercising a real forbidden-framework-requiring SwiftPM dependency.
  evidence: Current test-check-core-boundary.sh only exercises steps 1-2 (source-grep). Step 3's branch logic (the leaked_deps check) is only ever hit on the trivial "zero dependencies" path, so a regression there (e.g. a typo in the forbidden-framework pattern) would not be caught until a real violation occurs. Needs adding then removing a real dependency with network resolution -- not justified for a scaffold story with no real dependencies yet.
- source_spec: `_bmad-output/implementation-artifacts/spec-1-1-project-foundation-trustworthy-module-scaffold.md`
  summary: Add a CI check that the committed Salvage.xcodeproj stays in sync with project.yml (xcodegen's source of truth).
  evidence: ci.yml builds the checked-in .xcodeproj directly; nothing verifies it still matches what `xcodegen generate` would currently produce from project.yml. Real drift risk as the project grows, but the fix requires installing xcodegen in CI and diffing output -- more than a trivial addition for this foundation story.
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
