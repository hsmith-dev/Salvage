---
title: 'Project Foundation — Trustworthy Module Scaffold'
type: 'feature'
created: '2026-10-31'
status: 'done'
route: 'dispatch'
review_loop_iteration: 0
baseline_commit: '9b074c67e878b3ce1e312755dcff2200f35ddfcc'
context:
  - '{project-root}/_bmad-output/implementation-artifacts/epic-1-context.md'
  - '{project-root}/_bmad-output/planning-artifacts/architecture/architecture-DataRecoveryTool-2026-10-30/ARCHITECTURE-SPINE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Nothing exists in this repository yet beyond planning docs — no Xcode project, no module structure, no CI, no release pipeline — so no later Epic 1 story has a foundation to build on or ship through.

**Approach:** Scaffold the three-module hexagonal structure (`SalvageCore`, `SalvageDiskIO`, `Salvage` app) as local SwiftPM packages consumed by an Xcode app project, add a CI workflow that enforces the Core/DiskIO import boundary and builds on every push, and a signed+notarized release workflow triggered by version tags — per Architecture AD-1, AD-9, AD-10.

**Resolved decisions:**
- Bundle identifier: `dev.hsmith.Salvage`. Signing team: "HSmithDev LLC" selected via Xcode's team picker (`DEVELOPMENT_TEAM` resolved locally through the signed-in Apple ID) rather than a hardcoded Team ID string, which this story was not given. For CI, `DEVELOPMENT_TEAM` is a GitHub Actions secret/variable the human fills in later, consistent with the signing-secrets decision below — never a hardcoded value in committed workflow YAML.
- GitHub repository: create now and push. Name: `Salvage`, under the `hsmith-dev` account. Visibility: **public** — not separately asked, because the entire product thesis (MIT license, "fully open source," stated repeatedly across the brief and PRD) makes a private repo incoherent; flagged here plainly so the human can correct it before it happens if this inference is wrong.
- Release workflow (`release.yml`): written now, wired to expected secret names (`DEVELOPER_ID_APPLICATION_CERT_P12`, `DEVELOPER_ID_CERT_PASSWORD`, `NOTARIZATION_API_KEY`, `DEVELOPMENT_TEAM`), not executed against real secrets in this story.

## Boundaries & Constraints

