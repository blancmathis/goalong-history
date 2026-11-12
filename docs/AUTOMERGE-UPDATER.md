# Auto-merge updater (merge-queue substitute)

GitHub merge queues need an organisation repository; `blancmathis/goalong-history`
belongs to a user. `main` keeps `strict: true`. Since T-058 (2026-11-12) the only required check is
`fast-gate` (~1 min, Linux); the full suite (`build-test-package`, `verify`) runs
once per main commit, and publication waits for it on that exact commit.
Cost of strict: every move of `main` leaves the other PRs behind, and someone
had to click "Update branch". This agent does that click.

## Rule (each run, every 30 s)
1. Open PRs on `main` with auto-merge enabled, same repository, not draft.
   Fork PRs, drafts and PRs without auto-merge are never touched.
2. If one is already up to date with `main` and a required check is still
   pending (activity within 90 min), it is in flight: wait. Green but blocked
   (review, conversation) or stale: skipped, next PR considered. One PR at a time, so a merge never re-stales a PR that is
   mid-run.
3. Otherwise: the oldest (auto-merge enable time) PR that is behind `main`, not
   conflicting, with no failed required check, gets
   `PUT /pulls/{n}/update-branch` with its expected head SHA. Its checks re-run
   and auto-merge merges it when green.

4. While `build-test-package` or `verify` failed on `main`'s head: hold, no
   update. A red `main` is fixed (or reverted) before more PRs land.

It never merges and never enables auto-merge. Failed or conflicting PRs wait for
a human.

## Why a launchd agent on the Mac
A push made with `GITHUB_TOKEN` from a workflow does not start workflows, so a
GitHub Actions job would update the branch but the required checks would never
run. A PAT or GitHub App secret would fix that but needs a new secret from the
owner. The agent uses the owner's existing `gh` login, so the update is a normal
user push and the checks run. Cost: when the Mac sleeps, updates wait until it
wakes. Priority: `ProcessType=Background`, `Nice=10`, `LowPriorityIO`.

## Commands
- Dry run: `python3 scripts/automerge_updater.py --dry-run`
- Install and start: `python3 scripts/install_automerge_updater.py --start`
- Remove: `python3 scripts/install_automerge_updater.py --remove` (deletes agent and controller copy; the state dir with logs stays)
- Safety: no required checks found, or `gh` logged out/offline → no update; one log line per distinct error; logs are capped.
- Logs: `~/Library/Application Support/GoalongAutomergeUpdater/agent.log`
  (one line per change of decision, plus every update).
- Tests: `python3 scripts/test_automerge_updater.py`
