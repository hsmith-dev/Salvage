---
status: final
stepsCompleted: [step-01-validate-prerequisites, step-02-design-epics, step-03-create-stories, step-04-final-validation]
inputDocuments:
  - _bmad-output/planning-artifacts/prds/prd-DataRecoveryTool-2026-10-30/prd.md
  - _bmad-output/planning-artifacts/architecture/architecture-DataRecoveryTool-2026-10-30/ARCHITECTURE-SPINE.md
  - _bmad-output/planning-artifacts/architecture/architecture-DataRecoveryTool-2026-10-30/ARCHITECTURE.md
---

# Salvage - Epic Breakdown

## Overview

This document provides the complete epic and story breakdown for Salvage, decomposing the requirements from the PRD and the Architecture spine into implementable stories. No UX design contract exists yet; UI-heavy stories cite the PRD's Information Architecture and Aesthetic and Tone sections instead.

## Requirements Inventory

### Functional Requirements

FR-1: User can select any mounted or recognized block-device storage device (internal drive, external HDD/SSD, USB flash drive, SD/memory card) as a scan target. v1 excludes the live boot volume (cannot be unmounted while running).
FR-2: System displays live scan progress (percent, elapsed/remaining time, files found) and streams results incrementally.
FR-3: User can pause, resume, or cancel an in-progress scan without losing results already found.
FR-4: System recovers deleted-but-not-yet-overwritten files by reading intact filesystem metadata, preserving original filename, path, and timestamps.
FR-5: System supports APFS, HFS+, FAT32, and exFAT as scan and recovery targets.
FR-6: System detects FileVault-encrypted APFS volumes and prompts for a password/recovery key to unlock before recovery runs.
FR-7: When filesystem metadata is unavailable, system scans raw unallocated bytes for known file-format signatures and reconstructs files without relying on metadata.
FR-8: Reconstructed files are named deterministically and grouped under a "Reconstructed" folder by detected file type.
FR-9: System scans unallocated disk space for recognizable filesystem signatures and surfaces any found as a distinct "Lost Partition" result.
FR-10: User can select a detected lost partition and run full recovery against its reconstructed structure, without altering the source disk's actual partition table.
FR-11: Scan results are grouped by file type (Pictures, Videos, Audio, Documents, Archives, Other) with per-category counts and aggregate size.
FR-12: Each recoverable file shows a recovery-confidence indicator (High/Medium/Low) reflecting how it was recovered.
FR-13: User can preview a recoverable file before committing to recover it.
FR-14: User can select one, several, or all recoverable files/categories and recover them to a chosen destination.
FR-15: System never writes to the source disk at any point during scanning or recovery, and blocks setting the destination to the same volume as the source.
FR-16: On completing a recovery, system confirms file count, total size, source device, and destination path, with a direct Finder action.
FR-17: System makes zero network calls during scanning or recovery; the only network activity is an explicit, user-initiated "Check for Updates" action.
FR-18: System collects no usage analytics, crash telemetry, or any other data about how the app is used.
FR-19: App includes a plain-language, in-app explanation of exactly what it reads from and writes to the user's system, and when.

### NonFunctional Requirements

NFR1 (Performance): No fixed throughput target; progress visibility within ~2s, incremental result streaming, always pausable/cancellable.
NFR2 (Reliability/Safety): Read-only against the source disk at all times; destination-equals-source is a blocking condition.
NFR3 (Security): Code-signed with a Developer ID and notarized; Full Disk Access requested only when the user initiates a scan; verifiable build provenance (checksums + build logs from public CI).
NFR4 (Accessibility): Standard Apple HIG compliance, including VoiceOver support, for all primary flows.
NFR5 (Maintainability/Extensibility): The recovery engine is a module with a clear boundary from the UI layer, serving both open-source contribution and the longer-term cross-platform vision.
NFR6 (Observability): Local-only, user-accessible scan logs; nothing ever transmitted off-device.
NFR7 (Safety/Privacy constraints): No automatic/background scanning; zero telemetry/analytics/automatic network calls; "as-is, no warranty" disclaimer stated plainly in-product.
NFR8 (Cost): Developer ID signing/notarization already available under HSmithDev LLC — no release-blocking funding gap.

### Additional Requirements

