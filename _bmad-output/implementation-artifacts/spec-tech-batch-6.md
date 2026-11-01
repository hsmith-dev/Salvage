---
title: 'Batch 6: fuzzing, performance round 2, CLI, accessibility audit, release packaging'
type: 'tech'
created: '2026-10-31'
status: 'ready-for-dev'
baseline_commit: '427d405'
route: 'dispatch'
context:
  - '{project-root}/_bmad-output/planning-artifacts/architecture/architecture-DataRecoveryTool-2026-10-30/ARCHITECTURE-SPINE.md'
  - '{project-root}/_bmad-output/implementation-artifacts/spec-tech-batch-5.md'
  - '{project-root}/docs/ARCHITECTURE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

Five independent work items, one agent each. Each section lists the files it owns. Touching another section's files causes merge conflicts. Rules for every section:
- No network.
- No writes to any disk device.
- No sudo.
- Disk images only in temp dirs, detached and deleted afterwards.
- Never close or interfere with other apps or sessions on this Mac.

## A. Parser fuzzing (owns new `SalvageCore/Tests/SalvageCoreTests/FuzzTests.swift`, new `scripts/fuzz-parsers.sh`, and fixes in `SalvageCore/Sources/SalvageCore/Parsers/**` only)

**Goal:** a crafted or damaged drive must never crash Salvage. Swift traps on overflow, out-of-range subscripts and force-unwraps, so a trap during a scan kills the app.

**Approach.**
1. **Build a deterministic, seedable mutation fuzzer as an opt-in test** (`SALVAGE_FUZZ=1`, with `SALVAGE_FUZZ_ITERATIONS` and `SALVAGE_FUZZ_SEED`). Each iteration:
   - Starts from small valid seed images:
     - the existing synthetic builders for FAT32, exFAT, NTFS, EXT2/4, APFS and HFS+, plus MBR/GPT layouts;
     - real tiny `hdiutil` images where available.
   - Mutates them: bit flips, byte overwrites with boundary values (0, 0xFF, 0x7F…, 0x80…), length-field targeting at known header offsets, block truncation, block duplication, and splicing structures from one image into another.
   - Runs a full `ScanSession` over the result through an in-memory `BlockReader`.
2. **Detect crashes by running each batch in a child process** (re-invoke the test binary with a filter), so a trap is reported with its seed and iteration instead of killing the runner. Save every crashing input under the scratchpad with a reproducer command.
3. **Also check hangs:** every scan must finish within a wall-clock budget scaled to image size. Report any hang with its seed.
4. **Run it.** At least 20,000 iterations per format here. Then fix every crash and hang found in `Parsers/**` with checked arithmetic and bounds, following each parser's existing fail-closed or skip rules, and add a regression test per fixed bug using the minimised crashing input. Crashes found in carving or `ScanSession` are **reported, not fixed** (another agent owns those files), with seed and minimised input.
5. CI runs a short fuzz smoke test (500 iterations, fixed seed). Add the step to `.github/workflows/ci.yml` as **one new step only**.

## B. Performance round 2 (owns `SalvageCore/Sources/SalvageCore/ScanSession.swift`, `Carving/**`, `Parsers/VolumeDiscovery.swift` (only the `Data.number` helper and its callers' hot paths), `PerformanceTests.swift`, `scripts/benchmark-scan.sh`)

**Approach.** Batch 5D recorded these hotspots, in `spec-tech-batch-5.md` Implementation Notes D:
- ScanSession's per-file `.found` hand-off and the claimed-runs actor (13–18%);
- a `MeasuredReader` hop per read;
- carving at 15–18%;
- generic `Data.number` decoding.

Fix them without changing behaviour:
- **Claimed runs:** batch them (append runs in a local buffer and flush per volume), or make them a lock-protected struct.
- **Fewer actor hops:** read-ahead coalescing in `MeasuredReader` where it preserves measured-bytes semantics.
- **Faster `Data.number`:** use `withUnsafeBytes` and `loadUnaligned`.
- **Carving:** profile its signature scan loop. Use a first-byte dispatch table instead of testing every signature at every sector; avoid `Data` slicing.
- **JPEG decoder:** profile it (it runs on every carved JPEG at about 100 MB/s) and speed up its bit reader.

Measure before and after with the existing benchmark, in Release builds, on alternating runs. Every existing test must pass unchanged, and scan results must be byte-identical to before on the benchmark images. Report the numbers.

