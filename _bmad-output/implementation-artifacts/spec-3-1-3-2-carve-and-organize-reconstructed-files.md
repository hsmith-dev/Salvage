---
title: 'Carve Files from Raw Bytes and Organize Reconstructed Files (Stories 3.1 + 3.2)'
type: 'feature'
created: '2026-10-31'
status: 'done'
baseline_commit: '4d050bd'
route: 'dispatch'
context:
  - '{project-root}/_bmad-output/planning-artifacts/architecture/architecture-DataRecoveryTool-2026-10-30/ARCHITECTURE-SPINE.md'
  - '{project-root}/_bmad-output/planning-artifacts/ux-designs/ux-DataRecoveryTool-2026-10-31/EXPERIENCE.md'
  - '{project-root}/_bmad-output/planning-artifacts/ux-designs/ux-DataRecoveryTool-2026-10-31/mockups/file-browser.html'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** FR-7/FR-8: when metadata is gone, reconstruct files from raw bytes by signature, automatically during the normal scan, with Medium/Low confidence only (AD-7) and declarative JSON signatures (AD-6). FR-8 / Story 3.2: reconstructed files get collision-free generated names under `Reconstructed/<type>/`, and partial carves are marked, never shown as complete.

**Approach:** `ScanSession` already streams every swept chunk through `SignatureCarver` (a stub). Implement it:
- **Signatures:** JSON files in `SalvageCore/Sources/SalvageCore/Carving/Signatures/*.json` (SwiftPM resources), each with required `schemaVersion` (1), `id`, `extension`, `category` hint, `header` (hex, with optional `headerOffset`), optional `footer` (hex), optional `maxBytes`, optional `sizeField` (offset/width/endian/adjust for length-prefixed formats). **Unknown fields are ignored, never rejected.** A file with the wrong `schemaVersion` is skipped with a logged reason. Ship an initial set: JPEG, PNG, GIF, HEIC/ISO-BMFF (ftyp), MP4/MOV (ftyp via size field), MP3 (ID3/frame sync), WAV/RIFF, PDF, ZIP (incl. docx/xlsx/pptx), GZIP, 7z, RAR, SQLite, plus generic Office97 (OLE).
- **Engine:** a streaming matcher over chunks (handle matches spanning chunk boundaries with a carry-over window of max header length), sector-aligned header search (configurable, default 512), bounded open-carve count, footer or size-field termination, `maxBytes` fallback. Skip bytes inside **claimed** runs (metadata files) so carving reports only orphaned data. Produce `RecoveredFile`s with `recoveryMethod: .carved`, `filesystem: .carved`, `content: .runs([one contiguous run])`, `isPartial: true` when terminated by `maxBytes`/end-of-extent without footer/size, and an `overwriteConfidence` estimate (0.0 when footer/size validated; 0.6 when partial; 1.0 if the region is internally inconsistent). `fragmentCount` stays 1 (contiguous carving only in v1; fragmented reassembly is out of scope and must be noted).
- **Naming (3.2):** `Reconstructed/<Type>/<type>-<deviceOffsetHex>.<ext>`; collisions are impossible by construction (offset unique); add a sequence suffix if two signatures match one offset. Path shows under `/Reconstructed/<Type>/`.
- **UI:** File Browser groups carved files under a visually distinct "Reconstructed" section within each bucket (EXPERIENCE.md); a "Partial — may be incomplete" text tag (no color); confidence from the existing single function (Medium/Low). Dashboard bucket counts include reconstructed files but show them as "(n reconstructed)".

## Boundaries & Constraints

**Always:** Carving must never emit a file overlapping a claimed metadata run. Work is bounded: cap concurrent open carves (e.g. 64), cap total carved files (e.g. 250k), and never buffer file bodies (only offsets). Validate signature JSON strictly for required fields and hex. Tests: synthetic devices with embedded JPEG/PNG/PDF/ZIP byte patterns across chunk boundaries, inside claimed runs (skipped), truncated (partial), and a wrong-`schemaVersion` + unknown-field JSON fixture. AD-7 floor: assert carved never scores High.

