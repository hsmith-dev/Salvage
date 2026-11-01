# Distribution: Mac App Store or direct download

**Verdict: Salvage can't ship on the Mac App Store in its current form, and a store version would
lose the feature that makes it useful: reading USB drives and SD cards.** Ship it as a Developer
ID-signed, notarized DMG on GitHub Releases, as now (AD-10, [RELEASING.md](RELEASING.md)).

Written November 2026 from the [App Store Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
as published then. Points marked *(unverified)* come from general knowledge or forum posts, not
from Apple documentation or a test; check them before relying on them.

## How Salvage reads a drive today

- The app is **not sandboxed** (no `.entitlements` file, no `com.apple.security.app-sandbox`).
- It unmounts the chosen drive and opens `/dev/rdiskN` read-only. Raw device nodes are owned by
  root, so the open usually fails with `EACCES`/`EPERM` for a normal user.
- It then asks **SalvageHelper**, a launchd daemon that runs as **root**, registered with
  `SMAppService.daemon(plistName:)` from `Contents/Library/LaunchDaemons/` and approved by the
  user in Login Items (AD-13). The helper opens the disk read-only and passes the descriptor back
  over XPC.
- A password-prompt fallback through `/usr/libexec/authopen` (`AuthopenClient`, in progress when
  this was written) uses a setuid-root system tool that asks for an administrator password and
  hands back a descriptor.
- **Check for Updates…** (`Salvage/Updates/UpdateChecker.swift`) sends one GET to GitHub's
  "latest release" API when the user picks it, and links to the release page. It never downloads
  or installs anything.

## What the Mac App Store rules say

Guideline **2.4.5** applies to Mac App Store apps only (not to notarized direct downloads):

| Rule (2.4.5) | Salvage today | Conflict |
| --- | --- | --- |
| (i) "They must be appropriately sandboxed" | Not sandboxed | **Yes.** The sandbox has no entitlement for raw block devices. |
| (ii) "self-contained, single app installation bundles and cannot install code or resources in shared locations" | The helper stays inside the bundle (SMAppService doesn't copy it out) | Probably not by itself, but see (iii) and (v). |
| (iii) "may not … spawn processes that continue to run without consent after a user has quit the app" | Helper idles out about a minute after the app quits, and is approved by the user | Grey area; moot given (v). |
| (v) "may not request escalation to root privileges or use setuid attributes" | Root launchd daemon; `authopen` (setuid root, admin password prompt) | **Yes.** Both paths are escalation to root. |
| (vii) "must use the Mac App Store to distribute updates; other update mechanisms are not allowed" | Manual Check for Updates against GitHub | **Yes**, for a store build. It would have to be compiled out. |

Guideline **2.5.2** also requires apps to "be self-contained in their bundles, and may not read
or write data outside the designated container area", which is the sandbox again.

### App Sandbox and raw disk access

- A sandboxed process can't `open()` `/dev/rdisk*` or `/dev/disk*`. The sandbox has no entitlement
  that grants block-device access, and a user-selected-file entitlement covers files picked in an
  open panel, not device nodes. Apple DTS confirms that a sandboxed app gets `EPERM` on a physical
  disk where the same code works unsandboxed, and that granting Full Disk Access doesn't bypass
  the sandbox ([forum 705915](https://developer.apple.com/forums/thread/705915),
  [forum 807142](https://developer.apple.com/forums/thread/807142)).
- Child processes inherit the app's sandbox, so spawning `authopen` from a sandboxed app doesn't
  escape it. Whether the setuid bit is even honoured from inside the sandbox is *(unverified)*;
  either way it is 2.4.5(v) escalation.
- A sandboxed app can register a **login item** with SMAppService, but a **root launchd daemon**
  is privilege escalation under 2.4.5(v). Apple doesn't allow it on the store *(Apple's docs
  don't say outright that sandboxed apps can't call `SMAppService.daemon`; the review rule decides
  it)*.
- Even outside the sandbox, a root daemon's access can be limited by TCC for removable media
  ([forum 802650](https://developer.apple.com/forums/thread/802650)). That is already an open
  item in the README's "Not yet verified" list and doesn't affect this decision.

### What a store version could do

Only what a sandboxed app can open: disk image files the user picks in an open panel (`.dmg`,
`.img`, `.iso`). That is a narrow forensic tool, not "recover files from my SD card", and
directing users to make an image first needs `sudo dd` or a separate unsandboxed tool.

## How competitors distribute

| Product | Distribution | Notes |
| --- | --- | --- |
| **Disk Drill** (CleverFiles) | Direct download (main product), plus a separate Mac App Store edition | CleverFiles says the store edition is sandboxed and so lacks features that need deeper access to storage and devices, lists missing features (damaged-device reading, bootable recovery drives, iOS/Android recovery, S.M.A.R.T.), and recommends the direct version ([CleverFiles](https://www.cleverfiles.com/help/disk-drill-app-store-vs-site.html)). It has suggested installing the direct edition to give the store edition the access it lacks. |
| **Stellar Data Recovery**, **EaseUS Data Recovery Wizard**, **Wondershare Recoverit**, **R-Studio**, **Data Rescue** | Direct download from the vendor | *(unverified, general knowledge)*. Typically ask for Full Disk Access and/or an administrator password or helper. |
| **PhotoRec / TestDisk** | Open source; direct download or Homebrew | Run from the terminal with `sudo`. |

So the pattern is a notarized direct download; the one store presence (Disk Drill) is a reduced
companion edition that points users back to the direct download.

## Recommendation

1. **Ship Salvage 1.0 as a Developer ID-signed, notarized DMG on GitHub Releases** (the existing
   `release.yml`, or `scripts/release-local.sh` on the maintainer's Mac). Notarization still gives
   users the Gatekeeper "from an identified developer, checked by Apple for malicious software"
   assurance, and nothing in the current design breaks it.
2. **Keep the manual Check for Updates.** It is allowed for direct distribution; 2.4.5(vii) binds
   only store apps.
3. **Don't build a Mac App Store edition for 1.0.** A sandboxed edition could read only image files,
   would need a separate target with the helper, `authopen` and the update check compiled out, and
   would mainly create support load from users who expect it to read their SD card. Revisit only if
   there is demand for an image-only analyzer.
4. The privacy manifest (`Salvage/PrivacyInfo.xcprivacy`) is required only for App Store
   submissions. It is included anyway because it documents the required-reason APIs honestly and
   costs nothing.
