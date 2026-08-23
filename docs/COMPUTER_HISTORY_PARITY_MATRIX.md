# Computer History public-parity matrix

Last audited: 2026-08-23
Reference contract: <https://learn.chatgpt.com/docs/customization/computer-history>
Scope: public, externally observable Computer History behavior only. This matrix does
not claim knowledge of undocumented OpenAI internals or equivalence with Computer Use.

Status vocabulary:

- **implemented** — a corresponding Goalong code path exists;
- **CI-proven** — deterministic automated validation exercises the behavior;
- **live-unproven** — the behavior still needs a signed, permissioned macOS session;
- **open gap** — the public behavior is absent or not sufficiently reliable.

## Functional matrix

| Public behavior | Expected behavior | Goalong implementation | Automated evidence | Required live macOS scenario | Current result | Remaining gap / required change | Final proof location |
|---|---|---|---|---|---|---|---|
| Explicit enablement | Computer History is opt-in and can be turned off without silently widening capture | onboarding and activity controls; semantic capture remains separately consented | existing onboarding/config tests; privacy audit | enable metadata-only, then full context, then disable | implemented; live-unproven | verify migration never enables rich context implicitly | app UI + config + real-session checklist |
| Visible capture state | recording, paused, suppressed, permission-missing, tap-unavailable and evidence quality states are visible | menu-bar/dashboard runtime presentation plus evidence-based Computer History readiness | capture-health and readiness tests | revoke/restore Accessibility and Input Monitoring; pause/resume; run with no callback and with low semantic coverage | implemented and CI-proven for state logic; live-unproven | verify wording and transitions against the signed app identity | `RuntimePresentation`, `CaptureHealthEvaluator`, `ComputerHistoryReadinessAssessment` |
| Pause, resume, stop | user can pause/resume or turn capture off | recorder state and menu/dashboard controls | recorder-state tests | pause for ten minutes, resume, stop, inspect gaps | implemented; live-unproven | verify no detailed data during pause and honest gap display | recorder events + live checklist |
| Clicks | left, right, other-button and double-click actions are preserved | `CGEventTap`, pointer snapshots, action transactions | interaction tests and deterministic click fixture | TextEdit/Finder/browser single, double, right and auxiliary clicks | implemented; CI-proven for model; live-unproven for recall | measure ≥99% live callback recall and ≥95% target association | strict fixture + real benchmark report |
| Typing activity without keylogging | grouped bursts contain quantity/duration/field context and observable consequence, not reconstructed ordinary text | typing-burst grouper, AX field context, before/settled snapshots | privacy audit, causal fixture, semantic-store tests | type in normal and secure fields; inspect persisted JSON | implemented; CI-proven for model; live-unproven | measure burst boundaries and prove zero secure-field leakage | privacy audit + live benchmark |
| Keyboard shortcuts and navigation keys | meaningful combinations and special keys are recorded | event tap shortcut/navigation classification | action tests and deterministic Command-S fixture | Cmd-S, Cmd-C, arrows, Return, Escape in several apps | implemented; CI-proven for model; live-unproven | measure ≥99% live recall | strict fixture + live benchmark |
| Scrolling | scroll bursts remain ordered actions | event tap scroll grouping and transaction builder | deterministic scroll fixture | short and rapid scrolls in browser, Notes and editor | implemented; CI-proven for model; live-unproven | measure ≥99% live recall and burst quality | strict fixture + live benchmark |
| Application, window and page changes | app activation, window creation/change/title and URL/page changes are observed | `NSWorkspace`, `AXObserver`, URL sampler and fallback polling | unit tests for episode boundaries and resources | Finder, Safari, Chrome, Terminal, editor, Spaces/full screen | implemented; live-unproven | polling is only fallback; measure rapid-transition loss | real benchmark report |
| Focus, selection and value changes | useful AX focus/selection/value changes trigger context capture | AX observer notifications and debounced semantic sampler | AX model tests | text selection, changed field value, tab/focus switches | implemented; live-unproven | third-party AX quality and timing are unproved | real benchmark report |
| Before → action → after → settled | every important action is attributed only to a continuous app and resource | interaction IDs, phase metadata, application **and resource** continuity checks | parity tests, cross-app isolation test, cross-resource isolation test, strict fixture at 100% | switch app/document before delayed callback fires | CI-proven for deterministic model; live-unproven | live target ≥90% exploitable final state | `ComputerHistoryInteractionBuilder`, strict fixture |
| Rich Context is honest | UI distinguishes event tap, Accessibility, Input Monitoring, rich context, stable identity and degraded metadata-only/partial capture | permission/capture-health surfaces, semantic opt-in and readiness assessment requiring real callback plus ≥90% day pair coverage | capture-health tests and `ComputerHistoryReadinessTests` | run with each permission combination, ad-hoc and stable signatures, no callback, and 0–100% pair coverage | implemented and CI-proven for state logic; live-unproven | signed-build TCC and wording audit remains required | Computer History readiness card + live UI benchmark |
| Private browsing | no private title, URL, text or input details persist; uncertainty fails closed | private-window classifier, suppression events, cleared URL cache | private-content memory/search test and privacy audit | Safari/Chrome private windows, ambiguous transition | implemented; synthetic evidence; live-unproven | browser/version/localization coverage must be measured | privacy benchmark |
| Secure Input and protected controls | no key or semantic capture during Secure Input/secure fields | secure-input suppression and secure AX element guards | secure-input/privacy tests and audit | Terminal password prompt and password field | implemented; synthetic evidence; live-unproven | TCC/event-tap timing proof required | privacy benchmark |
| Application exclusions | excluded apps produce only a coverage gap | independent application policy | config migration/include-only tests; privacy audit | exclude TextEdit and exercise all action types | CI-proven for policy; live-unproven | verify callbacks cannot attach delayed semantic content | live privacy benchmark |
| Website exclusions | excluded domains/subdomains produce only a coverage gap | sanitized URL policy independent from app policy | domain tests and privacy audit | exclude one host while keeping browser enabled | CI-proven for policy; live-unproven | verify URL-unavailable transitions fail closed where required | live privacy benchmark |
| Application include-only | only explicitly listed bundle IDs are captured; unknown identity is suppressed | `CaptureListMode.includeOnly`, visible settings, recorder enforcement | migration and fail-closed policy tests | allow TextEdit only; exercise Finder/Safari/unknown wrapper | CI-proven for policy; live-unproven | verify real frontmost identity transitions | live privacy benchmark |
| Website include-only | only explicitly listed hosts/subdomains are captured; missing host is suppressed | separate website mode and visible list | independent policy tests | allow one site in Safari; switch tabs and disable URL exposure | CI-proven for policy; live-unproven | verify browser AX edge cases | live privacy benchmark |
| No screenshot/audio/clipboard capture | Computer History remains text/event based | no screenshot, video, camera, microphone, audio or clipboard capture paths | `audit_privacy_boundaries.sh` | inspect built app permissions and generated data | CI-audited; live inspection pending | repeat on final signed bundle | CI audit log + bundle inspection |
| First-class resource references | identify files, web pages, cloud docs, conversations, issues and app sessions with sanitized locators and provenance | resource resolver and `ComputerHistoryResourceReference` | resolver tests and deterministic Google Docs fixture | files, Docs/Sheets/Slides, ChatGPT/Claude, Slack, Notion, Figma, Linear, GitHub, Office, Notes, IDE, Terminal | partially implemented; live-unproven | provider-specific stable IDs/reopen coverage remains incomplete for several native apps | resolver tests + live resource table |
| Search without forced false positives | named queries return only evidence-backed matches and may return no result | evidence-gated subject matching, lexical/resource/recency ranking | unrelated named lookup regression and strict fixture | ask for present and absent named resources | CI-proven for fixture; live-unproven | calibrate multilingual semantic retrieval and conversational filler handling on a labeled live corpus | search benchmark |
| Stable resource inspection | a returned stable ID can be inspected with provenance and related episodes | read-only `find` and `resource` CLI commands | strict end-to-end CLI fixture | locate and reopen real files/pages | CI-proven for fixture; live-unproven | reopening success must reach ≥95% on tested resources | CLI output + live benchmark |
| Resume recent work | answer where work stopped with cited episode/resource and explicit limitations | local search service resume intent | resume tests and validator question | create break, switch task, ask to resume | implemented; synthetic evidence | measure ≥90% correct answers on live labeled questions | real Q&A benchmark |
| Stand-up and task status | summarize episodes, decisions/outcomes and bounded status without inventing facts | episode builder, status inference, local answers | completion/blocked/latest-success tests | complete, fail/retry, wait and abandon tasks | implemented; synthetic evidence | factual accuracy target ≥95% requires human-labeled live set | real Q&A benchmark |
| Chronological episodes | preserve ordered actions, transitions, resources, gaps, uncertainty and provenance | events → interactions → episodes pipeline | multi-action same-minute and separation tests | five rapid actions and unrelated browser tasks | CI-proven for model; live-unproven | high-volume performance and real boundary accuracy | tests + live benchmark |
| Durable local memories | JSON and Markdown memories are locally inspectable and queryable without proprietary service | memory engine/store and Codex memory mirror | memory serialization/query tests; strict fixture | generate, inspect, restart and query | implemented; synthetic evidence | verify long-term migration and deletion rebuild on real store | memory files + migration report |
| 48-hour detailed-event default | new detailed events expire after 48 hours; memories persist until deletion | new-config default is two days; data-class retention model preserves memories/proofs separately | hardening default test and retention tests | advance a disposable store beyond 48 hours | CI-proven for configuration/model; live-unproven | physical purge and restart proof on disposable macOS data | retention integration report |
| Granular deletion | item, ten minutes, hour, day/session and all-history deletion remove derived indexes/memories consistently after confirmation | deletion scopes and planner exist; retention cleanup only removes whole expired-day artifacts | retention/deletion planner tests | execute each scope on a disposable history and rebuild | open functional gap | implement confirmed physical partial/all deletion across events, semantic payloads, indexes, analyses and memories, then rebuild surviving days | deletion integration report |
| Repeated workflow suggestions | require repeated, normalized, meaningful actions, identified resources and observable result; never auto-install | grounded workflow detector and review-only suggestions | repeated-workflow test and app-switch-only rejection | repeat a real task twice/three times; inspect evidence | CI-proven for model; live-unproven | confidence calibration and diverse resource sequences | workflow benchmark |
| Timeline coverage honesty | metadata-only periods are not presented as complete semantic understanding | readiness card, coverage counts, pair ratio, limitations, lazy timeline rendering and rebuild deduplication | readiness tests, strict checker and memory consistency tests | open large high- and low-context days while measuring CPU/memory | implemented in data/UI logic; live performance unproven | high-volume CPU and memory benchmark remains open | UI/performance benchmark |
| Prompt-injection boundary | captured page text is untrusted evidence, never an executable command | security notice, deterministic summarizer/search, no execution path | privacy audit and memory tests | display hostile instructions in a page and query history | implemented; synthetic evidence | add signed-build black-box test | privacy benchmark |

