---
title: 'Carving: Exact Ends for MP3, OLE2 and gzip, and Bifragment JPEG Reassembly'
type: 'tech'
created: '2026-10-31'
status: 'ready-for-dev'
baseline_commit: 'd04d613'
route: 'dispatch'
context:
  - '{project-root}/_bmad-output/implementation-artifacts/spec-3-1-3-2-carve-and-organize-reconstructed-files.md'
  - '{project-root}/_bmad-output/planning-artifacts/architecture/architecture-DataRecoveryTool-2026-10-30/ARCHITECTURE-SPINE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** These formats are always carved partial/Low because the engine has no end rule for them (deferred from Stories 3.1/3.2). Fragmented files aren't reassembled at all.

**Approach (Carving only):**
1. **MP3:** walk MPEG frames to the end of the stream, using the frame-header parser that now exists for `validate: "mpegFrames"`. Accept an ID3v1 `TAG` trailer (128 bytes) and an APE tag. End as `.validated` once at least N consecutive frames were seen and the next bytes aren't a frame. Otherwise partial.
2. **OLE2 (doc/xls/ppt):** parse the header (sector shift, FAT sector count, DIFAT), read the FAT, and compute the file length from the highest sector referenced by any chain in the FAT and directory. Validate the FAT entries' ranges. This becomes a `structure: "ole2"` walker, bounded.
3. **gzip:** parse the header (FLG fields), then walk the DEFLATE stream to its final block to find the exact end, plus the 8-byte trailer. Use Apple's `Compression` framework only if it can report the consumed byte count reliably for raw DEFLATE. Otherwise implement a minimal DEFLATE block parser: decode Huffman tables only enough to skip symbols; no output buffering beyond the 32 KiB window. Validate the CRC32/ISIZE trailer when it was decoded; if not decoded, end as partial. Note `Compression` is a system framework; record it in AD-1 if used.
4. **Bifragment JPEG reassembly (bounded):** for a JPEG whose carve ends `.inconsistent` or `.nextHeader` inside entropy-coded data, try the classic bifragment gap search. Find a later sector-aligned region, within a bounded window (e.g. 16 MiB) and not claimed, where decoding the restart-marker/entropy stream continues validly to an `FFD9`. Emit the reassembled file as two `DataRun`s with `fragmentCount 2`, `overwriteConfidence 0.3`, and `isPartial: false` only if fully validated (so AD-7 gives Low). Cap the CPU spent per candidate. If this is infeasible to make reliable, ship 1–3 and document why 4 was skipped.

## Boundaries & Constraints

**Always:**
- Wrong contents are worse than missing.
- Every new walker is bounded and uses checked arithmetic.
- Tests: synthetic fixtures for each format, including truncated and corrupt variants that must stay partial; a fragmented JPEG test (if 4 is shipped) whose second fragment is placed after an unrelated file.
- Real-file fixtures may be generated at test time with system tools: `afconvert` for audio, `gzip`, `textutil` for doc.

**Never:** Edit only `SalvageCore/Sources/SalvageCore/Carving/**`, `CarvingTests.swift`, `SignatureLibraryTests.swift`, and this spec's Implementation Notes. No ScanSession, parser or app changes.

</frozen-after-approval>

## Verification

- `swift test --package-path SalvageCore`
- `./scripts/check-core-boundary.sh && ./scripts/check-no-network.sh`
- `xcodebuild -project Salvage.xcodeproj -scheme Salvage -configuration Debug -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build`

## Implementation Notes

**Shipped: 1–3. Skipped: 4 (bifragment JPEG reassembly).** Changes are limited to `SalvageCore/Sources/SalvageCore/Carving/**`, `CarvingTests.swift` and `SignatureLibraryTests.swift`.

