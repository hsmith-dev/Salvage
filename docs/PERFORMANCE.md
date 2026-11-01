# Performance at scale

This page describes how Salvage behaves on a large drive. The reference case is a 320 GB USB
hard drive with an MBR partition table, one NTFS partition with 144 GB used (hundreds of
thousands of files) and a 14 GB NTFS "RECOVERY" partition. It gives the measurements taken
before and after the scale pass, what was changed, what is still a risk, and how long a scan of
that drive should take.

## How it was measured

Everything ran on disk images in a temporary folder. No real drive was opened.

- **NTFS image** (`scripts/scale-benchmark`, `make-ntfs-image`): a 44 GiB sparse raw image with
  about 17 GB actually written. It has an MBR and two NTFS volumes:
  - **Volume 1** (40 GiB): 4 KiB clusters, 1 KiB MFT records, and 350,000 files in 25,000
    folders. The folders nest up to 10 levels, plus one chain 64 levels deep. 10% of the files
    are resident, 10% are deleted and 5% are fragmented. Volume 1 also has a 1 GiB unallocated
    zone holding 1,898 real JPEGs mixed with noise, for the carver.
  - **Volume 2** (4 GiB): 3,000 files.

  The second variant (`SHUFFLE=1`) numbers the MFT records in random order relative to where
  their data lies, like a drive that has been in use for years.
- **exFAT image** (`scripts/benchmark-scan.sh` with `SALVAGE_BENCHMARK_FILES=100000`,
  `SALVAGE_BENCHMARK_SIZE_MIB=6144`): 6 GiB, made with `newfs` through `hdiutil`. It holds
  100,000 files and the scan reports 201,050 entries.
- **Carve image** (`scripts/benchmark-scan.sh`, `carve`, 4 GiB): no filesystem. It holds real
  JPEGs and PNGs, truncated JPEGs, noise and zeros, so every byte goes through the carver and
  the JPEG decoder.
- **CLI**: a Release build of `salvage scan <image> -q` and `salvage recover <image> --all`,
  timed with `/usr/bin/time -l`. The NTFS image was also attached with
  `hdiutil attach -nomount` and scanned as `diskN`, which uses the device read path. Its
  identity was checked with `hdiutil info` before it was scanned or detached.
- **Read trace** (`trace-scan`): runs a `ScanSession` over an image and records every read. It
  reports the number of reads, the small reads and the seeks (a read that doesn't start within
  1 MiB of where the previous one ended), and the memory held per found file. From these it
  models a USB hard drive: 130 MB/s on USB 3 or 35 MB/s on USB 2, plus 12 ms per seek.
  `THROTTLE=<MB/s>` makes each read take as long as it would on a drive of that speed.
- **App model layer**: the app's own `ScanViewModel.swift`, `ResultsViewModel.swift`,
  `PartitionSummary.swift` and `ScanArchive.swift` were compiled into a Release executable. It
  feeds 500,000 NTFS-like files through a fake runner and redraws a stand-in progress view at
  most once per 16 ms frame. The view reads what `ScanProgressView` reads: the volume labels,
  the file count and, with the List cost on, every row's identity. The "before" column is the
  same driver run against the files as they were before this pass.

The host is an Apple M5 Max (18 cores). Other jobs kept its load average around 40 the whole
time, so wall times are noisy. Read the counts, the memory figures and the ratios rather than
the exact seconds.

## Results

