# Privacy

This page lists exactly what Salvage reads, what it writes, and the single network request it can
make. Each item names the source file, so you can check it yourself. The in-app Trust Panel (**What
Salvage reads and writes**, `Salvage/Views/TrustPanelView.swift`) is the short version.

Salvage collects no usage data, analytics or crash reports, and there is no account.

## What Salvage reads

**The drive you select, and only that drive.**

- Before scanning, Salvage unmounts the whole drive through DiskArbitration, then opens its raw
  node (`/dev/rdiskN`) read-only (`SalvageDiskIO/Sources/SalvageDiskIO/RawBlockReader.swift`). The
  descriptor is checked to be open `O_RDONLY` and to be the expected device. A writable descriptor
  is closed and the scan is refused.
- Physical drives are opened read-only by macOS's own `/usr/libexec/authopen`, after you enter an
  administrator password in macOS's dialog (`SalvageDiskIO/Sources/SalvageDiskIO/AuthopenClient.swift`).
  Salvage never sees or stores that password. authopen is asked only for read-only access
  (`-o 0`, which is `O_RDONLY`) and hands the descriptor back over a local socket; it reads no
  drive bytes itself. In a signed release you can instead approve the optional privileged helper
  (`SalvageHelper/main.swift`) once, which does the same without a password. Disk images you
  attached yourself are opened directly by the app.
- The startup disk, and anything built on it, is refused by both the app and the helper, before
  any password is asked for. If
  Salvage can't work out which disk is the startup disk, it refuses the scan.
- All parsing happens in the app, in memory. A preview is decoded in memory and never written to
  disk.

**Information about your disks, to list them and keep you safe.** Salvage reads these but doesn't
store them:

- device descriptions from DiskArbitration and the IORegistry (names, sizes, internal or
  external, whole disk or partition);
- `diskutil info -plist` (to identify the startup disk), `diskutil apfs list -plist` (to mark
  FileVault-locked drives), and `hdiutil info -plist` (to work out which drive a disk-image
  destination really lives on). These are read-only queries
  (`SalvageDiskIO/Sources/SalvageDiskIO/BootDiskSafety.swift`, `APFSVolumeListing.swift`,
  `DestinationSafety.swift`);
- mount information (`statfs`, `getfsstat`), to confirm the drive is unmounted and to check
  recovery destinations;
- the kernel's per-boot ID (`kern.bootsessionuuid`), to tie a saved scan position to this startup
  of your Mac.

Salvage doesn't read your other drives' contents, your files, or anything else on your Mac.

## What Salvage writes

**Nothing, ever, to the drive it scans.** It is opened read-only, whether directly, through
authopen's read-only right, or by the helper, which only ever opens drives read-only. Whichever
path opened it, the app checks the descriptor is read-only before reading.

**Recovered files**, only when you click **Recover**, and only into a new folder inside the
destination you choose (`Salvage/ViewModels/RecoveryCoordinator.swift`):

- The folder is named `Salvage Recovery <drive name> <date and time>`.
- Each file is written under a temporary `<name>.<random>.partial` name, flushed to disk, then
  renamed. The original modified date is set on it when known.
- A destination on the scanned drive is blocked, and so is one whose drive can't be determined
  (`SalvageDiskIO/Sources/SalvageDiskIO/DestinationSafety.swift`). The check runs when you choose
  the folder and again just before writing.

**A drive image**, only when you choose **Image This Drive…**, and only to the file you name in
the save panel (`Salvage/ViewModels/DriveImaging.swift`,
`SalvageDiskIO/Sources/SalvageDiskIO/ImageOutputFile.swift`):

- The `.img` file holds every byte of the drive, with zeros where sectors couldn't be read. It is
  created new; an existing file is replaced only when you confirm that in the save panel.
- Next to it, `<name>.img.badblocks.json` lists the unreadable byte ranges, how much was copied
  and the image's SHA-256. It holds no file contents.
- A destination on the drive being imaged is blocked, and so is one whose drive can't be
  determined, one without enough free space, and a FAT volume for a drive over 4 GB.

**A saved scan position**, so an interrupted scan can resume
(`Salvage/ViewModels/ScanCheckpointStore.swift`):

- It is stored at `~/Library/Application Support/dev.hsmith.Salvage/ScanCheckpoints/checkpoint-<device id>.json`.
- It holds offsets, sizes and identifiers only: the drive's IORegistry ID and size, the volume
  layout, how far the scan got, the boot-session ID and the time it was saved. It holds no file
  names, paths or contents.
