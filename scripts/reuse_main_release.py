#!/usr/bin/env python3
"""Tagged release from the bytes main already published, never a second build.

locate SHA VERSION   (any runner) wait for continuous-release to publish SHA, then print
                     found=true|false and tag=main-<run>-<attempt> (the release holding its archive).
verify SHA VERSION TAG  (macOS) download the latest-main generation of SHA into dist/ and
                     prove, before anything is published, that it is exactly what main built,
                     signed and verified: hashes, sizes, Sigstore attestations of the
                     continuous-release run at SHA, the three hosted gates on SHA's tree,
                     pinned code signature, architecture, identity, Sparkle Ed25519 feed and
                     archive signatures, the DMG's app identical to the ZIP's app, and the
                     security inventory. Any doubt => exit 1 (the workflow then fails; it
                     never publishes unverified bytes).
"""
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))
from fast_release_common import APP, ARCHIVE, REPO, attest_verify, digest
import local_deploy_policy

ROOT = Path(__file__).resolve().parents[1]
DIST = ROOT / 'dist'
DMG = 'Goalong-History-macOS-universal.dmg'
WORKFLOW = 'continuous-release.yml'
ROLLING = 'latest-main'
# Exactly the files release.yml has always published, plus the authenticated feed used to check them.
PUBLISHED = [DMG, f'{DMG}.sha256', ARCHIVE, f'{ARCHIVE}.sha256',
             'security-capabilities.json', 'sbom.spdx.json', 'release-manifest.json']
FEED = 'community-appcast.xml'
WAIT_SECONDS = int(os.environ.get('GOALONG_REUSE_WAIT_SECONDS', str(110 * 60)))


def run(*argv, **kwargs):
    print('+', ' '.join(map(str, argv)), flush=True)
    return subprocess.run([str(a) for a in argv], check=True, **kwargs)


def api(path):
    return json.loads(subprocess.check_output(['gh', 'api', f'repos/{REPO}/{path}'], text=True))


def output(**values):
    with open(os.environ.get('GITHUB_OUTPUT', '/dev/stdout'), 'a') as stream:
        for key, value in values.items():
            stream.write(f'{key}={value}\n')


def summary(text):
    print(text, flush=True)
    if os.environ.get('GITHUB_STEP_SUMMARY'):
        with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as stream:
            stream.write(text + '\n')


def rolling_manifest():
    release = api(f'releases/tags/{ROLLING}')
    asset = next((a for a in release['assets'] if a['name'] == 'release-manifest.json'), None)
    if not asset:
        return None
    raw = subprocess.check_output(['gh', 'api', '-H', 'Accept: application/octet-stream',
                                   f"repos/{REPO}/releases/assets/{asset['id']}"])
    return json.loads(raw)


def immutable_tag(manifest):
    # The immutable release that holds this generation: main-<run>-<attempt> of the full build,
    # or of the Prepare run whose candidate main promoted. The feed's archive URL names it, and
    # verify() binds that URL to the archive digest, the public receipt and the attestations.
    url = (manifest.get('fullEnclosure') or {}).get('url', '')
    match = re.fullmatch(rf'https://github\.com/{re.escape(REPO)}/releases/download/(main-\d+-\d+)/{re.escape(ARCHIVE)}', url)
    return match[1] if match else None


def capture(sha, tag):
    # The DMG, its digest and the feed live only in the rolling release, which the next main
    # push replaces. Copy them now; release.yml hands this copy to verify(), which checks it all.
    DIST.mkdir(parents=True, exist_ok=True)
    run('gh', 'release', 'download', ROLLING, '--repo', REPO, '--dir', DIST, '--clobber',
        *sum((['--pattern', name] for name in [*PUBLISHED, FEED]), []))
    manifest = json.loads((DIST / 'release-manifest.json').read_text())
    return manifest.get('sourceCommit') == sha and immutable_tag(manifest) == tag


