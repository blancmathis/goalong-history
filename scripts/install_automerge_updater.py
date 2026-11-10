#!/usr/bin/env python3
"""Install scripts/automerge_updater.py as a low-priority current-user launchd agent.

Runs every 2 minutes with the owner's `gh` login (no new secret). The
controller is copied out of the checkout so a branch switch cannot change it.
Usage: install_automerge_updater.py [--start | --remove]
"""
import argparse
import os
import plistlib
import shutil
import subprocess
from pathlib import Path

LABEL = "ai.goalong.automerge-updater"


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--start", action="store_true", help="load the agent now")
    parser.add_argument("--remove", action="store_true", help="unload and delete the agent and its controller copy")
    parser.add_argument("--interval", type=int, default=120)
    args = parser.parse_args()
    if os.uname().sysname != "Darwin" or os.getuid() == 0:
        parser.error("Requires the current non-root Mac user")
    home = Path.home()
    state = home / "Library/Application Support/GoalongAutomergeUpdater"
    plist = home / "Library/LaunchAgents" / f"{LABEL}.plist"
    domain = f"gui/{os.getuid()}"
    if subprocess.run(["launchctl", "print", f"{domain}/{LABEL}"], capture_output=True).returncode == 0:
        subprocess.run(["launchctl", "bootout", f"{domain}/{LABEL}"], check=True)
    if args.remove:
        plist.unlink(missing_ok=True)
        (state / "automerge_updater.py").unlink(missing_ok=True)
        print(f"Removed {LABEL} and its controller copy; state dir kept (logs, last-decision): {state}")
        return
    python, gh = shutil.which("python3"), shutil.which("gh") or "/opt/homebrew/bin/gh"
    if not python or not Path(gh).exists():
        parser.error("Install Python 3 and GitHub CLI first")
    for path in (state, plist.parent):
        if path.is_symlink():
            parser.error(f"Refusing symlinked path: {path}")
        path.mkdir(parents=True, exist_ok=True, mode=0o700)
    controller = state / "automerge_updater.py"
    shutil.copyfile(Path(__file__).resolve().parent / "automerge_updater.py", controller)
    controller.chmod(0o700)
    value = {"Label": LABEL,
             "ProgramArguments": [python, str(controller), "--gh", gh, "--state", str(state / "last-decision")],
             "WorkingDirectory": str(state), "RunAtLoad": True, "StartInterval": args.interval,
             "ProcessType": "Background", "LowPriorityIO": True, "Nice": 10,
             "EnvironmentVariables": {"PATH": "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"},
             "StandardOutPath": str(state / "agent.log"), "StandardErrorPath": str(state / "agent-error.log")}
    plist.write_bytes(plistlib.dumps(value))
    plist.chmod(0o600)
    if args.start:
        subprocess.run(["launchctl", "enable", f"{domain}/{LABEL}"], check=True)
        subprocess.run(["launchctl", "bootstrap", domain, str(plist)], check=True)
    print(f"Auto-merge updater {'started' if args.start else 'prepared'}: {plist}")
    print(f"Controller: {controller}; logs: {state}/agent.log")


if __name__ == "__main__":
    main()
