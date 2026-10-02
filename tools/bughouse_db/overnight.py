#!/usr/bin/env python3
"""Manually start/resume an overnight bughouse book build and publish its tables.

python3 tools/bughouse_db/overnight.py start --hours 8 --cores 8
python3 tools/bughouse_db/overnight.py status
python3 tools/bughouse_db/overnight.py stop
There is no timer: start it again whenever you want another run.
"""
import argparse
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools'))
from bughouse_db import expectimax

UNIT = 'bughouse-populate'
SUPPORT_ROOT = Path.home() / '.local/share/chess-prep'
REMOTE = '/opt/twic/repo/python/twic-position-finder'


def parser():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('command', choices=['start', 'run', 'status', 'stop'])
    p.add_argument('--hours', type=float, default=8)
    p.add_argument('--cores', type=int, default=8, help='Total CPU allowance across workers')
    p.add_argument('--workers', type=int, default=2)
    p.add_argument('--positions', type=int, default=10000, help='Popular FICS positions to enqueue (resumable)')
    p.add_argument('--nodes', type=int, default=800)
    p.add_argument('--plies', type=int, default=2)
    p.add_argument('--db', type=Path, default=SUPPORT_ROOT / 'bughouse-db/bughouse_expectimax.db')
    p.add_argument('--fics', type=Path, default=SUPPORT_ROOT / 'bughouse-db/bughouse_book.db')
    p.add_argument('--support', type=Path, default=SUPPORT_ROOT)
    p.add_argument('--dart', default=shutil.which('dart') or 'dart')
    p.add_argument('--worker-bin', type=Path)
    p.add_argument('--publish-to', default='twic-vps')
    p.add_argument('--publish-path', default=REMOTE + '/bughouse_expectimax.db')
    p.add_argument('--web-db', default=REMOTE + '/bughousedb.db')
    p.add_argument('--local-only', action='store_true', help='Do not read or publish the website database')
    return p


def shared_positions(args):
    """Prioritize positions visitors analysed, without downloading other user data."""
    script = '''import json,sqlite3,sys
from pathlib import Path
db=sqlite3.connect(Path(sys.argv[1]).as_uri()+'?mode=ro',uri=True)
exists=db.execute("SELECT 1 FROM sqlite_master WHERE name='lab_evaluation'").fetchone()
print(json.dumps([r[0] for r in db.execute('SELECT DISTINCT fen FROM lab_evaluation LIMIT 10000')] if exists else []))
'''
    output = subprocess.check_output(['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10',
        args.publish_to, shlex.join(['python3', '-c', script, args.web_db])], text=True, timeout=30)
    rows = json.loads(output)
    with expectimax.connect(args.db) as db:
        for fen in rows:
            dual = expectimax.DualBoard.from_dual_fen(fen)
            for board in 'AB':
                db.execute('INSERT INTO job(pos,board,fen,priority) VALUES(?,?,?,-1) '
                           'ON CONFLICT(pos,board) DO UPDATE SET priority=-1',
                           (expectimax.key_of(dual), board, dual.dual_fen))
    print(f'Queued {len(rows)} shared positions ahead of the opening sample.', flush=True)


def run(args):
    if not args.fics.is_file():
        raise SystemExit(f'FICS book is missing: {args.fics}')
    if args.worker_bin and not args.worker_bin.is_file():
        raise SystemExit(f'Worker executable is missing: {args.worker_bin}')
    args.retry_failed = True
    args.max_ply = 16
    expectimax.seed(args)
    if args.local_only:
        args.publish_to = None
    else:
        try:
            shared_positions(args)
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            print(f'Could not fetch shared positions; continuing the saved queue: {error}', file=sys.stderr)
    args.cores //= args.workers
    expectimax.run(args)


def main(argv=None):
    p = parser()
    args = p.parse_args(argv)
    if args.command == 'status':
        subprocess.run(['systemctl', '--user', 'show', UNIT + '.service',
                        '--property=ActiveState,SubState,Result,CPUUsageNSec,MemoryCurrent'])
        if args.db.exists():
            expectimax.stats(args)
        print(f'Logs: journalctl --user -u {UNIT} -n 30 --no-pager')
        return
    if args.command == 'stop':
        subprocess.run(['systemctl', '--user', 'stop', UNIT + '.service'], check=True)
        print('Stopped. Completed tables and per-position evaluations are kept for the next run.')
        return
    available = len(os.sched_getaffinity(0)) if hasattr(os, 'sched_getaffinity') else os.cpu_count() or 1
    if not (0 < args.hours <= 72 and 1 <= args.workers <= args.cores <= available
            and args.cores % args.workers == 0 and args.positions > 0
            and 100 <= args.nodes <= 100000 and 1 <= args.plies <= 4):
        p.error('Use 0–72 hours, available cores divisible by workers, positive positions, 100–100000 nodes, 1–4 plies.')
    if args.command == 'run':
        return run(args)
    if subprocess.run(['systemctl', '--user', 'is-active', '--quiet', UNIT + '.service']).returncode == 0:
        raise SystemExit('A population run is already active. Use status or stop.')
    forwarded = list(sys.argv[2:] if argv is None else argv[1:])
    command = [sys.executable, str(Path(__file__).resolve()), 'run', *forwarded]
    subprocess.run(['systemd-run', '--user', '--collect', '--unit=' + UNIT,
                    '--working-directory=' + str(ROOT), '--property=CPUQuota=' + str(args.cores * 100) + '%',
                    '--property=MemoryMax=6G', '--property=MemorySwapMax=1G',
                    '--property=KillMode=mixed', '--property=TimeoutStopSec=180',
                    '--property=RuntimeMaxSec=' + str(int(args.hours * 3600 + 600)),
                    '--setenv=PATH=' + os.environ.get('PATH', ''), *command], check=True)
    print(f'Started: {args.nodes} nodes, {args.plies} plies, {args.cores} cores, {args.hours:g} hours. No timer installed.')
    print('Use this command with status or stop; completed tables sync to the website every five minutes.'
          if not args.local_only else 'Local-only run: no website reads or writes.')


if __name__ == '__main__':
    main()
