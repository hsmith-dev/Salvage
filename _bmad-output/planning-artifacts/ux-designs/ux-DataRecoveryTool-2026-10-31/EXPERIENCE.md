---
name: Salvage
status: final
sources:
  - _bmad-output/planning-artifacts/prds/prd-DataRecoveryTool-2026-10-30/prd.md
  - _bmad-output/planning-artifacts/briefs/brief-DataRecoveryTool-2026-10-30/brief.md
  - _bmad-output/planning-artifacts/architecture/architecture-DataRecoveryTool-2026-10-30/ARCHITECTURE.md
  - _bmad-output/planning-artifacts/epics.md
created: 2026-10-31
updated: 2026-10-31
---

# Salvage — Experience Spine

## Foundation

Native macOS desktop app (SwiftUI), single window, standard sidebar + content split view — no custom chrome, no multi-window workflow in v1. No third-party UI system; inherits Apple Human Interface Guidelines throughout. `DESIGN.md` is the visual identity reference; this spine is the behavior. Light/dark follows the system setting automatically (no in-app theme toggle — there's nothing to configure, per the "calm, not configurable-for-its-own-sake" posture). The sidebar holds device selection only — no persistent scan-history list in v1 (no FR or story calls for one; each session starts from the Device Picker).

## Information Architecture

| Surface | Reached from | Purpose |
|---|---|---|
| Device Picker | App open (cold), or "New Scan" | Select a block device to scan (FR-1) |
| Scan Progress | Starting a scan from Device Picker | Live progress, pause/resume/cancel (FR-2, FR-3) |
| Scan Results Dashboard | Scan completes, or returning from File Browser | Type-bucketed tiles + Lost Partitions card (FR-9, FR-11) |
| File Browser & Preview | Tapping a type-bucket tile or a Lost Partition card | Browse, preview, select files for recovery (FR-12–FR-14) |
| Recovery Confirmation (sheet) | "Recover" action from File Browser | Destination picker + same-volume block (FR-15) |
| Recovery Summary | Recovery completes | Completion confirmation, reveal in Finder (FR-16) |
| FileVault Unlock (sheet) | Encountering a locked volume — up front at device selection, or mid-scan via a discovered lost partition | Password/recovery-key entry (FR-6) |
| Trust Panel | A persistent entry point visible from every surface | The in-app transparency statement (FR-19) |
| Check for Updates | App menu (Salvage ▸ Check for Updates…) | The app's one sanctioned, explicitly user-initiated network call (FR-17) — not a surface of its own, just a standard macOS menu convention |

Single-window, state-driven content pane — not independent pages a user navigates "back" through in the traditional sense. The sidebar (device list only, see Foundation) stays constant; the content pane transitions through Device Picker → Scan Progress → Scan Results Dashboard → File Browser as one continuous session, the way Disk Utility or a Finder search progresses. The Trust Panel is the one surface reachable from anywhere, at any time, including mid-scan — never gated behind a menu.

→ Composition reference: `mockups/device-picker.html` (boot-volume exclusion + FileVault-locked states), `mockups/scan-results-dashboard.html` (type-bucket grid + Lost Partitions card), `mockups/file-browser.html` (confidence-label hierarchy + reconstructed/carved tagging + preview pane), `mockups/filevault-unlock-sheet.html` (idle + wrong-password states). The remaining surfaces (Scan Progress, Recovery Confirmation, Recovery Summary, Trust Panel, Check for Updates) are spine-only by design, not a gap — confirmed with the user. Spine wins on conflict with any mock.

## Voice and Tone

Microcopy only. Brand posture lives in `DESIGN.md.Brand & Style`.

| Do | Don't |
|---|---|
| "This file could not be fully reconstructed." | "Oops! Something went wrong." |
| "Scanning… 1,204 files found so far." | "Working our magic! ✨" |
| "Your boot drive can't be scanned while macOS is running from it." | Silently excluding it with no explanation |
| "Wrong password." / "Couldn't unlock this volume — try again or use your recovery key." | A single generic "Unlock failed" for both cases |
| "Built from the techniques pioneered by TestDisk and PhotoRec." | Implying the recovery methods are novel or proprietary |
| Short, complete, factual sentences | Exclamation points, percentage claims, urgency language |

## Component Patterns

Behavioral. Visual specs live in `DESIGN.md.Components`.

| Component | Use | Behavioral rules |
|---|---|---|
| Device row | Device Picker | Click selects and immediately begins the scan — no separate "confirm" step, matching macOS's direct-manipulation convention. Boot volume (if present) is shown, grayed, with its one-line reason, never omitted. |
| Type-bucket tile | Scan Results Dashboard | Click opens File Browser scoped to that category. Count/size update live if a scan is still running in the background. |
| Lost Partitions card | Scan Results Dashboard | Visually and positionally distinct from the type-bucket grid — never merges into it (FR-9). Click opens File Browser scoped to that partition's reconstructed contents. |
| Confidence label | File Browser rows, Preview pane | Text only, distinguished by size/weight/tone together per `DESIGN.md` — never by color alone. Never recalculated or re-derived in the UI layer — reflects exactly what `SalvageCore`'s scoring function returned (Architecture AD-7). |
| Preview pane | File Browser (selection-driven) | Single click selects and previews (not double-click-to-open) — matches macOS Quick Look conventions users already know. Unsupported formats show "No preview available" in `ink-tertiary`, never a blank pane. |
| Multi-select + Recover | File Browser | Checkbox per row/tile, a persistent "Recover (n selected)" primary button reflecting the live count — never a separate "select mode" toggle. |
| FileVault unlock sheet | Device Picker (known-encrypted) or mid-scan (discovered lost partition) | Native sheet, secure text field, explicit wrong-password vs. tool-failure distinction (FR-6). Appearing mid-scan pauses the scan (Architecture AD-11's `.unlockRequired` event) rather than blocking the whole app. |
| Pause/Resume/Cancel controls | Scan Progress | Pause suspends in place (resumable); Cancel terminates the in-progress scan but never discards results already found — both always visible together, never one implying the other is unavailable. |
| Destination block banner | Recovery Confirmation (sheet) | The one place `DESIGN.md`'s `blocking` color appears. Blocks the Recover action entirely until a different destination is chosen — no "proceed anyway." |
| Recovery Summary | Post-recovery | States the actual count/size written (which may differ from the pre-recovery selection if any file failed), with a direct "Show in Finder" action. |
| Trust Panel | Always-available entry point | States, in plain language, exactly what Salvage reads (the source disk, read-only) and writes (the destination folder only, and nowhere else) — directly answers "why should I trust this" without requiring the user to find a README. |
| Check for Updates | App menu item | Plain, standard macOS update-check UI (native sheet: current version, available version if any, Install/Later). The only place in the app a network request is ever made, and only when this item is explicitly clicked. |

## State Patterns

| State | Surface | Treatment |
|---|---|---|
| No devices attached | Device Picker | "No storage devices found. Connect a drive to get started." — no illustration, no animation. |
| Boot volume present | Device Picker | Grayed row, one-line reason (see Voice and Tone). |
| Scan paused | Scan Progress | Progress freezes visually; "Paused" state text replaces the live percentage; Resume becomes the primary action. |
| Unsupported filesystem | Scan Progress / Results | "This filesystem isn't supported yet." — factual, not apologetic, no retry-loop UI. |
| FileVault locked (known up front) | Device Picker | Lock icon on the device row, paired with "Locked" in the row's accessible label (the glyph alone never conveys the state); selecting it opens the unlock sheet before any scan begins. |
| Scan completes, nothing recoverable | Scan Results Dashboard | "No recoverable files found on this device." — stated plainly, no retry-loop UI, no implication something went wrong (a securely wiped drive is a valid, expected outcome). |
| FileVault discovered mid-scan | Scan Progress | Scan visibly pauses; unlock sheet appears; declining to unlock skips that lost partition and the scan continues past it (not a hard stop). |
| Carved/reconstructed results | File Browser | Grouped under a visually distinct "Reconstructed" section within each type bucket — filenames are the deterministic generated names (Architecture AD-6), not implied to be original. |
| Partial/corrupted carve | File Browser | Explicit "Partial — may be incomplete" text treatment (never presented as indistinguishable from a complete file), per PRD FR-8's feature-specific NFR. |
| Destination = source attempted | Recovery Confirmation (sheet) | Destination block banner (see Components); Recover stays disabled until resolved. |
| Partial recovery failure | Recovery Summary | Summary states the actual written count and names that it's lower than the selection (destination-full or permission-denied are the realistic causes) without a separate error dialog interrupting the flow. |
| No network / fully offline | (ambient, not a surface) | There is no "offline" state to show — the app never attempts a network call outside the explicit Check for Updates action, so there's nothing to degrade from. |
| App relaunched mid-scan | Device Picker | The device row for an interrupted scan shows "Resume scan (N% complete)" instead of a plain "Scan" action, reading from the checkpointed byte offset (Architecture AD-11) — the user is never silently dropped back to a cold start. |
| Device already in an active scan session | Device Picker | Attempting to start a second scan against a device already locked by another session (Architecture AD-4) shows the device row as "In use by another scan" and disables selection, rather than silently allowing a second scan to race the first. |

## Interaction Primitives

- Click selects and acts (device row starts a scan; file row selects for preview) — no separate confirm step for non-destructive actions.
- Space bar previews the selected file (Quick-Look-style, a convention macOS users already carry from Finder).
- Checkbox multi-select in the File Browser; a live-updating "Recover (n)" button, never a modal "how many do you want" step.
- Keyboard navigation is a first-class path, not an afterthought — every primary action (scan, pause, select, recover) reachable without a mouse.
- **Banned:** onboarding carousels, celebratory animations/confetti on recovery completion (the moment is relief, not achievement), any upsell/"unlock more" modal (there is nothing to unlock), countdown timers or urgency framing of any kind, auto-advancing tooltips.

## Accessibility Floor

Behavioral. Visual contrast lives in `DESIGN.md`.

- VoiceOver: every interactive element — device rows, type-bucket tiles, confidence labels, recovery controls, Scan Progress's pause/resume/cancel controls, the FileVault unlock sheet's fields and error state, the Trust Panel's full statement, and the destination block banner — labeled with role and state. Confidence labels announce the word itself ("High," "Medium," "Low"), not a color or icon a screen reader can't perceive, which is also why `DESIGN.md` makes confidence text-only in the first place.
- Dynamic Type honored through system text styles (`DESIGN.md.typography`) at every level. The Trust Panel's content scrolls independently of its own chrome at any text size — the statement is never clipped or truncated, which matters here specifically since it's the surface the product's whole trust claim depends on.
- Full keyboard navigation (see Interaction Primitives) — this is a macOS-native expectation, not an add-on.
- Reduce Motion: no motion to reduce by default (per the banned-animations list above) — this list doubles as the Reduce Motion contract.
- Reduce Transparency: system materials (sidebar, window background) fall back to solid colors automatically (the AppKit default) — Salvage relies on this rather than overriding it (`DESIGN.md.Elevation & Depth`).
- Increase Contrast: confidence labels and other `ink-secondary`/`ink-tertiary` text pick up the system's automatic higher-contrast variants; if real-world testing shows the default `ink-tertiary` step insufficient at Caption size even with Increase Contrast on, the fallback is adjusting the Low-confidence token, not adding a color or icon.
- Focus order follows the sidebar → content reading order on every surface; sheets (FileVault unlock, Recovery Confirmation) trap focus until dismissed or resolved, per system sheet conventions.

## Inspiration & Anti-patterns

- **Lifted from Disk Drill/EaseUS (the functional pattern, not the visual style):** the type-bucketed results dashboard and the Lost Partitions card as a visually distinct category — this structural pattern is well-proven and already echoed in the PRD's own Information Architecture; what changes is the visual execution (system-native, not SaaS-branded).
- **Lifted from native macOS utilities (Disk Utility, Finder, Console):** sidebar + content layout, Quick-Look-style single-click-and-space-to-preview, system sheet presentation for the FileVault unlock and Recovery Confirmation moments.
- **Rejected — colored confidence badges/stars (Disk Drill's own pattern):** reads as a marketing trust signal, not an honest one; conflicts directly with the product's differentiation (verifiable trust, not optimistic framing) and with `DESIGN.md`'s no-color-for-confidence rule.
- **Rejected — completion celebration (confetti, success sound, badge):** the moment a user recovers lost files is relief after stress, not an achievement to be congratulated for — celebratory treatment would read as tone-deaf given who's using this and why.
- **Rejected — a "select mode" toggle for multi-select:** adds a mode-switch the Finder itself doesn't require; checkboxes are always present in the File Browser.

## Key Flows

### Flow 1 — Sam recovers two years of photos off a drive that stopped mounting

1. Sam plugs in the external SSD; opens Salvage; the device appears in the Device Picker (Finder shows nothing for it, but Salvage does).
2. Clicks the device — scan begins immediately, Scan Progress shows live count and ETA.
3. The scan surfaces a Lost Partition card, visually distinct from the (otherwise empty) mounted-volume results.
4. Scan completes; Sam opens the Lost Partition's File Browser, sees thousands of photos under Pictures, mostly labeled High confidence in plain text.
5. Clicks through a few with Space to preview, confirms they're intact.
6. Checks "select all" for the Pictures bucket, clicks Recover, picks a destination on a different drive.
7. **Climax:** Recovery Summary confirms the count and size written, with a direct "Show in Finder" button — Sam opens it and the photos are there, in their original folders.

Edge case: a handful of files in a fragmented region show Low confidence in dimmed text, grouped under "Reconstructed" — Sam can see at a glance these are less certain, without the app implying a false 100%.

### Flow 2 — Priya checks the tool is safe before trusting it with a client drive

1. Priya finds Salvage on GitHub, downloads it, opens it for the first time.
2. Before touching a device, she clicks the always-visible Trust Panel entry point and reads exactly what the app reads and writes.
3. She runs her own network monitor, plugs in the USB drive, selects it, and starts a scan.
4. Watches her monitor throughout — zero outbound connections, confirming the Trust Panel's claim herself rather than taking it on faith.
5. Recovers the deleted project files to a separate folder.
6. **Climax:** nothing dramatic happens — which is the point. No permission prompt she didn't expect, no network flash, no surprise. She trusts the tool for future client work because she verified it, not because of a brand name.

Edge case: she accidentally picks the USB drive itself as the recovery destination — the destination block banner stops her immediately, in the one place Salvage uses red at all.
