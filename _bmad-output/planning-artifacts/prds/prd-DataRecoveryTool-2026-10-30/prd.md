---
title: "PRD: Salvage"
status: final
created: 2026-10-30
updated: 2026-10-30
---

# PRD: Salvage

## 0. Document Purpose

This PRD is for whoever builds and reviews this product next: the PM/maintainer (Harrison), and the downstream BMAD workflows (UX, Architecture, Epics & Stories) that consume it. It builds on, and does not duplicate, the product brief and its addendum at `_bmad-output/planning-artifacts/briefs/brief-DataRecoveryTool-2026-10-30/` — read those for the fuller competitive landscape, recovery-technique background, and options considered (Electron vs. native, MIT vs. GPL). This document is structured capability-first: a Glossary anchors vocabulary, Features (§4) group Functional Requirements (FR-1 through FR-N, globally numbered, stable across reorganization), and every inferred `[ASSUMPTION]` is indexed in §9 for explicit confirmation.

**The three items that previously blocked public release are now resolved: the product name is Salvage, the license is MIT, and Developer ID signing/notarization is already available under HSmithDev LLC (see Open Questions 1–3 for the record). Nothing in this PRD blocks handing the feature set to UX/Architecture.**

## 1. Vision

Mac users who lose files — a corrupted external drive, a formatted SD card, an accidentally emptied Trash, a partition that silently disappeared — currently have one real option: hand raw, unfiltered access to their most sensitive data to a closed-source commercial tool (Disk Drill, EaseUS, Stellar) they cannot inspect, usually behind a paywall gating the moment they actually need the recovered files.

Salvage is a native macOS app that does the same job — scan a device, find what's recoverable, let the user browse and recover it — using the same proven techniques the category relies on (metadata-based undelete, signature-based file carving, lost-partition reconstruction), but fully open source, fully offline, and entirely free. No telemetry, no account, no scan/recover paywall split. The pitch isn't a better recovery algorithm on day one — mature closed-source tools have a head start there — it's that a tool whose entire job is reading your most sensitive data at the lowest level should be a tool you (or anyone) can actually verify, not one you're asked to trust on faith.

macOS is the deliberate starting point, not the ceiling. Once the recovery engine is solid, Linux and Windows support is an explicit intended direction — the engine is architected as a portable core from the start so a future cross-platform front end doesn't mean starting over.

## 2. Target User

### 2.1 Jobs To Be Done

- **Functional:** "When I've lost files from any block device (§3 Glossary), I want to scan it and recover what's left, using one tool regardless of device type."
- **Emotional/trust:** "When I'm about to hand a tool unrestricted access to a drive full of my sensitive files, I want to actually verify what it does — not just read a privacy policy — so I'm not trusting a stranger's word for it."
- **Financial:** "When I need to recover files, I want to do it without paying a license fee or subscription just to unlock files a free scan already found."
- **Contextual (builder/community):** "As a technically-minded user, I want to inspect, extend, or contribute to the recovery logic itself, not just consume a finished binary."

### 2.2 Non-Users (v1)

- Enterprise/forensic investigators needing chain-of-custody, legal-hold, or court-admissible reporting (R-Studio's and dedicated forensic tools' territory).
- Windows- or Linux-only users — v1 is macOS-only (see §5 Non-Goals; Linux/Windows is an explicit v2+ direction, not a v1 commitment).
- Users needing RAID array reconstruction or NAS/network-volume recovery.
- Users recovering data directly from iOS/mobile devices (Disk Drill supports this; out of scope here).

### 2.3 Key User Journeys

- **UJ-1. Sam recovers two years of photos off a drive that stopped mounting.**
  - **Persona + context:** Sam, a freelance photographer, plugs in an external SSD that macOS now refuses to mount — the Finder shows no volume at all.
  - **Entry state:** No prior app usage. Downloads Salvage, grants Full Disk Access when prompted.
  - **Path:** Opens the app, selects the external SSD from the device list (realizes FR-1). Starts a scan; sees live progress and files appearing by type as the scan runs (FR-2, FR-11). The scan surfaces a "Lost Partition" result distinct from the (absent) mounted volume (FR-9).
  - **Climax:** Sam opens the lost partition's results, sees thousands of photos bucketed under Pictures with high-confidence badges (recovered via intact metadata, FR-4, FR-12), previews a few to confirm they're intact (FR-13), and selects "Recover All" to a new external drive (FR-14).
  - **Resolution:** Recovery summary confirms file count, size, and destination; Sam opens the folder in Finder and confirms the photos are back, in their original folder structure and filenames.
  - **Edge case:** Some files in a heavily fragmented region show Low confidence (carved, no metadata, generic filename) — the UI is explicit about this rather than implying they're all equally safe to trust (realizes FR-12, FR-19).

