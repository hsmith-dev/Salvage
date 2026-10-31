---
title: "Verify the App's Privacy Guarantees Yourself"
type: 'feature'
created: '2026-10-31'
status: 'ready-for-dev'
baseline_commit: 'c1b21a3'
route: 'dispatch'
review_loop_iteration: 0
context:
  - '{project-root}/_bmad-output/implementation-artifacts/epic-1-context.md'
  - '{project-root}/_bmad-output/planning-artifacts/architecture/architecture-DataRecoveryTool-2026-10-30/ARCHITECTURE-SPINE.md'
  - '{project-root}/_bmad-output/planning-artifacts/ux-designs/ux-DataRecoveryTool-2026-10-31/DESIGN.md'
  - '{project-root}/_bmad-output/planning-artifacts/ux-designs/ux-DataRecoveryTool-2026-10-31/EXPERIENCE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:**
- FR-17–FR-19 and AD-12 require three things:
  - a plain-language Trust Panel reachable from the main UI;
  - zero network activity apart from a manual, user-initiated Check for Updates;
  - CI that fails the build when a network API appears anywhere else.
- Today the trust text is an inline sheet in `ContentView`, and no CI enforcement exists. That gap is recorded in `deferred-work.md` from Story 1.1.

**Approach:**
1. Move the trust content into a dedicated `TrustPanelView`, following the UX Trust Panel spec (scrollable at large Dynamic Type sizes).
2. Add a single designated update-check file. It is the only place `URLSession` is used, and it runs only when the user picks "Check for Updates…", never on launch or on a timer.
3. Add `scripts/check-no-network.sh` with a self-test, and wire both into CI.

## Boundaries & Constraints

**Always:**
- **Designated network file:** `Salvage/Updates/UpdateChecker.swift`.
  - It does a single GET of `https://api.github.com/repos/hsmith-dev/Salvage/releases/latest`.
  - The request uses an ephemeral `URLSession` (no cookies or cache) and sends no identifying headers beyond what's required. No analytics, no device or user identifiers in the URL or headers.
  - It compares `tag_name` against `CFBundleShortVersionString` and reports "up to date", "version X available" (with a button that opens the release page in the default browser via `NSWorkspace`) or a plain error.
  - It never downloads or installs anything.
- **Check for Updates trigger:**
  - Offered from the app menu (a `CommandGroup(after: .appInfo)` in `SalvageApp.swift`) and from the Trust Panel.
  - Disabled while a scan is active (`ScanViewModel.isActive`).
  - Never automatic.
- **Trust Panel content:**
  - What is read: the selected device, read-only, after unmounting.
  - What is written: nothing to the source. Story 1.10 will write recovered copies only to a destination you choose; describe that as "when you recover files".
  - When the network is used: only Check for Updates, and what it sends.
  - Zero telemetry, and the source code link.
  - The device stays unmounted after scanning.
  - Plain language, no jargon.
  - Reachable from the toolbar button that exists today.
- **`scripts/check-no-network.sh`:**
  - Fails if `URLSession`, `URLRequest`, `NSURLConnection`, `import Network`, `NWConnection`, `NWListener`, `NWPathMonitor`, `CFSocket`, `CFStreamCreatePairWithSocket`, `socket(`, `connect(`, `getaddrinfo`, `WKWebView` or `import WebKit` appears in any `.swift` file under `Salvage/`, `SalvageCore/`, `SalvageDiskIO/` or `scripts/`, except `Salvage/Updates/UpdateChecker.swift`.
  - Also fails if any `Package.swift` declares a remote dependency (`.package(url:`).
  - The pattern list is for the scanner only; exclude the script's own pattern list from its search.
- **`scripts/test-check-no-network.sh`:** proves the checker catches a planted violation in a temporary copy and passes on clean code. Use the same style as `test-check-core-boundary.sh`.
- **CI:** add both scripts to `.github/workflows/ci.yml` next to the boundary-check steps.
- **Network permissions:** if the target is sandboxed, only `com.apple.security.network.client` is allowed, and only because the update check needs it. Inspect `project.yml` and the Xcode project first, and change nothing if the app isn't sandboxed.

**Never:**
- No automatic or background network calls, no telemetry, no crash reporting.
- No edits to `ScanSession.swift`, `ScanViewModel.swift`, `ScanProgressView.swift`, `FATVolume.swift` or any parser. In `ContentView.swift`, edit only the toolbar and the trust sheet. The `runScan` function and the `ScanViewModel` construction belong to Story 1.5.

## I/O & Edge-Case Matrix

| Scenario | Input | Expected | Error handling |
|---|---|---|---|
| First launch | — | No network activity at all | — |
| Open Trust Panel | Toolbar button | Full explanation, scrollable | — |
| Check for Updates, newer version | User menu action | "Version X is available" + Open Release Page | — |
| Check for Updates, current version | — | "Salvage is up to date" | — |
| Offline or GitHub error / bad JSON | — | Plain-language failure, nothing retried automatically | No crash |
| Scan active | — | Menu item disabled | — |
| Stray `URLSession` in Core | CI | Build fails, naming the file | — |

