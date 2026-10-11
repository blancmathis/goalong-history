#!/usr/bin/env python3
"""Install the reviewed outbound-only coordinator as a current-user launchd agent."""
import argparse
import json
import os
import plistlib
import shutil
import subprocess
from pathlib import Path

LABEL = "ai.goalong.local-auto-deploy"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--start", action="store_true")
    args = parser.parse_args()
    if os.uname().sysname != "Darwin" or os.getuid() == 0:
        parser.error("Requires the current non-root Mac user")
    root = Path(__file__).resolve().parents[1]
    home = Path.home()
    state = home / "Library/Application Support/GoalongDeploy"
    runner = home / "actions-runner-goalong-history"
    if runner.exists():
        parser.error("Remove the GitHub runner before installing local auto-deploy")
    runners = json.loads(subprocess.check_output(["gh", "api", "repos/blancmathis/goalong-history/actions/runners"], text=True))
    if any(r["name"] == "goalong-mac" for r in runners["runners"]):
        parser.error("Unregister goalong-mac before installing local auto-deploy")
    for path in (state, state / "controller", home / "Library/LaunchAgents"):
        if path.is_symlink():
            parser.error(f"Refusing symlinked installation path: {path}")
        path.mkdir(parents=True, exist_ok=True, mode=0o700)
    controller = state / "controller/local_auto_deploy.py"
    shutil.copyfile(root / "scripts/local_auto_deploy.py", controller)
    controller.chmod(0o700)
    python = shutil.which("python3")
    if not python or not shutil.which("gh"):
        parser.error("Install Python 3 and GitHub CLI first")
    plist = home / "Library/LaunchAgents" / f"{LABEL}.plist"
    value = {"Label": LABEL, "ProgramArguments": [python, str(controller), "--repository", str(root)],
             "WorkingDirectory": str(root), "RunAtLoad": True, "StartInterval": 60,
             "ProcessType": "Interactive", "ThrottleInterval": 60,
             "EnvironmentVariables": {"PATH": "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin", "GODEBUG": "http2client=0"},
             "StandardOutPath": str(state / "agent.log"), "StandardErrorPath": str(state / "agent-error.log")}
    domain = f"gui/{os.getuid()}"
    loaded = subprocess.run(["launchctl", "print", f"{domain}/{LABEL}"], capture_output=True)
    if loaded.returncode == 0:
        subprocess.run(["launchctl", "bootout", f"{domain}/{LABEL}"], check=True)
    plist.write_bytes(plistlib.dumps(value)); plist.chmod(0o600)
    if args.start:
        subprocess.run(["launchctl", "enable", f"{domain}/{LABEL}"], check=True)
        subprocess.run(["launchctl", "bootstrap", domain, str(plist)], check=True)
    print(f"Local deploy agent {'started' if args.start else 'prepared'}: {plist}")
    print(f"Reviewed controller: {controller}; state/logs: {state}")


if __name__ == "__main__":
    main()