- **UJ-2. Priya checks the tool is safe before trusting it with a client drive.**
  - **Persona + context:** Priya, a freelance editor under an NDA, needs to recover deleted project files from a USB drive but won't run a closed-source tool against client data.
  - **Entry state:** Found Salvage via its GitHub repo, not an app store. Reads the in-app "what this app reads and writes" explanation before doing anything else (FR-19).
  - **Path:** Confirms in Activity Monitor / Little Snitch (her own tooling, not the app's) that no network connections occur during a scan (realizes FR-17, FR-18). Runs the scan against the USB drive.
  - **Climax:** Recovers the deleted files to a separate destination folder; the app never asked for network access and the source drive's modification time didn't change.
  - **Resolution:** Priya trusts the tool for future client work specifically because she could verify the claim herself, not because of a brand name.
  - **Edge case:** If she points the recovery destination at the same volume she's scanning, the app blocks it with an explicit warning rather than silently proceeding (realizes FR-15 and the Safety guardrail in §Constraints).

## 3. Glossary

- **Block device** — A storage device macOS can address at the raw byte/sector level (internal drive, external HDD/SSD, USB flash drive, SD/memory card). The unit Salvage scans.
- **Source disk** — The block device being scanned/recovered from. Never written to (see FR-15).
- **Destination** — The location, on a different volume than the source disk, where recovered files are copied.
- **Scan session** — One run of scanning a selected source disk, producing a set of recoverable results.
- **Metadata-based undelete** — Recovery via intact filesystem metadata (APFS catalog/journal, HFS+ catalog, FAT/exFAT directory entries) that still records a deleted file's name, path, and timestamps.
- **Signature-based carving** (carving) — Recovery via scanning raw, unallocated bytes for known file-format signatures when filesystem metadata is gone. Produces a **reconstructed file**: recoverable content with no original filename, path, or timestamp.
- **Lost partition** — A filesystem signature found in a disk's unallocated space, outside the current partition table — detected and reconstructed separately from normal volume scanning (FR-9, FR-10).
- **Recovery confidence** — A per-file indicator (High/Medium/Low) reflecting how the file was recovered: High for intact metadata, Low for carving with no metadata. Must not overstate certainty (SM-C1).
- **Full Disk Access (FDA)** — The macOS Privacy & Security permission a user grants an app to read protected/raw storage locations. Required for this app's core function.
- **System Integrity Protection (SIP)** — macOS's kernel-level protection restricting raw system/disk access; interacts with how FDA and raw block-device reads work (see Open Question 4).
- **Notarization / Developer ID / Gatekeeper** — Apple's code-signing and malware-scanning pipeline required for a direct-download macOS app to launch without a security warning. Requires a paid Apple Developer Program membership (see Constraints: Cost).
- **FileVault** — macOS's built-in full-disk encryption. A FileVault-encrypted APFS volume must be unlocked (via password or recovery key) before metadata-based or carving recovery can run against it (FR-6).

## 4. Features

### 4.1 Device & Volume Scanning
**Description:** The entry point to every recovery session — select any block device (§3 Glossary) and scan it. Device-type-agnostic by design (realizes UJ-1): every device type is the same kind of scan target, not a separate product path.

**Functional Requirements:**

#### FR-1: Device selection
User can select any mounted or recognized block-device storage device (internal drive, external HDD/SSD, USB flash drive, SD/memory card) as a scan target.

**Consequences (testable):**
- Device list reflects currently attached/recognized storage devices without requiring app restart.
- Internal and external devices appear in the same list, not separate modes.

#### FR-2: Live scan progress
System displays live scan progress (percent complete, elapsed/estimated remaining time, files found so far) and streams results incrementally rather than blocking until the scan fully completes.

**Consequences (testable):**
- Progress UI updates at least every 2 seconds during an active scan `[ASSUMPTION: 2-second threshold, confirm or adjust]`.
- Found files appear in results as they're discovered, not only after 100% completion.

#### FR-3: Scan control
User can pause, resume, or cancel an in-progress scan without losing results already found.

**Consequences (testable):**
- Cancelling a scan preserves and displays results found up to that point.
- Resuming a paused scan continues from where it left off rather than restarting.

### 4.2 Filesystem-Aware Recovery (Metadata-Based Undelete)
**Description:** When filesystem metadata survives, recovery is high-fidelity — original filename, path, and timestamp intact. Covers the most common and most trustworthy recovery case (realizes UJ-1's high-confidence results).

**Functional Requirements:**

#### FR-4: Metadata-based undelete
System recovers deleted-but-not-yet-overwritten files by reading intact filesystem metadata, preserving original filename, path, and timestamps.

**Consequences (testable):**
- Recovered files via this path retain their original name and folder structure where the metadata recorded it.
- Files recovered this way are flagged High recovery confidence (FR-12).

#### FR-5: Filesystem support
System supports APFS, HFS+, FAT32, and exFAT as scan and recovery targets.

**Consequences (testable):**
- A scan against a volume or lost partition using one of the four supported filesystems completes and surfaces results.
- A scan against an unsupported filesystem flags it as unsupported to the user rather than silently producing empty or incorrect results.

**Out of Scope:** NTFS, EXT2/3/4, ReFS, UFS (R-Studio's broader list) — not needed for the primary macOS-native use case; revisit only if Windows/Linux support (§1 Vision) materializes.

**Note:** APFS's on-disk format is proprietary and undocumented by Apple for third-party parsing — this is the single largest engineering risk in this FR set, not a routine integration. See Open Question 9.

#### FR-6: FileVault volume support
System detects FileVault-encrypted APFS volumes and prompts the user for their password or recovery key to unlock the volume before metadata-based recovery or carving runs against it.

**Consequences (testable):**
- An encrypted volume is clearly labeled as such before the user is asked for credentials.
- Scanning does not proceed against an encrypted volume's contents without successful unlock.
- Unlocking uses the most read-only access path macOS permits for the volume; any OS-level touch that unlocking itself unavoidably causes is disclosed in the in-app transparency statement (FR-19) rather than silently treated as compliant with FR-15's read-only guarantee. (Which specific OS mechanism causes such a touch is an Architecture question — see Open Question 10.)
- A failed unlock attempt distinguishes a wrong password/key from an unexpected tool- or macOS-version-related failure, rather than presenting both as the same generic error.

### 4.3 Signature-Based File Carving
**Description:** When metadata is gone — a reformatted drive, a badly corrupted filesystem — this is the fallback that still gets files back, with an honest trade-off: no original name, path, or timestamp (realizes UJ-1's edge case).

**Functional Requirements:**

#### FR-7: Signature-based carving
When filesystem metadata is unavailable, system scans raw, unallocated bytes for known file-format signatures and reconstructs files without relying on filesystem metadata.

**Consequences (testable):**
- Carving runs automatically as part of a scan when metadata-based recovery can't account for a region of the disk — not a separate manual mode.
- Reconstructed files are flagged Low or Medium recovery confidence (FR-12), never High.

#### FR-8: Reconstructed file naming and organization
Reconstructed files (no original name available) are named deterministically (type, dimensions/size, and a sequence number) and grouped under a "Reconstructed" folder by detected file type.

**Consequences (testable):**
- Two reconstructed files of the same type never collide on the same generated filename within one scan session.
- Every reconstructed file lands under `Reconstructed/<type>/`.

**Feature-specific NFRs:**
- Fragmented files that can't be fully reconstructed must be either recovered partially with a clear "partial/corrupted" indicator, or excluded — never presented as a complete, trustworthy file when they aren't (ties to SM-C1).

### 4.4 Lost Partition Detection & Reconstruction
**Description:** A drive that no longer mounts at all isn't "empty" — this feature finds the filesystem signature hiding in the disk's unallocated space and makes it recoverable as its own result, separate from the (absent) current partition table (realizes UJ-1's core scenario).

**Functional Requirements:**

#### FR-9: Lost partition detection
System scans unallocated disk space for recognizable filesystem signatures and surfaces any found as a distinct "Lost Partition" result, separate from currently-mounted-volume results.

**Consequences (testable):**
- A lost partition result never merges with or appears inside the normal mounted-volume results list; the UI distinguishes it as its own category (see the Lost Partitions panel, §Information Architecture).

#### FR-10: Lost partition recovery
User can select a detected lost partition and run full recovery (metadata-based undelete and/or carving, per FR-4/FR-7) against its reconstructed structure, without altering the source disk's actual, on-disk partition table.

**Consequences (testable):**
- Recovering from a lost partition never modifies the source disk itself — the reconstruction exists only in the app's working memory/scan state, consistent with FR-15's read-only guarantee.
- The app never exposes an action to write a reconstructed partition table back to the source disk in v1 — recovery from a lost partition is always file-copy-out to a separate destination, never partition-table repair-in-place.

### 4.5 Scan Results & Recovery UI
**Description:** The screen the user spends the most time in — browsing what was found, deciding what to trust, and getting it out. Matches the file-type-bucketed, preview-driven experience established by the category's reference UX (Disk Drill, EaseUS), realizes both UJs.

**Functional Requirements:**

#### FR-11: Type-bucketed results
Scan results are grouped by file type (Pictures, Videos, Audio, Documents, Archives, Other) with per-category file counts and aggregate size.

**Consequences (testable):**
- Every recovered file appears in exactly one type category (including the Other catch-all for unrecognized types).
- Displayed category counts and aggregate size match the files actually listed under that category.

#### FR-12: Recovery confidence indicator
Each recoverable file shows a recovery-confidence indicator (High/Medium/Low) reflecting whether it was recovered via intact metadata (High) or carving with partial/no metadata (Medium/Low). The scoring must be conservative — never implying more certainty than the recovery method actually supports (ties to SM-C1; exact scoring methodology is Open Question 7).

**Consequences (testable):**
- Every file recovered via FR-4 (intact metadata, no partial-overwrite evidence) is labeled High.
- Every file recovered via FR-7 (carving, no filesystem metadata) is never labeled High — Medium at most, and Low when the carve is partial or fragmented.
- This binary floor (metadata-recovered = High, carved = not-High) is the v1 bar; the finer Medium/Low boundary and any evidence-based adjustments are defined during Architecture per Open Question 7, not invented ad hoc before then.

#### FR-13: File preview
User can preview a recoverable file (image thumbnail/full preview; document, video, and audio preview where format support allows) before committing to recover it.

**Consequences (testable):**
- Selecting a file with a supported preview format renders a preview without first requiring recovery.
- A file with no supported preview format shows an explicit "no preview available" state rather than a blank or broken one.

**Out of Scope:** Preview for formats with no native macOS preview support (e.g., obscure proprietary formats) — file still recoverable, just without a preview.

#### FR-14: Selective and bulk recovery
User can select one, several, or all recoverable files or categories and recover them to a destination folder of their choosing.

**Consequences (testable):**
- Recovering a partial selection copies only the selected files to the destination, byte-identical to the source read.
- Recovering "all" within a category or scan covers every item currently listed in that scope.

#### FR-15: Read-only source guarantee
System never writes to the source disk at any point during scanning or recovery, and blocks (with an explicit warning) any attempt to set the recovery destination to the same volume as the source.

**Consequences (testable):**
- Source disk's filesystem metadata (e.g., modification times at the volume level) is unchanged after a full scan-and-recover session.
- Attempting to select the source volume as the destination surfaces a blocking warning, not a silent failure or silent allowance.
- The one documented exception is FR-6's FileVault unlock step: any unavoidable OS-level touches it causes are disclosed per FR-6/FR-19, not treated as a silent violation of this guarantee.

#### FR-16: Recovery completion summary
On completing a recovery, system confirms file count, total size, source device, and destination path, with a direct action to reveal the destination in Finder.

**Consequences (testable):**
- The file count and total size shown match what was actually written to the destination, not the pre-recovery selection count, if any copy failures occurred.
- The Finder action opens directly at the destination folder.

### 4.6 Privacy & Transparency
**Description:** The product's actual differentiator (per the brief): not a better recovery engine on day one, but a verifiably trustworthy one. These FRs make the "fully offline, no telemetry" claim a checkable product behavior, not a marketing line (realizes UJ-2 directly).

**Functional Requirements:**

#### FR-17: No automatic network activity
System makes zero network calls during scanning or recovery. The only network activity anywhere in the app is an explicit, user-initiated "Check for Updates" action — never automatic, never on launch.

**Consequences (testable):**
- No network connections are observed (e.g., via Little Snitch or equivalent) during a scan or recovery session.
- The update check only occurs when the user explicitly triggers it from a visible, intentional control.

#### FR-18: No telemetry
System collects no usage analytics, crash telemetry, or any other data about how the app is used — no opt-out setting is needed because there is nothing being collected to opt out of.

**Consequences (testable):**
- No analytics or crash-reporting SDK is linked into the app.
- A network-activity audit (e.g., via Little Snitch) during any scan or recovery session shows zero outbound connections, consistent with FR-17.

#### FR-19: In-app transparency statement
App includes a plain-language, in-app explanation of exactly what it reads from and writes to the user's system, and when — addressing the "why should I trust this" question directly rather than leaving it to a README.

**Consequences (testable):**
- The explanation is reachable from the main app UI — not only the README or website — before or during a user's first scan.
- It names the specific read path (source disk, read-only) and the specific write path (destination folder only), and is updated to disclose FR-6's unlock-step exception once that's defined.

## 5. Non-Goals (Explicit)

- Windows or Linux builds in v1 — an explicit v2+ direction (§1 Vision), not a v1 commitment.
- RAID array reconstruction and NAS/network-volume recovery.
- Recovery directly from iOS/mobile devices.
- Adjacent utilities bundled by competitors: video repair, byte-to-byte disk imaging/backup, duplicate-file finder, secure data shredding, S.M.A.R.T. drive-health monitoring.
- Mac App Store distribution — App Sandbox is incompatible with the raw block-device access this app requires (see Constraints: Cost, and the brief's addendum for the technical detail); ships as a notarized direct download only.
- Any telemetry, analytics, or usage tracking, now or later, without a full re-evaluation of the product and its trust positioning (this is a stated product value, not a missing feature).
- Automatic, scheduled, or background scanning — every scan is a user-initiated session.
- A public library/API surface for the recovery engine in v1. The engine should be *architected* for future reuse (§1 Vision, portability for Linux/Windows), but a committed, versioned public interface is not a v1 deliverable.
- Any paid tier, license key, or feature gating — contradicts the free/open-source model (§Constraints: Monetization).

## 6. MVP Scope

### 6.1 In Scope
- Scanning any block-device storage type macOS can mount or recognize (FR-1).
- APFS, HFS+, FAT32, exFAT filesystem support, including FileVault-encrypted APFS volumes (FR-4–FR-6).
- Signature-based file carving as a fallback when metadata is unavailable (FR-7–FR-8).
- Lost-partition detection and reconstruction (FR-9–FR-10).
- Full scan-results UI: type-bucketed dashboard, lost-partitions panel, file browser with preview and recovery-confidence indicators, selective/bulk recovery to a chosen destination (FR-11–FR-16).
- Zero-telemetry, zero-automatic-network-call operation, with an in-app transparency statement (FR-17–FR-19).

### 6.2 Out of Scope for MVP
- Everything listed under §5 Non-Goals.
- A command-line interface alongside the GUI — not decided either way; deferred (Open Question 6).
- Any additional file-format carving signatures beyond an initial common-format set (images, video, audio, documents, archives) — expanding the signature library is an ongoing, community-extensible effort, not a one-time v1 deliverable `[NOTE FOR PM: this is a natural first-contribution area once the project is public]`.

## 7. Success Metrics

*No telemetry (FR-18) means these cannot be measured via instrumentation — all primary metrics rely on community-reported, qualitative signals by design. This is a direct, intentional trade-off against the privacy positioning, not an oversight.*

**Primary**
- **SM-1**: Community-reported successful recovery outcomes across each supported filesystem (APFS, HFS+, FAT32, exFAT), with at least one validated lost-partition-reconstruction report per filesystem — tracked via GitHub issues/discussions. Validates FR-4–FR-10.
- **SM-2**: Adoption signals — GitHub stars, release download counts, inbound mentions in relevant communities. Validates overall product-market signal for the open-source positioning.

**Secondary**
- **SM-3**: External contribution rate — community-submitted PRs merged (new filesystem/signature support, bug fixes) within the first 6 months of public availability `[ASSUMPTION: 6-month window, confirm]`. Validates the "community-extensible" part of the differentiation claim.
- **SM-4**: Zero confirmed reports of the app writing to or corrupting a source disk. This is a floor, not a target to optimize — but the single most reputation-critical metric for this product category. Validates FR-15.

**Counter-metrics (do not optimize)**
- **SM-C1**: Recovery-confidence label accuracy must not be inflated to produce more "High confidence" results for better-looking demos or reviews. Counterbalances SM-1/SM-2 — don't chase adoption by overstating capability.
- **SM-C2**: Scan speed must not be optimized at the expense of the read-only safety guarantee (FR-15) — e.g., no write-based caching to the source disk for performance. Counterbalances future performance pressure.
- **SM-C3**: Feature or device-type breadth must not come at the expense of the zero-telemetry/zero-network guarantee (FR-17, FR-18) — e.g., no "let's just add anonymous usage stats to prioritize better" under adoption pressure from SM-2.

## 8. Open Questions

1. **~~Product name~~ — RESOLVED.** Salvage.
2. **~~License~~ — RESOLVED.** MIT.
3. **~~Who funds the $99/yr Apple Developer Program fee~~ — RESOLVED.** Developer ID signing/notarization is already available under HSmithDev LLC.
4. **(Pre-Architecture technical spike, with 9 and 10 below — one connected investigation, not three unrelated unknowns) Exact Full Disk Access / SIP entitlement mechanics** for raw `/dev/diskN` access were not independently confirmed during research. Needs a hands-on technical spike before Architecture finalizes the access model — current working assumption (FDA + Developer ID signing suffices, matching competitors) should be treated as unverified until then.
5. **Minimum supported macOS version.** Not yet set `[ASSUMPTION: macOS 14 Sonoma or later, pending confirmation against real target-user OS distribution]`.
6. **Should a command-line interface accompany the GUI** (TestDisk/PhotoRec-style, for power users or scripting)? Not decided.
7. **Recovery-confidence scoring methodology.** FR-12 requires a conservative, honest scoring approach, but the concrete algorithm (what evidence maps to High/Medium/Low) needs to be defined during Architecture or UX — a label invented ad hoc risks violating SM-C1.
8. **Initial file-format signature list for carving (FR-7).** Which formats ship in the v1 signature set vs. are added later via community contribution (§6.2 note)?
9. **APFS parsing strategy** *(same spike as 4 and 10)*. No public Apple API exists for third-party raw APFS metadata parsing. FR-4/FR-5/FR-9/FR-10 currently read as a routine filesystem-support line item, but this is the single largest engineering investment in the project. Needs a decision: reverse-engineer the format from scratch, adapt an existing open-source APFS reader (e.g., apfs-fuse, Sleuthkit's APFS module), or use a private/undocumented Apple framework — plus a maintenance plan for format drift across macOS releases. `[NOTE FOR PM: flagged for Architecture as the highest-risk technical decision in the project, not a routine integration.]`
10. **FileVault unlock mechanism and its interaction with the read-only guarantee (FR-6, FR-15)** *(same spike as 4 and 9)*. No documented public Swift/ObjC API was found for unlocking a non-boot APFS volume — the practical path is very likely shelling out to `diskutil apfs unlockVolume`. Needs confirmation during the Architecture spike of: the unlock mechanism itself, how to distinguish a wrong-password failure from a tool/version-drift failure, and whether a strictly read-only, non-journal-replaying access path exists for an unlocked volume — so FR-6 cannot silently violate FR-15.

## 9. Assumptions Index

- FR-2: progress-update staleness threshold assumed at 2 seconds.
- §Cross-Cutting NFRs / Accessibility: standard Apple HIG / VoiceOver support assumed as the baseline for primary flows, not separately specified per feature.
- §Platform: minimum macOS version assumed as macOS 14 Sonoma or later (also Open Question 5).
- SM-3: contribution-rate measurement window assumed at 6 months post public availability.
- §Cross-Cutting NFRs / Security: "verifiable build provenance" (not full bit-for-bit reproducibility) assumed as the v1 trust mechanism for builds — needs confirmation this is the intended bar.

---

## Cross-Cutting NFRs

- **Performance:** No fixed throughput target is promised (recovery speed depends heavily on device size, speed, and damage). What's required is responsiveness: progress visibility within the threshold in FR-2, incremental result streaming (FR-2), and a scan that is always pausable/cancellable (FR-3) rather than an opaque long-running black box.
- **Reliability/Safety:** Read-only against the source disk at all times (FR-15); destination-equals-source is a blocking condition, not a warning the user can dismiss blindly.
- **Security:** Code-signed with a Developer ID and notarized (see Constraints: Cost) despite not shipping via the Mac App Store; Full Disk Access requested only when the user initiates a scan, not on first launch. Builds should aim for reproducibility where practical (pinned toolchain versions, a documented build environment); standard Xcode/Swift tooling has known sources of non-determinism (SDK version drift, environment leakage) that make full bit-for-bit reproducibility a real engineering investment, not a checkbox. Where full reproducibility proves impractical, **verifiable build provenance** — binaries built via public CI from a tagged commit, with published checksums and build logs — is the v1 bar, with full reproducibility as a stretch goal `[ASSUMPTION: confirm this framing is the intended trust mechanism rather than a harder reproducibility commitment]`.
- **Accessibility:** Standard Apple Human Interface Guidelines compliance, including VoiceOver support, for all primary flows (device selection, scan progress, results browsing, recovery) `[ASSUMPTION: standard HIG/VoiceOver support assumed as the baseline, not separately specified per feature]`.
- **Maintainability/Extensibility:** The recovery engine (filesystem parsers, carving signatures, partition reconstruction) is built as a module with a clear boundary from the UI layer — this directly serves both the open-source contribution model (§Target User JTBD) and the longer-term cross-platform vision (§1), and is a real architectural constraint, not just an aspiration.
- **Observability:** Local-only, user-accessible scan logs for the user's own troubleshooting are acceptable; nothing is ever transmitted off-device (consistent with FR-17/FR-18).

## Constraints and Guardrails

**Safety**
- The app never writes to the source disk during scanning or recovery (FR-15).
- The recovery destination must be on a different volume than the source; the app blocks (does not just warn and allow) an attempt to set them the same.
- No automatic or background scanning — every scan is a deliberate, user-initiated action.
- Standard open-source "as-is, no warranty" licensing disclaimer applies. This doesn't substitute for FR-19's in-app transparency: the app should still state plainly, in-product, what it does and doesn't guarantee — trust is a product behavior here, not just a legal footnote.

**Privacy**
- Zero telemetry, zero analytics, zero automatic network calls (FR-17, FR-18) — this is the product's central trust claim, and because the source is open, it's independently verifiable rather than a policy promise.
- The sole network exception is a manual, user-initiated "Check for Updates" action (FR-17) — any future addition of network behavior needs the same bar of justification and disclosure.

**Cost**
- Apple's $99/yr Developer Program membership is required for Developer ID signing and notarization, regardless of the app itself being free. This is already covered — signing/notarization is available under HSmithDev LLC's existing Developer Program membership (see Open Question 3) — so this is no longer a release blocker, though it remains a real recurring cost worth tracking for a project with no monetization.

## Monetization

Free and fully open source, released under the MIT license (confirmed). No license key, no feature gating between "free scan" and "paid recovery," no subscription, no in-app purchase. This is a stated product value (differentiation, per the brief) as much as a pricing decision — any future monetization discussion would need to be reconciled against the trust positioning in §4.6, not layered on quietly.

## Platform

Native macOS app (Swift/SwiftUI), v1. Minimum supported macOS version not yet confirmed `[ASSUMPTION: macOS 14 Sonoma+, see Open Question 5]`. Linux and Windows support is an explicit v2+ direction (§1 Vision) — the recovery engine's architecture should anticipate this (Maintainability/Extensibility NFR above), but no second platform is a v1 deliverable (§5 Non-Goals).

## Aesthetic and Tone

Calm, plain-language, and non-alarmist — the user arriving at this app is often already stressed about lost data; product copy should state facts directly ("This file could not be fully reconstructed" rather than vague reassurance or marketing language) rather than oversell results. No urgency-driven upsell language of the kind common in commercial competitors (there's nothing to upsell), and recovery-confidence language in particular should err toward honest understatement rather than optimistic framing (ties directly to SM-C1). Product copy and any public-facing material should credit the established techniques this app builds on — metadata-based undelete, signature-based carving (as pioneered by PhotoRec), and lost-partition reconstruction (as pioneered by TestDisk) — rather than imply novel invention, consistent with the brief's honesty-about-the-moat stance in §What Makes This Different.

## Information Architecture

Top-level surfaces, at a capability level (detailed screen design belongs to `bmad-ux`):
- **Device & Volume Picker / Dashboard** — select a scan target (FR-1).
- **Scan Progress** — live progress, pause/cancel (FR-2, FR-3).
- **Scan Results** — type-bucketed dashboard plus a distinct Lost Partitions panel (FR-9, FR-11).
- **File Browser & Preview** — browse, preview, and select files for recovery, with confidence indicators (FR-12–FR-14).
- **Recovery Summary** — completion confirmation with a direct path to the recovered files (FR-16).
