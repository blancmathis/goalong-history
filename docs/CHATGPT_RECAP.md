# Daily Activity analysis through ChatGPT

Goalong History can use the user's connected ChatGPT plan through the local
`codex app-server` protocol. This is not an OpenAI API-key integration. API
credentials are rejected; Codex owns the ChatGPT browser login and managed
credentials inside Goalong's isolated `CODEX_HOME`.

The daily Activity report shown from **Today** combines three evidence sources for a selected day:

- factual Computer History and its bounded causal projection;
- Apple Screen Time totals and application usage for included devices;
- AI conversations discovered by Agent Activity and read transiently from each
  provider's original local storage.

Connecting ChatGPT is available directly in **Settings**.

## Daily report contract

Every new report uses exactly:

```text
model: gpt-5.6-luna
reasoning effort: high
```

Before starting a thread, Goalong asks `model/list` and verifies that this exact
model advertises High reasoning for the connected account. It pins the model and
`model_reasoning_effort` on `thread/start`, checks both values returned by the
thread, and lets `turn/start` inherit that verified pair. This avoids reapplying
an inconsistent turn override. Goalong fails clearly if the contract is
unavailable; there is no silent model or reasoning fallback.

The thread is ephemeral, uses Goalong's restricted permission profile and has no
execution environment. Goalong separately verifies the returned temporary `cwd`.
It accepts an empty effective workspace-root list because that grants less access
than requested, but rejects every root other than that exact temporary directory.
Apps, plugins, skills, memory, goals, browser/computer use and shell tools are
disabled for this one-shot worker. Goalong keeps only Codex authentication and the
small model cache; plugin catalogs, technical SQLite stores and other ephemeral
runtime caches are removed after the child process exits and before the next run.

The turn has a strict structured-output schema:

- a productivity score from 0 to 100;
- an evidence-confidence score from 0 to 100;
- exactly five non-empty summary lines.

The persisted numeric metadata also keeps the bounded AI-collaboration totals
(sessions, analyzed sessions, messages, user-visible messages, tool calls and
errors) so Activity remains informative after relaunch. It never stores
conversation bodies, prompts or excerpts.

The five lines cover the day's concrete outcomes, observed work bounds, strongest
focus interval, lowest-momentum or highest-friction interval, and agent
collaboration plus one grounded improvement. Missing, inaccessible, private,
excluded, or incomplete evidence lowers confidence; it is never treated as proof
of inactivity or procrastination.

## Data flow and no-copy boundary

1. Goalong derives the selected day's bounded Computer History projection and
   local activity aggregates.
2. It reads the selected Apple Screen Time summary.
3. It incrementally discovers configured Codex, Claude, OpenCode, and other local
   agent sources. During an explicit report run only, bounded conversation
   summaries are read directly from the original provider storage.
4. Provider adapters project only user requests and final assistant replies.
   Codex system/developer prompts, compactions, reasoning, tool traffic and
   commentary are excluded locally. Claude and OpenCode exclude thinking and
   tool parts and use the last assistant text before the next user request when
   no explicit final-answer phase exists.
5. Common credential patterns are redacted. The dialogue projection is capped at
   256 messages, 8 KiB per message and 64 KiB per source; the assembled agent
   section is capped at 60,000 characters, the full context at 175,000 characters,
   and the complete prompt at 180,000 characters.
6. Goalong starts one ephemeral, restricted Codex thread in a temporary empty
   workspace and sends the bounded context inline.
7. The app validates the strict five-line result, redacts it again, commits one
   canonical JSON report plus a regenerable Markdown mirror, and removes the
   temporary run directory on a best-effort basis.

Agent transcript bodies, titles, excerpts, commands, tools, and touched files are
never added to the Agent Activity index or daily report storage. They exist in
Goalong memory only while the source is being read and the prompt is assembled.
The saved report contains only the two scores, five derived lines, source counts,
model/effort proof fields, timestamps, and the bounded context digest.

Legacy normalized ChatGPT-export files are retained for backwards compatibility
if they already exist, but the Activity report does not read them and the Activity
UI no longer offers creation of a transcript copy.

## Scheduling and resource use

Automatic completed-day analysis is enabled by default unless the user has
explicitly turned it off.

- One tolerant, non-repeating timer is scheduled for 00:05 local time.
- The timer analyzes only the day that just ended.
- On app launch, one delayed catch-up checks yesterday only.
- Existing valid reports suppress duplicate work.
- There is no fifteen-minute polling loop and no unbounded historical backlog.
- Codex runs only for account checks or report generation, then its process is
  closed.
- Opening Activity loads metadata-only AI-conversation statistics; transcript
  bodies are read only for an explicit or scheduled report generation.

This schedule deliberately trades immediate midnight completion for lower churn
and a small buffer for the previous day's local journal to settle.

## Persistence bounds

New report Markdown is limited to 8 KiB and canonical JSON to 64 KiB. Each line
is limited to 512 UTF-8 bytes. Existing schema-v1 reports can still be read under
their legacy limits and appear as legacy reports until regenerated; every new
write must satisfy the schema-v2 five-line contract.

The canonical JSON is committed last. If that commit fails, the Markdown mirror
is restored or removed so readers never accept a partially advanced report.
Files are owner-only and storage operations reject symbolic links, unexpected
nodes, unstable source identity, and unsafe permissions.

## Codex security boundary

Goalong executes the located `codex` path directly with the fixed `app-server`
argument and a strict environment allow-list. It removes API keys, cloud
credentials, proxy secrets, and SSH-agent sockets; redirects `CODEX_HOME`; and
requires Codex initialization to report that exact isolated home.

The recap permission profile disables network tools, web search, skills, MCP,
login shells, and broad filesystem access. Goalong verifies the active permission
profile, runtime workspace roots, and ephemeral-thread response before sending
the prompt. Protocol lines, buffers, message counts, deferred queues, stderr, and
final output all have explicit hard limits.

The executable locator verifies executability but does not cryptographically
authenticate the selected Codex binary. A production distribution should bundle
or otherwise verify a reviewed signed helper.
