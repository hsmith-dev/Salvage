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

## 4. Verifying a downloaded release

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

## 5. Manual signed-helper end-to-end check (after the first signed release)

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
