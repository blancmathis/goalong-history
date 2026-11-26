#!/bin/bash
# make perso hand-off: who owns a request in PersoUpdate/inbox/<id>/ (L1L2-02). Sourced by local_try.sh and
# by the tests; the app side is PersoUpdateFiles.claim (GoalongGuardCore/PersoSelfUpdate.swift).
# Ownership changes by one atomic rename of `request.json`, never by reading a state:
#   Goalong claims:     request.json -> claimed    (before its slow copy and signature check)
#   the script cancels: request.json -> cancelled  (only when Goalong did not answer in time)
# Exactly one rename succeeds. A claimed request is Goalong's until a final result: the script never falls back
# to the installer then. A cancelled request is never installed by Goalong.

# 0 = the script took the request back (fall back to the installer); 1 = Goalong had claimed it.
perso_handoff_cancel() { /bin/mv "$1/request.json" "$1/cancelled" 2>/dev/null; }

perso_handoff_read_state() { # REQUEST -> "state<TAB>reason" or nothing
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["state"]+"\t"+(d.get("reason") or ""))' \
    "$1/result.json" 2>/dev/null || true
}

# Waits for Goalong's answer. Sets PERSO_HANDOFF_STATE, PERSO_HANDOFF_REASON, PERSO_HANDOFF_CLAIMED (1 once
# Goalong owns it). Returns 10 when the script took the request back (it is removed): use the installer.
perso_handoff_wait() { # REQUEST ANSWER_SECONDS FINAL_SECONDS [ON_CLAIM_COMMAND]
  local request="$1" answer="$2" final="$3" on_claim="${4:-}" deadline state reason
  PERSO_HANDOFF_STATE="" PERSO_HANDOFF_REASON="" PERSO_HANDOFF_CLAIMED=""
  deadline=$(( $(date +%s) + answer ))
  while :; do
    IFS=$'\t' read -r state reason <<<"$(perso_handoff_read_state "$request")"
    case "$state" in refused|installed|rolled_back) break ;; esac
    if [[ -z "$PERSO_HANDOFF_CLAIMED" ]] && [[ -e "$request/claimed" || "$state" == claimed || "$state" == accepted ]]; then
      # Copy, signature, swap, restart and health check: the relauncher gives up after 120 s + 30 s + 45 s.
      PERSO_HANDOFF_CLAIMED=1; deadline=$(( $(date +%s) + final ))
      [[ -z "$on_claim" ]] || $on_claim
    fi
    if (( $(date +%s) >= deadline )); then
      [[ -n "$PERSO_HANDOFF_CLAIMED" ]] && break
      if perso_handoff_cancel "$request"; then /bin/rm -rf "$request"; return 10; fi
      # F5: the request vanished before any claim or answer: nothing can install it, use the installer.
      if [[ ! -e "$request/request.json" && ! -e "$request/claimed" && ! -e "$request/result.json" ]]; then
        /bin/rm -rf "$request"; return 10
      fi
      # Goalong claimed it just before: it is Goalong's now (seen on the next pass).
      sleep 0.2; continue
    fi
    sleep 0.2
  done
  PERSO_HANDOFF_STATE="$state" PERSO_HANDOFF_REASON="$reason"
  return 0
}
