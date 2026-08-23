#!/usr/bin/env python3
"""Guided benchmark against real foreground macOS evidence.

Deterministic fixtures are intentionally excluded from this score. The script never
resets TCC, grants permissions, or accesses non-benchmark private data.
"""
from __future__ import annotations

import argparse, contextlib, dataclasses, http.server, json, os
from datetime import datetime, timezone, timedelta
from pathlib import Path
import platform, re, shutil, socket, socketserver, statistics, subprocess
import threading, time

THRESHOLDS = {
    "input_recall": .99, "association_accuracy": .95, "before_after": .90,
    "semantic_changes": .90, "resource_found": .95, "resource_reopened": .95,
    "factual_accuracy": .95, "resume_accuracy": .90,
}
CORE_SCENARIOS = {
    "input_ground_truth", "textedit", "private", "secure", "excluded_app",
    "excluded_domain", "include_denied_app", "include_allowed_app",
    "include_denied_site", "include_allowed_site", "resources", "lock", "spaces",
}
ACTION_TO_INTERACTION = {
    "mouseClick": "click", "keyboardShortcut": "shortcut",
    "scrollBurst": "scroll", "typingBurst": "typing",
}


def iso_now():
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def dt(value):
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(timezone.utc)
    except ValueError:
        return None


def cmd(args, cwd=None, check=True):
    return subprocess.run(
        args, cwd=str(cwd) if cwd else None, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=check,
    )


def ask(prompt, default=None):
    suffix = " [Y/n] " if default is True else " [y/N] " if default is False else " [y/n] "
    while True:
        value = input(prompt + suffix).strip().lower()
        if not value and default is not None:
            return default
        if value in {"y", "yes", "o", "oui"}:
            return True
        if value in {"n", "no", "non"}:
            return False


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False) + "\n")


def load_json(path):
    return json.loads(path.read_text())


def require_macos():
    if platform.system() != "Darwin":
        raise SystemExit("Run this in Mathis's foreground macOS session.")


def git(repo, *args):
    return cmd(["git", *args], cwd=repo).stdout.strip()


def signature(app):
    result = cmd(["/usr/bin/codesign", "-d", "--verbose=4", str(app)], check=False)
    raw = result.stdout + result.stderr

    def one(pattern):
        match = re.search(pattern, raw, re.M)
        return match.group(1).strip() if match else None

    authorities = re.findall(r"^Authority=(.+)$", raw, re.M)
    return {
        "exit_code": result.returncode,
        "identifier": one(r"^Identifier=(.+)$"),
        "team_identifier": one(r"^TeamIdentifier=(.+)$"),
        "authorities": authorities,
        "developer_id_application": any(
            value.startswith("Developer ID Application:") for value in authorities
        ),
        "raw": raw.strip(),
    }


def build_cli(repo):
    subprocess.run(
        ["xcrun", "swift", "build", "-c", "release", "--product", "goalong-history-query"],
        cwd=repo, check=True,
    )
    root = cmd(
        ["xcrun", "swift", "build", "-c", "release", "--show-bin-path"], cwd=repo
    ).stdout.strip()
    path = Path(root) / "goalong-history-query"
    if not path.is_file():
        raise RuntimeError(f"Missing {path}")
    return path


def status(cli, data_root):
    result = cmd([str(cli), "--root", str(data_root), "status"], check=False)
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError:
        return {"error": result.stderr or result.stdout}


def status_reasons(value):
    snap, assess = value.get("snapshot") or {}, value.get("assessment") or {}
    perm = snap.get("permissions") or {}
    reasons = []
    if perm.get("accessibilityPreflight") is not True:
        reasons.append("Accessibility switch is off")
    if perm.get("accessibilityFunctionalProbe") is not True:
        reasons.append("Accessibility probe fails")
    if perm.get("inputMonitoringPreflight") is not True:
        reasons.append("Input Monitoring is off")
    if snap.get("eventTapLifecycle") not in {"createdEnabled", "running"}:
        reasons.append("Event Tap is not running")
    if assess.get("captureProven") is not True:
        reasons.append("no real input callback reached this launch")
    return reasons


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


@dataclasses.dataclass
class WebState:
    token: str
    target: dict[str, int]
    counters: dict[str, int] = dataclasses.field(default_factory=dict)
    started: str | None = None
    ended: str | None = None
    complete: bool = False
    lock: threading.Lock = dataclasses.field(default_factory=threading.Lock)

    def update(self, value):
        with self.lock:
            for key in self.target:
                candidate = (value.get("counters") or {}).get(key)
                if isinstance(candidate, int):
                    self.counters[key] = min(candidate, self.target[key])
            self.started = value.get("startedAt") or self.started
            self.ended = value.get("endedAt") or self.ended
            self.complete = self.complete or value.get("complete") is True

    def snapshot(self):
        with self.lock:
            return {
                "target": dict(self.target), "counters": dict(self.counters),
                "started": self.started, "ended": self.ended, "complete": self.complete,
            }


