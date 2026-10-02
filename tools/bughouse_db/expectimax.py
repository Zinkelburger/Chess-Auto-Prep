"""Seed and run the shared desktop/web expectimax database, with checkpoints.

seed walks popular FICS edges from the initial table, preserving BOTH boards.
run starts independent Dart workers over one atomic SQLite queue.
"""
import argparse
import json
import os
from pathlib import Path
import signal
import shlex
import tempfile
import sqlite3
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT / 'tools/mcp'), str(ROOT / 'tools')]
from bughouse.board import DualBoard
from bughouse_db.hivemind_book import key_of

MODEL = 'crazyara-os96-t1.5-hivemind-search-v2'

SCHEMA = '''CREATE TABLE IF NOT EXISTS job(
 id INTEGER PRIMARY KEY, pos INTEGER NOT NULL, board TEXT NOT NULL,
 fen TEXT NOT NULL, priority REAL NOT NULL, status TEXT NOT NULL DEFAULT 'queued',
 worker TEXT, started INTEGER, error TEXT, UNIQUE(pos,board));'''


def connect(path):
    path.parent.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(path, timeout=30)
    db.execute('PRAGMA journal_mode=WAL')
    db.executescript(SCHEMA)
    return db


def seed(args):
    if args.positions < 1 or args.max_ply < 0:
        raise ValueError('Use a positive position count and nonnegative depth')
    db = connect(args.db)
    fics = sqlite3.connect(args.fics.resolve().as_uri() + '?mode=ro', uri=True)
    # Best-first by empirical reach probability; each position enters once.
    import heapq
    todo = [(0.0, 0, '', 0)]
    seen = set()
    sequence = 0
    while todo and len(seen) < args.positions:
        cost, _, line, ply = heapq.heappop(todo)
        dual = DualBoard()
        for token in line.split():
            board, san = token.split(':', 1)
            dual.push(board, san)
        key = key_of(dual)
        if key in seen:
            continue
        seen.add(key)
        for board in 'AB':
            db.execute('INSERT OR IGNORE INTO job(pos,board,fen,priority) VALUES(?,?,?,?)',
                       (key, board, dual.dual_fen, cost))
        if ply >= args.max_ply:
            continue
        edges = fics.execute('SELECT move,games FROM edge WHERE pos=? ORDER BY games DESC LIMIT 8', (key,)).fetchall()
        total = fics.execute('SELECT coalesce(sum(games),0) FROM edge WHERE pos=?', (key,)).fetchone()[0]
        if not total:
            continue
        for move, games in edges:
            if games / total <= .01:
                continue
            sequence += 1
            import math
            heapq.heappush(todo, (cost - math.log(games / total), sequence,
                                (line + ' ' + move).strip(), ply + 1))
    db.commit()
    print(json.dumps({'positions': len(seen), 'jobs': db.execute('SELECT count(*) FROM job').fetchone()[0]}))
    db.close(); fics.close()


def run(args):
    db = connect(args.db)
    # Only one coordinator owns restart/requeue; a file lock prevents duplicates.
    import fcntl
    lock = open(str(args.db) + '.builder.lock', 'w')
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    db.execute("UPDATE job SET status='queued',worker=NULL WHERE status='running'")
    if db.execute("SELECT 1 FROM sqlite_master WHERE name='analysis'").fetchone():
        db.execute('''UPDATE job SET status='queued',error=NULL WHERE status IN ('done','failed')
            AND NOT EXISTS (SELECT 1 FROM analysis a WHERE a.pos=job.pos AND a.board=job.board
            AND a.profile LIKE ? AND a.plies>=? AND a.nodes>=?)''',
            (MODEL + ':%', args.plies, args.nodes))
    db.commit(); db.close()
    executable = [str(args.worker_bin.resolve())] if args.worker_bin else [args.dart, 'run', 'tools/build_bughouse_expectimax.dart']
    command = executable + ['--db', str(args.db.resolve()),
               '--nodes', str(args.nodes), '--plies', str(args.plies), '--cores', str(args.cores),
               '--support', str(args.support)]
    cpus = sorted(os.sched_getaffinity(0)) if hasattr(os, 'sched_getaffinity') else []
    processes = []
    for i in range(args.workers):
        selected = cpus[i * args.cores:(i + 1) * args.cores]
        launch = (['taskset', '-c', ','.join(map(str, selected))] if selected else [])
        processes.append(subprocess.Popen(launch + command + ['--worker', str(i + 1)], cwd=ROOT))
    stopping = False
    def stop(sig, frame):
        nonlocal stopping
        stopping = True
        for proc in processes:
            if proc.poll() is None:
                proc.send_signal(sig)
    signal.signal(signal.SIGTERM, stop); signal.signal(signal.SIGINT, stop)
    deadline = time.monotonic() + args.hours * 3600
    next_publish = 0
    while any(p.poll() is None for p in processes):
        if args.publish_to and time.monotonic() >= next_publish:
            publish(args)
            next_publish = time.monotonic() + 300
        if time.monotonic() >= deadline and not stopping:
            stop(signal.SIGTERM, None)
        time.sleep(5)
    if args.publish_to:
        publish(args)
    raise SystemExit(max(abs(p.returncode) for p in processes))


