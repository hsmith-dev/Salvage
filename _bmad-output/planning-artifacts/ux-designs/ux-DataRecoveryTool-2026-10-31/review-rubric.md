# Spine Pair Review — Salvage

## Overall verdict

The spine pair has strong structural bones: flow coverage is exact (both PRD journeys appear verbatim with named protagonists, numbered steps, and climax beats), shape fit is fully correct against the canonical section order and required defaults, and the visual-reference section is honest about having no mocks yet rather than silently omitting the topic. The real risk is concentrated in Component coverage and Inheritance discipline: DESIGN.md was not touched during the recent input-reconciliation pass that updated EXPERIENCE.md, leaving it stale in several places — one component is named differently across the two files, one whole component ("Check for Updates") has no visual spec at all, and DESIGN.md's primary-button entry directly contradicts EXPERIENCE.md's actual click-to-scan interaction model. None of this requires a rework — it's a second pass reconciling DESIGN.md against EXPERIENCE.md's more recent state — but a downstream builder hitting these as written would build the wrong thing in at least two places.

## 1. Flow coverage — strong

EXPERIENCE.md's `sources` frontmatter lists 4 files. Only the PRD defines named journeys (UJ-1 Sam, UJ-2 Priya); the brief, Architecture explainer, and epics.md define no journeys of their own to miss. Both UJs are present as Key Flows with titles matching the PRD verbatim ("Sam recovers two years of photos off a drive that stopped mounting", "Priya checks the tool is safe before trusting it with a client drive"), named protagonists, numbered steps, an explicit **Climax** beat, and an edge-case/failure path each.

### Findings
None.

## 2. Token completeness — adequate

### Findings
- **medium** No contrast target stated for the product's two literal-hex, accessibility-load-bearing color pairs: `accent` as a filled button background, and `blocking` text on `blocking-surface`. Neither DESIGN.md's Colors section nor EXPERIENCE.md's Accessibility Floor states a standard (e.g., WCAG AA 4.5:1) these must meet (frontmatter `colors`, DESIGN.md §Colors). *Fix:* add one line to DESIGN.md's Colors section or EXPERIENCE.md's Accessibility Floor stating the contrast bar these combinations must clear.
- **low** `components.primary-button` specifies `background` and `radius` but no foreground/text color token (frontmatter `components.primary-button`) — the comparable shadcn example (`design-example-shadcn.md`) explicitly pairs background with a foreground token for its button-primary. *Fix:* add a foreground token, or an explicit note that the label inherits the system's default tinted-button label color.
- **low** `components.confidence-label`'s three values are descriptive prose ("ink-primary, body weight, no color, no icon") rather than the `{path.to.token}` reference style every other component in the file uses (frontmatter `components.confidence-label`). *Fix:* either restructure as token references or accept the inconsistency explicitly — currently it reads as an oversight, not a choice.

## 3. Component coverage — thin

Extracted every component named in DESIGN.md.Components and EXPERIENCE.md.Component Patterns and cross-checked. Several real mismatches, concentrated around content EXPERIENCE.md gained during a recent reconciliation pass that DESIGN.md didn't receive.

