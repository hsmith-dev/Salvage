# Release checklist

Manual checks before publishing a release. Use a disposable USB stick or SD card with known
FAT32/exFAT test files, and a second drive to recover to. Details for steps 2–4 are in
[RELEASING.md §6](RELEASING.md#6-manual-signed-helper-end-to-end-check-after-the-first-signed-release).

Version `X.Y.Z`: ______  Commit: ______  Date: ______

## Build

- [ ] `main` is green in CI, and `MARKETING_VERSION` in `project.yml` and `SalvageCLI.version` are `X.Y.Z`.
- [ ] `./scripts/release-local.sh --dry-run` reports every prerequisite in place.
- [ ] `./scripts/release-local.sh` finishes with `done: …/Salvage-X.Y.Z.dmg` (signed, both
      notarizations accepted, stapled, `spctl` accepted).

## On your Mac

- [ ] Install from the DMG into `/Applications` and launch that copy. **About Salvage** shows `X.Y.Z`.
- [ ] **Helper approval:** start a scan of the USB stick. Salvage shows the approval guidance;
      **Open System Settings** goes to Login Items & Extensions; turn Salvage on; **Retry scan** works.
- [ ] **Real USB scan:** the stick unmounts, the scan finishes, and the test files are listed.
- [ ] **Recovery to another drive:** recover several files to a folder on a different drive and
      compare them with the originals (`shasum`). Choosing a folder on the source stick is blocked.
- [ ] **Password-prompt path** (the `authopen` fallback): when Salvage asks for an administrator
      password instead of using the helper, cancelling fails cleanly with a clear message, and
      entering it lets the scan run.
- [ ] Quit Salvage; within about a minute `sudo launchctl print system/dev.hsmith.Salvage.Helper`
      shows no running PID.

## On a clean Mac (or a fresh user account / VM that has never run Salvage)

- [ ] Download the DMG from where users will get it (so it carries the quarantine flag).
- [ ] `shasum -a 256 -c SHA256SUMS` prints `OK`.
- [ ] `spctl -a -vv -t open --context context:primary-signature Salvage-X.Y.Z.dmg` and, after
      copying the app out, `spctl -a -vv /Applications/Salvage.app` both say
      `source=Notarized Developer ID`.
- [ ] Opening the app from Finder shows only the normal "downloaded from the Internet" prompt,
      with no "unidentified developer" or "damaged" warning.

## Publish

- [ ] Tag and push: `git tag -a vX.Y.Z -m "Salvage X.Y.Z" && git push origin vX.Y.Z`.
- [ ] GitHub release `vX.Y.Z` has `Salvage-X.Y.Z.dmg` and `SHA256SUMS`, with notes covering
      what's new and known limitations.
- [ ] In an older build, **Check for Updates…** finds `X.Y.Z` and links to the release page.
- [ ] Update the README's "Not yet verified" section with whatever this pass confirmed.
