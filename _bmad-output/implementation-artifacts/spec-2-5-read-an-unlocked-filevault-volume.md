---
title: 'Read an Encrypted (FileVault) APFS Volume'
type: 'feature'
created: '2026-10-31'
status: 'done'
baseline_commit: 'd04d613'
route: 'dispatch'
context:
  - '{project-root}/_bmad-output/planning-artifacts/architecture/architecture-DataRecoveryTool-2026-10-30/ARCHITECTURE-SPINE.md'
  - '{project-root}/_bmad-output/implementation-artifacts/spec-2-4-unlock-and-recover-from-a-filevault-encrypted-volume.md'
  - '{project-root}/_bmad-output/implementation-artifacts/spec-2-1-2-2-apfs-parsing-and-recovery.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Story 2.4's spike found that macOS refuses user-space raw reads of an unlocked APFS volume node (EACCES). Only the container node, which holds ciphertext, is readable. So an encrypted volume's files can't be recovered. AD-3's revision lists options; the user chose option (a): decrypt in `SalvageCore` from the container's raw bytes.

**Approach:** Implement software-encrypted APFS volume decryption from Apple's public *Apple File System Reference* ("Encryption" chapters: keybags, KEK, VEK, AES-XTS) only. AD-2 applies: no GPL/LGPL code, implementation or port may be read.

1. **Keybags.** Read the container keybag (`nx_keylocker`; a `kb_locker` object, decrypted with AES-XTS using the container UUID as key material per the Reference). Find the volume's wrapped KEK entry and the volume keybag location. Read and decrypt the volume keybag (keyed by the volume UUID), then find the wrapped KEK for the user's password (`KB_TAG_VOLUME_UNLOCK_RECORDS`) or for the personal recovery key.
2. **Unwrap.** Derive a key from the credential with PBKDF2-HMAC-SHA256 using the salt and iteration count in the KEK blob. AES key-unwrap (RFC 3394) the KEK, then AES key-unwrap the VEK (`KB_TAG_VOLUME_KEY` in the container keybag) with that KEK. A failed unwrap integrity check means **wrong password** (`UnlockError.wrongPassword`), never a tool failure.
3. **Decrypt.** AES-XTS-128 with the 256-bit VEK (two 128-bit halves). The tweak is the 512-byte sector number derived from the physical block address, exactly as the Reference specifies for file extents (`crypto_id`) and for metadata blocks (the volume's own crypto id). Decrypt metadata objects and file extents on read.
4. **Wire it through:**
   - `APFSContainer` accepts an optional `credentials: [String /*volume UUID*/: VolumeCredential]`. If an encrypted volume has a credential and the unwrap succeeds, it parses the volume through a decrypting reader. Otherwise it emits `.unlockRequired` as today.
   - `ScanSession.run` gains `credentials:` (default empty) and passes it to `scanVolume`, which passes it to `APFSContainer`.
   - `VolumeCredential` is a Core type holding the secret bytes; it zeroes them on `deinit`/`zero()`.
   - File content for decrypted files can't be expressed as plain `DataRun`s, because the bytes on disk are ciphertext. Add `FileContent.encryptedRuns([DataRun], keyID: String)`. `FileContentReader` decrypts through a registered decryptor that the session provides (`FileContentReader(reader:decryptors:)`).
   - Preview and recovery (app) pass the session's decryptors through `SourceSession`.
   - **No `diskutil` is involved in reading;** `FileVaultUnlocker` is no longer needed for the read path.
5. **UI:**
   - Flip `FileVaultUnlockFeature.canReadUnlockedVolumes` to true.
   - On a correct password, re-scan the device with the credential, through the same `ScanViewModel.start` path plus credentials.
   - Wrong password shows "Wrong password." A volume type that isn't supported (hardware-encrypted T2/Apple-silicon internal volumes, which can't be decrypted off-device) shows a distinct plain message.
   - The credential lives only in memory for the scan's duration, then is zeroed.

## Boundaries & Constraints

