#!/usr/bin/env python3
"""Package the committed Maia model into checksum-pinned static Pages assets."""
import gzip
import hashlib
import json
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parents[1]
PUBLIC = ROOT / 'python/twic-position-finder/frontend/public/prep-engine'

def main():
    PUBLIC.mkdir(parents=True, exist_ok=True)
    model = (ROOT / 'assets/maia3_simplified.onnx').read_bytes()
    compressed = gzip.compress(model, mtime=0)
    digest = lambda data: hashlib.sha256(data).hexdigest()
    chunks = []
    for i, start in enumerate(range(0, len(compressed), 16 * 1024 * 1024)):
        data = compressed[start:start + 16 * 1024 * 1024]
        name = f'maia-{digest(compressed)[:12]}-{i}.bin'
        (PUBLIC / name).write_bytes(data)
        chunks.append({'file': name, 'bytes': len(data), 'sha256': digest(data)})
    vocabulary = (ROOT / 'assets/data/all_moves_maia3.json').read_bytes()
    vocab_name = f'moves-{digest(vocabulary)[:12]}.json'
    (PUBLIC / vocab_name).write_bytes(vocabulary)
    (PUBLIC / 'model.json').write_text(json.dumps({'sha256': digest(model), 'chunks': chunks, 'vocabulary': vocab_name}, indent=2) + '\n')
    shutil.copyfile(ROOT / 'LICENSE', PUBLIC / 'LICENSE.txt')
    shutil.copyfile(ROOT / 'assets/licenses/MAIA3_LICENSE.txt', PUBLIC / 'MAIA3_LICENSE.txt')
    for path in PUBLIC.iterdir():
        if path.stat().st_size >= 25 * 1024 * 1024:
            raise SystemExit(f'{path.name} exceeds the Pages asset limit')
    print(f'Static Maia assets: {len(compressed) / 1024 / 1024:.1f} MiB in {len(chunks)} parts.')

if __name__ == '__main__':
    main()
