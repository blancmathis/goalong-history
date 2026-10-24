#!/usr/bin/env python3
"""Gallery orchestration (spec C §7-§8): render, manifest, index, diff, accept, clean.

Standard library only. Subcommands:
  run     [--only P] [--shards N] [--no-build]       render a new run, then diff it against the base
  diff    [--run R] [--base-env K] [--tol T] [--maxpx N]
  accept  [--run R] [--only P] [--force]
  index   [--run R]                                   rebuild index.html of a run
  clean                                               remove this checkout's runs

Paths:
  runs      <checkout>/qa/gallery/runs/<YYYYMMDD-HHMMSS>-<commit>/   (GALLERY_ROOT replaces <checkout>/qa/gallery)
  base      ~/Library/Caches/goalong-gallery/<env key>/baseline/     (GALLERY_CACHE replaces the cache folder,
                                                                      GALLERY_BASELINE replaces the base folder)
Nothing here opens a window or a browser, and nothing touches the network.
"""
from __future__ import annotations

import argparse
import datetime as dt
import errno
import fcntl
import html
import json
import os
import platform
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

SCHEMA = 2
KEEP_RUNS = 5
KEEP_BASE_KEYS = 3
MAX_RELAUNCHES = 40
STATUSES = ("ok", "unstable", "not-ready", "leaky", "timeout", "failed")
APP_ICON_LIMIT = ("Icônes d’apps : toujours l’initiale de l’app ; la galerie ne lit ni les apps installées ni "
                  "leurs icônes sur ce Mac.")
GUARD_LIMITS = ("Gardes : URLProtocol compté (aussi dans URLSession(configuration:)), NSTask lancé = échec, "
                "orderFront/beginSheet/runModal/statusItem = échec, UserDefaults.standard lu = leaky. "
                "Non couverts : posix_spawn/fork, sockets bas niveau, Network.framework, réseau d'un processus "
                "déjà lancé.")
# States spec C §6 lists that no catalogue entry renders yet (review C3-couverture-01): the index names them so a
# missing image reads as « non couvert », not as a forgotten state. Remove a line when its entry lands.
NOT_COVERED = (
    "Fenêtre : bannière après une mise à jour, bandeau Goalong Dev",
    "Activité : aperçu (mode développeur)",
    "Mon travail : agent absent",
    "Historique : filtres Temps d’écran et conversations",
    "Temps d’écran : importé, indisponible",
    "Conversations : consentement, liste, carte jetons (et fixtures §5.7)",
    "Bilan : chargement, erreur, rapport",
    "Surveillance : prête, interventions, panneau d’alerte Jev",
    "Distractions : suggestions",
    "Programme : semaine",
    "Blocage sévère : service absent, actif, « Retirer le service »",
    "Ambiance : erreur de téléchargement (page)",
    "Barre des menus : bouton avec badge dev",
    "Feuilles : import Santé, analyse de site, projets développeur",
    "Permissions : relance demandée",
    "Compte et site : non lié, appairage, lié, envoi auto, erreur, hors ligne ; carte ChatGPT (3 états) ; studio de profil",
    "Terminal : installé, lien cassé",
    "Mises à jour : 4 états",
    "Support : demande",
)
STALE_INDEX_LIMIT = ("Index : un accept réécrit l'index des runs de ce checkout ; un index ouvert depuis un autre "
                     "checkout ou une copie peut montrer une base remplacée depuis (make gallery-index pour le "
                     "réécrire).")

CHECKOUT = Path(__file__).resolve().parent.parent


def log(message: str) -> None:
    print(message, flush=True)


def fail(message: str, code: int = 2) -> "NoReturn":  # type: ignore[name-defined]
    print(f"gallery: {message}", file=sys.stderr, flush=True)
    sys.exit(code)


# ---------------------------------------------------------------- paths and environment

def gallery_root() -> Path:
    return Path(os.environ.get("GALLERY_ROOT") or CHECKOUT / "qa" / "gallery")


def runs_dir() -> Path:
    return gallery_root() / "runs"


def cache_dir() -> Path:
    return Path(os.environ.get("GALLERY_CACHE") or Path.home() / "Library" / "Caches" / "goalong-gallery")


def output(command: list[str]) -> str:
    try:
        return subprocess.run(command, capture_output=True, text=True, check=False, timeout=60).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return ""


def git(*args: str) -> str:
    return output(["git", "-C", str(CHECKOUT), *args])


def git_info() -> dict:
    status = git("status", "--porcelain", "--untracked-files=normal")
    return {"commit": git("rev-parse", "--short", "HEAD") or "unknown",
            "commitFull": git("rev-parse", "HEAD") or "unknown",
            "branch": git("rev-parse", "--abbrev-ref", "HEAD") or "unknown",
            "clean": status == "" and git("rev-parse", "HEAD") != ""}


def system_info() -> dict:
    xcode = output(["xcodebuild", "-version"]).splitlines()
    return {"macOS": output(["sw_vers", "-productVersion"]), "macOSBuild": output(["sw_vers", "-buildVersion"]),
            "xcode": xcode[0].replace("Xcode ", "") if xcode else "",
            "xcodeBuild": xcode[-1].split()[-1] if xcode else "", "arch": platform.machine()}


def env_key(system: dict, scale: float) -> str:
    override = os.environ.get("GALLERY_ENVKEY")
    if override:
        return override
    return f"{system['macOSBuild'] or 'unknown'}-{system['xcodeBuild'] or 'unknown'}-{system['arch']}-{scale:g}x"


def baseline_dir(key: str, base_env: str | None = None) -> Path:
    if os.environ.get("GALLERY_BASELINE"):
        return Path(os.environ["GALLERY_BASELINE"])
    return cache_dir() / (base_env or key) / "baseline"


def resolve_run(name: str | None) -> Path:
    name = name or "latest"
    candidate = Path(name)
    if candidate.is_absolute() or (candidate.exists() and (candidate / "manifest.json").exists()):
        run = candidate
    elif name == "latest":
        run = gallery_root() / "latest"
    else:
        run = runs_dir() / name
    run = run.resolve()
    if not (run / "manifest.json").exists():
        fail(f"run introuvable : {run} (lancer make gallery)")
    return run