### Findings
- **high** Same component, two names: DESIGN.md's Components section calls it "Blocking banner" (and frontmatter key `blocking-banner`); EXPERIENCE.md's Component Patterns calls it "Destination block banner" (DESIGN.md §Components; EXPERIENCE.md §Component Patterns). *Fix:* pick one name and use it in both files' prose and any frontmatter keys.
- **high** DESIGN.md's `primary-button` entry states its uses as "Scan, Recover — one primary action visible per screen" (DESIGN.md §Components), but EXPERIENCE.md's Device row pattern specifies "Click selects and immediately begins the scan — no separate 'confirm' step" (EXPERIENCE.md §Component Patterns) — there is no separate Scan button in the interaction model as written. A builder following DESIGN.md literally would add a redundant, contradictory Scan button. *Fix:* either DESIGN.md's primary-button should name only "Recover," or EXPERIENCE.md needs an explicit Scan button distinct from row-click (pick one interaction model and align both files).
- **medium** "Lost Partitions card" has a full behavioral row in EXPERIENCE.md requiring it to be "visually and positionally distinct" from the type-bucket grid (EXPERIENCE.md §Component Patterns), but DESIGN.md gives it no dedicated component row — only a parenthetical mention inside the Type-bucket tile bullet ("plus a separate Lost Partitions card," DESIGN.md §Components) that never states what makes it visually distinct. *Fix:* add a Lost Partitions card row to DESIGN.md.Components with its own visual treatment.
- **medium** "Recovery Summary" has a full EXPERIENCE.md Component Patterns row but no DESIGN.md visual spec anywhere. *Fix:* add a Recovery Summary row to DESIGN.md.Components.
- **medium** "Preview pane" is named in EXPERIENCE.md's Component Patterns and only passingly mentioned in DESIGN.md's Elevation & Depth section ("the preview pane," DESIGN.md §Elevation & Depth) — no dedicated Components row. *Fix:* add a Preview pane row to DESIGN.md.Components.
- **medium** "Check for Updates" has a full EXPERIENCE.md IA row and Component Patterns row (added during this spine's input-reconciliation pass) but does not appear anywhere in DESIGN.md — no visual spec for its native update-check sheet at all. *Fix:* add a Check for Updates row to DESIGN.md.Components; this is the clearest signal that DESIGN.md needs its own reconciliation pass against EXPERIENCE.md's current state.

## 4. State coverage — adequate

Walked every IA surface against expected states (empty, cold-load, error, locked/permission, offline).

### Findings
- **medium** No state for a scan that completes with zero recoverable files found at all (e.g., a securely wiped drive) — the Scan Results Dashboard's State Patterns entries cover "unsupported filesystem" but not "supported filesystem, nothing recoverable." *Fix:* add a "No recoverable files found" state row.
- **low** "Partial recovery failure" (Recovery Summary) states that the written count may be lower than the selection but doesn't name why a copy might fail (destination full, permission denied) — the state exists but its trigger is abstract. *Fix:* optional one-line addition naming the realistic failure causes, if that's useful to a downstream implementer; not load-bearing as written.

## 5. Visual reference coverage — strong

No files exist yet in `mockups/`, `wireframes/`, or `imports/` under the UX workspace — confirmed by directory listing. EXPERIENCE.md's Information Architecture section states this accurately ("→ Composition reference: none rendered yet — see Finalize's mock-coverage pass") rather than silently omitting the topic or implying mocks exist. No orphans, nothing to cross-reference yet.

### Findings
None.

## 6. Bloat & overspecification — strong

DESIGN.md's prose carries editorial voice appropriately (Brand & Style's rationale for the system-utility posture, flagged as a confirm-worthy assumption, earns its length). EXPERIENCE.md's prose stays behavioral and doesn't restate PRD/FR content beyond what's needed to ground each rule. No pixel-level specs duplicate what tokens already cover; no section reads as decorative narrative untied to a decision.

### Findings
None.

## 7. Inheritance discipline — thin

### Findings
- Covered by §3's findings above (component-name mismatches: Blocking banner / Destination block banner; components present in one file and absent from the other). These are the concrete inheritance-discipline failures — repeating here only to flag the category verdict, not duplicating the findings.
- **medium** DESIGN.md's Layout & Spacing section still reads "Sidebar holds device selection and scan history" (DESIGN.md §Layout & Spacing) — the same unsupported "scan history" claim that was removed from EXPERIENCE.md's Foundation section during this spine's reconciliation pass (which now correctly states "no persistent scan-history list in v1"). DESIGN.md was not updated in that pass and still contradicts EXPERIENCE.md on this point. *Fix:* remove "and scan history" from DESIGN.md's Layout & Spacing sentence to match EXPERIENCE.md's current, corrected statement.
- `sources` frontmatter (EXPERIENCE.md only, correctly — DESIGN.md's spec doesn't define a `sources` field) resolves cleanly to four real files. UJ names verbatim (§1). EXPERIENCE.md's loose prose token references (`blocking`, `ink-tertiary`, `DESIGN.md.typography`, etc.) all resolve to real DESIGN.md frontmatter keys — no broken references found.

## 8. Shape fit — strong

DESIGN.md's eight sections appear in exact canonical order (Brand & Style → Colors → Typography → Layout & Spacing → Elevation & Depth → Shapes → Components → Do's and Don'ts). EXPERIENCE.md has all eight required defaults, in the same order the mobile example establishes for a single-surface product (Foundation → IA → Voice and Tone → Component Patterns → State Patterns → Interaction Primitives → Accessibility Floor → Inspiration & Anti-patterns → Key Flows). Inspiration & Anti-patterns earns its place with five concrete lifted/rejected items tied to real decisions, not filler. Responsive & Platform is correctly omitted — this is single-surface macOS desktop, not multi-surface or breakpoint-driven.

### Findings
None.

## Mechanical notes

- Casing inconsistency: "Trust panel" (DESIGN.md §Components) vs. "Trust Panel" (EXPERIENCE.md, used throughout) — trivial, but worth matching exactly since it's otherwise treated as a proper component name.
- DESIGN.md's `typography.large-title` note is internally ambiguous: "used once per surface, the scan-results device/summary heading only" could mean either "appears once on every surface" or "appears exactly once, only on the scan-results surface." The Components/Key Flows usage implies the latter, but the sentence as written supports both readings.
- No broken `{path.to.token}` references found in either file's frontmatter; no Mermaid diagrams present in either spine (none required at this altitude).
