#!/usr/bin/env python3
"""Prepare the /bughouse board's engine: Lichess's Fairy-Stockfish build and its crazyhouse net.

The net is Lichess's own (lichess-org/lifat), pinned by checksum, gzipped and split
below Cloudflare Pages' 25 MiB file limit. Set CRAZYHOUSE_NNUE to a local copy to
skip the download.
"""
import gzip
import hashlib
import json
import os
from pathlib import Path
import shutil
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
FRONTEND = ROOT / 'python/twic-position-finder/frontend'
PUBLIC = FRONTEND / 'public/crazyhouse-engine'
CACHE = ROOT / 'build/crazyhouse-web'
NET = 'crazyhouse-8ebf84784ad2.nnue'
NET_SHA256 = '8ebf84784ad20fa33df403e60211818a7486db7cb8c3decfc86a80238d254f43'
NET_URL = f'https://raw.githubusercontent.com/lichess-org/lifat/master/nnue/{NET}'
CHUNK = 16 * 1024 * 1024


def digest(data):
    return hashlib.sha256(data).hexdigest()


def network():
    local = os.environ.get('CRAZYHOUSE_NNUE')
    cached = CACHE / NET
    for path in [Path(local)] if local else [cached]:
        if path.is_file() and digest(data := path.read_bytes()) == NET_SHA256:
            return data
    print('Downloading the pinned crazyhouse network for the static website…', flush=True)
    with urllib.request.urlopen(NET_URL, timeout=300) as response:
        data = response.read()
    if digest(data) != NET_SHA256:
        raise SystemExit('Crazyhouse network checksum mismatch.')
    CACHE.mkdir(parents=True, exist_ok=True)
    cached.write_bytes(data)
    return data


def main():
    PUBLIC.mkdir(parents=True, exist_ok=True)
    manifest_path = PUBLIC / 'net.json'
    current = json.loads(manifest_path.read_text()) if manifest_path.exists() else {}
    if current.get('sha256') != NET_SHA256 or not all((PUBLIC / c['file']).is_file() for c in current.get('chunks', [])):
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
    package = FRONTEND / 'node_modules/@lichess-org/stockfish-web'
    for name in ['fsf_14.js', 'fsf_14.wasm']:
        shutil.copyfile(package / name, PUBLIC / name)
    shutil.copyfile(package / 'LICENSE', PUBLIC / 'STOCKFISH_WEB_LICENSE.txt')
    for path in PUBLIC.iterdir():
        if path.is_file() and path.stat().st_size >= 25 * 1024 * 1024:
            raise SystemExit(f'{path.name} exceeds Cloudflare Pages\' 25 MiB file limit')
    print('Static crazyhouse engine ready; every file is below 25 MiB.')


if __name__ == '__main__':
    main()
