---
status: approved
created: 2026-10-31
updated: 2026-10-31
---

# Sprint Change Proposal — Salvage

## 1. Issue Summary

**Trigger:** Discovered during UX Finalize's mock-coverage review (2026-10-31), before any implementation has started — `sprint-status.yaml` is still entirely `backlog`, so this is a pre-implementation scope change, not a mid-sprint correction with completed work to reconcile.

**Issue type:** New requirement from the stakeholder (Harrison, as PM/maintainer).

**Problem statement:** v1 currently supports only APFS, HFS+, FAT32, and exFAT (PRD FR-5), with NTFS and EXT2/3/4 explicitly out of scope ("not needed for the primary macOS-native use case"). The user wants Salvage to recover files from NTFS- (Windows) and EXT2/3/4- (Linux) formatted drives too — a drive formatted by a different OS, plugged into a Mac, should be just as recoverable as a Mac-native one.

**Evidence:** Direct user request — "make sure that we are able to recover every file format on each device (Mac, Windows, Linux)" — confirmed as "add NTFS + EXT2/3/4 to v1" when I asked a clarifying question to distinguish this from "port the app itself to Windows/Linux" (which is already a separate, unchanged v2+ direction in the PRD Vision).

## 2. Impact Analysis

### Epic impact
- **Epics 1, 2, 3: unaffected.** No FR renumbering, no changes to existing stories. Both already-isolated risk boundaries (Epic 1's documented-format tier, Epic 2's isolated APFS risk) stay intact.
- **New Epic 4 needed**, not a fold-in to an existing epic: NTFS/EXT2/3/4 are a distinct user-value boundary (drives formatted by another OS) and — per research below — a distinct *risk* tier from Epic 2's APFS work, so bundling them into Epic 2 would blur the reason Epic 2 exists (isolating the one genuinely high-risk format). They also don't naturally belong in Epic 1 without growing it past a clean single-epic scope (11 stories already).
- **Epic order:** Epic 4 doesn't need to come last. It's mutually independent of Epic 2 and Epic 3 (neither requires the other — same independence rule the original epic design already follows), so it can be built before, after, or in parallel with Epic 2 despite the file-order numbering. I'm proposing to *append* it as Epic 4 rather than renumber Epic 2/3 to insert it earlier — renumbering would touch every story ID, cross-reference, and the sprint-status tracking file for no functional benefit, since independence already decouples build order from file order.

### Artifact conflicts

**PRD** (`prd.md`):
- FR-5 amended: add NTFS, EXT2/3/4 to the supported list; remove them from Out of Scope (ReFS, UFS stay out — not requested).
- §2.2 Non-Users clarified: the existing "Windows- or Linux-only users... v1 is macOS-only" line is about the *app's own platform*, not which drives it can read — worth stating explicitly since this is exactly the ambiguity that prompted this change.
- §6.1 MVP Scope and Success Metrics SM-1's filesystem lists extended to match.

**Architecture** (`ARCHITECTURE-SPINE.md`):
- AD-2 amended: extend the "documented format, low engineering risk" bucket (currently HFS+/FAT32/exFAT) to include NTFS and EXT2/3/4, backed by real research (below) — this is not the same risk as APFS.
- Structural Seed's `Parsers/` listing updated to name all six formats.

**UX** (`DESIGN.md` / `EXPERIENCE.md`): **No changes needed.** The Device Picker already treats "any block device" uniformly regardless of filesystem, and the File Browser/confidence-label/preview behavior is already filesystem-agnostic. Confirmed by re-reading both spines — this was a genuine check, not an assumption.

**Other artifacts:** `sprint-status.yaml` needs regeneration after `epics.md` changes (additive only — existing entries preserved, not downgraded).

### Technical risk — researched, not asserted

Before proposing an architecture-level approach, I checked whether NTFS/EXT2/3/4 carry APFS-style risk (undocumented format, GPL-only implementations) or FAT32/exFAT-style risk (well-documented, low risk):

