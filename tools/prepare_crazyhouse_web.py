#!/usr/bin/env python3
"""Prepare the static /bughouse engine: Lichess's Fairy-Stockfish build.

The page plays Fairy-Stockfish's pocketknight variant, which has no net, so
only the engine module and its license are copied from @lichess-org/stockfish-web.
Files from the old crazyhouse page (its net parts) are removed.
"""
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parents[1]
FRONTEND = ROOT / 'python/twic-position-finder/frontend'
PUBLIC = FRONTEND / 'public/crazyhouse-engine'


def main():
    PUBLIC.mkdir(parents=True, exist_ok=True)
    for old in [*PUBLIC.glob('net-*.bin'), PUBLIC / 'net.json']:
        old.unlink(missing_ok=True)
    package = FRONTEND / 'node_modules/@lichess-org/stockfish-web'
    for name in ['fsf_14.js', 'fsf_14.wasm']:
        shutil.copyfile(package / name, PUBLIC / name)
    shutil.copyfile(package / 'LICENSE', PUBLIC / 'STOCKFISH_WEB_LICENSE.txt')
    for path in PUBLIC.iterdir():
        if path.is_file() and path.stat().st_size >= 25 * 1024 * 1024:
            raise SystemExit(f'{path.name} exceeds Cloudflare Pages\' 25 MiB file limit')
    print('Static bughouse engine ready; every file is below 25 MiB.')


if __name__ == '__main__':
    main()