class Handler(http.server.SimpleHTTPRequestHandler):
    directory_path: Path
    state: WebState

    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(self.directory_path), **kwargs)

    def log_message(self, *_):
        pass

    def do_POST(self):
        try:
            size = int(self.headers.get("Content-Length", "0"))
            value = json.loads(self.rfile.read(size))
            if value.get("token") != self.state.token:
                raise ValueError("token mismatch")
            if self.path == "/complete":
                value["complete"] = True
            self.state.update(value)
            body = json.dumps(self.state.snapshot()).encode()
            self.send_response(200)
        except Exception as exc:
            body = json.dumps({"error": str(exc)}).encode()
            self.send_response(400)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


@contextlib.contextmanager
def serve(directory, state, port):
    class Server(socketserver.ThreadingMixIn, socketserver.TCPServer):
        daemon_threads = True
        allow_reuse_address = True

    class Bound(Handler):
        pass

    Bound.directory_path, Bound.state = directory, state
    server = Server(("127.0.0.1", port), Bound)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=3)


def stress_html(token, target):
    return f'''<!doctype html><meta charset="utf-8"><title>Goalong Real Benchmark {token}</title>
<style>body{{font:16px -apple-system;margin:30px auto;max-width:900px}}.n{{font:700 28px monospace}}#scroll{{height:280px;overflow:auto;border:2px solid;padding:10px}}.space{{height:2600px;background:linear-gradient(#fff,#bbb,#fff)}}button,input{{font:inherit;padding:12px}}</style>
<h1>Physical-input ground truth — {token}</h1><p>Use physical input only.</p>
<p>Clicks <span id="c" class="n">0</span>/{target['clicks']} <button id="click" aria-label="Goalong click {token}">Click target</button></p>
<p>Shortcuts <span id="k" class="n">0</span>/{target['shortcuts']} — press Control+Option+B.</p>
<p>Typing bursts <span id="t" class="n">0</span>/{target['typing']} <input id="type" aria-label="Goalong typing {token}" placeholder="type, then pause 1.5 s"></p>
<p>App-switch cycles <span id="a" class="n">0</span>/{target['switches']} — Cmd-Tab to TextEdit and back.</p>
<p>Scroll bursts <span id="s" class="n">0</span>/{target['scrolls']} — one gesture, pause 1.2 s.</p><div id="scroll"><div class="space"></div></div>
<button id="done" disabled>Finish</button><p id="status"></p>
<script>
const token={json.dumps(token)}, target={json.dumps(target)}, x={{clicks:0,shortcuts:0,typing:0,switches:0,scrolls:0}}, startedAt=new Date().toISOString(); let typing=null,wheel=null,hidden=false;
const post=(path='/state',endedAt=null)=>fetch(path,{{method:'POST',headers:{{'Content-Type':'application/json'}},body:JSON.stringify({{token,counters:x,startedAt,endedAt,complete:path==='/complete'}})}}).catch(()=>{{}});
function draw(){{c.textContent=x.clicks;k.textContent=x.shortcuts;t.textContent=x.typing;a.textContent=x.switches;s.textContent=x.scrolls;done.disabled=!Object.keys(target).every(q=>x[q]>=target[q]);status.textContent=done.disabled?'Complete every counter':'Ready: click Finish';}}
click.onclick=()=>{{x.clicks=Math.min(target.clicks,x.clicks+1);draw();post()}};
document.onkeydown=e=>{{if(e.ctrlKey&&e.altKey&&e.key.toLowerCase()==='b'&&!e.repeat){{e.preventDefault();x.shortcuts=Math.min(target.shortcuts,x.shortcuts+1);draw();post()}}}};
type.oninput=()=>{{clearTimeout(typing);typing=setTimeout(()=>{{if(type.value){{x.typing=Math.min(target.typing,x.typing+1);type.value='';draw();post()}}}},1500)}};
scroll.onwheel=()=>{{if(wheel===null){{x.scrolls=Math.min(target.scrolls,x.scrolls+1);draw();post()}}clearTimeout(wheel);wheel=setTimeout(()=>wheel=null,1100)}};
document.onvisibilitychange=()=>{{if(document.hidden)hidden=true;else if(hidden){{hidden=false;x.switches=Math.min(target.switches,x.switches+1);draw();post()}}}};
done.onclick=()=>{{const endedAt=new Date().toISOString();post('/complete',endedAt);done.disabled=true;done.textContent='Completed'}};draw();post();
</script>'''


def marker_html(title, marker):
    return (
        f'<!doctype html><meta charset="utf-8"><title>{title}</title><h1>{title}</h1>'
        f'<p>{marker}</p><button aria-label="{marker}">Click</button>'
        f'<input aria-label="{marker}"><div style="height:2400px">scroll</div>'
    )


