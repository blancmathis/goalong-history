# Sourced by dev_app.sh (and scripts/test_dev_app.sh). One make dev install/data/quit step at a time
# across every worktree. flock(2) on file descriptor 9: the kernel releases the lock when the holder
# exits, even when killed, so there is no stale lock to take over and no takeover race.
# Needs GLOBAL_LOCK (lock file path). Sets HAVE_GLOBAL_LOCK=1. GOALONG_DEV_LOCK_WAIT: seconds (default 600).
acquire_global_lock() {
  local waited=0 holder limit="${GOALONG_DEV_LOCK_WAIT:-600}" status
  mkdir -p "$(dirname "$GLOBAL_LOCK")"
  exec 9>>"$GLOBAL_LOCK"
  while :; do
    status=0
    # perl locks the open file description shared with this shell's fd 9; the lock outlives perl.
    /usr/bin/perl -MFcntl=:flock -e 'open(my $f, ">&=", 9) or exit 2; flock($f, LOCK_EX | LOCK_NB) or exit 1' || status=$?
    [[ "$status" != 0 ]] || break
    [[ "$status" == 1 ]] || { echo "Cannot lock $GLOBAL_LOCK." >&2; exit 1; }
    holder="$(cat "$GLOBAL_LOCK.pid" 2>/dev/null || true)"
    if (( waited == 0 )); then echo "Waiting for another make dev (PID ${holder:-?}) to finish its install step..."; fi
    if (( waited >= limit )); then
      echo "Still locked after ${limit} s: $GLOBAL_LOCK (PID ${holder:-?})." >&2; exit 1
    fi
    sleep 1; waited=$((waited + 1))
  done
  HAVE_GLOBAL_LOCK=1
  echo "$$" >"$GLOBAL_LOCK.pid"
}
