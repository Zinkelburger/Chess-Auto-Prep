#!/usr/bin/env python3
"""Embed the pinned Stockfish as a signed helper inside the macOS app bundle.

Xcode calls this after Flutter embeds its frameworks, before signing the app.
Sandboxed apps cannot execute the upstream engine with its original signature;
helpers must explicitly inherit the app's sandbox. Never re-sign at runtime.
"""
import gzip
import hashlib
import json
import os
import platform
from pathlib import Path
import subprocess


def main():
    root = Path(__file__).resolve().parent.parent
    asset = root / 'assets/executables/stockfish-macos.gz'
    compressed = asset.read_bytes()
    lock = json.loads((root / 'tools/assets.lock.json').read_text())
    digest = hashlib.sha256(compressed).hexdigest()
    # The fetcher refreshes only this host's entry. Although both entries
    # describe the same universal binary, zlib versions can change the gzip
    # container's hash, leaving the other architecture's entry unchanged.
    arch = 'arm64' if platform.machine().lower() in ('arm64', 'aarch64') else 'x86_64'
    if digest != lock[f'stockfish-macos-{arch}']['output_sha256']:
        raise RuntimeError('The macOS Stockfish does not match assets.lock.json')
    contents = Path(os.environ['TARGET_BUILD_DIR']) / os.environ['CONTENTS_FOLDER_PATH']
    helper = contents / 'Helpers/stockfish-macos'
    helper.parent.mkdir(parents=True, exist_ok=True)
    helper.write_bytes(gzip.decompress(compressed))
    helper.chmod(0o755)
    identity = os.environ.get('EXPANDED_CODE_SIGN_IDENTITY') or '-'
    subprocess.run([
        '/usr/bin/codesign', '--force', '--sign', identity,
        '--entitlements', str(root / 'macos/Runner/Engine.entitlements'),
        str(helper),
    ], check=True)
    subprocess.run(['/usr/bin/codesign', '--verify', '--strict', str(helper)], check=True)


if __name__ == '__main__':
    main()
