# Releasing Salvage

A release is a pushed `vX.Y.Z` tag. `.github/workflows/release.yml` (AD-10) builds, signs and
notarizes the app, packages it in a signed, notarized and stapled disk image, and publishes
`Salvage-X.Y.Z.dmg` and `SHA256SUMS` to GitHub Releases. If anything fails, nothing is published.

## 1. Secrets to add (once)

Add these in the repository's **Settings → Secrets and variables → Actions → Repository secrets**.
The names are fixed: `scripts/check-release-secrets.sh` names any that are missing and stops the
workflow before it builds anything.

| Secret | Value |
| --- | --- |
| `DEVELOPER_ID_APPLICATION_CERT_P12` | The **Developer ID Application** certificate and its private key, exported from Keychain Access as `.p12`, then base64-encoded: `base64 -i DeveloperID.p12 \| pbcopy` |
| `DEVELOPER_ID_CERT_PASSWORD` | The password you set when exporting that `.p12` |
| `NOTARIZATION_API_KEY` | An App Store Connect API key (Users and Access → Integrations → App Store Connect API, role Developer), packed as `<KEY_ID>:<ISSUER_ID>:<base64 of the .p8 file>`. Build it with `printf '%s:%s:%s' KEY_ID ISSUER_ID "$(base64 -i AuthKey_KEY_ID.p8)" \| pbcopy`. Line breaks in the base64 part are tolerated. |
| `DEVELOPMENT_TEAM` | The 10-character Apple Developer Team ID of HSmithDev LLC (Membership details in the developer account) |

`GITHUB_TOKEN` is provided by Actions; the workflow has `contents: write` to create the release.

## 2. Tagging a release

1. Make sure `main` is green in CI.
2. Pick the version `X.Y.Z`. The workflow sets the app's `MARKETING_VERSION` from the tag, and
   `package-release.sh` refuses to package if the built app's `CFBundleShortVersionString` differs
   from it.
3. Tag the commit and push the tag:

   ```sh
   git tag -a v1.2.0 -m "Salvage 1.2.0"
   git push origin v1.2.0
   ```

4. Watch the **Release** workflow in the Actions tab. Re-running a failed run, or re-pushing the tag,
   re-uploads the assets to the existing release (`--clobber`).

## 3. What the workflow does

In order, each step failing the run:

1. Checks out the tag and selects the pinned Xcode (same as CI).
2. **Verifies the four secrets are present** (`scripts/check-release-secrets.sh`).
3. Imports the Developer ID certificate into a temporary keychain (deleted at the end, always).
4. Builds `Salvage.app` in Release, signed with Developer ID, hardened runtime and a secure
   timestamp, with `MARKETING_VERSION` from the tag.
5. **Verifies the code signature:** `codesign --verify --deep --strict` on the app; the nested
   `SalvageHelper` must be signed as `dev.hsmith.Salvage.Helper` by the same Team ID, with hardened
   runtime and a timestamp; the helper's launchd plist must lint.
6. **Verifies the helper's SpawnConstraint team** matches the signing team
   (`scripts/check-helper-signing-team.sh`).
7. Notarizes the app (`xcrun notarytool submit --wait`) and staples it.
8. **Packages the disk image** with `scripts/package-release.sh --release`:
   - re-checks the bundle layout (helper at `Contents/MacOS/SalvageHelper`, its plist in
     `Contents/Library/LaunchDaemons/` with `BundleProgram` pointing at it), that the app is signed
     by `DEVELOPMENT_TEAM` and stapled, and that its version equals the tag;
   - builds a compressed (UDZO, HFS+) DMG holding `Salvage.app` and an `Applications` symlink,
     volume name `Salvage X.Y.Z`;
   - signs the DMG with Developer ID, checks its Team ID, notarizes it, staples and validates the
     ticket;
   - writes `Salvage-X.Y.Z.dmg` and `SHA256SUMS`.
9. **Verifies the DMG:** the checksum, the signature, the stapled ticket, and Gatekeeper
   (`spctl --assess --type open --context context:primary-signature`).
10. Publishes the GitHub Release with generated notes and the two assets.

### Trying the packaging locally

`--dry-run` runs every step that needs no credentials and prints the signing and notarization
commands instead of running them. It never signs or contacts Apple:

