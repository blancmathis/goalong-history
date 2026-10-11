#!/usr/bin/env python3
"""Hosted PR preparation: bind signed candidate bytes to their source tree in a private draft.

receipt: write dist/prepared-release.json (attested by the workflow).
stage:   replace this PR's older drafts with one draft holding the attested bytes.
Nothing here is public. Only promote_prepared_release.py, in the exact-main run, may publish.
"""
from datetime import datetime, timedelta, timezone
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import xml.etree.ElementTree as ET

sys.path.insert(0, str(Path(__file__).resolve().parent))
from fast_release_common import ARCHIVE, REPO, digest, recipe_digest

ROOT = Path(__file__).resolve().parents[1]
DIST = ROOT / 'dist'
DMG = 'Goalong-History-macOS-universal.dmg'
ASSETS = ['prepared-release.json', 'community-appcast.xml', ARCHIVE, f'{ARCHIVE}.sha256', DMG, f'{DMG}.sha256']
SPARKLE = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
VALIDITY = timedelta(hours=24)


def git(*args):
    return subprocess.check_output(['git', *args], cwd=ROOT, text=True).strip()


def draft_name(tree):
    return f'Prepared tree {tree}'


def receipt():
    env = os.environ
    info = plistlib.loads((DIST / 'Goalong History.app/Contents/Info.plist').read_bytes())
    tree = git('rev-parse', 'HEAD^{tree}')
    if git('rev-parse', 'HEAD') != env['GITHUB_SHA'] or info['GoalongSourceRevision'] != tree:
        raise ValueError('Candidate bundle is not bound to the checked-out merge tree')
    if git('status', '--porcelain', '--untracked-files=no'):
        raise ValueError('Candidate checkout is dirty')
    enclosure = ET.parse(DIST / 'community-appcast.xml').find('./channel/item/enclosure')
    now = datetime.now(timezone.utc).replace(microsecond=0)
    value = {
        'schemaVersion': 1, 'repository': REPO,
        'pullRequest': int(env['PR_NUMBER']), 'headCommit': env['PR_HEAD'], 'baseCommit': env['PR_BASE'],
        'preparedCommit': env['GITHUB_SHA'], 'preparedRef': env['GITHUB_REF'], 'sourceTree': tree,
        'run': {'id': int(env['GITHUB_RUN_ID']), 'attempt': int(env['GITHUB_RUN_ATTEMPT'])},
        'tag': env['IMMUTABLE_TAG'], 'version': info['CFBundleShortVersionString'], 'build': info['CFBundleVersion'],
        'recipeSha256': recipe_digest(ROOT),
        'enclosure': {'url': enclosure.attrib['url'], 'sizeBytes': int(enclosure.attrib['length']),
                      'edSignature': enclosure.attrib[f'{SPARKLE}edSignature']},
        'artifacts': {name: {'sha256': digest(DIST / name), 'sizeBytes': (DIST / name).stat().st_size}
                      for name in ASSETS[1:]},
        'createdAt': now.isoformat(), 'expiresAt': (now + VALIDITY).isoformat(),
    }
    if not value['enclosure']['url'].endswith(f"/{value['tag']}/{ARCHIVE}"):
        raise ValueError('Candidate enclosure does not point at its own immutable tag')
    if value['enclosure']['sizeBytes'] != value['artifacts'][ARCHIVE]['sizeBytes']:
        raise ValueError('Candidate enclosure and archive size disagree')
    (DIST / 'prepared-release.json').write_text(json.dumps(value, indent=2, sort_keys=True) + '\n')


def releases():
    raw = subprocess.check_output(['gh', 'api', '--paginate', f'repos/{REPO}/releases?per_page=100', '--jq',
                                   '.[] | {id, draft, name, body, created_at, tag_name}'], text=True)
    return [json.loads(line) for line in raw.splitlines() if line]


def stage():
    value = json.loads((DIST / 'prepared-release.json').read_text())
    marker = f"PR #{value['pullRequest']}"
    stale = datetime.now(timezone.utc) - timedelta(days=3)
    for release in releases():
        # Only drafts written by this workflow; never a published release.
        if not release['draft'] or not release['name'].startswith('Prepared tree '):
            continue
        created = datetime.fromisoformat(release['created_at'].replace('Z', '+00:00'))
        if marker in (release['body'] or '') or created < stale:
            subprocess.run(['gh', 'api', '-X', 'DELETE', f"repos/{REPO}/releases/{release['id']}"], check=True)
    body = (f"Private candidate for {marker}, head {value['headCommit']}, merge {value['preparedCommit']}, "
            f"tree {value['sourceTree']}, run {value['run']['id']}/{value['run']['attempt']}. "
            'Draft only; published solely by the exact-main promotion after all checks.')
    subprocess.run(['gh', 'release', 'create', value['tag'], '--repo', REPO, '--draft', '--prerelease',
                    '--target', 'main', '--title', draft_name(value['sourceTree']), '--notes', body,
                    *(str(DIST / name) for name in ASSETS)], check=True)


if __name__ == '__main__':
    {'receipt': receipt, 'stage': stage}[sys.argv[1]]()