**Always:**
- `SalvageCore` depends on nothing but Foundation; `SalvageDiskIO` depends only on `SalvageCore`; `Salvage` (app) depends on both (AD-1).
- CI fails the build if `AppKit`/`SwiftUI`/`IOKit` is imported anywhere under `SalvageCore`, or if `DiskArbitration` is imported anywhere outside `SalvageDiskIO` (AD-9).
- CI also resolves `SalvageCore`'s dependency graph and fails if any transitive dependency requires a non-portable platform framework (AD-9).
- Minimum deployment target: macOS 14 Sonoma (PRD's own stated default; not re-litigated here).
- The app launches to a minimal shell making zero network calls, even with no recovery features implemented (FR-17/FR-18 true from the first build).

**Never:**
- No recovery logic, disk I/O, or UI features beyond a blank window — those are later Epic 1 stories (1.3+).
- Do not hardcode a literal Developer Team ID string anywhere — use Xcode's team picker locally and a `DEVELOPMENT_TEAM` secret/variable in CI (see Resolved decisions).
- Do not commit real signing certificates, passwords, or notarization credentials anywhere in the repo — secret names only, referenced via `${{ secrets.* }}`.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Forbidden import in SalvageCore | PR adds `import SwiftUI` under `SalvageCore` | CI fails the build | Log names the offending file and import |
| DiskArbitration imported outside SalvageDiskIO | PR adds `import DiskArbitration` in `Salvage` app target | CI fails the build | Log names the offending file |
| Transitive platform-framework leak | `SalvageCore/Package.swift` adds a dependency that itself requires AppKit | CI fails via dependency-graph check | Log names the transitive dependency |
| Clean scaffold | PR with no violations | CI build passes | N/A |
| Tagged commit, signing secrets present | `git tag` matching the release pattern, pushed | Signed, notarized `.app` produced with published SHA-256 checksums | N/A |
| Tagged commit, signing secrets missing | Same, but secrets not yet configured | Release workflow fails at the signing step | Log names the missing secret, does not publish a fake/unsigned artifact |

</frozen-after-approval>

## Code Map

- Repository is greenfield — no existing source code anywhere. Nothing to reuse, nothing to avoid breaking.
- `_bmad-output/planning-artifacts/architecture/architecture-DataRecoveryTool-2026-10-30/ARCHITECTURE-SPINE.md` — AD-1 (module boundary), AD-9 (CI enforcement, exact Rule text), AD-10 (release pipeline, exact Rule text), Stack and Structural Seed sections (exact target tree, Swift/SwiftUI versions).

## Tasks & Acceptance

**Execution:**
- [x] `SalvageCore/Package.swift` + `SalvageCore/Sources/SalvageCore/` -- create the domain SwiftPM package, empty placeholder module that builds cleanly -- establishes AD-1's Core module; later stories fill `Parsers/`, `Carving/`, `Confidence/`, `Ports/`
- [x] `SalvageDiskIO/Package.swift` + `SalvageDiskIO/Sources/SalvageDiskIO/` -- create the macOS-adapter SwiftPM package, depending on `SalvageCore` -- establishes AD-1's DiskIO module
- [x] `Salvage.xcodeproj` (or `.xcworkspace` bundling both local packages) -- Xcode app project consuming `SalvageCore`/`SalvageDiskIO` as local packages, per Architecture Stack -- the app target, not pure-SPM
- [x] `Salvage/SalvageApp.swift` -- minimal SwiftUI `App` entry point, one blank window, no network calls -- satisfies the "minimal shell" AC
- [x] `scripts/check-core-boundary.sh` -- greps `SalvageCore` for forbidden imports and runs `swift package show-dependencies` to catch transitive leaks, exits non-zero naming the violation -- the actual enforcement logic AD-9 requires, kept testable locally
- [x] `scripts/test-check-core-boundary.sh` -- automated, repeatable coverage for the boundary checker's violation-detection paths (added during review: the I/O matrix's forbidden-import rows had only ad hoc manual verification, not a committed test) -- wired into `ci.yml`
- [x] `.github/workflows/ci.yml` -- builds all three targets and invokes `check-core-boundary.sh` (and now `test-check-core-boundary.sh`) on every push/PR -- CI entry point
- [x] `.github/workflows/release.yml` -- on version-tag push: build, sign with Developer ID, notarize via `notarytool`, publish to GitHub Releases with SHA-256 checksums -- implements AD-10, wired to secret names per Resolved decisions
- [ ] GitHub repo `hsmith-dev/Salvage`, public -- **not part of this task's implementation scope** (no push/remote ops during implementation); created and pushed by the orchestrating session after this story's local build and review pass, per Resolved decisions

**Acceptance Criteria:**
- Given a fresh checkout, when `swift build` runs in `SalvageCore/`, then it builds with zero non-Foundation dependencies.
- Given a fresh checkout, when `swift build` runs in `SalvageDiskIO/`, then it builds depending only on `SalvageCore`.
- Given the Xcode project, when built, then the `Salvage` app target builds and launches to a blank window with zero network calls.
- Given a PR introducing a forbidden import (per the I/O matrix), when CI runs, then it fails with a log naming the violation.
- Given a tagged commit, when the release workflow runs, then it either produces a signed/notarized `.app` with checksums (secrets present) or fails naming the missing secret (secrets absent) — never a silent partial success.

## Implementation Notes

