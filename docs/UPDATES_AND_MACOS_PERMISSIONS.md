# Updates and macOS permission continuity

Goalong has one bundle identity, `ai.goalong.localhistory`. Local builds use a stable Apple
Development identity when available; public builds require Developer ID and notarization. Keeping
the bundle identifier and designated requirement stable reduces unnecessary permission prompts,
but macOS may still require the user to confirm a switch after replacement or policy changes.

The app never assumes permission from a switch alone. It verifies functional Accessibility/input
health and separately requires the corresponding Goalong capability consent. Replacing the app
does not intentionally reset history or consent data.

Updates are manual. The app embeds no updater or feed and does not check GitHub in the background.
See [`UPDATE-SECURITY.md`](UPDATE-SECURITY.md) and [`BUILD-VERIFICATION.md`](BUILD-VERIFICATION.md).
