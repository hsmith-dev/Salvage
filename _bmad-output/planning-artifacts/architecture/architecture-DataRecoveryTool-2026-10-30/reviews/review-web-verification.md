# Web-Verification Review — Salvage ARCHITECTURE-SPINE.md

**Lens:** Verify every committed decision was web-researched/reality-checked rather than asserted from training data.
**Scope:** Claims not already grounded in this session's prior research pass (APFS licensing, `diskutil unlockVolume -nomount`, DiskArbitration+raw-read pattern precedent, Swift core/shell portability — not re-checked here).

## Overall verdict

The spine's remaining technology-currency claims mostly hold up, with one real gap worth surfacing (DiskArbitration vs. the newer FSKit framework) and two claims that are reasonable but rest on community pattern rather than official Apple documentation, which the spine should say plainly rather than imply otherwise.

## Findings

### 1. [Medium] DiskArbitration is not confirmed deprecated, but Apple's newer FSKit framework wasn't considered — a real currency gap

**Location:** AD-1, AD-4, Stack (DiskArbitration appears throughout as the committed low-level access mechanism)

**What I found:** No evidence DiskArbitration itself has been deprecated as a framework — third-party language bindings (Rust `objc2-disk-arbitration`, Go `diskarbitration`) were actively updated through 2025–2026, indicating it's still live and used. However: (a) several DiskArbitration *functions* show as individually flagged deprecated in current binding documentation, with no date confirmed for when; and (b) Apple shipped **FSKit** in the macOS 15.4 beta (2025) — a newer file-system framework that a developer forum thread describes DiskArbitration as now *integrating with* for FSKit-based filesystems, suggesting Apple's direction is toward FSKit for filesystem-level work, not toward DiskArbitration being retired outright.

**Why it matters:** The spine commits to DiskArbitration (AD-1, AD-4) as the raw-access mechanism without ever mentioning FSKit exists. For a project explicitly built to be current and maintained post-launch, silently not considering a framework Apple introduced in the same timeframe this spine was authored is exactly the kind of gap this lens exists to catch — even if the current choice turns out to be correct.

**Suggested fix:** Add a line to AD-4 or Deferred acknowledging FSKit was checked and DiskArbitration was chosen because [reason — likely: FSKit targets *implementing* new filesystem types/extensions, not *reading* arbitrary existing ones at the raw block level, which is Salvage's actual need] — but this reasoning should be confirmed with a few minutes of direct research against Apple's FSKit documentation before AD-4 is finalized, not asserted here. At minimum, flag it as a question for the AD-4 hands-on spike (Deferred already calls out a spike for FDA/TCC — fold this into the same spike's scope).

### 2. [Low] AD-10's GitHub Actions + notarytool pipeline is a well-established *community* pattern, not an Apple-documented CI integration — the spine doesn't distinguish this

**Location:** AD-10

**What I found:** `xcrun notarytool` itself is Apple's current, standard notarization CLI (superseding the deprecated `altool`), and running it on GitHub's `macos-latest` runners is a widely used community pattern — multiple maintained reusable Actions exist (e.g., `GuillaumeFalourd/notary-tools`, `plotlyst/notarize-action`) wrapping `notarytool store-credentials` / `submit` / `stapler`. This is a real, workable pattern. But I found no Apple-published, official GitHub Actions integration guide — it's community tooling built on top of Apple's documented CLI, which is a meaningfully different confidence level than "Apple supports this."

**Why it matters:** Not a correctness risk — the pattern works and is common — but the spine states it as a flat fact ("GitHub Actions builds signed, notarized releases...") without the caveat that this rests on community-maintained Actions wrapping Apple's CLI, which matters if one of those actions goes unmaintained.

**Suggested fix:** Low stakes; either leave as-is (the underlying `notarytool` mechanism is what actually matters and that's solid) or add one clause noting the CI *orchestration* is community-pattern, direct `notarytool` invocation in a hand-written workflow step being the lower-risk fallback if a wrapper Action breaks.

### 3. [Low] AsyncStream's specific buffering/continuation-termination semantics weren't verified — low risk, implementation-level, not architecture-blocking

**Location:** AD-5

**What I found:** Swift 6's strict concurrency checking and compile-time data-race safety are confirmed current and real (multiple current guides agree, consistent with Swift.org's own stated Swift 6 direction). `AsyncStream` itself is a stable, long-shipping Swift Concurrency API, not something new or at risk of deprecation — the choice itself is sound. What search didn't surface was AsyncStream's specific buffering-policy and continuation-termination behavior, which matters at implementation time (e.g., does back-pressure from a slow UI consumer cause the scan to block or drop events?) but is a coding decision, not an architectural one.

**Why it matters:** Doesn't threaten AD-5's validity — flagging only so this doesn't get silently treated as "fully researched" when the API's *fit at the architecture level* was confirmed but its *tuning parameters* weren't.

**Suggested fix:** None needed for the spine; worth a one-line implementation note when `SalvageCore`'s scan API is actually built (buffering policy choice, bounded vs. unbounded).

## What checked out clean

- **Xcode app target consuming local SwiftPM packages** (Stack, Structural Seed) — confirmed as Apple's own current, officially documented pattern ("Organizing your code with local packages," developer.apple.com), reinforced by multiple 2025-era community sources describing the same "thin Xcode project + local packages" shape this spine uses. No currency concern.
- **Swift 6 strict concurrency / structured concurrency as the committed model** (AD-5, Stack) — confirmed current and matches Swift 6's actual default behavior (strict concurrency checking on by default, compile-time data-race safety). No currency concern.

## Sources consulted

- [objc2-disk-arbitration (docs.rs)](https://docs.rs/objc2-disk-arbitration) — DiskArbitration binding, individual function deprecation flags, active 2025 releases
- [go-macos/diskarbitration (pkg.go.dev)](https://pkg.go.dev/github.com/go-macos/diskarbitration) — binding active through 2026
- [Apple Developer Forums: Porting VFS kext to FSKit](https://origin-devforums.apple.com/forums/thread/765424) — macOS Sequoia 15.4 beta FSKit/DiskArbitration integration note
- [GuillaumeFalourd/notary-tools](https://github.com/GuillaumeFalourd/notary-tools) — community notarytool-wrapping GitHub Action
- [plotlyst/notarize-action](https://github.com/plotlyst/notarize-action) — community notarize action
- [Apple Developer: Organizing your code with local packages](https://developer.apple.com/documentation/xcode/organizing-your-code-with-local-packages.md) — official Apple guidance confirming the Stack/Structural Seed pattern
- General search results on Swift 6 strict concurrency defaults (secondary/aggregator sources; no single authoritative swift.org page surfaced, but consistent across multiple independent sources)