def fixtures(root, token, port):
    web, files = root / "web", root / "files"
    web.mkdir(parents=True)
    files.mkdir()
    target = {"clicks": 25, "shortcuts": 25, "typing": 10, "switches": 25, "scrolls": 25}
    (web / "benchmark.html").write_text(stress_html(token, target))
    marks = {
        name: f"GOALONG_{name.upper()}_{token}" for name in (
            "private", "secure", "excluded_app", "excluded_domain",
            "include_denied_app", "include_denied_site",
        )
    }
    for name, marker in marks.items():
        (web / f"{name}.html").write_text(marker_html(f"Goalong {name} {token}", marker))
    excluded_file = files / f"{marks['excluded_app']}.txt"
    excluded_file.write_text(marks["excluded_app"])
    denied_folder = files / marks["include_denied_app"]
    denied_folder.mkdir()
    (denied_folder / "marker.txt").write_text(marks["include_denied_app"])
    secure_title = f"GOALONG_SECURE_WINDOW_{token}"
    secure_script = files / "secure.sh"
    secure_script.write_text(
        f"#!/bin/bash\nprintf '\\033]0;{secure_title}\\007'\n"
        f"read -s -p '{marks['secure']}: ' V\necho\nunset V\n"
    )
    secure_script.chmod(0o700)
    resources, links = [], []
    for index in range(1, 11):
        title, name = f"Goalong Benchmark Page {index:02d} {token}", f"page-{index:02d}.html"
        (web / name).write_text(
            f'<!doctype html><title>{title}</title><h1>{title}</h1>'
            f'<button aria-label="Resource {index:02d}">Mark</button>'
        )
        links.append(f'<li><a href="{name}">{title}</a></li>')
        resources.append({
            "id": f"page-{index:02d}", "title": title, "query": f"Find {title}",
            "expected": f"127.0.0.1:{port}/{name}",
            "url": f"http://127.0.0.1:{port}/{name}",
        })
    (web / "resources.html").write_text(
        f'<!doctype html><title>Resource Hub {token}</title><ol>{"".join(links)}</ol>'
    )
    edit = files / f"Goalong-Benchmark-TextEdit-{token}.txt"
    edit.write_text(f"Goalong benchmark {token}\nBefore state: draft\n")
    for index in range(1, 11):
        path = files / f"Goalong-Benchmark-File-{index:02d}-{token}.txt"
        title = f"Goalong Benchmark File {index:02d} {token}"
        path.write_text(title + "\n")
        resources.append({
            "id": f"file-{index:02d}", "title": title, "query": f"Find {title}",
            "expected": str(path), "path": str(path),
        })
    return {
        "web": str(web), "files": str(files), "target": target, "markers": marks,
        "resources": resources, "edit": str(edit), "excluded_file": str(excluded_file),
        "denied_folder": str(denied_folder), "secure_script": str(secure_script),
        "secure_title": secure_title,
        "hub": f"http://127.0.0.1:{port}/resources.html",
    }


def record(run, sid, title, instructions, *, optional=False, marker=None, reason=None,
           no_details=False, bundle=None, host=None, text=None, strict=False):
    print("\n" + "=" * 70 + f"\n{title}\n" + "=" * 70)
    for line in instructions:
        print("- " + line)
    if optional and not ask("Available and safe to run?", True):
        run["scenarios"].append({
            "id": sid, "title": title, "skipped": True, "why": input("Reason: "),
        })
        return
    input("Press Enter immediately before starting…")
    start = iso_now()
    input("Perform the actions; return and press Enter immediately after…")
    end = iso_now()
    run["scenarios"].append({
        "id": sid, "title": title, "skipped": False, "start": start, "end": end,
        "marker": marker, "reason": reason, "no_details": no_details,
        "bundle": bundle, "host": host, "text": text, "strict": strict,
    })


def jsonl(directory):
    rows = []
    if not directory.exists():
        return rows
    for path in sorted(directory.glob("*.jsonl")):
        for number, line in enumerate(path.read_text(errors="strict").splitlines(), 1):
            if not line:
                continue
            try:
                value = json.loads(line)
            except json.JSONDecodeError as exc:
                value = {"_malformed": True, "_error": str(exc)}
            if isinstance(value, dict):
                value["_path"], value["_line"] = str(path), number
                rows.append(value)
    return rows


def row_dt(row):
    return dt(row.get("timestamp") or row.get("capturedAt") or row.get("start"))


def window(rows, start, end, pad=.5):
    lower, upper = dt(start), dt(end)
    if not lower or not upper:
        return []
    return [
        item for item in rows if (stamp := row_dt(item))
        and lower - timedelta(seconds=pad) <= stamp <= upper + timedelta(seconds=pad)
    ]


def counts(rows):
    output = {}
    for row in rows:
        if isinstance(row.get("kind"), str):
            output[row["kind"]] = output.get(row["kind"], 0) + 1
    return output


def build_memory(cli, data_root, day, output):
    result = cmd(
        [str(cli), "--root", str(data_root), "computer-history", day], check=False
    )
    output.write_text(result.stdout)
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError:
        return {"error": result.stderr or result.stdout}


def interactions(memories):
    return [
        interaction for envelope in memories
        for episode in ((envelope.get("memory") or {}).get("episodes") or [])
        for interaction in episode.get("interactions", []) if isinstance(interaction, dict)
    ]


