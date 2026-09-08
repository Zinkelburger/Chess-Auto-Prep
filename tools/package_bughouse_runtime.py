#!/usr/bin/env python3
"""Package the built Windows VC++ DLLs for verified, offline engine repair."""
from __future__ import annotations

import argparse
import gzip
import hashlib
import json
import struct
from pathlib import Path

REQUIRED = {'msvcp140.dll', 'msvcp140_1.dll', 'vcruntime140.dll', 'vcruntime140_1.dll'}


def is_runtime(name: str) -> bool:
    name = name.lower()
    return name.endswith('.dll') and name.startswith(('msvcp140', 'vcruntime140', 'concrt140'))


def validate_image(data: bytes, name: str) -> None:
    if len(data) < 64 or data[:2] != b'MZ':
        raise ValueError(f'{name}: missing DOS header')
    offset = struct.unpack_from('<I', data, 60)[0]
    if offset + 26 > len(data) or data[offset:offset + 4] != b'PE\0\0':
        raise ValueError(f'{name}: invalid PE header')
    machine = struct.unpack_from('<H', data, offset + 4)[0]
    magic = struct.unpack_from('<H', data, offset + 24)[0]
    if machine != 0x8664 or magic != 0x20b:
        raise ValueError(f'{name}: expected x64 PE32+, got machine 0x{machine:04x}, magic 0x{magic:04x}')


def package(bundle: Path, check: bool = False) -> None:
    destination = bundle / 'data' / 'bughouse-runtime'
    if check:
        manifest = json.loads((destination / 'manifest.json').read_text())
        if not REQUIRED <= manifest.keys():
            raise ValueError('private runtime manifest is missing required DLLs')
        for name, expected in manifest.items():
            if not is_runtime(name) or Path(name).name != name or '/' in name or '\\' in name:
                raise ValueError(f'invalid runtime name: {name}')
            data = gzip.decompress((destination / f'{name}.gz').read_bytes())
            validate_image(data, name)
            if len(data) != expected['bytes'] or hashlib.sha256(data).hexdigest() != expected['sha256']:
                raise ValueError(f'{name}: private runtime hash/size mismatch')
        return
    sources = {path.name.lower(): path for path in bundle.iterdir() if path.is_file() and is_runtime(path.name)}
    if missing := REQUIRED - sources.keys():
        raise ValueError(f'built Windows bundle is missing: {", ".join(sorted(missing))}')
    # Validate all sources before producing an archive or replacing its manifest.
    payloads = {name: path.read_bytes() for name, path in sources.items()}
    for name, data in payloads.items():
        validate_image(data, name)
    destination.mkdir(parents=True, exist_ok=True)
    manifest = {}
    for name, data in sorted(payloads.items()):
        packed = destination / f'{name}.gz'
        temporary = packed.with_suffix('.partial')
        temporary.write_bytes(gzip.compress(data, mtime=0))
        temporary.replace(packed)
        manifest[name] = {'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()}
    path = destination / 'manifest.json'
    temporary = path.with_suffix('.partial')
    temporary.write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
    temporary.replace(path)
    package(bundle, check=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bundle', type=Path, required=True)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    package(args.bundle, args.check)
    print('Private bughouse VC++ runtime verified')


if __name__ == '__main__':
    main()
