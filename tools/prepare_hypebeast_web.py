#!/usr/bin/env python3
"""Prepare the /bughouse board's engine: HypeBeast compiled to WebAssembly and its net.

HypeBeast (https://github.com/Zinkelburger/HypeBeast) is a Fairy-Stockfish fork
that plays bughouse knowing both boards. Its browser build (hypebeast.js,
hypebeast.wasm), the build record (build.json) and the exact source it was built
from (hypebeast-source.tar.gz, for the GPL) are committed under
public/hypebeast-engine/; Cloudflare Pages compiles nothing. Every site build
checks those files against build.json, then puts Fairy-Stockfish's bughouse net,
pinned by checksum, in gzipped parts below Pages' 25 MiB file limit.

Set HYPEBEAST_NNUE to a local copy of the net to skip the download.

To take a new engine build into the site:

    python3 tools/prepare_hypebeast_web.py --import /path/to/HypeBeast

with HypeBeast's web/build.sh already run there and its tree committed.
"""
import argparse
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
FRONTEND = ROOT / 'python/twic-position-finder/frontend'
PUBLIC = FRONTEND / 'public/hypebeast-engine'
CACHE = ROOT / 'build/hypebeast-web'
NET = 'bughouse-cd8cceab93fe.nnue'
NET_SHA256 = 'cd8cceab93fed185b79932414d1a0823f40e15a09ca9776ceab7c9c5272ddc13'
# Fairy-Stockfish's published bughouse net (https://fairy-stockfish.github.io/nnue/).
NET_URL = 'https://drive.usercontent.google.com/download?id=1qZVSzm5G_KRc33YCqmsPM6Ayxo3CI4ME&export=download&confirm=t'
CHUNK = 16 * 1024 * 1024
LIMIT = 25 * 1024 * 1024
ENGINE_FILES = ['hypebeast.js', 'hypebeast.wasm']


def digest(data):
    return hashlib.sha256(data).hexdigest()


def network():
    local = os.environ.get('HYPEBEAST_NNUE')
    cached = CACHE / NET
    for path in [Path(local)] if local else [cached]:
        if path.is_file() and digest(data := path.read_bytes()) == NET_SHA256:
            return data
    if local:
        raise SystemExit(f'HYPEBEAST_NNUE={local} is not the pinned bughouse net.')
    print('Downloading the pinned bughouse network for the static website…', flush=True)
    with urllib.request.urlopen(NET_URL, timeout=300) as response:
        data = response.read()
    if digest(data) != NET_SHA256:
        raise SystemExit('Bughouse network checksum mismatch (the download may have been a Google Drive page).')
    CACHE.mkdir(parents=True, exist_ok=True)
    cached.write_bytes(data)
    return data


def import_build(source: Path):
    """Copies HypeBeast's web build in, with its record and its source."""
    def git(*args):
        return subprocess.check_output(['git', *args], cwd=source, text=True).strip()

    if git('status', '--porcelain', '--', 'engine', 'web'):
        raise SystemExit(f'{source}: commit the engine and web changes first, so the source archive matches the build.')
    dist = source / 'web/dist'
    for name in ENGINE_FILES:
        if not (dist / name).is_file():
            raise SystemExit(f'{dist / name} is missing: run web/build.sh in {source} first.')
    commit = git('rev-parse', 'HEAD')
    PUBLIC.mkdir(parents=True, exist_ok=True)
    record = {'source': 'https://github.com/Zinkelburger/HypeBeast', 'commit': commit, 'files': {}}
    for name in ENGINE_FILES:
        shutil.copyfile(dist / name, PUBLIC / name)
        record['files'][name] = digest((PUBLIC / name).read_bytes())
    build_sh = (source / 'web/build.sh').read_text()
    record['emscripten'] = next((line.split('=')[1] for line in build_sh.splitlines() if line.startswith('want=')), 'unknown')
    record['build'] = 'web/build.sh'
    archive = subprocess.check_output(['git', 'archive', '--format=tar', f'--prefix=hypebeast-{commit[:12]}/', commit,
                                       'engine', 'web', 'LICENSE', 'README.md'], cwd=source)
    (PUBLIC / 'hypebeast-source.tar.gz').write_bytes(gzip.compress(archive, compresslevel=9, mtime=0))
    record['files']['hypebeast-source.tar.gz'] = digest((PUBLIC / 'hypebeast-source.tar.gz').read_bytes())
    # The engine is GPL-3.0-or-later; its licence goes with the binaries.
    with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
        member = tar.extractfile(f'hypebeast-{commit[:12]}/engine/Copying.txt')
        assert member is not None  # a regular file in the archive
        copying = member.read()
    (PUBLIC / 'HYPEBEAST_LICENSE.txt').write_bytes(copying)
    (PUBLIC / 'build.json').write_text(json.dumps(record, indent=2) + '\n')
    print(f'Imported HypeBeast {commit[:12]} into {PUBLIC.relative_to(ROOT)}.')


def check_build():
    record_path = PUBLIC / 'build.json'
    if not record_path.is_file():
        raise SystemExit(f'{record_path.relative_to(ROOT)} is missing: import a HypeBeast build (see this script\'s --help).')
    record = json.loads(record_path.read_text())
    for name, sha in record['files'].items():
        path = PUBLIC / name
        if not path.is_file() or digest(path.read_bytes()) != sha:
            raise SystemExit(f'{path.relative_to(ROOT)} does not match build.json: import the HypeBeast build again.')


def prepare_net():
    manifest_path = PUBLIC / 'net.json'
    current = json.loads(manifest_path.read_text()) if manifest_path.exists() else {}
    if current.get('sha256') == NET_SHA256 and all((PUBLIC / c['file']).is_file() for c in current.get('chunks', [])):
        return
    for old in PUBLIC.glob('net-*.bin'):
        old.unlink()
    compressed = gzip.compress(network(), compresslevel=6, mtime=0)
    chunks = []
    for index, start in enumerate(range(0, len(compressed), CHUNK)):
        part = compressed[start:start + CHUNK]
        name = f'net-{NET_SHA256[:12]}-{index}.bin'
        (PUBLIC / name).write_bytes(part)
        chunks.append({'file': name, 'bytes': len(part), 'sha256': digest(part)})
    manifest_path.write_text(json.dumps({'name': NET, 'sha256': NET_SHA256, 'chunks': chunks}, indent=2) + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--import', dest='source', type=Path, help='a HypeBeast checkout whose web build to take in')
    args = parser.parse_args()
    if args.source:
        import_build(args.source.resolve())
    check_build()
    prepare_net()
    for path in PUBLIC.iterdir():
        if path.is_file() and path.stat().st_size >= LIMIT:
            raise SystemExit(f'{path.name} exceeds Cloudflare Pages\' 25 MiB file limit')
    print('Static HypeBeast engine ready; every file is below 25 MiB.')


if __name__ == '__main__':
    main()
