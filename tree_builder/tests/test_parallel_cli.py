#!/usr/bin/env python3
"""One versus ten workers: whole-tree equality, overlap, interrupt/resume, errors."""
import json
import os
from pathlib import Path
import signal
import sqlite3
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
FEN = '8/8/8/8/8/4k3/P7/4K3 w - - 0 1'

def command(base, method, workers):
    return [str(ROOT / 'bin/tree_builder'), '--search', method, '--maia-only',
            '-S', str(ROOT / 'tests/parallel_uci.py'), '-d', '4', '-e', '2',
            '-t', str(workers), '-c', 'w', '-f', FEN, '--max-eval-loss', '40', str(base)]

def events(path):
    if not path.exists():
        return []
    return [json.loads(line) for line in path.read_text().splitlines(keepends=True) if line.endswith('\n')]

def concurrency(rows, turn=None):
    active = peak = 0
    for row in sorted(rows, key=lambda row: row['t']):
        if turn and row['fen'].split()[1] != turn:
            continue
        assert row['threads'] == 1, 'Pure must not change UCI Threads with batch size'
        active += 1 if row['kind'] == 'start' else -1
        peak = max(peak, active)
    assert active == 0
    return peak

def semantic(node):
    # IDs and interruption-era progress counters are not search semantics.
    keys = ('fen', 'move_uci', 'move_probability', 'engine_eval_cp', 'expectimax_value',
            'value_lower', 'value_upper', 'committed_move_uci', 'decision_value',
            'decision_horizon', 'terminal_value')
    return {**{key: node.get(key) for key in keys},
            'children': [semantic(child) for child in node.get('children', [])]}

def tree(base):
    return json.loads(Path(str(base) + '.tree.json').read_text())

with tempfile.TemporaryDirectory(prefix='parallel-cli-') as temp:
    directory = Path(temp)
    for method in ('pure', 'fast'):
        reference = None
        for workers in (1, 10):
            base = directory / f'{method}-{workers}'
            trace = base.with_suffix('.events')
            env = dict(os.environ, PARALLEL_UCI_LOG=str(trace))
            result = subprocess.run(command(base, method, workers), cwd=ROOT, env=env,
                                    capture_output=True, text=True, timeout=120)
            assert result.returncode == 0, result.stdout + result.stderr
            data = tree(base)
            assert data['build_complete']
            rows = events(trace)
            peak = concurrency(rows)
            assert peak == workers, peak
            assert concurrency(rows, 'w') > (0 if workers == 1 else 1), 'leaves stayed serial'
            if reference is None:
                reference = semantic(data['tree'])
            else:
                assert semantic(data['tree']) == reference
            elapsed = rows[-1]['t'] - rows[0]['t']
            print(f'{method}: {workers} workers, peak {peak}, {len(rows)//2} evals, {elapsed:.3f}s search span', flush=True)

        # Interrupt while engines have work; no half-distribution or early Fast commitment.
        base = directory / f'{method}-resume'
        trace = base.with_suffix('.events')
        env = dict(os.environ, PARALLEL_UCI_LOG=str(trace), PARALLEL_UCI_DELAY='.03')
        with base.with_suffix('.log').open('w') as log:
            process = subprocess.Popen(command(base, method, 10), cwd=ROOT, env=env,
                                       stdout=log, stderr=log, start_new_session=True)
            try:
                deadline = time.monotonic() + 30
                while len(events(trace)) < 20 and process.poll() is None and time.monotonic() < deadline:
                    time.sleep(.01)
                assert process.poll() is None, 'run finished before interruption'
                process.send_signal(signal.SIGINT)
                process.wait(timeout=30)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()
        assert not tree(base)['build_complete']
        result = subprocess.run(command(base, method, 10), cwd=ROOT,
                                capture_output=True, text=True, timeout=120)
        assert result.returncode == 0, result.stdout + result.stderr
        assert tree(base)['build_complete']
        assert semantic(tree(base)['tree']) == reference
        print(f'{method}: interrupted batch resumes to the same complete tree', flush=True)

        base = directory / f'{method}-failure'
        result = subprocess.run(command(base, method, 10), cwd=ROOT,
                                env=dict(os.environ, PARALLEL_UCI_FAIL='1'),
                                capture_output=True, text=True, timeout=30)
        assert result.returncode != 0, 'insufficient-depth evaluation was accepted'
        assert not Path(str(base) + '.tree.json').exists()
        print(f'{method}: failed evaluation rejected before publishing an action set', flush=True)

    # Upgrading a cache must invalidate only the old Maia rows, once.
    base = directory / 'cache-upgrade'
    cmd = command(base, 'pure', 1)
    cmd[cmd.index('-d') + 1] = '1'
    subprocess.run(cmd, cwd=ROOT, capture_output=True, check=True, timeout=30)
    with sqlite3.connect(str(base) + '.db') as db:
        db.execute("DELETE FROM build_metadata WHERE key='maia_policy_version'")
        db.execute("INSERT INTO maia_cache VALUES ('old',2200,1,?,1)", (b'old',))
        db.execute("INSERT INTO evaluations(fen,eval_cp,depth) VALUES ('preserve-engine',37,16)")
    subprocess.run(cmd, cwd=ROOT, capture_output=True, check=True, timeout=30)
    with sqlite3.connect(str(base) + '.db') as db:
        assert db.execute('SELECT count(*) FROM maia_cache').fetchone()[0] == 0
        assert db.execute("SELECT eval_cp FROM evaluations WHERE fen='preserve-engine'").fetchone()[0] == 37
        db.execute("INSERT INTO maia_cache VALUES ('new',2200,1,?,1)", (b'new',))
    subprocess.run(cmd, cwd=ROOT, capture_output=True, check=True, timeout=30)
    with sqlite3.connect(str(base) + '.db') as db:
        assert db.execute('SELECT count(*) FROM maia_cache').fetchone()[0] == 1
    print('Maia cache migration preserves engine evaluations and new policies', flush=True)
