# Updates and macOS permission continuity

Goalong has one bundle identity, `ai.goalong.localhistory`. Local builds use a stable Apple
Development identity when one is already available. The free public Community Build is ad-hoc
signed and not notarized, so its designated requirement can change with the binary and macOS may
request fresh Goalong permissions after replacement. History is not removed by an app update.
A failed source-access check can turn the corresponding Goalong source off under the existing
fail-closed policy; the person may need to enable that source again after recovering macOS access.

Community updates use the signed in-app Sparkle flow. Automatic checks run at launch and hourly
unless disabled in Settings; clicking the sidebar badge or Check for Updates opens the native
installation flow. An old build with no updater needs one initial reinstall. Source builds without
a release public key never contact the feed. Neither Sparkle Ed25519 authentication nor GitHub
provenance grants a stable Apple signing identity, so permission continuity is not guaranteed.

## Already checked in System Settings, but Goalong still refuses access

The checkbox is not the authorization result for the running process. Do not report that the
person selected the wrong app merely because the preflight is false. An old signing requirement,
a still-running process or a separate filesystem restriction can explain the discrepancy.

1. Quit Goalong completely from its application/menu-bar menu, then reopen the installed app.
   Closing the dashboard does not terminate a menu-bar app.
2. If the same permission is still refused, in System Settings → Privacy & Security → the
   affected permission, remove **only Goalong's entry** with the minus button. Use the plus button
   to add the exact installed `.app`, enable it, and quit/reopen Goalong again. Do not grant access
   to Terminal, a script interpreter or an unrelated helper as a workaround.
3. Return to Goalong and check access. Re-enable the source if the prior failed check turned it
   off. If access remains refused, inspect the running build's identity and the relevant source
   error before giving further advice; do not repeat the same toggle instructions indefinitely.

The native permission sheet and source access card expose an **Already enabled?** guide for
Accessibility, Input Monitoring and Full Disk Access. It expands after the same permission is
still denied following a Settings request. The guide shows the running bundle's actual path,
version and build, discloses ad-hoc/unsigned identity, selects that exact app in Finder, and offers
a confirmed normal quit. It does not reset TCC, edit its database, change signatures, remove
quarantine, kill system daemons, or grant permission. Check access remains available without
first pressing the Settings button.

## Separate authorization, health and source availability

- **Accessibility:** `AXIsProcessTrusted()` is the authorization evidence. A successful read of
  Goalong's own AX window must not turn a false preflight into an apparent grant. A failed live
  probe also must not turn a true preflight into a denial: transient capture health is separate.
- **Input Monitoring:** `CGPreflightListenEventAccess()` reports the direct grant. Accessibility
  may permit an event-tap attempt, but is not a direct Input Monitoring grant. An explicit Input
  Monitoring request uses its own refreshed preflight, not the effective-access flag. A real
  callback remains necessary for capture-health proof.
- **Full Disk Access / Screen Time:** test the relevant Apple source locations read-only. Do not
  query the TCC database or read unrelated protected user content to infer FDA. Missing Screen
  Time data is a setup state, not evidence that another permission must be granted. Independent
  optional Apple stores need not all be readable for a usable source to exist.
- **Conversation folders:** only already-selected folders are opened, with no-follow read-only
  directory flags. Missing or moved folders are not repaired by toggling a privacy permission;
  `EPERM`/`EACCES` can require checking macOS and filesystem access.

Capture-health checks, cancellation generations and consent gates remain in force. No check
button or Settings-opening action is treated as a grant.

## Preventing recurrence for production users

Recovery UX does **not** solve ad-hoc identity changes across releases. Production permission
continuity requires moving distribution to a stable Apple code-signing identity, normally
Developer ID Application with the same team and bundle identifier, signing nested components
correctly and notarizing the distributed app. An Apple Development certificate is useful for
local development; it is not a substitute for Developer ID distribution.

The current Community workflows explicitly require ad-hoc signing. This recovery patch does not
silently change that trust policy or invent CI credentials. A signing migration needs the owner's
release credentials and an explicitly reviewed workflow/policy change. Even with stable signing,
revocation, device-management policy and OS changes must still be handled; do not promise that
permissions can never require attention.

## Verification

Run `swift test --filter 'PermissionRecoveryTests|PermissionStatusTests|PermissionRefreshTests|SourceActivationTests|ScreenTimeActivationAccessTests'`
and the complete macOS quality gate. Tests cover false preflight with a successful self-read,
true preflight with transient probe failure, direct input requests, stale cached grants, all
privacy-recovery states, cancellation and missing-data classification. These tests do not grant
permissions on the runner and cannot prove the affected user's TCC state.

Before declaring a release's permission continuity validated, exercise two genuine release builds
on a test macOS account: grant each required permission, verify AX reads and input callbacks,
update normally, then verify again. Also exercise revoke/regrant while running, full quit/reopen,
checked-but-denied recovery, and unavailable sources. Preserve logs of build identity and boolean
permission/health results only; no activity contents or credentials are needed.

See `UPDATE-SECURITY.md` and `BUILD-VERIFICATION.md`. Relevant Apple references:
`AXIsProcessTrusted()` API documentation, “Allow accessibility apps to access your Mac”, and
“Controlling app access to files in macOS”.
