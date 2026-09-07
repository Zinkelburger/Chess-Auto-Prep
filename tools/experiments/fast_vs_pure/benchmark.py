#!/usr/bin/env python3
"""Paired production-builder benchmark; invoke via run_overnight.sh.

Fresh Flutter/Stockfish process and app profile per run. Maia-only opponent policy.
Wall times exclude startup; independent engine hash histories mean value deltas
are descriptive, never a proof of algorithmic regret or playing strength.
"""
import argparse
import hashlib
import json
import os
import platform
from pathlib import Path
import subprocess
import time

CASES = [
    ('winawer-root', '', 'e4 e6 d4 d5 Nc3 Bb4', 1),
    ('pawn-control', '8/8/8/8/8/4k3/P7/4K3 w - - 0 1', '', 4),
    ('pawn-six', '8/8/8/8/8/4k3/P7/4K3 w - - 0 1', '', 6),
    ('italian-six', '', 'e4 e5 Nf3 Nc6 Bc4 Bc5', 6),
    ('qgd-six', '', 'd4 d5 c4 e6 Nc3 Nf6', 6),
]


def report(out, results):
    rows = [
        '# Fast compared with Pure', '',
        'Fresh-process pairs (worker counts recorded in stats.json). Same fixed engine depth, horizon, '
        '40 cp candidate-loss limit, Maia 2200 throughout. '
        'Startup excluded. Alternating run order. Incomplete pairs have no speedup or quality claim.', '',
        '| Position | Pure s | Fast s | Pure / Fast complete | Pure / Fast nodes | Speedup¹ | Root moves (Pure / Fast) |',
        '|---|---:|---:|---|---|---:|---|',
    ]
    for name, pair in results.items():
        if not all(a in pair for a in ('pure', 'fast')):
            continue
        pure, fast = pair['pure'], pair['fast']
        complete = pure['complete'] and fast['complete']
        speed = f"{pure['build_ms'] / max(1, fast['build_ms']):.2f}×" if complete else '—'
        rows.append(f"| {name} | {pure['build_ms']/1000:.2f} | {fast['build_ms']/1000:.2f} | "
                    f"{pure['complete']} / {fast['complete']} | {pure['nodes']} / {fast['nodes']} | "
                    f"{speed} | {pure['root_move'] or 'unresolved'} / {fast['root_move'] or 'unresolved'} |")
    rows += ['', '¹ One observation per case, not a statistical speed claim. '
             'The four-ply case is a control: Fast has no shorter lookahead than Pure there. '
             'A committed move in an incomplete Fast tree is not a completed policy.', '',
             'Root agreement is descriptive. Each engine process reuses its own hash during search; '
             'different traversal orders can produce different fixed-depth evaluations and candidate sets. '
             'Do not subtract root values and call the difference regret. These runs do not measure chess playing strength.', '',
             'Full configs, bounds, engine calls, and history-keyed choices are in each stats.json. '
             'Each tree.json preserves the search for inspection. results.json collects raw measurements.', '']
    (out / 'comparison.md').write_text('\n'.join(rows))
    (out / 'results.json').write_text(json.dumps(results, indent=2) + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', nargs='?', default=f'/tmp/fast-pure-{time.strftime("%Y%m%d-%H%M%S")}')
    parser.add_argument('--seconds', type=int, default=90, help='Cooperative cap per build; atomic expansions can overrun it')
    parser.add_argument('--depth', type=int, default=8)
    parser.add_argument('--workers', type=int, default=1)
    parser.add_argument('--case', choices=[c[0] for c in CASES], action='append')
    parser.add_argument('--onnx-lib', default=os.environ.get('ONNX_LIB', 'build/linux/x64/debug/bundle/lib'))
    args = parser.parse_args()
    if args.seconds < 1 or args.depth < 1 or args.workers < 1:
        parser.error('seconds, depth and workers must be positive')
    out = Path(args.output).resolve()
    if out.exists() and any(out.iterdir()):
        parser.error('Output must be a new or empty directory; existing measurements are immutable')
    out.mkdir(parents=True, exist_ok=True)
    (out / 'settings.json').write_text(json.dumps(vars(args), indent=2) + '\n')
    env = dict(os.environ)
    env['LD_LIBRARY_PATH'] = str(Path(args.onnx_lib).resolve()) + ':' + env.get('LD_LIBRARY_PATH', '')
    flutter = os.environ.get('FLUTTER', str(Path.home() / 'sdk/flutter/bin/flutter'))
    binaries = {
        'stockfish': Path.home() / '.local/share/com.example.chess_auto_prep/stockfish-linux',
        'maia': Path('assets/maia3_simplified.onnx'),
    }
    identity = {'platform': platform.platform(), 'engines': {}}
    for name, binary in binaries.items():
        with binary.open('rb') as source:
            digest = hashlib.file_digest(source, 'sha256').hexdigest()
        identity['engines'][name] = {'sha256': digest, 'bytes': binary.stat().st_size}
    (out / 'engine-identity.json').write_text(json.dumps(identity, indent=2) + '\n')
    results = {}
    for index, (name, fen, moves, plies) in enumerate(CASES):
        if args.case and name not in args.case:
            continue
        results[name] = {}
        for algorithm in (('pure', 'fast') if index % 2 == 0 else ('fast', 'pure')):
            run = out / name / algorithm
            if run.exists():
                raise SystemExit(f'Refusing to reuse a cold-run directory: {run}')
            run.mkdir(parents=True)
            definitions = dict(ALGO=algorithm, OUT=str(run), MAX_PLY=plies,
                               EVAL_DEPTH=args.depth, BUDGET_SECONDS=args.seconds, WORKERS=args.workers,
                               START_MOVES=moves)
            if fen:
                definitions['FEN'] = fen
            argv = [flutter, 'test', 'test/benchmark/fast_vs_pure_benchmark.dart', '--reporter=expanded',
                    *[f'--dart-define={key}={value}' for key, value in definitions.items()]]
            print(f'{name} {algorithm}: starting', flush=True)
            with (run / 'test.log').open('w') as log:
                subprocess.run(argv, env=env, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=args.seconds + 180)
            stats = json.loads((run / 'stats.json').read_text())
            results[name][algorithm] = stats
            print(f"  {stats['build_ms']/1000:.2f}s, {stats['nodes']} nodes, complete={stats['complete']}, move={stats['root_move']}", flush=True)
            report(out, results)
    print(out / 'comparison.md', flush=True)


if __name__ == '__main__':
    main()
