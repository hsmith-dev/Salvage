# Accessibility Review — Salvage UX Spines

**Scope:** DESIGN.md + EXPERIENCE.md, accessibility only (not duplicating rubric concerns like token completeness or naming consistency).

## Overall verdict

The spines get the structurally important calls right — confidence is text-content-bearing (not color-only or icon-only), focus-trapping sheets, full keyboard navigation, no motion by default — which means VoiceOver users are well served. The real gaps are for **sighted low-vision users**: the confidence-label hierarchy leans on `secondaryLabelColor`/`tertiaryLabelColor` at the smallest type size for genuinely meaningful content (not the de-emphasized/placeholder text Apple's semantic tertiary color is intended for), and the Accessibility Floor section omits two macOS accessibility settings (Increase Contrast, Reduce Transparency) that this spine's own heavy reliance on system materials and subtle tonal hierarchy makes directly relevant.

## Findings

### 1. [High] Confidence-label color hierarchy risks failing contrast for low-vision users, independent of VoiceOver

**Location:** DESIGN.md `components.confidence-label` (frontmatter) and Components section; EXPERIENCE.md Component Patterns "Confidence label" row.

**Concern:** High/Medium/Low confidence is distinguished *visually* only by `ink-primary` → `ink-secondary` → `ink-tertiary` text color, all at `caption` (the smallest defined type size), with no weight, icon, or size difference ("body weight" stated identically for all three in the frontmatter). Apple's own `tertiaryLabelColor` is semantically intended for de-emphasized/placeholder-like text (DESIGN.md itself uses it that way elsewhere — "no preview available" placeholder) — using it for "Low confidence," a decision-relevant piece of information the user needs to actually perceive, not glance past, stretches that color past its intended role. Apple's Accessibility Inspector audits against WCAG AA (4.5:1 for text ≤17pt, 3:1 at ≥18pt); I could not confirm from official Apple documentation that `secondaryLabelColor`/`tertiaryLabelColor` reliably clear 4.5:1 against `windowBackgroundColor` at Caption size in both light and dark mode — this needs verification against real rendered values during implementation, not an assumption either way.

**Why it matters:** VoiceOver users are unaffected (the word "Low" is read regardless of color), but a low-vision *sighted* user — a real part of this product's audience, including "elderly or less technical" users the product brief gestures at — could fail to perceive the Medium/Low distinction at a glance, which undermines exactly the "honest, perceivable gradation" the text-only design was meant to deliver.

**Suggested fix:** Either (a) confirm during implementation that `secondaryLabelColor`/`tertiaryLabelColor` at Caption size meet 4.5:1 against the surface in both appearances, and if not, bump confidence labels to `body`/`subheadline` size where tertiary's contrast improves relative to the 3:1 large-text threshold, or (b) add one more non-color distinguishing signal for Medium/Low beyond text color — e.g., `secondary` weight (semibold) for the word itself rather than a second color token — without reintroducing the rejected badge/icon/traffic-light pattern.

### 2. [Medium] Accessibility Floor omits Increase Contrast and Reduce Transparency — both directly relevant given how this spine is built

**Location:** EXPERIENCE.md Accessibility Floor section (covers VoiceOver, Dynamic Type, keyboard nav, Reduce Motion, focus order — five bullets, missing two).

**Concern:** DESIGN.md leans heavily on macOS system materials (vibrancy/translucency for the sidebar, per Elevation & Depth) and on a three-step tonal hierarchy (`ink-primary`/`secondary`/`tertiary`) for confidence and other de-emphasized text (Finding 1). Both of these are exactly the kind of visual choice macOS's Increase Contrast and Reduce Transparency accessibility settings exist to adjust — Apple's own accessibility guidance states apps should provide a higher-contrast scheme when Increase Contrast is on. Neither setting is mentioned anywhere in the Accessibility Floor, which otherwise reads as a deliberately complete contract.

**Why it matters:** Without an explicit commitment, it's unverifiable at review time whether `NSVisualEffectView` materials degrade gracefully under Reduce Transparency (AppKit generally handles this automatically, but the spine should say so rather than leave it implicit) or whether the `ink-secondary`/`ink-tertiary` confidence hierarchy gets an enhanced variant under Increase Contrast — which would also be the cleanest fix for Finding 1.

**Suggested fix:** Add two bullets to Accessibility Floor: "Reduce Transparency: system materials fall back to solid `surface-raised`/`sidebar` colors automatically (AppKit default) — confirmed during implementation, not overridden." and "Increase Contrast: confidence-label and other `ink-secondary`/`ink-tertiary` text get the system's automatic higher-contrast variants; if testing shows this insufficient for Finding 1, bump to a non-color signal instead."

### 3. [Medium] Trust Panel's "full transparency statement" at largest Dynamic Type size — scrollability unstated

**Location:** EXPERIENCE.md Accessibility Floor ("Dynamic Type honored... including the Trust Panel's full transparency statement") and DESIGN.md Components (`trust-panel`, no size/overflow behavior specified).

**Concern:** The Trust Panel is described as a persistent, always-reachable panel containing a "full plain-language" statement (DESIGN.md Components) of what the app reads and writes. At the largest accessibility text sizes, a multi-sentence statement in `body` style could occupy several times its nominal height. Neither spine states whether the panel's container scrolls, resizes the window, or is presented full-screen/full-sheet at large type sizes — "honored... at every level" asserts the type scales but doesn't commit to the container accommodating it without clipping or truncation.

**Why it matters:** A truncated or clipped Trust Panel at maximum Dynamic Type would be a direct, visible failure of the exact feature this product's differentiation depends on (FR-19, "why should I trust this") for precisely the users most likely to need the largest text — an avoidable, ironic gap.

**Suggested fix:** State explicitly in DESIGN.md's `trust-panel` component entry (or EXPERIENCE.md's Trust Panel row) that the panel's content is scrollable, independent of the panel's own fixed chrome, at any Dynamic Type size — "no truncated controls" is the bar the mobile reference example (Quill) states explicitly for its own Dynamic Type commitment; Salvage's spine should match that explicitness.

