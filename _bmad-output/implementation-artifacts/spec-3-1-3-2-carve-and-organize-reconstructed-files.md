---
title: 'Carve Files from Raw Bytes and Organize Reconstructed Files (Stories 3.1 + 3.2)'
type: 'feature'
created: '2026-10-31'
status: 'ready-for-dev'
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
