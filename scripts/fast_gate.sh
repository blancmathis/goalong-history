#!/usr/bin/env bash
# PR fast gate (T-058): the only check that blocks a merge. Linux-safe, ~30 s.
# Script syntax, release/update/privacy policies and their self tests run in parallel.
# The Swift suite, renders, app build, gallery and release build run after the merge on
# main (macos.yml, motion-integration.yml) and nightly; publication waits for them.
set -uo pipefail
cd "$(dirname "$0")/.."
LOGS="$(mktemp -d)"
trap 'rm -rf "$LOGS"' EXIT

CHECKS=(
  "syntax:bash -n Install.command Uninstall.command install.sh uninstall.sh && find scripts -type f -name '*.sh' -print0 | xargs -0 -n1 bash -n && python3 -m py_compile scripts/*.py"
  "privacy-audit:bash scripts/audit_privacy_boundaries.sh"
  "update-policy:python3 scripts/test_update_policy.py"
  "permission-policy:python3 scripts/test_permission_requirement_policy.py"
  "publication-policy:python3 scripts/test_release_publication_policy.py"
  "deferred-deltas:python3 scripts/test_deferred_release_deltas.py"
  "background-continuity:python3 scripts/test_background_continuity.py"
  "presigned-release:python3 scripts/test_prepare_presigned_release.py"
  "site-submission:python3 scripts/test_site_submission_policy.py"
  "automerge-updater:python3 scripts/test_automerge_updater.py"
  "motion-fixture:python3 scripts/test_motion_fixture_policy.py"
  "ambiance-privacy:python3 scripts/test_ambiance_privacy_policy.py"
  "parity-probe:python3 scripts/test_probe_computer_history_parity.py && bash scripts/test_probe_computer_history_parity.sh"
  "history-memory:bash scripts/test_check_computer_history_memory.sh"
  "build-number:bash scripts/test_build_number_policy.sh"
  "cli-link:bash scripts/test_install_cli_link.sh"
  "skip-report:bash scripts/test_skip_report.sh"
  "leaked-prefs:bash scripts/test_clean_leaked_test_prefs.sh"
  "gallery-script:bash scripts/test_gallery_script.sh"
  "runtime-measure:bash scripts/test_measure_computer_history_runtime.sh"
)

declare -A PIDS STARTS
for entry in "${CHECKS[@]}"; do
  name="${entry%%:*}"
  ( start=$(date +%s); bash -c "${entry#*:}" >"$LOGS/$name.log" 2>&1; status=$?
    echo "$status $(( $(date +%s) - start ))" >"$LOGS/$name.status" ) &
  PIDS[$name]=$!
done
wait

failed=0
printf '| Check | Result | Seconds |\n|---|---|---|\n' >"$LOGS/summary.md"
for entry in "${CHECKS[@]}"; do
  name="${entry%%:*}"
  read -r status seconds <"$LOGS/$name.status"
  if [[ "$status" == 0 ]]; then result=ok; else result="FAILED ($status)"; failed=1; fi
  printf '| %s | %s | %s |\n' "$name" "$result" "$seconds" >>"$LOGS/summary.md"
  if [[ "$status" != 0 ]]; then
    echo "::group::$name failed"; tail -n 60 "$LOGS/$name.log"; echo "::endgroup::"
  fi
done
cat "$LOGS/summary.md"
[[ -n "${GITHUB_STEP_SUMMARY:-}" ]] && cat "$LOGS/summary.md" >>"$GITHUB_STEP_SUMMARY"
exit "$failed"