def target_match(row, case):
    app = (
        row.get("app") if isinstance(row.get("app"), dict)
        else row.get("application") if isinstance(row.get("application"), dict) else {}
    )
    url = row.get("url") if isinstance(row.get("url"), dict) else {}
    raw = json.dumps(row, ensure_ascii=False).lower()
    return bool(
        (case.get("bundle") and app.get("bundleIdentifier") == case["bundle"])
        or (case.get("host") and (
            url.get("host") == case["host"] or case["host"] in str(url.get("value") or "")
        ))
        or (case.get("text") and case["text"].lower() in raw)
        or (case.get("marker") and case["marker"].lower() in raw)
    )


def resource(cli, data_root, case, output):
    output.parent.mkdir(parents=True, exist_ok=True)
    result = cmd(
        [str(cli), "--root", str(data_root), "find", "--days", "30", case["query"]],
        check=False,
    )
    output.write_text(result.stdout)
    try:
        payload = json.loads(result.stdout)
    except json.JSONDecodeError:
        return None
    hits = (payload.get("answer") or {}).get("hits") or []
    return hits[0].get("resource") if hits and isinstance(hits[0], dict) else None


def resource_ok(value, case):
    if not value:
        return False
    raw = " ".join(
        str(value.get(key) or "") for key in ("title", "canonicalURI", "localPath", "host")
    ).lower()
    return case["expected"].lower() in raw or case["title"].lower() in raw


def proc_sample(pid, duration=45):
    rows = []
    until = time.monotonic() + duration
    while time.monotonic() < until:
        result = cmd(["/bin/ps", "-p", str(pid), "-o", "%cpu=", "-o", "rss="], check=False)
        parts = result.stdout.split()
        if len(parts) >= 2:
            try:
                rows.append((float(parts[0]), float(parts[1]) / 1024))
            except ValueError:
                pass
        time.sleep(.5)
    cpu, memory = [value for value, _ in rows], [value for _, value in rows]
    return {
        "samples": len(rows), "cpu_mean": statistics.fmean(cpu) if cpu else None,
        "cpu_peak": max(cpu) if cpu else None,
        "rss_peak_mb": max(memory) if memory else None,
    }


def codex_matches(token):
    root = Path(os.environ.get("CODEX_HOME", Path.home() / ".codex")) / "memories"
    output = []
    if not root.is_dir():
        return output
    for path in root.rglob("*"):
        try:
            if (
                path.is_file() and path.suffix.lower() in {".md", ".json", ".jsonl", ".txt"}
                and path.stat().st_size < 10_000_000
                and token in path.read_text(errors="ignore")
            ):
                output.append(str(path))
        except OSError:
            pass
    return sorted(output)


def run_days(run):
    start, end = dt(run["started"]), dt(run.get("ended")) or datetime.now(timezone.utc)
    if not start:
        return []
    day, last, output = start.astimezone().date(), end.astimezone().date(), []
    while day <= last:
        output.append(day.isoformat())
        day += timedelta(days=1)
    return output


