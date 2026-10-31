#!/usr/bin/env bash
# seed:excluded-domain-parent (J-0911): the rule « t046-synthetique.fr » is a parent of the seeded site docs.t046-synthetique.fr (seed_events.py:64), so its « ⋯ » menu shows the disabled
# « Exclu par la règle « t046-synthetique.fr » (Réglages) ». Env: DATA. Exit 3 = config.json is read at launch. Throwaway CI runner only. Sibling: excluded-domain.sh (J-0912).
set -u
HOST="t046-synthetique.fr"; C="$DATA/config.json"; BAK="$DATA/.t046-excluded-domain-parent.bak"
case "${1:-}" in
  seed)
    # config.json = AppPaths.configFile (AppPaths.swift:107), RecorderConfig (Config.swift:3), key excludedDomains (:41), cleaned/validated by load (:259, :329).
    # Draft read at launch: settingsDraft.excludedDomainsText (DashboardModels.swift:335) -> configuredExcludedDomains (DashboardViewModelWebsiteRules.swift:156).
    # Suffix entry = parent (DashboardViewModelWebsiteRules.swift:14-24), so the menu shows the disabled « Exclu par la règle » item (UsageRulesList.swift:286-288).
    [[ -f "$C" ]] || { echo "no config.json: launch the app once first" >&2; exit 1; }
    cp -p "$C" "$BAK"
    python3 - "$C" "$HOST" <<'PY' || { mv -f "$BAK" "$C"; exit 1; }
import json, sys
p, host = sys.argv[1], sys.argv[2]
d = json.load(open(p)); d["excludedDomains"] = [x for x in d.get("excludedDomains", []) if x != host] + [host]
with open(p, "w") as f: json.dump(d, f)
PY
    exit 3 ;;
  unseed)
    # Put the old config back; the next launch re-reads it.
    [[ -e "$BAK" ]] && mv -f "$BAK" "$C"
    exit 0 ;;
  *) echo "usage: $0 seed|unseed" >&2; exit 2 ;;
esac
