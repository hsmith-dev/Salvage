# Technical Feasibility Review — PRD: OpenRecover

**Reviewer:** ad-hoc technical-feasibility (parallel to PM quality-rubric review)
**Scope:** technical feasibility only — not PM/structural concerns (glossary, FR numbering, etc., covered elsewhere)

## Overall verdict

The PRD's core feature set is feasible — every competitor it benchmarks against (Disk Drill, EaseUS, TestDisk) already ships the same category of capability, so nothing here is unprecedented. But two things are stated with more confidence than the technical reality supports: (1) APFS metadata-based recovery (FR-4, FR-5, FR-9, FR-10) rests on an undocumented, proprietary on-disk format with no public Apple parsing API — the PRD doesn't name this as a risk anywhere; and (2) FR-6 (FileVault unlock) and FR-15 (strict read-only-against-source) can conflict in practice, because the normal OS mechanism for unlocking/accessing an encrypted volume can itself write to that volume (journal replay, metadata touches) unless deliberately avoided. Both should become explicit Open Questions / Architecture inputs, not just implicit assumptions. The reproducible-builds claim in the Security NFR is also stated more firmly than current Swift/Xcode tooling realistically supports.

## Findings

### 1. [High] No public Apple API for raw APFS metadata parsing underlies FR-4, FR-5, FR-9, FR-10, but isn't named as a risk anywhere

**Location:** §4.2 FR-4/FR-5, §4.4 FR-9/FR-10; also §Cross-Cutting NFRs (Maintainability/Extensibility)

