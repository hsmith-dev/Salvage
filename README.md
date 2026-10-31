# Salvage

Salvage is a free, fully open-source macOS app for recovering deleted and lost files from
removable media (USB drives, SD cards, external drives) and other mounted disks, built to be
transparent and verifiably trustworthy -- it makes zero network calls during scanning or
recovery, and the only network activity anywhere is an explicit, user-initiated update check.

Licensed under the [MIT License](LICENSE).

## Project structure

- `SalvageCore/` -- the domain engine (filesystem parsers, carving, recovery-confidence scoring); depends on nothing but Foundation.
- `SalvageDiskIO/` -- the macOS disk-I/O adapter (DiskArbitration, raw block-device reads, FileVault unlock).
- `Salvage/` -- the SwiftUI app target; the composition root wiring `SalvageDiskIO` into `SalvageCore`.

## Planning and architecture docs

- [`_bmad-output/planning-artifacts/architecture/architecture-DataRecoveryTool-2026-10-30/ARCHITECTURE-SPINE.md`](_bmad-output/planning-artifacts/architecture/architecture-DataRecoveryTool-2026-10-30/ARCHITECTURE-SPINE.md) -- the hexagonal architecture spine and its invariants (AD-1 through AD-12).
- [`_bmad-output/implementation-artifacts/epic-1-context.md`](_bmad-output/implementation-artifacts/epic-1-context.md) -- Epic 1 goal, requirements, and story list.

## Building

```sh
swift build --package-path SalvageCore
swift build --package-path SalvageDiskIO
xcodebuild -project Salvage.xcodeproj -scheme Salvage build
```

`scripts/check-core-boundary.sh` enforces the module boundary between `SalvageCore` and
`SalvageDiskIO` locally, the same way CI does.
