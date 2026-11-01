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

## Implementation Notes — B

**Method.** Release `swift test -c release` (one process per image, `SALVAGE_BENCHMARK_SCAN_REPEATS=3`, best of 3 reported), before and after interleaved image by image over two rounds: new carve, old carve, new exFAT, old exFAT, new FAT32, old FAT32, then again. "Before" is `main` (`bd5d240`) `SalvageCore/Sources` built from a separate copy with this branch's `PerformanceTests.swift` dropped in, so both sides run the same harness on the same image files. Host: Apple M5 Max, with four other agents building and testing; load average was 110–280 during the first runs and fell to about 50 by the end. CPU time is the stable figure. Wall time moved up to 8× between identical runs under the heaviest load. Read counts are deterministic.

**Harness changes (`PerformanceTests.swift`, `scripts/benchmark-scan.sh`).**
- Each scan now reports `results_digest`: an FNV-1a hash over every event and notice except progress, in emission order. It covers every field of every found file except its random UUID, every byte of `rawRecord` and resident data, and the bit patterns of the `Double` and `Date` fields. Repeated scans of one image must produce the same digest, or the test fails.
- A new `carve` image (`SALVAGE_BENCHMARK_FS=carve`, `SALVAGE_BENCHMARK_CARVE_MIB`, default 1 GiB) is a raw file written directly, without hdiutil. It has no partition table and no filesystem. It holds a deterministic mix:
  - real ImageIO baseline JPEGs (640×480 up to 3000×2000) and PNGs;
  - JPEGs cut off part-way and followed by noise;
  - random noise and zero runs.

  The exFAT and FAT32 images are almost entirely claimed (0 carved files), so this is the only image that exercises the signature scan and the JPEG decoder.
- The script runs `exfat fat32 carve` (override with `SALVAGE_BENCHMARK_IMAGES`).

**Results (scan only, best of 3 per process; best of the two rounds; results identical before/after):**

| | carve before | carve after | exFAT before | exFAT after | FAT32 before | FAT32 after |
|---|---|---|---|---|---|---|
| CPU (user+sys), round 1 | 8.534 s | 5.636 s | 1.587 s | 0.829 s | 1.533 s | 1.055 s |
| CPU (user+sys), round 2 | 8.775 s | 6.038 s | 1.874 s | 1.118 s | 1.388 s | 0.747 s |
| **CPU, best** | **8.534 s** | **5.636 s (−34%)** | **1.587 s** | **0.829 s (−48%)** | **1.388 s** | **0.747 s (−46%)** |
| device reads | 35,716 | 35,716 | 7,156 | 7,156 | 5,842 | 5,842 |
| bytes read from device | 1,091,504,128 | same | 2,163,127,808 | same | 2,161,658,880 | same |
| wall, best | 8.564 s | 5.660 s | 1.411 s | 0.531 s | 1.128 s | 0.489 s |
| throughput, best | 120 MiB/s | 181 MiB/s | 1,450 MiB/s | 3,850 MiB/s | 1,815 MiB/s | 4,180 MiB/s |
| peak footprint during scan | 17.1–17.3 MiB | 17.1–17.3 MiB | 126.7–128.0 MiB | 126.3–131.2 MiB | 120.7–131.0 MiB | 129.2–129.5 MiB |
| results digest (events/notices) | `643164122c3f6bad`/`cbf29ce484222325` | same | `dc571ad4b324f780`/same | same | `9505e4faded16c49`/same | same |
| results | 729 carved (121 partial) | same | 91,050 live + 10,000 deleted | same | 91,050 live + 10,000 deleted | same |

The notice digest `cbf29ce484222325` is the FNV offset basis, meaning no notices were emitted. Read counts are unchanged because no change alters what is read; see read-ahead below. A first, heavily loaded carve run on `main` took 9.36 s of CPU. With only the ScanSession, carver and Huffman-table changes it took 7.38 s, before the bit-reader fast path was added.

**Profile before (`sample`, carve image, `main`).**
- `JPEGScanDecoder.drain()` was about 73% of on-CPU samples, and `JPEGCarveTrack.feed` another 7%.
- `swift_retain`/`swift_release` (and their bridge-object forms) were about 14%. The sources were per-block table loads in the decoder (`layout.dcTables[component]` / `acTables`) and `signatures.filter` copying every `FileSignature` at every sector.
- `claimedRange` and the `carry + chunk` copy were each about 1%.

