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
    "Blocage": "nav:concentration p:\"Programme\" w:2",
    "Blocage › Mot de passe": "nav:concentration p:\"Programme\" w:2",
    "Blocage › Ralentir": "nav:concentration p:\"Programme\" w:2",
    "Blocage › Écran de blocage": "nav:concentration p:\"Programme\" w:2",
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
    # L3j: alert and folder-sheet « Enregistrer », not the longer « Enregistrer … » buttons of the page behind.
    # L3k: J-0331 = the work-definition alert after « Enregistrer » on Mon travail.
    "J-0331": ("", "dialog", "", "Changer la définition du travail"),
    "J-0453": ("", "id", "AXButton", "activity-tasks-review"),
    "J-0505": ("", "dialog", "", "Corriger le classement"),
    "J-0504": ("", "label", "AXButton", "Terminé"),
    # L3k: « Commande copiée » is the label AFTER the press: press « Copier la commande » (ex: checks the new label).
    "J-0946": ("", "exact", "AXButton", "Copier la commande"),
    "J-0947": ("", "exact", "AXButton", "Copier la commande"),
    "J-0372": ("", "exact", "AXButton", "Enregistrer"),
    "J-0373": ("", "exact", "AXButton", "Enregistrer"),
    # L3h: GoalongMenuPicker is a SwiftUI Menu (AXMenuButton); the nav's pick: chooses the item.
    "J-0475": ("", "label", "AXMenuButton", "Trier les usages"),
    "J-0477": ("", "label", "AXButton", "Exporter les durées"),
    # L3e: the permission row's button carries a fixed id; several « activity-usage » buttons share one id (J-0476);
    # the confirmation dialog's buttons are action-button-N: match « Annuler » (J-0444).
    "J-0807": ("", "id", "AXButton", "permission-primary-action"),
    "J-0476": ("", "label", "AXButton", "Voir les "),
    "J-0444": ("", "label", "AXButton", "Annuler"),
    # L3e: « Actions groupées » items, in the menu the nav leaves open (pk:Actions groupées|).
    **{f"J-{n:04d}": ("", "menuitem", "AXMenuItem", None) for n in (427, 428, 429)},
    # The site rules are the items of the row menu « Règles du site » (opened by the nav).
    **{f"J-{n:04d}": ("", "menuitem", "AXMenuItem", None) for n in range(908, 916)},
    # L3f: the replacements tab title is static text; its toggles are the rule's checkboxes (after « Ajouter… »).
    "J-0433": ("", "label", "AXCheckBox", "Respecter la casse"),
    "J-0434": ("", "label", "AXCheckBox", "Mot entier"),
    # L3f: « Nouvelle tâche… » / « Laisser l’agent décider » are items of the row menu « Corriger » (left open by pk:).
    **{f"J-{n:04d}": ("", "menuitem", "AXMenuItem", None) for n in (500, 501, 503)},
    # L3h: the control, not the page or sheet it opens (L3g audit); the nav's ex: names the opened page or sheet.
    "J-0462": ("", "id", "AXButton", "activity-explore-reports"),
    "J-0469": ("", "id", "AXButton", "activity-explore-code"),
    "J-0779": ("", "label", "AXButton", "Analyser le contexte d’une session"),
    "J-0794": ("", "label", "AXButton", "Utiliser cette session relue"),
    # L3i: the target is the date picker itself (act type sets it one day back, reads it, restores it).
    "J-0515": ("", "label", "AXDateTimeArea", "Conversations actives depuis"),
    # L3l (ui-int3): Profile Studio and Rythme labels renamed.
    "J-0524": ("", "label", "AXButton", "Exporter la consigne pour mon agent…"),
    "J-0783": ("", "label", "AXCheckBox", "Inclure les textes de fenêtres déjà autorisés"),
    # L3i: « Actions groupées » became a kit menu (AXMenuButton); the nav's pick: chooses the item.
    "J-0427": ("", "label", "AXMenuButton", "Actions groupées"),
    "J-0428": ("", "label", "AXMenuButton", "Actions groupées"),
    "J-0429": ("", "label", "AXMenuButton", "Actions groupées"),
    # L3n E-A (run 41227452518 dumps): the alert's « Annuler » is action-button-2 (the page's « Annuler » comes first);
    # « Enregistrer » of the goals editor by id; labels as shown; conversation actions are items of a menu left open.
    "J-0330": ("", "id", "AXButton", "action-button-2"),
    "J-0331": ("", "id", "AXButton", "monitoring-save-goals"),
    "J-0366": ("", "label", "AXTextField", "Claude Code local history"),
    "J-0368": ("", "label", "AXPopUpButton", "Conversations et journaux"),
    "J-0430": ("", "label", "AXCheckBox", "Claude Code, Claude Code local history"),
    "J-0881": ("\"ex:Choisir la demande d’analyse Goalong\"", "label", "AXButton", "Choisir la demande…"),
    **{f"J-{n:04d}": ("", "menuitem", "AXMenuItem", "Afficher la source d’origine") for n in (347, 363)},
    **{f"J-{n:04d}": ("", "menuitem", "AXMenuItem", "Vérifier que la source est intacte") for n in (348, 364)},
}

