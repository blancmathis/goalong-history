# Computer History public-parity matrix

Last audited: 2026-08-23
Reference contract: <https://learn.chatgpt.com/docs/customization/computer-history>
Scope: public, externally observable Computer History behavior only. This matrix does
not claim knowledge of undocumented OpenAI internals or equivalence with Computer Use.

Status vocabulary:

- **implemented** — a corresponding Goalong code path exists;
- **CI-regression-proven** — synthetic/unit evidence exercises the deterministic logic;
- **live-unproven** — the behavior still needs a signed foreground macOS measurement;
- **open gap** — the public behavior is absent or not sufficiently reliable.

No CI-regression-proven row is a real parity measurement. The only parity-eligible
protocol is documented in
[`COMPUTER_HISTORY_REAL_BENCHMARK.md`](COMPUTER_HISTORY_REAL_BENCHMARK.md).

## Functional matrix

| Public behavior | Expected behavior | Goalong implementation | Automated evidence | Required real macOS scenario | Current result | Remaining proof | Final evidence |
|---|---|---|---|---|---|---|---|
| Explicit enablement | Computer History is opt-in and can be turned off without silently widening capture | onboarding/activity controls; separate Rich Context consent | onboarding/config/privacy tests | metadata-only → Rich Context → off | implemented; live-unproven | confirm migration and stored data on signed app | real report + inspected config |
| Visible capture state | recording, paused, suppressed, permission-missing, tap-unavailable and evidence quality are visible | menu/dashboard runtime plus readiness assessment | capture-health/readiness tests | remove/restore permissions; no callback; low pair coverage | CI-regression-proven; live-unproven | verify exact signed-identity transitions | real report + UI review |
| Pause, resume and stop | no detailed capture while paused/stopped; honest gaps | recorder/menu/dashboard controls | recorder-state tests | pause ten minutes, resume and inspect | implemented; live-unproven | prove no hidden detail during gap | real report |
| Clicks | left/right/other/double clicks preserved | `CGEventTap`, pointer snapshot, causal transaction | unit tests + synthetic reconstruction | independent physical click counter | CI-regression-proven; real recall unmeasured | ≥99% recall; ≥95% target association | `report.json` input metrics |
| Typing activity | grouped duration/count/field context, without general keylogging | typing bursts, AX target, semantic aftermath | privacy/semantic tests + synthetic reconstruction | independent physical typing bursts; secure field | CI-regression-proven; live-unproven | burst quality and zero protected leakage | real report |
| Shortcuts/navigation keys | meaningful combinations retained | Event Tap keyboard classification | unit tests + synthetic Command-S | independent physical shortcut counter | CI-regression-proven; real recall unmeasured | ≥99% recall | real report |
| Scrolling | ordered scroll bursts retained | Event Tap scroll grouper | synthetic scroll regression | independent physical gesture counter | CI-regression-proven; real recall unmeasured | ≥99% recall and usable grouping | real report |
| Application/window/page changes | event-driven app/window/title/URL transitions, polling only as fallback | `NSWorkspace`, `AXObserver`, URL sampler, fallback polling | episode/resource tests | Finder, Safari, Chrome, Terminal, editor, Spaces/full screen | implemented; live-unproven | measure rapid-transition loss | real report |
| Focus/selection/value changes | useful AX changes trigger context capture | AX notifications and semantic sampler | AX/privacy model tests | focus, selection and value changes in real apps | implemented; live-unproven | third-party AX timing/coverage | real report |
| Before → action → after → settled | context belongs to the same app, window and resource | interaction phases plus app/resource continuity gate | cross-app and cross-resource isolation tests; synthetic complete pairs | switch app/document before delayed callback | CI-regression-proven; live-unproven | ≥90% important interactions with usable final state | real report |
| Rich Context honesty | UI distinguishes consent, switches, working tap, stable signature and pair coverage | evidence-based readiness card | readiness tests | every permission/signature/coverage state | CI-regression-proven; live-unproven | signed-build TCC and wording audit | real report + UI review |
| Private browsing | no title/URL/input/semantic content; fail closed | private-window classifier, suppression, URL-cache clearing | suppression/privacy tests | Safari private and Chrome incognito | synthetic evidence only | zero leakage across tested browsers/locales | real privacy rows |
| Secure Input/protected controls | no input or semantic detail | Secure Input and secure AX guards | secure/privacy tests | Terminal Secure Keyboard Entry and protected field | synthetic evidence only | zero leakage and correct suppression record | real privacy rows |
| Application exclusions | excluded app yields only coverage state | independent app policy | exclusion/include-only tests | exclude TextEdit; exercise all actions | CI-regression-proven; live-unproven | zero detail leakage | real privacy rows |
| Website exclusions | excluded host/subdomain yields only coverage state | independent sanitized-host policy | domain/privacy tests | exclude localhost/127.0.0.1 in browser | CI-regression-proven; live-unproven | zero detail leakage | real privacy rows |
| Application include-only | only listed bundle IDs captured; unknown denied | `CaptureListMode.includeOnly`, UI and enforcement | migration/fail-closed/precedence tests | allow TextEdit; deny Finder/unknown app | CI-regression-proven; live-unproven | prove real identity transitions | real privacy rows |
| Website include-only | only listed hosts/subdomains captured; missing host denied | independent website include-only mode | policy/precedence tests | allow localhost; deny 127.0.0.1 | CI-regression-proven; live-unproven | prove real tab/AX edge cases | real privacy rows |
| No screenshot/audio/clipboard | event/text observation only | prohibited APIs absent | `audit_privacy_boundaries.sh` | inspect signed bundle and output | CI-audited; live inspection pending | repeat on final signed bundle | audit log + real artifacts |
| Resource references | identify files, pages, docs, conversations, issues, app/terminal sessions with provenance | resource resolver and stable `ComputerHistoryResourceReference` | resolver tests + synthetic known resource | twenty independent local files/pages plus available third-party apps | partially implemented; live-unproven | ≥95% correct found and reopened; provider coverage | real resource table |
| Search without forced false positives | may return no match; named subject requires evidence | subject-gated local ranking | unrelated-query regression | present/absent named real resources | CI-regression-proven; live-unproven | ≥95% correct resource; multilingual calibration | real query artifacts |
| Stable resource inspection/reopen | stable ID resolves locator and related episodes | real `find` and `resource` CLI commands | end-to-end synthetic CLI regression | open exact intended local/page resource | CI-regression-proven; live-unproven | ≥95% reopen success | real resource review |
| Resume recent work | recover where work stopped with evidence/limitations | resume intent over episodes/resources | English/French resume tests | ten labeled questions across benchmark sequence | synthetic evidence only | ≥90% correct/useful/evidence-backed | real resume review |
| Stand-up/task status | summarize observable work/status without invented facts | episode/status inference and answers | completion/blocked/latest-success tests | success, retry, wait, abandon, stand-up | synthetic evidence only | ≥95% factual accuracy | real factual review |
| Chronological episodes | preserve every ordered action, transition, gap, uncertainty and provenance | events → interactions → episodes | same-minute and boundary tests | rapid actions and unrelated browser tasks | CI-regression-proven; live-unproven | real boundary accuracy | real memory artifacts |
| Durable local memories | JSON/Markdown locally inspectable and queryable | local memory stores plus namespaced Codex mirror | serialization/query/rebuild tests | generate, restart, query and inspect | CI-regression-proven; live-unproven | migration/restart proof on real store | real artifacts |
| 48-hour detailed default | detailed events temporary; memories/proofs separate | two-day default and independent retention coordinator | retention boundary and transaction tests | disposable live data over boundary/restart | CI-regression-proven; live-unproven | physical purge proof on installed build | retention report |
| Granular deletion | item/interval/day/session/all deletion removes raw+semantic+derived coherently and rebuilds survivors | causal JSONL deletion, transactional backup/rollback, later-day invalidation/rebuild | engine/coordinator/rollback tests | confirmed deletion scopes on disposable real history | implemented and CI-regression-proven; live-unproven | UI execution and post-restart proof | real deletion report |
| Workflow suggestions | repeated semantic sequence, concrete resources and observable outcome; never app-switch-only | grounded workflow detector; review-only proposals | repeated-workflow and switch-only rejection tests | repeat real task two/three times | CI-regression-proven; live-unproven | confidence calibration and no false suggestion | real workflow review |
| Timeline honesty/performance | coverage and uncertainty visible; no full eager rebuild/freeze | readiness card, lazy rendering and rebuild deduplication | readiness/cache tests | large real history; sample CPU/RSS and responsiveness | logic implemented; performance live-unproven | performance guard and high-volume run | real performance section |
| Prompt-injection boundary | captured text remains untrusted evidence, never a command | deterministic analysis/search and security notices | privacy/memory tests | hostile text in disposable page | synthetic evidence only | signed-build black-box proof | real privacy/security report |
| Extra Goalong surfaces | Computer History changes do not regress Screen Time, conversations, agents, integrity or updates | existing isolated features | complete test suite | manually smoke-test all five surfaces | automated tests pass; live-unproven | real smoke checks | real report regressions |

