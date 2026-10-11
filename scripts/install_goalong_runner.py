#!/usr/bin/env python3
"""Install the pinned official runner and trusted hooks as the current Mac user.

Requires the owner's existing gh repository-admin session. Registration tokens
are passed only through the supported runner input environment, never argv/logs.
No developer private key is exported or copied. No sudo or paid service.
"""
import argparse
import hashlib
import json
import os
import platform
import shlex
import shutil
import subprocess
import tarfile
from pathlib import Path

VERSION = "2.338.0"
DIGEST = "df4cebda25c86a886ed204e49fee63f5c2e7cec5f447b5c98440a826bbdf9df2"
REPO = "blancmathis/goalong-history"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--start", action="store_true", help="Start the installed current-user launchd service")
    args = parser.parse_args()
    if platform.system() != "Darwin" or platform.machine() != "arm64" or os.getuid() == 0:
        parser.error("Requires Apple Silicon macOS and the current non-root user")
    source = Path(__file__).resolve().parent
    root = Path.home() / "actions-runner-goalong-history"
    hooks = Path.home() / "Library/Application Support/GoalongRunnerHooks"
    for directory in (root, hooks):
        if directory.is_symlink():
            parser.error(f"Refusing symbolic-link installation directory: {directory}")
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        directory.chmod(0o700)
    # The trusted hook is outside the workflow checkout and the runner app.
    shutil.copyfile(source / "guard_self_hosted_runner.py", hooks / "guard.py")
    started = hooks / "started.sh"
    started.write_text("#!/bin/bash\nset -euo pipefail\nexec /usr/bin/python3 " + shlex.quote(str(hooks / "guard.py")) + "\n")
    completed = hooks / "completed.sh"
    completed.write_text('''#!/bin/bash
set -euo pipefail
: "${RUNNER_TEMP:?}" "${GITHUB_WORKSPACE:?}"
keychain="$RUNNER_TEMP/goalong-release-signing.keychain-db"
if [[ -f "$keychain" ]]; then /usr/bin/security delete-keychain "$keychain"; fi
/bin/rm -f "$RUNNER_TEMP/goalong-release-signing.p12"
/usr/bin/python3 - "$GITHUB_WORKSPACE/dist" "$RUNNER_TEMP/delta-bases" "$RUNNER_TEMP/goalong-presigned" <<'PY'
import shutil,sys
from pathlib import Path
for arg in sys.argv[1:]:
    p=Path(arg)
    if p.is_symlink(): p.unlink()
    elif p.is_dir(): shutil.rmtree(p)
PY
''')
    for script in (started, completed):
        script.chmod(0o700)
    if not (root / "config.sh").exists():
        archive = hooks / "runner.tar.gz"
        url = f"https://github.com/actions/runner/releases/download/v{VERSION}/actions-runner-osx-arm64-{VERSION}.tar.gz"
        subprocess.run(["curl", "--fail", "--location", "--silent", "--show-error", "--proto", "=https", "--proto-redir", "=https", "--max-time", "300", url, "-o", str(archive)], check=True)
        if hashlib.sha256(archive.read_bytes()).hexdigest() != DIGEST:
            raise ValueError("Official runner archive checksum mismatch")
        with tarfile.open(archive) as package:
            package.extractall(root, filter="data")
        archive.unlink()
    env_file = root / ".env"
    if env_file.exists():
        existing = [line for line in env_file.read_text().splitlines() if not line.startswith(("ACTIONS_RUNNER_HOOK_JOB_", "PATH="))]
    else:
        existing = []
    existing.extend([
        f"ACTIONS_RUNNER_HOOK_JOB_STARTED={started}",
        f"ACTIONS_RUNNER_HOOK_JOB_COMPLETED={completed}",
        "PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin",
    ])
    env_file.write_text("\n".join(existing) + "\n")
    env_file.chmod(0o600)
    log = hooks / "installation.log"
    with log.open("a") as output:
        log.chmod(0o600)
        if not (root / ".runner").exists():
            result = subprocess.run(["gh", "api", "--method", "POST", f"repos/{REPO}/actions/runners/registration-token"], check=True, capture_output=True, text=True)
            env = os.environ.copy()
            env["ACTIONS_RUNNER_INPUT_TOKEN"] = json.loads(result.stdout)["token"]
            subprocess.run(["./config.sh", "--unattended", "--url", f"https://github.com/{REPO}", "--name", "goalong-mac", "--labels", "goalong-mac", "--work", "_work"], cwd=root, env=env, stdout=output, stderr=subprocess.STDOUT, check=True)
            del env["ACTIONS_RUNNER_INPUT_TOKEN"]
        for name in (".credentials", ".credentials_rsaparams", ".runner"):
            p = root / name
            if p.exists():
                p.chmod(0o600)
        if not (root / ".service").exists():
            subprocess.run(["./svc.sh", "install"], cwd=root, stdout=output, stderr=subprocess.STDOUT, check=True)
        if args.start:
            subprocess.run(["./svc.sh", "start"], cwd=root, stdout=output, stderr=subprocess.STDOUT, check=True)
    print(f"Official runner installed with trusted origin and cleanup hooks: {root}")
    print(f"Current-user launchd service {'started' if args.start else 'installed, stopped'}; private log: {log}")


if __name__ == "__main__":
    main()