- **Module structure (Architecture AD-1):** Three-package hexagonal split — `SalvageCore` (portable recovery engine, zero AppKit/SwiftUI/DiskArbitration/IOKit dependencies), `SalvageDiskIO` (macOS adapter: DiskArbitration, raw reads, FileVault unlock, exclusive DiskArbitration owner), `Salvage` (SwiftUI app, composition root). This is the de facto starting scaffold for Epic 1 Story 1 — no third-party starter template is used (native Xcode app consuming local SwiftPM packages, per Architecture Stack).
- **APFS parsing strategy (AD-2, `[ASSUMPTION]` flagged for user confirmation):** Original MIT-licensed Swift code informed by Apple's 2018 APFS Reference — never linking/vendoring GPL/LGPL parsers (apfs-fuse, libfsapfs, Sleuth Kit). Single highest engineering risk in the project; a timeboxed spike is recommended before broad implementation.
- **FileVault unlock mechanism (AD-3):** `diskutil apfs unlockVolume <device> -nomount`, credentials held transiently and zeroized after use.
- **Raw read path and type-level read-only enforcement (AD-4):** `DADiskCreateFromBSDName` → `DADiskUnmount` → unbuffered `open()`/`read()` on `/dev/rdiskN`. `BlockReader` port has no write method. `SalvageDiskIO` owns a single-session-per-device lock. Boot-volume exception applies (see FR-1).
- **Scan event protocol (AD-11):** `ScanEvent` is a closed enum (`.progress`, `.found`, `.lostPartitionFound`, `.unlockRequired`, `.error`, `.completed`) delivered via `AsyncStream<ScanEvent>`. Pause = actor-held resumable gate (same Task); Cancel = Task cancellation (terminal); `ScanSession` checkpoints byte offset for cold-start resume. Mid-scan FileVault unlock is supported via `.unlockRequired`.
- **Carving signature schema (AD-6):** Declarative JSON definitions with a required `schemaVersion` field; engine ignores unknown fields rather than rejecting them (community-contribution surface).
- **Confidence scoring (AD-7):** One pure function in `SalvageCore`; evidence inputs are graduated (`fragmentCount: Int`, `overwriteConfidence: Double`), never booleans.
- **Destination safety (AD-8):** Volume-identity comparison via a `SalvageDiskIO`-exposed API (never a direct DiskArbitration call from the app, never path-string comparison); writes proceed file-by-file with per-file success/failure reported back, not an all-or-nothing batch.
- **CI-enforced boundaries (AD-9):** Build fails if `AppKit`/`SwiftUI`/`IOKit` is imported in `SalvageCore`, or if `DiskArbitration` is imported anywhere outside `SalvageDiskIO`; CI also checks `SalvageCore`'s resolved dependency graph for transitive platform-framework leaks.
- **Zero-network enforcement (AD-12):** Build fails if any network API appears anywhere except one designated update-check file in the `Salvage` app target.
- **Release pipeline (AD-10):** GitHub Actions, `notarytool`-based signing/notarization using HSmithDev LLC's Developer ID, GitHub Releases distribution with published SHA-256 checksums.
- **Testing strategy (Deferred in spine, not silent):** The hexagonal boundary and injectable `BlockReader` port are deliberately structured for testability (file-backed/in-memory reader, no real disk needed for `SalvageCore` tests) — concrete framework/coverage approach is left to implementation, should be addressed early in Epic 1.
- **Open spike before implementation-heavy work:** Exact Full Disk Access/SIP entitlement requirements at the raw-device level, and whether Apple's newer FSKit framework has any bearing, are unconfirmed (PRD Open Question 4 / spine Deferred) — needs a hands-on spike, ideally as an early Epic 1 story, before committing deeply to the DiskArbitration-based access model.

### UX Design Requirements

None — no UX design contract exists yet. UI-heavy stories reference the PRD's Information Architecture (Device/Volume Picker, Scan Progress, Scan Results, File Browser & Preview, Recovery Summary) and Aesthetic and Tone sections directly.

### FR Coverage Map

