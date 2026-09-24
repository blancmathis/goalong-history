# Foreground screen time (0.6.45)

Input silence is not absence. The default reading tolerance is five minutes
since the last system input, for any visible foreground application, even when
window titles, control labels, URLs and recorded keyboard/click details are off.
Settings > Enregistrement > Suivi du temps d’écran offers 2, 5, 10, 15 and 30
minutes. The explicitly selected screen-on mode has no input timeout; it still
requires an awake display, an available unlocked session and a visible foreground.
It may include absence when somebody leaves an unlocked Mac with a window open.
No camera, microphone, audio/video capture or new permission is used.

Fresh foreground call/playback evidence continues beyond the reading tolerance.
Process-only display assertions can support app time, not arbitrary background
tabs: website attribution is bounded by the reading deadline unless focused
playback/call controls supply direct evidence. Names alone are not evidence.
A foreground observation does not prove attention or productivity.

Lock, sleep, privacy pause, exclusions, secure input and unavailable context
invalidate evidence. Screen sleep and system sleep are independent gates.
Workspace notifications are supplemented by a fresh read-only session/display
check, including launch while locked. Screen-lock notifications are separate
from session-switch notifications. No security or permission setting is altered.

## Measurement contract

New recorder observations include `activity.presence_policy=foreground-v1`,
`activity.foreground_visible`, `activity.idle_limit_seconds` and `idle_seconds`.
The observation travels with its original context through buffered input and
semantic capture, without affecting context fingerprints. Delayed contexts and
playback evidence expire. Automatic title changes never reset the input clock.

`ForegroundUsageObservation.activeDuration` and `websiteDuration` are shared by
the dashboard and website projection; local analytics use the same interval
budget. Idle cutoffs split an interval precisely rather than removing the entire
preceding interval. Missing observations (>120s), explicit gaps and unconfirmed
last samples do not create time. Heartbeats are bounded to <=30s independently
of diagnostic heartbeat settings. Input-minute metrics remain explicitly separate
from foreground duration; websites are a subset of app time, never an extra total.

The selected reading limit is recorded, not read from today's preferences when
replaying history. Old, unversioned journals keep their prior interpretation.
This update does not invent unrecorded historical meetings or rewrite raw journals.
Apple Screen Time is a separate optional source and is not overwritten.

## Regression coverage

Tests cover 1–4 minutes of quiet reading; exact five-minute cutoffs; return after
absence; arbitrary apps; long-reading settings; explicit screen-on mode; 45-minute
calls and silent videos; playback stop; app switches; website/app reconciliation;
locks, sleep, pause and exclusions; invalid/stale evidence; gaps and clock reversal;
configuration migration; recorder propagation; optional monitoring; and disk-backed
parity between dashboard, website totals and local analytics.
