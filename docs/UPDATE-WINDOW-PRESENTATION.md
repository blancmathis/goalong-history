# Update-window presentation

The existing Sparkle 2.9.6 standard user driver, signing policy, installer and feed remain unchanged.
`SoftwareUpdateWindowCoordinator` is armed only by an explicit update action. It recognizes
Sparkle-owned AppKit window controllers by their defining framework bundle, not translated window
titles, private ivars, KVC or runtime patching. Newly visible checking/update/download/status windows
are attached above the dashboard and raised to floating level for that update session. They hide
on app deactivation, work as fullscreen auxiliaries, and recover when the dashboard is reopened.
Other application windows and passive background checks are not promoted. Original window properties
and child relationships are restored at the end of the Sparkle session. No timer polls another app.
The public `standardUserDriverAllowsMinimizableStatusWindow` delegate prevents losing the progress
window in the Dock; normal Cancel/Close/Skip controls remain owned by Sparkle.

Reference: https://sparkle-project.org/documentation/api-reference/Protocols/SPUStandardUserDriverDelegate.html
