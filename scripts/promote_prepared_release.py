#!/usr/bin/env python3
"""Exact-main promotion of a hosted, attested PR candidate (fast path).

admit:   prove tree(main) == candidate tree, the three gates, the candidate attestation,
         every digest, the pinned signature, the signed appcast, and the authenticated
         public state; then build the final inventory. Any failure here => fallback
         (nothing public has changed yet).
publish: make the draft immutable release public at the exact main commit, then
         replace the feed last and verify it with a public GET. Failures are fatal.
"""
import concurrent.futures
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import time
import urllib.request

sys.path.insert(0, str(Path(__file__).resolve().parent))
from authenticated_release_state import authenticated_state, require_successor
from fast_release_common import APP, ARCHIVE, REPO, attest_verify, digest, recipe_digest
import local_deploy_policy
from prepare_candidate_release import ASSETS, DMG, draft_name
from prepare_presigned_release import validate_archive

ROOT = Path(__file__).resolve().parents[1]
DIST = ROOT / 'dist'
WORK = Path(os.environ.get('RUNNER_TEMP', '/tmp')) / 'goalong-promote'
VERIFIER = WORK / 'verify-update'
PREP_WORKFLOW = 'prepare-candidate-release.yml'
API = f'https://api.github.com/repos/{REPO}'
UPLOADS = f'https://uploads.github.com/repos/{REPO}'
WAIT_FOR_PREPARATION = 20 * 60
ROLLING = 'latest-main'
FINAL_JSON = ['security-capabilities.json', 'sbom.spdx.json', 'release-manifest.json']
TIMES = {}


class Fallback(Exception):
    """No admissible prepared candidate: the full hosted build must run instead."""


def stamp(name):
    TIMES[name] = datetime.now(timezone.utc).isoformat(timespec='milliseconds')
    print(f'[{TIMES[name]}] {name}', flush=True)


def headers(accept='application/vnd.github+json'):
    return {'Authorization': f"Bearer {os.environ['GH_TOKEN']}", 'Accept': accept,
            'X-GitHub-Api-Version': '2022-11-28'}


def api(path, method='GET', body=None):
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(f'{API}/{path}', data=data, method=method, headers=headers())
    with urllib.request.urlopen(request, timeout=60) as response:
        content = response.read()
    return json.loads(content) if content else None


def run(*argv, **kwargs):
    subprocess.run(argv, check=True, cwd=ROOT, **kwargs)


def git(*args):
    return subprocess.check_output(['git', *args], cwd=ROOT, text=True).strip()


def download_asset(asset, target):
    # curl drops the token on the cross-host redirect to the storage URL.
    run('curl', '--fail', '--location', '--silent', '--show-error', '--retry', '3', '--proto', '=https',
        '--proto-redir', '=https', '--max-filesize', '350000000',
        '--header', f"Authorization: Bearer {os.environ['GH_TOKEN']}",
        '--header', 'Accept: application/octet-stream', asset['url'], '-o', str(target))


def upload_asset(release_id, path):
    run('curl', '--fail', '--silent', '--show-error', '--proto', '=https', '-X', 'POST',
        '--header', f"Authorization: Bearer {os.environ['GH_TOKEN']}",
        '--header', 'Content-Type: application/octet-stream', '--data-binary', f'@{path}',
        f'{UPLOADS}/releases/{release_id}/assets?name={path.name}', stdout=subprocess.DEVNULL)


def remote_main():
    return git('ls-remote', 'origin', 'refs/heads/main').split()[0]


def output(**values):
    with open(os.environ['GITHUB_OUTPUT'], 'a') as stream:
        for key, value in values.items():
            stream.write(f'{key}={value}\n')


def summary(text):
    with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as stream:
        stream.write(text + '\n')


def merged_pull_request(main):
    for pr in api(f'commits/{main}/pulls'):
        if (pr['merged_at'] and pr['merge_commit_sha'] == main and pr['base']['ref'] == 'main'
                and pr['head']['repo'] and pr['head']['repo']['full_name'] == REPO):
            return pr
    raise Fallback('Main commit is not a merged same-repository pull request')


def find_candidate(tree, pr):
    deadline = time.monotonic() + WAIT_FOR_PREPARATION
    while True:
        drafts = [r for r in api('releases?per_page=100') if r['draft'] and r['name'] == draft_name(tree)]
        # The draft exists before its assets finish uploading (2026-10-14, run 38530577256):
        # take only a draft whose full asset set is uploaded, else keep waiting for the run.
        complete = [r for r in drafts if {a['name'] for a in r['assets'] if a['state'] == 'uploaded'} == set(ASSETS)]
        if complete:
            # Newest preparation first; tags are main-<run>-<attempt>.
            return sorted(complete, key=lambda r: tuple(map(int, r['tag_name'].split('-')[1:])), reverse=True)[0]
        runs = api(f"actions/workflows/{PREP_WORKFLOW}/runs?head_sha={pr['head']['sha']}&per_page=20")['workflow_runs']
        if not any(r['status'] != 'completed' for r in runs) or time.monotonic() > deadline:
            if drafts:
                return sorted(drafts, key=lambda r: tuple(map(int, r['tag_name'].split('-')[1:])), reverse=True)[0]
            raise Fallback('No prepared candidate for this tree')
        print('Preparation for this tree is still running; waiting for it.', flush=True)
        time.sleep(15)


