# Selected-day token usage

History → AI conversations displays locally observed tokens independently of conversation search filters. This is deterministic parsing, with no model call, network request, token purchase or credential access. Counters live only in bounded transient summaries; the index does not encode them or transcript bodies.

Supported sources:

- Codex JSONL: `event_msg/token_count`, `info.last_token_usage`, cumulative `total_token_usage`, model from `turn_context`.
- Claude Code JSONL: assistant `message.usage`, deduplicated by message ID and request ID.
- OpenCode SQLite message rows through the existing read-only adapter: `tokens`, `time`, `modelID`. Parts do not add usage. Legacy JSON storage is not covered by this numeric adapter.

Codex repeated cumulative snapshots contribute nothing. An advanced snapshot uses the last request counters when present, otherwise a nonnegative cumulative delta. A first cumulative-only snapshot is unknown, rather than attributing earlier work to today. Counter resets use the last request when present; an ambiguous reset is skipped. Daily projection observes preceding counters/model context in its existing read window. A bounded header read recognizes a fork even when the projection starts near EOF. Explicit forks are excluded and marked partial because replayed prefixes can have rewritten timestamps; their new work is currently also omitted. Independent subagent logs remain eligible. Equivalent Codex timestamp/counter events across copies are deduplicated; exceptionally identical independent events may be collapsed.

Dates are attributed to the usage event, using the selected calendar day's half-open interval in the Mac timezone, including DST. Source discovery, missing files, read limits and the existing 256-record transient cache constrain coverage. The UI reports observed totals, not account-wide completeness. Each source keeps at most 4096 numeric events, within the existing transient memory budget. Missing fields remain unknown. Claude input is normalized to include cache read and creation; Codex cache and reasoning are subsets and are never added again. OpenCode total is shown only when explicitly recorded because provider output/reasoning conventions vary.

No prices are used: token observations cannot establish API charges, subscription invoices, quota consumption or credits. Refresh uses the existing bounded single-worker scan, without a second scanner or persisted conversation archive.

## Primary-source research

Reviewed [ccusage](https://github.com/ccusage/ccusage) at commit `05cd43670fe2388a888812257f1d154b2d8870fe`:

- [Codex parser](https://github.com/ccusage/ccusage/blob/05cd43670fe2388a888812257f1d154b2d8870fe/rust/adapters/codex/src/parser.rs): repeated cumulative snapshots, last-request fallback, replayed fork caveats.
- [Claude daily loader](https://github.com/ccusage/ccusage/blob/05cd43670fe2388a888812257f1d154b2d8870fe/rust/adapters/claude/src/daily.rs): message/request deduplication and daily timestamps.
- [OpenCode parser](https://github.com/ccusage/ccusage/blob/05cd43670fe2388a888812257f1d154b2d8870fe/rust/adapters/opencode/src/parser.rs): message token/cache fields.
- [MIT license](https://github.com/ccusage/ccusage/blob/05cd43670fe2388a888812257f1d154b2d8870fe/apps/ccusage/LICENSE), copyright 2025 ryoppippi.

This is an independent Swift implementation informed by those approaches. No ccusage code is vendored and no runtime dependency is added.

The runtime retains one numeric snapshot for the selected day independently of the transcript cache. The card shows its analysis time; refresh or re-enter the AI page to recompute it. Changing the selected day clears it immediately. A runtime regression test explicitly discards all transcript summaries and verifies that tokens remain visible, then verifies day-change clearing.

## Verification in this implementation session

- Initial complete Swift suite: 832 tests, 7 opt-in/environment skips, zero failures; 13 Python site-policy tests also passed through the existing build script.
- Final targeted suite after the snapshot fix: 26 tests, 2 opt-in skips, zero failures. This includes parsing, date/DST boundaries, duplicate files, cache normalization, unknown counters, SQLite message-only extraction and runtime snapshot retention.
- Opt-in read-only Codex smoke test: 27 real events / 1,987,224 tokens in a bounded source sample, without printing source text.
- Native installed-panel verification observed 410,742,698 tokens across nine readable indexed Codex sources, with a tenth unavailable source explicitly marked missing. An independent streaming calculation shortly afterwards observed 411,780,095 across 2,889 events in the same candidate set; active logs continued growing, so these are time-specific observations rather than a frozen equality assertion.
- Claude and OpenCode have synthetic parser/SQLite coverage; no claim of live provider usage completeness is made.

Final installed verification: `/Applications/Goalong History.app`, version 0.6.18, executable SHA-256 `488a759b219e7fb17594f0babfc02584fdb9e8282e77ab5baf0e0007cd65211f`, identical to the built bundle. The installer verified the unchanged designated signing requirement and retained rollback binaries in `/tmp/goalong-before-usage.INchLt` (original 0.6.17) and `/tmp/goalong-before-usage.ZVqh10` (first candidate). Native screenshot/AX verification showed 415,144,978 observed tokens, an analysis timestamp, disclosure details and the pre-existing missing source warning. Recording locally remained enabled. No website/export integration files were changed by this task.