def read_json(path: Path) -> dict:
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def write_json(path: Path, value: dict) -> None:
    temporary = path.with_name(f".{path.name}.tmp")
    with open(temporary, "w", encoding="utf-8") as handle:
        json.dump(value, handle, ensure_ascii=False, indent=1, sort_keys=True)
        handle.write("\n")
    os.replace(temporary, path)


def matches(identifier: str, only: str | None) -> bool:
    """Same rule as GalleryCatalog.filtered: comma-separated id prefixes."""
    if not only:
        return True
    prefixes = [part.strip() for part in only.split(",") if part.strip()]
    return not prefixes or any(identifier == prefix or identifier.startswith(prefix) for prefix in prefixes)


# ---------------------------------------------------------------- diff tool

def diff_tool() -> Path:
    source = CHECKOUT / "scripts" / "gallery_diff.swift"
    binary = Path(os.environ.get("GALLERY_TOOLS") or CHECKOUT / ".build" / "gallery-tools") / "gallery-diff"
    if binary.exists() and binary.stat().st_mtime >= source.stat().st_mtime:
        return binary
    binary.parent.mkdir(parents=True, exist_ok=True)
    temporary = binary.with_name(f".gallery-diff-{os.getpid()}")
    result = subprocess.run(["xcrun", "swiftc", "-O", str(source), "-o", str(temporary)],
                            capture_output=True, text=True, check=False)
    if result.returncode != 0:
        fail(f"compilation de gallery_diff.swift impossible :\n{result.stderr[-2000:]}")
    os.replace(temporary, binary)
    return binary