**Concern:** APFS's on-disk format is proprietary and not documented by Apple for third-party low-level parsing. The existing prior art the brief's addendum cites (TestDisk/PhotoRec, and tools like apfs-fuse, sleuthkit's APFS module) got there by reverse-engineering the format, not by using an Apple-provided framework. The PRD states "system recovers deleted-but-not-yet-overwritten files by reading intact filesystem metadata (APFS catalog/journal...)" (FR-4) and "system supports APFS... as scan and recovery targets" (FR-5) as if this were a routine integration, when in practice it's the single largest engineering investment in the whole product — a from-scratch or adapted APFS structure parser maintained against an undocumented, Apple-controlled format that can change across macOS releases.

**Why it matters:** This is the feature the whole differentiation story leans on (§1 Vision explicitly says "the pitch isn't a better recovery algorithm," but the product still needs a working one). If this is treated as a routine FR rather than the primary technical risk it is, Architecture and Epics/Stories will under-scope it, and "APFS support" could silently become the long pole that blocks the rest of the launch-grade scope in §6.1.

**Suggested fix:** Add to §8 Open Questions: "What is the APFS parsing strategy — reverse-engineer from scratch, adapt an existing open-source APFS reader (e.g., apfs-fuse, sleuthkit), or use a private/undocumented Apple framework — and what's the maintenance plan for format drift across macOS versions?" Flag explicitly for Architecture as the highest-risk technical decision in the project, not folded silently into FR-5's one-line filesystem list.

### 2. [High] FR-6 (FileVault unlock) can conflict with FR-15 (strict read-only-against-source)

**Location:** §4.2 FR-6; §4.5 FR-15 and its Consequences; §Cross-Cutting NFRs (Reliability/Safety)

**Concern:** Web research confirms the practical mechanism for unlocking a non-boot APFS encrypted volume is `diskutil apfs unlockVolume <volume> -passphrase <key>` (or the recovery-key equivalent) — see the Harmony Endpoint and Eclectic Light sources below. That unlock step, and the mount that typically follows it, is a normal macOS filesystem mount — and a normal mount is not guaranteed to be side-effect-free on the volume: journal replay, "last mounted by" metadata updates, and similar OS-level touches are a known class of risk for any tool in this category that needs FR-15's guarantee to hold absolutely. FR-15's own Consequences ("source disk's filesystem metadata... is unchanged after a full scan-and-recover session") is written as if this is simply true by construction, but it isn't automatic — it requires deliberately mounting/opening read-only (or working from a raw block-device read path) wherever the OS allows it, and FR-6 as written doesn't say how the unlock+access step avoids this.

**Why it matters:** FR-15 / the read-only guarantee is the product's single most reputation-critical claim (SM-4 calls it "the single most reputation-critical metric for this product category"). FileVault handling (FR-6) is the one feature most likely to quietly violate it, because unlocking a volume is inherently more invasive than reading an already-unencrypted one. A silent conflict here is exactly the kind of gap that won't show up until a real FileVault recovery session in the field.

**Suggested fix:** Add an explicit Consequence to FR-6 or FR-15: "Unlocking a FileVault volume for scanning uses the most read-only access mode macOS permits (e.g., explicit read-only mount flags or raw device access post-unlock), and any unavoidable OS-level metadata touches from the unlock step itself are disclosed in the in-app transparency statement (FR-19) rather than silently contradicting FR-15." Also add to Open Question 4's spike scope: "confirm whether a strictly read-only, journal-non-replaying access path exists for an unlocked APFS volume."

### 3. [Medium] FR-6's unlock mechanism has no documented public Swift/ObjC API — likely requires shelling out to `diskutil`

**Location:** §4.2 FR-6

**Concern:** Targeted search found no public Apple framework API (e.g., nothing resembling a documented `CryptoUserAuthentication` or similar Security-framework call) for unlocking a non-boot APFS volume — only the `diskutil apfs unlockVolume` / `diskutil apfs listUsers` command-line surface is documented in the wild (via Eclectic Light's APFS command-tools reference and others). The practical implementation path is very likely shelling out to `diskutil` via `Process` and parsing its (undocumented-for-this-purpose) plist/text output, which is a legitimate pattern for a non-sandboxed direct-download app but is meaningfully different from "call a documented API" and should be named as such.

**Why it matters:** This affects reliability (parsing CLI output is brittler than a typed API) and the error-handling surface FR-6's Consequences imply ("An encrypted volume is clearly labeled... before credentials are requested") — distinguishing wrong-password from a `diskutil` version/format change needs explicit design attention.

**Suggested fix:** Fold into Open Question 4 (or add a new Open Question): confirm `diskutil apfs unlockVolume` (or an equivalent private framework call) as the chosen mechanism during the Architecture spike, and scope error handling (wrong password vs. tool/version drift) explicitly rather than leaving it implicit in FR-6.

### 4. [Medium] "Reproducible builds" stated more firmly than current Swift/Xcode tooling realistically supports

**Location:** §Cross-Cutting NFRs → Security

**Concern:** The NFR states builds "should be reproducible... and should not be treated as optional polish." Research on Swift/Xcode build reproducibility surfaced real, known sources of non-determinism in the standard toolchain: Xcode/SDK version drift between builds, environment variables (`DEVELOPER_DIR`, derived-data paths) leaking into build output, and no mainstream hermetic-build system in common use for Xcode-based macOS apps comparable to e.g. Bazel's or Debian's `reprotest` tooling. Achieving true bit-for-bit reproducibility would require deliberate toolchain pinning, a controlled/containerized build environment, and ongoing discipline most small open-source Mac projects don't carry — this is a real, non-trivial engineering investment, not a checkbox.

**Why it matters:** As worded, this NFR reads as a hard requirement Architecture must satisfy. If it's aspirational rather than committed, stating it this firmly risks either (a) Architecture under-delivering against a stated NFR, or (b) real effort diverted from the core recovery engine (finding #1, the actual highest-risk item) toward build tooling.

**Suggested fix:** Soften to: "Builds should aim for reproducibility where practical (pinned toolchain versions, documented build environment); where full bit-for-bit reproducibility proves impractical with standard Xcode tooling, verifiable build provenance (binaries built via public CI from a tagged commit, with published checksums and build logs) is the v1 bar, with full reproducibility as a stretch goal." This keeps the trust intent (independently verifiable builds) while being honest about the engineering cost, consistent with the brief's own "do not fabricate moats" discipline.

### 5. [Low] FR-10's "without altering the source disk's actual partition table" boundary is sound as stated — one clarifying addition recommended

**Location:** §4.4 FR-10

**Concern:** This is a pass, not a problem: research into TestDisk (the reference implementation this PRD's own addendum cites) confirms the same model is standard and achievable — TestDisk's analyze/list steps are non-destructive, and only an explicit, separate "Write" action touches the disk's actual partition table (which TestDisk itself treats as the dangerous step, warning users to verify first). FR-10 as written never commits to writing a partition table back to the source disk at all — it only commits to recovering files from the reconstructed structure — so the boundary is technically sound.

**Why it matters / suggested fix:** Worth a one-line addition to FR-10's Consequences closing off scope creep: "The app never exposes an action to write a reconstructed partition table back to the source disk in v1 — recovery is always file-copy-out, never partition-table repair-in-place." This pre-empts a natural, more dangerous feature request ("can it just fix my partition table instead of copying files out?") before it reaches Architecture or Epics.

## Sources consulted

- [APFS: Command tools — Eclectic Light](https://eclecticlight.co/2024/04/22/apfs-command-tools/) — `diskutil apfs unlockVolume`, `listUsers` documentation
- [FileVault Recovery — Check Point Harmony Endpoint guide](https://sc1.checkpoint.com/documents/Infinity_Portal/WebAdminGuides/EN/Harmony-Endpoint-Admin-Guide/Topics-HEP/FileVault-Recovery.htm) — `diskutil apfs unlockVolume -passphrase` flow
- [TestDisk — Wikipedia](https://en.wikipedia.org/wiki/TestDisk) — analyze/write-step distinction
- [TestDisk forum: No partition found after Deep Scan](https://forum.cgsecurity.org/phpBB3/viewtopic.php?p=16411) — real-world deep-scan/write caveats
- Swift/Xcode reproducible-build search did not surface authoritative first-party tooling; general knowledge of Xcode toolchain/SDK drift and environment-variable leakage applied — flagged as a gap for Architecture to verify directly rather than a confirmed claim.
