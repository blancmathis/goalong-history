#!/usr/bin/env bash
# seed:screentime-on (J-0621 J-0633): « Temps d’écran Apple » enabled. Env: DATA. Exit 3 = consent is read at launch. Throwaway CI runner only.
set -u
C="$DATA/capability-consent.json"; BAK="$DATA/.t046-screentime-consent.bak"; NONE="$DATA/.t046-screentime-consent.none"
case "${1:-}" in
  seed)
    # Consent file AppPaths.swift:109; keys GoalongCapability.appleScreenTime (CapabilityConsentStore.swift:8), doc {schemaVersion:1, policyVersion:1, capabilities}
    # (:42-47, normalized() :80 fills missing ones); read once by GoalongCapabilityConsentStore.shared (:107) -> isEnabled(.appleScreenTime) (AppDelegate.swift:1244,
    # GoalongActivityAppleCard.swift:20) feeds accessEnabled. A missing/invalid file fails closed (all off).
    if [[ -e "$C" ]]; then cp -p "$C" "$BAK"; else : > "$NONE"; fi
    chflags nouchg "$C" 2>/dev/null
    python3 - "$C" <<'PY' || exit 1
import json, sys, os
p = sys.argv[1]
try: d = json.load(open(p))
except Exception: d = {}
d["schemaVersion"] = 1; d["policyVersion"] = 1; d.setdefault("capabilities", {})
d["capabilities"]["appleScreenTime"] = {"enabled": True, "surface": "settings"}
with open(p, "w") as f: json.dump(d, f)
os.chmod(p, 0o600)
PY
    exit 3 ;;
  unseed)
    # Put the old consent back (or remove ours); the next row starts from the same file. Next launch re-reads it.
    if [[ -e "$BAK" ]]; then mv -f "$BAK" "$C"; elif [[ -e "$NONE" ]]; then rm -f "$C" "$NONE"; fi
    exit 0 ;;
  *) echo "usage: $0 seed|unseed" >&2; exit 2 ;;
esac