def pixel_diff(pairs: list[tuple[Path, Path, Path, int]]) -> list[dict]:
    if not pairs:
        return []
    lines = "".join(f"{base}\t{current}\t{diff}\t{tol}\n" for base, current, diff, tol in pairs)
    result = subprocess.run([str(diff_tool())], input=lines, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        fail(f"gallery-diff a échoué : {result.stderr[-2000:]}")
    return [json.loads(line) for line in result.stdout.splitlines() if line.strip()]


# ---------------------------------------------------------------- render

class Homes:
    """Throwaway shard HOMEs under /tmp/goalong-gallery-<run>/; all removed on exit, error or signal (spec §8).

    Each HOME sits one level below the run folder: Goalong trusts the parent of its data folders and opens them
    without following symlinks, so that parent must be a real folder, not /tmp (a symlink to /private/tmp).
    """

    def __init__(self, run_name: str) -> None:
        self.root = Path("/private/tmp") / f"goalong-gallery-{run_name}"
        self.paths: set[str] = set()

    def new(self, shard: int) -> str:
        self.root.mkdir(mode=0o700, exist_ok=True)
        path = tempfile.mkdtemp(prefix=f"shard-{shard}-", dir=self.root)
        self.paths.add(path)
        return path

    def remove(self, path: str) -> None:
        shutil.rmtree(path, ignore_errors=True)
        self.paths.discard(path)

    def remove_all(self) -> None:
        for path in list(self.paths):
            self.remove(path)
        shutil.rmtree(self.root, ignore_errors=True)


def build() -> None:
    log("gallery: build (swift build --build-tests --jobs 6)")
    result = subprocess.run(["xcrun", "swift", "build", "--build-tests", "--jobs", "6"], cwd=CHECKOUT, check=False)
    if result.returncode != 0:
        fail("build en échec", 1)


LAUNCH_ARGUMENTS = ["-AppleLocale", "fr_FR", "-AppleLanguages", "(fr)", "-AppleAccentColor", "4",
                    "-AppleShowScrollBars", "WhenScrolling"]


def shard_command(run: Path, shard: int, shards: int, home: str, only: str | None) -> list[str]:
    environment = ["PATH=/usr/bin:/bin", "TZ=Europe/Paris", f"HOME={home}", f"CFFIXED_USER_HOME={home}",
                   f"GOALONG_GALLERY={run}", f"GOALONG_GALLERY_SHARD={shard}/{shards}"]
    if only:
        environment.append(f"GOALONG_GALLERY_ONLY={only}")
    probe = os.environ.get("GOALONG_GALLERY_CLOCK_PROBE")
    if probe in ("1", "-1"):  # one day later or earlier
        environment.append(f"GOALONG_GALLERY_CLOCK_PROBE={probe}")
    xctest = CHECKOUT / ".build" / "debug" / "LocalHistoryPackageTests.xctest"
    # Spec C §3-4: the arguments domain is read only before -XCTest. The fake HOME has no global preferences, so the
    # accent colour and the scroll-bar style (else « Automatic »: legacy bars once a mouse is plugged in) are fixed here.
    return ["/usr/bin/env", "-i", *environment, "/usr/bin/xcrun", "xctest", *LAUNCH_ARGUMENTS,
            "-XCTest", "LocalHistoryAppTests.GalleryTests", str(xctest)]


def render(run: Path, shards: int, only: str | None, homes: Homes) -> list[str]:
    """Runs the shards in parallel; a shard stopped by the watchdog (code 3) restarts with a fresh HOME."""
    problems: list[str] = []
    running: dict[int, tuple[subprocess.Popen, str, object]] = {}
    relaunches = {shard: 0 for shard in range(shards)}

    def start(shard: int) -> None:
        home = homes.new(shard)
        handle = open(run / f"shard-{shard}.log", "a", encoding="utf-8")
        handle.write(f"--- launch {relaunches[shard] + 1} HOME={home}\n")
        handle.flush()
        process = subprocess.Popen(shard_command(run, shard, shards, home, only), cwd=CHECKOUT,
                                   stdout=handle, stderr=subprocess.STDOUT, start_new_session=True)
        running[shard] = (process, home, handle)

    for shard in range(shards):
        start(shard)
    try:
        while running:
            time.sleep(0.2)
            for shard, (process, home, handle) in list(running.items()):
                code = process.poll()
                if code is None:
                    continue
                handle.close()  # type: ignore[attr-defined]
                homes.remove(home)
                del running[shard]
                if code == 3 and relaunches[shard] < MAX_RELAUNCHES:
                    relaunches[shard] += 1
                    log(f"gallery: shard {shard} relancé après le chien de garde ({relaunches[shard]})")
                    start(shard)
                elif code != 0:
                    problems.append(f"shard {shard} : code {code} (voir shard-{shard}.log)")
    finally:
        for process, home, handle in running.values():
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
            handle.close()  # type: ignore[attr-defined]
    return problems


def merge_results(run: Path) -> tuple[list[dict], dict]:
    images: dict[str, dict] = {}
    for path in sorted(run.glob("results-*.jsonl")):
        for line in path.read_text(encoding="utf-8").splitlines():
            if line.strip():
                entry = json.loads(line)
                images[entry["key"]] = entry
    environments = [read_json(path) for path in sorted(run.glob("env-*.json"))]
    return sorted(images.values(), key=lambda item: item["key"]), (environments[0] if environments else {})


def manifest_image(entry: dict) -> dict:
    return {"key": entry["key"], "id": entry["id"], "surface": entry.get("surface", ""),
            "state": entry.get("state", ""), "theme": entry.get("theme", ""), "size": entry.get("size", ""),
            "file": "png/" + entry["file"], "points": [entry.get("pointWidth", 0), entry.get("pointHeight", 0)],
            "pixels": [entry.get("pixelWidth", 0), entry.get("pixelHeight", 0)], "scale": entry.get("scale", 0),
            "sha256": entry.get("hash", ""), "status": entry.get("status", "failed"), "detail": entry.get("detail", ""),
            "ms": entry.get("ms", 0), "source": entry.get("source", ""), "note": entry.get("note", ""),
            **({"standardStack": entry["standardStack"]} if entry.get("standardStack") else {})}


def duplicate_groups(images: list[dict]) -> list[list[str]]:
    """Images with the same pixels that come from different entries (ids), as sorted groups of keys."""
    by_hash: dict[str, list[dict]] = {}
    for image in images:
        if image.get("sha256") and image.get("status") == "ok":
            by_hash.setdefault(image["sha256"], []).append(image)
    groups = [sorted(image["key"] for image in group) for group in by_hash.values()
              if len({image["id"] for image in group}) > 1]
    return sorted(groups)


def new_run_dir(name: str) -> Path:
    """A fresh run folder; two runs in the same second on the same commit get -2, -3… (a run is never rewritten)."""
    runs_dir().mkdir(parents=True, exist_ok=True)
    for attempt in range(1, 100):
        run = runs_dir() / (name if attempt == 1 else f"{name}-{attempt}")
        try:
            run.mkdir()
            return run
        except FileExistsError:
            continue
    fail(f"impossible de créer un dossier de run neuf pour {name} dans {runs_dir()}")


def command_run(args: argparse.Namespace) -> int:
    if not args.no_build:
        build()
    diff_tool()
    info, system = git_info(), system_info()
    stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    run = new_run_dir(f"{stamp}-{info['commit']}")
    name = run.name
    homes = Homes(name)
    previous = {sig: signal.getsignal(sig) for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)}

    def interrupted(signum, _frame):
        homes.remove_all()
        raise SystemExit(128 + signum)

    for sig in previous:
        signal.signal(sig, interrupted)
    started = time.time()
    log(f"gallery: rendu dans {run} ({args.shards} shard(s){', ONLY=' + args.only if args.only else ''})")
    try:
        problems = render(run, args.shards, args.only, homes)
    finally:
        homes.remove_all()
        for sig, handler in previous.items():
            signal.signal(sig, handler)
    duration = round(time.time() - started, 1)
    results, environment = merge_results(run)
    if not results:
        problems.append("aucune image rendue")
    scale = float(environment.get("windowScale") or environment.get("screenScale") or 0)
    manifest = {
        "schema": SCHEMA, "run": name, "commit": info["commit"], "commitFull": info["commitFull"],
        "branch": info["branch"], "clean": info["clean"], "date": dt.datetime.now().astimezone().isoformat(timespec="seconds"),
        **system, "envKey": env_key(system, scale),
        "screen": {"width": environment.get("screenWidth"), "height": environment.get("screenHeight"),
                   "scale": environment.get("screenScale")},
        "windowScale": environment.get("windowScale"), "locale": environment.get("locale"),
        "timeZone": environment.get("timeZone"), "clock": environment.get("clock"),
        "clockProbe": environment.get("clockProbe", 0), "guards": environment.get("guards", False),
        "shards": args.shards, "only": args.only or "", "duration": duration, "problems": problems,
        "images": [manifest_image(entry) for entry in results],
    }
    manifest["duplicates"] = duplicate_groups(manifest["images"])
    write_json(run / "manifest.json", manifest)
    counts = {status: 0 for status in STATUSES}
    for image in manifest["images"]:
        counts[image["status"]] = counts.get(image["status"], 0) + 1
    with open(run / "render.log", "w", encoding="utf-8") as handle:
        handle.write(f"run {name}\nenv {manifest['envKey']}\nduration {duration}s\n")
        handle.write("".join(f"{key} {value}\n" for key, value in counts.items()))
        for image in manifest["images"]:
            if image["status"] != "ok":
                handle.write(f"{image['status']}\t{image['key']}\t{image['detail']}\n")
        for problem in problems:
            handle.write(f"problem\t{problem}\n")
    report = compare_after_render(run, manifest)
    write_index(run)
    link = gallery_root() / "latest"
    temporary = gallery_root() / ".latest.tmp"
    if temporary.is_symlink() or temporary.exists():
        temporary.unlink()
    temporary.symlink_to(Path("runs") / name)
    os.replace(temporary, link)
    prune_runs()
    log(f"gallery: {len(manifest['images'])} images en {duration} s — "
        + ", ".join(f"{key} {value}" for key, value in counts.items() if value))
    print_report(report)
    for image in manifest["images"]:
        if image["status"] != "ok":
            log(f"  {image['status']:9} {image['key']}  {image['detail']}")
    for problem in problems:
        log(f"  problème : {problem}")
    if manifest["duplicates"]:
        # Not a failure: an entry may legitimately match another (Surveillance opens Réglages › Jev). But a group
        # of different states with one image is how blank pages and ignored fixtures were found.
        log(f"gallery: {len(manifest['duplicates'])} groupe(s) d’images identiques entre états différents :")
        for group in manifest["duplicates"]:
            log("  identiques  " + "  ".join(group))
    log(f"gallery: index : {run / 'index.html'}")
    bad = problems or any(image["status"] != "ok" for image in manifest["images"])
    return 1 if bad else 0