### Engine
- New `structure` values `mp3`, `ole2`, `gzip` (beside `gif`). Each is a `CarveWalker` (`CarveWalker.swift`): a reference type held in a new `.walker` carve phase and confined to the `SignatureCarver` actor. The engine keeps the carry from the walker's `retainFrom`. The walker starts no step past the next unexamined header or the carve's claim/`maxBytes` bound, so the existing cut rules still apply. When a walker reports an end past a bound, the carve is cut at that bound as claimed or limit. The walker also decides which headers it absorbs: a header inside a size-declared tag counts as embedded, a header inside a walked frame or DEFLATE data is absorbed only if it's weak, and while the end is unknown only weak headers are absorbed.
- `Window` went from `private` to internal so the walkers can read it. It gained `matches([UInt8])` and `allZero`.
- Bounds: every offset addition in a walker is checked (`addingReportingOverflow`). On overflow the walk ends as inconsistent. The caps are: MP3 padding 64 KiB and APE tag 16 MiB; OLE2 FAT size derived from `maxBytes` (≤ 2 MiB of entries at 256 MiB); gzip FNAME/FCOMMENT 64 KiB and output 2 GiB per carve (past that the carve goes open-ended/partial, which caps CPU on deflate bombs). Release throughput is about 10 MB/s compressed (about 60 MB/s decoded) for one carve.

### MP3 (`mp3-id3.json`, `mp3-frame.json` → `structure: "mp3"`)
- First an optional ID3v2 tag: syncsafe size, the v2.4 footer, then up to 64 KiB of zero padding. Then frames of one version/layer/sample-rate (the existing `mpegFrame` parser). Then an optional APEv2 tag (header and footer both verified) and/or an ID3v1 `TAG`.
- The carve is `.validated` only when one of these holds: (a) a Xing/Info frame count is present and the walk matches it (the count, or the count + 1, because encoders differ on whether the Info frame counts itself); or (b) there's no such count and at least **N = 8** frames were walked. **And** the stream must close with an ID3v1/APE trailer, or the bytes from the last frame up to the next sector boundary must be zero. Non-zero non-frame bytes right after the last frame (how fragmentation or overwrite looks) make the carve end there as partial (0.6). An ID3 tag with no frames after it runs open-ended as before.
- `mp3-id3` now embeds `jpeg`/`png`, so cover art at a sector boundary inside the tag's declared size is not split off.
- Residual risk: a stream fragmented at a cluster boundary whose next cluster is zero-filled free space passes the zero-slack test, so it looks complete and is validated with its last frame's tail zeroed. The Xing count catches this when present. Without it, nothing local tells the two cases apart.
- No real-file MP3 fixture: `afconvert` on this macOS can decode MP3 but has no MP3 encoder (`ExtAudioFileSetProperty('cfmt') failed`). Fixtures are synthetic: MPEG-1 L3 128 kbps frames, ID3v1/APE/ID3v2/Xing variants.

### OLE2 (`ole.json` → `structure: "ole2"`, header reach 512)
- The walker parses the header: byte order, v3/512 or v4/4096 sectors, mini shift 6, cutoff 4096, FAT count bounded by `maxBytes`, DIFAT count consistent with the FAT count, unused DIFAT slots free, v3 directory count 0. It then reads each DIFAT sector, each FAT sector and the first directory sector **as the sweep reaches them** (they often sit at the end of the file). If a DIFAT sector names a FAT sector the sweep has already passed, the walker can't read it in one streaming pass, so the carve runs open-ended (partial) rather than guessing.
- Validation: every entry is free, end-of-chain, a marker, or `< FAT size`. Each sector has at most one predecessor. Pointers never reach free or marker sectors. Every chain is walked from its head, and an unvisited chain sector means a cycle. Marker counts match the DIFAT. The directory and mini-FAT chains start at heads with the lengths the header gives. Each FAT-stored stream in the first directory sector, and the root's mini stream, starts a chain exactly `ceil(size/sectorSize)` long. The end is `(highest allocated sector + 2) × sectorSize`. Any failure gives `.inconsistent` (partial, 1.0). The end is size-derived, so the 64 MiB `trustedMaxBytes` default still applies.
- Real-writer quirk found with `textutil -convert doc`: Cocoa's writer marks its FAT sector `ENDOFCHAIN`, not `FATSECT`. This is accepted only for a DIFAT-listed sector that nothing points to. A sector the DIFAT doesn't list may never carry a marker.
- Only the **first** directory sector's streams get chain-length checks. Later directory sectors are only known once the FAT is complete, and by then the sweep may have passed them. Trailing free sectors after the highest allocated one are not carved. Every referenced sector is kept, so all streams stay intact.
- A strong header inside the document before the FAT is read still cuts the carve (partial), as before. Absorbing it would hide a real file whenever the FAT turns out to be garbage.