Batch 5D's exFAT/FAT32 profile had already put the `.found` hand-off with the `ClaimedRuns` hop at 13–18%.

**What changed (no behaviour change):**
1. **`ClaimedRuns`, `CarveDropRange`, `MeasuredReader` (ScanSession.swift).** All three are now lock-protected (`NSLock`) final classes instead of actors.
   - A found file's claim no longer awaits an actor hop. Runs are appended in the same order.
   - A parser read no longer hops to the `MeasuredReader` executor. The coverage update and the "emit progress now?" decision happen together under the lock, and `measured` is snapshotted there. The source read and the progress event happen outside the lock, just as the actor was suspended across them.
   - `ranges`/`measured` stay readable, so `measuredCoverageStaysExactAcrossManyDisjointReads` passes unchanged (its `await`s now only produce "no async operations" warnings).
2. **Read-ahead coalescing was not done.** It would read bytes no parser asked for:
   - an unreadable sector just past a request would turn into an I/O failure the scan never had;
   - a read could cross an extent boundary that `MeasuredReader` must refuse;
   - `measured` would have to count bytes that were never requested.

   Removing the hop gets the per-read cost without any of that.
3. **`Data.number` (VolumeDiscovery.swift).** For 1-, 2-, 4- and 8-byte widths it does one `withUnsafeBytes` + `loadUnaligned` + `littleEndian`. Other widths use a plain loop. The guard is unchanged, so out-of-range reads still throw. `bigEndian` was left as it was: the section scopes only `Data.number`.
4. **Carver signature scan (CarvingEngine.swift).**
   - `HeaderDispatch` is a first-byte table, one per distinct `headerOffset`, mapping each byte value to a bitset of the signatures whose header pattern can start with it under its mask. Signatures with an empty header pattern are always candidates. Only those candidates go through the full `headerMatches && validates` test, in library order, so `matched` is exactly what `signatures.filter` returned, with no per-sector array or `FileSignature` copies.
   - The claimed-range binary search now runs once per unclaimed gap (`unclaimedUntil = nextClaimStart(after:)`) instead of at every sector.
5. **JPEG decoder (JPEGEntropyDecoder.swift).**
   - **Tables without ARC.** `JPEGScanLayout.blocks` flattens each MCU block's component, DC/AC table pointers and DC limit, so the decode loop does no retain/release and no array bounds checks per block or symbol. The layout keeps the tables alive.
   - **Faster long codes.** For codes longer than the 9-bit lookup, the canonical search starts at length 10 from the 9-bit prefix. A zero lookup entry proves that no code of 9 bits or fewer is a prefix, so the search cannot stop earlier.
   - **Bit-reader fast path.** `feedPlainData` reads the plain entropy data up to the next marker: bytes other than 0xFF, plus stuffed `FF 00` pairs. It drains at 56 bits instead of 40 (a drain leaves at most 30 bits, so the 64-bit buffer cannot overflow), without the per-byte status checks.
     - Drain timing only affects where a failure is reported (`position`, `unusedAtFailure`, so `validUpTo`). The fast pass therefore commits only where the reference loop would also be fully drained: at the end of a feed, or at a real marker (0xFF, any fill bytes, then a byte other than 0x00 or 0xFF).
     - It also commits when a drain ends a restart interval or the frame with fewer than 8 bits left and only a marker or the end of the range follows.
     - In every other case (any failure, an interval end followed by data, or fill bytes before a stuffed `FF 00`) it restores the state from before the feed and replays the range through the unchanged reference loop.
   - **Differential check.** A temporary differential test (not committed) compared the new decoder with a verbatim copy of the old one over 50,000 iterations: synthetic `TestJPEG`s with restart intervals 0–13, ImageIO JPEGs, and mutations (bit flips, boundary bytes, inserted RST/EOI markers, `FF 00`, `FF FF 00`, fill runs, truncation, noise). It used random feed splits of 1–9 bytes, 1–700 bytes, 512 bytes and the whole file, plus random `resumed(at:)` jumps. After every feed it compared every observable value (status, position, MCUs, restart count and sequence, last restart, `validUpTo`, bytes consumed) and every stored field by reflection, and it also compared `JPEGBaselineDecoder.decode` results. The first version committed at any 0xFF and differed in 5 of 6,000 cases, all at failure positions after `FF FF 00`. That is how the fill-byte rule was found. The final version has 0 differences in 20,000 + 30,000 iterations with two seeds.

