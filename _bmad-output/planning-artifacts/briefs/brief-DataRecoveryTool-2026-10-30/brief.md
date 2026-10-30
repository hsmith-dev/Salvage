---
title: "Product Brief: Salvage"
status: final
created: 2026-10-30
updated: 2026-10-30
---

# Product Brief: Salvage

## Executive Summary

Losing files — a formatted SD card, a dropped USB drive, an accidentally emptied Trash, a corrupted external HDD — is a common, stressful moment that currently pushes Mac users toward one of a handful of closed-source commercial tools (Disk Drill, EaseUS Data Recovery Wizard, Stellar, R-Studio). Every one of these asks a user to hand raw, unfiltered access to their most sensitive personal data — photos, documents, financial records — to a proprietary binary they cannot inspect, in exchange for a license fee or subscription.

This project is a **native macOS data recovery app that is free, fully open source, and fully offline** — no telemetry, no cloud upload, no account, no paywall between "see what's recoverable" and "actually recover it." It targets the same core use cases the commercial incumbents own today — deleted-file undelete, lost-partition detection and reconstruction, and signature-based file carving across common filesystems — with the same approachable, scan-and-browse experience (file-type categorization, per-file recovery-confidence indicators, live previews before committing to a recovery) but built in the open, auditable by anyone, and trustworthy by construction rather than by brand reputation.

Product name (confirmed): **Salvage**.

## The Problem

People lose access to files on macOS in a handful of recurring ways: a drive is reformatted or corrupted and a partition "disappears," files are deleted (by mistake, by a misbehaving app, or during a format) and the Trash doesn't have them, or a drive develops filesystem corruption and simply stops mounting cleanly. In the moment, the user is anxious and in a hurry — and the tools available to them require trusting a closed-source application with direct, low-level read access to the entire disk, often before they even know if the tool can help (most ask for payment or an account before letting the user confirm a successful scan).

There is no actively-maintained, trustworthy, zero-cost option for Mac users today that matches the UX quality of the commercial tools. The free/open alternatives that exist (TestDisk, PhotoRec, DMDE) are real and respected among technical users, but are command-line or dated-UI tools that assume filesystem and partitioning literacy most Mac users don't have — they solve the technical problem but not the trust-and-approachability problem together.

## The Solution

A native SwiftUI macOS application that scans a selected disk, volume, or lost partition and presents recoverable content the way Disk Drill does today: results bucketed by file type (Pictures, Videos, Audio, Documents, Archives, Other), a dedicated "lost partitions" view when the scanner finds a filesystem signature outside the current partition table, a file browser with thumbnail/preview support and a per-file recovery-confidence indicator, and a one-click recovery flow that copies selected files out to a destination the user chooses — never writing to the source disk.

Under the hood it combines the three standard recovery techniques the whole category relies on: metadata-based undelete (reading still-intact filesystem catalog/journal records for APFS, HFS+, FAT32, exFAT), signature-based file carving (reconstructing files from raw unallocated bytes when metadata is gone, the same technique PhotoRec uses), and lost-partition reconstruction (scanning unallocated space for a recognizable filesystem signature and rebuilding the partition table entry, the way TestDisk does). None of that is novel — the openness, the trust model, and the UX are the point.

## What Makes This Different

Being honest about the moat: this is **not** a claim of superior recovery technology on day one. Mature closed-source competitors (R-Studio in particular) have years of engineering behind their carving and reconstruction engines, and matching their raw recovery rate will take real time. The actual differentiation is:

- **Fully offline, zero telemetry, by design and verifiable.** Nothing about a scan, a found file, or a recovery ever leaves the machine. Because the source is open, this is a checkable claim, not a privacy-policy promise.
- **Free with no artificial gate.** No scan/recover split, no license key, no subscription — the thing that works in a demo is the thing that works for real.
- **Auditable recovery logic.** For a category of software whose entire job is reading a user's most sensitive data at the lowest level, "trust us" is a weak proposition. Open source lets technically-minded users (and eventually security researchers) verify the app does only what it claims.
- **Community-extensible.** New file-signature definitions, filesystem support, and bug fixes can come from contributors, not just a single vendor's roadmap.

License (confirmed): MIT, chosen to maximize adoption and allow commercial/derivative use.

## Who This Serves

**Primary**: Mac users who have lost data and are specifically wary of handing unrestricted disk access to a closed-source tool — privacy-conscious professionals, security-aware technical users, and anyone who has reason not to trust an unaudited binary with sensitive content (legal, medical, financial, journalistic work). Success for them is this: run the scan, confirm (for themselves, not on faith) that nothing left the machine, recover what's recoverable. Done.

