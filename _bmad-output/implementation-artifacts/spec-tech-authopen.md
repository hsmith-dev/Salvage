---
title: 'Read Physical Drives Without Terminal: authopen Password Fallback'
type: 'tech'
created: '2026-11-01'
status: 'done'
baseline_commit: '6f0cd9a'
route: 'dispatch'
context:
  - '{project-root}/docs/ARCHITECTURE.md'
  - '{project-root}/_bmad-output/implementation-artifacts/spec-1-12-read-physical-drives-via-a-read-only-privileged-helper.md'
  - '{project-root}/_bmad-output/planning-artifacts/ux-designs/ux-DataRecoveryTool-2026-10-31/DESIGN.md'
---

## Intent

**Problem:** Physical drives' raw nodes (`/dev/rdiskN`) are `root:operator 0640`. Salvage opened
them directly, and on `EACCES`/`EPERM` went to the SMAppService helper. The helper works only in
a Developer ID–signed build that the user approved in System Settings. In every unsigned or
development build, scanning a real drive failed, and the workaround was `sudo` in Terminal.

**Approach:** Add macOS's own `/usr/libexec/authopen` as the fallback, which is what Raspberry Pi
Imager and balenaEtcher use. It shows the standard administrator-password dialog, opens the node
itself, and hands back an open descriptor over a socket with `SCM_RIGHTS`. The helper becomes an
optional "skip the password next time" path in signed builds.

## Requirements

1. **Fallback chain (AD-13)** in `openRawDevice`: direct `open(O_RDONLY)`, then the helper only
   if its status is `.enabled`, otherwise authopen. A helper safety refusal is final. Only the
   helper's "couldn't be reached" errors (approval revoked, missing, no reply) fall through to
   authopen.
2. **Invocation:** `/usr/libexec/authopen -stdoutpipe -o 0 /dev/rdiskN` through `Process`.
   Absolute path, fixed argv, no shell, and a BSD name already validated by
   `isWholeDiskBSDName`. stdout is one end of `socketpair(AF_UNIX, SOCK_STREAM)`, received with
   `recvmsg` + `SCM_RIGHTS`. Never `-w`, `-a`, `-c`, `-x`, `-m` or `-extauth`.
3. **Outcomes:** exactly one descriptor from a zero exit is accepted, and it still goes through
   `validateRawDescriptor` (O_RDONLY, expected character device). Every other descriptor is
   closed. A failed run with no descriptor (the user cancelled, or the dialog timed out) throws
   the new `ScanError.administratorPasswordNeeded`: "Salvage needs your administrator password
   to read this drive. Scanning is read-only." Cancelling the scan task, or the timeout,
   terminates authopen.
4. **Safety order unchanged:** whole-disk name check, boot-disk refusal, unmount and identity
   re-check all happen in `RawBlockReader.prepare` before `openReadOnly`, so authopen never runs
   for the startup disk or for a non-whole-disk name.
5. **App:** before the dialog, the scan screen explains: "macOS will ask for an administrator
   password so Salvage can read this drive. Salvage only reads it — it never writes to it." On
   cancel it shows the error, the explanation and **Try Again**. `HelperApprovalView` becomes the
   optional "Skip the password next time" path, shown only when the build is signed with a Team
   ID and the helper is embedded (status not `.notFound`).
6. **Every open path** (scan, saved-scan reconnect, FileVault verification, CLI) goes through
   `RawBlockReader.prepare`, so all of them get the fallback.
7. **Tests never launch authopen** or anything else that can show a password dialog.

## Implementation Notes

- **`SalvageDiskIO/Sources/SalvageDiskIO/AuthopenClient.swift`** (new):
  - `AuthopenInvocation`: the hard-coded executable path, the argv builder (nil for a non-whole
    name), and the 180 s timeout.
  - `AuthopenClient: PrivilegedOpening` maps a `DescriptorPassingResult` to a descriptor or an
    error (`descriptor(from:)`): one fd from `exited(0)` is accepted. No fd from a non-zero exit,
    a signal or a timeout throws `.administratorPasswordNeeded`. Anything else (no fd from a
    zero exit, more than one fd, an fd from a failed run, truncated rights) closes every fd and
    throws `handoffFailedError`.
  - `DescriptorPassingLauncher` is the injectable seam. `ProcessDescriptorLauncher` is the
    production one: stdin and stderr are `/dev/null`, and Foundation passes the child only fds
    0-2 (checked with lsof during development). It closes the parent's copy of the child end
    after launch, waits with `OneShotCompletion` (timeout and cancellation), and only then drains
    the socket. On timeout or cancellation it sends SIGTERM, then SIGKILL after 1 s, and waits for
    the reap off the cooperative pool before returning. Cancellation throws `CancellationError`.
    A timeout returns `.timedOut`.
  - `receivePassedDescriptors(from:)` sets the socket non-blocking and reads up to 64 messages
    until EOF or `EAGAIN`, so it never blocks. It parses `cmsghdr` by hand, because the `CMSG_*`
    macros aren't imported into Swift, using Darwin's 4-byte `__DARWIN_ALIGN32`. It marks every
    received fd close-on-exec and reports `MSG_CTRUNC`.
