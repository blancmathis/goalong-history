---
context_room:
  id: assurance.security.permissions
---

# macOS permissions and Goalong consent

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
