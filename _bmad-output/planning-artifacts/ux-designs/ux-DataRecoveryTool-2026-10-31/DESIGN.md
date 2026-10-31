---
name: Salvage
status: final
updated: 2026-10-31
description: Open-source macOS data recovery utility. Calm, honest, system-native — a trustworthy tool, not a sales pitch.
colors:
  surface-base:
    note: 'System window background (NSVisualEffectView / windowBackgroundColor) — follows system light/dark automatically'
  surface-raised:
    note: 'System content background (controlBackgroundColor) for cards, panels, the preview pane'
  sidebar:
    note: 'System sidebar material (NSVisualEffectView, .sidebar) — standard macOS sidebar vibrancy'
  ink-primary:
    note: 'System label color (labelColor) — automatic light/dark, automatic contrast compliance'
  ink-secondary:
    note: 'System secondary label color (secondaryLabelColor) — used for Medium/Low confidence text, metadata, captions'
  ink-tertiary:
    note: 'System tertiary label color (tertiaryLabelColor) — used for "no preview available" and other quiet placeholder states'
  border-hairline:
    note: 'System separator color (separatorColor)'
  accent: '#2E6E6E'
  accent-dark: '#5FA3A3'
  accent-on: '#FFFFFF'
  blocking: '#D64545'
  blocking-dark: '#E0685F'
  blocking-surface: '#FCEEED'
  blocking-surface-dark: '#3A2422'
typography:
  large-title:
    note: 'macOS system Large Title — appears exactly once in the whole app, the Scan Results Dashboard device/summary heading; no other surface uses it'
  title:
    note: 'macOS system Title 2 — section headings (type-bucket names, "Lost Partitions")'
  headline:
    note: 'macOS system Headline — file names, device names, primary labels'
  body:
    note: 'macOS system Body — all running text, microcopy, the in-app transparency statement, High-confidence labels (semibold)'
  secondary:
    note: 'macOS system Subheadline — metadata lines (size, date, path), Medium-confidence labels'
  caption:
    note: 'macOS system Caption 1 — counts, timestamps, Low-confidence labels'
rounded:
  sm: 6px
  md: 10px
  lg: 12px
  DEFAULT: 10px
spacing:
  '1': 4px
  '2': 8px
  '3': 12px
  '4': 16px
  '5': 24px
  '6': 32px
  '7': 48px
components:
  device-row:
    background: '{colors.surface-raised}'
    radius: '{rounded.sm}'
    padding: '{spacing.3}'
  type-bucket-tile:
    background: '{colors.surface-raised}'
    radius: '{rounded.md}'
    padding: '{spacing.4}'
    icon-treatment: 'single-weight SF Symbol, ink-secondary — never a colored badge per type'
  lost-partitions-card:
    background: '{colors.surface-raised}'
    radius: '{rounded.md}'
    padding: '{spacing.4}'
    distinction: 'same tile family as type-bucket-tile but a dedicated section/position in the Scan Results Dashboard, never inside the type-bucket grid itself — positional separation carries the distinction, not a color or border treatment'
  confidence-label:
    high:
      color: '{colors.ink-primary}'
      type: '{typography.body}'
      weight: 'semibold'
    medium:
      color: '{colors.ink-secondary}'
      type: '{typography.secondary}'
      weight: 'regular'
    low:
      color: '{colors.ink-tertiary}'
      type: '{typography.caption}'
      weight: 'regular'
    note: 'size + weight + color hierarchy together, not color alone — no color is ever hue-coded (see Colors), and this redundancy is the accessibility fix for low-vision users who may not perceive the ink-* tonal steps alone'
  destination-block-banner:
    background: '{colors.blocking-surface}'
    text: '{colors.blocking}'
    radius: '{rounded.sm}'
    use: 'destination-equals-source block only (Recovery Confirmation sheet) — never for confidence, never for carving/reconstructed results'
  primary-button:
    background: '{colors.accent}'
    foreground: '{colors.accent-on}'
    radius: '{rounded.sm}'
    use: 'Recover — the one primary action button in the app; scanning begins via direct device-row interaction, not a button (see EXPERIENCE.md Component Patterns)'
  trust-panel:
    background: '{colors.surface-raised}'
    radius: '{rounded.lg}'
    use: 'the in-app transparency statement (FR-19) — reachable from every surface, never buried in a menu; content scrolls independently of the panel chrome at any Dynamic Type size'
  preview-pane:
    background: '{colors.surface-raised}'
    radius: '{rounded.lg}'
    use: 'selection-driven preview in the File Browser; "no preview available" renders in {colors.ink-tertiary}'
  recovery-summary:
    background: '{colors.surface-raised}'
    radius: '{rounded.lg}'
    padding: '{spacing.5}'
    use: 'post-recovery completion state — no color, no celebratory treatment (see Do\'s and Don\'ts); states actual written count/size plainly'
  check-for-updates-sheet:
    use: 'native macOS system sheet, no custom styling — system-default button/text treatment throughout, since this is the one surface where "looks exactly like a standard macOS dialog" is itself the correct choice'
