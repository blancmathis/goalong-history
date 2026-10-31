#!/usr/bin/env bash
# seed:storage-failed (J-0996): « Enregistrement interrompu » banner with « Signaler le problème… ». Env: DATA. Exit 3 = journal handle opened at first write after launch. Throwaway CI runner only.
set -u
EV="$DATA/events"; STATE="$DATA/.t046-storage-failed.modes"
day() { date +%Y-%m-%d; }
case "${1:-}" in
  seed)
    # Banner: GoalongAttentionBanner.swift:25 notice = .storage(kind) when recording is expected and runtime.storageFailure != nil; for kind != .diskFull
    # actions() :99-103 shows « Signaler le problème… » (diskFull shows « Gérer le stockage… » instead, so the failure must NOT be ENOSPC).
    # Failure kind: StorageHealth.failureKind StorageHealth.swift:24-29 maps EACCES/EPERM/EROFS to .permissionDenied; set by EventRecorder.swift:690-694 -> CaptureHealth.swift:650.
    # Append path: JSONLStore.swift:1460-1461 opens events/<local yyyy-MM-dd>.jsonl O_RDWR|O_APPEND (AppPaths.swift:1880; dir AppPaths.swift:83): file mode 000 -> EACCES at the first event write.
    # Directory mode 500 also blocks creating the file when today's journal does not exist yet.
    mkdir -p "$EV"; F="$EV/$(day).jsonl"
    { stat -f 'dir %Lp' "$EV"; if [[ -e "$F" ]]; then stat -f 'file %Lp' "$F"; else echo "nofile"; fi; echo "$(day)"; } > "$STATE"
    [[ -e "$F" ]] && chmod 000 "$F"
    chmod 500 "$EV"
    exit 3 ;;
  unseed)
    # Restore the recorded modes (journal name saved in the state file, in case midnight passed), so the next row records normally.
    [[ -f "$STATE" ]] || exit 0
    d="$(sed -n 3p "$STATE")"; F="$EV/$d.jsonl"
    chmod "$(sed -n 1p "$STATE" | cut -d' ' -f2)" "$EV"
    if [[ "$(sed -n 2p "$STATE")" == file* ]]; then chmod "$(sed -n 2p "$STATE" | cut -d' ' -f2)" "$F"; fi
    # A file the app could not create stays absent; a 0-byte one created during the row is left (the app owns it).
    rm -f "$STATE"
    exit 0 ;;
  *) echo "usage: $0 seed|unseed" >&2; exit 2 ;;
esac
