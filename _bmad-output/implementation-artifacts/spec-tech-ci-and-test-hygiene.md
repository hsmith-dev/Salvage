---
title: 'CI and Test Hygiene from the Deferred List'
type: 'tech'
created: '2026-10-31'
status: 'done'
baseline_commit: 'd04d613'
route: 'dispatch'
context:
  - '{project-root}/_bmad-output/implementation-artifacts/deferred-work.md'
  - '{project-root}/_bmad-output/implementation-artifacts/spec-1-1-project-foundation-trustworthy-module-scaffold.md'
  - '{project-root}/_bmad-output/implementation-artifacts/spec-1-12-read-physical-drives-via-a-read-only-privileged-helper.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

Close the mechanical items in `deferred-work.md`:
1. **Project sync check (CI).** Fail CI if the committed `Salvage.xcodeproj` differs from what `xcodegen generate` produces from `project.yml`. Install a **pinned** xcodegen version in CI: pin a Homebrew formula version, or download a release by exact version with a SHA-256 check. Regenerate into a temp copy and `diff -r`. Write `scripts/check-xcodeproj-sync.sh`, which works locally too, plus a self-test that plants a drift.
2. **Boundary-check step 3 coverage.** `scripts/test-check-core-boundary.sh` must exercise the transitive dependency-leak check with a real local package: a throwaway local SwiftPM package in a temp dir whose target imports a forbidden framework, added to a temp copy of SalvageCore's `Package.swift` as a path dependency. It must fail without network access. If step 3 can't detect it, fix the checker.
3. **DiskWatchRegistration tests.** Add a seam so `DiskWatchRegistration` start/stop can be tested without a real DA session. Inject the register/unregister functions. Prove that unregister uses the same callback/context pair as register, and that no callback fires after stop. Add a deselection test for the device list: model-level `clearSelection` from a nil selection binding.
4. **Release signing check.** In `.github/workflows/release.yml`, after signing, verify that the bundled helper plist's SpawnConstraint `team-identifier` equals the app's signing Team ID (`codesign -dv` → `TeamIdentifier`). Also verify the nested helper is signed with the same team. The check must fail closed when they differ.
5. **Real-image test reporting.** Make CI set `SALVAGE_REQUIRE_HDIUTIL=1` (introduced by the HFS+ fixes), so real-image suites can't silently skip on macOS runners. Apply the same env-var rule to the APFS real-image suite (`APFSVolumeTests.swift`), editing only its `.enabled(if:)` condition and adding an availability-report test like HFS+'s.

## Boundaries & Constraints

**Always:**
- Mark each resolved entry in `deferred-work.md` with a `status:` line.
- CI changes must keep every existing step.

**Never:** Edit only these:
- `scripts/`
- `.github/workflows/ci.yml` and `release.yml`
- `SalvageDiskIO/Sources/SalvageDiskIO/DeviceWatcher.swift` (seam only) and `DeviceWatcherTests.swift`
- `Salvage/ViewModels/DeviceListViewModel.swift` (only if the deselection seam needs it) and `SalvageTests/DeviceListViewModelTests.swift`
- the APFS real-image suite condition in `APFSVolumeTests.swift`
- `deferred-work.md`

No parser, ScanSession or app-view changes.

</frozen-after-approval>

## Verification

- `./scripts/check-core-boundary.sh && ./scripts/test-check-core-boundary.sh`
- `./scripts/check-no-network.sh && ./scripts/test-check-no-network.sh`
- `./scripts/check-xcodeproj-sync.sh` and its self-test
- `swift test --package-path SalvageDiskIO`
- `swift test --package-path SalvageCore`
- `xcodebuild -project Salvage.xcodeproj -scheme Salvage -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:SalvageTests test`
- Validate workflow YAML syntax with `ruby -ryaml -e 'YAML.load_file(ARGV[0])' <file>` or python `yaml.safe_load`.

## Implementation Notes

- **Project sync (item 1).** `scripts/check-xcodeproj-sync.sh [ROOT]` copies the tree (git: tracked plus untracked non-ignored files) to a temp dir, moves the copied `Salvage.xcodeproj` aside, runs `xcodegen generate`, and `diff -r`s the result against that copy (excluding `xcuserdata`). Comparing the copy rather than the live directory means the empty directories Xcode creates during a build don't count as drift. It fails closed if xcodegen is missing or isn't the pinned `2.46.0` (`SALVAGE_XCODEGEN_ANY_VERSION=1` is a local-only override). CI downloads the 2.46.0 release zip and checks it against SHA-256 `4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806` before use. Locally, this binary and Homebrew's 2.46.0 produce the same project. The self-test (`scripts/test-check-xcodeproj-sync.sh`) plants each drift in a temp git copy: a hand-edited pbxproj, an unregenerated project.yml, a new source file, a stale extra scheme, a missing project, missing xcodegen, and the wrong xcodegen version.
- **Boundary step 3 (item 2).** Step 3 could not catch the planted dependency: it only grepped `show-dependencies` text for framework *names*, so a package called "Harmless" that imports AppKit passed. The fix keeps the name check and adds a walk of every package path in the `--format json` graph. Each package's sources are grepped for forbidden Swift imports (attribute-prefixed ones included), C `#import`/`#include`/`@import`, `link framework` in module maps, and `.linkedFramework`. `SALVAGE_CORE_PACKAGE_PATH` points step 3 at the temp copy. The test sets `GIT_ALLOW_PROTOCOL=file` and dead proxies, and asserts that no repository was fetched. Scenarios: a clean dependency, a direct AppKit import, a transitive `@preconcurrency import SwiftUI`, and a module map that links IOKit.
- **DiskWatchRegistration (item 3).** The seam is `DiskArbitrationRegistrar` (schedule, unschedule, three register closures, unregister), with `.live(session:)` for production, so the live behavior is unchanged. `DiskWatchRegistration` and `handleChange` are now internal, and the registration takes an `enumerate` closure. A deselection test is now in `DeviceListViewModelTests` at model level, through `clearSelection()`. The view's private SwiftUI binding is still not driven, and the view model needed no changes.
- **Release signing (item 4).** `scripts/check-helper-signing-team.sh APP [DEVELOPMENT_TEAM]` runs in release.yml as a new step after "Verify code signature", which is left unchanged. It is tested with a fake `codesign` in `scripts/test-check-helper-signing-team.sh`, and ci.yml runs that test.
- **Real-image reporting (item 5).** `SALVAGE_REQUIRE_HDIUTIL: '1'` is set as job-level env in ci.yml. The APFS suite condition now probes for a real create+attach of an APFS image. `APFSRealImageAvailabilityTests` mirrors the HFS+ test: with `SALVAGE_SKIP_HDIUTIL=1 SALVAGE_REQUIRE_HDIUTIL=1` it fails, as intended.
- **Test counts:** SalvageCore 332 → 333, SalvageDiskIO 155 → 158, SalvageTests 136 (one new).
