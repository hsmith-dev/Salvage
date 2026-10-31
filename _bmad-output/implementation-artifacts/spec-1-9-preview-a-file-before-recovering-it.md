---
title: 'Preview a File Before Recovering It'
type: 'feature'
created: '2026-10-31'
status: 'ready-for-dev'
baseline_commit: '0654e86'
route: 'dispatch'
context:
  - '{project-root}/_bmad-output/planning-artifacts/ux-designs/ux-DataRecoveryTool-2026-10-31/DESIGN.md'
  - '{project-root}/_bmad-output/planning-artifacts/ux-designs/ux-DataRecoveryTool-2026-10-31/EXPERIENCE.md'
  - '{project-root}/_bmad-output/planning-artifacts/ux-designs/ux-DataRecoveryTool-2026-10-31/mockups/file-browser.html'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** FR-13 asks that users can preview a discovered file without recovering it first.

**Approach:**
- Build a self-contained `FilePreviewView(file: RecoveredFile, source: SourceSession?)`.
- It reads a bounded prefix of the file in memory through `source.content` (`FileContentReader`, commit `113d279`) and renders it:
  - images via `NSImage(data:)`, downsampled;
  - PDF via PDFKit `PDFDocument(data:)`;
  - plain text and UTF-8/UTF-16 decodable text;
  - otherwise a hex dump of the first 4 KiB, offered as "Show raw bytes".
- Unsupported, unmapped or unreadable files show an explicit "No preview available" state.
- Story 1.7, running in parallel, will drop this view into its preview slot.

## Boundaries & Constraints

**Always:**
- **Read caps:** at most 32 MiB for images and PDFs, 1 MiB for text. Read off the main actor and cancel when the selection changes (a `.task(id: file.id)` loader).
- **Large images:** downsample before display, e.g. with `CGImageSourceCreateThumbnailAtIndex`, max dimension 2048.
- **Show the reason** when there is no preview: no supported format, can't be recovered (unmapped), file too large for preview, couldn't read the device. Use the `ink-tertiary` style from `DESIGN.md`.
- **Metadata header:** name, size, modified, "Deleted" tag.
- **Never write anything to disk.** No temp files. Previews are in-memory only.
- **No QuickLook API:** it needs a file URL.
- **Preview bytes are untrusted input** from damaged or hostile media. Use only Apple's image/PDF decoders. No WebKit or HTML rendering (the zero-network rule).
- **VoiceOver:** label the preview region and announce "No preview available" plus the reason.

**Never:**
- Don't edit `FileBrowserView.swift`, `ResultsDashboardView.swift`, `ContentView.swift`, `ScanViewModel.swift`, Core or DiskIO.
- Don't add network-capable APIs.

</frozen-after-approval>

## Code Map

- New `Salvage/Views/FilePreviewView.swift` and `Salvage/ViewModels/PreviewLoader.swift`. The loader is a testable, injectable reader that does format detection by magic bytes first and extension second.
- New `SalvageTests/PreviewLoaderTests.swift`. Build `SourceSession` values over an in-memory `BlockReader` with `RecoveredFile.content` runs, and check images, PDF, text, binary, unmapped, an oversize file and a read failure.
- Regenerate the project with `xcodegen generate`.

## Verification

- `./scripts/check-no-network.sh`
- `xcodebuild -project Salvage.xcodeproj -scheme Salvage -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:SalvageTests test`
- `xcodebuild -project Salvage.xcodeproj -scheme Salvage -configuration Debug -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build`
