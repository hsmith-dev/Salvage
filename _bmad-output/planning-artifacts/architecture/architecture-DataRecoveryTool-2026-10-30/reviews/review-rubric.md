# Architecture Spine Rubric Review — Salvage

**Reviewed:** ARCHITECTURE-SPINE.md (Fast-path draft, `[ASSUMPTION]`-tagged) against the PRD at `prd-DataRecoveryTool-2026-10-30/prd.md`.

## Overall verdict

The paradigm choice (hexagonal, three modules) and the license-risk framing in AD-2 are strong — AD-2 in particular is a standout: it's specific, research-grounded, honest that it's the single biggest risk in the project, and correctly scopes the risk to APFS rather than over-applying it. But the spine has one **critical, unaddressed contradiction** that would block an explicitly in-scope requirement (internal/boot-drive scanning vs. AD-4's unmount-before-read rule), plus two **high**-severity gaps: FR-3's pause/resume consequence isn't actually enforceable under AD-5's stated mechanism, and the product's single most trust-critical guarantee (zero telemetry/network, FR-17/FR-18) is only gestured at in a Convention-table cell rather than codified as its own AD. Fix these three before treating the spine as implementation-ready; the rest is in good shape for a Fast-path draft.

## Findings

### Critical — AD-4's unmount-before-read rule is impossible for the boot/internal volume FR-1 explicitly includes

**Location:** AD-4 (Raw read path), cross-referenced by FR-1's Consequences ("Internal and external devices appear in the same list, not separate modes") and the original UJ/Vision language about "internal drive" as a valid scan target.

AD-4's Rule requires `SalvageDiskIO` to call `DADiskUnmount` (whole-disk) before any raw read, on the stated basis that Salvage "never reads a device that remains mounted for normal OS use." This is achievable for external drives, USB, SD cards — but **you cannot unmount the currently-running startup/boot volume from user space while macOS is running on it**; the OS actively depends on it. As written, the rule is either impossible to execute against the boot volume (the app would have to silently fail or special-case it) or, if attempted literally, could hang/crash the running system. The spine never carves out this exception, so a story written directly from FR-1 + AD-4 would ship a scan-target option (internal/boot drive) the architecture cannot actually fulfill as specified.

*Fix:* Add an explicit carve-out to AD-4 (or a new AD) for the boot-volume case — the realistic options, consistent with how Disk Drill/EaseUS/TestDisk handle this, are: (a) the running boot volume is excluded from raw-unmount scanning and instead requires booting from external/recovery media for internal-drive recovery, or (b) a live-mounted-volume read path (not the raw-unmount path) is used for the *currently running* boot volume specifically, accepting a different (weaker) read-only guarantee for that one case and disclosing it per FR-19. Either is legitimate; leaving it undecided is not — this is exactly the kind of call two independently-built units would resolve incompatibly (one silently drops boot-volume support, another tries to force-unmount and breaks the user's running system).

### High — AD-5's "Task cancellation" mechanism doesn't actually deliver FR-3's resume behavior

**Location:** AD-5 (Structured concurrency only), cross-referenced by FR-3's Consequence: "Resuming a paused scan continues from where it left off rather than restarting."

Swift `Task` cancellation is one-directional and terminal — a cancelled task cannot be "resumed"; once cancelled, it's done. AD-5's Rule states pause/resume/cancel are *all* handled "via Swift Task cancellation," which is a correct mechanism for cancel but doesn't, by itself, give you resume-from-where-it-left-off. That requires some persisted scan cursor/offset plus a decision about whether "resume" means continuing the *same* unfinished Task (not possible once cancelled) or launching a *new* Task seeded from a checkpoint (possible, but needs an explicit state-checkpointing rule AD-5 doesn't mention). As written, two builders could reasonably diverge: one treats "pause" as soft (suspend the stream, keep the Task alive, no cancellation at all) and another treats it as AD-5 literally says (cancel, then somehow "resume" the same cancelled Task, which won't compile/behave as intended).

*Fix:* Split the rule: cancel = Task cancellation (as-is, correct); pause/resume = a different, explicit mechanism — e.g., the `AsyncStream` continuation is held open and gated by a resumable signal (actor-held `Bool`/continuation pause point) rather than cancelling the underlying Task at all, with the scan's current byte offset checkpointed in `ScanSession` state so a *true* cancel-and-relaunch path (if that's instead the chosen design) has something to resume from.

### High — The product's central trust guarantee (zero network/telemetry) has no enforceable AD of its own

**Location:** Consistency Conventions → State & cross-cutting row ("...enforced by the same AD-9-style CI check extended to network-capable imports..."); Capability → Architecture Map's Privacy & Transparency row (governed by "AD-9 (extended to network imports)").

FR-17/FR-18 (zero automatic network calls, zero telemetry) and PRD counter-metric SM-C3 ("don't add anonymous usage stats under adoption pressure") are, by the PRD's own framing, the product's central differentiator and its single most reputation-critical non-safety guarantee. But the spine never actually writes this as its own AD with a Binds/Prevents/Rule block — it only appears as a parenthetical "AD-9-style" extension inside a table cell. AD-9's literal Rule text (as written in Invariants & Rules) bans four specific imports (`AppKit`, `SwiftUI`, `DiskArbitration`, `IOKit`) in `SalvageCore` and says nothing about network frameworks (`Network`, `URLSession`, etc.) anywhere in the codebase. There is currently no enforceable rule that would catch a contributor adding a stray network call outside the designated update-check path — exactly the SM-C3 scenario the PRD itself warns about.

*Fix:* Promote this to its own AD (e.g., AD-11): CI fails the build if any network-capable API (`URLSession`, `Network.framework`, raw sockets) is referenced anywhere in the codebase except one explicitly designated update-check module/file in the `Salvage` app target. This deserves the same first-class treatment as AD-9, not a footnote inside it.

### Medium — Testing strategy is a fully silent dimension

**Location:** Whole document — no AD, Convention, or Deferred line addresses unit/integration test strategy anywhere.

The hexagonal paradigm (AD-1) and the injectable `BlockReader` port (AD-4/AD-8) are specifically well-suited to testability (inject a file-backed or in-memory reader, no real disk needed for `SalvageCore` tests) — but the spine never says so, nor defers it explicitly. A future contributor can't tell whether this is an intentional omission or a gap.

*Fix:* At minimum, add a line to Deferred naming the test strategy as intentionally left to implementation, noting the injection point AD-4 already provides for it — doesn't need a full AD, but shouldn't be silent.

### Low — AD-2's "original code only" licensing stance isn't generalized across all of `Parsers/`

**Location:** AD-2 (scoped explicitly to APFS); Structural Seed's `Parsers/` directory (APFS, HFS+, FAT32, exFAT together).

AD-2 correctly scopes its GPL/LGPL-avoidance rule to APFS specifically, noting HFS+/FAT32/exFAT "carry no equivalent risk" since they're documented formats. But it doesn't say whether a third-party MIT-compatible library could be used for those instead of original code — probably a non-issue in practice, but currently unstated either way.

*Fix:* Optional one-line clarification in AD-2 or a Convention row: whether `Parsers/` as a whole follows "original implementation against the documented spec" uniformly, or whether non-APFS parsers may use a suitable third-party dependency if one emerges. Low stakes; fine to leave for implementation judgment if the author prefers.

### Low — FileVault credential handling in memory isn't addressed

**Location:** AD-3 (FileVault unlock); FR-6's Consequences (wrong-password vs. tool-drift distinction).

Given the product's trust positioning, the spine could note that unlock passwords/recovery keys are held only transiently (never persisted, zeroized after use) — standard practice, but currently unstated.

*Fix:* Optional note in AD-3 or Deferred; low severity since this is conventional behavior most implementations would get right by default, but worth a line given how central "trust" is to this specific product.

## Mechanical notes

- `lint_spine.py` passed clean (0 findings) — no placeholders, duplicate AD IDs, or missing Binds/Prevents/Rule blocks.
- `binds` frontmatter (FR-1–FR-19) matches the Capability → Architecture Map's FR coverage; no FR is silently uncovered by the map, though see the Critical/High findings above for cases where the *stated* coverage doesn't hold up under scrutiny.
- Deferred section is appropriately scoped — nothing in it currently risks incompatible independent builds (each item either has zero near-term build activity against it, or is already funneled through a single owning AD).
- Named tech (Swift 6 language mode, `diskutil apfs unlockVolume -nomount`, DiskArbitration raw-read pattern) is appropriately hedged where research couldn't fully confirm specifics (e.g., exact Swift toolchain patch version correctly left unpinned rather than asserted) — good hygiene, consistent with the PRD's own caution about unverified claims.
