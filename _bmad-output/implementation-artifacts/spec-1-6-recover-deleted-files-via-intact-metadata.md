---
title: 'Recover Deleted Files via Intact Metadata'
type: 'feature'
created: '2026-10-31'
status: 'ready-for-dev'
baseline_commit: 'c1b21a3'
route: 'dispatch'
review_loop_iteration: 0
context:
  - '{project-root}/_bmad-output/implementation-artifacts/epic-1-context.md'
  - '{project-root}/_bmad-output/planning-artifacts/architecture/architecture-DataRecoveryTool-2026-10-30/ARCHITECTURE-SPINE.md'
  - '{project-root}/_bmad-output/implementation-artifacts/spec-1-4-scan-a-fat32-exfat-device-with-live-progress.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** The Story 1.4 scanner indexes only live files. FR-4 requires finding deleted-but-not-overwritten FAT32/exFAT files with their original name, path and timestamp.

**Approach:** Extend `FATVolume` to report deleted directory entries as `RecoveredFile` values with `isDeleted: true`, and to decode `modified` timestamps for every file, live and deleted. Live-metadata handling stays fail-closed as Story 1.4 built it. Deleted entries are expected to be partly stale, so they are validated individually and skipped when implausible; they never abort the scan.

## Boundaries & Constraints

**Always:**
- **FAT32 deleted entry** (first byte 0xE5):
  - Rebuild the full name from the preceding deleted LFN slots when their checksum matches the short entry. The LFN ordinal byte is also overwritten with 0xE5, so rely on position and checksum, not the ordinal.
  - Otherwise use the short name with its first character replaced by `_`.
  - Deletion zeroes the FAT chain, so assume the file is contiguous from its first cluster for `ceil(size/clusterBytes)` clusters.
  - Emit it only if every one of those clusters is free in the active FAT and within the volume. Otherwise skip it, because it has probably been overwritten.
- **exFAT deleted entry set** (in-use bit clear: 0x05 / 0x40 / 0x41):
  - The set checksum must validate. It covers the in-use bit, so recompute it with the bits restored.
  - Use the stream extension's NoFatChain flag. A contiguous run must be fully free in the allocation bitmap, or the file is skipped.
  - A fragmented deleted exFAT file (with a FAT chain) is skipped. Log this in the spec's Implementation Notes.
- Deleted entries never `claim()` clusters. They mustn't raise cross-link errors against live files, and live files mustn't be rejected because of them.
- `modified` comes from the FAT32 write date/time (local time, 2-second resolution) and from exFAT's last-modified field with its 10 ms increment and UTC offset when that offset is valid. An out-of-range date gives `nil`, never a fabricated date.
- Paths: a deleted file's path is its parent directory's path. Deleted directories are not descended into in this story.
- Original entry bytes go into `rawRecord`, exactly as for live files.

**Never:**
- No edits outside `SalvageCore/Sources/SalvageCore/Parsers/FATVolume.swift` and new test files. `ScanSession.swift`, `ScanEvent.swift`, `VolumeDiscovery.swift`, `VolumeScanners.swift`, the app, DiskIO and CI belong to other stories running in parallel.
- No confidence scoring (Story 1.8), no UI changes, no writing recovered files (Story 1.10).

## I/O & Edge-Case Matrix

| Scenario | Input | Expected | Error handling |
|---|---|---|---|
| FAT32 deleted file with LFN | 0xE5 short entry + deleted LFN, valid checksum, free clusters | Emitted with the full original name, the parent path, `isDeleted`, `modified` | — |
| FAT32 deleted 8.3 only | 0xE5 short entry, free clusters | Name `_ELLO.TXT`-style | — |
| Overwritten deleted file | A cluster is now allocated in the FAT | Not emitted | Skip, no error |
| Implausible deleted entry | Cluster out of range, or size exceeds the volume | Not emitted | Skip, no error |
| exFAT deleted contiguous | In-use bits clear, NoFatChain, bitmap free | Emitted | — |
| exFAT deleted with a bad checksum | — | Not emitted | Skip |
| Deleted data shares clusters with a live file | — | Live file still emitted, no cross-link error | — |
| Live file timestamps | Any live entry | `modified` populated | `nil` if the date is invalid |

</frozen-after-approval>

## Code Map