## C. Command-line tool (owns new `SalvageCLI/` directory, its target in `project.yml`, and a CI build step in `ci.yml` as **one new step only**; may add a small public API in `SalvageDiskIO` only if strictly needed, as a new file)

**Approach.** Build a `salvage` command-line tool, as a SwiftPM executable package at `SalvageCLI/Package.swift` that depends on `SalvageCore` and `SalvageDiskIO` by path. Commands:
- `salvage list`: the device tree, as in the app.
- `salvage scan <diskN | /path/to/image>`: progress to stderr. With `--json`, one JSON object per found file and per notice on stdout. `--deleted-only`, `--format`, `--limit` filters.
- `salvage recover <source> --to <folder> [--all | --path <glob> ... | --partition <offset>] [--include-reconstructed]`: uses the same rules as the app's `RecoveryCoordinator`. Extract that engine's pure logic into a shared place only if needed; if it's app-target-only, reimplement through `FileContentReader` and the same safety rules in DiskIO/Core, and document the duplication.
  - It refuses destinations on the source (`DestinationSafety`).
  - It never overwrites.
  - It reports results per file.
- `salvage --version`.

Constraints:
- Images are read from regular files directly (read-only `open`), and devices through `RawBlockReader`, which includes the boot-disk refusal and the helper fallback.
- Exit codes are documented.
- No network: the no-network checker must cover `SalvageCLI/`; extend the checker's scope list if needed, in its own line.
- Tests: a CLI test target that runs scan and recover against a temp exFAT image. Recovered files must be byte-identical. A destination on the source must be refused. JSON output must parse.
- Document it in `docs/CLI.md`, and add one line to README linking it.

## D. Accessibility audit and UI-test robustness (owns `SalvageUITests/**`, and accessibility-only modifiers in `Salvage/Views/*.swift`: labels, values, hints, traits, identifiers, sort priority, and Dynamic Type fixes limited to `.lineLimit`/`.minimumScaleFactor`/`.fixedSize`)

**Approach.**
- Add XCUITest `performAccessibilityAudit()` runs (macOS 14+) on each main screen:
  - the device picker;
  - scan progress (running and paused);
  - the dashboard, with Partitions and Lost partitions;
  - the file browser with preview;
  - the recovery sheet (ready and blocked);
  - the summary;
  - the Trust Panel;
  - the FileVault sheet.
- Fix every reported issue with accessibility-only changes. If an issue needs a layout or logic change, report it rather than fixing it.
- Check the EXPERIENCE.md rules:
  - confidence labels announce the word;
  - the destination block banner is labeled;
  - pause/resume/cancel have role and state;
  - the device tree reads "Partition …, on …".

**Robustness:**
- Call `app.activate()` before every keyboard interaction, and retry once with re-activation on "Failed to synthesize event".
- Wait on element state instead of fixed sleeps.
- If another app holds focus persistently, the test should record a clear issue ("another app holds keyboard focus"), not a misleading assertion. Don't close other apps.

Run the UI suite 3 times and report the results. If other sessions' apps keep stealing focus, report it as such.

## E. Release packaging (owns new `scripts/package-release.sh`, `scripts/test-package-release.sh`, `.github/workflows/release.yml`, and a "Releasing" section in `docs/ARCHITECTURE.md` or a new `docs/RELEASING.md`)

**Approach.** `package-release.sh <Salvage.app> <version> <outdir>`:
- Verifies the app bundle layout: the embedded helper and its launchd plist, as CI checks.
- Builds a compressed DMG (`hdiutil create -format UDZO`) containing `Salvage.app` and an `/Applications` symlink, with a deterministic volume name `Salvage <version>`.
- Writes `Salvage-<version>.dmg` and `SHA256SUMS`.
- In release mode only, behind flags, it signs the DMG, notarizes and staples it with `xcrun notarytool` / `stapler`. Credentials come from the existing secret names.
- A `--dry-run` mode runs everything that doesn't need credentials.

`release.yml` uses the script after the app is signed and notarized. Keep every existing verification step, including the helper-team check.

The self-test packages an unsigned Debug build in dry-run mode. It then mounts the DMG read-only, verifies the contents and the checksum, and detaches.

`docs/RELEASING.md` covers:
- the exact secrets the user must add;
- how to tag a release;
- what the workflow does;
- how to verify a downloaded release (checksum, `spctl --assess`, `codesign --verify --deep --strict`);
- the manual signed-helper end-to-end check from the 1.12 spec.

