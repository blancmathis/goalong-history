#!/bin/bash
# T-059 lot 5: the blocking guard agent (reused for the reopening after a forced quit). Builds nothing,
# loads nothing: the plist build_app_core.sh writes is rendered into a temporary folder, linted and read.
# Then the installer side: continuity never refuses --unregister-guard, which runs before every bootout.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
WORK="$(mktemp -d /tmp/goalong-guard-plist-test-XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

BUILD="$ROOT/scripts/build_app_core.sh"
for BUNDLE_ID in ai.goalong.localhistory ai.goalong.localhistory.dev; do
  GUARD_LABEL="$BUNDLE_ID.blocking-guard"
  PLIST="$WORK/$GUARD_LABEL.plist"
  # The heredoc between `<<PLIST` and `PLIST`, with the two variables build_app_core.sh expands.
  /usr/bin/awk '/LaunchAgents\/\$GUARD_LABEL\.plist" <<PLIST$/ {on=1; next} on && /^PLIST$/ {exit} on {print}' "$BUILD" \
    | /usr/bin/sed -e "s/\$GUARD_LABEL/$GUARD_LABEL/g" -e "s/\$BUNDLE_ID/$BUNDLE_ID/g" > "$PLIST"
  [[ -s "$PLIST" ]] || fail "guard plist heredoc not found in build_app_core.sh"
  /usr/bin/plutil -lint "$PLIST" >/dev/null || fail "$GUARD_LABEL: plutil -lint"
  read_key() { /usr/bin/plutil -extract "$1" raw -o - "$PLIST" 2>/dev/null || echo "<missing>"; }
  [[ "$(read_key Label)" == "$GUARD_LABEL" ]] || fail "$GUARD_LABEL: Label"
  [[ "$(read_key BundleProgram)" == Contents/MacOS/goalong-blocking-guard ]] || fail "$GUARD_LABEL: BundleProgram"
  # exit 0 (not armed, allowed « Quitter ») leaves it stopped; a kill or a crash brings it back.
  [[ "$(read_key KeepAlive.SuccessfulExit)" == false ]] || fail "$GUARD_LABEL: KeepAlive must be {SuccessfulExit=false}"
  [[ "$(/usr/bin/plutil -extract KeepAlive raw -o - "$PLIST" 2>/dev/null || true)" != true ]] || fail "$GUARD_LABEL: KeepAlive true would loop"
  [[ "$(read_key RunAtLoad)" == true ]] || fail "$GUARD_LABEL: RunAtLoad"
  [[ "$(/usr/bin/plutil -extract "MachServices" json -o - "$PLIST")" == "{\"$GUARD_LABEL\":true}" ]] \
    || fail "$GUARD_LABEL: MachServices (the app's ping starts it on demand)"
  [[ "$(read_key LimitLoadToSessionType)" == Aqua ]] || fail "$GUARD_LABEL: Aqua session only"
  [[ "$(read_key ThrottleInterval)" == 10 ]] || fail "$GUARD_LABEL: ThrottleInterval"
done

# Continuity is the installed Goalong's only: the guard ignores it under any other bundle id.
grep -qF 'environment.continuityAllowed = identity.bundleIdentifier == GuardIdentity.releaseBundleIdentifier' \
  "$ROOT/Sources/GoalongGuard/main.swift" || fail "the guard must allow continuity for the release bundle only"
# Installers: --unregister-guard is refused only by guard-until (never by guard-continuity), removes the
# continuity file and leaves the override token while it exists, before every launchctl bootout.
CLIENT="$ROOT/Sources/LocalHistoryApp/Blocking/GoalongGuardClient.swift"
grep -qF 'static func isRefused(marker: GuardMarker, now: Date, environment: [String: String]) -> Bool {' "$CLIENT" \
  || fail "isRefused must depend on guard-until only"
grep -qF 'writesOverride(marker: marker, now: Date(), continuity: files.continuityExists())' "$CLIENT" \
  || fail "--unregister-guard must leave guard-override while guard-continuity exists"
grep -qF 'files.removeContinuity()' "$CLIENT" || fail "--unregister-guard must remove guard-continuity"
for script in install.sh uninstall.sh scripts/install_from_source.sh; do
  body="$(/usr/bin/awk '/^release_blocking_guard\(\) *\{/ {on=1} on {print} on && /^\}/ {exit}' "$ROOT/$script")"
  [[ -n "$body" ]] || fail "$script: release_blocking_guard not found"
  [[ "${body%%launchctl bootout*}" == *'--unregister-guard'* ]] || fail "$script: --unregister-guard must run before the bootout"
done
echo "guard agent plist and installer checks: ok"