def compare_after_render(run: Path, manifest: dict) -> dict:
    """The run's diff; a base held too long by another accept or diff leaves a note instead of an exit: the images
    are rendered, the run still gets its index and becomes `latest` (C2-outil-06)."""
    try:
        return compare(run, manifest, None, 0, 0)
    except BaseLocked as error:
        report = {"run": manifest["run"], "runKey": manifest["envKey"], "noBase": True, "baseLocked": True,
                  "message": f"diff non fait ({error}) ; relancer make gallery-diff RUN={manifest['run']}",
                  "changed": [], "new": [], "missing": [], "resized": [], "notOk": [], "same": 0, "withinTolerance": 0}
        write_json(run / "diff.json", report)
        return report


def prune_runs() -> None:
    runs = sorted(path for path in runs_dir().iterdir() if path.is_dir() and not path.name.startswith("."))
    latest = (gallery_root() / "latest").resolve()
    for old in runs[:-KEEP_RUNS]:
        if old.resolve() != latest:
            shutil.rmtree(old, ignore_errors=True)


# ---------------------------------------------------------------- diff

def compare(run: Path, manifest: dict, base_env: str | None, tol: int, maxpx: int) -> dict:
    """Compares a run with a base; writes diff/ PNGs and diff.json in the run. Same hash = same pixels."""
    key = manifest["envKey"]
    base = baseline_dir(key, base_env)
    report: dict = {"run": manifest["run"], "runKey": key, "base": str(base), "tol": tol, "maxpx": maxpx,
                    "changed": [], "new": [], "missing": [], "resized": [], "notOk": [], "same": 0,
                    "withinTolerance": 0}
    # Shared lock: an accept swaps the base with two renames; a diff never reads between them.
    if not base.parent.is_dir():
        return compare_locked(run, manifest, base, base_env, report, tol, maxpx)  # no base, nothing to lock
    with BaseLock(base, shared=True):
        return compare_locked(run, manifest, base, base_env, report, tol, maxpx)


def compare_locked(run: Path, manifest: dict, base: Path, base_env: str | None, report: dict, tol: int,
                   maxpx: int) -> dict:
    key = manifest["envKey"]
    base_manifest_path = base / "manifest.json"
    if not base_manifest_path.exists():
        report["baseKey"] = base_env or key
        report["cause"] = "environnement"
        report["noBase"] = True
        report["message"] = (f"pas de base pour {base_env or key} ; comparer avec BASE_ENV=<ancienne clé> TOL=…"
                             + (f" (clés connues : {', '.join(known_keys())})" if known_keys() else ""))
        write_json(run / "diff.json", report)
        return report
    base_manifest = read_json(base_manifest_path)
    report["baseKey"] = base_manifest.get("envKey", base_env or key)
    report["baseCommit"] = base_manifest.get("commit", "")
    report["baseRevision"] = base_revision(base_manifest)
    if len(base_manifest.get("accepts") or []) > 1:
        report["basePartialAccepts"] = base_manifest["accepts"][1:]
    report["cause"] = "code" if report["baseKey"] == key else "environnement"
    current = {image["key"]: image for image in manifest["images"]}
    previous = {image["key"]: image for image in base_manifest.get("images", [])
                if matches(image["id"], manifest.get("only"))}
    shutil.rmtree(run / "diff", ignore_errors=True)
    pairs, keys = [], []
    for name, image in current.items():
        if image.get("status", "ok") != "ok":
            # A timeout or a failed render is not a pixel change: say what happened to it.
            report["notOk"].append({"key": name, "status": image.get("status", ""), "detail": image.get("detail", "")})
        elif name not in previous:
            report["new"].append({"key": name})
        elif image["sha256"] and image["sha256"] == previous[name]["sha256"] and tol == 0:
            report["same"] += 1
        else:
            pairs.append((base / previous[name]["file"], run / image["file"], run / "diff" / name, tol))
            keys.append(name)
    for name, result in zip(keys, pixel_diff(pairs)):
        if "error" in result:
            report["changed"].append({"key": name, "error": result["error"], "percent": 100.0})
        elif result.get("sizeChanged"):
            report["resized"].append({"key": name, "baseSize": result["baseSize"], "currentSize": result["currentSize"]})
        elif result["changed"] == 0 or result["changed"] <= maxpx:
            report["same" if result["changed"] == 0 else "withinTolerance"] += 1
            if result["changed"]:
                (run / "diff" / name).unlink(missing_ok=True)
        else:
            report["changed"].append({"key": name, "pixels": result["changed"], "percent": round(result["percent"], 3),
                                      "bbox": result.get("bbox"), "maxDelta": result.get("maxDelta"),
                                      "diff": "diff/" + name,
                                      "baseCommit": previous[name].get("acceptedCommit", report["baseCommit"])})
    report["missing"] = [{"key": name} for name in sorted(set(previous) - set(current))]
    write_json(run / "diff.json", report)
    return report


def base_revision(base_manifest: dict) -> str:
    """Identity of a base's content; bases accepted before `revision` existed fall back to their run."""
    return base_manifest.get("revision") or base_manifest.get("acceptedFrom", "")


def known_keys() -> list[str]:
    if not cache_dir().exists():
        return []
    return sorted(path.name for path in cache_dir().iterdir() if (path / "baseline" / "manifest.json").exists())


