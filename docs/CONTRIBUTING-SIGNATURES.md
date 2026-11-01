# Contributing a file signature

Salvage reconstructs ("carves") files from raw bytes using declarative signatures (Architecture
AD-6). Each signature is one JSON file in
[`SalvageCore/Sources/SalvageCore/Carving/Signatures/`](../SalvageCore/Sources/SalvageCore/Carving/Signatures/).
For most formats, adding one means writing that JSON file. You don't need to change any Swift.

The decoder and the authoritative rules are in
[`SignatureLibrary.swift`](../SalvageCore/Sources/SalvageCore/Carving/SignatureLibrary.swift). The
engine that runs them is
[`CarvingEngine.swift`](../SalvageCore/Sources/SalvageCore/Carving/CarvingEngine.swift).

## How the engine uses a signature

- The sweep reads every volume Salvage scans, in order. The carver looks for a signature's header
  at **512-byte-aligned** device offsets, skipping byte ranges that belong to files the
  filesystem already lists.
- On a match it finds the file's end using the first rule that applies, in this order: `sizeField`,
  then `segments`, then `footer`, then `structure`. With none of these, the carve runs until
  `maxBytes`, the next header, a claimed run or the end of the volume, and is **partial**.
- A file whose end is confirmed is complete, with confidence **Medium**. A carve cut short, or one
  whose size claim exceeds `trustedMaxBytes`, is partial with confidence **Low**.
- Every carved file is one contiguous run of bytes.
- The file is named `<id>-<start offset as 12 hex digits>.<extension>` and listed under
  `/Reconstructed/<Category>/`, for example `/Reconstructed/Pictures/jpeg-000000002000.jpg`.

## Schema (version 1)

Hex strings are case-insensitive, may contain spaces between bytes, and may use `?` as a
**nibble** wildcard. For example, `"52494646????????57415645"` is `RIFF` + any 4 bytes + `WAVE`.
**Unknown keys are ignored, never rejected**, so a `notes` field for human readers is fine. A key
set to `null` counts as absent.

### Required

| Field | Type | Rule |
| --- | --- | --- |
| `schemaVersion` | integer | Must be `1`. |
| `id` | string | 1–32 ASCII letters, digits, `-` or `_`. Used in carved file names. Two files may share an id: `mp3-frame.json` and `mp3-id3.json` are both `mp3`. |
| `extension` | string | Same character rule as `id`. The carved file's extension. |
| `category` | string | One of `pictures`, `videos`, `audio`, `documents`, `archives`, `other`. |
| `header` | hex | Non-empty. |

### Optional: matching

| Field | Type | Meaning |
| --- | --- | --- |
| `alternateHeaders` | array of hex | Other headers for the same format. |
| `headerOffset` | integer ≥ 0 | Where the header sits relative to the file start (ISO-BMFF `ftyp` is at 4). Default 0. |
| `validate` | string | A built-in structural check before a header counts. Only `"mpegFrames"`, which needs two consecutive valid MPEG audio frame headers. |
| `embeds` | array of ids | Signature ids whose headers may legitimately appear inside this format, such as a JPEG thumbnail in a JPEG or cover art in an MP4. They don't end the carve. |
| `cutsOthers` | boolean | Default `true`. Set to `false` for a weak header (MP3 frame sync, gzip) that should never end another carve that still has an end rule to find. |

### Optional: where the file ends

| Field | Type | Meaning |
| --- | --- | --- |
| `sizeField` | object or non-empty array of objects | Length fields read relative to the header start. The file size is the sum of `value * scale + adjust` over them. Used by RIFF, 7z and SQLite. |
| `segments` | object | A chained walk over self-describing records (JPEG markers, ISO-BMFF boxes). Can't be combined with `sizeField`. |
| `footer` | hex | A byte pattern searched after the header. |
| `footerMode` | `"first"` or `"last"` | Which footer occurrence ends the file. Default `first`. PDF uses `last`. |
| `footerLength` | integer | Bytes the footer record spans. At least the footer's length, which is also the default. |
| `footerSizeField` | size field | Extra footer length read from the footer record (a ZIP end-of-central-directory comment). |
| `footerOffsetCheck` | non-empty array of size fields | Fields read from the footer whose sum must equal the footer's offset from the file start. A footer that fails belongs to a nested file and is skipped (ZIP). |
| `structure` | string | A format walker built into the engine: `"gif"`, `"mp3"`, `"ole2"` or `"gzip"`. Can't be combined with `sizeField`, `segments` or `footer`. |
| `entropy` | string | An extra content check run on every carve of this type: `"jpegBaseline"` decodes the JPEG's Huffman-coded image data and reports the file as partial if decoding fails before its end marker. Only valid on JPEG signatures. |

`footerLength`, `footerMode`, `footerSizeField` and `footerOffsetCheck` all need a `footer`.

### Optional: limits

| Field | Type | Meaning |
| --- | --- | --- |
| `maxBytes` | integer, 1 to 64 GiB (68719476736) | The longest carve. The engine default is 256 MiB. |
| `trustedMaxBytes` | integer, 1 to 64 GiB | The largest size a size field or record walk may claim and still count as confirmed. Larger claims usually mean a fragmented file or garbage, so those carves are partial. The engine default is 64 MiB. |

### Size field object

