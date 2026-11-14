#!/usr/bin/env python3
"""Wait until the post-merge gates finish on this exact main commit (T-058).

PRs only run the fast gate; the full suite runs once on main. Publication must not
start before it is green on the commit it publishes. Prints `ready=true|false` for
$GITHUB_OUTPUT. Exit 1 when a gate failed (nothing is published), 0 otherwise.
`ready=false` with exit 0 means main moved on: the newer commit's run publishes.
"""
import json
import os
import subprocess
import sys
import time

from local_deploy_policy import GATES, REPO

POLL_SECONDS = 30


def api(path):
    return json.loads(subprocess.check_output(['gh', 'api', f'repos/{REPO}/{path}'], text=True))


def main_head():
    return subprocess.check_output(['git', 'ls-remote', 'origin', 'refs/heads/main'], text=True).split()[0]


def latest_checks(sha):
    rows = api(f'commits/{sha}/check-runs?per_page=100&filter=latest')['check_runs']
    found = {}
    for row in rows:
        if row['name'] in GATES and row['app']['slug'] == 'github-actions':
            if row['name'] not in found or row['id'] > found[row['name']]['id']:
                found[row['name']] = row
    return found


def decide(found):
    """'ready', 'failed' or 'pending' from the latest check run of each gate."""
    if any(c['status'] == 'completed' and c['conclusion'] != 'success' for c in found.values()):
        return 'failed'
    if set(found) == set(GATES) and all(c['conclusion'] == 'success' for c in found.values()):
        return 'ready'
    return 'pending'


def emit(ready):
    line = f"ready={'true' if ready else 'false'}"
    print(line)
    if os.environ.get('GITHUB_OUTPUT'):
        with open(os.environ['GITHUB_OUTPUT'], 'a') as handle:
            handle.write(line + '\n')


def run(sha):
    while True:
        found = latest_checks(sha)
        state = decide(found)
        summary = ', '.join(f"{n}={c['status']}/{c['conclusion']}" for n, c in sorted(found.items())) or 'no gate yet'
        print(f'{time.strftime("%H:%M:%S")} {state}: {summary}', file=sys.stderr, flush=True)
        if state == 'ready':
            emit(True)
            return 0
        if main_head() != sha:
            print('main moved on; the newer commit publishes', file=sys.stderr)
            emit(False)
            return 0
        if state == 'failed':
            emit(False)
            return 1
        time.sleep(POLL_SECONDS)


if __name__ == '__main__':
    sys.exit(run(sys.argv[1] if len(sys.argv) > 1 else os.environ['GITHUB_SHA']))
