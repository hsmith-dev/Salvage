# Epic 1 Context: Recover Files from Everyday Removable Media, Transparently and Safely

<!-- Compiled from planning artifacts. Edit freely. Regenerate with compile-epic-context if planning docs change. -->

## Goal

A user can scan a USB drive, SD card, or external drive formatted FAT32 or exFAT, watch live scan progress, browse results bucketed by file type with an honest recovery-confidence indicator, preview files before committing, and recover selected files to a destination of their choice — all while being able to verify, not just trust, that the app made zero network calls and did nothing undisclosed. This epic is also the project's foundation: the three-module scaffold, CI-enforced module/network boundaries, the scan event protocol, destination-safety enforcement, and the signed/notarized release pipeline every later epic depends on. The Full Disk Access/raw-device spike runs early here too, since every later epic's read path rests on its outcome.

## Stories

- Story 1.1: Project Foundation — Trustworthy Module Scaffold
- Story 1.2: Full Disk Access / Raw Device Access Spike
- Story 1.3: Select and List Scan-Target Devices
- Story 1.4: Scan a FAT32/exFAT Device with Live Progress
- Story 1.5: Pause, Resume, and Cancel a Scan
- Story 1.6: Recover Deleted Files via Intact Metadata
- Story 1.7: Browse Results by File Type
- Story 1.8: See and Trust the Recovery-Confidence Indicator
- Story 1.9: Preview a File Before Recovering It
- Story 1.10: Recover Selected Files to a Safe Destination
- Story 1.11: Verify the App's Privacy Guarantees Yourself

## Requirements & Constraints