def score(run, cli):
    root, output = Path(run["data_root"]), Path(run["output"])
    events, semantic = jsonl(root / "events"), jsonl(root / "semantic")
    memories = [
        build_memory(cli, root, day, output / f"memory-{day}.json") for day in run_days(run)
    ]
    all_interactions = interactions(memories)
    by_id = {item["id"]: item for item in run["scenarios"]}
    stress = by_id.get("input_ground_truth")
    measures, detail = {}, {}
    if stress:
        rows = window(events, stress["start"], stress["end"])
        captured, truth = counts(rows), stress["truth"]
        expected = {
            "mouseClick": truth["clicks"], "keyboardShortcut": truth["shortcuts"],
            "scrollBurst": truth["scrolls"], "typingBurst": truth["typing"],
            "applicationActivated": truth["switches"] * 2,
        }
        core = ("mouseClick", "keyboardShortcut", "scrollBurst", "applicationActivated")
        measures["input_recall"] = (
            sum(min(captured.get(kind, 0), expected[kind]) for kind in core)
            / sum(expected[kind] for kind in core)
        )
        associated, total, token = 0, sum(expected.values()), run["token"]
        for kind, expected_count in expected.items():
            candidates = [row for row in rows if row.get("kind") == kind]
            if kind == "applicationActivated":
                good = [
                    row for row in candidates if ((row.get("app") or {}).get("bundleIdentifier")
                    in {"com.apple.Safari", "com.apple.TextEdit", "com.google.Chrome"})
                ]
            else:
                good = [
                    row for row in candidates
                    if token.lower() in json.dumps(row, ensure_ascii=False).lower()
                    or "127.0.0.1" in json.dumps(row)
                ]
            associated += min(len(good), expected_count)
        measures["association_accuracy"] = associated / total
        interaction_rows = window(all_interactions, stress["start"], stress["end"], 1)
        important = sum(expected[kind] for kind in ACTION_TO_INTERACTION)
        paired = changed = 0
        for event_kind, action_kind in ACTION_TO_INTERACTION.items():
            candidates = [item for item in interaction_rows if item.get("action") == action_kind]
            expected_count = expected[event_kind]
            paired += min(sum(bool(item.get("beforeContext") and item.get("afterContext")) for item in candidates), expected_count)
            changed += min(sum(bool(item.get("semanticDelta")) for item in candidates), expected_count)
        measures["before_after"] = paired / important
        measures["semantic_changes"] = changed / important
        detail["input"] = {
            "expected": expected, "captured": captured, "interactions": len(interaction_rows),
            "paired": paired, "changed": changed,
        }
    privacy = []
    for case in run["scenarios"]:
        if case.get("skipped") or not case.get("no_details"):
            continue
        event_window = window(events, case["start"], case["end"])
        semantic_window = window(semantic, case["start"], case["end"])
        target = [item for item in event_window + semantic_window if target_match(item, case)]
        marker = (case.get("marker") or "").lower()
        marker_leaks = sum(marker in json.dumps(item, ensure_ascii=False).lower() for item in target) if marker else 0
        action_leaks = sum(
            case.get("strict") and target_match(item, case)
            and item.get("kind") in {"mouseClick", "keyboardShortcut", "typingBurst", "scrollBurst", "semanticSnapshot"}
            and item.get("suppressionReason") is None for item in event_window
        )
        semantic_leaks = sum(target_match(item, case) for item in semantic_window)
        reason_observed = any(
            item.get("suppressionReason") == case.get("reason")
            or case.get("reason") in json.dumps(item) for item in event_window
        )
        privacy.append({
            "id": case["id"], "reason": reason_observed,
            "marker_leaks": marker_leaks, "action_leaks": action_leaks,
            "semantic_leaks": semantic_leaks,
            "pass": reason_observed and marker_leaks + action_leaks + semantic_leaks == 0,
        })
    measures["privacy_leaks"] = (
        sum(item["marker_leaks"] + item["action_leaks"] + item["semantic_leaks"] for item in privacy)
        if privacy else None
    )
    query_dir, found, reopened, resource_rows = output / "resource-queries", [], [], []
    for case in run["resources"]:
        value = resource(cli, root, case, query_dir / f"{case['id']}.json")
        correct = resource_ok(value, case)
        found.append(correct)
        if isinstance(case.get("reopened"), bool):
            reopened.append(case["reopened"])
        resource_rows.append({
            "id": case["id"], "correct": correct, "resource": value,
            "reopened": case.get("reopened"),
        })
    measures["resource_found"] = sum(found) / len(found) if found else None
    measures["resource_reopened"] = sum(reopened) / len(reopened) if reopened else None
    facts = (run.get("manual") or {}).get("facts") or []
    resumes = (run.get("manual") or {}).get("resume") or []
    measures["factual_accuracy"] = sum(item["correct"] for item in facts) / len(facts) if facts else None
    measures["resume_accuracy"] = sum(item["correct"] for item in resumes) / len(resumes) if resumes else None
    checks = {
        key: None if measures.get(key) is None else measures[key] >= threshold
        for key, threshold in THRESHOLDS.items()
    }
    checks["privacy_zero"] = (
        None if measures.get("privacy_leaks") is None
        else measures["privacy_leaks"] == 0 and all(item["pass"] for item in privacy)
    )
    scenario_complete = CORE_SCENARIOS <= set(by_id) and all(
        not by_id[identifier].get("skipped") for identifier in CORE_SCENARIOS
    )
    expected_events = {
        "textedit": {"mouseClick", "typingBurst", "keyboardShortcut", "scrollBurst"},
        "lock": {"sessionLocked", "sessionUnlocked"}, "spaces": {"windowChanged"},
    }
    scenario_checks = {}
    for identifier, kinds in expected_events.items():
        rows = window(events, by_id[identifier]["start"], by_id[identifier]["end"]) if identifier in by_id else []
        observed = {item.get("kind") for item in rows}
        scenario_checks[identifier] = {
            "missing": sorted(kinds - observed), "pass": kinds <= observed,
        }
    performance = run.get("performance") or {}
    performance_pass = (
        performance.get("responsive") is True and performance.get("samples", 0) > 0
        and (performance.get("cpu_mean") or 999) <= 50
        and (performance.get("rss_peak_mb") or 99999) <= 1024
    )
    signing = run["signature"]
    config_restored = run.get("config_restored") is True
    regressions = run.get("regressions") or {}
    regressions_ok = bool(regressions) and all(regressions.values())
    codex = run.get("codex") or {}
    codex_ok = codex.get("completed") is True if codex.get("accessible") else bool(codex.get("reason"))
    complete = all(value is not None for value in checks.values())
    thresholds_pass = complete and all(checks.values())
    eligible = (
        signing.get("developer_id_application")
        and signing.get("identifier") == "ai.goalong.localhistory"
        and not status_reasons(run["preflight"])
        and scenario_complete and all(item["pass"] for item in scenario_checks.values())
        and performance_pass and config_restored and regressions_ok and codex_ok
        and thresholds_pass
    )
    return {
        "schema": 1, "type": "real_foreground_macos", "synthetic_fixture": False,
        "public_parity_validated": bool(eligible),
        "status": "public_parity_validated" if eligible else "incomplete_or_below_threshold",
        "run_id": run["id"], "head": run["head"], "measurements": measures,
        "thresholds": THRESHOLDS, "checks": checks, "privacy": privacy,
        "resources": resource_rows, "input_detail": detail.get("input"),
        "required_scenarios_complete": scenario_complete, "scenario_checks": scenario_checks,
        "performance": {**performance, "guard_pass": performance_pass},
        "config_restored": config_restored, "regressions": regressions, "codex": codex,
        "limitations": [
            "Only this exact signed build/session/scenario set is measured.",
            "Synthetic 4/4 fixtures are not real capture or parity evidence.",
            "No claim covers undocumented proprietary internals.",
        ],
    }


