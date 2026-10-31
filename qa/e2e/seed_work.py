#!/usr/bin/env python3
"""T-046 L3j: owner-classified contexts for the synthetic events of seed_events.py.

Writes <data>/work-classification.json (GoalongWorkStore format, version 1) so Activité shows
its « Tâches » section (J-0452/0453), « Corriger » opens a review with tasks (J-0504/0505) and
the review rows offer « Nouvelle tâche… » (J-0488). Owner verdicts survive a definition change.
Key: GoalongWorkContext.key (GoalongWork.swift:40), FNV-1a 64 over app␟host␟title, lowercased.
"""
import datetime, json, os, sys

# Same list and order as seed_events.py APPS (event i uses APPS[(i // 7) % 12] and title (i // 7) % 50).
APPS = [("TextEdit", "com.apple.TextEdit"), ("Safari", "com.apple.Safari"), ("Finder", "com.apple.finder"),
        ("Terminal", "com.apple.Terminal"), ("Xcode", "com.apple.dt.Xcode"), ("Notes", "com.apple.Notes"),
        ("Mail", "com.apple.mail"), ("Calendrier", "com.apple.iCal"), ("Aperçu", "com.apple.Preview"),
        ("Musique", "com.apple.Music"), ("Pages", "com.apple.iWork.Pages"), ("Rappels", "com.apple.reminders")]

TASKS = {"com.apple.TextEdit": "Rapport T-046", "com.apple.Safari": "Rapport T-046",
         "com.apple.dt.Xcode": "Démo T-046", "com.apple.Terminal": "Démo T-046"}
HOST = {"com.apple.Safari": "docs.t046-synthetique.fr"}


def key(app, host, title):
    h = 0xcbf29ce484222325
    for b in (app.lower() + "\x1f" + (host or "").lower() + "\x1f" + (title or "").lower()).encode():
        h = ((h ^ b) * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF
    return format(h, "016x")


def main():
    data = sys.argv[1]
    today = datetime.date.today().isoformat()
    entries, corrections = {}, []
    for j in range(300):  # lcm(12 apps, 50 titles): every (app, title) pair seed_events can emit
        name, bundle = APPS[j % len(APPS)]
        title, host, task = f"Document synthétique T-046 {j % 50}", HOST.get(bundle), TASKS.get(bundle)
        k = key(bundle, host, title)
        if k in entries:
            continue
        verdict = "work" if task else "other"
        entries[k] = {"verdict": verdict, "task": task, "byOwner": True, "seen": today, "attempts": 0}
        corrections.append({"key": k, "verdict": verdict, "task": task,
                            "label": {"application": name, "bundleIdentifier": bundle, "host": host, "title": title}})
    path = os.path.join(data, "work-classification.json")
    with open(path, "w", encoding="utf-8") as f:
        json.dump({"version": 1, "revision": "", "automatic": True, "entries": entries, "corrections": corrections},
                  f, ensure_ascii=False)
    os.chmod(path, 0o600)
    print(f"seed_work: {len(entries)} contexts ({sum(e['verdict'] == 'work' for e in entries.values())} work) -> {path}")


if __name__ == "__main__":
    main()
