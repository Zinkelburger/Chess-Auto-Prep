#!/usr/bin/env python3
"""Exercise the packaged v2 executable, using only its disposable self-test profile."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def main():
    # Windows redirected stdout otherwise defaults to the legacy code page.
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('executable', type=Path)
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    executable = args.executable.resolve(strict=True)
    with tempfile.TemporaryDirectory(prefix='desktop-check-report-') as scratch:
        temporary = Path(scratch) / 'report.json'
        # A sandboxed Mac may not write a caller-chosen temporary directory.
        # Its stdout report is copied by this external harness instead.
        flag = f'--self-test-desktop={temporary}' if os.name == 'nt' else '--self-test-desktop'
        result = subprocess.run([str(executable), flag], cwd=executable.parent,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                text=True, encoding='utf-8', errors='replace', timeout=180)
        print(result.stdout)
        if temporary.exists():
            report = json.loads(temporary.read_text(encoding='utf-8'))
        else:
            lines = [line.split('CAP_DESKTOP_REPORT=', 1)[1]
                     for line in result.stdout.splitlines() if 'CAP_DESKTOP_REPORT=' in line]
            if not lines:
                raise RuntimeError(f'No desktop report (exit {result.returncode})')
            report = json.loads(lines[-1])
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, indent=2), encoding='utf-8')
        if result.returncode or report.get('ok') is not True:
            raise RuntimeError(f'Desktop check failed: {report}')
        print('Documents, Stockfish, Maia and login sockets passed in the packaged app.')


if __name__ == '__main__':
    main()
