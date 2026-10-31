---
title: 'Recover Selected Files to a Safe Destination'
type: 'feature'
created: '2026-10-31'
status: 'ready-for-dev'
baseline_commit: '0654e86'
route: 'dispatch'
context:
  - '{project-root}/_bmad-output/planning-artifacts/architecture/architecture-DataRecoveryTool-2026-10-30/ARCHITECTURE-SPINE.md'
  - '{project-root}/_bmad-output/planning-artifacts/ux-designs/ux-DataRecoveryTool-2026-10-31/DESIGN.md'
  - '{project-root}/_bmad-output/planning-artifacts/ux-designs/ux-DataRecoveryTool-2026-10-31/EXPERIENCE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** FR-14–FR-16 and AD-8 require three things:
- copying selected files byte-identically to a destination folder the user picks;
- refusing any destination on the same physical device as the source;
- a summary showing what was actually written.

**Approach:**
- **`SalvageDiskIO` — `DestinationSafety`:** decides whether a destination URL lives on the same physical device as the source `BlockDevice`. It resolves the destination volume via `statfs` (`f_mntfromname`), reduces it to a whole disk, and expands APFS physical stores. It reuses the existing `BootDiskSafety`/`BSDDeviceNames` helpers.
- **App — `RecoveryCoordinator`:** streams each file through `source.content` (`FileContentReader`) into the destination, one file at a time, and reports a result per file.
- **App — `RecoverySheet(files: [RecoveredFile], source: SourceSession, onDone: () -> Void)`:** the destination picker, a red block banner for an unsafe destination, progress, and a summary with "Show in Finder". Story 1.7, running in parallel, will present this sheet from its "Recover" button.

## Boundaries & Constraints

**Always:**
- **Destination check:** if it is the same device or can't be determined, Recover is disabled, with the banner "This folder is on the drive you're recovering from. Choose a folder on a different drive." There is no "proceed anyway". The banner is the only place the `blocking` color is used.
- **Path safety:**
  - Sanitize every name and path component, removing NUL, `/`, `:` (Finder) and leading dots, and replacing a lone `.` or `..` component with `_`.
  - Rebuild the original folder structure under one root folder, e.g. "Salvage Recovery <device> <date>".
  - Refuse any path that resolves outside that root. Check this after symlink resolution and use `O_NOFOLLOW`.
  - Never overwrite an existing file; add a " (2)"-style suffix instead.
- **Writing:**
  - Write to a temporary `.partial` file in the same folder, `fsync`, then rename atomically.
  - Set the modification date from `RecoveredFile.modified` when present.
  - On failure (disk full, permission, read error, unmapped), remove the partial file and record why. Never abort the whole batch.
- **Byte-identical:** compute SHA-256 while streaming and record it. Tests verify the written bytes equal the source bytes.
- **Summary:** the actual count and bytes written, which may be below the selection. List failed files by name with their reason. "Show in Finder" uses `NSWorkspace.activateFileViewerSelecting`.
- **Cancel:** the user can cancel mid-run. Files already written stay; the file in progress is cleaned up.
- **Security-scoped access** to the chosen folder isn't needed, because the app isn't sandboxed (see `project.yml`); confirm this.
- **Destination volumes:** the app may write only under the folder the user chose. It never writes to the source device.

**Never:**
- Don't edit `FileBrowserView.swift`, `ResultsDashboardView.swift`, `ContentView.swift`, `ScanViewModel.swift`, `RawBlockReader.swift`, the parsers or Core.
- No network APIs.

</frozen-after-approval>

## Code Map

- **New:**
  - `SalvageDiskIO/Sources/SalvageDiskIO/DestinationSafety.swift`, with an injectable mount-source resolver for tests.
  - `SalvageDiskIO/Tests/SalvageDiskIOTests/DestinationSafetyTests.swift`.
  - `Salvage/ViewModels/RecoveryCoordinator.swift` (testable with a temp directory and an in-memory `BlockReader`).
  - `Salvage/Views/RecoverySheet.swift`.
  - `SalvageTests/RecoveryCoordinatorTests.swift`.
- **Test cases:** traversal names, collisions, partial failure, an unmapped file, cancellation, byte equality and mtime.
- **Project:** regenerate with `xcodegen generate`.

## Verification

- `swift test --package-path SalvageDiskIO`
- `./scripts/check-core-boundary.sh && ./scripts/check-no-network.sh`
- `xcodebuild -project Salvage.xcodeproj -scheme Salvage -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:SalvageTests test`
- `xcodebuild -project Salvage.xcodeproj -scheme Salvage -configuration Debug -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build`