def report_md(report):
    lines = [
        "# Goalong real Computer History benchmark", "",
        f"- Run: `{report['run_id']}`", f"- Commit: `{report['head']}`",
        f"- Result: **{report['status']}**", "- Synthetic fixture: **no**", "",
        "| Metric | Measured | Required | Result |", "|---|---:|---:|---|",
    ]
    for key, threshold in THRESHOLDS.items():
        measured = report["measurements"].get(key)
        rendered = "not measured" if measured is None else f"{measured * 100:.2f}%"
        lines.append(f"| {key} | {rendered} | {threshold * 100:.0f}% | {report['checks'].get(key)} |")
    lines.append(
        f"| privacy leaks | {report['measurements'].get('privacy_leaks')} | 0 | "
        f"{report['checks'].get('privacy_zero')} |"
    )
    lines += [
        "", "## Preconditions",
        f"- Required scenarios complete: {report['required_scenarios_complete']}",
        f"- Configuration restored: {report['config_restored']}",
        f"- Performance guard: {report['performance'].get('guard_pass')}",
        "", "## Codex comparison", "", "```json",
        json.dumps(report["codex"], indent=2), "```", "", "## Limitations",
    ]
    lines += [f"- {item}" for item in report["limitations"]]
    return "\n".join(lines) + "\n"


def review_resources(run, cli):
    root, output = Path(run["data_root"]), Path(run["output"]) / "resource-live-review"
    for case in run["resources"]:
        value = resource(cli, root, case, output / f"{case['id']}.json")
        print("\n", case["id"], json.dumps(value, indent=2, ensure_ascii=False) if value else "NO RESULT")
        if not resource_ok(value, case):
            case["reopened"] = False
            continue
        locator = value.get("localPath") or value.get("canonicalURI")
        if not locator:
            case["reopened"] = False
            continue
        subprocess.run(["/usr/bin/open", str(locator)], check=False)
        case["reopened"] = ask("Exact intended resource reopened?")


def manual_review(run, cli):
    root, output = Path(run["data_root"]), Path(run["output"])
    memories = []
    for day in run_days(run):
        path = output / f"memory-review-{day}.json"
        memories.append(str(path))
        build_memory(cli, root, day, path)
    print("Review memories:", *memories, sep="\n- ")
    facts = []
    for index, case in enumerate(run["resources"], 1):
        print(f"{index:02d}. {case['title']}")
        facts.append({
            "id": case["id"],
            "correct": ask("Correctly represented without invented facts?"),
        })
    questions = [
        "Where was I before the private-browsing test?",
        "Which page was used for physical-input ground truth?",
        "Which TextEdit file did I edit?", "What preceded Secure Input?",
        "Find Goalong Benchmark Page 03.", "Find Goalong Benchmark File 03.",
        "Which work was suppressed by app exclusion?",
        "Which site was denied by include-only?",
        "What remained after the resource sequence?",
        "Prepare a stand-up from this benchmark.",
    ]
    resumes, query_dir = [], output / "resume-queries"
    query_dir.mkdir(parents=True, exist_ok=True)
    for index, question in enumerate(questions, 1):
        result = cmd(
            [str(cli), "--root", str(root), "ask", "--days", "30", question],
            check=False,
        )
        (query_dir / f"{index:02d}.json").write_text(result.stdout)
        print("\n", question, "\n", result.stdout)
        resumes.append({"question": question, "correct": ask("Correct, useful, and evidence-backed?")})
    run["manual"] = {"facts": facts, "resume": resumes}


def codex_review(run):
    accessible = ask(
        "Is Codex Computer History accessible and enabled for this same window?", False
    )
    value = {"accessible": accessible, "completed": False}
    if not accessible:
        value["reason"] = input("Precise reason unavailable: ") or "not accessible"
        run["codex"] = value
        return
    value["memory_matches"] = codex_matches(run["token"])
    observations = {}
    for name in (
        "clicks", "typing", "shortcuts", "scrolls", "app switches", "before/after",
        "resources", "search/resume", "private", "Secure Input", "exclusions",
    ):
        observations[name] = ask(f"Did Codex correctly cover {name}?")
    value.update({
        "observations": observations, "notes": input("Visible differences: "),
        "completed": True,
    })
    run["codex"] = value