FR-1: Epic 1 - Device selection (block-device agnostic, boot volume excluded)
FR-2: Epic 1 - Live scan progress
FR-3: Epic 1 - Scan pause/resume/cancel
FR-4: Epic 1 - Metadata-based undelete
FR-5: Epic 1 (FAT32/exFAT) + Epic 2 (APFS/HFS+) - Filesystem support
FR-6: Epic 2 - FileVault volume support
FR-7: Epic 3 - Signature-based carving
FR-8: Epic 3 - Reconstructed file naming/organization
FR-9: Epic 3 - Lost partition detection
FR-10: Epic 3 - Lost partition recovery
FR-11: Epic 1 - Type-bucketed results
FR-12: Epic 1 - Recovery confidence indicator
FR-13: Epic 1 - File preview
FR-14: Epic 1 - Selective and bulk recovery
FR-15: Epic 1 - Read-only source guarantee
FR-16: Epic 1 - Recovery completion summary
FR-17: Epic 1 - No automatic network activity
FR-18: Epic 1 - No telemetry
FR-19: Epic 1 - In-app transparency statement

*NFRs (NFR1-NFR8) are cross-cutting: established as Definition of Done in Epic 1 (module scaffold, CI-enforced boundaries, release pipeline, read-only/privacy guarantees) and maintained by every subsequent epic, not individually re-delivered.*

## Epic List

### Epic 1: Recover Files from Everyday Removable Media, Transparently and Safely
A user can scan a USB drive, SD card, or external drive formatted FAT32 or exFAT, watch live progress, browse results bucketed by file type with an honest recovery-confidence indicator, preview files before committing, and recover selected files to a destination of their choice — all while being able to verify, not just trust, that the app made zero network calls and did nothing it didn't disclose. This epic also stands up the project's foundation: the three-module scaffold (`SalvageCore`/`SalvageDiskIO`/`Salvage`), CI-enforced module and network boundaries (AD-9, AD-12), the scan event protocol (AD-11), destination-safety enforcement (AD-8), and the signed/notarized release pipeline (AD-10) needed to ship anything at all. The Full Disk Access/SIP entitlement spike (PRD Open Question 4) runs early here, since the raw-read path every later epic depends on rests on its answer.
**FRs covered:** FR-1, FR-2, FR-3, FR-4, FR-5 (FAT32/exFAT), FR-11, FR-12, FR-13, FR-14, FR-15, FR-16, FR-17, FR-18, FR-19

### Epic 2: Recover from Mac-Native Drives, Including Encrypted Ones
A user can scan and recover from APFS- or HFS+-formatted drives — internal (non-boot) and external — including FileVault-encrypted volumes, unlocked safely via `diskutil apfs unlockVolume -nomount` with credentials held only transiently, and with the same confidence-indicator and recovery flow Epic 1 established. This is where the project's single biggest engineering risk lives: an original, MIT-licensed, from-scratch APFS parser (AD-2, still flagged `[ASSUMPTION]` pending explicit confirmation). A timeboxed technical spike against a read-only, unencrypted APFS volume is recommended before committing to full-epic scope.
**FRs covered:** FR-5 (APFS/HFS+), FR-6

### Epic 3: Recover from Severely Damaged or Unmountable Media
A user whose drive won't mount at all, or is too corrupted for normal undelete, can still get files back: signature-based carving reconstructs files from raw bytes when filesystem metadata is gone, and lost-partition detection finds and recovers from a filesystem signature hiding in unallocated space — the "nothing else worked" safety net, using the declarative, community-extensible signature format (AD-6) and graduated confidence evidence (AD-7). This epic reuses Epic 1's results browser, confidence indicator, and recovery flow almost entirely; the work here is concentrated in `SalvageCore`, not new UI surfaces.
**FRs covered:** FR-7, FR-8, FR-9, FR-10

## Epic 1: Recover Files from Everyday Removable Media, Transparently and Safely

A user can scan a USB drive, SD card, or external drive formatted FAT32 or exFAT, watch live progress, browse results bucketed by file type with an honest recovery-confidence indicator, preview files before committing, and recover selected files to a destination of their choice — all while being able to verify, not just trust, that the app made zero network calls and did nothing it didn't disclose. This epic also stands up the project's foundation: the three-module scaffold, CI-enforced boundaries (AD-9, AD-12), the scan event protocol (AD-11), destination-safety enforcement (AD-8), and the signed/notarized release pipeline (AD-10) needed to ship anything at all.

### Story 1.1: Project Foundation — Trustworthy Module Scaffold

As a maintainer,
I want the three-module project (SalvageCore/SalvageDiskIO/Salvage) scaffolded with CI-enforced import boundaries and a signed/notarized build pipeline,
So that every later feature builds on a foundation that already guarantees module isolation and distribution trust.

**Acceptance Criteria:**

**Given** a fresh checkout
**When** CI runs
**Then** it fails the build if SalvageCore imports AppKit/SwiftUI/IOKit, or if DiskArbitration is imported anywhere outside SalvageDiskIO (AD-9)