## Deterministic CI benchmark contract

`scripts/validate_computer_history_fixture.sh` creates an isolated synthetic LocalHistory
store and executes the same public read-only CLI used for local data. It currently
requires:

| Metric | Required | Fixture expectation |
|---|---:|---:|
| action events preserved | 100% | 4 / 4 |
| reconstructed interactions | 100% | 4 / 4 |
| before/after pair ratio | ≥90% | 4 / 4 = 100% |
| concrete resources | ≥1 | Google Docs document |
| stable resource lookup | success | same resource ID and related episode |
| unsupported named lookup | zero hits | strategic acquisition query |
| no-pair negative fixture | strict rejection | required |

This proves deterministic model and integration behavior only. It does **not** measure
macOS callback recall, TCC persistence, private-window detection, resource reopening in
third-party apps, CPU usage, or factual accuracy of live summaries.

## Live benchmark status

The execution environment used for this change is Linux and has no access to Mathis's
macOS session, TCC database, installed applications, local history, or Codex Computer
History. Therefore the mandatory live figures remain **not measured**, not zero and not
passed:

| Live threshold | Status |
|---|---|
| clicks, shortcuts, scrolls and app switches ≥99% recall | not measured |
| correct element/document association ≥95% | not measured |
| important interactions with exploitable final state ≥90% | not measured |
| important semantic changes recovered ≥90% | not measured |
| correct resource found ≥95% | not measured |
| correct resource reopened ≥95% | not measured |
| private/Secure Input/exclusion leakage = 0 | not measured on signed live build |
| summary factual accuracy ≥95% | not measured |
| resume questions solved ≥90% | not measured |
| timeline CPU and memory limits | not measured |
| side-by-side Codex black-box comparison | unavailable in this environment |

A public-parity conclusion is forbidden until these rows have measured evidence on the
specific signed build and application set being claimed.
