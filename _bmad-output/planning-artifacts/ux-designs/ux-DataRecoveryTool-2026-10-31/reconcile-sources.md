# Input Reconciliation — Salvage UX Spines

Checked `DESIGN.md` and `EXPERIENCE.md` against all four sources (PRD, brief, Architecture explainer, epics.md). Full FR/NFR/UJ/AC-level pass below. Overall: the spines cover the great majority of source content well (confidence-as-text, boot-volume handling, blocking-color scoping, Trust Panel placement, both key flows mirroring UJ-1/UJ-2 verbatim, Accessibility Floor's general shape). Five real gaps found, listed most to least significant.

## Gaps found

### 1. [Medium] "Check for Updates" control has no UI placement anywhere in the spines

**Source:** PRD FR-17's Consequence — "The update check only occurs when the user explicitly triggers it from a visible, intentional control." Epics.md Story 1.11's AC: "Given no scan is in progress, When I check for updates, Then the only network call anywhere in the app is this explicit, user-initiated action."

**Gap:** Both sources require a real, visible UI control for this action — it's the *only* network-capable surface in the entire app (Architecture AD-12), so where it lives is not a trivial detail. Neither EXPERIENCE.md's Information Architecture table, Component Patterns, nor Interaction Primitives places it anywhere (not in the sidebar, not near the Trust Panel, not in a menu). This should get an explicit home — a natural candidate is alongside or inside the Trust Panel itself, since both are about the same "here's exactly what this app does on the network" story, but that pairing isn't stated.

### 2. [Medium] Cold-start scan resume (after an app relaunch mid-scan) has no designed flow

**Source:** Architecture AD-11 and epics.md Story 1.5's third AC: "Given the app is relaunched after being closed mid-scan, When I return to the scan, Then it can resume from the last checkpointed byte offset rather than restarting from zero."

**Gap:** EXPERIENCE.md's State Patterns table covers in-session pause ("Scan paused") but not what the user sees when they reopen Salvage after quitting mid-scan — is a checkpointed scan auto-resumed, does the Device Picker show an "interrupted scan — resume?" affordance, or is this invisible until the user re-selects the same device? This is a real state the architecture explicitly built a mechanism for, with no corresponding UX decision.

### 3. [Medium] No UI state for a concurrent-scan-attempt rejection

**Source:** Architecture AD-4 — "`SalvageDiskIO` owns a single-session-per-device lock... a second scan attempt against a device already under an active session is rejected with a clear error."

**Gap:** This is an architecture-mandated *user-facing* error ("a clear error" implies something shown to the person, not just an internal guard), but no state pattern, component, or microcopy anywhere in EXPERIENCE.md covers what a user sees if they try to start a second scan on a device already being scanned (plausible in v1 if, e.g., they click a device row twice, or a future multi-window/CLI interaction overlaps — flagged regardless since the architecture treats it as a real case).

### 4. [Low] "Scan history" is referenced once with no basis in the sources and no design anywhere else

**Source:** None — not in the PRD's Information Architecture, not in any FR, not in epics.md.

**Gap:** EXPERIENCE.md's Information Architecture section states: "The sidebar (device list, scan history) stays constant..." This is the only mention of scan history in either spine — it isn't listed as its own IA surface, has no component, no state pattern, and traces to no FR or story. Either this was an invented addition that should be removed (device list alone matches every source), or it's a reasonable small addition that needs its own row in the IA table and component entry if kept. As written it's a dangling reference.

### 5. [Low] Accessibility Floor's VoiceOver bullet names 4 components, not all interactive surfaces

**Source:** PRD NFR4 — "Standard Apple HIG compliance, including VoiceOver support, for all primary flows (device selection, scan progress, results browsing, recovery)."

**Gap:** EXPERIENCE.md's VoiceOver bullet explicitly names "device row, type-bucket tile, confidence label, recovery controls" — it doesn't explicitly name Scan Progress's pause/resume/cancel controls, the FileVault unlock sheet's fields, the Trust Panel, or the destination-block banner, even though the general "every interactive element" framing technically implies coverage. Minor — the principle is sound, the explicit list just isn't exhaustive against the PRD's named flows (device selection ✓, results browsing ✓, recovery ✓, but "scan progress" isn't explicitly named).

## What checked out clean

- Confidence-as-text-only, reserved blocking-red, "credit prior art" microcopy, no-celebration-on-completion, boot-volume grayed-with-reason, destination-block behavior, Trust Panel always-reachable placement, FileVault wrong-password-vs-drift distinction, mid-scan unlock pausing (not hard-stopping) the scan, partial-carve "may be incomplete" treatment, Dynamic Type / Reduce Motion / keyboard-nav coverage, and both Key Flows (Sam, Priya) all trace cleanly back to specific FRs, ADs, or PRD/brief passages with no loss of substance.
- Brief's "What Makes This Different" and PRD's Aesthetic and Tone content that *is* UX-shaping (calm/non-alarmist tone, no color-coded trust signals, crediting PhotoRec/TestDisk) made it into the spines; the parts that are purely business/licensing (MIT, free-with-no-gate, community-extensibility) correctly have no UX surface, since none of them imply any visible UI.
