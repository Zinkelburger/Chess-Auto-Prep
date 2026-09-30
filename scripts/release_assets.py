#!/usr/bin/env python3
"""Stage only a complete, validated set of public release downloads."""
import argparse
import hashlib
from pathlib import Path
import re
import shutil


def expected_assets(tag):
    if not re.fullmatch(r'v\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?', tag):
        raise ValueError(f'Invalid release tag: {tag}')
    prefix = f'chess-auto-prep-{tag}-'
    return {
        'linux-build': [prefix + suffix for suffix in (
            'linux.zip', 'linux.flatpak', 'linux-amd64.deb', 'linux-x86_64.rpm')],
        'windows-build': [prefix + suffix for suffix in ('windows.zip', 'windows-setup.exe')],
        'macos-arm64-build': [prefix + 'macos-arm64.zip'],
        'macos-x86_64-build': [prefix + 'macos-x86_64.zip'],
    }


def stage(tag, source, destination):
    expected = expected_assets(tag)
    if set(p.name for p in source.iterdir()) != set(expected):
        raise ValueError('Expected exactly the four platform build artifact directories')
    files = []
    for artifact, names in expected.items():
        directory = source / artifact
        if directory.is_symlink() or not directory.is_dir():
            raise ValueError(f'Not an artifact directory: {directory}')
        if set(p.name for p in directory.iterdir()) != set(names):
            raise ValueError(f'{artifact}: expected exactly {names}')
        for name in names:
            path = directory / name
            if path.is_symlink() or not path.is_file() or path.stat().st_size == 0:
                raise ValueError(f'Missing, empty or unsafe release download: {path}')
            files.append(path)
    # A fresh staging directory prevents stale/unrelated files reaching the glob.
    destination.mkdir(parents=True, exist_ok=False)
    checksums = []
    for path in sorted(files):
        target = destination / path.name
        shutil.copyfile(path, target)
        digest = hashlib.sha256()
        with target.open('rb') as data:
            for block in iter(lambda: data.read(1024 * 1024), b''):
                digest.update(block)
        checksums.append(f'{digest.hexdigest()}  {target.name}\n')
    (destination / 'SHA256SUMS').write_text(''.join(checksums))
    print(f'Verified {len(files)} downloads; staged downloads and SHA256SUMS in {destination}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('tag')
    parser.add_argument('source', type=Path)
    parser.add_argument('destination', type=Path)
    args = parser.parse_args()
    try:
        stage(args.tag, args.source, args.destination)
    except (OSError, ValueError) as error:
        parser.exit(1, f'Release assets: {error}\n')
