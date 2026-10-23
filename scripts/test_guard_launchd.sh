#!/bin/bash
# Spec K, opt-in (GOALONG_LAUNCHD_TEST=1): proves the launchd behaviour the blocking guard relies on,
# with GoalongGuardTestHost only. No Goalong copy, no SMAppService, no window. It loads ONE temporary
# job (label ai.goalong.test.guard.<pid>) in the user's gui domain and always boots it out on exit.
# Checks: KeepAlive SuccessfulExit=false respawns after kill -9; exit 0 is not respawned; a Mach
# message wakes the job after exit 0 (M6); a replaced binary exits 75 and launchd starts the new one.
set -euo pipefail
if [[ "${GOALONG_LAUNCHD_TEST:-}" != 1 ]]; then
  echo 'SKIP: set GOALONG_LAUNCHD_TEST=1 to load a temporary launchd job for this test.'; exit 0
fi
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
LABEL="ai.goalong.test.guard.$$"
WORK="$(mktemp -d /tmp/goalong-guard-launchd.XXXXXX)"
WORK="$(cd "$WORK" && pwd -P)"
PLIST="$WORK/$LABEL.plist"
DOMAIN="gui/$(id -u)"
cleanup() {
  /bin/launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
wait_for() { # seconds, condition
  local limit=$(( $1 * 10 )) i=0; shift
  while (( i < limit )); do if eval "$1"; then return 0; fi; /bin/sleep 0.1; i=$((i + 1)); done
  return 1
}
started() { ls "$WORK/run" 2>/dev/null | grep -c '^started-' || true; }

(cd "$ROOT" && xcrun swift build --product goalong-guard-test-host >/dev/null)
HOST_BUILT="$(cd "$ROOT" && xcrun swift build --product goalong-guard-test-host --show-bin-path)/goalong-guard-test-host"
mkdir -p "$WORK/bin" "$WORK/run"
cp "$HOST_BUILT" "$WORK/bin/host"
python3 - "$PLIST" "$LABEL" "$WORK/bin/host" "$WORK/run" <<'PY'
import plistlib, sys
plist, label, program, run = sys.argv[1:]
with open(plist, 'wb') as stream:
    plistlib.dump({'Label': label, 'ProgramArguments': [program, '--label', label, '--dir', run],
                   'KeepAlive': {'SuccessfulExit': False}, 'RunAtLoad': True,
                   'MachServices': {label: True}, 'ProcessType': 'Standard', 'ThrottleInterval': 10}, stream)
PY
/bin/launchctl bootstrap "$DOMAIN" "$PLIST"
wait_for 5 '[[ "$(started)" -ge 1 ]]' || fail 'the job did not start at load'

# 1. kill -9 is respawned (after the 10 s throttle at most).
pid="$(head -1 "$WORK/run/started-1")"
kill -9 "$pid"
wait_for 15 '[[ "$(started)" -ge 2 ]]' || fail 'kill -9 was not respawned'
echo 'PASS: kill -9 respawned'

# 2. exit 0 is not respawned.
touch "$WORK/run/exit-zero"
/bin/sleep 12
count="$(started)"
/bin/sleep 12
[[ "$(started)" == "$count" ]] || fail 'exit 0 was respawned'
echo 'PASS: exit 0 not respawned'

# 3. M6: a Mach message wakes the job after exit 0 (the app's ping relies on it).
rm -f "$WORK/run/exit-zero"
cat > "$WORK/ping.swift" <<'SWIFT'
import Foundation
import XPC
let connection = xpc_connection_create_mach_service(CommandLine.arguments[1], nil, 0)
xpc_connection_set_event_handler(connection) { _ in }
xpc_connection_resume(connection)
let message = xpc_dictionary_create(nil, nil, 0)
let reply = xpc_connection_send_message_with_reply_sync(connection, message)
exit(xpc_get_type(reply) == XPC_TYPE_DICTIONARY ? 0 : 1)
SWIFT
xcrun swiftc "$WORK/ping.swift" -o "$WORK/bin/ping" >/dev/null
"$WORK/bin/ping" "$LABEL" || fail 'the Mach ping got no reply'
[[ "$(started)" -gt "$count" ]] || fail 'the Mach ping did not start the job'
echo 'PASS: Mach message wakes the job after exit 0'

# 4. A replaced binary exits 75 and launchd starts the new one (after the throttle).
count="$(started)"
cp "$WORK/bin/host" "$WORK/bin/host.new" && mv -f "$WORK/bin/host.new" "$WORK/bin/host"
wait_for 20 '[[ "$(started)" -gt "$count" ]]' || fail 'the replaced binary was not restarted'
echo 'PASS: replaced binary restarted'
echo 'Guard launchd tests passed.'
