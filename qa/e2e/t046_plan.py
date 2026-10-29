#!/usr/bin/env python3
"""T-046 L3: turn qa/e2e/t046-rows.tsv into one driver plan per shard.

Usage: t046_plan.py ROWS.tsv SOURCE_ROOT SHARD OUT.tsv
Output columns: id, kind, nav, mode, role, needle, action, na_reason, screen.
kind: ui | trigger (dialog or sheet opened by another action) | cli | bg | make | na.
nav uses the step vocabulary of qa/e2e/t046_shard.sh (nav:, pane:, p:, o:, si, w:, ...).
Fileline targets (no id, no literal label in the matrix) are resolved here from the source line.
"""
import re
import sys

# Screen (left of " :: " in screen_journey) -> navigation from a clean dashboard.
NAV = {
    "Fenêtre principale (barre latérale)": "nav:overview",
    "Fenêtre principale": "nav:overview",
    "Bandeau d’attention": "nav:overview",
    "Barre des menus (panneau)": "si",
    "Pause globale": "si",
    "Menu de l’app (barre macOS)": "",
    "Mise à jour": "",
    "Onboarding": "",
    "Installation": "",
    "App (cycle de vie)": "",
    "Permissions": "pane:permissions",
    "Autre (SourceActivation)": "pane:permissions",
    "Activité (navigation jour)": "nav:overview",
    "Activité": "nav:overview",
    "Activité › Analyse": "nav:overview o:activity-explore-usage w:2",
    "Activité › Analyse site": "nav:overview o:activity-explore-usage w:2",
    "Activité › Profil": "pane:website",
    "Activité › Rythme": "pane:website",
    "Bilan quotidien (ChatGPT)": "pane:chatGPT",
    "Calendrier": "pane:connections",
    "Conversations IA": "nav:history p:\"Conversations locales\" w:2",
    "Historique de ce Mac": "nav:history p:\"Ce Mac\" w:2",
    "Mon travail": "nav:work",
    "Mon travail › Développeur": "nav:work",
    "Temps d’écran Apple": "nav:history p:\"Temps d’écran Apple\" w:2",
    "Terminal (page CLI)": "pane:home o:\"Terminal et agents\" w:2",
    "Ambiance": "nav:ambiance",
    "Autre (BackgroundContinuitySettings)": "pane:home",
    "Autre (GoalongControls)": "pane:home",
    "Autre (GoalongDisclosureGroup)": "pane:home",
    "Autre (VisibleContextControl)": "pane:recording",
    "Blocage": "nav:concentration o:\"Blocage\" w:2",
    "Blocage › Mot de passe": "nav:concentration o:\"Blocage\" w:2",
    "Blocage › Ralentir": "nav:concentration o:\"Blocage\" w:2",
    "Blocage › Écran de blocage": "nav:concentration o:\"Blocage\" w:2",
    "Braise": "nav:braise",
    "Concentration": "nav:concentration",
    "Confidentialité et sécurité": "pane:home o:\"Diagnostic et preuves\" w:2",
    "Jev (surveillance)": "pane:jev",
    "Partager": "pane:storage o:\"Exporter un fichier signé…\" w:2",
    "Réglages": "pane:home",
    "Réglages › Applications": "pane:applications",
    "Réglages › Règles d’usage": "pane:applications",
    "Réglages › ChatGPT": "pane:chatGPT",
    "Réglages › Conservation": "pane:storage",
    "Réglages › Stockage": "pane:storage",
    "Réglages › Import santé": "pane:storage",
    "Réglages › Développeur": "pane:advanced",
    "Réglages › Modules": "pane:modules",
    "Réglages › Ouverture au login": "pane:home",
    "Site Goalong (partage)": "pane:website",
    "Support / diagnostic": "pane:home p:settings-report-problem w:3",
}

# Per-row overrides after reading the AX dumps: id -> (extra nav appended, mode, role, needle) (None keeps the field).
RECIPES = {}