</frozen-after-approval>

## Verification (each agent runs what applies)

- `swift test --package-path SalvageCore`
- `swift test --package-path SalvageDiskIO`
- `./scripts/check-core-boundary.sh && ./scripts/check-no-network.sh && ./scripts/check-xcodeproj-sync.sh`
- `xcodebuild -project Salvage.xcodeproj -scheme Salvage -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:SalvageTests test`
- `xcodebuild -project Salvage.xcodeproj -scheme Salvage -configuration Release -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build`
- Workflow YAML must parse (`python3 -c "import yaml; yaml.safe_load(open(f))"`).

## Implementation Notes — E

**Built.**
- `scripts/package-release.sh (--dry-run | --release) [--identity NAME] [--keychain PATH] <Salvage.app> <version> <outdir>`. Exactly one mode is required, so a release can't happen by accident. It:
  - checks the layout as ci.yml does: `Contents/MacOS/SalvageHelper` is executable, the launchd plist lints, and `BundleProgram` = `Contents/MacOS/SalvageHelper`. It also checks `Info.plist` and the main executable;
  - checks the version is `X.Y.Z[-suffix]`, without a leading `v`;
  - builds the image in a temp work dir: `ditto` the app into staging, add an `Applications -> /Applications` symlink, then `hdiutil create -format UDZO -fs HFS+ -volname "Salvage <version>"` and `hdiutil verify`;
  - writes `Salvage-<version>.dmg` and `SHA256SUMS` (`shasum -a 256` format) only at the end. It refuses to overwrite either file.
- `--release` only:
  - it first checks `DEVELOPMENT_TEAM` and `NOTARIZATION_API_KEY` (the existing secret names) and names every one that's missing;
  - it requires the app to pass `codesign --verify --deep --strict`, to be signed by `DEVELOPMENT_TEAM`, to be stapled, and to have `CFBundleShortVersionString` equal to `<version>`;
  - it then signs the DMG with Developer ID (`--timestamp`, optional `--keychain`), checks the DMG's Team ID, runs `notarytool submit --wait` (the API key is parsed exactly like release.yml does, and the `.p8` is decoded into the temp dir, which is always deleted), then `stapler staple` and `stapler validate`. The checksum is computed after stapling.
- `--dry-run` skips signing and notarization and prints the commands instead. A version mismatch is only a warning in this mode.
- Exit codes: 0 OK, 1 a check failed, 2 usage.
- `release.yml`:
  - The old "Package release artifact (zip)" step is replaced by "Package, sign, and notarize the release disk image" (the script with `--release --keychain "$KEYCHAIN_PATH"`).
  - A new step, "Verify the release disk image", runs the checksum check, `codesign --verify --strict`, `stapler validate` and `spctl --assess --type open --context context:primary-signature`.
  - Publish now uploads the DMG and `SHA256SUMS`.
  - Every earlier step is unchanged: secrets check, keychain, signed build, signature and helper checks, the helper-team check, app notarization and staple, and keychain cleanup.
- `scripts/test-package-release.sh [app]` (25 scenarios):
  - fail-closed cases on stand-in bundles: no mode or both modes, `v`-prefixed or slash version, missing app, helper, plist, wrong BundleProgram, `--release` with no or malformed credentials. None of these creates an output folder;
  - a `--dry-run` package of a real unsigned Debug build. The outdir must hold exactly the DMG and `SHA256SUMS`, the checksum must verify, the format must be UDZO, and an existing DMG must be refused;
  - a read-only `-nobrowse` mount at a temp mount point. It checks the volume name, that the top level is exactly `Applications` and `Salvage.app`, that the symlink target is `/Applications`, that the helper and plist are present, and that `diff -r` against the source app is empty. Then it detaches;
  - a modified copy must fail the checksum.
  - The mount is also detached in the EXIT trap. Without an app argument (or `SALVAGE_APP`), it builds one into its temp dir.
- `docs/RELEASING.md` covers the secrets and how to make each value, tagging, each workflow step, how to try it locally, how to verify a download (shasum, `spctl` on the DMG and the app, `codesign --verify --deep --strict`, the helper identifier and team), and the 1.12 manual signed-helper end-to-end check (with the SpawnConstraint, `launchctl print` and idle-exit steps). In `docs/ARCHITECTURE.md`, the one-paragraph release.yml description now mentions the DMG and links RELEASING.md.