| Measurement | Before | After |
|---|---|---|
| CLI scan, NTFS image file (44 GiB, 353,000 metadata files + 1,898 carved) | 17.0 s, peak RSS 779 MB | 15.2 s, peak RSS 586 MB, same output |
| CLI scan, same image attached as `diskN` | 23.4 s, 782 MB | 23.4 s, 597 MB |
| Memory held per found NTFS file | 1,894 B | 1,352 B |
| Long-used layout (shuffled MFT): reads under 64 KiB / seeks | 32,459 / 16,176 | 1,034 / 17 |
| …the same scan, modelled on a USB 3 hard drive | 564 s (194 s of it seeking) | 370 s |
| 4 GiB JPEG-heavy carve image read at 130 MB/s (33 s of pure transfer) | 72.8 s | 51.5 s |
| Carving CPU throughput, JPEG-heavy data, one core | 149 MiB/s | unchanged |
| CLI scan, exFAT image (6 GiB, 201,050 entries) | 2.6 s, 243 MB | 1.3 s, 248 MB |
| `salvage recover --all`, NTFS image, to an internal SSD | 225 files/s, 9.6 MB/s (stopped after 105,848 files) | 970 files/s, 42 MB/s (353,000 files, 15.2 GB in 365 s) |
| App: 500,000 files through `ScanViewModel` and the progress view | 26–51 s; 860–1,640 redraws; 11.5–21 s of main-thread redraw time; worst frame 38–127 ms | 0.8–1.1 s; 4–6 redraws; at most 52 ms in all; worst frame 18 ms |
| App: results model at 500,000 rows | build 1.7 s (off the main thread); totals 7 ms; sort by name 0.94 s and other sorts and searches 0.13–0.26 s (off the main thread); Partitions section 101 ms (main thread, once) | unchanged |
| App: saved scan of 500,000 files | 69 MiB, written in 58 ms and read in 110 ms | unchanged |
| Checkpoint | 236 bytes of JSON, saved at most once a second | unchanged |

On the exFAT row, the scan code for exFAT didn't change. The difference there is mostly load
on the host and the read-ahead.

## What changed

1. **Scan events reach the app's main thread in batches** (`ScanViewModel`). Each event used to
   be handled on the main thread, so every found file cost a main-thread wakeup. Each file was
   also appended to the observed `files` array on its own, and every redraw of the progress
   view rebuilt the volume labels with a pass over all files. Together that was O(n²) work on
   the main thread. A 500,000-file scan spent 12–21 s of the main thread redrawing, with frames
   up to 127 ms. Its event pipe also slowed the scan itself, because the core waits whenever the
   app's small event buffer is full.

   Now the event stream is read off the main thread. Events are applied there in one batch at
   most every 250 ms. Errors, completion, lost partitions, unlock requests and the first
   progress event are applied at once, after the files found before them. Volume labels come
   from a set that is kept up to date as files arrive.
2. **The next 1 MiB chunk is read while the carver works on the current one**
   (`ScanSession.sweep`, used by the sweep and the carve backfill). The drive used to sit idle
   while each chunk was carved. Now the read time and the carving time overlap. Only one read
   is in flight at a time and the reads stay sequential. Each read still waits at the pause gate
   first, so no read starts while the scan is paused.
3. **The NTFS `$Bitmap` is read once** (`NTFSVolume.loadWholeBitmap`). Checking whether a
   deleted file's clusters are still free used to read a 4 KiB bitmap page per lookup. On a
   long-used drive that meant one small random read, and so one seek on a hard drive, for
   nearly every deleted MFT record. The whole bitmap is now read in one sequential pass on the
   first check: about 10 MB for a 320 GB volume. Bitmaps larger than 64 MiB, or ones that can't
   be read whole, fall back to paging as before.
4. **Less memory per NTFS file** (`NTFSVolume.usedPart`). Every found file kept its full 1 KiB
   MFT record. Non-resident files now keep only the bytes in use, which still includes every
   attribute. Resident files keep the whole record, because a saved scan locates their data
   inside it. The copy is a real copy: a `Data` slice of the record would have kept the 1 KiB
   buffer alive.
5. **Recovery flushes the drive once per batch, not once per file** (`RecoveryEngine`, and
   re-copied into the CLI). Each file is written under its `.partial` name and `fsync`ed, then
   one `F_FULLFSYNC` makes the whole batch durable (at most 32 files or 64 MiB), and only then
   is each file renamed to its final name, in order. fcntl(2) documents this two-phase pattern:
   data that was `fsync`ed on the device before an `F_FULLFSYNC` is persisted when that call
   returns. So a final name still never points to bytes that could be lost. Every other rule is
   unchanged: `O_EXCL` partial files, no overwriting, the folder identity checks and the
   destination checks. A failed flush publishes nothing from its batch. A cancel still keeps
   every file that was finished. When a file needs a new folder next to files that are still
   waiting to be published, those files are published first, so every name (`name (2).ext`
   included) comes out exactly as it did before.