LITERAL_CALL = re.compile(r'(?:(?:Button|Toggle|DatePicker|Stepper|Picker|Label|TextField|SecureField|Menu|Link|Text|'
                          r'help|accessibilityLabel)\(|NSMenuItem\(title:|NSButton\(title:)\s*"((?:[^"\\]|\\.)*)"')


def literal(text):
    """First literal label in the text; an interpolated one is cut before its first \\( (kept if 4+ chars)."""
    for m in LITERAL_CALL.finditer(text):
        s = m.group(1)
        if "\\(" in s:
            s = s.split("\\(")[0]
        s = s.strip()
        if len(s) >= 2 and not s.startswith("\\"):
            return s
    return ""


def resolve(src, path, line):
    try:
        lines = open(f"{src}/{path}", encoding="utf-8").read().split("\n")
    except OSError:
        return ""
    return literal("\n".join(lines[line - 1:line + 5]))


def main():
    rows_path, src, shard, out = sys.argv[1:5]
    rows = [l.rstrip("\n").split("\t") for l in open(rows_path, encoding="utf-8")][1:]
    plan = []
    for r in rows:
        r += [""] * (7 - len(r))
        rid, sh, journey, target, action, _expected, na = r[:7]
        if sh != shard:
            continue
        screen = journey.split(" :: ")[0].strip()
        nav = NAV.get(screen, "nav:overview")
        mode = role = needle = ""
        kind = "ui"
        m = re.match(r"^(AX\w+)", target)
        role = m.group(1) if m else ""
        if na or not target:
            kind, na = "na", na or "sans cible"
        elif target.startswith("cli: make") or target.startswith("cli: ") and re.search(r"\.(sh|command)$", target):
            kind, needle = "make", target[5:]
        elif target.startswith("cli:"):
            kind, needle = "cli", target[4:].strip()
        elif target.startswith("bg:"):
            kind, needle = "bg", target[3:]
        elif target.startswith("id="):
            needle = target[3:]
            mode = "id"
            if "\\(" in needle:
                needle, mode = needle.split("\\(")[0], "idprefix"
        elif "ouvert par l’action hôte" in target:
            kind, mode = "trigger", "dialog"
        elif "~\"" in target:
            needle = re.findall(r'~"(.*?)"(?=\]|\s)', target)[-1]
            mode = "label"
            if role == "AXDialog":
                kind, mode = "trigger", "dialog"
            elif role == "AXMenuItem":
                mode = "menuitem"
        elif "@" in target:
            path, _, line = target.split("@", 1)[1].rpartition(":")
            needle = resolve(src, path, int(line)) if line.isdigit() else ""
            mode = "menuitem" if role == "AXMenuItem" else "label"
            if not needle:
                kind, na = "na", f"non adressable : ni identifiant ni libellé littéral ({target.split('@', 1)[1]})"
        else:
            kind, na = "na", f"cible non reconnue par le pilote : {target}"
        if kind in ("ui", "trigger") and role == "AXMenuItem" and screen in ("Barre des menus (panneau)", "Pause globale"):
            nav = "si p:\"Plus d’options\" pc w:1"
        if rid in RECIPES:
            extra, m2, r2, n2 = RECIPES[rid]
            nav = (nav + " " + extra).strip()
            mode, role, needle = m2 or mode, r2 if r2 is not None else role, n2 if n2 is not None else needle
            if kind == "na" and needle:
                kind, na = "ui", ""
        plan.append([rid, kind, nav, mode, role, needle, action or "observe", na, screen])
    # Onboarding needs a fresh app: first. Lifecycle quits the app: last.
    order = {"Onboarding": 0, "App (cycle de vie)": 2}
    plan.sort(key=lambda p: (order.get(p[8], 1), p[8], p[0]))
    with open(out, "w", encoding="utf-8") as f:
        for p in plan:
            f.write("\t".join(x.replace("\t", " ") for x in p) + "\n")
    kinds = {}
    for p in plan:
        kinds[p[1]] = kinds.get(p[1], 0) + 1
    print(f"{shard}: {len(plan)} rows {kinds}")


if __name__ == "__main__":
    main()
