#!/usr/bin/env python3
"""Reuse official hosted gates only with evidence of their actual tested tree."""
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = 'blancmathis/goalong-history'
GATES = {'build-test-package': '.github/workflows/macos.yml',
         'verify': '.github/workflows/motion-integration.yml',
         'native-sharing': '.github/workflows/sharing-acceptance.yml'}

class PendingGates(ValueError):
    """Missing/unfinished gates can be reevaluated without a publication attempt."""

def api(path):
    return json.loads(subprocess.check_output(['gh', 'api', f'repos/{REPO}/{path}'], text=True))

def pages(path, key=None):
    result = []
    for page in range(1, 101):
        data = api(f"{path}{'&' if '?' in path else '?'}per_page=100&page={page}")
        rows = data[key] if key else data
        result.extend(rows)
        if len(rows) < 100:
            return result
    raise ValueError('Gate evidence pagination exceeded its bound')

def git(*args):
    return subprocess.check_output(['git', *args], text=True).strip()

def tree_for(revision):
    if subprocess.run(['git', 'cat-file', '-e', f'{revision}^{{commit}}'],
                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode:
        subprocess.run(['git', 'fetch', '--no-tags', 'origin', revision], check=True,
                       stdout=sys.stderr, stderr=sys.stderr)
    return git('rev-parse', f'{revision}^{{tree}}')

def validate_receipt(receipt, run, name, tree):
    path = GATES[name]
    expected = {'schemaVersion': 1, 'repository': REPO, 'runId': run['id'],
                'runAttempt': run['run_attempt'], 'job': name, 'event': run['event'],
                'sourceTree': tree, 'runnerEnvironment': 'github-hosted'}
    if any(receipt.get(k) != v for k, v in expected.items()):
        raise ValueError('Gate receipt identity or tested tree mismatch')
    if not receipt.get('workflowRef', '').startswith(f'{REPO}/{path}@'):
        raise ValueError('Gate receipt came from another workflow')
    commit = receipt.get('checkoutCommit', '')
    if not re.fullmatch(r'[0-9a-f]{40}', commit) or tree_for(commit) != tree:
        raise ValueError('Gate checkout is not the admitted source tree')
    if git('show', f'{commit}:{path}') != git('show', f'HEAD:{path}'):
        raise ValueError('Gate workflow recipe differs from the publication checkout')

def gates_for(candidates, tree, revision, merged_at=None):
    for tested in candidates:
        checks = pages(f'commits/{tested}/check-runs', 'check_runs')
        evidence = {}
        for name, path in GATES.items():
            matching = [c for c in checks if c['name'] == name and c['app']['slug'] == 'github-actions']
            if not matching:
                break
            check = max(matching, key=lambda c: c['id'])
            match = re.fullmatch(r'https://github\.com/blancmathis/goalong-history/actions/runs/([0-9]+)/job/([0-9]+)', check['details_url'] or '')
            if check['conclusion'] != 'success' or check['status'] != 'completed' or not match:
                break
            run = api(f'actions/runs/{match[1]}')
            if (run['conclusion'] != 'success' or run['status'] != 'completed'
                    or run['head_sha'] != tested or run['path'].split('@')[0] != path
                    or run['head_repository']['full_name'] != REPO
                    or run['event'] not in {'pull_request', 'push', 'workflow_dispatch'}):
                break
            jobs = pages(f"actions/runs/{run['id']}/attempts/{run['run_attempt']}/jobs", 'jobs')
            job = next((j for j in jobs if j['id'] == int(match[2])), None)
            if (not job or job['name'] != name or job['conclusion'] != 'success'
                    or job['runner_group_id'] != 0 or 'self-hosted' in job.get('labels', [])):
                break
            artifact_name = f"Goalong-Gate-{name}-{run['run_attempt']}"
            artifacts = pages(f"actions/runs/{run['id']}/artifacts", 'artifacts')
            rows = [a for a in artifacts if a['name'] == artifact_name and not a['expired']]
            if len(rows) != 1:
                break
            with tempfile.TemporaryDirectory(prefix='goalong-gate-') as directory:
                subprocess.run(['gh', 'run', 'download', str(run['id']), '--repo', REPO,
                                '--name', artifact_name, '--dir', directory], check=True, stdout=sys.stderr)
                receipt = json.loads((Path(directory) / 'gate-receipt.json').read_text())
            validate_receipt(receipt, run, name, tree)
            evidence[name] = {**receipt, 'checkId': check['id'], 'jobId': job['id'],
                              'artifactId': rows[0]['id'], 'artifactDigest': rows[0].get('digest')}
        if set(evidence) == set(GATES):
            producer = evidence['build-test-package']
            return {'sourceCommit': revision, 'tree': tree, 'testedCommit': tested, 'gateEvidence': evidence,
                    'runs': {n: e['runId'] for n, e in evidence.items()},
                    'buildRunId': producer['runId'], 'buildRunAttempt': producer['runAttempt'], 'mergedAt': merged_at}
    raise PendingGates('All three official hosted gates and their exact-checkout receipts must pass')

def source_gates(revision):
    if not re.fullmatch(r'[0-9a-f]{40}', revision):
        raise ValueError('Full source SHA required')
    if git('ls-remote', 'origin', 'refs/heads/main').split()[0] != revision:
        raise ValueError('Source has been superseded')
    tree = tree_for(revision)
    candidates, merged_at = [revision], None
    for pr in pages(f'commits/{revision}/pulls'):
        if (pr['merged_at'] and pr['merge_commit_sha'] == revision and pr['base']['ref'] == 'main'
                and pr['head']['repo'] and pr['head']['repo']['full_name'] == REPO):
            merged_at = pr['merged_at']
            candidates.append(pr['head']['sha'])
    return gates_for(candidates, tree, revision, merged_at)

if __name__ == '__main__':
    try:
        proof = source_gates(sys.argv[1])
        if len(sys.argv) == 3:
            Path(sys.argv[2]).write_text(json.dumps(proof, indent=2) + '\n')
        else:
            print(json.dumps(proof))
    except PendingGates as error:
        print(str(error), file=sys.stderr)
        sys.exit(75)