def verify_receipt(value, release, tree, pr, prepared):
    number = pr['number']
    expected = {'schemaVersion': 1, 'repository': REPO, 'sourceTree': tree, 'pullRequest': number,
                'headCommit': pr['head']['sha'], 'tag': release['tag_name'],
                'preparedRef': f'refs/pull/{number}/merge'}
    if any(value.get(k) != v for k, v in expected.items()):
        raise Fallback('Candidate receipt does not match this merge')
    if datetime.fromisoformat(value['expiresAt']) <= datetime.now(timezone.utc):
        raise Fallback('Candidate expired')
    commit = value['preparedCommit']
    if api(f'git/commits/{commit}')['tree']['sha'] != tree:
        raise Fallback('Candidate merge tree differs from main')
    run_id, attempt = value['run']['id'], value['run']['attempt']
    workflow_run = api(f'actions/runs/{run_id}/attempts/{attempt}')
    if (workflow_run['event'] != 'pull_request' or workflow_run['status'] != 'completed'
            or workflow_run['conclusion'] != 'success' or workflow_run['head_sha'] != pr['head']['sha']
            or workflow_run['path'].split('@')[0] != f'.github/workflows/{PREP_WORKFLOW}'
            or workflow_run['head_repository']['full_name'] != REPO):
        raise Fallback('Candidate preparation run is not a successful same-repository PR run')
    attest_verify(prepared, commit, PREP_WORKFLOW, run_id, attempt, ref=f'refs/pull/{number}/merge')
    if value['recipeSha256'] != recipe_digest(ROOT):
        raise Fallback('Candidate release recipe differs from main')


def admit():
    stamp('admit_started')
    main = os.environ['GITHUB_SHA']
    if os.environ['GITHUB_REF'] != 'refs/heads/main' or os.environ['GITHUB_EVENT_NAME'] != 'push':
        raise Fallback('Promotion runs only for a push to main')
    WORK.mkdir(parents=True, exist_ok=True)
    DIST.mkdir(exist_ok=True)
    tree = git('rev-parse', f'{main}^{{tree}}')
    pool = concurrent.futures.ThreadPoolExecutor(max_workers=8)
    compiled = pool.submit(run, 'xcrun', 'swiftc', 'scripts/verify_update_archive.swift', '-o', str(VERIFIER))
    gates = pool.submit(local_deploy_policy.source_gates, main)
    pr = merged_pull_request(main)
    release = find_candidate(tree, pr)
    stamp('candidate_found')
    assets = {a['name']: a for a in release['assets']}
    if set(assets) != set(ASSETS):
        raise Fallback('Candidate draft has an unexpected asset set')
    downloads = {name: pool.submit(download_asset, assets[name], DIST / name) for name in ASSETS}
    downloads['prepared-release.json'].result()
    value = json.loads((DIST / 'prepared-release.json').read_text())
    verify_receipt(value, release, tree, pr, DIST / 'prepared-release.json')
    for name, future in downloads.items():
        future.result()
        if name != 'prepared-release.json' and (digest(DIST / name) != value['artifacts'][name]['sha256']
                or (DIST / name).stat().st_size != value['artifacts'][name]['sizeBytes']):
            raise Fallback(f'{name} differs from the attested candidate')
    stamp('candidate_downloaded_and_attested')
    validate_archive(DIST / ARCHIVE)
    run('ditto', '-x', '-k', str(DIST / ARCHIVE), str(DIST))
    info = plistlib.loads((DIST / APP / 'Contents/Info.plist').read_bytes())
    if info['GoalongSourceRevision'] != tree or info['CFBundleVersion'] != value['build']:
        raise Fallback('Signed bundle is not the candidate built from the main tree')
    run('bash', 'scripts/verify_release_bundle.sh', str(DIST / APP), value['version'], value['build'])
    compiled.result()
    os.environ['LOCALHISTORY_UPDATE_VERIFIER'] = str(VERIFIER)
    empty = WORK / 'no-deltas'
    empty.mkdir(exist_ok=True)
    run(str(VERIFIER), str(DIST / APP / 'Contents/Info.plist'), str(DIST / ARCHIVE),
        str(DIST / 'community-appcast.xml'), str(empty))
    require_successor(authenticated_state(WORK / 'previous-public'), info)
    stamp('candidate_verified')
    try:
        proof = gates.result()
    except local_deploy_policy.PendingGates as error:
        raise Fallback(f'Gates not admitted: {error}')
    stamp('gates_admitted')
    (WORK / 'source-gates.json').write_text(json.dumps(proof, indent=2) + '\n')
    binding = {'compiledFromCommit': value['preparedCommit'], 'sourceTree': tree,
               'preparedRun': value['run'], 'preparedTag': value['tag'], 'pullRequest': pr['number'],
               'preparedReleaseSha256': digest(DIST / 'prepared-release.json'), 'gateRuns': proof['runs']}
    (DIST / 'prepared-binding.json').write_text(json.dumps(binding, indent=2, sort_keys=True) + '\n')
    run('python3', 'scripts/generate_security_artifacts.py', '--app', str(DIST / APP), '--edition', 'unified',
        '--output-dir', str(DIST), '--include-release-artifacts')
    run('python3', 'scripts/verify_security_capabilities.py', '--manifest', str(DIST / 'security-capabilities.json'),
        '--app', str(DIST / APP), '--edition', 'unified')
    stamp('inventory_ready')
    pool.shutdown(wait=False)
    (WORK / 'admission.json').write_text(json.dumps({'release': release['id'], 'tag': value['tag'],
        'version': value['version'], 'build': value['build'], 'pullRequest': pr['number'], 'times': TIMES}))
    output(result='admitted', tag=value['tag'], version=value['version'], build=value['build'])


