#!/usr/bin/env python3
"""Fetch the pinned, official Codex runtime for a Goalong build (never at app launch)."""
from pathlib import Path
import argparse, hashlib, json, os, shutil, subprocess, tarfile, tempfile, urllib.request

VERSION = 'rust-v0.154.0'
ARTIFACTS = {
    'arm64': ('aarch64', '344310a0a591c1b192e04feff304321a69907c9498baaac331ca7e16ebcef9d7'),
    'x86_64': ('x86_64', '1219c837d8f813b493a424c125c0038b5d9ca16279bc6d3fe6ce037a3e18a6e7'),
}

def fetch(url: str, target: Path, digest: str | None = None, maximum: int = 150_000_000) -> None:
    if target.is_file() and digest and hashlib.sha256(target.read_bytes()).hexdigest() == digest:
        return
    request = urllib.request.Request(url, headers={'User-Agent': 'Goalong-History-build'})
    temporary = target.with_name(target.name + '.part')
    hasher = hashlib.sha256()
    size = 0
    try:
        with urllib.request.urlopen(request, timeout=60) as source, temporary.open('wb') as output:
            while block := source.read(1024 * 1024):
                size += len(block)
                if size > maximum:
                    raise RuntimeError('Official runtime exceeded the build size bound')
                output.write(block); hasher.update(block)
        if digest and hasher.hexdigest() != digest:
            raise RuntimeError('Official runtime checksum mismatch; refusing to package')
        temporary.replace(target)
    finally:
        temporary.unlink(missing_ok=True)

def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cache', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--archs', nargs='+', default=['arm64', 'x86_64'], choices=ARTIFACTS)
    args = parser.parse_args()
    args.cache.mkdir(parents=True, exist_ok=True)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    paths = []
    for arch in args.archs:
        target_arch, digest = ARTIFACTS[arch]
        name = f'codex-{target_arch}-apple-darwin'
        archive = args.cache / f'{VERSION}-{name}.tar.gz'
        url = f'https://github.com/openai/codex/releases/download/{VERSION}/{name}.tar.gz'
        print(f'Verifying official Codex {VERSION} for {arch}', flush=True)
        fetch(url, archive, digest)
        binary = args.cache / f'{VERSION}-{name}'
        with tarfile.open(archive, 'r:gz') as bundle:
            members = [m for m in bundle.getmembers() if m.isfile() and Path(m.name).name == name]
            if len(members) != 1 or members[0].size > 350_000_000:
                raise RuntimeError('Unexpected Codex runtime archive')
            with bundle.extractfile(members[0]) as source, binary.open('wb') as output:
                shutil.copyfileobj(source, output)
        binary.chmod(0o755)
        subprocess.run(['/usr/bin/lipo', str(binary), '-verify_arch', arch], check=True)
        paths.append(binary)
    if len(paths) == 1:
        shutil.copy2(paths[0], args.output)
    else:
        subprocess.run(['/usr/bin/lipo', '-create', *map(str, paths), '-output', str(args.output)], check=True)
    args.output.chmod(0o755)
    license_file = args.output.with_name('CODEX-LICENSE.txt')
    fetch(f'https://raw.githubusercontent.com/openai/codex/{VERSION}/LICENSE', license_file, maximum=100_000)
    args.output.with_name('codex-runtime.json').write_text(json.dumps({
        'version': VERSION, 'source': 'https://github.com/openai/codex',
        'architectures': args.archs, 'archiveSHA256': {k: ARTIFACTS[k][1] for k in args.archs}
    }, indent=2) + '\n')
    print(str(args.output), flush=True)

if __name__ == '__main__':
    main()
