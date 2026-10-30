---
title: "Addendum: Open-Source macOS Data Recovery Tool"
created: 2026-10-30
updated: 2026-10-30
---

# Addendum

Supporting depth from the brief conversation and research that belongs to downstream documents (PRD, architecture) rather than the brief itself.

## Competitive Landscape (detail)

| Tool | Model | Filesystems | Distinctive UX / notes |
|---|---|---|---|
| **Disk Drill** (CleverFiles) | One-time purchase; free tier recovers up to 500MB | APFS, HFS+, FAT32, exFAT, NTFS | File-type-bucketed scan dashboard, per-file "Recovery chances" indicator, lost-partition detection as a distinct result category. Mac App Store edition is DMG-only / crippled; full raw-disk recovery is direct-download ("Basic Edition") only. This is the primary UX reference for this project. |
| **EaseUS Data Recovery Wizard for Mac** | Subscription or lifetime license; free tier ~2GB (500MB base + bonus via social share) | APFS, HFS+, FAT32, exFAT | Mac App Store version reportedly can only recover from DMG files; raw disk recovery is direct-download only. |
| **Stellar Data Recovery** | Free tier capped at 1GB | NTFS, exFAT, FAT, HFS+, APFS | One hands-on review found it (and EaseUS) failed to see a lost volume that R-Studio could reconstruct — anecdotal, not verified first-hand. |
| **R-Studio** | Free version capped at 256KB/file | NTFS, FAT, exFAT, HFS+, APFS, EXT2/3/4, ReFS, UFS | Widest filesystem support of the group; positioned for power users/professionals. UI reviewed as outdated/complex. Strongest reported partition-reconstruction result in one anecdotal comparison — the bar to eventually match on raw capability. |
| **iBoysoft** | Free tier 1GB; pricing muddled across sources (~$89.95/mo–$169.99 lifetime depending on source) | APFS-focused | One review notes it struggled on a heavily fragmented test drive. |
| **TestDisk / PhotoRec** | Free, open source, CLI | Filesystem-agnostic (PhotoRec); TestDisk rebuilds MBR/GPT partition tables | PhotoRec is pure signature-based carving. TestDisk is the reference implementation for lost-partition reconstruction. Sets the "free floor" this project competes against on UX, not raw capability — this project should explicitly credit these techniques, not claim to have invented them. |
| **DMDE** | Free-tier-commercial, cross-platform | Sector-level, with a disk/MBR/GPT editor | Mentioned for completeness; not a close UX comparable. |

Sources (not independently re-verified beyond the research pass):
- [Disk Drill vs EaseUS](https://thesweetbits.com/disk-drill-vs-easeus-data-recovery/)
- [Disk Drill vs EaseUS, 2026 comparison](https://www.cbackup.com/best/dd-vs-eu-2578.html)
- [EaseUS's own Mac review](https://www.easeus.com/data-recovery-review/easeus-data-recovery-mac-review.html)
- [MiniTool Mac data recovery comparison](https://www.minitool.com/data-recovery-software/mac-data-recovery-comparison.html)
- [Macworld iBoysoft review](https://www.macworld.com/article/2923312/iboysoft-data-recovery-for-mac-review.html)
- [Wikipedia: TestDisk](https://en.wikipedia.org/wiki/TestDisk)
- [TestDisk presentation, cgsecurity.org](https://www.cgsecurity.org/testdisk_doc/presentation.html)
- [Apple Developer docs: App Sandbox](https://developer.apple.com/documentation/security/app-sandbox.md)
- [Apple Developer Forums: Full Disk Access entitlement thread](https://developer.apple.com/forums/thread/739482)
- [NordVPN glossary: file carving](https://nordvpn.com/cybersecurity/glossary/file-carving/)

## Platform Constraint Detail (for Architecture)

- Raw block-device recovery **cannot ship through the Mac App Store** — App Sandbox is mandatory for Store apps, there is no entitlement for Full Disk Access, and block-level I/O needs privileges sandboxed apps don't get. Every competitor above ships the same way (see table). Treat this as settled, standard practice for the category — do not revisit sandboxing as an option during architecture.
- Notarization + Developer ID signing is required regardless of price, to clear Gatekeeper on a direct-download build. This is the source of the funding tension noted in the brief's Risks section.
- **Not confirmed, needs a spike**: exact SIP interaction and entitlement requirements for reading `/dev/diskN` directly, and whether anything has changed in recent macOS versions (2025–2026) that affects this. Working assumption carried into Architecture: Full Disk Access (user-granted via System Settings → Privacy & Security) plus Developer ID signing is sufficient, matching how Disk Drill/EaseUS ship — but Architecture should verify this hands-on before committing to it structurally.

## Core Recovery Techniques (detail)

- **Metadata-based undelete**: parses live-but-marked-deleted filesystem records (APFS catalog/journal, HFS+ catalog, FAT directory entries) to recover the real filename, path, and timestamps. Only works while metadata survives — this is the "high recovery chances" case in the UI.
- **Signature-based carving**: ignores the filesystem entirely, scans raw bytes for known file-format headers/footers (JPEG, PDF, etc.) to reconstruct files with no surviving metadata. This is the generic `file_3375x6000_000028.jpg`-style unnamed-output case seen in the reference screenshots' "Reconstructed" folder. Cannot recover original filename/timestamp, and formats without a reliable signature (e.g. plain text) are effectively unrecoverable this way. Struggles with fragmented files.
- **Lost-partition/volume reconstruction**: distinct from file recovery — scans unallocated space for a recognizable filesystem signature and rebuilds the partition table (MBR/GPT) entry. Once rebuilt, normal metadata-based recovery can run against the restored volume. TestDisk is the reference implementation for this step.

## Options Considered

- **Cross-platform shell (Electron/Tauri + Rust/C++ core) vs. native Swift/SwiftUI**: native Swift/SwiftUI was chosen earlier in this project's setup (before this brief conversation), prioritizing deep macOS integration (Full Disk Access flow, native file previews via QuickLook, the notarization process) over early cross-platform reach. The Vision section's longer-term cross-platform idea would mean a second native implementation or a shared recovery-engine library, not a framework swap — worth flagging for Architecture rather than silently assuming.
- **License: MIT vs. GPL-family (GPLv3/AGPL)** — **RESOLVED: MIT confirmed.** Chosen to maximize adoption and allow unrestricted reuse/forking, consistent with "community-extensible" positioning. (The copyleft alternative, which would have more strongly guaranteed derivative/commercial forks stay open, was considered and not chosen.)

## Process Notes

Discovery was run as a batched "fast path": stakes, differentiation angle, business model, and v1 scope were collected via one consolidated set of questions rather than a long back-and-forth, per the user's apparent preference for moving quickly. The working title "OpenRecover" was a placeholder invented for this brief, not a user-provided name — flagged as an assumption in the brief body. During the PRD pass, the user confirmed the name as **Salvage** (wanted something distinctive, not evocative of competitor naming), confirmed the MIT license, and confirmed Developer ID signing/notarization is already available under HSmithDev LLC — resolving all three items this brief had flagged as open.
