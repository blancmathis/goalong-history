# Real macOS Computer History benchmark

This protocol measures Goalong History in a **real foreground macOS session**. It is the
only repository benchmark that can contribute evidence toward a public-parity claim.

The deterministic four-action fixture used in CI is a reconstruction regression test.
It verifies that known JSONL input can pass through the analysis pipeline. It does not
measure real input recall, TCC, private browsing, Secure Input, application exclusions,
resource reopening, answer correctness, user-interface performance, or Codex behavior.
A synthetic fixture result must never be reported as real parity evidence.

## What the real benchmark measures

The guided harness records independent ground truth and evaluates the exact installed
application identity against the required thresholds:

- physical clicks, shortcuts, scroll gestures and application-switch cycles;
- typing bursts without reconstructing ordinary typed characters;
- association with the correct app, element, page or document;
- semantic state before and after important interactions;
- semantic changes and concrete resource references;
- twenty resource searches and reopen checks;
- factual review of generated memories and ten resume questions;
- Safari private browsing, Terminal Secure Keyboard Entry, exclusions and include-only;
- lock/unlock, optional sleep/wake, Spaces and full screen;
- CPU, resident memory and foreground responsiveness while Computer History opens;
- visible regressions in Screen Time, conversation analysis, agent activity, integrity
  and software updates;
- the same visible scenarios in Codex Computer History when it is accessible.

Every privacy scenario uses a unique disposable marker. The analyzer fails the privacy
check if that marker, a target-specific action or a semantic payload appears where only
a suppression record is allowed.

## Required build identity

A Developer ID Application signature is required for a parity-eligible run because an
ad-hoc identity is not stable enough to establish update and TCC behavior.

List usable signing identities:

```bash
security find-identity -v -p codesigning
```

Build with the exact Developer ID Application identity:

```bash
export LOCALHISTORY_CODESIGN_IDENTITY='Developer ID Application: YOUR NAME (TEAMID)'
./scripts/build_app.sh
codesign --verify --strict --verbose=4 'dist/Goalong History.app'
```

Install that exact bundle at the stable application path:

```bash
sudo /usr/bin/ditto \
  'dist/Goalong History.app' \
  '/Applications/Goalong History.app'
open '/Applications/Goalong History.app'
```

The harness refuses a public-parity-eligible run when the installed bundle is not
`ai.goalong.localhistory` or does not have a Developer ID Application authority. The
`--allow-unstable-signature` option exists only for debugging the harness and cannot make
an ad-hoc run eligible for public parity.

## Minimal manual preparation

Do not reset TCC. In **System Settings → Privacy & Security**, grant only these two
permissions to the exact `/Applications/Goalong History.app` bundle:

1. Accessibility;
2. Input Monitoring.

In Goalong History, explicitly enable Rich Context and use **Validate input**. Perform one
physical click so the persisted health record can prove that a real input callback
reached the running process. A visible permission switch or a created Event Tap alone is
not sufficient.

Use a clean checkout of the exact branch head, then run:

```bash
bash scripts/run_real_computer_history_benchmark.sh \
  --expected-head "$(git rev-parse HEAD)"
```

The script does not grant permissions, reset TCC, publish data, merge code, release the
application, or delete existing history. It creates disposable benchmark files/pages and
a timestamped report folder on the Desktop. Follow each foreground instruction exactly
and use physical input for the ground-truth page.

## Required thresholds

The report may set `public_parity_validated: true` only when every prerequisite and every
measurement is present and passes:

| Metric | Minimum |
|---|---:|
| clicks, shortcuts, scrolls and application switches recalled | 99% |
| actions associated with the correct element or document | 95% |
| important interactions with usable final context | 90% |
| important semantic changes recovered | 90% |
| correct resource found | 95% |
| correct resource reopened when possible | 95% |
| private/Secure Input/exclusion/include-only leakage | 0 |
| factual statements accepted during memory review | 95% |
| resume questions answered correctly and with evidence | 90% |

The following are also mandatory:

- a Developer ID Application signature for `ai.goalong.localhistory`;
- working Accessibility and Input Monitoring for that exact installed identity;
- an Event Tap with a real callback observed during the current launch;
- all core scenarios completed rather than skipped;
- lock/unlock and Spaces/full-screen evidence present;
- performance sampling with no sustained freeze;
- benchmark configuration restored exactly;
- the five extra product surfaces manually checked;
- Codex scenarios completed when Computer History is accessible, or a precise reason
  recorded when it is unavailable.

A missing measurement is a failure to validate, never an implicit pass.

## Artifacts

The Desktop report directory contains:

- `run.json`: immutable scenario windows, ground truth, manual judgments and environment;
- `report.json`: machine-readable measurements, thresholds and final eligibility;
- `report.md`: concise human-readable result;
- `memory-*.json`: Computer History reconstruction for each benchmark day;
- `resource-queries/` and `resume-queries/`: exact local CLI evidence;
- `config.before.json`: configuration that must be restored after the run;
- disposable `fixtures/` used only for the benchmark.

Re-run the analyzer without repeating the foreground session after correcting only manual
review fields in `run.json`:

```bash
python3 scripts/real_computer_history_benchmark.py analyze \
  --run "$HOME/Desktop/goalong-real-.../run.json"
```

Do not edit timestamps, ground-truth counters, captured evidence or benchmark identity.

## Codex comparison

When Codex Computer History is available, enable it for the same time window and perform
the same visible scenarios. The harness records a side-by-side human review for actions,
before/after context, resources, search/resume and privacy suppression. It also searches
`$CODEX_HOME/memories` only for the run's unique disposable token.

When Codex Computer History is not accessible, record the precise reason. Documentation
remains the public contract, but no black-box equivalence may then be claimed.

## Interpretation

A green GitHub Actions run proves the code builds, tests and packages. A green synthetic
fixture proves deterministic reconstruction. Neither proves real capture or public
parity. Only a completed `real_foreground_macos` report for the exact signed build can
support the parity conclusion, and its claim remains scoped to the apps, macOS version
and scenarios actually measured.