**Secondary**: The broader open-source/macOS developer community — potential contributors who extend filesystem or carving support, and technically curious users who'd otherwise reach for TestDisk/PhotoRec but want a native Mac experience around the same underlying techniques.

## Success Criteria

Because this is a community project with no revenue goal, success is adoption and trust, not monetization:

- Real recovery outcomes: users successfully get back files they'd otherwise have paid to recover, or lost entirely — tracked informally via GitHub issues/discussions and community reports, not telemetry.
- Adoption signals: GitHub stars/forks, download counts on releases, inbound contributions (issues, PRs, new filesystem/signature support).
- Trust signals specific to this product's premise: reproducible builds, a documented "what this app reads/writes and when" explanation, no flagged privacy concerns from the security community.
- Coverage parity milestones: successful recovery across APFS, HFS+, FAT32, and exFAT, and at least one validated lost-partition-reconstruction scenario per filesystem — these are the concrete technical bars that justify the "broad scope" claim below.

## Scope

**In for v1** (deliberately ambitious — matches the full scope shown in the Disk Drill/EaseUS reference screenshots, not a cut-down MVP):

- Any storage device macOS can mount as a block device — internal drives, external HDD/SSD, USB flash drives, SD/memory cards — not a fixed device list.
- Filesystem support: APFS, HFS+, FAT32, exFAT.
- Metadata-based undelete where filesystem metadata survives.
- Signature-based file carving for common formats (images, video, audio, documents, archives) when metadata is gone.
- Lost-partition detection and reconstruction (recognizing a filesystem signature in unallocated space, rebuilding the partition entry, then recovering from it).
- Scan-results UI: file-type-bucketed dashboard, lost-partitions panel, file browser with thumbnails/previews and a per-file recovery-confidence indicator, recover-to-chosen-destination flow.
- Fully offline operation; read-only against the source disk (the app never writes to the disk being scanned).

**Explicitly out for v1**:

- Windows/Linux builds (native macOS only — see Vision for longer-term cross-platform ambition).
- RAID reconstruction and NAS/network-volume recovery.
- Adjacent utilities competitors bundle in (video repair, byte-to-byte disk imaging/backup, duplicate finder, secure data shredding, S.M.A.R.T. monitoring) — these are plausible future additions, not v1.
- iOS/mobile device recovery (Disk Drill supports iPhone backups; out of scope here).
- Mac App Store distribution — not feasible for this category (see Addendum: App Sandbox forbids the raw block-device access this app needs). It ships as a notarized, Developer-ID-signed direct download instead.

This scope is ambitious for a first release; the Architecture and Epics/Stories phases that follow this brief should expect to sequence it (e.g., which filesystem ships first) rather than build all of it simultaneously.

## Risks & Open Questions

- ~~Notarization requires a paid Apple Developer ID ($99/yr), in tension with "free and open source."~~ **RESOLVED** — Developer ID signing/notarization is already available under HSmithDev LLC's existing membership, so this is covered. Mac App Store distribution still isn't an option for this category (raw disk access needs more than the sandbox allows — see Scope), so notarized direct download remains the distribution path.
- **Recovery-confidence accuracy.** A "recovery chances" indicator is only trustworthy if it's honest; overpromising on carved files with no metadata (the hardest case) would undercut the whole trust-based pitch. Needs a deliberately conservative scoring approach.
- **Full Disk Access / `/dev/diskN` entitlement mechanics weren't fully confirmed in research.** Working assumption: Full Disk Access + Developer ID signing suffices (matches competitors) — verify with a hands-on spike before Architecture commits to it.
- **Legal/liability framing.** Standard open-source "as-is, no warranty" disclaimers apply, but a tool that reads raw user disks should say plainly, in-product, what it does and doesn't do (read-only, no network access) — this is as much a trust feature as a legal one.

## Vision

If this works, it becomes the thing TestDisk/PhotoRec are for technical users but for everyone on macOS — the default answer to "I lost my files" that doesn't require either paying a license fee or trusting a closed binary with your data. macOS is the deliberate starting point, not the ceiling: Linux and Windows support is an explicit intended direction once the Mac app and its recovery engine are solid, not a hypothetical. The recovery engine itself (filesystem parsers, carving signatures, partition reconstruction) should be architected so it can become a reusable core that a future Linux/Windows front end builds on, the way libraries like `libewf` or `sleuthkit` serve the forensics community today — this is a real constraint on Architecture's separation-of-concerns decisions, not just a mission statement.