def publish(args):
    """Send only completed analysis rows; keep engine checkpoints on this machine.

    SSH credentials stay in the user's SSH configuration. The remote merge is one
    SQLite transaction and preserves other profiles and existing web analyses.
    """
    if not args.publish_to or not args.publish_path:
        raise ValueError('Publishing requires an SSH host and absolute database path')
    destination = args.publish_path
    if not destination.startswith('/'):
        raise ValueError('Remote database path must be absolute')
    remote = destination + f'.incoming-{os.getpid()}'
    try:
        with tempfile.TemporaryDirectory(prefix='bughouse-publish-') as temp:
            snapshot = Path(temp) / 'analysis.db'
            source = sqlite3.connect(args.db.resolve().as_uri() + '?mode=ro', uri=True, timeout=30)
            if not source.execute("SELECT 1 FROM sqlite_master WHERE name='analysis'").fetchone():
                source.close()
                return
            schema = source.execute("SELECT sql FROM sqlite_master WHERE name='analysis'").fetchone()[0]
            rows = source.execute('SELECT * FROM analysis').fetchall()
            source.close()
            with sqlite3.connect(snapshot) as export:
                export.execute(schema)
                export.executemany('INSERT INTO analysis VALUES(?,?,?,?,?,?,?,?)', rows)
            subprocess.run(['scp', '-q', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10',
                            str(snapshot), args.publish_to + ':' + remote], check=True, timeout=90)
            script = """import os,sqlite3,sys
path,stage=sys.argv[1:]
with sqlite3.connect(path,timeout=30) as db:
 db.execute('PRAGMA journal_mode=WAL')
 db.execute('ATTACH DATABASE ? AS incoming',(stage,))
 schema=db.execute("SELECT sql FROM incoming.sqlite_master WHERE name='analysis'").fetchone()[0]
 db.execute(schema.replace('CREATE TABLE ', 'CREATE TABLE IF NOT EXISTS ',1))
 db.execute('INSERT OR REPLACE INTO analysis SELECT * FROM incoming.analysis')
owner=os.stat(os.path.dirname(path))
for suffix in ("","-wal","-shm"):
 if os.path.exists(path+suffix):
  if os.geteuid()==0: os.chown(path+suffix,owner.st_uid,owner.st_gid)
  os.chmod(path+suffix,0o644)
os.unlink(stage)
"""
            subprocess.run(['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10', args.publish_to,
                            shlex.join(['python3', '-c', script, destination, remote])], check=True, timeout=90)
            print(json.dumps({'published': len(rows), 'host': args.publish_to}), flush=True)
    except (OSError, sqlite3.Error, subprocess.SubprocessError) as error:
        # A network outage must not discard or stop local engine work. Retry on
        # the next interval; all completed snapshots remain in the local book.
        print(f'Publish failed (will retry): {error}', file=sys.stderr, flush=True)


def stats(args):
    db = connect(args.db)
    print(json.dumps({'jobs': dict(db.execute('SELECT status,count(*) FROM job GROUP BY status')),
                      'errors': db.execute("SELECT id,error FROM job WHERE status='failed' LIMIT 5").fetchall()}, indent=2))
    db.close()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    default = Path.home() / '.local/share/chess-prep/bughouse-db'
    parser.add_argument('--db', type=Path, default=default / 'bughouse_expectimax.db')
    commands = parser.add_subparsers(dest='command', required=True)
    s = commands.add_parser('seed')
    s.add_argument('--fics', type=Path, default=default / 'bughouse_book.db')
    s.add_argument('--positions', type=int, default=1000)
    s.add_argument('--max-ply', type=int, default=12)
    r = commands.add_parser('run')
    r.add_argument('--dart', default='dart')
    r.add_argument('--worker-bin', type=Path)
    r.add_argument('--workers', type=int, default=2)
    r.add_argument('--cores', type=int, default=4)
    r.add_argument('--nodes', type=int, default=3000)
    r.add_argument('--plies', type=int, default=2)
    r.add_argument('--hours', type=float, default=10)
    r.add_argument('--support', type=Path, default=Path.home() / '.local/share/chess-prep')
    pub = commands.add_parser('publish')
    for command in (r, pub):
        command.add_argument('--publish-to', help='SSH host for publishing completed web tables')
        command.add_argument('--publish-path', help='Absolute expectimax database path on that host')
    commands.add_parser('stats')
    args = parser.parse_args()
    if args.command == 'run' and (args.workers < 1 or args.cores < 1 or not 100 <= args.nodes <= 100000 or not 1 <= args.plies <= 4 or args.hours <= 0):
        parser.error('Use positive workers/cores/hours, 100–100000 nodes and 1–4 plies')
    if args.command == 'run' and hasattr(os, 'sched_getaffinity') and args.workers * args.cores > len(os.sched_getaffinity(0)):
        parser.error('Requested worker cores exceed available CPU affinity')
    globals()[args.command](args)