```sh
xcodebuild -project Salvage.xcodeproj -scheme Salvage -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath /tmp/salvage-dd \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build
./scripts/package-release.sh --dry-run /tmp/salvage-dd/Build/Products/Debug/Salvage.app 1.2.0 /tmp/salvage-out
```

The self-test, `./scripts/test-package-release.sh [path/to/Salvage.app]`, checks the fail-closed
cases, packages an unsigned Debug build with `--dry-run`, mounts the DMG read-only in a temp dir,
checks the volume name, the contents and the checksum, and detaches. Without an app path it builds
one into a temp folder first.

`package-release.sh` exit codes: `0` success, `1` a check or tool failed, `2` usage error. It never
overwrites an existing DMG or `SHA256SUMS` in the output folder.

## 4. Releasing from your own Mac

`scripts/release-local.sh` does what the workflow does, on your Mac, with your own certificate and
a notarytool keychain profile instead of CI secrets. It builds Release with your team, signs the app
and the helper with Developer ID and the hardened runtime, verifies them (`codesign --verify --deep
--strict` and `scripts/check-helper-signing-team.sh`), notarizes and staples the app, packages it
with `package-release.sh --release --notary-profile`, which signs, notarizes and staples the DMG,
and finishes with `spctl -a -vv` on the app and the DMG. The output is
`build/release/X.Y.Z/Salvage-X.Y.Z.dmg` plus `SHA256SUMS` (`build/` is git-ignored).

### One-time setup

1. **Find your Team ID.** In Xcode, open **Settings → Accounts**, select your Apple ID, and look at
   the team list: the Team ID is the 10-character code shown for the team (also under
   **developer.apple.com → Account → Membership details**). Don't write it into any file in the
   repository. Pass it per run, or export it in your shell profile:

   ```sh
   export SALVAGE_TEAM_ID=XXXXXXXXXX   # your 10-character Team ID
   ```

2. **Get a Developer ID Application certificate.** Only the Account Holder of the developer team
   can create one. In Xcode, **Settings → Accounts → (team) → Manage Certificates… → + →
   Developer ID Application**. (Or create it at **developer.apple.com → Certificates, IDs &
   Profiles → Certificates → +**, upload a CSR made in Keychain Access, and double-click the
   downloaded `.cer`.) Check that it is installed with its private key:

   ```sh
   security find-identity -v -p codesigning | grep "Developer ID Application"
   ```

