#!/usr/bin/env python3
"""T-046 L3, shard S4: run each `cli: goalong …` row on the runner's synthetic data.

Usage: t046_cli.py GOALONG DATA_ROOT PLAN.tsv OUT_DIR
Writes OUT_DIR/<id>.txt (transcript) and prints one line per row: id, verdict, cause, detail.
Arguments come from `goalong help --json` (command syntax); placeholders get synthetic values.
pass = exit 0, or a nonzero exit with the documented JSON error on stderr; fail = crash, timeout or undocumented failure.
"""
import json
import os
import re
import subprocess
import sys

goalong, root, plan_path, out = sys.argv[1:5]
tmp = os.path.join(out, "tmp")
os.makedirs(tmp, exist_ok=True)
VALUES = {"DAY": "today", "N": "5", "QUESTION": "Combien de minutes dans TextEdit ?", "ACTIVITY_ID": "1",
          "HTTPS_ORIGIN": "https://127.0.0.1:9", "URL": "https://127.0.0.1:9", "ID,ID": "mac",
          "TIMEZONE": "Europe/Paris", "DATE": "today", "FROM": "today", "TO": "today"}


def value(ph):
    ph = ph.strip('"()[],.')
    if ph in VALUES:
        return VALUES[ph]
    if "PATH" in ph or "FILE" in ph or "XML" in ph or "OUTPUT" in ph:
        return os.path.join(tmp, f"t046-{ph.lower()}-{os.getpid()}")
    if "ISO" in ph or "UTC" in ph:
        return "2026-01-01T00:00:00Z"
    if ph in ("YYYY-MM-DD", "DAY", "DATE") or "DAY" in ph:
        return "today"
    if "HH" in ph:
        return "09:00"
    if "WEEK" in ph or "Www" in ph:
        return "this"
    if re.fullmatch(r"\d+…\d+", ph):
        return ph.split("…")[0]
    if re.fullmatch(r"[A-Z_]*(N|MIN|MINUTES|TOKENS|LIMIT|OFFSET|DAYS|COUNT)", ph):
        return "5"
    if ph in ("TEXT", "NAME", "TITLE", "QUESTION"):
        return "T046 synthétique"
    return "1" if "ID" in ph else "today"


def run(argv):
    try:
        p = subprocess.run([goalong, "--root", root] + argv, capture_output=True, text=True, timeout=90, stdin=subprocess.DEVNULL)
        return p.returncode, p.stdout, p.stderr
    except subprocess.TimeoutExpired:
        return 124, "", "timeout 90 s"


rc, contract, err = run(["help", "--json"])
commands = []
try:
    data = json.loads(contract)
    for c in data.get("commands", []):
        commands.append((c.get("name", ""), c.get("syntax", ""), [a for a in c.get("aliases", [])]))
except Exception as e:  # noqa: BLE001
    print(f"# help --json unreadable: {e} {err[:200]}", file=sys.stderr)


READ_FIRST = ("status", "show", "current", "list", "probe")


def argv_for(name, syntax, flag=None):
    """Command, a read-only subcommand when there are several, required positional placeholders, plus FLAG and its value."""
    rest = re.sub(r"^(goalong\s+)?(\[--root PATH\]\s+)?" + re.escape(name) + r"\b", "", syntax).strip()
    argv = [name]
    if flag:
        m = re.search(re.escape(flag) + r"(?:[ =]([^\s\[\]()|]+))?", rest)
        argv.append(flag)
        if m and m.group(1) and not m.group(1).startswith("-"):
            argv.append(value(m.group(1)))
        return argv
    while True:  # Optional and grouped parts out, innermost first.
        stripped = re.sub(r"\[[^\[\]]*\]|\([^()]*\)", " ", rest)
        if stripped == rest:
            break
        rest = stripped
    branches = [b.split() for b in re.split(r"\s\|\s", rest)] or [[]]
    branch = next((b for b in branches if b and b[0] in READ_FIRST), branches[0])
    if branch and "|" in branch[0] and branch[0].islower():
        subs = branch[0].split("|")
        branch = [next((x for x in READ_FIRST if x in subs), subs[0])] + branch[1:]
    for tok in branch:
        if tok.startswith("<") or "…" in tok and not argv[-1].startswith("-"):
            continue
        argv.append(value(tok) if re.search(r"[A-Z]", tok) and not tok.startswith("-") else tok)
    return argv


def documented(rc, stderr):
    if rc == 0:
        return True
    if rc >= 124 or rc < 0:
        return False
    try:
        return isinstance(json.loads(stderr), dict)
    except Exception:  # noqa: BLE001
        return False


for line in open(plan_path, encoding="utf-8"):
    f = line.rstrip("\n").split("\t")
    if f[1] != "cli":
        continue
    rid, spec = f[0], re.sub(r"^goalong\s+", "", f[5])
    runs = []
    if spec.startswith("<commande>"):
        flag = spec.split()[1]
        hit = next(((n, s) for n, s, _ in commands if flag in s), None)
        if flag in ("--help", "--version", "--json", "--root"):
            hit = hit or ("status", "goalong status")
        if not hit:
            runs.append((None, f"aucune commande de `help --json` ne cite {flag}"))
        else:
            runs.append((argv_for(hit[0], hit[1], flag), None))
    else:
        for name in [x.strip() for x in spec.split("/")]:
            syn = next((s for n, s, al in commands if n == name or name in al), f"goalong {name}")
            runs.append(((["help"] if name in ("help",) else argv_for(name, syn)) if not name.startswith("-") else [name], None))
    transcript, verdicts = [], []
    for argv, why in runs:
        if argv is None:
            transcript.append(f"# {why}")
            verdicts.append(("N/A", why))
            continue
        rc, so, se = run(argv)
        ok = documented(rc, se)
        transcript.append(f"$ goalong --root <synthetic> {' '.join(argv)}\n# exit {rc}\n{so[:3000]}\n# stderr\n{se[:1500]}")
        verdicts.append(("pass" if ok else "fail", f"{argv[0]} exit {rc}"))
    with open(os.path.join(out, f"{rid}.txt"), "w", encoding="utf-8") as t:
        t.write(f"{rid} — {f[5]}\n\n" + "\n\n".join(transcript) + "\n")
    states = [v for v, _ in verdicts]
    verdict = "fail" if "fail" in states else "pass" if "pass" in states else "N/A"
    cause = "cli-error" if verdict == "fail" else ""
    print("\t".join([rid, verdict, cause, "; ".join(d for _, d in verdicts)[:300]]))