| Field | Type | Meaning |
| --- | --- | --- |
| `offset` | integer ≥ 0 | Relative to the record (or header) start. |
| `width` | integer 1–8 | Bytes. |
| `endian` | `"little"` or `"big"` | Default `little`. |
| `adjust` | integer | Added to the value. Default 0. |
| `scale` | object | Optional multiplier read from another field: `offset`, `width` (1–8), `endian`, and an optional `oneMeans` (SQLite stores page size 65536 as 1). |

### `segments` object

| Field | Type | Meaning |
| --- | --- | --- |
| `start` | integer ≥ 0 | Where the first record starts. Default 0. |
| `size` | size field | **Required.** The record's total length. |
| `minimum` | integer ≥ 1 | The smallest acceptable record. A smaller one ends the walk. Default 1. |
| `typeOffset`, `typeLength` | integers ≥ 0 | Where the record type bytes are. |
| `typeMatch` | hex | The type bytes must match this. |
| `typePrintable` | boolean | The type bytes must be printable ASCII (ISO-BMFF box types). Needs `typeLength`. |
| `largeSize` | object | `ifValue`, `offset`, `width`: when the size field holds `ifValue`, the real size is this wider field (ISO-BMFF `largesize`). |
| `stopAt` | array of hex | Record types that hand over to the `footer` search (JPEG start-of-scan `FFDA`). |
| `fillByte` | one hex byte | A padding byte skipped before a record (JPEG `FF` fill). |
| `zeroSizeToEnd` | boolean | A record whose size is 0 runs to the end of the file. The carve then has no confirmed end and is partial. |

The walk ends at the first record that fails validation, which is where the file ends, or at a
`stopAt` type.

### Reach limit

No rule may read more than **64 KiB** (65536 bytes) past a candidate position. That covers the
header, size fields, record headers, footer records and validators together. A signature that
exceeds it is skipped with the reason "rules read N bytes past a match; the cap is 65536".

## Example

`png.json`, the simplest kind, with a header and a footer:

```json
{
  "schemaVersion": 1,
  "id": "png",
  "extension": "png",
  "category": "pictures",
  "header": "89504E470D0A1A0A",
  "footer": "49454E44AE426082",
  "maxBytes": 67108864
}
```

`wav.json`, with a size field and a wildcard header:

```json
{
  "schemaVersion": 1,
  "id": "wav",
  "extension": "wav",
  "category": "audio",
  "header": "52494646????????57415645",
  "sizeField": { "offset": 4, "width": 4, "endian": "little", "adjust": 8 },
  "maxBytes": 4294967304,
  "trustedMaxBytes": 67108864
}
```

For record walks, see `jpeg.json` (markers up to start-of-scan, then a footer) and `mp4.json`
(ISO-BMFF boxes). For a footer with an offset check, see `zip.json`.

## When a file fails to load

A file that fails validation is **skipped, not fatal**. The other signatures still load. The skipped
file's name and reason are written to the system log (`SalvageCore: skipped carving signature …`).
The scan's **About this scan** section then says "Some file-type definitions couldn't be loaded
(…), so files of those types weren't reconstructed."

## Checklist and how to test

1. **Pick an extension that lands in your category.** A bundled-library test requires
   `FileCategory.classify(fileName: "x.<extension>")` to equal the signature's `category`. The
   extension table is `byExtension` in
   [`FileCategory.swift`](../SalvageCore/Sources/SalvageCore/Entities/FileCategory.swift). An
   extension that isn't listed classifies as `other`.
2. **Add the JSON file** to `Carving/Signatures/`. The directory is copied as a SwiftPM resource
   (`.copy("Carving/Signatures")` in `SalvageCore/Package.swift`), so no project regeneration is
   needed.
3. **Update `bundledSignaturesAllLoadAndMatchTheirCategories`** in
   [`SignatureLibraryTests.swift`](../SalvageCore/Tests/SalvageCoreTests/SignatureLibraryTests.swift).
   It pins the signature count (`== 19` today, in this test and in
   `missingResourceBundleGivesAnEmptyLibraryWithAReason`) and the list of ids. It also checks that
   nothing was skipped, that every reach is within the cap, and which signatures lack an end rule
   (only `rar5` today).
4. **Add a carving test** in
   [`CarvingTests.swift`](../SalvageCore/Tests/SalvageCoreTests/CarvingTests.swift). The file's
   helpers build a synthetic device and stream it through a fresh carver:

   ```swift
   @Test func myFormatIsCarvedExactly() async throws {
       let sample = Data(/* a small, valid file of your format */)
       let files = try await carve(device(size: 64 * 1024, [(8192, sample)]))
       let file = try #require(files.first)
       #expect(file.bytes == 8192..<8192 + sample.count)   // exact end found
       #expect(!file.isPartial)
       #expect(file.recoveryConfidence == .medium)
   }
   ```

   Place samples at 512-byte-aligned offsets, because headers are only looked for there. To test a
   signature in isolation, pass `library: try library(json)` to `carve`. Worth covering: a truncated
   file (partial, Low), a file followed by unrelated bytes, and a header-like byte run that must
   not match.
5. **Run the tests:**

   ```sh
   swift test --package-path SalvageCore --filter SignatureLibraryTests
   swift test --package-path SalvageCore --filter CarvingTests
   swift test --package-path SalvageCore
   ```

If a format can't be described by these rules, the engine needs a new `structure` walker, like
`MP3Walker.swift`, `OLE2Walker.swift` or `GzipWalker.swift` in `Carving/`. That is a code change,
which AD-6 discourages, so open an issue first.
