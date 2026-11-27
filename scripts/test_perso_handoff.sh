#!/bin/bash
# L1L2-02: make perso hand-off (scripts/perso_handoff.sh). Goalong claims a request by renaming request.json to
# `claimed`; the script cancels by renaming it to `cancelled`. Only one rename wins. A claimed request never
# falls back to the installer, even when the claim lands after the 20 s answer window. Fake Goalong = a subshell.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/goalong-handoff-test.XXXXXX")"
trap '/bin/rm -rf "$T"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
# shellcheck source=perso_handoff.sh
source "$SCRIPT_DIR/perso_handoff.sh"
new_request() { /bin/rm -rf "$T/$1"; /bin/mkdir -p "$T/$1"; echo '{}' >"$T/$1/request.json"; echo "$T/$1"; }
app_claim() { /bin/mv "$1/request.json" "$1/claimed" 2>/dev/null; } # what PersoUpdateFiles.claim does
result() { printf '{"state":"%s","reason":"%s"}' "$2" "${3:-}" >"$1/result.json.tmp" && /bin/mv "$1/result.json.tmp" "$1/result.json"; }

# 1. No answer in the window: the script takes the request back (rc 10), and a late claim then fails.
r="$(new_request silent)"; set +e; perso_handoff_wait "$r" 1 5; rc=$?; set -e
[[ "$rc" == 10 ]] || fail "silent Goalong: rc $rc, want 10 (installer)"
[[ ! -e "$r" ]] || fail "cancelled request left behind"
r="$(new_request silent2)"; perso_handoff_cancel "$r" || fail "cancel of an unclaimed request"
app_claim "$r" && fail "Goalong claimed a cancelled request"

# 2. Claimed before the window ends, final answer later: no fallback, final state returned.
r="$(new_request claimed)"
( /bin/sleep 0.3; app_claim "$r"; /bin/sleep 1.5; result "$r" installed ) &
set +e; perso_handoff_wait "$r" 1 10; rc=$?; set -e
wait
[[ "$rc" == 0 && "$PERSO_HANDOFF_STATE" == installed && "$PERSO_HANDOFF_CLAIMED" == 1 ]] \
  || fail "claimed request: rc $rc state '$PERSO_HANDOFF_STATE' claimed '$PERSO_HANDOFF_CLAIMED'"

# 3. Claimed first, then the script's cancel loses: the request stays Goalong's.
r="$(new_request race)"; app_claim "$r" || fail "claim"
perso_handoff_cancel "$r" && fail "the script cancelled a claimed request"
[[ -e "$r/claimed" && ! -e "$r/cancelled" ]] || fail "race markers"

# 4. The claim lands at the very end of the window, before any result: the cancel loses, the script keeps
#    waiting for Goalong's final answer instead of falling back (the old state-reading code fell back here).
#    Deterministic: the fake Goalong claims inside the script's cancel, just before its rename (a sleep-based
#    claim at 0.9 s raced the whole-second deadline of `date +%s` and failed at random).
r="$(new_request late)"
eval "real_$(declare -f perso_handoff_cancel)"
perso_handoff_cancel() { app_claim "$1"; ( /bin/sleep 0.5; result "$1" rolled_back "boom" ) & real_perso_handoff_cancel "$1"; }
set +e; perso_handoff_wait "$r" 1 10; rc=$?; set -e
wait
eval "$(declare -f real_perso_handoff_cancel | /usr/bin/sed '1s/^real_//')"; unset -f real_perso_handoff_cancel
[[ "$rc" == 0 && "$PERSO_HANDOFF_STATE" == rolled_back && "$PERSO_HANDOFF_REASON" == boom ]] \
  || fail "late claim: rc $rc state '$PERSO_HANDOFF_STATE' (must not fall back to the installer)"

# 5. F5: the request folder vanishes before any claim: rc 10 at the deadline, no busy loop that never ends.
r="$(new_request vanished)"; /bin/rm -rf "$r"
( perso_handoff_wait "$r" 1 5 ) & waiter=$!
( /bin/sleep 6; kill "$waiter" 2>/dev/null ) & killer=$!
set +e; wait "$waiter"; rc=$?; set -e
kill "$killer" 2>/dev/null || true; wait "$killer" 2>/dev/null || true
[[ "$rc" == 10 ]] || fail "vanished request: rc $rc, want 10 (the wait never ended)"

# 6. local_try uses this contract.
grep -F 'perso_handoff_wait "$request"' "$SCRIPT_DIR/local_try.sh" >/dev/null || fail "local_try does not use perso_handoff_wait"
echo "test_perso_handoff: OK"