6. **The remaining-time estimate follows the recent rate.** It uses the bytes read over the
   last 90 s of active scanning, once that much time has passed. Before, it used the average
   since the start. A hard drive reads its inner tracks at about half the speed of its outer
   ones, so the average kept promising too little remaining time near the end.

The tests are in `NTFSVolumeTests` (`scatteredDeletedFilesReadTheBitmapOnce`,
`bitmapOverTheCacheLimitIsPaged`, and the updated `rawRecord` check), `SweepReadAheadTests`,
`ScanEventBatchingTests` and `RecoveryCoordinatorTests`
(`filesAreFlushedOncePerBatchBeforeAnyOfThemIsPublished`, `aFailedBatchFlushPublishesNoneOfThatBatch`).

## What was checked and is fine

- **Carving memory on a 320 GB span.** The carver keeps only byte ranges: the merged runs
  claimed by files found through metadata (a few MB for 500,000 files), at most 64 open carves,
  and the names already used. File bodies are never buffered. A drive with more than 250,000
  carvable files stops carving at that cap and says so.
- **Checkpoints** are 236 bytes of JSON: offsets and sizes only, written at most once a second.
- **The results browser** filters and sorts off the main thread, so a 500,000-row sort takes
  under a second without blocking the window.

## Remaining risks

- **The progress view's file list.** `ScanProgressView` shows `List(model.files)`. It now
  redraws only about 4 times a second, but each redraw still diffs every row: about 13–18 ms at
  500,000 rows in the stand-in, and likely more in real SwiftUI. Showing only the most recent
  few hundred files there would remove this. That is a one-line change in a file another change
  was editing during this pass, so it was left alone.
- **JPEG-heavy free space is limited by the CPU.** On this Mac the carver decodes JPEG data at
  about 150 MB/s on one core. A slower Mac may decode at 80–100 MB/s. With the read-ahead,
  this only matters on a USB 3 drive whose free space is full of old photos. There, carving
  sets the pace, not the drive.
- **Resuming re-reads everything before the checkpoint.** Carved files aren't saved in the
  checkpoint, so a resumed scan carves again every byte before the point where it resumed. On
  this drive, resuming at 90% costs almost a full scan.
- **The real USB read path wasn't measured.** Reading a real drive goes through the privileged
  read-only helper and `/dev/rdisk`, in synchronous 1 MiB reads. The read-ahead keeps the drive
  busy between reads, but there is no deeper queue. No real drive was touched for this page.
- **Recovering everything to a USB hard drive.** The flush cost is now per batch, but writing
  144 GB to a hard drive still takes about 25–50 minutes at its write speed. That time adds to
  reading the same data from the source.
- **Memory with 500,000 files.** The app holds about 1.4 KB per file for the scan and about
  another 0.5 KB per file for the results browser, so roughly 1 GB at 500,000 files. That is
  fine on 8 GB Macs or more. A drive with several million files would need several GB.

## Expected time for the owner's drive

A scan reads every byte of both NTFS partitions, about 320 GB. The MFT of a few hundred
thousand files is a few hundred MB and is read twice, which is negligible. Neither the CPU nor
memory sets the pace: the drive's sustained read speed does. A 320 GB 2.5" drive reads at about
100 MB/s on its outer tracks and 50 MB/s on its inner ones.

| Connection | Typical sustained read | Scan time |
|---|---|---|
| USB 3 (5 Gb/s port and enclosure) | 60–100 MB/s | about 55–90 minutes |
| USB 2 | 25–35 MB/s | about 2.5–3.5 hours |

The estimate assumes the drive reads without errors. Bad sectors make a drive retry, and each
retry can take seconds, so a failing drive can take far longer than this. The "Remaining" time
in the app settles after the first one and a half minutes of scanning and then follows the
drive's current speed.