---

## Brand & Style

Salvage's visual identity starts from a deliberate rejection: it should not look like the category it's in. Disk Drill and EaseUS — the products this app is positioned against — favor bright-blue SaaS gloss, colored badges, percentage claims ("Recover 99.7%!"), and marketing-style trust signals. Salvage's actual trust claim is different in kind: *verify, don't just believe*. A visual language borrowed from the products it's distinguishing itself from would undercut that claim before a user reads a word of copy.

Instead, Salvage looks like a native macOS system utility — closer in spirit to Disk Utility or Console than to a consumer SaaS product. System materials, system typography, one quiet accent color, and text that says exactly what happened rather than text that sells what happened. The person opening this app has likely just lost something that matters to them; the interface should feel like competent help, not a product trying to impress them.

`[ASSUMPTION — confirm]` This is a significant brand-posture choice: plain system-utility aesthetic over a distinct "designed product" visual identity. The alternative — a more opinionated, custom-branded look — was considered and set aside because a utility this close to the user's raw data earns more trust by looking like it belongs on the system than by looking designed.

## Colors

The palette is almost entirely borrowed from the system on purpose — surfaces, text, and separators use macOS's own semantic colors (`note`-based tokens above) rather than fixed hex values, so the app respects the user's actual system appearance (light, dark, increased contrast, accent color preference) without Salvage having to reimplement any of that itself.

Two colors are genuinely Salvage's own:

- **Accent (`#2E6E6E` light / `#5FA3A3` dark, muted teal)** — the single chromatic color in the app, used only for the primary action per screen (Recover). Deliberately not blue, to avoid visual confusion with Disk Drill's and EaseUS's own blue branding, and deliberately desaturated rather than a bright "startup" teal — calm, not energetic.
- **Blocking (`#D64545` light / `#E0685F` dark)** — reserved exclusively for the one true blocking error state in the product: attempting to set the recovery destination to the same volume as the source (FR-15). This is the only place red appears anywhere in Salvage. It is never used for recovery confidence, carved/reconstructed results, or any other "this might not be perfect" state — those are communicated by text and tone, never by alarm color, because they aren't alarms.

`[ASSUMPTION — confirm]` No color is used anywhere to represent recovery confidence (High/Medium/Low). See Components and Do's and Don'ts — this is deliberate, not an oversight, and is the decision most worth a second look given it departs furthest from the reference products' visual pattern (which use colored badges/stars).

**Contrast bar.** `accent` as a filled button background, and `blocking` text on `blocking-surface`, must each meet WCAG AA (4.5:1) in both light and dark mode — the literal hex values above are a starting point, verified against rendered output at implementation time, not asserted as already-confirmed. The `ink-secondary`/`ink-tertiary` system colors used for Medium/Low confidence are paired with size and weight differences (see Components → Confidence label) specifically because their contrast at small type sizes isn't guaranteed by this spine alone.

## Typography

Platform conventions are the spec: macOS system text styles (Large Title, Title 2, Headline, Body, Subheadline, Caption 1), rendering in San Francisco, honoring the user's Dynamic Type / text-size system setting at every level. Salvage introduces no custom typeface and no display sizes — this is a utility, not a marketing surface.

Large Title is reserved for exactly one heading in the whole app: the Scan Results Dashboard's device/summary heading. It never appears on any other surface. Everything else is Headline, Body, Subheadline, or Caption. No all-caps labels, no letter-spaced "eyebrow" text.