**Not done / left as is:**
- The `carry + chunk` window concatenation per 1 MiB chunk (about 1% of samples) was left as it was.
- The lost-partition probes account for about 34,700 of the carve image's 35,716 reads. They are in `VolumeDiscovery` outside the `Data.number` helper, so this section doesn't own them.
- NTFS, EXT, HFS+ and APFS were not benchmarked at scale (see batch 5D for why). They still benefit from `Data.number` and from the removed actor hops.
- Per-change attribution on exFAT/FAT32 was not measured separately. Those images carve nothing, so their gain comes from items 1, 3 and 4 (the claimed-gap search, and no per-sector filter over the free space).

**Verification (B branch):**
- `swift test --package-path SalvageCore`: 406 tests in 31 suites passed, with the benchmark suite skipped. No existing test was changed.
- `swift test --package-path SalvageDiskIO`: 168 tests in 24 suites, all passed.
- The three check scripts pass.
- `xcodebuild … -only-testing:SalvageTests test` (Debug): 177 tests in 15 suites, TEST SUCCEEDED.
- The Release build succeeded.
- No workflow YAML was touched.

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

## Implementation Notes — A (parser fuzzing)

**What was built.**
- `SalvageCore/Tests/SalvageCoreTests/FuzzTests.swift`: a deterministic, seedable mutation fuzzer. It is opt-in (`SALVAGE_FUZZ=1`, `SALVAGE_FUZZ_ITERATIONS` per format, `SALVAGE_FUZZ_SEED`; the other knobs are listed in the file header).
  - Seeds: the existing synthetic builders (`fatImage`, `exfatImage` plus a deleted-entry variant, `EXTImage`/`ext2Image`/`deletedImage` for ext2 and ext4 extents and 64-bit descriptors, `HFSImage` basic/journaled/stale-slack), a compact port of the private NTFS builder, and MBR (exFAT + ext2 + an unlisted NTFS lost partition) and GPT (exFAT + HFS+) layouts. Real `hdiutil` images are added where available: FAT32, exFAT, HFS+, HFS+J, APFS, MBR/exFAT and GPT/HFS+J. They are created in a temp dir and attached `-nobrowse` at a private mount point only while populated (files written, one deleted), then detached and deleted. APFS has no synthetic seed, because the APFS builder is private to `APFSVolumeTests`; a checksummed NXSB stub stands in when hdiutil is unavailable.
  - Mutations: bit flips; 1/2/4/8-byte boundary values (LE, or mostly BE for HFS+); length-field targeting at per-format header offsets (boot sectors, superblocks, MFT records and attributes, inodes, B-tree headers and node descriptors, NXSB, MBR/GPT entries); arithmetic ±1..16; random runs; truncation; block duplication; zero/0xFF fills; and splicing 32 B–4 KiB from any seed (any format) into the image. Offsets favour blocks that hold structure in the seed. In 80% of iterations a fix-up step re-seals checksums the seed had valid, so mutations get past them: APFS Fletcher-64, exFAT boot region and entry sets, and the GPT header and entry array.
  - Each iteration runs a full `ScanSession` (discovery, parsers, sweep, carving) over the result through the in-memory `ImageReader`.
  - `fuzzParsers` (driver) re-invokes the test binary (`swiftpm-testing-helper … --filter FuzzTests/fuzzWorker`) once per batch, in parallel. The worker writes each iteration number to a status file before scanning it. A signal death or an unfinished exit is a crash, located by iteration, and `SWIFT_BACKTRACE` supplies a signature: the trap message plus the first SalvageCore frame. A child whose iteration outlives `HANG_BASE + HANG_PER_MIB × largest seed MiB` (30 s + 2 s/MiB) is SIGKILLed and reported as a hang. The batch then resumes at the next iteration. Each finding gets `crashes/<kind>-<format>-<iteration>/` with `input.img` and a `README.txt` holding the mutation list and two commands: one replays the input (`SALVAGE_FUZZ_REPRO=… --filter FuzzTests/fuzzReproduce`), the other regenerates it from the seed. Crashes are also greedily minimised against their base seed into `minimised.img` and a patch list (in Swift literal form, for regression tests). `summary.json` holds the totals. `SALVAGE_FUZZ_ALLOW` lets a known, owned-elsewhere signature be reported without failing the run.
  - `mutatorIsDeterministicAndSeedsScan` (always on) checks that the mutator is a pure function of (seed, format, iteration) and that every synthetic seed under 4 MiB scans to completion.
  - Harness self-test: `SALVAGE_FUZZ_INJECT_CRASH` / `SALVAGE_FUZZ_INJECT_HANG=<format>:<iteration>` trap or spin in the worker. With these, the injected crash (exfat:37, `signal 5`) and hang (ntfs:120, killed after 5 s) were both reported at the right iteration and the run continued.