def locate(sha, version):
    deadline = time.monotonic() + WAIT_SECONDS
    while True:
        manifest = rolling_manifest()
        if manifest and manifest.get('sourceCommit') == sha:
            got = (manifest.get('product') or {}).get('version')
            if got != version:
                summary(f'main published {sha} as {got}, not {version}: full build fallback.')
                return output(found='false')
            tag = immutable_tag(manifest)
            if not tag:
                summary(f'{ROLLING} names no immutable archive for {sha}: full build fallback.')
                return output(found='false')
            if not capture(sha, tag):
                summary(f'{ROLLING} moved past {sha} while it was being copied: full build fallback.')
                return output(found='false')
            summary(f'Reusing the {version} generation main published for {sha} ({tag}).')
            return output(found='true', tag=tag)
        runs = api(f'actions/workflows/{WORKFLOW}/runs?head_sha={sha}&event=push&per_page=20')['workflow_runs']
        if not runs or all(r['status'] == 'completed' for r in runs) or time.monotonic() > deadline:
            summary(f'No published main generation for {sha} in {ROLLING}: full build fallback.')
            return output(found='false')
        print(f'continuous-release for {sha} still running; waiting.', flush=True)
        time.sleep(30)


def require(condition, message):
    if not condition:
        raise SystemExit(f'Refusing to reuse main bytes: {message}')


def gates(sha, tree):
    candidates, merged_at = [sha], None
    for pr in local_deploy_policy.pages(f'commits/{sha}/pulls'):
        if (pr['merged_at'] and pr['merge_commit_sha'] == sha and pr['base']['ref'] == 'main'
                and pr['head']['repo'] and pr['head']['repo']['full_name'] == REPO):
            merged_at = pr['merged_at']
            candidates.append(pr['head']['sha'])
    return local_deploy_policy.gates_for(candidates, tree, sha, merged_at)


def cdhash(app):
    details = subprocess.run(['codesign', '-dvvv', str(app)], capture_output=True, text=True, check=True).stderr
    match = re.search(r'^CDHash=([0-9a-f]+)$', details, re.M)
    require(match, f'no CDHash for {app}')
    return match[1]