def differences(report: dict) -> int:
    return (len(report["changed"]) + len(report["new"]) + len(report["missing"]) + len(report["resized"])
            + len(report.get("notOk", [])))


def print_report(report: dict) -> None:
    if report.get("noBase"):
        log(f"gallery: diff — {report['message']}")
        return
    count = differences(report)
    partial = report.get("basePartialAccepts") or []
    commits = ", ".join(sorted({item.get("commit", "?") for item in partial}))
    header = (f"gallery: diff contre {report['baseKey']} (commit {report.get('baseCommit') or '?'}"
              + (f", + {len(partial)} accept(s) partiel(s) : {commits}" if partial else "") + ") — "
              f"{count} écart(s), {report['same']} identique(s)")
    if report["withinTolerance"]:
        header += f", {report['withinTolerance']} sous MAXPX"
    log(header)
    if count:
        log(f"  cause probable : {report['cause']}"
            + (f" (clé du run {report['runKey']} ≠ clé de la base {report['baseKey']})"
               if report["cause"] == "environnement" else " (même clé env)"))
    for item in report["changed"]:
        box = item.get("bbox")
        where = f" boîte {box[0]},{box[1]} {box[2]}×{box[3]} px" if box else ""
        origin = f"  (base : {item['baseCommit']})" if partial and item.get("baseCommit") else ""
        log(f"  changé          {item['key']}  {item['percent']} %{where}{origin}"
            + (f"  {item['error']}" if item.get("error") else ""))
    for item in report["resized"]:
        log(f"  taille changée  {item['key']}  {item['baseSize'][0]}×{item['baseSize'][1]} → "
            f"{item['currentSize'][0]}×{item['currentSize'][1]} px")
    for item in report.get("notOk", []):
        log(f"  non ok          {item['key']}  {item['status']}" + (f" : {item['detail']}" if item.get("detail") else ""))
    for item in report["new"]:
        log(f"  nouveau         {item['key']}")
    for item in report["missing"]:
        log(f"  disparu         {item['key']}")


def command_diff(args: argparse.Namespace) -> int:
    run = resolve_run(args.run)
    manifest = read_json(run / "manifest.json")
    try:
        report = compare(run, manifest, args.base_env or None, args.tol, args.maxpx)
    except BaseLocked as error:
        fail(str(error), 3)
    write_index(run)
    print_report(report)
    log(f"gallery: index : {run / 'index.html'}")
    return 1 if report.get("noBase") or differences(report) else 0


# ---------------------------------------------------------------- accept

class BaseLocked(Exception):
    """Another accept or diff held the base past GALLERY_LOCK_TIMEOUT."""


class BaseLock:
    def __init__(self, base: Path, shared: bool = False) -> None:
        base.parent.mkdir(parents=True, exist_ok=True)
        self.mode = fcntl.LOCK_SH if shared else fcntl.LOCK_EX
        self.path = base.parent / f"{base.name}.lock" if os.environ.get("GALLERY_BASELINE") else base.parent / "baseline.lock"
        self.handle = None

    def __enter__(self) -> "BaseLock":
        if self.handle is not None:
            return self  # already held: `lock = BaseLock(b).__enter__()` then `with lock:`
        self.handle = open(self.path, "a+")
        deadline = time.time() + float(os.environ.get("GALLERY_LOCK_TIMEOUT", "60"))
        while True:
            try:
                fcntl.flock(self.handle, self.mode | fcntl.LOCK_NB)
                return self
            except OSError as error:
                if error.errno not in (errno.EAGAIN, errno.EACCES) or time.time() >= deadline:
                    self.handle.close()
                    self.handle = None
                    raise BaseLocked(f"base verrouillée par un autre accept ou diff ({self.path})") from None
                time.sleep(0.2)

    def __exit__(self, *_exc) -> None:
        fcntl.flock(self.handle, fcntl.LOCK_UN)
        self.handle.close()
        self.handle = None


