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
