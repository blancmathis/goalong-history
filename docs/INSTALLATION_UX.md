# Installation experience principles

The installation is part of the product, not a developer prerequisite checklist.

1. **One obvious download.** The primary action is the universal Community DMG. Source installation is documented separately.
2. **Trust before access.** Explain the exact privacy boundary before triggering any macOS permission prompt.
3. **One permission at a time.** Accessibility and Input Monitoring each get a dedicated screen, a plain-language purpose, a direct Settings link, and live status.
4. **Never dead-end.** Every screen offers a next step, a way to check again, and a safe “set up later” path.
5. **No hidden persistence.** Starting at login is an explicit final toggle managed by macOS `SMAppService`, not a hand-written LaunchAgent.
6. **Immediate payoff.** Completion opens the dashboard and tells the user where pause, privacy, and sharing controls live.
7. **Recover gracefully.** Updates preserve local history. Uninstalling keeps data unless the user explicitly chooses to remove it.
8. **Explain Gatekeeper honestly.** The free build is not Apple-notarized. After the first blocked open, direct the user only to **System Settings → Privacy & Security → Open Anyway**; never ask them to disable Gatekeeper.
9. **Separate integrity from identity.** Show the SHA-256, release manifest and GitHub provenance check without claiming they are Apple notarization. Say that updates keep the pinned signing identity, so permissions normally persist; approval can repeat once when leaving a legacy ad-hoc build or if the identity ever changes.
10. **Move to Applications safely.** A launch from a disk image or a translocated path offers to move the app. The copy is made next to the destination and swapped in atomically, so a failure never leaves the user without an app. Another running copy must quit first. The step removes only `com.apple.quarantine` from the copy it just made, never a Gatekeeper setting and never another path. A translocated copy of the version that is already installed never replaces it: the user is sent to the installed app.
