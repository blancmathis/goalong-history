# macOS permissions after a Community update

## Report and diagnosis

Goalong History can be listed as enabled in System Settings while the running app
still receives a denied Accessibility preflight or `EPERM` opening Apple Screen
Time stores. Legacy Community builds were ad-hoc signed: replacing a build changed their
code identity. A switch for an earlier build is not proof that macOS authorizes
the current process. Full Disk Access changes may also require a process restart.
Neither a cached checkbox nor an AX read of Goalong's own window may override a
denied permission.

For the root-cause signing correction and its verified limits, see
[Stable release identity](STABLE_RELEASE_IDENTITY.md). Manual entry replacement is
not the normal update path.

## Recovery in the app

1. Open the blocked source. **Check access** is always available and shows a
   progress indicator followed by the result of each attempt.
2. A failed check expands **Already enabled in System Settings?**. Restart the
   app after changing permissions. When a stale entry remains, remove only
   Goalong History from that permission list, then use **+** to add the exact
   copy shown by **Show this app in Finder**, and enable it.
3. **Restart Goalong History** reopens that exact bundle and returns to Settings.
   Enable the desired source again. No source, recording preference, exclusion,
   analysis, or sharing permission is changed by restarting.

The source becomes enabled only after an actual, successful permission check and
a saved, user-initiated consent. This recovery does not turn a real OS denial
into a false success. It does not reset TCC, alter code-signing requirements,
weaken Gatekeeper, read TCC databases, or change another application's permissions.

## Implementation and regression protection

- Activation uses prompt-free OS preflights, independently from AX capture-health
  round trips. The system-wide capture-health probe has a bounded messaging timeout.
- An eight-second activation timeout ends stalled checks. Cancellation, timeout,
  and duplicate callback protection prevent late results from enabling a source.
- Self-relaunch uses LaunchServices, not a shell or an arbitrary subprocess.
  PID, launch date, and exact bundle path identify the previous process. The new
  instance waits up to twenty seconds for its predecessor to flush and exit;
  otherwise it exits without opening history stores. Normal duplicate-instance
  protection remains active. No process is forcibly terminated.
- Unit tests cover denied-to-granted transitions, repeated visible failures,
  stale callbacks, timeouts, malformed relaunch requests, PID reuse, and unrelated
  app paths. Isolated native screenshots cover both blocked sources in both themes.

A green unit test or rendered fixture is not proof that macOS permissions were
physically regranted on a user's Mac. Verify the real OS preflight, source toggle,
and live capture health separately after the user approves the current build.