def verify(sha, version, tag):
    started = time.monotonic()
    work = Path(os.environ.get('RUNNER_TEMP', tempfile.gettempdir())) / 'goalong-reuse'
    immutable = work / 'immutable'
    for path in (DIST, immutable):
        path.mkdir(parents=True, exist_ok=True)
    require(re.fullmatch(r'[0-9a-f]{40}', sha), 'full source SHA required')
    tree = local_deploy_policy.tree_for(sha)

    # DIST holds the copy locate() took from the rolling release; every check below applies to it.
    for name in [*PUBLISHED, FEED]:
        require((DIST / name).is_file(), f'{name} was not captured by locate')
    run('gh', 'release', 'download', tag, '--repo', REPO, '--dir', immutable, '--clobber',
        '--pattern', f'{ARCHIVE}.sha256', '--pattern', 'public-verification.json',
        '--pattern', 'Goalong-History-macOS-universal-from-*.delta')

    # 1. The manifest names this commit, version and run, and binds every downloaded byte.
    manifest = json.loads((DIST / 'release-manifest.json').read_text())
    product = manifest.get('product') or {}
    require(manifest.get('sourceCommit') == sha and manifest.get('sourceTree') == tree
            and manifest.get('sourceDirty') is False, 'manifest is not the clean main tree')
    require(product.get('version') == version and product.get('bundleIdentifier') == 'ai.goalong.localhistory'
            and product.get('edition') == 'unified', 'manifest product differs')
    require(immutable_tag(manifest) == tag, 'manifest archive URL is not the immutable tag')
    listed = {a['path']: a for a in manifest.get('artifacts', [])}
    # continuous-release binds these in the manifest; the DMG and the .sha256 files are bound
    # by their own attestations (step 3), the digest files below and the DMG = ZIP check (step 6).
    bound = [(DIST / n) for n in (ARCHIVE, 'security-capabilities.json', 'sbom.spdx.json', FEED)]
    deltas = sorted(immutable.glob('Goalong-History-macOS-universal-from-*.delta'))
    require({p.name for p in deltas} == {n for n in listed if n.endswith('.delta')},
            'immutable deltas differ from the manifest')
    for path in [*bound, *deltas]:
        entry = listed.get(path.name)
        require(entry, f'{path.name} is not bound by the manifest')
        require(digest(path) == entry['sha256'] and path.stat().st_size == entry['sizeBytes'],
                f'{path.name} differs from the manifest')
    for name in (DMG, ARCHIVE):
        recorded = (DIST / f'{name}.sha256').read_text().split()
        require(recorded == [digest(DIST / name), name], f'{name}.sha256 does not match {name}')
    enclosure = manifest.get('fullEnclosure') or {}
    require(enclosure.get('sha256') == digest(DIST / ARCHIVE)
            and enclosure.get('url', '').endswith(f'/{tag}/{ARCHIVE}'), 'feed enclosure is not this immutable archive')

    # 2. The immutable release of that run publicly verified the same archive.
    receipt = json.loads((immutable / 'public-verification.json').read_text())
    require(receipt.get('verification') == 'PUBLIC_UPDATE_VERIFIED' and receipt.get('sourceCommit') == sha
            and receipt.get('tag') == tag and (receipt.get('archive') or {}).get('sha256') == digest(DIST / ARCHIVE),
            'public verification receipt does not cover this archive')
    require((immutable / f'{ARCHIVE}.sha256').read_bytes() == (DIST / f'{ARCHIVE}.sha256').read_bytes(),
            'immutable and rolling archive digests differ')

    # 3. Sigstore: every byte was attested by continuous-release.yml running at this exact main commit.
    for path in [*(DIST / n for n in [*PUBLISHED, FEED]), immutable / 'public-verification.json', *deltas]:
        attest_verify(path, sha, WORKFLOW)
    print('Attestations verified for continuous-release.yml at', sha, flush=True)

    # 4. The three official hosted gates (full test suite included) passed on this tree.
    proof = gates(sha, tree)
    (work / 'source-gates.json').write_text(json.dumps(proof, indent=2) + '\n')
    print('Gates passed:', json.dumps(proof['runs']), flush=True)

    # 5. The app: pinned signature, universal binary, identity, Sparkle key, built from this tree.
    app = DIST / APP
    run('ditto', '-x', '-k', DIST / ARCHIVE, DIST)
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    require(info.get('GoalongSourceRevision') == tree, 'app was not built from this tree')
    require(info.get('CFBundleShortVersionString') == version and info.get('CFBundleVersion') == product.get('build'),
            'app version/build differs from the manifest')
    run('bash', 'scripts/verify_release_bundle.sh', app, version, product['build'])

    # 6. The DMG carries the very same signed app.
    mount = work / 'dmg'
    mount.mkdir(exist_ok=True)
    run('hdiutil', 'attach', DIST / DMG, '-readonly', '-nobrowse', '-noautoopen', '-mountpoint', mount)
    try:
        mounted = mount / APP
        run('codesign', '--verify', '--strict', '--verbose=4', mounted)
        require(cdhash(mounted) == cdhash(app), 'DMG app differs from the ZIP app')
        require((mounted / 'Contents/Info.plist').read_bytes() == (app / 'Contents/Info.plist').read_bytes(),
                'DMG Info.plist differs')
    finally:
        subprocess.run(['hdiutil', 'detach', str(mount), '-force'], check=False)

    # 7. Sparkle: the authenticated feed signs this archive and its deltas with the shipped key.
    verifier = work / 'verify-update'
    run('xcrun', 'swiftc', 'scripts/verify_update_archive.swift', '-o', verifier)
    run(verifier, app / 'Contents/Info.plist', DIST / ARCHIVE, DIST / FEED, immutable)

    # 8. The published security inventory describes this app.
    run('python3', 'scripts/verify_security_capabilities.py', '--manifest', DIST / 'security-capabilities.json',
        '--app', app, '--edition', 'unified')

    output(build=product['build'])
    summary(f'Reused {tag} for {version} ({product["build"]}) at {sha}: every check passed '
            f'in {time.monotonic() - started:.0f} s.')


if __name__ == '__main__':
    command, args = sys.argv[1], sys.argv[2:]
    {'locate': locate, 'verify': verify}[command](*args)
