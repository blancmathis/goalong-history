---
context_room:
  id: assurance.security.permissions
---

# macOS permissions and Goalong consent

**Goalong can play music; it never listens.** Ambiance asks for no permission at
onboarding, module activation or Play. Sound output uses no microphone, Apple Music
library or Full Disk Access. The module defaults to off; off creates no audio engine
or download session.

Personal music is selected through the system file picker (`NSOpenPanel`) only when
the member asks. Ambiance stores paths and streams the selected files from disk,
without making a copy. If macOS itself later asks for access to Documents, Downloads
or Desktop while reading a selected file, that system folder prompt is acceptable;
Goalong does not request those permissions preemptively.

| Capability | Why Goalong may need it | Behavior when absent or off |
| --- | --- | --- |
| Accessibility | Foreground app/window/control context and browser URL where exposed | Computer History remains off or reports incomplete context |
| Input Monitoring | Coarse click, scroll, shortcut/navigation and typing-count activity | No input activity is captured |
| Full Disk Access | Read Apple Screen Time and configured local agent histories at their original locations | Each protected source reports unavailable; other sources continue |
| Launch at login | Start Goalong after sign-in | App starts only when opened manually |

Every row has two gates: explicit Goalong consent and the macOS permission. A previously granted
macOS switch never enables a Goalong feature. Computer History, Screen Time and AI conversations
can be enabled or revoked independently in Settings. ChatGPT analysis has its own consent and does
not follow Full Disk Access automatically.

Full Disk Access is broad. The current main process owns it; the narrower reader service described
in [`lifecycle/changes/active/fda-reader-isolation`](lifecycle/changes/active/fda-reader-isolation/index.md)
is not shipped.

## Optional Blocage module (Standard)

The module switch is separate explicit consent, off by default. Off creates no controller,
blocking file, timer, observer or permission prompt. Once on, active/upcoming blocks reuse the
existing context monitor even when Computer History is paused, disabled or privacy-stopped.
This independent lane reads only app identity, window geometry, private-window status and public
browser host/path, never records history and never feeds Jev or analysis. History exclusions do
not exempt a blocking rule. Private addresses are never read by this lane.

Accessibility permits browser inspection, menu tab closure, a fixed pid-scoped Command-W fallback,
and the fixed Control-Command-Q screen-lock shortcut. The module never requests Accessibility
itself; the existing permission settings remain the approval route. Without it, application
termination works and known browsers with active site rules are covered as unsupported.
A freeze using screen locking requires Accessibility; shield mode remains available.
The locked module requests `SMAppService.mainApp` launch at login and publishes enabled,
awaiting approval or failure. It adds no helper/daemon and does not grant itself permission.
