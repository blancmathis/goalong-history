# Background continuity

Goalong is the only long-running application process. This change installs no
LaunchAgent, daemon, watchdog executable, privileged service, or scheduled task.
The existing Sparkle update machinery and fixed-purpose permission relauncher
remain unchanged; neither is repurposed as a persistent supervisor.

## User controls

- **Keep Goalong running in the background** defaults on. Closing the dashboard
  keeps the selected sources running. Turning it off allows the app to quit when
  its last window closes. This preference never grants a capture permission.
- **Start Goalong when I log in** is visibly preselected for an undecided setup.
  It registers only after the user completes setup or changes the Settings switch,
  through `SMAppService.mainApp`. Saved opt-outs are preserved. Status is refreshed
  from macOS; the app never silently re-registers after a user disables the item.
- Menu/Command-Q and Dock Quit ask before stopping when background protection and
  a source are enabled. The safe default keeps running; confirmed Quit really quits.
  System logout/shutdown, updater exits and permission restarts are not intercepted.
- A manually requested recording pause survives updates and restarts. Explicitly
  enabling Computer History or pressing Resume can resume it.

## Reliability

The privacy-onboarding migration no longer unregisters an existing native login
item or resets its startup preference. Sparkle's controller is retained during
its approved update/relaunch handoff. There is no competing relaunch loop.

A Foundation activity assertion disables automatic/sudden termination while
background work is enabled. It does not prevent sleep or forced termination.
The existing in-process permission check also repairs a stopped context monitor,
only with source consent and while capture is unpaused and the session is active.
Wake checks re-read permissions. No monitoring is added outside Goalong.

A bounded local technical journal stores a session-open flag, one heartbeat
(timestamp updated roughly once a minute) and the last orderly exit reason.
After an unclean exit, Settings shows an interruption notice. An unclean exit is
not labeled a crash: power loss and Force Quit are indistinguishable here.
No activity payload is added to this journal or sent to a server.

## Verification on an installed signed build

1. Finish fresh setup with startup on; check the native Login Items entry. Repeat
   with it off, then update: the opt-out must remain off.
2. Close the dashboard and verify new local events continue. Reopen it. Turn off
   background operation, close the last window and verify orderly termination.
3. Press Command-Q and use Dock Quit: cancel keeps recording; confirm stops it.
   Logout/shutdown must not show Goalong's confirmation or trigger a relaunch loop.
4. Install an offered signed update. Verify exactly one app remains, enabled
   sources resume, the login item persists, and a prior pause remains paused.
5. Sleep/wake and lock/unlock; verify recovery without collecting while unavailable.
6. Force Quit, reopen, and verify the interruption notice. The app must not
   relaunch itself after Force Quit. Missing data must never be fabricated.

Automated tests cover preference/pause persistence, opt-outs, exit journals,
termination policy and the actual AppDelegate last-window policy. The real signed
update, Login Items UI and capture permissions still require an installed Mac.
