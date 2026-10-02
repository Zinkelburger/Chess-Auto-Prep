#!/usr/bin/env python3
"""Install the pinned Linux x86-64 CrazyAra policy runtime for Bughouse Lab.

Run through scripts/ci.sh with -- python3 tools/setup_crazyara.py.
--cache accepts the earlier research downloads; no user game data is touched.
"""
import argparse
import hashlib
import os
from pathlib import Path
import platform
import shutil
import stat
import tarfile
import tempfile
import urllib.request
import zipfile

ASSETS = {
    'Aras_1.0.5_Linux_OpenVino.zip': (
        'https://github.com/QueensGambit/CrazyAra/releases/download/1.0.5/Aras_1.0.5_Linux_OpenVino.zip',
        'f7ad90ec2b27d16966d7b5a944a756df993e3b09d07522fd015971837b63a846'),
    'CrazyAra-rl-model-os-96.zip': (
        'https://github.com/QueensGambit/CrazyAra/releases/download/0.9.5/CrazyAra-rl-model-os-96.zip',
        'd5fb44a0a3b149d308a8b6e548f5df60bcb1f7fad442ad38e38d4b8d974c0276'),
    'tbb-2020.3-lin.tgz': (
        'https://github.com/uxlfoundation/oneTBB/releases/download/v2020.3/tbb-2020.3-lin.tgz',
        'bb8cddd0277605d3ee7f4e19b138c983f298d69fcbb585385b59ef7239d5ef83'),
}


def install(destination, cache):
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists():
        raise SystemExit(f'{destination} already exists; refusing to replace it.')
    cache.mkdir(parents=True, exist_ok=True)
    for name, (url, digest) in ASSETS.items():
        archive = cache / name
        if not archive.exists():
            print(f'Downloading {name}', flush=True)
            partial = archive.with_suffix('.part')
            urllib.request.urlretrieve(url, partial)
            partial.rename(archive)
        if hashlib.file_digest(archive.open('rb'), 'sha256').hexdigest() != digest:
            raise SystemExit(f'Checksum mismatch: {archive}')
    with tempfile.TemporaryDirectory(dir=destination.parent) as scratch:
        root = Path(scratch)
        with zipfile.ZipFile(cache / 'Aras_1.0.5_Linux_OpenVino.zip') as z:
            z.extractall(root)
            for entry in z.infolist():
                if stat.S_ISLNK(entry.external_attr >> 16):
                    target = root / entry.filename
                    target.unlink()
                    target.symlink_to(z.read(entry).decode())
        engine = root / 'Aras_1.0.5_Linux_OpenVino'
        model = engine / 'model/CrazyAra/crazyhouse'
        model.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(cache / 'CrazyAra-rl-model-os-96.zip') as z:
            for name in z.namelist():
                if name.endswith('bsize-1.onnx') or name.endswith('.txt'):
                    (model / Path(name).name).write_bytes(z.read(name))
        with tarfile.open(cache / 'tbb-2020.3-lin.tgz') as t:
            member = next(m for m in t.getmembers() if m.name.endswith('/lib/intel64/gcc4.8/libtbb.so.2'))
            (engine / 'libtbb.so.2').write_bytes(t.extractfile(member).read())
        (engine / 'CrazyAra').chmod(0o755)
        launcher = root / 'crazyara'
        launcher.write_text('''#!/usr/bin/env bash
set -euo pipefail
CRAZYARA_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$CRAZYARA_ROOT/Aras_1.0.5_Linux_OpenVino"
export LD_LIBRARY_PATH="$PWD${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export OMP_NUM_THREADS=2
exec ./CrazyAra "$@"
''')
        launcher.chmod(0o755)
        # Move the complete installation into place; never expose partial files.
        stage = root / 'installation'
        stage.mkdir()
        shutil.move(str(engine), stage)
        shutil.move(str(launcher), stage)
        stage.rename(destination)
    print(f'Installed {destination / "crazyara"}', flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    data = Path(os.environ.get('XDG_DATA_HOME', Path.home() / '.local/share'))
    parser.add_argument('--destination', type=Path, default=data / 'chess-prep/crazyara')
    parser.add_argument('--cache', type=Path, default=data / 'chess-prep/downloads/crazyara')
    args = parser.parse_args()
    if platform.system() != 'Linux' or platform.machine() not in ('x86_64', 'AMD64'):
        raise SystemExit('This installer supports Linux x86-64. Set CRAZYARA_BIN to a compatible runtime on other platforms.')
    install(args.destination, args.cache)