**Verified locally (dry-run only, nothing signed, notarized or sent).**
- The self-test passed all 25 scenarios against an unsigned Debug build (`CODE_SIGNING_ALLOWED=NO`).
- A sample `--dry-run ... 1.0.0` gave `Salvage-1.0.0.dmg` (3,096,653 bytes; volume "Salvage 1.0.0"; HFS+).
  - Top level: `Applications -> /Applications` and `Salvage.app`.
  - Inside the app: `Contents/MacOS/{Salvage, SalvageHelper, Salvage.debug.dylib, __preview.dylib}`, `Contents/Library/LaunchDaemons/dev.hsmith.Salvage.Helper.plist`, and `Resources/SalvageCore_SalvageCore.bundle`.
  - It was detached and deleted afterwards, and `hdiutil info` shows no image left.
- Both workflow YAML files parse with `yaml.safe_load`. `check-no-network.sh` passes. shellcheck is clean on `package-release.sh`. On the test script it reports only info/style notes (`A && B || C` reporting, `ls`), the same style as the other `test-check-*` scripts.

**Not done / follow-ups.**
- The `--release` path (signing, `notarytool`, `stapler`, the new release.yml steps) has never run. It needs the real secrets on the release runner, and the first tagged release is its test. The same goes for the 1.12 manual check in RELEASING.md §5.
- The DMG bytes are not reproducible: `hdiutil` embeds timestamps, so the checksum changes from build to build (two runs gave different sums). Only the volume name and contents are deterministic, which is what the spec asks for.
- The release no longer publishes the `.zip` and `.sha256`. It publishes the DMG and `SHA256SUMS` instead.
- `test-package-release.sh` is not in ci.yml: §E doesn't own ci.yml, and A and C each own one step there. Suggested step: `./scripts/test-package-release.sh "$RUNNER_TEMP/DerivedData/Build/Products/Debug/Salvage.app"`, after the "Verify the helper is embedded" step. README doesn't link RELEASING.md (README isn't §E's).

## Implementation Notes — C

**What was built.** `salvage` is a SwiftPM executable package at `SalvageCLI/`. It depends on `SalvageCore` and `SalvageDiskIO` by path and contains three targets:
- `SalvageCLIKit`: everything testable;
- `salvage`: a thin `main.swift`, where Ctrl-C cancels the command;
- `SalvageCLITests`.

It has `list [--json]`, `scan <diskN|image> [--json] [--deleted-only] [--format …] [--limit n] [--quiet]`, `recover <source> --to <folder> (--all | --path <glob>… | --partition <offset>…) [--include-reconstructed] [--json] [--quiet]`, and `--version`/`--help`. It is documented in `docs/CLI.md`, with one README line linking to it. Exit codes are 0 done, 1 failed, 2 usage, 3 refused for safety, 4 finished with problems, 5 nothing matched, and 130 interrupted. A test checks that the doc lists each one.

**Safety rules, and where each one is enforced:**
- **Read-only source.**
  - Devices go only through `RawBlockReader.prepare`, so they get the same checks as the app: the whole-disk name check, the identity checks, unmounting, an `O_RDONLY` open with the helper fallback, and validation of the descriptor.
  - Image files go through `ImageFileReader`. It opens with `O_RDONLY`, checks the access mode after the open, accepts only a regular file, and reads with `pread`. A device node, or a link to one, given as a "path" is refused (exit 3), so `/dev/rdisk0` can't bypass the device checks.
  - Compressed or encoded UDIF images (koly trailer with an XML block map) are refused rather than misread.