- `scripts/fuzz-parsers.sh`: builds in release with `-Xswiftc -enable-testing`. Debug traps the same way but scans the 32 MiB FAT32 seeds about 150× slower (≈6 s vs ≈35 ms). The default is 20,000 iterations per format with a random seed. `--smoke` gives 500 iterations at fixed seed `0x5a17a6e`, `--debug` switches the build, and `--repro <file>` replays an input. Exits 1 on any non-allowed finding.
- `.github/workflows/ci.yml`: one new step, `./scripts/fuzz-parsers.sh --smoke`, after the DiskIO tests. Cost: the release test build took about 11 minutes here (the fuzz run itself takes about 25 s locally), so expect the step to add 10–20 minutes on the hosted runner.

**Runs (all release, 8 parallel workers, on a shared machine).**

| Seed | Iterations per format | Formats | Crashes | Hangs | Wall time |
|---|---|---|---|---|---|
| `0x20261101` | 20,000 | 9 | 0 | 0 | ~13 min of workers (driver hung, see below) |
| `0x20261102` | 20,000 | 9 | 0 | 0 | 231 s |
| `0x20261103` | 200,000 | 9 | 0 | 0 | 1,796 s |
| `0x5a17a6e` (smoke) | 500 | 9 | 0 | 0 | 10 s |

The formats are fat32, exfat, ntfs, ext2, ext4, hfsplus, apfs, mbr and gpt. The first run's driver never wrote a summary: `Process.waitUntilExit()` blocked forever on a cooperative thread after its children exited. Every worker had written `done` and no crash log was left, but that run is counted only as corroboration. The driver now observes exit through `terminationHandler`.

Scan depth check, 200 inputs per format: about half complete with files found and half end in a parser error (`malformed`, `unsupported`, cluster/extent damage). MBR and GPT complete almost always, because one damaged partition only skips that volume. FAT32 completes about 80% of the time, finding 0–10 files.

**Findings.** None. No trap or hang appeared in `Parsers/**`, carving or `ScanSession` in 2.2 million total iterations, so no parser fix or regression test was needed, and there are no carving or `ScanSession` crashes to report. The parsers' existing checked arithmetic (`checkedAdd`/`checkedMultiply`/`signed`, bounded `Data.number`) and work budgets held.

**Limits.** Coverage is mutation-based from a small seed set. It does not exercise APFS FileVault unlocking (no credentials are passed), resumed scans (`resumingFrom`), or recovery reads after the scan (`FileContentReader`). Real-image seeds differ between runs (UUIDs, timestamps), so a finding from a real seed is reproduced from its saved `input.img`, not from the seed number alone. HFS+ journal and NTFS update-sequence checksums are not re-sealed.

## Implementation Notes — D

**Audits added** (`SalvageUITests.swift`, `testAccessibilityAudit*`, macOS 14+ `performAccessibilityAudit`): Device Picker; Scan Progress running and paused; Results Dashboard with Partitions; File Browser with preview; Recovery sheet ready and blocked; Recovery Summary; Trust Panel; FileVault sheet (empty and after a wrong password). Each screen is audited in two passes (contrast on its own, as it is the slowest). A pass that times out ("Audit failed to complete in time", seen repeatedly under load averages of 40–235) is retried once, then reported as a timeout, not as findings. A new issue fails the test with every finding listed by screen. Known issues that need a change outside §D (list below) are attached to the test result ("<screen> -- reported accessibility issues") and don't fail it. They are matched by narrow rules in `knownIssue(_:window:table:sheet:)`.

**Lost partitions not audited.** The UI-test fixture image has no lost partition, so the Lost partitions card never appears. Auditing it needs a fixture with one (`Salvage/Testing/UITestFixtures.swift`), which is outside §D.