**Given** a tagged commit
**When** the release workflow runs
**Then** it produces a Developer-ID-signed, notarized `.app` with published SHA-256 checksums (AD-10)

**Given** no recovery features are implemented yet
**When** a user opens the app
**Then** it presents a minimal shell with zero network calls (FR-17/FR-18 hold from the first build)

### Story 1.2: Full Disk Access / Raw Device Access Spike

As a maintainer,
I want to confirm, hands-on, exactly what macOS permission and API path is required to read a raw block device,
So that the rest of Epic 1's recovery work is built on a verified access model instead of an unconfirmed assumption (PRD Open Question 4).

**Acceptance Criteria:**

**Given** a Developer-ID-signed, non-sandboxed build with Full Disk Access granted
**When** the app attempts `DADiskCreateFromBSDName` + `DADiskUnmount` + raw `open()`/`read()` on `/dev/rdiskN` for a test external device
**Then** the read succeeds and the exact required permission/entitlement combination is documented

**Given** the same attempt without Full Disk Access granted
**When** read is attempted
**Then** the actual failure mode is observed and documented

**Given** findings from this spike
**When** complete
**Then** `ARCHITECTURE-SPINE.md`'s Deferred/AD-4 is updated to reflect the confirmed (not assumed) access model

### Story 1.3: Select and List Scan-Target Devices

As a user,
I want to see a list of storage devices I can scan,
So that I can pick the drive I lost files on.

**Acceptance Criteria:**

**Given** one or more external/internal (non-boot) block devices are attached
**When** I open the device picker
**Then** I see all of them listed without needing to restart the app

**Given** the currently-running boot volume
**When** I view the device list
**Then** it is excluded or clearly marked unsupported, not offered as a scan target

**Given** internal and external devices are both present
**When** I view the list
**Then** they appear together, not in separate modes

### Story 1.4: Scan a FAT32/exFAT Device with Live Progress

As a user,
I want to start a scan on my chosen device and watch its progress live,
So that I know the app is working and roughly how long it will take.

**Acceptance Criteria:**

**Given** I've selected a FAT32 or exFAT device
**When** I start a scan
**Then** progress (percent, elapsed/estimated remaining time, files found so far) updates at least every ~2 seconds

**Given** the scan is running
**When** a file is found
**Then** it appears in results immediately, not only after the scan reaches 100%

**Given** the device is unmounted before reading begins
**When** the scan starts
**Then** no other process can read/write it concurrently (single-session-per-device lock)

### Story 1.5: Pause, Resume, and Cancel a Scan

As a user,
I want to pause a long scan and resume it later, or cancel it outright,
So that I'm not stuck waiting if I need to do something else.

**Acceptance Criteria:**

**Given** an active scan
**When** I tap Pause
**Then** the scan suspends in place (not cancelled) and resumes from the same point when I tap Resume

**Given** an active scan
**When** I tap Cancel
**Then** it terminates and the results found so far remain visible

**Given** the app is relaunched after being closed mid-scan
**When** I return to the scan
**Then** it can resume from the last checkpointed byte offset rather than restarting from zero

### Story 1.6: Recover Deleted Files via Intact Metadata

As a user,
I want the app to find files I deleted from a FAT32/exFAT drive using whatever the filesystem still remembers about them,
So that I get my original filenames and folder structure back.

**Acceptance Criteria:**

**Given** a FAT32/exFAT device with deleted-but-not-overwritten files
**When** the scan completes
**Then** those files appear in results with their original filename, path, and timestamp intact

**Given** a file recovered this way
**When** I view its recovery-confidence indicator
**Then** it shows High

### Story 1.7: Browse Results by File Type

As a user,
I want recovered files grouped by type (Pictures, Videos, Audio, Documents, Archives, Other),
So that I can quickly find what I'm looking for among potentially thousands of results.

**Acceptance Criteria:**

**Given** a completed scan with mixed file types
**When** I view results
**Then** each category shows its own file count and aggregate size

**Given** a file of an unrecognized type
**When** I view results
**Then** it appears under Other, not omitted

### Story 1.8: See and Trust the Recovery-Confidence Indicator

As a user,
I want each file to show how confident the app is that it recovered correctly,
So that I don't waste effort on files that might be corrupted or assume something is safe when it isn't.

**Acceptance Criteria:**