- Any mounted/recognized block device is a valid scan target (internal, external HDD/SSD, USB, SD card); the running boot volume is excluded/marked unsupported (can't unmount while macOS runs from it) — "internal drive" means non-boot only. Device list updates live, no restart; internal/external appear in one unified list.
- Live progress (percent, elapsed/remaining time, files found) updates at least every ~2s; results stream in as found, not just at 100%. Scans must be pausable (resumes same point), cancellable (results kept), and resumable after relaunch from a checkpointed offset.
- FAT32/exFAT is this epic's filesystem scope; unsupported filesystems must be reported as such, never silently wrong/empty.
- Metadata-recovered files keep original filename/path/timestamp and always show High confidence; the floor (metadata = High, anything else = never High) must hold even before carving exists.
- Results group into fixed categories (Pictures, Videos, Audio, Documents, Archives, Other) with accurate per-category count/size; unrecognized types land in Other, never dropped.
- Preview works without recovering first; unsupported formats get an explicit "no preview available" state, never blank.
- Recovery copies exactly the selection, byte-identical to source; destination-equals-source is a hard, explicit block, never silent. Completion summary reports actual written count/size (not pre-recovery selection) plus a direct Finder reveal.
- Zero network calls during scan/recovery; the only network activity anywhere is an explicit, user-initiated update check, never automatic. No analytics/telemetry/crash reporting.
- A plain-language in-app explanation of what the app reads/writes and when must be reachable from the main UI from first launch, not just a README.
- Standard HIG/VoiceOver compliance for primary flows; local-only logs; Developer-ID signed and notarized; Full Disk Access requested only when a scan is initiated, never on launch.

## Technical Decisions

- Three-module hexagonal split: `SalvageCore` (engine, Foundation-only, no AppKit/SwiftUI/DiskArbitration/IOKit), `SalvageDiskIO` (macOS adapter: DiskArbitration, raw reads, FileVault unlock; sole DiskArbitration owner), `Salvage` (SwiftUI app, composition root — only place wiring a concrete adapter into Core). CI fails the build on a forbidden import or a transitive dependency leaking a platform framework into Core.
- CI also fails the build if any network-capable API appears outside one designated update-check file.
- Raw read path: unmount via `DADiskCreateFromBSDName`/`DADiskUnmount`, then unbuffered `open()`/`read()` on `/dev/rdiskN`; the `BlockReader` port has no write method at the type level; a single-session-per-device lock rejects concurrent scans on the same device.
- Scanning exposes a closed `ScanEvent` enum (`.progress`, `.found`, `.lostPartitionFound`, `.unlockRequired`, `.error`, `.completed`) via `AsyncStream` — no Combine/completion handlers. Cancel = `Task` cancellation (terminal). Pause = actor-held resumable gate on the same `Task`; `ScanSession` checkpoints byte offset for cold-start resume.
- Recovery confidence is one pure function in `SalvageCore`, taking recovery method plus graduated (non-boolean) evidence, returning High/Medium/Low — never recomputed elsewhere.
- Destination-equals-source safety is an app-layer check via a `SalvageDiskIO`-exposed volume-identity API (never path-string comparison, never direct DiskArbitration from the app); writes proceed file-by-file with individual success/failure, not all-or-nothing.
- Release pipeline: GitHub Actions, `notarytool`-based signing, GitHub Releases with published SHA-256 checksums and build logs — never the App Store.
- The FDA/SIP spike (Story 1.2) goes in unconfirmed (working assumption: FDA + Developer ID signing) and should also check relevance of Apple's FSKit; findings update the architecture doc from assumed to confirmed.
- Testing approach is open by design, but the hexagonal boundary and injectable `BlockReader` exist so `SalvageCore` is testable with a file-backed/in-memory reader, no real disk — worth settling early here.

## UX & Interaction Patterns

- Single window, sidebar (device selection only) + content split view; content flows Device Picker → Scan Progress → Results Dashboard → File Browser as one session, no back-navigation model, no scan history.
- Clicking a device row selects and immediately starts scanning — no separate Scan button. Boot volume, if present, is grayed with a one-line reason, never omitted. A device already in an active session shows "In use by another scan," disabled. A relaunched interrupted scan offers "Resume scan (N%)," not a cold start.
- Type-bucket tiles open a scoped File Browser; counts/size update live during background scanning.
- Confidence is text-only (size+weight+tone hierarchy) — never color, badges, stars, or percentages; deliberately distinct from competitors' colored trust signals.
- Preview: single click selects/previews (not double-click), Space bar previews (Quick-Look convention); unsupported formats show "No preview available" in tertiary ink, never blank.
- Multi-select uses always-visible checkboxes plus a live "Recover (n selected)" button — no separate select mode.
- Destination-equals-source shows the one red "blocking" banner in the app, in the Recovery Confirmation sheet; Recover stays disabled until resolved, no override.
- Recovery Summary states actual written count/size plainly with "Show in Finder" — explicitly no celebratory treatment; the moment is relief, not achievement.
- Trust Panel (the transparency statement) is reachable from every surface at any time, including mid-scan.
- Pause/Resume/Cancel are always shown together; Pause freezes progress and shows a "Paused" state with Resume as primary; Cancel never discards found results.
- Copy is short, factual, plain-language; no exclamation points, percentage claims, urgency, onboarding carousels, or celebratory animation.
- Every interactive element needs a VoiceOver role/state label; confidence labels must announce the word itself, not color/icon; every primary action must be reachable by keyboard alone.

## Cross-Story Dependencies

- Story 1.1 (scaffold, CI boundaries, release pipeline) underlies every other story in this epic and all later epics.
- Story 1.2 (FDA/raw-device spike) should resolve before the read path used by Stories 1.3–1.6 is built with confidence.
- Story 1.4 (scan + progress) is a prerequisite for 1.5 (pause/resume/cancel), 1.6 (metadata undelete), and 1.7 (type-bucketed browsing).
- Story 1.8 (confidence) depends on 1.6's results to label, and its floor must already reject a hypothetical carved result even though carving ships in Epic 3.
- Stories 1.9 (preview) and 1.10 (recovery) depend on 1.7's results browser existing first.
- Epics 2, 3, and 4 reuse this epic's results browser, confidence indicator, and recovery flow almost unchanged, so the contracts established here have direct downstream impact.