**Always:**
- **Crypto primitives come from CommonCrypto**, which the boundary check allows: `CCKeyDerivationPBKDF`, `CCSymmetricKeyUnwrap`, `CCCryptorCreateWithMode` with `kCCModeXTS`. Wrap them behind a tiny internal protocol so a future non-Apple Core adapter can swap them. Record in AD-1's text that Core uses CommonCrypto (a system library, not a third-party dependency).
- **Credentials:** never logged, persisted, or put in errors. Zero every derived key buffer (`memset_s`).
- **Test vectors:** verify each primitive first against published vectors: RFC 3394 key unwrap, IEEE 1619 XTS-AES-128, RFC 7914 / NIST PBKDF2-HMAC-SHA256.
- **Spike on a real image.** Create an encrypted APFS volume on a disk image with `diskutil apfs addVolume <container> APFS Secret -passphrase <p>` (no sudo), write files with known hashes, delete some, and lock or detach it. Read the container node raw, decrypt, scan, and compare hashes. Record the commands and results in Implementation Notes. If decryption is infeasible in reasonable time, stop and report with what was learned.
- **Fail closed:** any keybag parse, checksum or unwrap failure means no decryption. Never parse garbage as plaintext.
- **Hardware-encrypted volumes** (no software keybag entry, or the key isn't wrapped by a user KEK) are reported as unsupported, never as a wrong password.

**Never:** No mount, no `diskutil unlockVolume` for reading, no network. Don't edit the other filesystem parsers or the carving engine. In `ScanSession.swift`, add only the `credentials` parameter and its plumbing. Another agent is adding a `notices` side channel there in parallel; keep the edits to separate lines.

## I/O & Edge-Case Matrix

| Scenario | Input | Expected |
|---|---|---|
| Real encrypted image, correct password | `diskutil apfs addVolume … -passphrase` | Files listed; content byte-identical after decryption; deleted files from older checkpoints when blocks are pending-free |
| Wrong password | — | `wrongPassword`; nothing parsed |
| Recovery key | the volume's personal recovery key | Unlocks |
| Hardware-encrypted / no user KEK | synthetic | "unsupported" message, not a wrong password |
| Corrupt keybag | crafted | Fail closed; `.unlockRequired` remains; no garbage files |

</frozen-after-approval>

## Code Map

- **New Core files:**
  - `SalvageCore/Sources/SalvageCore/Parsers/APFSCrypto.swift`: keybags, unwrap, the XTS reader, and the CommonCrypto adapter.
  - `Entities/VolumeCredential.swift`.
- **Core edits:** `APFSContainer.swift`, `VolumeScanners.swift` (credential plumbing), `ScanSession.swift` (parameter only), `ScanEvent.swift` (the `FileContent.encryptedRuns` case), `FileContentReader.swift` (decryptors).
- **App edits:** `ScanViewModel.swift` (start with credentials), `SourceSession.swift` (decryptors), `UnlockViewModel.swift`, `FileVaultUnlockSheet.swift`, `ContentView.swift` (unlock lines only), `RecoveryCoordinator.swift` / `PreviewLoader.swift` (pass decryptors only).
- **Tests:**
  - `SalvageCore/Tests/SalvageCoreTests/APFSCryptoTests.swift`: the test vectors, plus a real encrypted image created and detached in a temp dir.
  - `SalvageTests/UnlockViewModelTests.swift`.
- **Docs:** `ARCHITECTURE-SPINE.md` AD-1 and AD-3 (one sentence each recording the outcome).

## Verification

- `swift test --package-path SalvageCore`
- `swift test --package-path SalvageDiskIO`
- `./scripts/check-core-boundary.sh && ./scripts/check-no-network.sh`
- `xcodebuild -project Salvage.xcodeproj -scheme Salvage -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:SalvageTests test`
- `xcodebuild -project Salvage.xcodeproj -scheme Salvage -configuration Debug -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build`

## Implementation Notes

### Spike on a real encrypted image (2026-10-31, macOS 27.2): decryption works

No `sudo`; only images created for the spike, in the session scratch directory; nothing else was touched. Commands and results:

```
hdiutil create -size 1g -type SPARSE -fs APFS -volname SpikePlain fv25           # -> disk18 (GPT), disk18s1 (store), disk19 (container), disk19s1
hdiutil attach -nomount fv25.sparseimage
diskutil apfs addVolume disk19 APFS Secret -passphrase spike-pass-123           # -> disk19s2, FileVault: Yes (Unlocked), mounted
mkdir docs; printf ... > docs/secret-note.txt; head -c 65536 /dev/urandom > docs/blob.bin;
head -c 3000000 /dev/urandom > docs/big.bin; head -c 200000 /dev/urandom > docs/doomed.bin; sync; shasum -a 256 docs/*
  blob.bin d66f3313…b7fd   big.bin 2bf2929b…7553
rm docs/doomed.bin; sync; diskutil apfs lockVolume disk19s2                     # "APFS Volume is now unmounted and locked"
```

Then a throwaway Swift probe (CommonCrypto only) read `/dev/rdisk19` (the container node, user-readable) with aligned `pread`s:

- `nx_keylocker` (superblock offset 0x510) = block 829, 1 block. XTS-AES-128 with the container UUID as both key halves and data unit = block x 8 (512-byte sectors) gave an object of type `'keys'`, `kl_version` 2, 2 entries for the volume UUID: tag 3 (the volume keybag's `prange_t`: block 827, 1) and tag 2 (the wrapped VEK, a 124-byte DER blob).
- The volume keybag, decrypted the same way with the volume UUID, is type `'recs'` with one tag-3 unlock record (UUID = the volume UUID for a `diskutil addVolume -passphrase` volume). DER layout of both blobs: `SEQUENCE { [0] 0, [1] 32-byte HMAC, [2] 8-byte salt, [3] { [0] 0, [1] UUID, [2] 8-byte flags, [3] 40-byte wrapped key, [4] iterations (KEK only: 0x0186a0 = 100000), [5] 16-byte PBKDF2 salt (KEK only) } }`.
- PBKDF2-HMAC-SHA256(password, salt, 100000, 32) -> RFC 3394 unwrap of the KEK: status 0 with `spike-pass-123`, -4304 (integrity failure) with a wrong password. KEK -> unwrap of the VEK: status 0, 32 bytes.
- The volume superblock (APSB, `fs_flags` = 0x8 `APFS_FS_ONEKEY`) and the volume object map are plaintext; the object-map entries carry `OMAP_VAL_ENCRYPTED` (flag 4) and the blocks they name (raw type `63690a14`, garbage) decrypt with the VEK halves and data unit = block x 8 to a valid fs-tree node (`10000002`, oid 1031).
- File extents: `crypto_id` equals the physical block at write time (838, 846, 848, 864, …). Decrypting each extent with data unit = `crypto_id` x 8 + sector index gave `blob.bin` and `big.bin` with exactly the SHA-256 recorded above.
- `hdiutil detach disk18` afterwards; the image was deleted.

Probe of CommonCrypto's XTS: the macOS 27.2 SDK's public `CommonCryptor.h` no longer declares `kCCModeXTS` (only the `tweak` parameter's comment mentions XTS), and `CCCryptorCreateWithMode` with the undeclared raw value 8 didn't produce a cryptor (the probe trapped on its status check). So XTS is built per IEEE 1619 on CommonCrypto's public AES-ECB (`CCCryptorCreate` + `kCCOptionECBMode`), which is a deviation from the Approach's "`CCCryptorCreateWithMode` with `kCCModeXTS`"; it is verified against the IEEE 1619 vectors below before anything uses it. PBKDF2 (`CCKeyDerivationPBKDF`) and key unwrap (`CCSymmetricKeyUnwrap`) are used as specified.

Sizing note for the automated test: a container under 512 MB allows only one volume (`addVolume` fails -69493), so the test image is 64 MB raw UDIF with its default volume deleted and the encrypted one added in its place (`diskutil apfs deleteVolume diskNs1` + `addVolume`), read straight from the `.dmg` file after `hdiutil detach`.

### What was built

- **`SalvageCore/Parsers/APFSCrypto.swift`** (new):
  - `SecretBytes`: owned, `memset_s`-erased key material; every derived buffer (PBKDF2 output, KEK, VEK, key halves, XTS masks) is erased when done.
  - `APFSCryptoProvider` (internal protocol) with the `CommonCryptoProvider` adapter: PBKDF2-HMAC-SHA256, RFC 3394 unwrap (integrity failure -> nil), AES-ECB block transform.
  - `AESXTS`: XTS-AES over whole 512-byte data units, all of a call's tweaks and masks computed in bulk, locked for concurrent preview/recovery.
  - Bounds-checked DER reader, `APFSWrappedKey`, keybag parsing (`APFSKeybag.entries`: checksum, type, version, sizes and every entry bounded), and `APFSKeyUnwrapper`. The failure meanings: no unlock record accepts the credential -> `wrongPassword`. No usable software unlock record (a blob asking for more than 10,000,000 PBKDF2 iterations is malformed and never tried), no ONEKEY, no VEK entry, or a KEK that doesn't open the VEK -> `unsupported`. An unreadable or damaged keybag, or one that asks for more PBKDF2 work than an attempt may spend -> `toolFailure`. A key that unwraps but whose root tree fails its checksum or structure check -> `damaged` (review patch, below).
  - A recovery key's record (`EBC6C064-0000-11AA-AA11-00306543ECAC`) is tried first. Every record is tried with any credential. A recovery key is normalized when the credential is made (see the review patch).
  - `public enum EncryptedVolumeUnlock { static func verify(reader:volumeUUID:credential:) }`: checks a credential reading only discovery, checkpoint, keybags and the volume's root tree.
- **`Entities/VolumeCredential.swift`** (new):
  - `VolumeCredential` holds the secret in `SecretBytes`; it is zeroed on `zero()` and `deinit`, has a redacted `description`, and is never in errors or logs. It records the unwrapped key (`decryptor`) or the `failure`. Once a key is recorded the secret can be zeroed, and later scans use the recorded key; the key is still checked against the root tree.
  - `public protocol ContentDecryptor`.
- **`APFSContainer`**:
  - `credentials:` (by uppercased volume UUID) and an injectable provider. An encrypted volume with a credential is unlocked (keybags, unwrap), and its context must then build and verify through the key. If it doesn't, the credential records `.damaged` and the volume is reported through `notice` as `.volumeSkipped` (review patch). Failing closed: nothing is ever parsed from guessed plaintext.
  - Object-map entries flagged encrypted are decrypted on read: `object(at:decrypting:)`, a node cache keyed by (address, decrypted), and `APFSTree.rootIsEncrypted`.
  - Files map to `.encryptedRuns`: each run carries `firstDataUnit = crypto_id x (block size / 512)`, and runs coalesce only when the tweak continues. A placed extent with `crypto_id == 0` in an unlocked volume is unmapped.
  - Deleted-file recovery (older checkpoints, snapshots) runs for the unlocked volume with the same key; candidates carry their `keyID`.
  - `APFSContainerSuperblock` gained `nx_keylocker`.
- **`ScanEvent.swift`**: `UnlockError.unsupported`, `DataRun.firstDataUnit` (default nil), and `FileContent.encryptedRuns([DataRun], keyID:)`. `RecoveryConfidence` treats encrypted runs like runs.
- **`FileContentReader(reader:chunkSize:decryptors:)`**: `.encryptedRuns` without a decryptor is `FileContentError.locked`. Reads are widened to whole data units from the run's start, decrypted, and trimmed. A run without a data unit, or whose rounded-up ciphertext leaves the device, is rejected; a decryptor failure is `.decryptionFailed`.
- **Plumbing**: `scanVolume(credentials:)`. `ScanSession.run(…, credentials:)`: only the parameter, its doc line and the pass-through to `scanVolume`.
- **App**:
  - `FileVaultUnlockFeature.canReadUnlockedVolumes = true`.
  - `UnlockViewModel` now checks the credential with an injected `verify` (`ContentView` passes `EncryptedVolumeUnlock.verify` over the finished scan's session, or a fresh read-only `RawBlockReader` for a picker-locked device). Wrong password / wrong recovery key, unsupported ("This volume's encryption is tied to the Mac it came from…") and tool failure are distinct; the sheet stays open to retry.
  - On success the secret is zeroed at once, the sheet closes, and, once no other volume of that scan is waiting to be asked about, `rescan` starts `ScanViewModel.start(device, credentials:)` with every volume unlocked in the flow (always a fresh scan, no checkpoint offer).
  - `runScan` passes the credentials to `ScanSession`, keeps their decryptors in `SourceSession(decryptors:)` (used by `content`, hence by preview and recovery unchanged), and zeroes every secret.
  - The relock and "unlocked but unreadable" paths are gone, since nothing is unlocked in the OS any more. `FileVaultUnlocker` (SalvageDiskIO) is untouched but no longer used by the app.
  - `PreviewLoader` only maps the two new `FileContentError` cases to "unavailable".
- **Docs**: AD-1 records the CommonCrypto use and AD-3 the outcome, one sentence each.

### Tests

- `APFSCryptoTests.swift`:
  - IEEE 1619 XTS-AES-128 vectors 1, 2 and 4 (the whole 512-byte vector 4, plus decryption and multi-unit consistency); RFC 3394 §4.1 and §4.6 unwrap and a tampered blob; RFC 7914 PBKDF2-HMAC-SHA256 (c=1 and c=80000).
  - Secret erasure. Synthetic unwrapping: correct, wrong, other-user record, recovery key in any case, and the unsupported cases (no records, no salt, VEK wrapped by another key, junk blob, iteration bound). Hostile keybags and DER.
  - Encrypted content across chunk sizes, holes and tails; locked without a decryptor; tweak-aware coalescing.
  - **Real image**: a 64 MB UDIF in a private temp directory with an encrypted volume (`diskutil apfs addVolume … -passphrase`), 4 kept files (3 MB, 70 KB, a note, an empty file) and 1 deleted 100 KB file, detached before reading. It checks:
    - Without a credential: `.unlockRequired` and no files.
    - With the password: `verify` succeeds; a full `ScanSession` completes with no unlock request; every kept file is byte-identical through the decryptor and its plaintext isn't on disk; the deleted file is recovered byte-identical from the older checkpoint.
    - Wrong password: `wrongPassword`, `.unlockRequired`, no files.
    - Corrupt container keybag (patched on read): `toolFailure`, `.unlockRequired`, no files.
    - ONEKEY cleared on the superblock (checksum refreshed): `unsupported`.
    - The zeroed credential's recorded key re-scans the volume.
- `UnlockViewModelTests.swift` (rewritten): offers and flows, distinct messages and retry, pre-scan success starts the scan with the credential, a post-scan two-volume flow ends in one re-scan carrying both keys (and declining the second still re-scans the first), cancel during a check drops the late result, guidance when withheld, copy without jargon, and `SourceSession` passes its decryptors to `content`.

### Not covered / follow-ups

- **Personal recovery key on a real volume:** not tested on a real volume. Neither `diskutil apfs addVolume` nor `diskutil apfs encryptVolume` creates one without `sudo` / `fdesetup`, so the recovery-key path is covered only by the synthetic keybag test.
- **Hardware-encrypted volumes:** not tested on a real T2 or Apple-silicon internal disk; that would mean reading a real internal volume. Those volumes are reported unsupported by rule (no ONEKEY, no software record, or a VEK the KEK doesn't open, or a key that doesn't verify the root tree), never as a wrong password; the ONEKEY case is checked on the real image.
- **Flags not interpreted:** the KEK/VEK `flags` field and the blob HMAC aren't checked (the Reference doesn't define the HMAC key). Integrity rests on RFC 3394's check plus the Fletcher checksum of the decrypted root node, so a key that doesn't fit fails closed.
- **Carver and ciphertext:** `ScanSession` now claims `.encryptedRuns` as well as `.runs`, so an unlocked volume's listed files are never carved. The sweep still reads ciphertext elsewhere: the volume's unallocated space, its encrypted metadata blocks, and the whole of any volume left locked. Carving those bytes can only produce false positives, where random bytes happen to match a signature. It can never expose plaintext.
- **Possible merge conflict in `ScanSession.swift`:** the new parameter is added on its own new line, but it ends the `run(...)` signature, so a parallel edit to that same signature line may conflict mechanically.
- **Snapshot metadata tree read as plaintext:** for an encrypted volume the snapshot metadata tree is read as plaintext (best effort; if it is encrypted, snapshots are skipped and older checkpoints still apply).
- **`.fseventsd` files listed:** macOS writes `.fseventsd` logs to the encrypted volume while it is mounted, and they are listed like any file.

### Review patch (2026-10-31)

- **Damaged, not unsupported.** A key that unwraps but whose root tree fails its checksum or structure check is recorded as the new `UnlockError.damaged`. The VEK passed RFC 3394's integrity check, so it is the volume's key and the failure is damage. The sheet says "Salvage unlocked this volume but its file list is damaged, so its files can't be listed." In a scan, `APFSContainer` gets `scanVolume`'s `notice` channel (one line in `VolumeScanners.swift`) and emits `.volumeSkipped` with that reason instead of `.unlockRequired`, since asking for the password again can't help. `.unsupported` is kept for a missing software keybag entry and for hardware-bound keys. Adding the enum case meant a one-line edit to `ScanEvent.swift`.
- **PBKDF2 work bound.** A record asking for more than 10,000,000 iterations is malformed. One attempt may spend at most 10,000,000 iterations plus its costliest record's count across all records; past that it stops with `toolFailure`. `Task.checkCancellation()` runs before each record. Cancel in the sheet (`resolve()`) now cancels the check in flight, so `waitForPendingUnlock()` returns once the current derivation ends. The secret is copied once into erasable bytes, so the credential's lock isn't held through derivation.
- **Key lifetime.** `VolumeCredential.discardKeys()` erases the secret and drops the recorded decryptor. The decryptor holds no raw key bytes, only CommonCrypto key schedules that are released with it. `SourceSession.close()` drops its decryptors. `UnlockViewModel` discards the flow's keys when a new flow starts (selecting a device, including another device) and in `tearDown()`, which `ContentView.onDisappear` calls after `scan.stopForTeardown()` releases the session.
- **Recovery-key normalization** happens on the bytes in `VolumeCredential.init`, with no `String` copy. Whitespace and hyphens are stripped and letters uppercased. If 24 letters or digits remain, the key is written as six hyphenated groups of four, Apple's personal recovery key form. Otherwise the text is kept as typed, after the trim. The old lowercase-to-uppercase second try is gone, so each record costs one derivation.
- **Failure copy** follows the kind of credential that was submitted, not the current toggle.
- **Real image on a partition map.** The real-image test runs twice: with `-layout GPTSPUD`, where the container is in a GPT partition at a non-zero offset (asserted), and with `-layout NONE`, at offset 0. The test helpers take the discovered APFS extent, and the patching reader works in container-relative blocks. A mutation that made the tweak device-relative fails the GPT case only.
- Tests: Core `recoveryKeysAreNormalizedOnTheBytes`, `manyHighIterationRecordsAreRefusedWithinTheBudget`, `cancellationStopsBetweenRecords`, `discardingKeysReleasesTheRecordedDecryptor`, the extended `recoveryKeyUnlocksThroughItsRecordEvenTypedInLowercase` and `iterationCountAboveTheBoundIsNotTried`, and the damaged-tree case in the parameterized real-image test. App `wrongCredentialMessageFollowsTheSubmittedKindNotTheToggle`, `damagedVolumeHasItsOwnMessage`, `cancelCancelsTheCheckSoTheWaitingScanStartsPromptly`, `teardownDropsTheFlowsKeys` and `closingTheSessionDropsItsDecryptors`. Each behavioural fix was mutated back and its test failed.

### Verification (2026-10-31)

- `swift test --package-path SalvageCore`: `Test run with 345 tests in 25 suites passed` (one earlier full run hit a timing flake in the HFS+ real-image journal test `deletedFilesAreRecoveredFromTheJournalUnlessTheirBlocksWereReused`, which this story doesn't touch; it passed twice alone and the full rerun passed).
- `swift test --package-path SalvageDiskIO`: `Test run with 155 tests in 21 suites passed`.
- `./scripts/check-core-boundary.sh && ./scripts/check-no-network.sh`: both PASSED.
- `xcodebuild … -only-testing:SalvageTests test`: `Test run with 135 tests in 13 suites passed`, `** TEST SUCCEEDED **`.
- `xcodebuild … build`: `** BUILD SUCCEEDED **`, no warnings.

### Verification after the review patch (2026-10-31)

- `swift test --package-path SalvageCore`: `Test run with 384 tests in 29 suites passed` (the real-image test runs as 2 cases, GPTSPUD and NONE).
- `./scripts/check-core-boundary.sh && ./scripts/check-no-network.sh && ./scripts/check-xcodeproj-sync.sh`: all three PASSED.
- `xcodebuild … -only-testing:SalvageTests test`: `Test run with 149 tests in 13 suites passed`, `** TEST SUCCEEDED **`.
- `xcodebuild … build`: `** BUILD SUCCEEDED **`.
