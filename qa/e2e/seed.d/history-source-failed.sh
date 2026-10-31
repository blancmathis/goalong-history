#!/usr/bin/env bash
# seed:history-source-failed (J-0765): Historique > Ce Mac shows « Réessayer », then « Réessayer encore » after one click (the retry fails again). Env: DATA. Exit 3 = restart so the page reads the day fresh. Throwaway CI runner only, non-root.
set -u
EV="$DATA/events"; STATE="$DATA/.t046-history-source.state"
day() { date +%Y-%m-%d; }
case "${1:-}" in
  seed)
    # Button: ComputerHistoryPage.swift:791-795, needsRetry (:819-824) when sourceStatus is .inaccessible or .unverified; hasRetried flips on the first click (:793) -> label « Réessayer encore » (:792).
    # Failure: refresh (:99-119) -> ActivityAnalysisCycleError.sourceInaccessible when the day journal cannot be opened O_RDONLY (ActivityAnalysisRuntime.swift:2013-2020 « Could not open … read-only ») -> .inaccessible (:139-147).
    # Journal path events/<local yyyy-MM-dd>.jsonl (AppPaths.swift:1880; ActivityAnalysisRuntime.swift:1866-1869): mode 000 -> EACCES at every retry. Created empty if absent (the day then has a journal nobody can open).
    mkdir -p "$EV"; F="$EV/$(day).jsonl"
    if [[ -e "$F" ]]; then echo "file $(stat -f %Lp "$F") $(day)" > "$STATE"; else echo "nofile - $(day)" > "$STATE"; : > "$F"; fi
    chmod 000 "$F"
    exit 3 ;;
  unseed)
    [[ -f "$STATE" ]] || exit 0
    read -r kind mode d < "$STATE"; F="$EV/$d.jsonl"
    if [[ "$kind" == file ]]; then chmod "$mode" "$F"; else chmod 600 "$F"; rm -f "$F"; fi
    rm -f "$STATE"
    exit 0 ;;
  *) echo "usage: $0 seed|unseed" >&2; exit 2 ;;
esac