def command_accept(args: argparse.Namespace) -> int:
    run = resolve_run(args.run)
    manifest = read_json(run / "manifest.json")
    if not manifest.get("clean"):
        fail(f"refusé : le run {manifest['run']} vient d'un arbre non propre (commit {manifest['commit']}) ; "
             "committer puis relancer make gallery")
    # A run made with ONLY= holds only part of the catalogue: its accept is always partial, limited to both filters,
    # so the rest of the base stays (else `make gallery ONLY=settings/` then accept emptied the shared base).
    run_only = manifest.get("only") or ""
    filters = [only for only in (args.only, run_only) if only]

    def in_scope(identifier: str) -> bool:
        return all(matches(identifier, only) for only in filters)

    label = " et ".join(f"ONLY={only}" for only in filters) or "ONLY=*"
    if manifest.get("problems") and not args.force:
        fail("refusé : le run a des problèmes (images peut-être manquantes) : " + " ; ".join(manifest["problems"])
             + " ; relancer make gallery, ou FORCE=1")
    selected = [image for image in manifest["images"] if in_scope(image["id"])]
    if not selected:
        fail(f"aucune image ne correspond à {label}")
    bad = [image for image in selected if image["status"] != "ok"]
    if bad:
        fail("refusé : entrées non ok dans le filtre : "
             + ", ".join(f"{image['key']} ({image['status']})" for image in bad[:10])
             + (" …" if len(bad) > 10 else ""))
    base = baseline_dir(manifest["envKey"])
    try:
        lock = BaseLock(base).__enter__()
    except BaseLocked as error:
        fail(str(error), 3)
    with lock:
        old_manifest = read_json(base / "manifest.json") if (base / "manifest.json").exists() else None
        if old_manifest and not args.force:
            for field, current, previous in (
                ("échelle de l'écran", (manifest.get("screen") or {}).get("scale"),
                 (old_manifest.get("screen") or {}).get("scale")),
                ("échelle de la fenêtre", manifest.get("windowScale"), old_manifest.get("windowScale"))):
                if current != previous:
                    fail(f"refusé : {field} {current} ≠ base {previous} ; FORCE=1 pour remplacer")
        staging = Path(tempfile.mkdtemp(prefix=".baseline-", dir=base.parent))
        try:
            images: dict[str, dict] = {}
            if old_manifest and filters:
                # Partial accept: the base keeps every image outside the filters.
                shutil.copytree(base / "png", staging / "png", dirs_exist_ok=True)
                images = {image["key"]: image for image in old_manifest.get("images", [])
                          if not in_scope(image["id"])}
            for image in selected:
                target = staging / image["file"]
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(run / image["file"], target)
                images[image["key"]] = {**image, "acceptedCommit": manifest["commit"], "acceptedFrom": manifest["run"]}
            if filters and old_manifest:
                for path in (staging / "png").rglob("*.png"):
                    key = str(path.relative_to(staging / "png"))
                    if key not in images:
                        path.unlink()
            accepted_at = dt.datetime.now().astimezone().isoformat(timespec="seconds")
            accept = {"run": manifest["run"], "commit": manifest["commit"], "only": label, "date": accepted_at,
                      "images": len(selected)}
            if old_manifest and filters:
                # Partial accept: the header still describes the full accept most images come from; this accept
                # joins the history and each image keeps its own commit (C2-outil-04).
                fields = {key: value for key, value in old_manifest.items() if key not in ("images", "accepts")}
                accepts = old_manifest.get("accepts") or [{"run": old_manifest.get("acceptedFrom", ""),
                                                           "commit": old_manifest.get("commit", ""),
                                                           "only": old_manifest.get("only") or "ONLY=*"}]
            else:
                fields = {key: value for key, value in manifest.items() if key not in ("images", "problems")}
                fields["acceptedFrom"] = manifest["run"]
                accepts = []
            # A new value at every accept: a run's index knows when the base it was compared with was replaced.
            fields["revision"] = f"{manifest['run']}@{time.time_ns()}"
            write_json(staging / "manifest.json", {**fields, "accepts": accepts + [accept],
                                                   "images": sorted(images.values(), key=lambda item: item["key"])})
            history = (base / "accept.log").read_text(encoding="utf-8") if (base / "accept.log").exists() else ""
            line = (f"{dt.datetime.now().astimezone().isoformat(timespec='seconds')}\t{manifest['run']}\t"
                    f"{manifest['commit']}\t{label}\t{len(selected)} image(s)"
                    f"{chr(9) + 'FORCE' if args.force else ''}\n")
            (staging / "accept.log").write_text(history + line, encoding="utf-8")
            retired = None
            if base.exists():
                retired = base.parent / f".retired-{os.getpid()}-{time.time_ns()}"
                os.rename(base, retired)
            os.rename(staging, base)
            staging = None
            if retired:
                shutil.rmtree(retired, ignore_errors=True)
        finally:
            if staging:
                shutil.rmtree(staging, ignore_errors=True)
    if not os.environ.get("GALLERY_BASELINE"):
        prune_base_keys(manifest["envKey"])
    refreshed = refresh_indexes(base)
    log(f"gallery: {len(selected)} image(s) acceptée(s) dans {base} ; index réécrit pour {refreshed} run(s) de ce "
        "checkout comparé(s) à cette base (autre checkout : make gallery-index)")
    return 0


def refresh_indexes(base: Path) -> int:
    """Rewrites the index of this checkout's runs whose diff targets `base`: a static index otherwise keeps showing
    the replaced base's live file:// URL as the base its percentages describe (C3-outil-01)."""
    if not runs_dir().is_dir():
        return 0
    refreshed = 0
    for run in sorted(runs_dir().iterdir()):
        try:
            if not (run / "manifest.json").exists() or not (run / "diff.json").exists():
                continue
            if Path(read_json(run / "diff.json").get("base", "")).resolve() != base.resolve():
                continue
            write_index(run)
            refreshed += 1
        except (OSError, ValueError, KeyError) as error:
            log(f"gallery: index de {run.name} non réécrit : {error}")
    return refreshed


def prune_base_keys(current: str) -> None:
    keys = [path for path in cache_dir().iterdir() if path.is_dir() and (path / "baseline").exists()]
    keys.sort(key=lambda path: (path / "baseline").stat().st_mtime, reverse=True)
    kept = 0
    for path in keys:
        if path.name == current or kept < KEEP_BASE_KEYS - 1:
            kept += path.name != current
            continue
        shutil.rmtree(path, ignore_errors=True)


# ---------------------------------------------------------------- clean

def command_clean(_args: argparse.Namespace) -> int:
    link = gallery_root() / "latest"
    if link.is_symlink():
        link.unlink()
    shutil.rmtree(runs_dir(), ignore_errors=True)
    log(f"gallery: runs supprimés ({runs_dir()}) ; la base partagée reste")
    return 0


# ---------------------------------------------------------------- index

