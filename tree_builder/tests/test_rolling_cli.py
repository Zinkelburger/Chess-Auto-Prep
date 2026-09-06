#!/usr/bin/env python3
"""Run the real CLI: the local search must not lose --search while configuring."""
import json
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
for method in ('fast', 'rolling'):
    with tempfile.TemporaryDirectory(prefix='rolling-cli-') as temp:
        base = Path(temp) / 'tree'
        command = [str(root / 'bin/tree_builder'), '--search', method,
                   '-S', str(root / 'tests/fake_uci.py'), '-d', '1', '-e', '2',
                   '-t', '1', '-c', 'w', '--max-eval-loss', '20000', str(base)]
        run = subprocess.run(command, cwd=root, capture_output=True, text=True, timeout=30)
        assert run.returncode == 0, run.stdout + run.stderr
        data = json.loads(Path(str(base) + '.tree.json').read_text())
        assert data['config']['search_algorithm'] == 'rolling'
        assert data['build_complete'] and data['tree']['decision_horizon'] == 1
        assert data['tree']['committed_move_uci'] == 'a2a3'
        pgn = Path(str(base) + '.pgn').read_text()
        assert '[Search "Fast (4-ply, approximate)"]' in pgn
        # Export must preserve the saved method when no mode flag is supplied.
        again = [command[0], *command[3:-1], '--build-now', str(base)]
        run = subprocess.run(again, cwd=root, capture_output=True, text=True, timeout=30)
        assert run.returncode == 0, run.stdout + run.stderr
        assert json.loads(Path(str(base) + '.tree.json').read_text())['config']['search_algorithm'] == 'rolling'
        print('Fast CLI: public name and rolling alias, saved mode, PGN labels and export passed.')