- Implemented by a subagent per the spec; verified independently (not just trusting the subagent's report) by re-running `swift build`/`swift test` for both packages, `xcodebuild` for the app target, and `check-core-boundary.sh` directly — all passed for real.
- `project.yml` (xcodegen spec) is committed alongside the generated `Salvage.xcodeproj`, since xcodegen isn't guaranteed to be installed everywhere `.xcodeproj` is opened; regenerate via `xcodegen generate` after structural changes.
- `DEVELOPMENT_TEAM` is intentionally absent from `project.yml`/committed signing config (`CODE_SIGN_STYLE: Automatic` locally) — resolved via Xcode's team picker, never hardcoded, per Resolved decisions.
- One documented interpretation in `release.yml`: the spec names a single `NOTARIZATION_API_KEY` secret, but `notarytool` needs three pieces (key ID, issuer ID, `.p8` key). Packed as `"<KEY_ID>:<ISSUER_ID>:<base64 .p8 key>"`, parsed and validated (malformed input fails loudly) in the notarize step. **Confirm this packing convention with whoever provisions the secret before the first real tag push** — this is a judgment call, not a confirmed fact.
- Matrix Test Audit gap found and fixed during review: the I/O matrix's forbidden-import/leak rows (1-2) had only ad hoc manual verification (inject violation, observe failure, delete file) from both the implementing subagent and my own independent check — not a committed, repeatable test. Added `scripts/test-check-core-boundary.sh`, wired it into `ci.yml`, and ran it for real (all 4 assertions pass, tree confirmed clean after teardown via `trap`).
- Matrix rows 5-6 (tagged-commit release scenarios) remain untestable without real Apple signing/notarization credentials, as the spec itself anticipated — verified by static review of `release.yml` instead (secret-presence check logic reads correctly, fails closed and names the missing secret).
- Matrix row 3 (transitive dependency leak) was not exercised end-to-end with a real forbidden-framework-requiring package (would need adding then removing a real SwiftPM dependency, with network resolution) — verified instead by confirming `swift package show-dependencies` runs correctly against the current zero-dependency graph and the grep pattern mirrors AD-9's Rule text. Flagging this as a lighter-weight check than rows 1-2, not a blocking gap for a scaffold story with no real dependencies yet.
- GitHub repo creation/push intentionally not done in this step (see Tasks) — next action for the orchestrating session.
- Review pass 1: 19 triaged entries (12 patch, 3 defer, 1 false, 3 rejected — see Review Triage Log). All 12 patches sent back to the same implementation agent in one dispatch, applied, and independently re-verified (not just trusting its report): rebuilt both packages, rebuilt the Xcode app, re-ran both boundary/secrets test scripts, live-spot-checked the attribute-prefixed-import fix against a file under `SalvageCore/Tests` specifically (the exact gap finding #1/#2 named), confirmed `LICENSE`/`README.md` content, confirmed `MARKETING_VERSION` and `trap`-based cleanup fixes present in `release.yml`, confirmed both workflow YAML files still parse. All genuinely pass.

## Spec Change Log

## Review Triage Log

Review pass 1 — 3 layers (blind-hunter, edge-case-hunter, verification-gap), 23 raw findings grouped into 19 entries.

| # | Verdict | Route | Finding | Evidence |
|---|---|---|---|---|
| 1 | medium | patch | `check-core-boundary.sh`'s import regex only matches bare `import X`, missing `@testable import SwiftUI` etc. (blind-hunter + edge-case-hunter, same root cause) | Confirmed: regex is `^[[:space:]]*import[[:space:]]+(...)`, no attribute-prefix handling — a trivially defeatable check for something meant to be "CI-enforced, not just reviewed." |
| 2 | low | patch | Step 1 of the boundary checker only scans `SalvageCore/Sources`, not `SalvageCore/Tests` | Confirmed by reading the script. Doesn't violate AD-1 (test target isn't the shipped library product) but is a real gap in the stated "CI-enforced" boundary. |
| 3 | low-medium | patch | Both grep invocations in the boundary checker scan the whole tree with no exclusion for `.git/`, `.build/`, `DerivedData/` (blind-hunter + edge-case-hunter) | Confirmed. Harmless today (no dependencies exist yet) but will produce false positives once Epic 2/4 add real SwiftPM dependencies. |
| 4 | medium | patch | `release.yml` never propagates the pushed tag into `MARKETING_VERSION` (stays hardcoded `0.1.0`) | Confirmed in `project.yml`/`project.pbxproj`. A release built from `v1.2.0` would self-report as `0.1.0` forever — undermines the "trustworthy release" intent behind AD-10. |
| 5 | medium | patch | No `LICENSE` file or root `README.md`, despite this story's own Resolved Decision to push a public, "fully open source," MIT-licensed repo | Confirmed via directory listing. Directly within this story's own stated scope (it's the story creating the public repo). |
| 6 | low | patch | Decoded signing cert / notarization key temp files aren't cleaned up if the step after writing them fails (edge-case-hunter #1 + #3, same pattern) | Confirmed: `rm -f` for both temp files only runs on the success path; `set -e` means an earlier failure skips it. Bounded by ephemeral GitHub-hosted runners, but worth a `trap`. |
| 7 | low | patch | `security list-keychains -d user -s "$keychain_path" $existing_keychains` word-splits an unquoted variable | Confirmed. Low real-world risk (default runner keychain paths have no spaces) but a genuine shell-correctness bug in credential-handling code. |
| 8 | medium | patch | `NOTARIZATION_API_KEY` parsed via `read -r ... <<< "$NOTARIZATION_API_KEY"`, which truncates at the first embedded newline if the secret was pasted as line-wrapped base64 (a common `openssl base64` default) | Plausible human-error path when provisioning the secret; degrades the AC's "fails naming the missing secret, never a silent partial success" guarantee into a confusing failure deep in notarization instead. |
| 9 | low | patch | `gh release create` has no fallback if a release for that tag already exists (re-run after a prior failure, or a re-pushed tag) | Confirmed by reading the step. Narrow but real retry-UX gap. |
| 10 | — | patch | Release-workflow secret-presence check has no automated test, unlike the equivalent boundary-check script (verification-gap, pre-verified) | Filed pre-verified with disposition `patch`; trusted per review-gap rules. Bundled with #8 since both touch the same secret-handling logic. |
| 11 | low | patch | Generated `Salvage.xcscheme` has an empty `<Testables>` block — Xcode's Cmd-U runs nothing | Confirmed by reading the `.xcscheme` XML directly. CI's direct `swift test` calls aren't affected; this is a local-DX gap only. |
| 12 | low | patch | `ci.yml` runs on `macos-latest` with no explicit Xcode version pin | Confirmed. Real but common-default risk; trivial to add. |
| 13 | — | defer | Transitive dependency-leak check (boundary-checker step 3) has no automated test coverage (verification-gap, pre-verified) | Filed pre-verified with disposition `defer` — meaningful coverage needs adding/removing a real forbidden-framework-requiring SwiftPM dependency, not justified for a scaffold story with zero real dependencies yet. Already honestly flagged in this spec's own Implementation Notes. |
| 14 | low | defer | Nothing in CI verifies the committed `Salvage.xcodeproj` still matches what `project.yml` would currently generate (verification-gap, verified) | Confirmed: `ci.yml` builds the checked-in `.xcodeproj` directly. Real drift risk over time, but the fix (installing xcodegen in CI + diffing) is more than a trivial addition — deferred rather than patched now. |
| 15 | — | defer | AD-12's zero-network CI enforcement isn't implemented in this diff | Real and accurate, but out of this story's committed scope (frozen Intent names only AD-1/AD-9/AD-10) — explicitly owned by Epic 1 Story 1.11 ("Verify the App's Privacy Guarantees Yourself"), not Story 1.1. |
| 16 | false | — | `sprint-status.yaml` says `in-progress` while the spec frontmatter says `in-review` | Refuted: the two tracking files use different status vocabularies by design (`sprint-status.yaml` has no `in-review` state; it uses `review`/`done`) and sync at specific workflow checkpoints, not on every spec-frontmatter transition. Expected transient state during review, not drift. |
| 17 | low | reject | No shellcheck/lint step runs over the shell scripts, despite one inline `shellcheck disable` comment | Real but unlikely to be hit in everyday use, and adding a lint CI step is more than a direct correction (new tool dependency) — rejected per the low-finding rule. |
| 18 | low | reject | `test-check-core-boundary.sh`'s cleanup relies on an `EXIT` trap; a hard-kill between writing a violation file and the trap firing could leave it committed | Real but requires exact-timing process termination; fix (isolated fixture directory) is more than a direct correction — rejected. |
| 19 | low | reject | Boundary checker's `2>/dev/null` on the import grep could mask a read error as a clean pass | Real but requires an actually-unreadable file in a git-tracked tree, an unusual scenario; rejected per the low-finding rule. |

## Design Notes

The boundary check is a shell script (`scripts/check-core-boundary.sh`), not inline CI YAML, so it's runnable and testable locally before any push:

```sh
# forbidden-import check
grep -rlE '^\s*import (AppKit|SwiftUI|IOKit)' SalvageCore/Sources && exit 1
grep -rl 'import DiskArbitration' --include='*.swift' . \
  | grep -v '^SalvageDiskIO/' && exit 1
# transitive dependency check
swift package show-dependencies --package-path SalvageCore | grep -i <forbidden-pattern> && exit 1
```

Exact forbidden-framework list for the transitive check should mirror AD-9's Rule verbatim, not be re-derived from memory.

## Verification

**Commands:**
- `swift build --package-path SalvageCore` -- expected: success, zero warnings about missing Foundation-only dependency
- `swift build --package-path SalvageDiskIO` -- expected: success
- `xcodebuild -project Salvage.xcodeproj -scheme Salvage build` -- expected: success
- `./scripts/check-core-boundary.sh` run against a deliberately-violating test file -- expected: non-zero exit, names the violation

**Manual checks (if no CLI):**
- Launch the built app once; confirm a blank window appears with no crash and no network-activity indicator (e.g. Little Snitch) fires.
