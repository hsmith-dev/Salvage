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