- **NTFS**: well-documented via mature, long-standing community reference work (the Linux-NTFS project's documentation), not an official Microsoft spec but stable and thorough — a real difference from APFS's single partial, incomplete 2018 Apple document. `ntfs-3g` and the Linux kernel's NTFS3 driver are GPL, but a **real MIT/Apache-dual-licensed alternative exists**: the Rust `ntfs` crate (read-only, actively maintained) — usable as reference or adaptation with no license conflict, an option that simply doesn't exist for APFS.
- **EXT2/3/4**: the Linux kernel's own ext4 documentation covers the format thoroughly. `e2fsprogs`/`libext2fs` is mostly GPL, but again a **real permissive alternative exists**: the Rust `ext4-view` crate (read-only, covers ext2 too, dual Apache-2.0/MIT).
- Recovery-specific note: NTFS's Master File Table actually preserves *more* deleted-file metadata than FAT does, making metadata-based undelete more tractable, not less. Ext4 adds extent-tree/journal complexity beyond FAT32, but nothing close to APFS's undocumented structures.

**Conclusion: both belong in the same low-risk bucket as FAT32/exFAT, not APFS's bucket.** This directly shapes the Architecture proposal below.

## 3. Recommended Approach

**Option 1 — Direct Adjustment.** Add Epic 4 and two new stories; amend the PRD and Architecture spine in place; regenerate sprint tracking. No rollback needed (nothing implemented yet — Option 2 is moot). No MVP scope *reduction* needed (Option 3 is moot) — this is a scope *addition* the stakeholder explicitly wants, not a constraint forcing a cut.

**Effort:** Medium (two new stories following an already-proven pattern from Epic 2's APFS/HFS+ split; five scoped document edits). **Risk:** Low, specifically because it was checked, not assumed. **Timeline impact:** Epic 4 adds to total scope but doesn't block or delay Epic 1/2/3 — it can run in parallel given its independence.

## 4. Detailed Change Proposals

### 4.1 PRD — FR-5

**OLD:**
> System supports APFS, HFS+, FAT32, and exFAT as scan and recovery targets.
> ...
> **Out of Scope:** NTFS, EXT2/3/4, ReFS, UFS (R-Studio's broader list) — not needed for the primary macOS-native use case; revisit only if Windows/Linux support (§1 Vision) materializes.

**NEW:**
> System supports APFS, HFS+, FAT32, exFAT, NTFS, and EXT2/3/4 as scan and recovery targets — covering drives formatted by macOS, Windows, or Linux, regardless of which operating system is running Salvage itself (v1 remains macOS-only as a platform; see §2.2 Non-Users).
> ...
> **Out of Scope:** ReFS, UFS (R-Studio's broader list) — not requested; revisit only if real demand materializes.
>
> Consequences bullet updated: "one of the six supported filesystems" (was four). Note updated to add: "NTFS and EXT2/3/4, by contrast, are well-documented via long-standing community reference work and carry risk comparable to FAT32/exFAT, not APFS — see Architecture AD-2."

**Rationale:** Directly implements the approved scope change; keeps FR-5 as the single stable FR for filesystem support rather than proliferating near-duplicate FRs.

### 4.2 PRD — §2.2 Non-Users

**OLD:** "Windows- or Linux-only users — v1 is macOS-only (see §5 Non-Goals; Linux/Windows is an explicit v2+ direction, not a v1 commitment)."

**NEW:** "Users who need Salvage to run on Windows or Linux themselves — v1 is macOS-only as a platform (a Windows/Linux port is an explicit v2+ direction, §1 Vision). This is separate from filesystem support: Salvage running on a Mac reads NTFS- and EXT-formatted drives from day one (FR-5) — what's out of scope is the app running on another OS, not which drives it can read."

**Rationale:** Closes exactly the ambiguity that prompted this change, for the next reader.

### 4.3 PRD — §6.1 MVP Scope, Success Metrics SM-1

Both filesystem lists extended from four to six formats (APFS, HFS+, FAT32, exFAT, NTFS, EXT2/3/4). Mechanical, no rationale beyond consistency with FR-5.

### 4.4 Architecture — AD-2

**OLD (relevant clause):** "...HFS+/FAT32/exFAT carry no equivalent risk — their formats are properly documented (Apple TN1150; Microsoft FAT/exFAT specs) — so this rule binds APFS specifically; `Parsers/` as a whole may use original code throughout, or a suitable MIT-compatible third-party dependency for the non-APFS formats if one emerges — implementer's call for those three."

**NEW:** "...HFS+/FAT32/exFAT/NTFS/EXT2/3/4 carry no equivalent risk — their formats are properly documented via official specs (Apple TN1150; Microsoft FAT/exFAT specs) or mature, long-standing community reference work (the Linux-NTFS project's documentation for NTFS; the Linux kernel's ext4 documentation for EXT2/3/4) — so this rule binds APFS specifically; `Parsers/` as a whole may use original code throughout, or a suitable MIT-compatible third-party dependency for the non-APFS formats if one emerges — confirmed candidates exist for NTFS (the `ntfs` Rust crate, dual Apache-2.0/MIT, read-only) and EXT2/3/4 (the `ext4-view` Rust crate, same dual license), unlike APFS where no such option exists. Implementer's call for all five non-APFS formats."

**Rationale:** Grounds the extension in the research above rather than silently assuming NTFS/EXT parsing is "easy" — names real, checked options.

### 4.5 Architecture — Structural Seed

`Parsers/` directory comment updated: `# APFS (AD-2), HFS+, FAT32, exFAT, NTFS, EXT2/3/4 (all non-APFS formats: AD-2's low-risk bucket)`.

### 4.6 Epics — new Epic 4 (appended, not inserted/renumbered)

> **Epic 4: Recover from Windows- and Linux-Formatted Drives**
> A user can scan and recover from NTFS- (Windows) or EXT2/3/4- (Linux) formatted drives using the same results browser and recovery flow established in Epic 1 — a drive formatted by someone else's computer is just as recoverable as a Mac-native one. Unlike Epic 2's APFS work, these formats are well-documented via mature community reference work, with confirmed MIT/Apache-licensed reference implementations available (Architecture AD-2) — comparable engineering risk to Epic 1's FAT32/exFAT, not Epic 2's APFS risk. Independent of Epic 2 and Epic 3; can be built before, after, or alongside either.
> **FRs covered:** FR-5 (NTFS, EXT2/3/4)
>
> **Story 4.1: Scan and Recover Deleted Files from an NTFS Drive**
> As a user, I want to scan an NTFS-formatted drive and recover deleted files using the same results browser and recovery flow I already know, so that drives from a Windows PC are just as recoverable as my Mac's own drives.
> - Given an NTFS device with deleted-but-not-overwritten files, When I scan it, Then those files appear in results with original filename, path, and timestamp.
> - Given an NTFS device, When selected, Then it appears in the same unified device list as every other supported filesystem.
> - Given a scan against a corrupted or unsupported NTFS structure, When encountered, Then the app reports it as such rather than silently producing wrong results.
>
> **Story 4.2: Scan and Recover Deleted Files from an EXT2/3/4 Drive**
> As a user, I want to scan an EXT2, EXT3, or EXT4-formatted drive and recover deleted files the same way, so that Linux-formatted drives are covered too.
> - Given an EXT2/3/4 device with deleted-but-not-overwritten files, When I scan it, Then those files appear in results with original filename, path, and timestamp.
> - Given an EXT2/3/4 device, When selected, Then it's scanned through the same unified flow as other filesystems.
> - Given an ext4 device with journal/extent-tree complexity, When scanned, Then recovery still succeeds for the common case; edge cases needing deeper journal replay are acceptable to under-recover rather than risk incorrect results.

Also: `epics.md`'s Requirements Inventory FR-5 line and FR Coverage Map row updated to match the amended PRD and list Epic 4.

### 4.7 Sprint tracking

Regenerate `sprint-status.yaml` via `sprint_plan.py generate` after the above — additive only (`epic-4`, `4-1-...`, `4-2-...`, `epic-4-retrospective`, all `backlog`); existing Epic 1/2/3 entries untouched.

## 5. Implementation Handoff

**Scope classification: Moderate.** Touches multiple planning artifacts (PRD, Architecture, Epics) but is additive and well-scoped — doesn't invalidate or require reworking anything already planned, and nothing has been implemented yet to reconcile.

**Handoff:** All edits above are mine to execute directly upon your approval (I authored the PRD, Architecture, and Epics originally — no separate PM/Architect/PO handoff needed for a solo-maintainer project). Once applied and `sprint-status.yaml` regenerated, Epic 4 is ready for `bmad-build` exactly like Epics 1–3.

**Success criteria:** PRD FR-5/§2.2/§6.1/SM-1 consistent with six-filesystem scope; Architecture AD-2 and Structural Seed reflect the researched risk bucketing; `epics.md` has Epic 4 with 2 stories and an updated FR Coverage Map; `sprint-status.yaml` regenerates cleanly with the new entries, no dropped or downgraded existing ones.
