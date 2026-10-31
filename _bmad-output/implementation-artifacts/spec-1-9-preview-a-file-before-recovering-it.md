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

## Implementation Notes

- **Interface:** `FilePreviewView(file: RecoveredFile, source: SourceSession?)` exactly as contracted. All loading lives in `PreviewLoader` (a `Sendable` struct; `load(_:)` is a nonisolated async function, so it runs off the main actor). It is injectable through `init(readPrefix:)`; `init(source:)` wires it to `source.content.prefix(of:limit:)`. The view drives it from `.task(id: file.id)`, so a selection change cancels the in-flight read.
- **Read order:** the loader first reads a 4 KiB header for format detection and the raw-bytes dump. It then reads the rest, up to the format's cap, only when needed. An image or PDF larger than 32 MiB is refused as "too large" after the header read only. The full 32 MiB is never pulled for a file that can't be shown. For text and unknown formats, if the 4 KiB header already fails text decoding, the loader stops there and does not read 1 MiB.
- **Text over 1 MiB:** shown truncated to the first 1 MiB with a "Showing the first 1 MB." note, rather than refused. A multi-byte UTF-8 sequence split by the cap is trimmed. UTF-16 is recognised only with a BOM, and more than 95% of its code units must be printable: assigned, not private-use, not a lone surrogate, and not a control character other than tab, LF, CR or FF. Otherwise random bytes after `FF FE` would pass as CJK "text". UTF-8 text with NULs or other control bytes counts as binary.
- **Format detection:** "BM" alone no longer means BMP, since a CSV can start with "BMI,". `PreviewFormat.isPlausibleBMP` also requires a known DIB header size (12, 16, 40, 52, 56, 64, 108 or 124), a pixel-data offset past both headers, and a file-size field that is either 0 or at least that offset. The header sniff now looks at 32 bytes.
- **Images:** decoded with ImageIO (`CGImageSourceCreateThumbnailAtIndex`, max 2048 px, EXIF transform applied) instead of `NSImage(data:)`. That is still Apple's decoder, and it avoids a full-size decode. An image whose declared pixel count is over 100 megapixels is refused as "too large" before decoding, to avoid a decompression bomb. An image that doesn't declare both `PixelWidth` and `PixelHeight` is refused (`checkDeclaredSize`), since its decode cost can't be bounded. The thumbnail is built straight from the source (`kCGImageSourceCreateThumbnailFromImageAlways`, max pixel size 2048), with `kCGImageSourceShouldCache` and `kCGImageSourceShouldCacheImmediately` both false, so there is no full-size decode. ImageIO won't report the size of a header-only fixture this large, so the cap is tested through `checkDeclaredSize` directly.
- **PDF:** decoded with `PDFDocument(data:)` in the loader. It is wrapped `@unchecked Sendable` to hand it to the main actor (it is not mutated afterwards). `PDFView` link clicks are swallowed through its delegate, `PDFLinkBlocker`, so a hostile PDF can't open a URL. PDFView opens the URL itself only when its delegate doesn't implement `pdfViewWillClick(onLink:with:)`. The blocker's implementation only records the URL, and a unit test covers it.
- **Reasons:** I added a fifth reason, `empty` ("This file is empty."). A missing `SourceSession` reports "The device couldn't be read." `FileContentError.runsShorterThanFile` and `.runOutsideDevice` count as "unmapped" ("can't be recovered"), alongside `.unmapped`.
- **Truncated reads:** `FileContentReader.prefix` can return short data without throwing when its stream is cancelled. The loader rejects any read whose length is not the expected one, and checks for cancellation after each read, so a partial read is never shown as content.
- **Raw bytes:** offered as "Show raw bytes" on the no-preview state whenever the header could be read (unsupported format, corrupt image or PDF, or too large). It is not offered for unmapped or unreadable files.
- **Metadata header:** this view owns it (name, size, modified, "Deleted"). A host adds extra lines (the File Browser adds path and recovery status) through the `details` view builder, `FilePreviewView(file:source:details:)`. They sit under the header instead of wrapping the view in a second background and padding. `FilePreviewView(file:source:)` is unchanged.
- **Accessibility:** the preview region is labelled "Preview of <name>". The no-preview state is one combined element labelled "No preview available. <reason>", and the same string is posted as an `AccessibilityNotification.Announcement`.
- **Not done here:** Story 1.7 owns placing this view in the File Browser, and the Space-bar shortcut (Space shows a hidden preview and never hides a showing one; see spec-1-7-1-8). `sprint-status.yaml` was left untouched to avoid merge conflicts between the parallel branches.