def rolling_release(admission, main):
    notes = WORK / 'rolling-notes.md'
    run('python3', 'scripts/render_rolling_notes.py', admission['version'], admission['build'], main, str(notes))
    run('gh', 'release', 'edit', ROLLING, '--repo', REPO, '--prerelease', '--latest=false', '--title',
        f"Goalong History {admission['version']} Community Build — latest main", '--notes-file', str(notes))
    run('gh', 'release', 'upload', ROLLING, '--repo', REPO, '--clobber',
        *(str(DIST / name) for name in (DMG, f'{DMG}.sha256', ARCHIVE, f'{ARCHIVE}.sha256', *FINAL_JSON)))


def publish():
    admission = json.loads((WORK / 'admission.json').read_text())
    TIMES.update(admission['times'])
    os.environ['LOCALHISTORY_UPDATE_VERIFIER'] = str(VERIFIER)
    stamp('publish_started')
    main, release_id, tag = os.environ['GITHUB_SHA'], admission['release'], admission['tag']
    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
        for future in [pool.submit(upload_asset, release_id, DIST / name) for name in FINAL_JSON]:
            future.result()
    current = {a['name']: a['id'] for a in api(f'releases/{release_id}')['assets']}
    for name in ('community-appcast.xml', DMG, f'{DMG}.sha256'):
        api(f'releases/assets/{current[name]}', method='DELETE')
    if remote_main() != main:
        raise RuntimeError('Main moved before publication; the newer main run publishes instead.')
    api(f'releases/{release_id}', method='PATCH', body={
        'draft': False, 'prerelease': True, 'make_latest': 'false', 'tag_name': tag, 'target_commitish': main,
        'name': f"Goalong History {admission['version']} — build {admission['build']}",
        'body': (f'Authenticated Community update archive for {main} (tree {git("rev-parse", "HEAD^{tree}")}). '
                 'Prepared from the identical PR tree, promoted by the exact-main run. '
                 'Stable certificate-backed identity; not Apple-notarized.')})
    reference = api(f'git/ref/tags/{tag}')['object']
    if reference['type'] != 'commit' or reference['sha'] != main:
        raise RuntimeError('Immutable tag does not point at the exact main commit')
    stamp('immutable_release_public')
    background = concurrent.futures.ThreadPoolExecutor(max_workers=1)
    rolling = background.submit(rolling_release, admission, main)
    if remote_main() != main:
        raise RuntimeError('Main moved before the feed replacement; refusing to write the feed.')
    info = plistlib.loads((DIST / APP / 'Contents/Info.plist').read_bytes())
    require_successor(authenticated_state(WORK / 'current-public'), info)
    run('gh', 'release', 'upload', ROLLING, str(DIST / 'community-appcast.xml'), '--repo', REPO, '--clobber')
    stamp('feed_uploaded')
    # Read the uploaded feed through the GitHub API: the public download URL can serve the
    # previous feed from cache for minutes. A later job checks the public URL without blocking.
    environment = dict(os.environ, LOCALHISTORY_PUBLIC_RECEIPT=str(DIST / 'public-verification.json'),
                       LOCALHISTORY_FEED_SOURCE='api')
    run('bash', 'scripts/verify_published_update.sh', str(DIST), env=environment)
    stamp('feed_verified')
    run('git', 'tag', '--force', ROLLING, main)
    run('git', 'push', 'origin', f'refs/tags/{ROLLING}', '--force')
    rolling.result()
    stamp('rolling_release_done')
    for draft in api('releases?per_page=100'):
        if draft['draft'] and draft['name'].startswith('Prepared tree ') and f"PR #{admission['pullRequest']}" in (draft['body'] or ''):
            api(f"releases/{draft['id']}", method='DELETE')
    (DIST / 'promotion-timings.json').write_text(json.dumps(TIMES, indent=2) + '\n')
    summary('### Fast-path promotion (UTC)\n' + '\n'.join(f'- {k}: {v}' for k, v in TIMES.items()))


if __name__ == '__main__':
    if sys.argv[1] == 'publish':
        publish()
    else:
        try:
            admit()
        except Exception as error:  # Nothing public changed: the full fallback build runs.
            print(f'::warning::Fast path not admitted: {error}', flush=True)
            summary(f'Fast path not admitted, full fallback runs: {error}')
            output(result='fallback')
