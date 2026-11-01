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