- It is deleted when a scan completes or is cancelled, when you choose **Start over**, and when it
  is found to be stale on load (another startup, another drive, a different size, or older than
  7 days).

**Nothing else.** A scan on its own saves only that position. Salvage keeps no history of
scans and keeps no log of files found. One log message exists: if a bundled file-type definition
fails to load, `SalvageCore` writes the definition's file name and the reason to the system log
(`SignatureLibrary.swift`). It contains no data from your drive.

**System changes you'll notice:**

- The scanned drive stays unmounted after the scan. Disconnect it and plug it back in to use it.
- macOS's administrator-password dialog appears when you scan a physical drive (unless you
  approved the helper). macOS may record the authorization in its own system log, as it does for
  any administrator prompt.
- Approving the optional helper adds Salvage under **Allow in the Background** in System Settings → General
  → Login Items. Turn it off there, or delete the app to remove the registration.

## The single network request

Salvage connects to the internet only when you choose **Check for Updates…**, in the Salvage menu
or the Trust Panel, or **Check Again** in the update window. Opening the update window doesn't
start a check. Salvage never checks on launch or on a timer. It never retries on
its own. It is disabled while a scan is running. All of it is in
`Salvage/Updates/UpdateChecker.swift`, the only file allowed to use network APIs.

The request:

- `GET https://api.github.com/repos/hsmith-dev/Salvage/releases/latest`
- Headers: `Accept: application/vnd.github+json` and `User-Agent: Salvage`. The system's
  default user agent, which names your macOS build, is replaced.
- It goes over an ephemeral session: no cookies, no cache, no stored credentials. It times out
  after 15 seconds per request and 30 seconds overall.
- It contains nothing about you, your Mac or your drives. Like any website, GitHub can see your
  internet address.

From the reply, Salvage reads only `tag_name`, to compare versions, and `html_url`, the release
page. It downloads and installs nothing. If a newer version exists, **Open Release Page** opens
that page in your web browser. A page that isn't on `https://github.com/hsmith-dev/Salvage/` is
replaced by the fixed releases page.

Two other links hand off to your web browser, not to Salvage: **View the source code on GitHub**
in the Trust Panel, and **Open Release Page**. Links inside a previewed PDF are swallowed and never
opened (`PDFLinkBlocker` in `Salvage/Views/FilePreviewView.swift`).

### How this is enforced

`scripts/check-no-network.sh` runs in CI on every push. It fails if any `.swift` file under
`Salvage/`, `SalvageCore/`, `SalvageDiskIO/`, `SalvageHelper/` or `scripts/`, other than
`UpdateChecker.swift`, mentions `URLSession`, `URLRequest`, `NSURLConnection`, `import Network`,
`NWConnection`, `NWListener`, `NWPathMonitor`, `CFSocket`, `CFStreamCreatePairWithSocket`,
`socket(`, `connect(`, `getaddrinfo`, `WKWebView` or `import WebKit`. It also fails if any
`Package.swift` declares a remote dependency. XPC, used for the local helper, isn't network access
and is allowed. `scripts/test-check-no-network.sh` plants violations to prove the checker
catches them.

To check yourself, run `./scripts/check-no-network.sh` from the repository root.

## Passwords and recovery keys

FileVault passwords and recovery keys are **never stored**: not on disk, not in the Keychain, not
in preferences, and never logged.

- The secure field's text is moved into an erasable byte buffer the moment you click **Unlock**,
  and the field is cleared in the same step (`Salvage/ViewModels/UnlockViewModel.swift`,
  `SalvageCore/Sources/SalvageCore/Entities/VolumeCredential.swift`).
- Salvage checks it by reading the volume's keybags from the drive and unwrapping the volume key
  itself (`SalvageCore/Sources/SalvageCore/Parsers/APFSCrypto.swift`). Nothing is mounted, and
  `diskutil` isn't used for this.
- The password or key bytes are erased with `memset_s` as soon as the check finishes.
- The volume key unwrapped from it stays **in memory only**, so the scan, preview and recovery can
  decrypt the volume. It is dropped when you select a drive again, when the scan's session closes,
  or when the window closes.

The code states two limits plainly. The text the secure field held while you typed is a Swift
`String`, which can be freed but not scrubbed. And macOS's secure text field may keep its own
internal copy. Neither is ever written anywhere by Salvage.
