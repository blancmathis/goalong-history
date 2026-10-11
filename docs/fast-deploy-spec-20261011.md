# Fast deploy: merge-to-published in ≤ 10 min (2026-10-11)

Owner decision: builds run on the owner's Mac (Apple M4 Pro, 14 cores) as a GitHub self-hosted runner. Target: PR checks ≤ ~7 min, merge → update published ≤ ~3 min. No check is removed; duplicates are.

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