- `SalvageCore/Sources/SalvageCore/Parsers/FATVolume.swift`: `directory()` currently treats 0xE5 as a reset of the LFN run. Build deleted-entry handling there, and decode timestamps where `RecoveredFile` is constructed (both FAT32 and exFAT paths).
- Tests: a new file `SalvageCore/Tests/SalvageCoreTests/DeletedFileTests.swift`. Reuse the `fatImage`/`exfatImage` builders, `put` and `scan` from `ScanSessionTests.swift`; add helper builders in the new file rather than editing the shared ones.

## Tasks & Acceptance

- [x] Timestamp decoding for live FAT32 and exFAT files, plus tests.
- [x] FAT32 deleted entries (LFN reconstruction, short-name fallback, free-cluster check), plus tests.
- [x] exFAT deleted entry sets (checksum with restored in-use bits, bitmap-free check, fragmented → skip), plus tests.
- [x] Tests showing deleted entries never abort a scan or cross-link live files.

**Acceptance criteria:**
- Given a FAT32/exFAT device with deleted-but-not-overwritten files, when the scan completes, those files appear with their original filename, path and timestamp, and `isDeleted == true`.
- The High-confidence indicator is delivered by Story 1.8, which reads `isDeleted` and the metadata recovery method.

## Verification

- `swift test --package-path SalvageCore`
- `./scripts/check-core-boundary.sh`
- `xcodebuild -project Salvage.xcodeproj -scheme Salvage -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:SalvageTests test`

## Implementation Notes

Only `FATVolume.swift` and the new `DeletedFileTests.swift` were changed. Judgment calls:

- **The deleted LFN checksum can't be checked directly.** The checksum covers the short name's first byte, and deletion overwrites that byte with 0xE5. The checksum is also a bijection in that byte, so some first byte always matches any checksum, and "a matching byte exists" proves nothing. Instead, the lost byte is taken from the recovered long name the way short names are generated: its first character (after any leading `.` or space), uppercased, or `_` when that character isn't valid 8.3 ASCII. The LFN name is used only when the checksum matches one of those candidates. Otherwise the code falls back to the `_`-prefixed short name. A short name the user chose by hand that doesn't start with the long name's first letter therefore falls back to the short name. That is the safe direction.
- **Choosing the deleted LFN run.** Without ordinals, the code takes the trailing slots before the short entry that share its checksum. It then drops any older slots before the last slot holding a 0x0000 terminator, since a stale slot from an earlier deleted file can share the checksum. If a name is an exact multiple of 13 units (so it has no terminator) and a stale same-checksum slot comes before it, padding validation fails and the short-name fallback is used.
- **Single-cluster FAT-chained exFAT files are kept.** The spec skips fragmented deleted exFAT files that have a FAT chain. A deleted file whose stream lacks NoFatChain but fits in one cluster can't be fragmented, so it is emitted after the same bitmap-free check. Files with NoFatChain clear that span more than one cluster are skipped.
- **A partly overwritten exFAT set yields to live entries.** While a deleted set is being collected, any entry with its in-use bit set, or a new deleted primary (0x05), abandons the set. That entry is then processed normally. Live entries are never swallowed into a stale set.
- **Deleted entries are reported as `contiguous: true`.** FAT32 deletion zeroes the chain, so contiguity is assumed. For exFAT, NoFatChain is set or the file is a single cluster. Story 1.10 can read the run directly. `rawRecord` keeps the original on-disk bytes: the LFN slots actually used plus the short entry, or the exFAT set with its in-use bits still cleared.
- **What isn't reported.** Deleted directories and volume labels (FAT32 attribute 0x10/0x08, exFAT directory attribute) are not emitted or descended into. Zero-length deleted files are emitted without a cluster check, just as live ones are. Two deleted entries that point at the same free clusters are both emitted, because neither claims clusters.
- **Timestamp validation.** Each field is range-checked by hand: real days per month including leap years, hour ≤ 23, minute ≤ 59, 2-second count ≤ 29, exFAT 10 ms increment ≤ 199. Anything out of range gives `nil`, so Foundation never quietly normalizes a bad date. The exFAT UTC offset counts as valid only when bit 7 is set and the signed 7-bit quarter-hour value is within −12:00…+14:00. Otherwise, and for every FAT32 timestamp, the value is read as local time in `TimeZone.current`.
- **Known limitation (not handled):** some FAT32 drivers, notably Windows, clear the high 16 bits of the first cluster when deleting. Deleted files above cluster 65535 on those volumes then point at the wrong low cluster. They are only emitted if that wrong run happens to be free, and Story 1.8's confidence scoring should treat them as weaker.