def execute(args):
    require_macos()
    repo = Path(args.repo).expanduser().resolve()
    root = Path(args.data_root).expanduser().resolve()
    app = Path(args.app).expanduser().resolve()
    head, dirty = git(repo, "rev-parse", "HEAD"), git(repo, "status", "--porcelain")
    if dirty and not args.allow_dirty:
        raise SystemExit("Use a clean worktree:\n" + dirty)
    if args.expected_head and head != args.expected_head:
        raise SystemExit(f"Expected {args.expected_head}, found {head}")
    signing = signature(app)
    if signing["identifier"] != "ai.goalong.localhistory":
        raise SystemExit("Wrong bundle identity")
    if not signing["developer_id_application"] and not args.allow_unstable_signature:
        subprocess.run(["security", "find-identity", "-v", "-p", "codesigning"])
        print(
            'Build with: LOCALHISTORY_CODESIGN_IDENTITY="Developer ID Application: …" '
            './scripts/build_app.sh\nInstall with: sudo ditto "dist/Goalong History.app" '
            '"/Applications/Goalong History.app"'
        )
        return 77
    cli = build_cli(repo)
    subprocess.run(["open", str(app)])
    preflight = status(cli, root)
    while reasons := status_reasons(preflight):
        print("Blocked:", *reasons, sep="\n- ")
        input(
            "Grant only Accessibility/Input Monitoring in System Settings, click Validate "
            "input, perform one physical click, then Enter…"
        )
        preflight = status(cli, root)
    stamp = datetime.now().astimezone().strftime("%Y%m%d-%H%M%S")
    run_id = f"goalong-real-{stamp}-{head[:8]}"
    output = (
        Path(args.output).expanduser().resolve()
        if args.output else Path.home() / "Desktop" / run_id
    )
    output.mkdir()
    token, port = f"GRB-{stamp}-{head[:6]}", free_port()
    fixture = fixtures(output / "fixtures", token, port)
    if (root / "config.json").is_file():
        shutil.copy2(root / "config.json", output / "config.before.json")
    run = {
        "schema": 1, "id": run_id, "token": token, "head": head,
        "branch": git(repo, "branch", "--show-current"), "repo": str(repo),
        "data_root": str(root), "output": str(output), "signature": signing,
        "preflight": preflight, "started": iso_now(), "port": port,
        "fixtures": fixture, "scenarios": [], "resources": fixture["resources"],
    }
    write_json(output / "run.json", run)
    state = WebState(token, fixture["target"], {key: 0 for key in fixture["target"]})
    with serve(Path(fixture["web"]), state, port):
        subprocess.run(["open", "-a", "TextEdit", fixture["edit"]])
        subprocess.run(["open", "-a", "Safari", f"http://127.0.0.1:{port}/benchmark.html"])
        print("Complete every physical ground-truth counter in Safari.")
        last = None
        while not state.snapshot()["complete"]:
            snapshot = state.snapshot()
            if snapshot["counters"] != last:
                print(snapshot["counters"], "/", snapshot["target"])
                last = snapshot["counters"]
            time.sleep(3)
        snapshot = state.snapshot()
        run["scenarios"].append({
            "id": "input_ground_truth", "start": snapshot["started"],
            "end": snapshot["ended"] or iso_now(), "truth": snapshot["counters"],
        })
        record(run, "textedit", "TextEdit causal transaction", [
            f"Use {fixture['edit']}",
            "Ten typing bursts separated by 2 s; Cmd-S; scroll; double-click; right-click.",
        ])
        record(run, "private", "Safari private window", [
            f"Private Safari: http://127.0.0.1:{port}/private.html; click/type/scroll; close.",
        ], marker=fixture["markers"]["private"], reason="privateBrowserWindow",
            no_details=True, bundle="com.apple.Safari", host="127.0.0.1", strict=True)
        record(run, "secure", "Terminal Secure Keyboard Entry", [
            "Separate Terminal window; enable Secure Keyboard Entry.",
            f"Run {fixture['secure_script']} without printing it; enter disposable text; "
            "close window while secure mode remains enabled.",
        ], marker=fixture["markers"]["secure"], reason="secureInput", no_details=True,
            text=fixture["secure_title"], strict=True)
        record(run, "excluded_app", "Excluded application", [
            "Apps: All except listed; exclude com.apple.TextEdit; save.",
            f"Open {fixture['excluded_file']} in TextEdit; click/type/scroll.",
        ], marker=fixture["markers"]["excluded_app"], reason="excludedApplication",
            no_details=True, bundle="com.apple.TextEdit", strict=True)
        record(run, "excluded_domain", "Excluded domain", [
            "Restore TextEdit. Sites: All except listed; exclude 127.0.0.1; save.",
            f"Normal Safari: http://127.0.0.1:{port}/excluded_domain.html; click/type/scroll.",
        ], marker=fixture["markers"]["excluded_domain"], reason="excludedDomain",
            no_details=True, bundle="com.apple.Safari", host="127.0.0.1", strict=True)
        record(run, "include_denied_app", "Application include-only denied", [
            "Apps: Only listed, allow com.apple.TextEdit only; save.",
            f"Finder: open {fixture['denied_folder']}; click/right-click/scroll.",
        ], marker=fixture["markers"]["include_denied_app"], reason="excludedApplication",
            no_details=True, bundle="com.apple.finder", strict=True)
        record(run, "include_allowed_app", "Application include-only allowed", [
            "Keep TextEdit allowed only; in normal benchmark file click, type, Cmd-S.",
        ])
        record(run, "include_denied_site", "Website include-only denied", [
            "Restore apps. Sites: Only listed, allow localhost but not 127.0.0.1.",
            f"Normal Safari: http://127.0.0.1:{port}/include_denied_site.html; click/type/scroll.",
        ], marker=fixture["markers"]["include_denied_site"], reason="excludedDomain",
            no_details=True, bundle="com.apple.Safari", host="127.0.0.1", strict=True)
        record(run, "include_allowed_site", "Website include-only allowed", [
            f"Keep localhost allowed; visit http://localhost:{port}/page-01.html; click/scroll.",
        ])
        print(
            "Restore normal benchmark capture: All except listed; allow "
            "TextEdit/Finder/Safari/localhost/127.0.0.1; save."
        )
        input("Enter when restored…")
        optional_cases = [
            ("chrome", "Chrome normal window", [
                f"Chrome: http://localhost:{port}/page-02.html; click/type/shortcut/scroll."
            ]),
            ("google_docs", "Google Docs", [
                f"Disposable doc titled Goalong Benchmark Google Doc {token}; type and sync."
            ]),
            ("chatgpt", "ChatGPT conversation", [
                f"Disposable conversation visibly containing {token}; send harmless message."
            ]),
            ("slack", "Slack conversation", [
                f"Disposable channel/thread containing {token}; harmless post/draft."
            ]),
            ("notes", "Apple Notes", [
                f"Disposable note titled Goalong Benchmark Note {token}; edit and switch away/back."
            ]),
            ("editor_terminal", "Editor and Terminal", [
                f"Open benchmark file in Xcode/VS Code and Terminal at {output / 'fixtures'}; "
                "save; pwd; ls."
            ]),
        ]
        for identifier, title, instructions in optional_cases:
            record(run, identifier, title, instructions, optional=True)
        record(run, "resources", "Twenty resource observations", [
            f"Safari: visit every link from {fixture['hub']}.",
            f"Finder/TextEdit: open all ten Goalong-Benchmark-File files in {fixture['files']}.",
        ])
        record(run, "lock", "Lock/unlock", [
            "Control-Command-Q; unlock normally; do not use benchmark markers in password field."
        ])
        record(run, "sleep", "Sleep/wake", ["Apple menu Sleep; wake and unlock."], optional=True)
        record(run, "spaces", "Spaces/full screen", [
            "Safari full screen; another Space; return; exit full screen."
        ])
        pids = cmd(["pgrep", "-x", "Goalong History"], check=False).stdout.split()
        if pids:
            input("Activity page ready. Enter immediately before opening Computer History…")
            started = time.monotonic()
            input("Enter when fully usable…")
            performance = proc_sample(int(pids[0]))
            performance["open_manual_s"] = time.monotonic() - started
            performance["responsive"] = ask("No beachball or sustained freeze?")
            run["performance"] = performance
        else:
            run["performance"] = {"error": "process not found"}
        review_resources(run, cli)
    run["ended"] = iso_now()
    manual_review(run, cli)
    codex_review(run)
    print("Restore exact pre-benchmark Settings from", output / "config.before.json")
    input("Enter after saving the exact original configuration…")
    try:
        run["config_restored"] = (
            load_json(output / "config.before.json") == load_json(root / "config.json")
        )
    except Exception:
        run["config_restored"] = False
    prompts = {
        "screen_time": "Screen Time still works?",
        "conversations": "Conversation analysis still works?",
        "agents": "Agent activity still works?",
        "integrity": "Integrity/sharing still works?",
        "updates": "Updates surface still works?",
    }
    run["regressions"] = {name: ask(question) for name, question in prompts.items()}
    write_json(output / "run.json", run)
    result = score(run, cli)
    write_json(output / "report.json", result)
    (output / "report.md").write_text(report_md(result))
    print(output / "report.md", result["status"])
    return 0 if result["public_parity_validated"] else 2


def analyze(args):
    require_macos()
    run = load_json(Path(args.run).expanduser())
    cli = build_cli(Path(run["repo"]))
    result = score(run, cli)
    output = Path(run["output"])
    write_json(output / "report.json", result)
    (output / "report.md").write_text(report_md(result))
    print(output / "report.md")
    return 0 if result["public_parity_validated"] else 2


def parse_args():
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    runner = subparsers.add_parser("run")
    runner.add_argument("--repo", default=str(Path(__file__).resolve().parents[1]))
    runner.add_argument(
        "--data-root", default=str(Path.home() / "Library/Application Support/LocalHistory")
    )
    runner.add_argument("--app", default="/Applications/Goalong History.app")
    runner.add_argument("--output")
    runner.add_argument("--expected-head")
    runner.add_argument("--allow-dirty", action="store_true")
    runner.add_argument("--allow-unstable-signature", action="store_true")
    analyzer = subparsers.add_parser("analyze")
    analyzer.add_argument("--run", required=True)
    return parser.parse_args()


def main():
    args = parse_args()
    return execute(args) if args.command == "run" else analyze(args)


if __name__ == "__main__":
    raise SystemExit(main())