## Layout & Spacing

8pt-based scale (4 / 8 / 12 / 16 / 24 / 32 / 48), matching macOS's own layout conventions so the app's internal rhythm matches the chrome around it (toolbar, sidebar, window controls). Generous spacing in the file browser and preview pane — this is where a user spends the most time and is often already stressed; cramped density would compound that.

Standard macOS sidebar + content split view. Sidebar holds device selection only (no persistent scan-history list in v1 — see EXPERIENCE.md Foundation); content holds whatever state the app is in (idle, scanning, results, preview). No custom window chrome, no non-standard title bar treatment.

## Elevation & Depth

Minimal. macOS system materials (vibrancy, translucency) handle the sidebar/window relationship natively — Salvage doesn't add its own shadow language on top of that. Within content, `surface-raised` panels (type-bucket tiles, the preview pane, the Trust Panel) sit on `surface-base` distinguished by tone and a hairline border, not by drop shadow. The one exception is the FileVault unlock and Recovery Confirmation sheets, which use the system's native sheet-presentation elevation — inherited, not custom. Under Reduce Transparency, system materials fall back to solid `surface-raised`/`sidebar` colors automatically (the AppKit default) — Salvage relies on this rather than overriding it.

## Shapes

`rounded/sm` (6px) for buttons, device rows, and small controls. `rounded/md` (10px) for type-bucket tiles and cards. `rounded/lg` (12px) for larger panels (the Trust Panel, preview pane). Nothing fully circular except system-standard controls (checkboxes, the system progress spinner). No pill-shaped buttons — macOS buttons are rectangular with soft corners, and Salvage follows that rather than importing an iOS/web convention.

## Components

- **Device row** — boot volume (when unsupported) is grayed rather than omitted, always with its reason stated. A locked device carries "Locked" in its accessible label, not the lock glyph alone.
- **Type-bucket tile** — icon stays single-weight and `ink-secondary` for every category; a colored icon per category would compete with the no-color-coding discipline used for confidence.
- **Lost Partitions card** — same surface family as the type-bucket tile, but its own dedicated position in the dashboard, never inside the type-bucket grid. The distinction is positional and structural (its own section, not a seventh tile), not a color treatment.
- **Confidence label** — see frontmatter: size, weight, and tone together, never a chromatic color. The triple redundancy exists so the High/Medium/Low gradation is perceivable even for a low-vision user who can't distinguish the tonal steps alone.
- **Destination block banner** — the one colored alert in the product; never reused for confidence or carving/reconstructed results.
- **Primary button** — exactly one in the app, **Recover**. There is no Scan button — selecting a device row begins scanning directly (see EXPERIENCE.md Component Patterns).
- **Preview pane** — "No preview available" renders in `ink-tertiary` for unsupported formats, never a blank pane.
- **Recovery Summary** — no celebratory treatment (see Do's and Don'ts): the moment is relief, not achievement.
- **Trust Panel** — the in-app transparency statement (FR-19); see EXPERIENCE.md Information Architecture for placement. Scrolls independently of its own chrome at any Dynamic Type size — never clipped or truncated.
- **FileVault unlock sheet** — the "wrong password" vs. "something else went wrong" distinction (FR-6) is plain body text, not an icon-decorated error state.
- **Check for Updates sheet** — the one surface where matching the default macOS dialog exactly is the deliberate choice, not an oversight.

## Do's and Don'ts

| Do | Don't |
|---|---|
| Text-only confidence labels (High/Medium/Low in a size/weight/tone hierarchy) | Colored badges, stars, percentage scores, or traffic-light dots for confidence |
| One accent color, used only for the primary action | Color-code file-type categories or recovery methods |
| Plain-language state text ("This file could not be fully reconstructed.") | Marketing language, exclamation points, percentage claims ("99.7% success!") |
| System materials and system text styles throughout | A custom typeface, display sizes, or non-native window chrome |
| Red reserved for the single true blocking state (destination = source) | Red/yellow/green used for anything related to recovery confidence or carving results |
| Grey out and explain the boot volume when unsupported | Silently omit the boot volume from the device list with no explanation |