## Synthetic CI reconstruction contract

`scripts/validate_computer_history_fixture.sh` creates generated JSONL input and verifies
only deterministic reconstruction:

| Synthetic check | Expected |
|---|---:|
| generated actions preserved | 4 / 4 |
| generated interactions reconstructed | 4 / 4 |
| generated before/after pairs | 4 / 4 |
| known generated resource resolved | yes |
| unsupported named query rejected | yes |
| no-pair negative fixture rejected | yes |

Its machine-readable output explicitly contains:

```json
{
  "synthetic_regression_valid": true,
  "synthetic_fixture": true,
  "real_capture_measured": false,
  "public_parity_validated": false
}
```

This fixture cannot support a real-parity statement regardless of a `4/4` result.

## Real benchmark status

The guided fail-closed protocol is implemented in:

```bash
bash scripts/run_real_computer_history_benchmark.sh \
  --expected-head "$(git rev-parse HEAD)"
```

It requires a Developer ID-signed `ai.goalong.localhistory` bundle installed at the
stable Applications path, working Accessibility and Input Monitoring for that identity,
Rich Context consent and a real foreground callback. It records independent physical
input ground truth, privacy markers, twenty resource reviews, factual/resume judgments,
performance samples and a Codex comparison when accessible.

At the time of this matrix update, the protocol has **not been executed in Mathis's
foreground macOS session**. Therefore every required live metric remains **not measured**
and no public-parity conclusion is permitted:

| Live threshold | Status |
|---|---|
| clicks, shortcuts, scrolls and app switches ≥99% recall | not measured |
| correct element/document association ≥95% | not measured |
| important interactions with usable final state ≥90% | not measured |
| important semantic changes recovered ≥90% | not measured |
| correct resource found ≥95% | not measured |
| correct resource reopened ≥95% | not measured |
| private/Secure Input/exclusion/include-only leakage = 0 | not measured |
| factual accuracy ≥95% | not measured |
| resume questions solved ≥90% | not measured |
| CPU/RSS and foreground responsiveness guard | not measured |
| side-by-side Codex Computer History comparison | not executed |

Only a `real_foreground_macos` report for the exact signed build may set
`public_parity_validated: true`; missing measurements fail closed.
