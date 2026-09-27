# Permission lifecycle — validation record

Date: 2026-09-27. Main baseline: `77fefe44da9931172ffd157d182ec8b3af30a891`.
Implementation: `6f7d58ee960eed65d4bc37cb62567bec00863d27`.
Native fixture correction: `107a853438a51735aa86dc7dbe012e023d708186`.
The final change also prevents the Full Disk Access sheet footer from reintroducing
repeated relaunches and adds its deterministic regression test.

## Verified results

- Final local access/permission/capture-health/support/activation selection: **110
  tests, zero failures**, including the final Full Disk Access footer change.
  Command: `swift test --filter 'Permission|CaptureHealth|SupportDiagnostics|SourceActivation|ScreenTimeActivation'`.
- Complete independent GitHub Swift suite at `107a853`: **1,369 tests, 29 skipped,
  zero failures**. Run `36308416651`, native brand motion integration. The macOS
  quality gate `36308416591` also completed its full Swift test step successfully.
- The first complete local run at the same production code had **two failed
  assertions in one OpenCode SQLite test**, unrelated files unchanged by this patch.
  That exact test passed on an isolated rerun without any code or assertion change
  (3.595 seconds), and on the independent full GitHub runs. It uses a five-second
  fixture body-read budget; local resource contention is a possible explanation,
  not a proven diagnosis. The unsuccessful run is not counted as a green run.
- Five designated-requirement policy tests pass. Two genuinely different locally
  signed fixture binaries satisfy the same prior requirement. Weakened designated
  requirements and ad-hoc replacements are rejected.
- The strengthened verifier accepts the existing installed production app, CLI
  and relauncher on every architecture. No installed component was changed.
- Real isolated relaunch integration passes three quit/reopen cycles (four PIDs).
  Each old process drains before its successor; ordinary Quit stays quit. Missing
  helper reports failure without terminating the parent.
- Three CI preference-restoration regression tests pass using a stub, not the
  actual macOS preferences. Two local native motion rendering runs pass all pixel
  assertions. The corrected GitHub native motion job also passes both real OS
  Reduce Motion settings in its disposable runner.
- Privacy-boundary audit, six update-policy tests, five publication-policy tests,
  release-signing policy, public installer safety and source installer safety pass.
- Shell syntax validation and `git diff --check` pass.

## What was not proven

The local Mac runs macOS 26.5.1 with Apple Swift 6.2.4. The reported Mac runs 26.6.2.
A state-machine test and a code-signature test cannot establish that the affected
Mac's TCC authorization record has been recreated. No permission reset, approval,
installed application replacement, code-signing key export, history change or
consent change was performed on the owner's installed Goalong.

The source changes do not themselves constitute a published update. Record the
final PR-head CI result and verify the actual signed feed/archive before claiming
publication. The final footer change has local targeted coverage; the earlier
full GitHub pass must not be represented as a run of a later commit.

The shared report supports a persistent denial and an identity-change clue, not a
specific diagnosis of TCC corruption or a detected device-management policy.
See `PERMISSION_LIFECYCLE.md` for the complete recovery matrix and invariants.
