# Salvage

Salvage is a free, open-source macOS app (MIT License) that finds and recovers deleted and lost
files. It works on USB drives, SD cards, external drives and disk images. It reads the drive you
pick, shows what it found and how likely each file is to come back intact, and copies the files
you choose to a folder on a different drive.

> **Status: pre-release.** Everything below is built and covered by automated tests, but parts of
> it have not yet been checked on real hardware or by hand. See [Not yet verified](#not-yet-verified).

## Trust promises

Each promise below is enforced in code, and most are checked in CI. The in-app Trust Panel
(toolbar button **What Salvage reads and writes**) says the same things in plain language
(`Salvage/Views/TrustPanelView.swift`).

- **No network, except a manual update check.** The only network code in the project is
  `Salvage/Updates/UpdateChecker.swift`. It runs only when you choose **Check for Updates…**, and
  then it sends one GET request to GitHub's "latest release" API. `scripts/check-no-network.sh`
  fails CI if any other Swift file under `Salvage/`, `SalvageCore/`, `SalvageDiskIO/`,
  `SalvageHelper/` or `scripts/` uses a network API, or if any `Package.swift` declares a remote
  dependency. See [docs/PRIVACY.md](docs/PRIVACY.md).
- **Read-only.** Salvage unmounts the drive you pick, then opens it read-only. Every descriptor is
  checked to be open `O_RDONLY` before it is used, and a writable one is refused
  (`SalvageDiskIO/Sources/SalvageDiskIO/RawBlockReader.swift`). Recovered files go only to a
  folder you choose. A folder on the drive you are recovering from is blocked, and so is one
  whose drive Salvage can't identify.
- **Your startup drive is never scanned.** It is listed but grayed out, and the read path refuses it.
- **No tracking.** There is no analytics, no crash reporting and no account.
- **Open source.** Anyone can read the code behind every statement above.

## What it can read

| Kind | Supported |
| --- | --- |
| Filesystems | FAT32, exFAT, NTFS, EXT2/3/4, HFS+ (and HFSX), APFS |
| Partition maps | MBR and GPT. Extended (logical) MBR partitions and hybrid MBR/GPT maps aren't supported. |
| Encrypted volumes | Software-encrypted (FileVault) APFS volumes, unlocked with the password or recovery key. Hardware-bound encryption (the internal storage of a Mac with a T2 or Apple silicon chip) can't be unlocked. |
| Lost partitions | Filesystems found in unallocated space, outside the current partition table. They are read in place, and the partition table is never modified. |
| Reconstructed (carved) files | JPEG, PNG, GIF, HEIC, MP4, MOV, M4A, MP3, WAV, AVI, PDF, ZIP (including docx/xlsx/pptx, saved as .zip), gzip, 7z, RAR (4.x and 5), SQLite, OLE2 (Office 97–2003, saved as .doc). Defined by JSON files in `SalvageCore/Sources/SalvageCore/Carving/Signatures/`. |

Devices must use 512-byte logical sectors. See the [user guide](docs/USER-GUIDE.md#limitations)
for the full list of limitations.

## Build from source

You need macOS 14 or later and Xcode 16 with Swift 6. CI pins Xcode 16.0.

```sh
git clone https://github.com/hsmith-dev/Salvage.git
cd Salvage

# The engine and the disk adapter are Swift packages:
swift build --package-path SalvageCore
swift test  --package-path SalvageCore
swift build --package-path SalvageDiskIO
swift test  --package-path SalvageDiskIO

# The app, unsigned (the same build CI runs):
xcodebuild -project Salvage.xcodeproj -scheme Salvage -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build

# App view-model tests:
xcodebuild -project Salvage.xcodeproj -scheme Salvage -configuration Debug \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:SalvageTests test

# The policy checks CI enforces:
./scripts/check-core-boundary.sh
./scripts/check-no-network.sh
./scripts/check-xcodeproj-sync.sh   # needs xcodegen 2.46.0
```

`Salvage.xcodeproj` is generated from `project.yml` with xcodegen and committed. After you add
files or targets, run `xcodegen generate`.

**USB drives and SD cards need a signed build.** Physical drives' raw device nodes are owned by
root, so Salvage reads them through a small privileged helper (`SalvageHelper/`). The helper only
serves an app signed by the same team. An unsigned build can read only disk images you attach
yourself, such as `hdiutil attach -nomount image.dmg`. To read a real drive from source, set the
same team for the `Salvage` and `SalvageHelper` targets in Xcode and run a Debug build. The manual
steps are in
[spec-1-12, "Manual end-to-end verification"](_bmad-output/implementation-artifacts/spec-1-12-read-physical-drives-via-a-read-only-privileged-helper.md).

Signed, notarized releases come from `.github/workflows/release.yml` when a `v*.*.*` tag is
pushed, and are published to [GitHub Releases](https://github.com/hsmith-dev/Salvage/releases)
with a SHA-256 checksum. If no release is listed there yet, build from source.

## Project layout

- `SalvageCore/` is the recovery engine: filesystem parsers, carving, lost-partition search,
  FileVault decryption and recovery-confidence scoring. It depends on nothing but Foundation.
- `SalvageDiskIO/` is the macOS disk adapter: the device list (DiskArbitration), unmounting,
  raw read-only reads, the boot-disk check, destination safety, and the client for the privileged
  helper.
- `Salvage/` is the SwiftUI app. It is the composition root that connects `SalvageDiskIO` to
  `SalvageCore`.
- `SalvageHelper/` is the privileged read-only helper. It is a launchd daemon embedded in
  `Salvage.app`, and its one job is to open a validated whole disk read-only and hand the file
  descriptor back.
- `scripts/` holds the CI policy checks, their self-tests, and `spike-raw-device-access/`, a
  disposable harness from the Story 1.2 spike that is never built into the app.

## Documentation

- [User guide](docs/USER-GUIDE.md): install, scan, browse, preview, recover, FileVault, lost
  partitions, limitations.
- [Privacy](docs/PRIVACY.md): exactly what Salvage reads, writes and sends.
- [Command-line tool](docs/CLI.md): `salvage list`, `scan` and `recover`, with the same safety rules as the app.
- [Contributing a file signature](docs/CONTRIBUTING-SIGNATURES.md): the JSON signature format
  and how to test a new one.
- [Architecture overview](docs/ARCHITECTURE.md): the modules and their rules, with links to the
  planning documents.
- [Releasing](docs/RELEASING.md): the signing secrets, tagging a release, and verifying a download.

## Not yet verified

- **The signed privileged helper on real USB drives and SD cards.** The helper and its client are
  unit-tested, and CI checks that the helper is embedded where launchd expects it. Nobody has yet
  run a Developer ID–signed build end to end: approving the helper, scanning a real USB drive,
  and confirming launchd's SpawnConstraint and the helper's idle exit. It is also still open
  whether macOS privacy controls (TCC) gate the helper's raw open of removable media.
- **Hands-on UI testing.** Every flow is unit-tested at the view-model level, and the core path was
  checked without the UI on real exFAT and FAT32 images created by macOS. Nobody has yet clicked
  through scan, browse, preview and recover in the running app, and no VoiceOver testing has been
  done.

## License

[MIT](LICENSE).