**Given** a file recovered via intact metadata (Story 1.6)
**When** I view it
**Then** its confidence indicator shows High

**Given** the confidence scoring function
**When** evaluated against a hypothetical carved-with-no-metadata result
**Then** it never labels such a file High — the floor is enforced now, even though carving itself ships in Epic 3

### Story 1.9: Preview a File Before Recovering It

As a user,
I want to preview a recoverable file before deciding to recover it,
So that I can confirm it's actually what I'm looking for.

**Acceptance Criteria:**

**Given** a file with a supported preview format (e.g. an image)
**When** I select it
**Then** a preview renders without first requiring recovery

**Given** a file with no supported preview format
**When** I select it
**Then** I see an explicit "no preview available" state, not a blank or broken view

### Story 1.10: Recover Selected Files to a Safe Destination

As a user,
I want to select one, several, or all recoverable files and copy them somewhere safe,
So that I actually get my files back.

**Acceptance Criteria:**

**Given** I've selected a subset of files
**When** I choose a destination and recover
**Then** only the selected files are copied, byte-identical to the source read

**Given** I attempt to set the destination to the same volume as the source
**When** I confirm
**Then** the app blocks it with an explicit warning rather than proceeding

**Given** a recovery completes (with or without individual file failures)
**When** I view the summary
**Then** it shows the actual count/size written (not the pre-recovery selection count) and offers a direct "show in Finder" action at the destination

### Story 1.11: Verify the App's Privacy Guarantees Yourself

As a privacy-conscious user,
I want to see, in-app, exactly what Salvage reads and writes, and independently confirm it makes no network calls during a scan,
So that I can trust it with sensitive data without taking anyone's word for it.

**Acceptance Criteria:**

**Given** I open the app for the first time
**When** I look for it
**Then** an in-app, plain-language explanation of what the app reads/writes and when is reachable from the main UI, not only a README

**Given** a scan and recovery session is running
**When** I monitor network activity with a tool like Little Snitch
**Then** zero outbound connections occur

**Given** the app has no scan in progress
**When** I check for updates
**Then** the only network call anywhere in the app is this explicit, user-initiated action — never automatic, never on launch

## Epic 2: Recover from Mac-Native Drives, Including Encrypted Ones

A user can scan and recover from APFS- or HFS+-formatted drives — internal (non-boot) and external — including FileVault-encrypted volumes, with the same confidence-indicator and recovery flow Epic 1 established. This is where the project's single biggest engineering risk lives: an original, MIT-licensed, from-scratch APFS parser (AD-2, flagged `[ASSUMPTION]`).

### Story 2.1: APFS Parsing Strategy Spike

As a maintainer,
I want to validate the from-scratch APFS parsing approach against a real, unencrypted test volume before committing further engineering,
So that AD-2's assumption is confirmed or revised early, when the cost of changing course is lowest.

**Acceptance Criteria:**

**Given** a real, unencrypted APFS test volume with known deleted files
**When** the spike's parser reads its catalog/journal structures using only Apple's public 2018 APFS Reference plus independent testing (no GPL/LGPL code)
**Then** it correctly enumerates at least the basic file/catalog records for that volume

**Given** the spike's results
**When** complete
**Then** a go/no-go decision on the from-scratch approach is documented, with `ARCHITECTURE-SPINE.md`'s AD-2 updated from `[ASSUMPTION]` to either `[ADOPTED]` or revised

**Given** the spike reveals the approach is infeasible in reasonable time
**When** documented
**Then** the fallback options (shelling out to a GPL tool with a FUSE dependency, accepting LGPL linking risk, etc.) are re-evaluated explicitly rather than silently persisted with

### Story 2.2: Scan and Recover Deleted Files from an APFS Drive

As a user,
I want to scan an APFS-formatted drive (internal non-boot, or external) and recover deleted files using the same results browser and recovery flow I already know from Epic 1,
So that my Mac-native drives are covered too.

**Acceptance Criteria:**

**Given** an unencrypted APFS device with deleted-but-not-overwritten files
**When** I scan it
**Then** those files appear in results with original filename, path, and timestamp

**Given** an APFS device
**When** selected
**Then** it appears in the same unified device list as FAT32/exFAT/HFS+ devices

**Given** a scan against an unsupported or corrupted APFS structure the parser can't interpret
**When** encountered
**Then** the app reports it as such rather than silently producing wrong results

