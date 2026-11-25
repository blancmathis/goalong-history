---
name: goalong-day
description: "Keep Goalong's guided agenda and parallel agent processes current during explicitly requested project or orchestrated work. Use when a task starts, needs a human answer, is ready for review, finishes or fails, or when preparing an authorized daily plan. Publish compact explicit state through the local CLI; never infer passive tracking or block real work when Goalong is unavailable."
---

# Goalong: one human agenda, parallel processes

Goalong owns the day's actions, slots and process states. Project documentation owns knowledge and decisions; link to it. The coach may retain preferences and reasons. Do not create competing editable task lists or copy transcripts into Goalong.

## Scope

Use for substantive project work or a requested plan. A short answer, unrelated lookup or read-only delegated review needs no new process. Honor the parent's write scope: let the parent report your state when Goalong writes are outside it. If the orchestrator already reports the process, do not create a duplicate.

For an authorized task, reporting its explicit lifecycle is part of the workflow. Do not ask at every transition. A schedule does not authorize new goals, launching agents, changing blockers, contacting anyone or publishing work. Existing task permissions still apply.

The CLI never launches Goalong. If missing, disabled, unavailable or slow, continue the real task. No polling, daemon or repeated repair attempts. Mention a material reporting failure once; do not make a daily check-in into troubleshooting.

## Read before writing

Default CLI: `/Applications/Goalong History.app/Contents/MacOS/goalong`. This package's `scripts/goalong_plan.py` wraps it using Python 3's standard library, with no shell interpolation. `--cli ABSOLUTE_PATH` overrides the install path.

Use an explicit local day `YYYY-MM-DD`. Read `plan show DAY` or `python3 /path/to/goalong-day/scripts/goalong_plan.py snapshot --day DAY`. A compact coaching summary is not a write payload.

Inspect `agendaDiagnostics.conflicts` and `agendaDiagnostics.unplaced` before calling the day feasible. These read-only diagnostics do not modify a plan. Keep impossible blocks visible to reschedule. New agendas/templates must use the Mac's current calendar time zone; do not silently change historical plans' zones.

IDs are stable UUIDs. Reuse an existing process by its ID or verified external task ID. Generate an ID once for a new process and retain it in the task note; do not create one every turn.

## Report only known states

| Status | Required evidence |
|---|---|
| `queued` | Accepted task, not started. |
| `running` | Work actually started or resumed. |
| `waitingForYou` | A concrete human decision or action blocks progress. |
| `readyForReview` | Work and relevant checks await the responsible reviewer. |
| `done` | The actual completion criteria are met. |
| `failed` | Work stopped after a concrete failure. |
| `cancelled` | User or orchestrator explicitly cancelled it. |

Only short title/project/agent labels, external ID, context URL and current question/answer. No tokens, raw activity, medical details or transcripts. A question states the decision needed and, when useful, a recommended choice. Answers must reflect an actual decision. Recording an answer leaves `waitingForYou` until the worker explicitly acknowledges resuming. `readyForReview` is not verified `done`. Agent elapsed time is not human work time.

Prepare from a fresh full plan; this command prints JSON without writing:

```bash
python3 /path/to/goalong-day/scripts/goalong_plan.py process \
  --day YYYY-MM-DD --id PROCESS_UUID --title "Implement the accepted change" \
  --agent "T3 worker" --external-id TASK_ID --status running \
  --actor "T3 worker" > /private/task-directory/goalong-operation.json
```

Use a task-owned private path. A later transition uses the same process ID and a new operation. Optional flags: `--question`, `--answer`, `--context-url`, `--project`, `--clear-question`, `--clear-answer`. For every new or changed question, pass `--clear-answer` together with `--question` and `--status waitingForYou`; a previous answer must never appear to answer a different question. Clear obsolete questions explicitly. `process` preserves the other fields of that process and leaves unrelated processes untouched. To record an answer use `--status waitingForYou`; only the worker later reports `running`.

Apply the saved operation once:

```bash
python3 /path/to/goalong-day/scripts/goalong_plan.py apply \
  --file /private/task-directory/goalong-operation.json
```

## Prepare the human day

Several projects and agents may run together. The human agenda describes the user's next action: launch a group, edit docs, create a video, answer questions, review results, or ordinary solo work. One human attention lane does not make background processes sequential. Do not impose parallel work on a user who prefers one task.

Group nonurgent questions into coordination windows. Preserve creative work unless a genuinely blocking decision or the user changes the priority. Respect fixed anchors, buffers and the chosen end of day. Guided reminders fire once per slot; `reminderLimit` defaults to 8 per day and is adjustable from 1 to 32. Ensure the user's chosen limit covers the intended anchors, especially the evening check-in, without inventing extra reminders. Work that no longer fits remains visibly unscheduled; do not stretch the day or mark it complete.

Human items support `nextAction`, `doneWhen`, `actionKind` (`work`, `launch`, `coordination`, `review`, `routine`), `contextURL`, `processIDs`. Bounds: 10 human items, 64 processes, 64 slots. Use `plan patch`; upserts are complete objects, so merge changed fields into the fresh full object. `agenda` replaces the full agenda: preserve unrelated slots. Do not use legacy `plan set` on a shared live plan.

```bash
python3 /path/to/goalong-day/scripts/goalong_plan.py prepare \
  --day YYYY-MM-DD --if-revision REVISION --file patch.json \
  > /private/task-directory/goalong-operation.json
```

The same prepare/apply flow supports `--kind reflow` or `--kind undo` without `--file`. Undo requires an appropriate request; it is not conflict recovery. A recurring `routine` has no linked project item and creates no task commitments by itself. Reporting a process never requires replacing the routine.

## Concurrency and uncertain outcomes

- On success, inspect returned state/revision before claiming a change.
- `conflict`: reread the complete plan, preserve concurrent changes, prepare a new operation with a new request ID. At most one conflict refresh for a routine status report; then continue work and retain a concise pending report.
- `requestConflict`: an ID was reused with changed content. Inspect the receipt; do not alter or resend that operation. Use a new ID only for a genuinely new operation.
- `outcomeUnknown`, write timeout or unreadable write reply: do not regenerate or blindly retry. Read `plan show DAY` and inspect `receipts` for the same request ID. A matching receipt records the write. If absent, retain the exact operation for later reconciliation. Identical explicit replay is idempotent while the receipt remains retained. The helper never automatically retries.

No automatic T3 observation exists. Only explicit reports by agents that load this skill appear in Goalong. Already running threads may need to read it once; do not claim that all threads are now monitored.
