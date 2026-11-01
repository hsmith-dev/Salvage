---
title: 'Read an Encrypted (FileVault) APFS Volume'
type: 'feature'
created: '2026-10-31'
status: 'ready-for-dev'
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
