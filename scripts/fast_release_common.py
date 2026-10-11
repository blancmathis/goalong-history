#!/usr/bin/env python3
"""Shared digest and verified-certificate checks for prepared/final releases."""
import hashlib
import json
from pathlib import Path
import subprocess

REPO = 'blancmathis/goalong-history'
ARCHIVE = 'Goalong-History-macOS-universal.zip'
APP = 'Goalong History.app'

def digest(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(1024*1024), b''):
            h.update(block)
    return h.hexdigest()

def verified_certificate(rows, sha, workflow, run_id=None, attempt=None, ref='refs/heads/main'):
    for row in rows:
        result = row['verificationResult']
        certificate = result['signature']['certificate']
        expected = {'sourceRepositoryURI': f'https://github.com/{REPO}',
                    'sourceRepositoryDigest': sha, 'sourceRepositoryRef': ref,
                    'buildSignerURI': f'https://github.com/{REPO}/.github/workflows/{workflow}@{ref}',
                    'buildSignerDigest': sha, 'runnerEnvironment': 'github-hosted'}
        if any(certificate.get(k) != v for k, v in expected.items()):
            continue
        if result['statement']['predicateType'] != 'https://slsa.dev/provenance/v1':
            continue
        if run_id is not None and certificate.get('runInvocationURI') != f'https://github.com/{REPO}/actions/runs/{run_id}/attempts/{attempt}':
            continue
        return certificate
    raise ValueError('Verified attestation certificate has the wrong exact source/ref/workflow/run')

def attest_verify(path, sha, workflow, run_id=None, attempt=None, ref='refs/heads/main'):
    raw = subprocess.check_output(['gh', 'attestation', 'verify', str(path), '--repo', REPO,
        '--source-digest', sha, '--source-ref', ref, '--signer-digest', sha,
        '--signer-workflow', f'{REPO}/.github/workflows/{workflow}', '--deny-self-hosted-runners',
        '--predicate-type', 'https://slsa.dev/provenance/v1', '--format', 'json'], text=True)
    rows = json.loads(raw)
    verified_certificate(rows, sha, workflow, run_id, attempt, ref)
    return rows

def recipe_digest(root):
    h = hashlib.sha256()
    names = subprocess.check_output(['git', 'ls-files', '-z', 'scripts', 'Distribution',
                                    'Package.swift', 'Package.resolved', 'VERSION'], cwd=root).decode().split('\0')
    for name in sorted(n for n in names if n):
        h.update(name.encode() + b'\0')
        h.update((Path(root)/name).read_bytes())
    return h.hexdigest()