**Never:** No edits to any `Parsers/*.swift`, `ScanSession.swift` (the hook is in place), `ScanEvent.swift`, `RecoveryConfidence.swift`, DiskIO, `ResultsDashboardView.swift` beyond the "(n reconstructed)" caption, or CI. In the app you own `FileBrowserView.swift` and `ResultsViewModel.swift` edits for grouping/tagging; keep them additive. Another agent (lost partitions) adds a dashboard card in a new file and may add a small `volumeFilter` to `ResultsViewModel`; avoid restructuring that type.

## I/O & Edge-Case Matrix

| Scenario | Input | Expected |
|---|---|---|
| JPEG header+footer in unallocated space | synthetic | Carved, exact bytes, Medium, not partial |
| Header spanning two chunks | synthetic | Carved |
| Signature inside a claimed run | metadata file bytes | Not carved |
| Header without footer, hits maxBytes | synthetic | Carved `isPartial`, Low |
| ZIP with central directory | synthetic | Size via EOCD; Medium |
| Bad JSON schemaVersion / unknown field | fixtures | Skipped / accepted respectively |

</frozen-after-approval>

## Code Map

- `SalvageCore/Sources/SalvageCore/Carving/CarvingEngine.swift` (implement `SignatureCarver`, keep the `Carver` protocol and `init(emit:)`), new `Carving/SignatureLibrary.swift`, `Carving/Signatures/*.json`; add `resources: [.copy("Carving/Signatures")]` to `SalvageCore/Package.swift` (you own that file's resources line only) and make sure the Xcode app target still builds (SwiftPM resources in a local package are fine).
- App: `Salvage/ViewModels/ResultsViewModel.swift`, `Salvage/Views/FileBrowserView.swift` (Reconstructed section, Partial tag), one-line caption in `ResultsDashboardView.swift`.
- Tests: `SalvageCore/Tests/SalvageCoreTests/CarvingTests.swift`, `SignatureLibraryTests.swift`; `SalvageTests/ResultsViewModelTests.swift` additions.

## Verification

- `swift test --package-path SalvageCore`
- `./scripts/check-core-boundary.sh && ./scripts/check-no-network.sh`
- `xcodebuild -project Salvage.xcodeproj -scheme Salvage -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:SalvageTests test`
- `xcodebuild -project Salvage.xcodeproj -scheme Salvage -configuration Debug -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build`

## Implementation Notes

- **Schema (AD-6), as shipped:** required `schemaVersion` (1), `id`, `extension`, `category` (one of the `FileCategory` raw values; anything else is rejected, since it names the `Reconstructed/<Type>/` folder), `header` (hex). Optional: `headerOffset`, `alternateHeaders`, `footer`, `footerMode` (`first` | `last`), `footerLength`, `footerSizeField`, `maxBytes`, `sizeField` (one object or an array that is summed; each is `value * scale + adjust`, `scale` being another field with `oneMeans` for SQLite's page size), and `segments` (a chained record walk: `start`, `size`, `minimum`, `typeOffset`/`typeLength` with `typeMatch` or `typePrintable`, `largeSize`, `stopAt`). Hex accepts `?` nibble wildcards (`RIFF????WAVE`). Unknown keys anywhere are ignored, a known key set to `null` counts as absent, and `id`/`extension` are restricted to 1-32 ASCII `[A-Za-z0-9_-]` because they become file names. Files that fail validation land in `SignatureLibrary.skipped` with the reason and are reported with `NSLog` at load; the UI doesn't surface them yet (follow-up).
- **Why `segments` exists:** a footer-only JPEG rule ends at the EXIF thumbnail's own `FFD9`, so camera JPEGs would carve as a few KB. The marker walk (APP0/APP1/... up to `FFDA`) skips embedded data and hands over to the footer search at the scan data, where `FFD9` can only be the real EOI. The same walk gives exact sizes for ISO-BMFF (MP4/MOV/M4A/HEIC) by summing boxes; a sector-aligned JPEG header inside `mdat` is therefore ignored. "MP4 via size field" from the Intent is implemented this way because a single size field only covers the first box.
- **How a carve ends, and the AD-7 evidence it reports:** validated end (footer, size field, record walk ending at the first non-record) -> not partial, `overwriteConfidence` 0 -> Medium. Cut by `maxBytes`, by the next sector-aligned header, or by the end of the extent -> partial, 0.6 -> Low. Cut by a claimed run (the bytes belong to a live file) or a size field that is inconsistent (smaller than the header or larger than `maxBytes`) -> partial, 1.0 -> Low. `footerMode: last` (PDF) ends at the last footer seen when anything cuts it, so an incrementally updated PDF keeps all its revisions.
- **Next-header rule:** a header found while a carve is open ends that carve (partial) unless the open carve's structure (known size, record walk) says the position is inside the file. Because of this, concurrent open carves only ever share one start offset (two signatures matching the same bytes), so the 64-open-carve cap is a guard, not a working limit. Open-ended formats (MP3, gzip, OLE, RAR5) therefore end at the next file's header in practice rather than running to `maxBytes`.
- **Naming (3.2):** `<id>-<12 lowercase hex digits of the device offset>.<ext>` under `/Reconstructed/<category displayName>/`; a second signature matching the same offset with the same `id`/`extension` gets `-2`, `-3`. Carved files use `SourceMetadata(filesystem: .carved, volumeOffset: extent start, recordOffset: start, allocationStart: start, contiguous: true, rawRecord: header bytes)`, so `ScanViewModel`'s dedupe key stays unique. Only offsets are kept: `rawRecord` holds at most the library's reach (64 bytes).
- **Initial set (19 files):** JPEG, PNG, GIF, HEIC (ftyp heic/mif1/heix/hevc/heim/msf1), MP4 (isom/iso2/mp41/mp42/avc1/M4V/dash/mp71/MSNV/3gpN), MOV (qt), M4A/M4B, MP3 ID3v2, MP3 frame sync, WAV, AVI, PDF, ZIP, GZIP, 7z, RAR 1.5-4 (footer), RAR5, SQLite, OLE2 (.doc). Judgment calls: MP3 frame sync is limited to the common CBR first-frame bytes (128-320 kbps at 44.1/48 kHz, three fixed bytes) because a two-byte sync at sector alignment would produce thousands of false files per disk and the declarative schema can't express frame-header validation. MP3, gzip, OLE and RAR5 have no end rule and are always partial/Low; honest, but an OLE FAT walk and an MP3 frame walk would fix two of them (deferred). ZIP covers docx/xlsx/pptx with the `.zip` extension (their first entry doesn't reveal the type). GIF's `003B` footer and ZIP's `PK\5\6` can in theory occur inside compressed data. An ISO-BMFF box with size 0 ("to end of file") ends the walk before it. A JPEG with an MPF secondary image after its EOI loses that image unless the second header happens to be sector-aligned.
- **Sweep interplay:** headers are sought at multiples of 512 device-absolute bytes (configurable in `Limits`), so a partition that isn't sector-aligned still carves at device sector boundaries. Chunks that aren't contiguous with the previous one start a new extent: open carves are cut at the old extent's end (partial) and the carry window is dropped. A resumed scan carves only the remaining bytes, as the hook already arranged. `maxCarvedFiles` (250k) stops emission and sets `hitFileLimit`; nothing reports that to the user yet (follow-up).
- **UI:** `ResultsViewModel.apply` keeps the chosen sort and then moves reconstructed rows after the filesystem's rows; `visibleReconstructedCount` lets `FileBrowserView` render two `Table` sections ("From the filesystem" / "Reconstructed", macOS 14 `Section` rows) only when a listing has carved files. The Name column adds text-only "Reconstructed" and "Partial — may be incomplete" tags beside the existing "Deleted"; the preview pane explains both. Bucket tiles append "(n reconstructed)" to their caption (the only `ResultsDashboardView` line touched); the tile's accessibility label and the dashboard's closing sentence ("indexed from intact metadata") were not changed per the ownership limits and are now incomplete when carved files exist (follow-up). `FileCategory.fromSignature` is still empty: carved names always carry an extension.
- **Out of scope, noted per the Intent:** fragmented reassembly. Every carve is one contiguous run, `fragmentCount` is 1, and a file whose bytes continue after a claimed run is cut there.
- **Verification:** `swift test --package-path SalvageCore`: 230 tests in 14 suites pass (25 new: 18 carving, 7 library). `xcodebuild ... -only-testing:SalvageTests test`: 116 tests in 10 suites pass (1 new). Both boundary scripts pass; the unsigned Debug build succeeds and `Salvage.app/Contents/Resources/SalvageCore_SalvageCore.bundle/Signatures/` holds the 19 JSON files.
