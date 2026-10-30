# Input Reconciliation: brief.md + addendum.md → prd.md

**Input:** Product brief (`brief.md`) and its companion `addendum.md`, both at `_bmad-output/planning-artifacts/briefs/brief-DataRecoveryTool-2026-10-30/`.
**Target:** `prd.md` (this PRD run), current draft.

## Method

Read all three files in full. Walked every substantive claim, decision, risk, and nuance in the brief/addendum and checked whether the *idea* (not necessarily the wording) appears somewhere in the PRD — Vision, Features/FRs, Non-Goals, Constraints, Success Metrics, Open Questions, or Assumptions Index.

## Gaps Found

| # | Source location | What it says | Status in PRD | Recommendation |
|---|---|---|---|---|
| 1 | `brief.md` §Success Criteria, "Trust signals" bullet | "Trust signals specific to this product's premise: **reproducible builds**, a documented 'what this app reads/writes and when' explanation, no flagged privacy concerns from the security community." | The "documented what it reads/writes" half is covered (PRD FR-19). **"Reproducible builds" does not appear anywhere in the PRD** — not in Success Metrics, Cross-Cutting NFRs, or Open Questions. This is a specific, concrete trust commitment from the brief, not vague color — it's exactly the kind of checkable claim (§4.6's whole premise) that should either become a requirement/metric or an explicit open question about build tooling. | Add to either §7 Success Metrics (as a trust signal alongside SM-4) or Cross-Cutting NFRs (Security/Maintainability), or at minimum list as an Open Question if the build-reproducibility approach isn't yet decided. |
| 2 | `brief.md` §Risks & Open Questions, "Legal/liability framing" bullet | "Standard open-source 'as-is, no warranty' disclaimers apply..." | The in-product "what it does/doesn't do" transparency half is covered (FR-19). **The "as-is, no warranty" legal disclaimer itself is not mentioned anywhere in the PRD** (not in Non-Goals, Constraints, or Open Questions). Minor but a distinct legal item from the product-transparency one. | Add a one-line mention under Constraints or Open Questions — doesn't need its own section at this stage. |
| 3 | `addendum.md` §Competitive Landscape / Core Recovery Techniques, repeated framing | The brief and addendum are explicit and repeated that this project should **credit TestDisk/PhotoRec and not claim to have invented these techniques** ("None of that is novel — the openness, the trust model, and the UX are the point" / "this project should explicitly credit these techniques, not claim to have invented them"). | This tonal/integrity commitment doesn't appear in the PRD's §Aesthetic and Tone or anywhere else. It's a qualitative "voice" instruction the FR structure naturally drops, exactly the kind of thing Finalize step 2 exists to catch. | Add one sentence to §Aesthetic and Tone (or a `[NOTE FOR PM]` near the Vision/Glossary) committing to crediting prior art (TestDisk, PhotoRec, sleuthkit/libewf as referenced in the brief's Vision) rather than implying novel technique invention. |

## Not Gaps (checked, confirmed present)

- Device-agnostic scanning, broad v1 filesystem scope, lost-partition reconstruction, free/open-source/no-paywall model, zero-telemetry positioning, Mac App Store infeasibility, $99/yr notarization cost tension, FDA/SIP spike need, Linux/Windows as v2+ direction, recovery-confidence honesty requirement — all present in the PRD, usually in more structured form (FRs, Non-Goals, Open Questions, Constraints).
- Electron-vs-native and MIT-vs-GPL options-considered detail — correctly *not* restated in the PRD; it's addendum-tier technical-how/decision-rationale, and the PRD appropriately points back to the brief's addendum (§0 Document Purpose) rather than duplicating it.
- Process Notes section (fast-path methodology) — correctly not carried into the PRD; it's about how the brief was produced, not product content.