INDEX_STYLE = """
:root{color-scheme:light dark;--bg:#f6f5f2;--fg:#1d1d1f;--mute:#6e6e73;--card:#fff;--line:#d8d6d0;--bad:#c4372b;--chg:#c026d3}
@media (prefers-color-scheme:dark){:root{--bg:#18181a;--fg:#ececee;--mute:#9a9aa0;--card:#232326;--line:#3a3a3e}}
*{box-sizing:border-box}body{margin:0;font:13px/1.45 -apple-system,system-ui,sans-serif;background:var(--bg);color:var(--fg)}
header{padding:16px 22px;border-bottom:1px solid var(--line)}h1{font-size:18px;margin:0 0 4px}
.meta{color:var(--mute)}.meta b{color:var(--fg);font-weight:600}.limits{color:var(--mute);font-size:12px;margin-top:6px}
.bar{display:flex;gap:10px;flex-wrap:wrap;padding:10px 22px;border-bottom:1px solid var(--line);position:sticky;top:0;background:var(--bg);z-index:2}
select,input{font:inherit}h2{font-size:15px;margin:22px 22px 8px}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(230px,1fr));gap:12px;padding:0 22px}
.card{background:var(--card);border:1px solid var(--line);border-radius:8px;overflow:hidden;cursor:pointer}
.card img{display:block;width:100%;height:160px;object-fit:contain;object-position:top;background:repeating-conic-gradient(#8881 0 25%,#0000 0 50%) 0 0/16px 16px}
.card .t{padding:6px 8px;display:flex;justify-content:space-between;gap:6px}.card .k{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.tag{font-size:11px;padding:0 6px;border-radius:9px;border:1px solid var(--line);white-space:nowrap}
.tag.bad{color:#fff;background:var(--bad);border-color:var(--bad)}.tag.chg{color:#fff;background:var(--chg);border-color:var(--chg)}
#view{position:fixed;inset:0;background:#000c;display:none;z-index:5;overflow:auto;padding:20px;color:#eee}
#view .row{display:flex;gap:14px;align-items:flex-start;flex-wrap:wrap}#view figure{margin:0;flex:1;min-width:300px}
#view img{max-width:100%;display:block;background:#fff2}#view figcaption{margin:4px 0 8px}
.slide{position:relative;display:inline-block;max-width:100%}.slide img{max-width:100%}
.slide .top{position:absolute;inset:0;overflow:hidden}.slide .top img{max-width:none}
#close{position:fixed;top:12px;right:18px;font-size:22px;cursor:pointer}
"""

INDEX_SCRIPT = """
const D=JSON.parse(document.getElementById('data').textContent);
const changed={};for(const c of D.diff.changed||[])changed[c.key]=c;for(const c of D.diff.resized||[])changed[c.key]=Object.assign({resized:1},c);
const fresh=new Set((D.diff.new||[]).map(c=>c.key));
const $=s=>document.querySelector(s);const esc=s=>String(s).replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
function fill(sel,vals){for(const v of vals){const o=document.createElement('option');o.value=v;o.textContent=v;sel.appendChild(o)}}
fill($('#theme'),[...new Set(D.images.map(i=>i.theme))].sort());fill($('#surface'),[...new Set(D.images.map(i=>i.surface))].sort());
fill($('#status'),[...new Set(D.images.map(i=>i.status))].sort());
function draw(){const th=$('#theme').value,su=$('#surface').value,st=$('#status').value,ch=$('#changed').checked,q=$('#q').value.toLowerCase();
 const groups={};for(const i of D.images){if(th&&i.theme!==th)continue;if(su&&i.surface!==su)continue;if(st&&i.status!==st)continue;
 if(ch&&!changed[i.key]&&!fresh.has(i.key))continue;if(q&&!i.key.toLowerCase().includes(q))continue;(groups[i.surface]=groups[i.surface]||[]).push(i)}
 let h='';for(const s of Object.keys(groups).sort()){h+='<h2>'+esc(s)+' <span class="meta">('+groups[s].length+')</span></h2><div class="grid">';
 for(const i of groups[s]){let tags='';if(i.status!=='ok')tags+='<span class="tag bad">'+esc(i.status)+'</span>';
  if(changed[i.key])tags+='<span class="tag chg">'+(changed[i.key].resized?'taille':changed[i.key].percent+' %')+'</span>';
  if(fresh.has(i.key))tags+='<span class="tag">nouveau</span>';
  h+='<div class="card" data-k="'+esc(i.key)+'"><img loading="lazy" src="'+esc(i.file)+'" alt=""><div class="t"><span class="k" title="'+esc(i.key)+'">'
   +esc(i.state+' · '+i.theme+(i.size?' · '+i.size:''))+'</span>'+tags+'</div></div>'}h+='</div>'}
 $('#list').innerHTML=h||'<p style="padding:22px">Aucune image pour ces filtres.</p>';
 for(const c of document.querySelectorAll('.card'))c.onclick=()=>show(c.dataset.k)}
function show(key){const i=D.images.find(x=>x.key===key);const sib=D.images.filter(x=>x.id===i.id&&x.size===i.size);
 let h='<div id="close">✕</div><h1>'+esc(i.id)+(i.size?' · '+esc(i.size):'')+'</h1><p>'+esc(i.source)+' · '+i.points.join('×')+' pt · '
  +i.pixels.join('×')+' px'+(i.note?' · '+esc(i.note):'')+'</p><div class="row">';
 for(const s of sib)h+='<figure><figcaption>'+esc(s.theme)+' — '+esc(s.status)+(s.detail?' : '+esc(s.detail):'')+' · '+s.ms+' ms</figcaption><img src="'+esc(s.file)+'"></figure>';
 h+='</div>';const c=changed[key];
 if(c&&D.diff.basePng){const b=D.diff.basePng+'/'+key;h+='<h2>Écart avec la base ('+esc(D.diff.baseKey)+')</h2><div class="row">'
  +'<figure><figcaption>base</figcaption><img src="'+esc(b)+'"></figure><figure><figcaption>actuel</figcaption><img src="'+esc(i.file)+'"></figure>'
  +(c.diff?'<figure><figcaption>diff (magenta = changé)</figcaption><img src="'+esc(c.diff)+'"></figure>':'')+'</div>';
  if(!c.resized)h+='<h2>Curseur base / actuel</h2><input type="range" id="sl" min="0" max="100" value="50" style="width:320px"><br><div class="slide"><img src="'+esc(b)+'"><div class="top" id="top"><img src="'+esc(i.file)+'"></div></div>'}
 if(c&&!D.diff.basePng&&c.diff)h+='<h2>Écart avec la base du diff (remplacée depuis)</h2><div class="row"><figure><figcaption>diff (magenta = changé)</figcaption><img src="'+esc(c.diff)+'"></figure></div>';
 const v=$('#view');v.innerHTML=h;v.style.display='block';$('#close').onclick=()=>v.style.display='none';
 const sl=$('#sl');if(sl){const top=$('#top');const set=()=>{top.style.width=sl.value+'%';top.querySelector('img').style.width=top.parentElement.querySelector('img').clientWidth+'px'};sl.oninput=set;setTimeout(set,50)}}
for(const id of ['#theme','#surface','#status','#changed','#q'])$(id).oninput=draw;
document.addEventListener('keydown',e=>{if(e.key==='Escape')$('#view').style.display='none'});draw();
"""


