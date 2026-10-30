#!/usr/bin/env python3
"""T-046 L3: turn qa/e2e/t046-rows.tsv into one driver plan per shard.

Usage: t046_plan.py ROWS.tsv SOURCE_ROOT SHARD OUT.tsv
Output columns: id, kind, nav, mode, role, needle, action, na_reason, screen.
kind: ui | trigger (dialog or sheet opened by another action) | cli | bg | make | na.
nav uses the step vocabulary of qa/e2e/t046_shard.sh (nav:, pane:, p:, o:, si, w:, ...).
Fileline targets (no id, no literal label in the matrix) are resolved here from the source line.
"""
import os
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
    "Partager": "pane:advanced p:\"Outils de partage et analyses\" w:2 o:\"Exporter un fichier signé…\" w:2",
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

# Source file of the target (fileline, or the only file holding the literal) -> navigation, after run 1's dumps.
# The share tools (GoalongAdvancedTools) are the pane Avancé > « Outils de partage et analyses », not Stockage.
# It wins over NAV: the screen names of the matrix do not always match the tab or the opener.
FILE_NAV = {
    "BlockingPageLists.swift": "nav:concentration p:\"Distractions\" w:2",
    "BlockingPage.swift": "nav:concentration p:\"Programme\" w:2",
    "BlockingWeek.swift": "nav:concentration p:\"Programme\" w:2",
    "ConcentrationCommitmentViews.swift": "nav:concentration o:concentration-commitment-create w:2",
    "GoalongProfileStudio.swift": "pane:advanced p:\"Outils de partage et analyses\" w:2 p:\"Comprendre mon travail\" w:3",
    "GoalongSiteAnalysisSheet.swift": "pane:advanced p:\"Outils de partage et analyses\" w:2 p:\"Analyser une demande du site…\" w:2",
    "GoalongAnalyticsPage.swift": "nav:overview p:activity-explore-usage w:2",
    "GoalongActivityUsageList.swift": "nav:overview p:activity-explore-usage w:2",
    "GoalongHealthImportSheet.swift": "nav:overview p:activity-explore-coverage w:2 p:\"Importer…\" w:2",
    # The source toggle checks access first; the runner has no local conversation folder, so it stays off (state, not driver).
    "AgentActivityPage.swift": "nav:history p:\"Conversations locales\" w:2",
    "JevConnectionSheet.swift": "pane:jev p:jev-open-connection w:2",
    "JevInterventionControls.swift": "pane:jev o:jev-intervention-settings w:1",
    "JevMonitoringPage.swift": "pane:jev",
    "JevControls.swift": "pane:jev",
    "JevWorkContextControls.swift": "pane:jev",
}

# Per-row overrides after reading the AX dumps: id -> (extra nav appended, mode, role, needle) (None keeps the field).
RECIPES = {
    # Computed id: the morning panel is open on the runner (evening one after 18:00 local).
    "J-0147": ("", "id", "AXButton", "concentration-morning-panel"),
    # L3d: a container id (activity-header, activity-usage) hides the child id: match the child's label.
    "J-0466": ("", "label", "AXButton", "Aujourd’hui"),
    "J-0467": ("", "label", "AXButton", "Actualiser"),
    "J-0475": ("", "label", "AXPopUpButton", "Trier les usages"),
    "J-0477": ("", "label", "AXButton", "Exporter les durées"),
    # The site rules are the items of the row menu « Règles du site » (opened by the nav).
    **{f"J-{n:04d}": ("", "menuitem", "AXMenuItem", None) for n in range(908, 916)},
}

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
    # L3d: a fileline on a modifier (.keyboardShortcut) below its Button: the nearest literal above.
    return literal("\n".join(lines[line - 1:line + 5])) or next(
        (lit for k in range(line - 2, max(line - 10, 0) - 1, -1) if (lit := literal(lines[k]))), "")


def cancel_shortcut(src, target):
    """The fileline's button is the .cancelAction one: its shortcut is Escape, not Return."""
    m = re.search(r"@(Sources/\S+?\.swift):(\d+)", target)
    if not m:
        return False
    try:
        lines = open(f"{src}/{m.group(1)}", encoding="utf-8").read().split("\n")
    except OSError:
        return False
    here = lines[int(m.group(2)) - 1] if int(m.group(2)) <= len(lines) else ""
    # The fileline is the button or its .keyboardShortcut line: decide on that line, else on the next one.
    for text in (here, lines[int(m.group(2))] if int(m.group(2)) < len(lines) else ""):
        if ".defaultAction" in text:
            return False
        if ".cancelAction" in text:
            return True
    return False


_FILES = {}


def source_file(src, target, needle):
    """Basename of the file behind the target: the fileline, else the only app file holding the literal."""
    m = re.search(r"@(Sources/\S+?\.swift)", target)
    if m:
        return m.group(1).rsplit("/", 1)[-1]
    if not needle or len(needle) < 4:
        return ""
    if not _FILES:
        import glob
        for f in glob.glob(f"{src}/Sources/LocalHistoryApp/**/*.swift", recursive=True):
            _FILES[f.rsplit("/", 1)[-1]] = open(f, encoding="utf-8").read()
    hits = [n for n, t in _FILES.items() if '"' + needle in t]
    return hits[0] if len(hits) == 1 else ""


def table(name):
    """Optional side file of qa/e2e: tab-separated lines, # comments skipped."""
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), name)
    if not os.path.exists(path):
        return None
    return [l.rstrip("\n").split("\t") for l in open(path, encoding="utf-8") if l.strip() and not l.startswith("#")]


def main():
    rows_path, src, shard, out = sys.argv[1:5]
    # L3b: the nav of another row whose AX dump held the target (t046-nav.tsv), and a targeted run (t046-only.txt).
    nav_of = {f[0]: f[1] for f in table("t046-nav.tsv") or [] if len(f) > 1}
    only = table("t046-only.txt")
    only = {f[0] for f in only} if only is not None else None
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
        if kind == "ui" and mode == "label" and role in ("AXSheet", "AXDialog", "AXWindow", "AXPopover"):
            kind = "trigger"  # The container is opened by another control; found only if navigation opened it.
            if role == "AXSheet":
                mode = "dialog"  # L3d: the title is a child of the sheet, not an attribute (J-0722).
        if action == "shortcut" and cancel_shortcut(src, target):
            action = "escape"
        if kind == "trigger" and not needle:
            kind, na = "na", "dialogue ouvert par une action hôte non scriptée (" + target.split("(")[-1].rstrip(")") + ")"
        if kind in ("ui", "trigger"):
            nav = FILE_NAV.get(source_file(src, target, needle), nav)
        if kind in ("ui", "trigger") and role == "AXMenuItem" and screen in ("Barre des menus (panneau)", "Pause globale"):
            nav = "si p:\"Plus d’options\" pc w:1"
        if kind in ("ui", "trigger") and rid in nav_of:
            nav = nav_of[rid]
            if nav.startswith("@onboarding"):  # Seen only on the fresh app: run with the onboarding rows.
                nav, screen = nav[len("@onboarding"):].strip(), "Onboarding"
        if rid in RECIPES:
            extra, m2, r2, n2 = RECIPES[rid]
            nav = (nav + " " + extra).strip()
            mode, role, needle = m2 or mode, r2 if r2 is not None else role, n2 if n2 is not None else needle
            if kind == "na" and needle:
                kind, na = "ui", ""
        if only is not None and rid not in only:
            continue
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
