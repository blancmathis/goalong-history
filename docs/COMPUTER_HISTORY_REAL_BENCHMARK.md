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
application identity and binary against the required thresholds:

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

## Required exact build identity

A Developer ID Application signature is required for a parity-eligible run because an
ad-hoc identity is not stable enough to establish update and TCC behavior.

List usable signing identities:

```bash
security find-identity -v -p codesigning
```

From a clean checkout of the exact commit to measure, build, verify, record the binary
hash and install that same bundle in one command:

```bash
export LOCALHISTORY_CODESIGN_IDENTITY='Developer ID Application: YOUR NAME (TEAMID)'
bash scripts/build_real_computer_history_benchmark_app.sh --install
```

This helper:

1. refuses a dirty checkout;
2. records the exact `git rev-parse HEAD`;
3. runs the normal application build with the selected Developer ID identity;
4. verifies the bundle and `ai.goalong.localhistory` identifier;
5. records the executable SHA-256, Team ID, CDHash and designated requirement in
   `dist/goalong-real-benchmark-build.json`;
6. installs that exact binary at `/Applications/Goalong History.app` when `--install` is
   supplied;
7. verifies the installed executable hash before opening it.

The benchmark launcher independently verifies the manifest, repository HEAD, installed
bundle identifier, Developer ID authority, Team ID and executable hash. It refuses to run
against an older or different installed build.

The lower-level `--allow-unstable-signature` Python option exists only for debugging the
harness and cannot make an ad-hoc run eligible for public parity. The standard launcher
does not expose that bypass.

## Minimal manual preparation

Do not reset TCC. In **System Settings → Privacy & Security**, grant only these two
permissions to the exact `/Applications/Goalong History.app` bundle:

1. Accessibility;
2. Input Monitoring.

In Goalong History, explicitly enable Rich Context and use **Validate input**. Perform one
physical click so the persisted health record can prove that a real input callback
reached the running process. A visible permission switch or a created Event Tap alone is
not sufficient.

Then run:

```bash
bash scripts/run_real_computer_history_benchmark.sh \
  --expected-head "$(git rev-parse HEAD)"
```

The launcher first proves that the installed executable is the exact Developer ID-signed
binary recorded for that HEAD. The benchmark does not grant permissions, reset TCC,
publish data, merge code, release the application, or delete existing history. It creates
disposable benchmark files/pages and a timestamped report folder on the Desktop. Follow
each foreground instruction exactly and use physical input for the ground-truth page.

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

- the exact manifest-verified Developer ID Application build for
  `ai.goalong.localhistory`;
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

The build directory contains:

- `dist/goalong-real-benchmark-build.json`: exact source/signature/binary provenance;
- `dist/Goalong History.app`: the verified source bundle copied to `/Applications`.

The Desktop report directory contains:

- `run.json`: scenario windows, independent ground truth, judgments and environment;
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
parity. Only a completed `real_foreground_macos` report for the exact manifest-verified
signed binary can support the parity conclusion, and its claim remains scoped to the
apps, macOS version and scenarios actually measured.
