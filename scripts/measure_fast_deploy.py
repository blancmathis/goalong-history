#!/usr/bin/env python3
"""Per-stage UTC times and durations, from PR merge to the verified public feed.

Usage: measure_fast_deploy.py <continuous-release run id>
Sources: the GitHub API (merge time, run, jobs, steps) and the attested public
verification receipt of the published immutable release.
"""
from datetime import datetime
import json
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = 'blancmathis/goalong-history'


def api(path):
    return json.loads(subprocess.check_output(['gh', 'api', f'repos/{REPO}/{path}'], text=True))


def when(value):
    return datetime.fromisoformat(value.replace('Z', '+00:00'))


def main(run_id):
    run = api(f'actions/runs/{run_id}')
    pulls = [p for p in api(f"commits/{run['head_sha']}/pulls") if p['merge_commit_sha'] == run['head_sha']]
    merged = when(pulls[0]['merged_at']) if pulls else when(run['created_at'])
    jobs = api(f'actions/runs/{run_id}/jobs?per_page=100')['jobs']
    rows = [('merge', merged), ('run created', when(run['created_at']))]
    path = 'fast'
    for job in jobs:
        if job['name'] == 'publish-latest-main' and job['conclusion'] == 'success':
            path = 'fallback'
    tag = None
    for job in jobs:
        if job['name'] not in ('promote-prepared', 'publish-latest-main') or not job['started_at']:
            continue
        if job['conclusion'] == 'skipped':
            continue
        rows.append((f"{job['name']} job started", when(job['started_at'])))
        for step in job['steps']:
            if step['conclusion'] == 'success' and step['completed_at'] and step['name'] != 'Set up job':
                rows.append((f"{job['name']}: {step['name']}", when(step['completed_at'])))
    releases = json.loads(subprocess.check_output(['gh', 'release', 'list', '--repo', REPO, '--limit', '20',
                                                   '--json', 'tagName'], text=True))
    verified = None
    with tempfile.TemporaryDirectory() as directory:
        for release in releases:
            tag = release['tagName']
            if not tag.startswith('main-'):
                continue
            target = Path(directory) / tag
            if subprocess.run(['gh', 'release', 'download', tag, '--repo', REPO, '--pattern', 'public-verification.json',
                               '--dir', str(target)], capture_output=True).returncode:
                continue
            receipt = json.loads((target / 'public-verification.json').read_text())
            if receipt['sourceCommit'] == run['head_sha']:
                verified = when(receipt['verifiedAt'])
                rows.append(('public feed verified (attested receipt)', verified))
                break
    rows.sort(key=lambda row: row[1])
    print(f"Run {run_id} ({path} path), main {run['head_sha'][:12]}, tag {tag if verified else 'n/a'}\n")
    print('| Stage | UTC | Since merge (s) | Delta (s) |\n|---|---|---|---|')
    previous = merged
    for name, moment in rows:
        print(f"| {name} | {moment.strftime('%H:%M:%S')} | {(moment - merged).total_seconds():.0f} | {(moment - previous).total_seconds():.0f} |")
        previous = moment
    if verified:
        print(f"\nMerge -> verified public feed: {(verified - merged).total_seconds():.0f} s")


if __name__ == '__main__':
    main(sys.argv[1])
