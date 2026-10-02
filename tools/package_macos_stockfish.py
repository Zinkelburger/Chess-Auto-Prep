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
    engine = gzip.decompress(asset.read_bytes())
    lock = json.loads((root / 'tools/assets.lock.json').read_text())
    # The engine is checked, not its gzip container, whose bytes depend on the
    # zlib of whichever machine packed it. Both macOS entries pin the same
    # universal binary; the check follows the architectures Xcode builds
    # (ARCHS), not the machine it runs on: an Apple Silicon runner builds the
    # Intel app too.
    host = 'arm64' if platform.machine().lower() in ('arm64', 'aarch64') else 'x86_64'
    archs = os.environ.get('ARCHS', '').split() or [host]
    expected = {lock[f'stockfish-macos-{arch}']['payload_sha256']
                for arch in archs if f'stockfish-macos-{arch}' in lock}
    if hashlib.sha256(engine).hexdigest() not in expected:
        raise RuntimeError(
            f'The macOS Stockfish does not match assets.lock.json for {" ".join(archs)}')
    contents = Path(os.environ['TARGET_BUILD_DIR']) / os.environ['CONTENTS_FOLDER_PATH']
    helper = contents / 'Helpers/stockfish-macos'
    helper.parent.mkdir(parents=True, exist_ok=True)
    helper.write_bytes(engine)
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
