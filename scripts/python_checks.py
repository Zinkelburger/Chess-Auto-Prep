#!/usr/bin/env python3
"""Run ruff and pyright over tools/, scripts/ and python/twic-position-finder.

The tools live in a private virtual environment under the job cache, one per
version of tools/requirements-lint.txt, built on first use. Configuration is
in pyproject.toml. Run through `scripts/ci.sh lint`.
"""
from __future__ import annotations

import fcntl
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
REQUIREMENTS = ROOT / 'tools/requirements-lint.txt'
TARGETS = ('tools', 'scripts', 'python/twic-position-finder')


def environment() -> Path:
    """The virtual environment for the current pins, created if missing."""
    cache = Path(os.environ.get('CHESS_PREP_JOB_CACHE')
                 or Path.home() / '.cache/chess-prep-jobs')
    digest = hashlib.sha256(REQUIREMENTS.read_bytes()).hexdigest()[:12]
    target = cache / f'python-lint-{digest}'
    ready = target / '.ready'
    if ready.exists():
        return target
    cache.mkdir(parents=True, exist_ok=True)
    with open(cache / 'python-lint.lock', 'w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if ready.exists():
            return target
        shutil.rmtree(target, ignore_errors=True)
        subprocess.run([sys.executable, '-m', 'venv', str(target)], check=True)
        subprocess.run([str(target / 'bin/pip'), 'install', '--quiet',
                        '--disable-pip-version-check', '-r', str(REQUIREMENTS)],
                       check=True)
        ready.touch()
    return target


def main() -> int:
    try:
        venv = environment()
    except (OSError, subprocess.CalledProcessError) as e:
        print(f'python_checks: could not install the lint tools: {e}', file=sys.stderr)
        return 1
    python = str(venv / 'bin/python')
    print('── ruff', flush=True)
    ruff = subprocess.run([python, '-m', 'ruff', 'check', *TARGETS], cwd=ROOT).returncode
    print('── pyright', flush=True)
    env = {**os.environ, 'PYRIGHT_PYTHON_IGNORE_WARNINGS': '1'}
    pyright = subprocess.run([python, '-m', 'pyright', '--pythonpath', python],
                             cwd=ROOT, env=env).returncode
    return 1 if ruff or pyright else 0


if __name__ == '__main__':
    sys.exit(main())
