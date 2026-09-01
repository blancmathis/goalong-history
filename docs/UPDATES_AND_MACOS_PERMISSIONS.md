# Updates and macOS permission continuity

Goalong has one bundle identity, `ai.goalong.localhistory`. Local builds use a stable Apple
Development identity when one is already available. The free public Community Build is ad-hoc
signed and not notarized, so its designated requirement can change with the binary and macOS may
request fresh Goalong permissions after replacement. The installer reports that consequence before
replacing the app; history and settings remain preserved.

The app never assumes permission from a switch alone. It verifies functional Accessibility/input
health and separately requires the corresponding Goalong capability consent. Replacing the app
does not intentionally reset history or consent data.

Updates are manual. The app embeds no updater or feed and does not check GitHub in the background.
See [`UPDATE-SECURITY.md`](UPDATE-SECURITY.md) and [`BUILD-VERIFICATION.md`](BUILD-VERIFICATION.md).