3. **Store notarization credentials in the keychain** under a profile name (the script's default is
   `salvage-notary`). Either an app-specific password for your Apple ID (made at
   [account.apple.com](https://account.apple.com) → Sign-In and Security → App-Specific Passwords):

   ```sh
   xcrun notarytool store-credentials salvage-notary \
     --apple-id you@example.com --team-id XXXXXXXXXX
   # prompts for the app-specific password
   ```

   or an App Store Connect API key (the same `.p8` the workflow uses):

   ```sh
   xcrun notarytool store-credentials salvage-notary \
     --key AuthKey_KEYID.p8 --key-id KEYID --issuer ISSUER-UUID
   ```

   The credentials stay in your login keychain; nothing is written to the repository.

### Each release

```sh
git switch main && git pull           # a clean, committed tree; the script refuses a dirty one
./scripts/release-local.sh --dry-run  # checks team, certificate, profile, version, output folder
./scripts/release-local.sh            # builds, signs, notarizes (a few minutes), packages
```

The version is `MARKETING_VERSION` in `project.yml` (the CLI's `SalvageCLI.version` must match; a
test checks). Options: `--team ID` (else `$SALVAGE_TEAM_ID`, else `$DEVELOPMENT_TEAM`),
`--profile NAME` (else `$SALVAGE_NOTARY_PROFILE`, else `salvage-notary`), `--out DIR`,
`--allow-dirty`. Every missing prerequisite is named before anything is built, and any failure
stops the run without leaving a DMG. If Apple rejects a submission, the script prints the
`xcrun notarytool log <id> --keychain-profile <profile>` command that explains why. The build log is
in `build/release-work/`.

Then go through [RELEASE-CHECKLIST.md](RELEASE-CHECKLIST.md), tag the commit
(`git tag -a vX.Y.Z -m "Salvage X.Y.Z" && git push origin vX.Y.Z`) and attach the DMG and
`SHA256SUMS` to the GitHub release (`gh release create vX.Y.Z build/release/X.Y.Z/* --generate-notes`).
Pick one path per release. A pushed tag starts the release workflow: with its secrets unset it
stops at the secrets check before building or publishing anything; with them set it uploads its own
build over these assets (`--clobber`), which has a different checksum.

`./scripts/test-release-local.sh` checks the script without any certificate, team or network: it
replaces every Apple tool with a fake and covers the fail-closed preflight, `--dry-run`, a full run
and failures after preflight.

## 5. Verifying a downloaded release

Download `Salvage-X.Y.Z.dmg` and `SHA256SUMS` into the same folder, then:

```sh
# 1. The checksum must print "Salvage-X.Y.Z.dmg: OK".
shasum -a 256 -c SHA256SUMS

# 2. The disk image is signed and notarized.
spctl --assess --type open --context context:primary-signature --verbose=4 Salvage-X.Y.Z.dmg
# expect: accepted, source=Notarized Developer ID

# 3. Mount it read-only and check the app inside.
hdiutil attach -readonly -nobrowse Salvage-X.Y.Z.dmg
codesign --verify --deep --strict --verbose=2 "/Volumes/Salvage X.Y.Z/Salvage.app"
spctl --assess --type execute --verbose=4 "/Volumes/Salvage X.Y.Z/Salvage.app"
# expect: accepted, source=Notarized Developer ID
codesign -dv --verbose=4 "/Volumes/Salvage X.Y.Z/Salvage.app/Contents/MacOS/SalvageHelper" 2>&1 \
  | grep -E '^(Identifier|TeamIdentifier)='
# expect: Identifier=dev.hsmith.Salvage.Helper and the same TeamIdentifier as the app
hdiutil detach "/Volumes/Salvage X.Y.Z"
```

To install, drag `Salvage.app` onto the `Applications` link in the mounted image.

## 6. Manual signed-helper end-to-end check (after the first signed release)

The privileged helper (Story 1.12, AD-13) can't be exercised in CI: launchd only spawns it for a
Developer ID-signed app whose Team ID matches the helper's SpawnConstraint. Do this once per release
that changes the helper, signing, or `project.yml`, on a Mac you control, with a disposable USB
stick or SD card holding FAT32/exFAT test data:

1. Install the release build: copy `Salvage.app` from the DMG to `/Applications` and launch that
   copy (SMAppService daemons are most reliable from there). Only a Developer ID-signed Release
   build works; a Release build signed any other way fails closed by design ("didn't respond").
   For a Debug build, set the same Team for the `Salvage` and `SalvageHelper` targets in Xcode.
2. Check the signatures:
   - `codesign -dv --verbose=4 /Applications/Salvage.app/Contents/MacOS/SalvageHelper` shows
     `Identifier=dev.hsmith.Salvage.Helper`, the app's `TeamIdentifier`, and `flags=…runtime`.
   - `codesign --verify --deep --strict /Applications/Salvage.app` passes.
   - `plutil -extract SpawnConstraint.team-identifier raw /Applications/Salvage.app/Contents/Library/LaunchDaemons/dev.hsmith.Salvage.Helper.plist`
     prints the same Team ID.
3. Insert the test stick, select it in Salvage and start a scan. **Expected:** the scan stops with
   the approval guidance and an **Open System Settings** button, and macOS posts "Background Items
   Added".
4. Click **Open System Settings**. It opens General → Login Items & Extensions. Turn on **Salvage**
   under "Allow in the Background" and authenticate.
5. Back in Salvage, click **Retry scan**. **Expected:** the device unmounts, the scan runs and files
   are listed. Preview and recover a file to a different drive and compare it with the original.
6. Confirm launchd runs the helper: `sudo launchctl print system/dev.hsmith.Salvage.Helper`. If it
   refused the SpawnConstraint, `log show --last 10m --predicate 'subsystem == "com.apple.xpc.launchd"'`
   says so.
7. Quit Salvage and wait about a minute: the helper exits when idle, and `launchctl print` no longer
   shows a running PID.
8. Clean up if wanted: turn Salvage off in Login Items, or delete `/Applications/Salvage.app`.

The full background and the security-review notes are in
`_bmad-output/implementation-artifacts/spec-1-12-read-physical-drives-via-a-read-only-privileged-helper.md`.