# UI branch (t046/evidence-ui): labels the UI lots renamed between 06e199f and 973ff6a. The matrix (and a
# file:line resolved at MATRIX_REV) gives the old label; the row looks for the new one.
UI_RENAMES = {
    "Démarrage à la connexion indisponible": "Ouverture de session indisponible",
    "Ouvrir les éléments d’ouverture…": "Ouvrir Réglages Système…",
    "Ouvrir les éléments d’ouverture": "Ouvrir Réglages Système",
    "Ouvrir Goalong à la connexion": "Lancer Goalong à l’ouverture de session",
    "Vérifier l’empreinte SHA-256": "Vérifier que la source est intacte",
    "Confidentialité · tout suspendre…": "Confidentialité, tout suspendre…",
    "Projet A · vide pour supprimer": "Projet A, vide pour supprimer",
    "exemple.fr · un domaine par ligne": "exemple.fr, un domaine par ligne",
    "Tout autoriser · durées seulement": "Tout autoriser, durées seulement",
    "Tout autoriser · détails choisis": "Tout autoriser, détails choisis",
    "· le lendemain": ", le lendemain",
    "Ajouter un site · exemple.fr": "Ajouter un site, exemple.fr",
    "Site à exclure · exemple.fr": "Site à exclure, exemple.fr",
    # The button now reads « Supprimer… »; its accessibility label (AXDescription) names the data.
    "Supprimer ses données…": "Supprimer les données Concentration",
}
# Controls the UI lots removed: no target left in 973ff6a.
UI_REMOVED = {
    "Configurer la source",  # GoalongAnalyticsPage: the unavailable-source row lost its button.
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


# UI branch: the matrix's file:line targets point into Sources/ at 06e199f; the UI lots moved the lines.
MATRIX_REV = "06e199f"
_MATRIX = {}


def matrix_lines(src, path):
    """Lines of PATH at MATRIX_REV (git show), else the checked-out file; None if neither is readable."""
    if path not in _MATRIX:
        import subprocess
        r = subprocess.run(["git", "-C", src, "show", f"{MATRIX_REV}:{path}"], capture_output=True, text=True)
        if r.returncode == 0:
            _MATRIX[path] = r.stdout.split("\n")
        else:
            try:
                _MATRIX[path] = open(f"{src}/{path}", encoding="utf-8").read().split("\n")
            except OSError:
                _MATRIX[path] = None
    return _MATRIX[path]


def resolve(src, path, line):
    lines = matrix_lines(src, path)
    if lines is None:
        return ""
    # L3d: a fileline on a modifier (.keyboardShortcut) below its Button: the nearest literal above.
    return literal("\n".join(lines[line - 1:line + 5])) or next(
        (lit for k in range(line - 2, max(line - 10, 0) - 1, -1) if (lit := literal(lines[k]))), "")


def cancel_shortcut(src, target):
    """The fileline's button is the .cancelAction one: its shortcut is Escape, not Return."""
    m = re.search(r"@(Sources/\S+?\.swift):(\d+)", target)
    if not m:
        return False
    lines = matrix_lines(src, m.group(1))
    if lines is None:
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
    # L3n: per-lot side files <stem>.d/*<ext> (one writer each, sorted by name) come after the main file, so a
    # lot adds lines without touching the shared file (no merge conflict); the last nav line for an id still wins.
    here = os.path.dirname(os.path.abspath(__file__))
    stem, ext = os.path.splitext(name)
    paths = [os.path.join(here, name)]
    side = os.path.join(here, stem + ".d")
    if os.path.isdir(side):
        paths += [os.path.join(side, f) for f in sorted(os.listdir(side)) if f.endswith(ext)]
    paths = [p for p in paths if os.path.exists(p)]
    if not paths:
        return None
    return [l.rstrip("\n").split("\t") for p in paths for l in open(p, encoding="utf-8") if l.strip() and not l.startswith("#")]

# L3n: the row's action when t046-rows.tsv names one the driver cannot play (J-0290 « Fermer » is .cancelAction).
ACTIONS = {"J-0290": "escape"}


def main():
    rows_path, src, shard, out = sys.argv[1:5]
    # L3b: the nav of another row whose AX dump held the target (t046-nav.tsv), and a targeted run (t046-only.txt).
    nav_of = {f[0]: f[1] for f in table("t046-nav.tsv") or [] if len(f) > 1}
    only = table("t046-only.txt")
    only = {f[0] for f in only} if only is not None else None
    # L3n: discovery passes (t046-discover.txt and .d/): nav + AX dump, no verdict (status DISC, never sorted).
    disc = {f[0] for f in table("t046-discover.txt") or []}
    verdict_ids = set(only or ())
    if only is not None:
        only |= disc
    rows = [l.rstrip("\n").split("\t") for l in open(rows_path, encoding="utf-8")][1:]
    # L3n extension point: t046-rows.d/<lot>.tsv (same 7 columns) replaces a catalogue row by id (fixed label or screen).
    fix = {}
    side = os.path.join(os.path.dirname(os.path.abspath(__file__)), "t046-rows.d")
    if os.path.isdir(side):
        for name in sorted(os.listdir(side)):
            if name.endswith(".tsv"):
                for l in open(os.path.join(side, name), encoding="utf-8"):
                    if l.strip() and not l.startswith("#"):
                        f = l.rstrip("\n").split("\t"); fix[f[0]] = f
    rows = [fix.get(r[0], r) for r in rows]
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
        if kind in ("ui", "trigger") and needle in UI_REMOVED:
            kind, na = "na", f"contrôle retiré par les lots UI (973ff6a) : {needle}"
        needle = UI_RENAMES.get(needle, needle)
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
        action = ACTIONS.get(rid, action)
        if rid in disc and rid not in verdict_ids:
            kind, na = "disc", ""
        plan.append([rid, kind, nav, mode, role, needle, action or "observe", na, screen])
    # Onboarding needs a fresh app: first. Lifecycle quits the app: last.
    order = {"Onboarding": 0, "App (cycle de vie)": 2}
    # L3f: J-0807 opens System Settings; J-0810/0811 (same button, Return key) play before it.
    plan.sort(key=lambda p: (order.get(p[8], 1), p[8], p[0] == "J-0807", p[0]))
    with open(out, "w", encoding="utf-8") as f:
        for p in plan:
            f.write("\t".join(x.replace("\t", " ") for x in p) + "\n")
    kinds = {}
    for p in plan:
        kinds[p[1]] = kinds.get(p[1], 0) + 1
    print(f"{shard}: {len(plan)} rows {kinds}")


if __name__ == "__main__":
    main()
