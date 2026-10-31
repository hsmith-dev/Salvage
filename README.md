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
- `scripts/spike-raw-device-access/` -- a standalone, disposable SwiftPM CLI harness built for Story 1.2's Full Disk Access / raw-device-access spike (see `_bmad-output/implementation-artifacts/spec-1-2-full-disk-access-raw-device-access-spike.md`). It is never wired into `Salvage.app`, `SalvageCore`, or `SalvageDiskIO`, so its direct `import DiskArbitration` is a deliberate, narrow exclusion from `scripts/check-core-boundary.sh`'s repo-wide DiskArbitration-ownership check (AD-1/AD-9 bind the three hexagonal modules, not standalone spike tooling).

## Planning and architecture docs

- [`_bmad-output/planning-artifacts/architecture/architecture-DataRecoveryTool-2026-10-30/ARCHITECTURE-SPINE.md`](_bmad-output/planning-artifacts/architecture/architecture-DataRecoveryTool-2026-10-30/ARCHITECTURE-SPINE.md) -- the hexagonal architecture spine and its invariants (AD-1 through AD-12).
- [`_bmad-output/implementation-artifacts/epic-1-context.md`](_bmad-output/implementation-artifacts/epic-1-context.md) -- Epic 1 goal, requirements, and story list.

## Building

```sh
swift build --package-path SalvageCore
swift build --package-path SalvageDiskIO
xcodebuild -project Salvage.xcodeproj -scheme Salvage build

# Disposable spike harness (see scripts/spike-raw-device-access/ above):
swift build --package-path scripts/spike-raw-device-access
```

`scripts/check-core-boundary.sh` enforces the module boundary between `SalvageCore` and
`SalvageDiskIO` locally, the same way CI does.