**Fixed (accessibility-only):**
- Device tree partition rows had "Unknown role": `.accessibilityAddTraits(.isStaticText)` (`DeviceListView`). The text is now exposed as a static text's value; tests match label or value.
- Device list scroll view had no description: `.accessibilityLabel("Devices")` on the List.
- Scan Progress file rows read only their size ("1 KB", unknown role), because `.combine` dropped the selectable path text. Now one static text: "path, volume, size". The list is labeled "Files indexed so far".
- Scan Progress bar: identifier `scan-progress`, value "Scanning, N percent" / "Paused, N percent" (EXPERIENCE.md role and state). Pause/Resume/Cancel scan are buttons with enabled state and hints; the tests check this.
- File table scroll view had no description: `.accessibilityLabel("Files")`.
- Preview pane confidence line ("Recovery confidence High") had unknown role: `.isStaticText`.
- Dashboard tile grid had no description: a container labeled "By type".

**Reported, not fixed (need a non-accessibility change, or are framework-internal):**
- Contrast: secondary/tertiary text fails or nearly fails the audit's ratio on every screen: partition rows, "Select a device to start scanning.", "5 files · 14 KB in total", "N files indexed", the scan footers, file paths in the table, the browser title, the summary's destination path, and the window title "Salvage" (seen while the window was inactive). This needs a DESIGN.md color-token change (EXPERIENCE.md's Increase Contrast fallback), not a modifier.
- NavigationSplitView / HSplitView panes (the window root, sidebar, detail and preview columns) are unlabeled AppKit groups. A label on the content doesn't reach them (tried on the split view root).
- Sheet host groups (Trust Panel, FileVault sheet, Recovery sheet) are unlabeled. `.accessibilityElement(children: .contain)` plus a label on each sheet's root doesn't reach them (tried on all three, reverted).
- SwiftUI Table cell containers (checkbox, Name, Path cells) are unlabeled. A label on the cell's Text doesn't reach them (tried on Path, reverted).
- The "Select" `Menu` in the File Browser: "Action is missing" (an AXMenuButton opens with AXShowMenu, not AXPress).
- FileVault sheet: one AppKit "Parent/Child mismatch" with no element attached.

**EXPERIENCE.md checks** (asserted in the audit tests): confidence labels announce the word ("Recovery confidence High"); the destination block banner is labeled "Destination blocked. …"; Pause/Resume/Cancel scan are enabled buttons, Pause is replaced by Resume while paused, the paused state is stated in words, and the progress bar has the progress role; partition rows read "Partition …, on <drive>".

**Robustness:**
- Every click goes through `click(_:)`. It brings Salvage to the front, gives the element a short wait to become hittable, then clicks.
- Every keystroke goes through `typeKey`/`typeText`. These re-activate Salvage and retry once on "Failed to synthesize event"; a second failure, or Salvage not reaching the front, records "Another app holds keyboard focus (frontmost: X)".
- The fixed sleeps in the pause test are replaced by `waitUntilStable`.
- An interruption monitor claims every interruption without touching it. XCUITest's "Handler claimed to have handled … still interrupting" is reworded as "Another app holds keyboard focus or covers Salvage".
- Found here: when a monitor can't make another app's system permission prompt go away, XCUITest falls back to its built-in handler and presses "Don't Allow" on it, whichever app it belongs to. It also swipes at notification-center elements.
  - In the first runs it tried this on PrivaStudy's "would like to access files in your Documents folder" prompt. Every attempt failed: the prompt stayed open until someone outside these tests answered it.
  - The suite now checks for an open permission prompt in `setUp` and before every click and keystroke. It fails with "Another app's permission prompt is open (…). Answer it, then rerun" and clicks nothing.

**UI suite runs** (the spec's command, `-only-testing:SalvageUITests`, 14 tests):
1. Before the prompt guard and the final rules: 8 passed, 6 failed. Failures: 4 from XCUITest's built-in handler on PrivaStudy's open permission prompt and notification-center elements (no effect on either); 1 from PrivaStudy's window covering Salvage; 1 Pause click that found no button.
2. With the prompt guard: 11 passed, 3 failed. Failures: 1 stopped cleanly by the guard while PrivaStudy's prompt was open; 1 had Path-cell findings not yet matched by the Table-cell rule (fixed after); 1 checked the partition row without waiting (now waits).
3. Final code: 14 passed, 0 failed. No built-in handler activity.

The coordinator then asked for no further UI runs: other agents' UI tests share the desktop and steal focus. Earlier discovery runs (subsets) also saw "Timed out while enabling automation mode" twice, audits timing out under load, and PrivaStudy's window covering Salvage.

**Other verification:** `check-core-boundary.sh`, `check-no-network.sh`, `check-xcodeproj-sync.sh` pass. SalvageTests: 177 tests pass. The Release build succeeds. The SwiftPM packages are untouched by §D, so they were not rerun.
