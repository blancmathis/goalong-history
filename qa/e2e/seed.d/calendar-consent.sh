#!/usr/bin/env bash
# seed:calendar-consent (J-0721): Réglages home shows « Autoriser l’accès… » (id settings-calendar-access). Env: DATA. Exit 3 = consent is read at launch. Throwaway CI runner only.
# Needs the runner to have NO Calendar/Reminders TCC grant (default on a fresh runner): the TCC state itself cannot be seeded from files.
set -u
C="$DATA/capability-consent.json"; BAK="$DATA/.t046-calendar-consent.bak"; NONE="$DATA/.t046-calendar-consent.none"
case "${1:-}" in
  seed)
    # Block shown by SettingsPage.swift:22-34 only if consents.isEnabled(.calendar) (:24) and calendar or reminders permission != .ready (:23);
    # with the runner's undetermined permission the label is « Autoriser l’accès… » (:29), id :32.
    # Consent file: AppPaths.swift:109, key `calendar` (CapabilityConsentStore.swift:7), doc {schemaVersion, policyVersion, capabilities} (:42-47, same shape as seed chatgpt-connected), read at launch -> exit 3.
    if [[ -e "$C" ]]; then cp -p "$C" "$BAK"; else : > "$NONE"; fi
    chflags nouchg "$C" 2>/dev/null
    mkdir -p "$DATA" && python3 - "$C" <<'PY' || exit 1
import json, sys, os
p = sys.argv[1]
try: d = json.load(open(p))
except Exception: d = {}
d["schemaVersion"] = 1; d["policyVersion"] = 1; d.setdefault("capabilities", {})
d["capabilities"]["calendar"] = {"enabled": True, "surface": "settings"}
with open(p, "w") as f: json.dump(d, f)
os.chmod(p, 0o600)
PY
    exit 3 ;;
  unseed)
    if [[ -e "$BAK" ]]; then mv -f "$BAK" "$C"; elif [[ -e "$NONE" ]]; then rm -f "$C" "$NONE"; fi
    exit 0 ;;
  *) echo "usage: $0 seed|unseed" >&2; exit 2 ;;
esac