- **Startup-disk refusal.** The CLI checks `isBootVolume` from the device tree and refuses before anything is opened. `RawBlockReader.prepare` refuses it again. A partition (`disk4s1`) or a synthesized container is refused with the whole-drive name to use.
- **Destination on the source.**
  - **For a device:** `DestinationSafety.live`.
  - **For an image file:** the new `SalvageDiskIO/Sources/SalvageDiskIO/ImageFileDestinationSafety.swift`. This is the one new public DiskIO API, and it is strictly needed: the live physical-store, backing and `wholeDiskBSDName` resolvers are internal. The source is the image file, so a destination counts as on the source when its volume is backed by that file, directly or through nested images. The file is compared by `(st_dev, st_ino)`. Anything undetermined is refused. A folder on the volume that *stores* the image is allowed, matching how the app treats an attached image (its `sourceDeviceSet` doesn't follow the image to its host).
  - **Order of checks:** checked before the source is opened (opening a drive unmounts it), then again right before writing. The engine then checks `fstatfs` coverage of the folder it actually opened.
- **Never overwrite.** The app's engine is used unchanged. `RecoveryEngine` lives in the app target, so `SalvageCLIKit/RecoveryEngine.swift` is a **verbatim copy** of everything in `Salvage/ViewModels/RecoveryCoordinator.swift` above `// MARK: - Coordinator`. That copy includes `RecoveryPaths`, the `O_EXCL` `.partial` publish, the `O_NOFOLLOW` walks, root containment and durable sync. This duplication is documented in the file header and in `docs/CLI.md` (Maintenance, with an exact re-copy command). `engineCopyMatchesTheApp` fails on any drift. Moving the engine into a shared module would have meant editing app files outside §C.
- **No network.** `scripts/check-no-network.sh` gained one line, `scan_dirs+=(SalvageCLI)`. `noNetworkCheckerCoversTheCLI` plants a violation under `SalvageCLI/` in a temp tree and checks that it is caught. There are no remote packages.

**Decisions:**
- **No `project.yml` target.** The CLI stays a standalone SwiftPM package: it isn't built into or embedded in the app, and `Salvage.xcodeproj` is unchanged. This avoids regenerating the project, and avoids conflicts with D and E, which also touch the app bundle and project.
- **CI.** `ci.yml` gained one step: `swift test --package-path SalvageCLI`.
- **Recover selection.** `--all`, `--path` and `--partition` select only recoverable files (`!isUnmapped`). Reconstructed files need `--include-reconstructed`, even when they are the only matches. The app pre-ticks the box in that case; the CLI exits 5 with a hint instead.
- **Incomplete scans.** If a scan fails part-way, the files found so far are still recovered, as in the app's "found so far" flow, and the exit code is 4.
- **Recovery folder name.** It is `Salvage Recovery <drive or image name> <date>`.
- **JSON output.** It is JSON Lines with sorted keys. Besides the specified `file` and `notice` objects, `scan --json` also emits `lostPartition` objects. Notices come after the files, since the notice stream is drained when the scan ends.

**Tests.** `swift test --package-path SalvageCLI` passes 28 tests in 6 suites. Drives in the tests are always injected fakes: no real device is listed or opened. The image tests build 16 MB GPT/exFAT images with `hdiutil` in a temp folder. Each image is attached only while it is populated, or for the mount-refusal test, then detached and deleted. The tests cover:
- `scan --json`: every line parses, live and deleted files are listed, and the filters and `--limit` work;
- `recover --all`: every file is byte-identical, including the deleted one, with no `.partial` files left over;
- a second run gets a ` (2)` folder and leaves the first run's files untouched;
- `--path` and `--partition` select the right files, and an empty match exits 5;
- a destination inside the mounted source image is refused through the *live* `ImageFileDestinationSafety`, with nothing written;
- a fake drive is checked → opened → checked again, in that order, then recovered;
- the startup disk, and a same-device or undetermined destination, are refused with zero opens;
- unit tests for parsing, globs, the image reader (device nodes, UDIF trailers) and the image-destination rule, plus the repo guards (engine drift, version vs `project.yml`, no-network coverage);
- the built binary, run as a process.

**Verification run (2026-11-01, on this branch):**
- `swift test --package-path SalvageCLI`: 28 tests in 6 suites passed.
- `swift test --package-path SalvageCore`: 406 tests in 31 suites passed.
- `swift test --package-path SalvageDiskIO`: 168 tests in 24 suites passed.
- `check-core-boundary.sh`, `check-no-network.sh`, `check-xcodeproj-sync.sh` and `test-check-no-network.sh` all passed.
- `xcodebuild … -only-testing:SalvageTests test`: 177 tests in 15 suites passed.
- `xcodebuild … -configuration Release … build`: succeeded.
- `ci.yml` and `release.yml` parse with `yaml.safe_load`.

**Not done / limits:**
- FileVault volumes can't be unlocked from the CLI; they are reported as locked.
- There is no pause or resume.
- Physical USB drives and memory cards can't be read by the CLI as a normal user. The privileged helper's peer requirement only accepts the signed app, so `RawBlockReader` returns the helper's guidance error. User-owned devices and image files work.
- The device path (`list`, `scan diskN`, `recover diskN`) was exercised only with injected fake drives, as required. It was never run against a real device: the one live manual check listed devices and then refused the startup disk before opening anything.