def write_index(run: Path) -> None:
    manifest = read_json(run / "manifest.json")
    report = read_json(run / "diff.json") if (run / "diff.json").exists() else {}
    base_replaced = False
    if report and not report.get("noBase"):
        # The diff's base may have been replaced by an accept since (C2-outil-05): its images then no longer
        # show what diff/ and the percentages describe, so the index does not show them as "base".
        base_manifest_path = Path(report["base"]) / "manifest.json"
        current_revision = base_revision(read_json(base_manifest_path)) if base_manifest_path.exists() else None
        base_replaced = "baseRevision" in report and current_revision != report["baseRevision"]
        if not base_replaced:
            # Absolute URL: the index also opens through the `latest` link or from a copy of the run, where a path
            # relative to runs/<run> points one level off.
            report["basePng"] = (Path(report["base"]) / "png").resolve().as_uri()
    data = {"images": manifest["images"], "diff": report}
    counts: dict[str, int] = {}
    for image in manifest["images"]:
        counts[image["status"]] = counts.get(image["status"], 0) + 1
    if report.get("noBase"):
        diff_line = html.escape(report.get("message", ""))
    elif report:
        diff_line = (f"diff contre <b>{html.escape(report['baseKey'])}</b> : {differences(report)} écart(s) "
                     f"({len(report['changed'])} changées, {len(report['new'])} nouvelles, {len(report['missing'])} "
                     f"disparues, {len(report['resized'])} taille changée, {len(report.get('notOk', []))} non ok) — "
                     f"cause : {html.escape(report['cause'])}")
        if base_replaced:
            diff_line += (" — <b>base remplacée depuis le diff</b> : les images de base ne sont plus affichées ; "
                          "relancer make gallery-diff pour comparer à la base actuelle")
    else:
        diff_line = "pas de diff"
    duplicates = manifest.get("duplicates") or []
    if duplicates:
        # The best detector of blank pages and ignored fixtures: different states that give the same pixels.
        rows = "".join(f"<li>{' = '.join(html.escape(key) for key in group)}</li>" for group in duplicates)
        duplicates_block = (f'<details class="limits"><summary>{len(duplicates)} groupe(s) d’images identiques entre '
                            f'états différents</summary><ul>{rows}</ul></details>')
    else:
        duplicates_block = '<div class="limits">aucune image identique entre états différents</div>'
    not_covered = (f'<details class="limits"><summary>{len(NOT_COVERED)} groupe(s) d’états de la spec (§6) non '
                   f'couverts : pas d’image</summary><ul>'
                   + "".join(f"<li>{html.escape(line)}</li>" for line in NOT_COVERED) + "</ul></details>")
    totals = " · ".join(f"{html.escape(key)} {value}" for key, value in sorted(counts.items()))
    payload = json.dumps(data, ensure_ascii=False).replace("</", "<\\/")
    page = f"""<!doctype html>
<html lang="fr"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src 'self' file: data:; style-src 'unsafe-inline'; script-src 'unsafe-inline'">
<title>Galerie Goalong — {html.escape(manifest['run'])}</title><style>{INDEX_STYLE}</style></head><body>
<header><h1>Galerie Goalong</h1>
<div class="meta">commit <b>{html.escape(manifest['commit'])}</b> ({html.escape(manifest['branch'])}{'' if manifest['clean'] else ', arbre non propre'}) ·
{html.escape(manifest['date'])} · <b>{len(manifest['images'])}</b> images ({totals}) · clé env <b>{html.escape(manifest['envKey'])}</b> ·
{manifest.get('shards')} shard(s), {manifest.get('duration')} s{' · ONLY=' + html.escape(manifest['only']) if manifest.get('only') else ''}</div>
<div class="meta">{diff_line}</div>
{duplicates_block}
{not_covered}
<div class="limits">{html.escape(GUARD_LIMITS)} {html.escape(APP_ICON_LIMIT)} {html.escape(STALE_INDEX_LIMIT)}</div></header>
<div class="bar"><label>Thème <select id="theme"><option value="">tous</option></select></label>
<label>Surface <select id="surface"><option value="">toutes</option></select></label>
<label>Statut <select id="status"><option value="">tous</option></select></label>
<label><input type="checkbox" id="changed"> changées seulement</label>
<label>Chercher <input id="q" type="search" placeholder="id"></label></div>
<main id="list"></main><div id="view"></div>
<script type="application/json" id="data">{payload}</script>
<script>{INDEX_SCRIPT}</script></body></html>
"""
    temporary = run / ".index.html.tmp"
    temporary.write_text(page, encoding="utf-8")
    os.replace(temporary, run / "index.html")


def command_index(args: argparse.Namespace) -> int:
    run = resolve_run(args.run)
    write_index(run)
    log(f"gallery: index : {run / 'index.html'}")
    return 0


# ---------------------------------------------------------------- main

def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(prog="gallery.py", description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    run = sub.add_parser("run")
    run.add_argument("--only", default=os.environ.get("ONLY", ""))
    run.add_argument("--shards", type=int, default=4)
    run.add_argument("--no-build", action="store_true")
    diff = sub.add_parser("diff")
    diff.add_argument("--run", default="latest")
    diff.add_argument("--base-env", default="")
    diff.add_argument("--tol", type=int, default=0)
    diff.add_argument("--maxpx", type=int, default=0)
    accept = sub.add_parser("accept")
    accept.add_argument("--run", default="latest")
    accept.add_argument("--only", default="")
    accept.add_argument("--force", action="store_true")
    index = sub.add_parser("index")
    index.add_argument("--run", default="latest")
    sub.add_parser("clean")
    args = parser.parse_args(argv)
    if args.command == "run" and not 1 <= args.shards <= 16:
        fail("SHARDS doit être entre 1 et 16")
    handlers = {"run": command_run, "diff": command_diff, "accept": command_accept, "index": command_index,
                "clean": command_clean}
    return handlers[args.command](args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