### gzip (`gzip.json` → `structure: "gzip"`)
- **Apple `Compression` was not used.** AD-1 restricts SalvageCore to Foundation, and its streaming API doesn't report how many input bytes a raw DEFLATE stream consumed. So AD-1 needed no change. A minimal resumable inflater is built in instead (`GzipWalker.swift`). It handles the header (reserved FLG bits rejected; FEXTRA/FNAME/FCOMMENT; FHCRC verified), stored, fixed and dynamic blocks (puff/zlib rules: over-subscribed codes rejected, incomplete codes only as a single one-bit code, distance ≤ bytes produced), and a 9-bit fast lookup table. It keeps only the 32 KiB window, the CRC-32 and the length. Each step (block header, one symbol, part of a stored block) either commits or is retried when more bytes arrive.
- The end is `.validated` only when both the trailer's CRC-32 and ISIZE match. On a mismatch the carve ends after the trailer as inconsistent. On invalid DEFLATE data it ends at the bad byte as inconsistent. If the extent ends mid-stream it is partial (0.6). An invalid header emits nothing: three bytes plus bad flags is not a gzip file.
- Multi-member files are walked as one file. The exception is a member that ends exactly on a sector boundary: there, the next `1F8B08` is treated as a separate file, because adjacent `.gz` files on disk look the same.
- Real-file fixtures come from `/usr/bin/gzip` at test time: dynamic, fixed, incompressible/stored, and `-N` with FNAME. Synthetic fixtures cover stored blocks, an empty member, all header flags, multi-member files, and corrupt CRC/ISIZE/data/LEN/flags plus truncation.

### Why 4 (bifragment JPEG) was skipped
The spec allows shipping 1–3 if 4 can't be made reliable, and it couldn't be made reliable here:
- **Validation strength.** The only thing that makes a gap candidate safe is decoding the baseline Huffman entropy stream with the DHT/SOF tables and checking the MCU count against the frame dimensions (plus RST order). Checking the marker syntax alone (`FF00`/`RSTn`/`FFD9`) passes for nearly any FF-free data, so it would stitch foreign bytes into "validated" pictures, which breaks "wrong contents are worse than missing". A full baseline entropy decoder (progressive and arithmetic-coded JPEGs excluded) is a project of its own.
- **Break point.** A streaming carve is cut at the *next header* or a claimed run. The real fragment boundary can be any earlier cluster boundary, and decode errors trail it by an unknown distance. So the search is two-dimensional (break × resume), not one.
- **Engine model.** The sweep never buffers file bodies. Testing every sector-aligned resume point in a 16 MiB window means running a cloned decoder state per candidate as the bytes stream by (up to 32 768 live candidates per JPEG), and claim/overlap bookkeeping would have to reach across later carves.
Each of these can be solved, but not to the "never wrong" bar in this batch without a real entropy decoder and a corpus of fragmented images to tune against. The carve still reports these JPEGs as partial/Low, exactly as before. `SignatureCarver` still says "every carved file is one contiguous run". This should be tracked as deferred work.

### Test changes
- `nextHeaderEndsAnOpenEndedCarve` now uses RAR5 (gzip is no longer open-ended). `gzipBytes` builds a real stored-block gzip. `carvedFilesNeverScoreHigh` expects 10 files, because the `1F8B08`+filler blob has reserved FLG bits and is no longer carved. `mp3FrameSyncNeedsTwoConsecutiveValidFrames` expects the 10-frame stream to be exact and validated. `SignatureLibraryTests` was updated for `hasKnownEnd` (now only `rar5` has no end) and the new `structure` error text.
- New suite "Carving exact ends: MP3, OLE2, gzip" (12 tests).