### Story 2.3: Scan and Recover Deleted Files from an HFS+ Drive

As a user,
I want the same recovery experience for older HFS+-formatted drives,
So that older Mac drives and backups are covered too.

**Acceptance Criteria:**

**Given** an HFS+ device with deleted-but-not-overwritten files
**When** I scan it
**Then** those files appear in results with original filename, path, and timestamp

**Given** an HFS+ device
**When** selected
**Then** it's scanned through the same unified flow as other filesystems

### Story 2.4: Unlock and Recover from a FileVault-Encrypted Volume

As a user,
I want to unlock a FileVault-protected drive with my password or recovery key and then recover from it,
So that encryption doesn't leave me stuck when I need my files back.

**Acceptance Criteria:**

**Given** a FileVault-encrypted APFS volume
**When** I select it to scan
**Then** I'm clearly told it's encrypted and prompted for a password or recovery key before anything else happens

**Given** I enter the correct password
**When** unlock completes
**Then** scanning proceeds via `diskutil apfs unlockVolume -nomount` (no mount occurs) and my credential is never persisted

**Given** I enter an incorrect password
**When** unlock fails
**Then** I'm told specifically that the password was wrong, distinct from a tool/version-related failure

**Given** the volume is unlocked
**When** the scan reads it
**Then** it goes through the same read-only raw-read path as any other device — no exception to the read-only guarantee

## Epic 3: Recover from Severely Damaged or Unmountable Media

A user whose drive won't mount at all, or is too corrupted for normal undelete, can still get files back: signature-based carving reconstructs files from raw bytes when filesystem metadata is gone, and lost-partition detection finds and recovers from a filesystem signature hiding in unallocated space. This epic reuses Epic 1's results browser, confidence indicator, and recovery flow almost entirely; the work here is concentrated in `SalvageCore`, not new UI surfaces.

### Story 3.1: Carve Files from Raw Bytes When Metadata Is Gone

As a user,
I want the app to reconstruct files directly from raw disk bytes when the filesystem no longer remembers them,
So that a reformatted or badly corrupted drive still gives me something back.

**Acceptance Criteria:**

**Given** a region of the scanned disk with no intact filesystem metadata
**When** the scan reaches it
**Then** the carving engine automatically scans for known file-format signatures without needing a separate manual mode

**Given** a carved file
**When** I view its recovery-confidence indicator
**Then** it's Medium or Low, never High

**Given** the carving signature library
**When** loading
**Then** it reads declarative JSON definitions with a `schemaVersion` field and ignores unrecognized fields rather than rejecting the file

### Story 3.2: Organize Reconstructed Files Sensibly

As a user,
I want reconstructed files (with no original name) to be named and organized predictably,
So that I can tell them apart and find things by type even without original filenames.

**Acceptance Criteria:**

**Given** two reconstructed files of the same type in one scan session
**When** named
**Then** they never collide on the same generated filename

**Given** a reconstructed file
**When** placed
**Then** it lands under a `Reconstructed/<type>/` folder grouped by detected file type

**Given** a fragmented file that can't be fully reconstructed
**When** shown
**Then** it's either recovered partially with a clear "partial/corrupted" indicator, or excluded — never presented as a complete file when it isn't

### Story 3.3: Discover a Lost Partition

As a user,
I want the app to find a filesystem hiding in my disk's unallocated space even when nothing is mounted,
So that a drive that "shows nothing" isn't actually empty.

**Acceptance Criteria:**

**Given** a disk with no current mounted volume but a recognizable filesystem signature in unallocated space
**When** scanned
**Then** that signature surfaces as a distinct "Lost Partition" result

**Given** a lost partition result
**When** shown
**Then** it never merges with or appears inside the normal mounted-volume results list — it's its own category

### Story 3.4: Recover Files from a Lost Partition

As a user,
I want to select a detected lost partition and recover files from it just like a normal scan,
So that my files come back even though the partition itself was gone.

**Acceptance Criteria:**

**Given** a detected lost partition
**When** I select it and run recovery
**Then** metadata-based undelete and/or carving run against its reconstructed structure using the same browsing/preview/recovery flow as Epic 1

**Given** a lost-partition recovery
**When** it completes
**Then** the source disk's actual on-disk partition table is never modified — recovery is always file-copy-out, never partition-table repair-in-place

**Given** the app's available actions
**When** reviewed
**Then** there is no action anywhere that writes a reconstructed partition table back to the source disk