### 4. [Low] FileVault-locked state relies partly on a lock icon; explicit accessible description not stated

**Location:** EXPERIENCE.md State Patterns ("FileVault locked (known up front)" row: "Lock icon on the device row").

**Concern:** The row-level VoiceOver commitment ("device rows... labeled with role and state," Accessibility Floor) likely covers this by including "locked" in the row's full label, but the State Patterns entry itself only describes the *visual* lock icon, not the accessible description that must accompany it independent of the glyph.

**Why it matters:** Low risk given the general row-labeling commitment already exists, but worth closing explicitly so an implementer doesn't ship an icon-only `Image(systemName: "lock.fill")` with no `accessibilityLabel` addition beyond the row's base text.

**Suggested fix:** One clause: "the lock icon is accompanied by 'Locked' in the row's accessible label, not conveyed by the glyph alone."

### 5. [Low] "Destination confirmation" sheet status is stated in Accessibility Floor but not established as a sheet elsewhere

**Location:** EXPERIENCE.md Accessibility Floor ("sheets (FileVault unlock, destination confirmation) trap focus") vs. Information Architecture / Component Patterns, where "Recovery Confirmation" / "Destination block banner" is never explicitly called a sheet (only FileVault unlock is explicitly "native sheet" elsewhere).

**Concern:** This is a minor internal cross-reference gap rather than a new accessibility rule, but it matters here specifically because the focus-trap guarantee's applicability to Recovery Confirmation depends on it actually being a sheet.

**Why it matters:** If Recovery Confirmation is implemented as an inline panel instead of a sheet, the stated focus-trap accessibility guarantee silently stops applying to it.

**Suggested fix:** Add "(presented as a sheet)" to the Recovery Confirmation row in the Information Architecture table, or to its Component Patterns entry, so the Accessibility Floor's claim has a committed anchor.

## Sources consulted

- [Apple Human Interface Guidelines — Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility.md) — WCAG AA thresholds (4.5:1 / 3:1) as used by Apple's Accessibility Inspector; Increase Contrast guidance
- Could not confirm official Apple-published contrast ratio values for `secondaryLabelColor`/`tertiaryLabelColor` specifically — flagged in Finding 1 as needing implementation-time verification rather than asserted here
