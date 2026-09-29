# Permission lifecycle and recovery — September 2026

## Incident and limits of the evidence

The affected 0.6.49 process was installed in Applications, was the only running
copy, and reported a valid Apple Development signature. All 175 recorded AX
permission observations were negative (174 API-disabled results, one messaging
failure). Two clean relaunches did not restore access. The journal also reported a
changed last-working permission identity. These facts support an identity migration
as a possible cause, not a definitive reading of the macOS authorization record.
The original user report is not committed: only structural findings are retained.

There were independent application bugs: non-browser NSWorkspace fallback was
counted as AX success, a private/excluded context hid the permission failure, the
stale-identity assessment covered ad-hoc builds only, and recovery repeated the
same advice without remembering the steps already attempted. Source checks and
the capture watchdog also performed independent overlapping permission probes.

## Invariants

A source consent, an OS preflight, a protected external-process AX read, and an
input callback are different facts. None may silently stand in for another.
A generic application name or a read of Goalong's own window is not AX evidence.
An input tap that can be created is not proof of real callback delivery. Old
callbacks retained for diagnostics never prove the current launch is working.
A missing focused window or a temporarily unresponsive app does not revoke the
saved recording choice. An explicit API-disabled response is distinguished from a
messaging timeout and can contradict a stale positive preflight; its evidence is
preserved in backward-decodable health snapshots. An explicit OS denial must not be hidden by a private
window or application exclusion. Manual/global pause and privacy suppression
continue to stop collection independently of the diagnostic display.

## Shared observations and cancellation

The app, setup checks and permission requests use one PermissionManager. Snapshot
reads perform no OS calls. Concurrent worker checks join one bounded observation;
the main thread does not wait for another worker. A pending observation is not a
successful activation. The recording watchdog refreshes outside the main thread.
A backwards wall-clock jump cannot indefinitely retain a cached observation.

Every explicit repair invalidates an observation generation before and after the
operation. Observations are suspended for the entire reset interval, not only at its
endpoints. A timeout reports failure but does not reopen the gate while the owned
reset process is still running. A late AX probe cannot publish a pre-reset grant. Source check delivery
rechecks the generation on the main thread, so a result queued before a reset cannot
later enable a source. All OS checks remain prompt-free except an explicit request
from the person. The protected fallback tries at most two external processes with
0.12-second AX messaging timeouts, reads only the type/existence of a window list,
and retains a definite API-disabled result if another target times out.

## Guided recovery

A local, per-service recovery ledger retains only bounded counters for settings
visits, successfully prepared relaunches and successful targeted resets. It expires
after one day and is scoped to the installation and build. It contains no grants,
recording consent or activity. No recovery step automatically enables a source.

| Situation | Result |
| --- | --- |
| New denied installation | Explain the exact permission and current app copy. |
| Person reports enabling permission | Offer one exact-copy relaunch. |
| Denial after relaunch or changed working identity | Make the confirmed, single-service repair visible. |
| Reset succeeded | Ask for a new macOS approval; never show success from the reset alone. |
| Denial after reset, reapproval and relaunch | Explain exact-entry replacement and export diagnostics; do not loop through automatic resets. |
| Temporary location or path traversal | Install in Applications before offering a reset. |
| Invalid code signature | Replace the application; a reset cannot repair its signature. |
| Multiple running copies | Ask the person to close the other copy; do not kill processes. |
| AX available but actual input-tap creation fails | Allow the distinct direct Input Monitoring permission to be requested. |
| Full Disk Access blocked | Keep the file-access check independent of AX, and track FDA recovery separately. |
| No Apple usage database or unreadable non-permission source | Do not claim an AX/FDA reset solves absent or broken data. |
| Managed/locked settings or unexplained persistent denial | Explain the limitation and administrator/support route; do not claim to detect a policy that was not read. |

Only the fixed command `tccutil reset SERVICE ai.goalong.localhistory` is supported
by the confirmed repair UI. The services are explicitly allowlisted. No reset All,
TCC database read/write, global trust change, entitlement change, signing downgrade,
Gatekeeper bypass or automatic grant is introduced. Tests never reset the installed
application's permissions. History, exclusions, recording choices, analysis consent
and sharing consent are not modified by recovery.

## Stable release identity

The existing certificate and team pin in Distribution/release-signing.json is
unchanged. Distribution/permission-requirements.json additionally pins normalized
fingerprints of the designated requirements of the current verified production
application, CLI and one-shot relauncher. No raw certificate subject is duplicated
in this policy. The public release verifier checks the pinned certificate and exact
component identifiers, then checks each architecture's designated requirement.
Whitespace and rendering comments are ignored; quoted identifiers are not changed.
An otherwise valid signature with a weakened or silently rotated requirement fails.

The continuity regression signs two genuinely different fixture executables. They
must have different code hashes, identical designated requirements, and satisfy the
previous requirement. A weakened requirement and an ad-hoc replacement must fail.
The fixtures never access TCC. Apple Development is not Developer ID notarization.

Certificate renewal, a change of signing identity, or a future Developer ID migration
must be reviewed explicitly: compare the old requirement with the proposed signed
build, test upgrades on an isolated account, document any required one-time approval,
and only then update policy pins. Do not regenerate the pins merely to make a failed
release green. Identity continuity reduces avoidable permission invalidation; it is
not a promise that a previous OS decision can authorize arbitrary new code forever.

## Shareable evidence

The support report adds only allowlisted Boolean/enum/numeric or hash fields:
current-launch AX evidence, pending observation, tap lifecycle, checked source,
cancelled-check state, whether a previous
working identity exists, previous signature kind, validated previous version,
a hash of the current requirement, and the numeric Security API result from testing
the current process against its previous working requirement. A matching requirement
is still not proof of a TCC grant. Raw requirement text, paths, names, account data,
activity, titles and typed content remain excluded from exports.

## Regression matrix and commands

The deterministic suites cover 64 authorization combinations, concurrent check
coalescing, main-thread non-waiting behavior, generation invalidation, clock rollback,
external/self-process evidence, signed/ad-hoc migrations, same-team requirement
changes, denial visibility over privacy suppression, historical callback isolation,
input-only failure, recovery persistence/expiry/bounds, exact permission scope,
installation guards and sanitized previous-identity export.

```
swift test --filter 'Permission|CaptureHealth|SupportDiagnostics'
python3 scripts/test_permission_requirement_policy.py
bash scripts/test_stable_release_identity.sh
bash scripts/test_permission_relaunch.sh
bash scripts/audit_privacy_boundaries.sh
python3 scripts/test_update_policy.py
python3 scripts/test_release_publication_policy.py
```

The relaunch integration test uses a separate random fixture bundle identifier and
verifies real parent/helper/LaunchServices exits, not the user's installed app. It
uses a no-op ledger adapter; ledger progression has separate deterministic tests.
A passing state-machine/signature/relaunch test is not a claim that the friend's
macOS permission record has been recreated. Confirm on the affected Mac with new
AX and real input evidence after explicit approval. Persistent denial should remain
visible and produce actionable diagnostics, never a fabricated green state.

## Primary references

- Apple TN3127, Inside Code Signing: Requirements:
  https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements
- Apple TN2206, macOS Code Signing In Depth:
  https://developer.apple.com/library/archive/technotes/tn2206/_index.html
- Apple AXError.apiDisabled:
  https://developer.apple.com/documentation/applicationservices/axerror/apidisabled