- **`RawBlockReader.swift`:**
  - `openRawDevice` takes `ElevatedOpeners` (helper, helper status, password opener, and a
    `willAskForPassword` hook run just before authopen).
  - `prepare(device:onAdministratorPasswordPrompt:)` is public, and the hook defaults to a no-op.
  - The `NativeRawDeviceOperations` comment now covers both privileged paths.
- **`PrivilegedOpenClient.swift`:**
  - `isUnavailability(_:)` decides which helper errors may fall through to authopen.
  - The public `Offer` (`unavailable` / `canRegister` / `awaitingApproval` / `enabled`),
    `currentOffer()` and `register()` drive the optional UI. `offer(teamID:status:)` is pure and
    tested. A build with no Team ID (ad-hoc or unsigned) is never offered the helper, because
    the helper only serves the same team.
  - The guidance text now describes skipping the password.
  - The client still registers on `.notRegistered` if asked, but `openRawDevice` asks it only
    when it is `.enabled`.
- **`ScanError.administratorPasswordNeeded`** (SalvageCore) is mirrored in the saved-scan
  `Failure` codable enum, and the round trip is tested.
- **App:**
  - `ScanRun.willAskForAdministratorPassword` sets `ScanViewModel.isAwaitingAdministratorPassword`
    while `.preparing`, then sleeps 600 ms (`passwordExplanationLead`) so the text renders before
    the dialog takes focus. The flag clears on first progress and when the run ends.
  - In `HelperApprovalView.swift`, `AdministratorPasswordExplanation` has a waiting state and a
    declined state with **Try Again** and `HelperApprovalView` underneath. `HelperApprovalView`
    loads the `Offer` in `.task` and renders nothing unless it is `canRegister` or
    `awaitingApproval`.
  - `ScanProgressView` and `ResultsDashboardView` handle the new error.
  - Saved-scan reconnect (`SavedScanBanner`) shows "Waiting for your administrator password…"
    and the explanation, and after a cancel, "Salvage needs your administrator password to read
    X. Click Reconnect to try again." `ScanViewModel.reconnect` returns the new
    `.needsAdministratorPassword`.
  - The approval-required branch (helper approval revoked mid-run) still renders its guidance
    and Open System Settings inline.
- **Callers of `RawBlockReader.prepare`** (checked with grep):
  - `ContentView.runScan` passes the hook.
  - `ContentView.verifyUnlock` gets the dialog without the in-app explanation, a rare path.
  - `ScanArchiveSource.open` (reconnect) passes the hook.
  - `ImageSource` opens disk images, which open directly, so no prompt.
  - `SalvageCLI` `CLIEnvironment.live.openDevice`: in a terminal the dialog still appears as a
    window. Cancel prints the new error and exits with the failure code.
  - Recovery and preview reuse the scan's open `SourceSession`. `RecoveryEngine` (the CLI's
    verbatim copy) is untouched.
- **Tests:**
  - `SalvageDiskIOTests/AuthopenClientTests.swift` covers:
    - argv and path pinning;
    - descriptor passing from another thread over a real socketpair;
    - EOF, never blocking, multiple fds and truncation;
    - client policy: cancel, timeout, signal, handoff failures, extra fds closed (pipe/EPIPE
      probes);
    - fallback order: explain-then-password, helper preferred, refusals final, unreachable helper
      falls through, writable and wrong-node fds refused, non-whole name never reaches the
      password path;
    - the real `ProcessDescriptorLauncher` run on `/usr/bin/false`, `/usr/bin/true`, `/bin/sh`
      and `/bin/sleep`, including timeout and cancellation killing and reaping the child;
    - the offer table.
  - The closure probes poll for up to 2 s. When another test closes a socket that still has
    rights in flight, XNU's unix-socket GC can briefly hold an in-flight file after every fd to
    it was closed, and this made a strict check flaky under parallel runs.
  - App tests: the explanation flag and Try Again (`ScanViewModelTests`), reconnect after a
    cancelled password and the banner copy (`ScanArchiveTests`).
- **Not verified:** the real dialog was never shown. These are untested on real hardware:
  - authopen's exit status on Cancel, which the code treats as any non-zero exit with no fd;
  - what happens to the SecurityAgent dialog when authopen is terminated mid-prompt;
  - whether authopen accepts `-o 0` as the explicit read-only flags on current macOS;
  - whether a descriptor authopen opens for a removable drive is then readable without Full Disk
    Access (TCC).

  A removed drive makes authopen fail too, and that is currently reported as
  `.administratorPasswordNeeded`. Try Again then surfaces `deviceChanged` from the identity
  check.
