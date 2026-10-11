# Fast deploy: merge-to-published in ≤ 10 min (2026-10-11)

Historical initial proposal (superseded by the Revision below): builds run on the owner's Mac (Apple M4 Pro, 14 cores) as a GitHub self-hosted runner. Target: PR checks ≤ ~7 min, merge → update published ≤ ~3 min. No check is removed; duplicates are.

## Measured today (run 38140195716 / 38140195867)
- PR "macOS quality gate": 22 min, sequential (tests 7, journeys/renders 4, app bundle 8).
- Same gate again on push to main: 20 min (duplicate).
- "Continuous Community macOS release": 34 min = universal build 21 (re-runs tests, arm64 then x86_64, no cache) + appcast with 3 Sparkle deltas 10.
- No `actions/cache` anywhere.

## Target design
1. Self-hosted runner on this Mac
   - Official actions/runner in `~/actions-runner-goalong-history`, launchd service as the current user, labels `self-hosted, macOS, ARM64, goalong-mac`. Register with `gh api` registration token.
   - Public repo: self-hosted jobs only for `push` to main, `workflow_dispatch`, and PRs whose head repo == this repo (`github.event.pull_request.head.repo.full_name == github.repository`). Fork PRs fall back to `macos-15`. Set repo setting: fork PR workflows require approval for all outside contributors.
   - Persistent workspace = free incremental cache (`.build`, SwiftPM). Clean temp keychains/artifacts each run; never leave secrets on disk.
2. One build per commit
   - PR: parallel jobs on the Mac: tests ‖ universal release build (arm64 ‖ x86_64 concurrently, then lipo) signed with the release identity ‖ journeys/renders. Upload the signed universal ZIP as an artifact keyed by tree SHA.
   - Merge → release: if an artifact for the same tree exists (squash/rebase merge keeps the tree), reuse it: verify signature/arch/identity, build number/version handling must still be right (decide: stamp version at PR build from predicted rolling number, or re-stamp + re-sign only, no recompile). Fallback: full build if no artifact.
   - Drop the duplicate quality gate on push to main when the tree already passed on the PR.
   - Release build no longer re-runs tests (`LOCALHISTORY_RUN_TESTS: 0`) when the tree passed on the PR; require CI green before merge (branch protection).
3. Sparkle deltas off the critical path
   - Publish full archive + authenticated feed first; generate deltas in a follow-up job, then republish the feed. Feed must stay valid and signed at every moment.
4. Keep every existing security property: signing identity pin, appcast auth, provenance attestation, "refuse superseded/non-main commit", privacy audit.

## Acceptance
- Measure on real runs: PR wall time, merge → "Publish authenticated feed last" wall time; total ≤ 10 min.
- An installed app sees the update (same check as the last release).
- Fork-PR path still runs on GitHub-hosted runners and cannot reach the self-hosted runner.

## Revision 2026-10-11 (after GPT Pro 812713) — supersedes §1 "Self-hosted runner"
Owner decision: NO GitHub runner on the Mac (pre-job hook does not stop `always()`/`failure()` steps of hostile YAML; repo is public). Unregister runner `goalong-mac`, remove `~/actions-runner-goalong-history` service and the hooks.
Replacement = local auto-deploy:
- launchd agent (current user) polls `origin/main` every ~60 s (git ls-remote / fetch only; no inbound access). New main SHA → run the deploy command once per SHA (lock, state file, log; skip if superseded).
- Deploy command (also runnable by hand): clean checkout of exact SHA in a dedicated dir with persistent per-arch scratch; tests ‖ arm64 build ‖ x86_64 build in parallel (bounded CPU), lipo, sign with the pinned local identity WITHOUT changing keychain search list, full bundle/identity/CLI-per-slice verification, then publish through the existing explicit local-signature path (`publish_local_release.sh` / `prepare-local-signed-release.yml` / `signed_stage`), full archive + feed first, deltas afterwards off the critical path. Keep every check and `verify_published_update.sh`.
- Motion/UI tests that change system prefs stay on GitHub hosted VMs (PR CI), not on the Mac.
- PR CI stays on GitHub hosted runners; parallelize/caching there is a bonus, not required.
- Apply Pro's design where relevant: `~/.gpt-pro/tasks/812713/response.md` §3 (version monotonicity, CLI plist per slice, hash-addressed plist for warm cache), §6 (scratch, signing, fixture cleanup), §7 (single writer, full then deltas, no Sparkle global cache wipe). Feed atomicity: keep current fail-closed behaviour, out of scope.
- Single writer: the hosted `continuous-release.yml` must no longer publish on push to main in parallel with the local deploy (make it manual/fallback, e.g. when the Mac deploy has not published a SHA within N min); never two writers of the feed.
Acceptance: merge → authenticated feed live and `verify_published_update.sh` OK in ≤ 10 min, measured on a real merge (warm cache); report cold run too.