</frozen-after-approval>

## Code Map

- New `Salvage/Views/TrustPanelView.swift` and `Salvage/Updates/UpdateChecker.swift`.
- `Salvage/SalvageApp.swift`: the menu command.
- `Salvage/Views/ContentView.swift`: toolbar and sheet only.
- New `scripts/check-no-network.sh` and `scripts/test-check-no-network.sh`.
- `.github/workflows/ci.yml`.
- `project.yml` and a regenerated project only if the new folder isn't picked up automatically. Check whether `Salvage` sources are folder-based first.
- Tests:
  - `SalvageTests/UpdateCheckerTests.swift` covers version comparison and JSON parsing through an injected fetch closure. Tests must not hit the network.
  - `scripts/test-check-no-network.sh`.

## Tasks & Acceptance

- [x] Trust Panel view with the full content, reachable from the toolbar.
- [x] UpdateChecker (user-initiated only, ephemeral session, injectable fetch) plus tests for comparing semantic-version tags (with or without a leading `v`) and parse failures.
- [x] Menu command, disabled while scanning.
- [x] `check-no-network.sh` and its self-test, wired into CI. Both must pass on the current tree.

**Acceptance criteria:**
- Given first open, an in-app plain-language explanation of what is read and written, and when, is reachable from the main UI.
- Given a scan or recovery session, there are zero outbound connections. CI enforces this, and nothing in Core or DiskIO can reach the network.
- Given no scan in progress, the only network call anywhere is the explicit Check for Updates action.

## Implementation Notes

- **Scan state reaches the app menu through a tracker, not `ScanViewModel`.** The menu lives in `SalvageApp`, but the `ScanViewModel` is built inside `ContentView` (Story 1.5's code). The new `ScanActivity` (`Salvage/Updates/UpdateCommands.swift`) is an app-level observable that each window reports its `scan.isActive` to. The reporting is done by the `.trustPanel(isPresented:isScanning:)` modifier that replaced the old inline `.sheet`, so the `ContentView` edit is a single line in the sheet slot. This also keeps the menu item disabled when a different window (such as the update window) has focus during a scan. A `focusedSceneValue` would not do that.
- **Where the update result shows.** The menu item opens a small `Window` scene ("Check for Updates") that shows the result. The Trust Panel's own "Check for Updates…" button shows the same status inline. Both read one shared `UpdateChecker`. Opening or restoring the window never starts a check; only the menu item, the panel's button, and the window's "Check Again" button do, and all three are disabled while scanning. EXPERIENCE.md mentions Install/Later. The frozen spec forbids installing, so the only action is "Open Release Page" (`NSWorkspace`).
- **Request headers.** The ephemeral session has cookies, cache and credential storage turned off. The request sets `Accept: application/vnd.github+json` and replaces the default user agent (which names the macOS/CFNetwork build) with a bare `User-Agent: Salvage`, which GitHub's API requires. The Trust Panel says plainly that GitHub can still see the user's IP address.
- **Release page validation.** `html_url` is used only if it is an `https://github.com/hsmith-dev/Salvage/...` URL. Otherwise the page falls back to the fixed `/releases/latest` page.
- **Version comparison.** A leading `v`/`V` is stripped and pre-release or build suffixes (`-beta`, `+meta`) are ignored, since `/releases/latest` never returns a pre-release. Missing components count as 0 (`0.1` = `0.1.0`). Non-numeric tags are a plain "couldn't read" failure. A non-200 status names the status code.
- **Checker details.** `check-no-network.sh` accepts an optional root argument, so `test-check-no-network.sh` plants violations in a temporary `rsync` copy and never touches the real tree. This differs from `test-check-core-boundary.sh`, which writes into the real tree. `socket(` and `connect(` are matched on a word boundary so `disconnect(` doesn't trip the check. The `Package.swift` search skips hidden directories, so running it from the main checkout doesn't scan `.claude/worktrees/*`. A commented-out `.package(url:` line also fails, which is the deliberately conservative choice.
- **Sandbox.** `project.yml` and `project.pbxproj` have no entitlements and no `ENABLE_APP_SANDBOX`, so the app isn't sandboxed and no entitlement was added.
- **Xcode project.** `Salvage` sources aren't folder-synchronized, so `Salvage.xcodeproj` was regenerated with `xcodegen generate`. The diff only adds the three new files.
- **Not touched.** `deferred-work.md` still lists the AD-12 enforcement gap from Story 1.1. Its entry, and `sprint-status.yaml`, were left alone because they are shared files that the parallel story branches would conflict on. Mark that entry resolved when merging.

## Verification

- `./scripts/check-no-network.sh && ./scripts/test-check-no-network.sh`
- `./scripts/check-core-boundary.sh`
- `swift test --package-path SalvageCore`
- `xcodebuild -project Salvage.xcodeproj -scheme Salvage -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:SalvageTests test`
- `xcodebuild -project Salvage.xcodeproj -scheme Salvage -configuration Debug -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build`
