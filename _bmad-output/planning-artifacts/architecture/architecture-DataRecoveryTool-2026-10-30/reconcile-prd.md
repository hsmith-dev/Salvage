# Reconciliation — ARCHITECTURE-SPINE.md vs. PRD (prd-DataRecoveryTool-2026-10-30)

**Scope:** Every FR, NFR, Constraint, Non-Goal, and the Aesthetic/Tone + Information Architecture sections checked against the spine's ADs, Conventions, Capability Map, and Deferred list.

## Overall verdict

Full FR coverage confirmed (all FR-1–FR-19 land in the Capability → Architecture Map, backed by a real AD, not just listed). Two PRD sections correctly have no spine counterpart because they're not architecture-altitude concerns (Accessibility NFR, Aesthetic and Tone) — this is right, not a gap. The one real, actionable gap: **the spine resolves or substantially advances PRD Open Questions 9 and 10, but the PRD's Open Questions section still reads as if both are fully unanswered** — a reader of the PRD alone (without also reading the spine) gets a stale picture. One small naming-accuracy slip and one minor Deferred-section gap round out the findings.

## Findings

### 1. [Should fix] PRD Open Questions 9 and 10 are stale relative to the spine's resolution

- **OQ10** (FileVault unlock vs. read-only guarantee) is **fully resolved** by AD-3: `diskutil apfs unlockVolume -nomount` means Salvage never mounts the source at all, encrypted or not — the FR-6/FR-15 tension OQ10 described no longer exists as stated. The PRD still presents this as an open spike item.
- **OQ9** (APFS parsing strategy) now has a **proposed answer** — AD-2 commits to original MIT-licensed code over the GPL/LGPL-tool alternatives, with reasoning (FUSE install-friction, license contamination) — but it's explicitly `[ASSUMPTION — confirm]`, not fully closed; the PRD's framing of it as a wide-open "reverse-engineer vs. adapt vs. private-API" menu is now narrower than what's actually decided.
- **OQ7** (confidence scoring methodology) is **partially advanced**: AD-7 fixes the mechanism (one pure function, graduated evidence types) though not the exact Medium/Low numeric boundary — the PRD's framing as "needs to be defined during Architecture" is accurate but could note what Architecture actually delivered.

**Fix:** Update PRD §8 Open Questions 9 and 10 the same way 1–3 were handled (resolved/addressed-pending-confirmation notation pointing at the spine's AD-2/AD-3), and add a one-line note to OQ7 pointing at AD-7. This is exactly the kind of upstream/spine divergence the Architecture skill's own discipline says to close, not leave silent.

### 2. [Minor] Consistency Conventions' "verbatim Glossary match" claim isn't quite accurate for one term

The Naming convention row states types "match PRD Glossary terms verbatim" and lists `LostPartitionCandidate` as an example — but the PRD Glossary's actual term is **"Lost partition"** (no "Candidate"). The "Candidate" suffix is a reasonable code-level distinction (a detected-but-not-yet-recovered-from signature hit vs. the general concept), but as written the convention overstates verbatim fidelity for this one entity.

**Fix:** Either soften the convention's claim ("match PRD Glossary terms, with `Candidate`/`Session` suffixes where code needs a narrower state than the PRD's general term") or confirm `LostPartitionCandidate` should instead just be `LostPartition` to stay literally verbatim. Low stakes, doesn't block anything.

### 3. [Optional] Deferred doesn't explicitly restate the "no public library surface" Non-Goal

PRD Non-Goals states "a public library/API surface for the recovery engine in v1" is explicitly out. The spine's module structure (SalvageCore as an internal local SwiftPM package) is consistent with this, but Deferred never says so directly — someone could read AD-1's portability framing and reasonably wonder whether publishing `SalvageCore` standalone is in scope. Not a contradiction, just an opportunity to close the loop explicitly.

**Fix:** Optional one-line addition to Deferred: "Publishing `SalvageCore` as a standalone, versioned public package — Non-Goal per PRD §5; it stays an internal local package in v1."

### Confirmed correctly out of scope at this altitude (not gaps)

- **Accessibility NFR** (HIG/VoiceOver) — purely within-module SwiftUI implementation concern; no cross-boundary divergence risk, correctly left to UX/implementation.
- **Aesthetic and Tone** (calm copy, crediting PhotoRec/TestDisk) — content/copy concern, not structural; correctly has no AD. (Minor thought, not a finding: the planned `ARCHITECTURE.md` explainer could be a natural place to credit prior art for a technical reader, but that's a documentation choice, not an architecture gap.)
- **"Verifiable build provenance" NFR** — actually covered concretely by AD-10 (SHA-256 checksums, build logs, tagged commits via `notarytool`), not just gestured at as initially worth checking.
- **"No automatic/background scanning" Non-Goal** — satisfied by absence (no scheduling mechanism exists anywhere in the spine to accidentally misuse), not something requiring an explicit AD.
