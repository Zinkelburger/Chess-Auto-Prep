"""Read/import the desktop builder's versioned, clock-free expectimax snapshots."""
from contextlib import closing
import json
import math
import os
from pathlib import Path
import sqlite3
import time

MODEL = 'crazyara-os96-t1.5-hivemind-search-v2'
DB_PATH = Path(os.getenv('BUGHOUSE_EXPECTIMAX_PATH', Path(__file__).parent / 'bughouse_expectimax.db'))
SCHEMA = '''CREATE TABLE IF NOT EXISTS analysis(
 pos INTEGER NOT NULL, board TEXT NOT NULL, profile TEXT NOT NULL,
 plies INTEGER NOT NULL, nodes INTEGER NOT NULL, fen TEXT NOT NULL,
 data TEXT NOT NULL, updated INTEGER NOT NULL, PRIMARY KEY(pos,board,profile));'''


def read(key, fen, path=None):
    path = Path(path or DB_PATH)
    result = {'A': None, 'B': None}
    if not path.exists():
        return result
    with closing(sqlite3.connect(path.resolve().as_uri() + '?mode=ro', uri=True, timeout=5)) as db:
        if not db.execute("SELECT 1 FROM sqlite_master WHERE name='analysis'").fetchone():
            return result
        for board in result:
            row = db.execute('SELECT data,updated FROM analysis WHERE pos=? AND board=? AND fen=? '
                             'AND profile LIKE ? ORDER BY plies DESC,nodes DESC LIMIT 1',
                             (key, board, fen, MODEL + ':%')).fetchone()
            if row:
                result[board] = {**json.loads(row[0]), 'updated': row[1]}
    return result


def canonical(boards):
    return ' | '.join(' '.join(b.fen().split()[:4]) for b in boards)


def validate_rows(rows, boards, board, parse_dual, push, budget):
    if not isinstance(rows, list) or len(rows) > 5:
        raise ValueError('At most five candidate moves per position')
    seen = set()
    for row in rows:
        budget[0] -= 1
        if budget[0] < 0:
            raise ValueError('Tree too large')
        move = boards[board].parse_uci(row['uci'])
        if move not in boards[board].legal_moves or row['uci'] in seen:
            raise ValueError('Invalid or repeated move')
        seen.add(row['uci'])
        for field in ('eval', 'white', 'black', 'probability', 'coverage'):
            value = row[field]
            lower = 0 if field in ('probability', 'coverage') else -1
            if not isinstance(value, (int, float)) or not math.isfinite(value) or not lower <= value <= 1:
                raise ValueError('Invalid value')
        after = push(boards, board, move)
        if canonical(parse_dual(row['fen'])) != canonical(after):
            raise ValueError('Child position does not match move')
        validate_rows(row['replies'], after, board, parse_dual, push, budget)


def store(records, parse_dual, position_key, push, path=None):
    if len(records) > 20:
        raise ValueError('At most 20 positions per batch')
    checked = []
    for record in records:
        boards = parse_dual(record['fen'])
        data = record['data']
        board = record['board']
        if board not in ('A', 'B') or data['model'] != MODEL:
            raise ValueError('Unsupported model or board')
        if data.get('perspective') != 'white-on-selected-board':
            raise ValueError('Wrong score perspective')
        plies, nodes = data['plies'], data['nodes']
        if not isinstance(plies, int) or not 1 <= plies <= 8 or not isinstance(nodes, int) or not 100 <= nodes <= 100000:
            raise ValueError('Invalid depth or budget')
        validate_rows(data['rows'], boards, 'AB'.index(board), parse_dual, push, [4000])
        checked.append((position_key(boards), board, f'{MODEL}:{plies}:{nodes}', plies, nodes,
                        canonical(boards), json.dumps(data, allow_nan=False), int(time.time())))
    path = Path(path or DB_PATH)
    path.parent.mkdir(parents=True, exist_ok=True)
    with closing(sqlite3.connect(path, timeout=10)) as db, db:
        db.execute('PRAGMA journal_mode=WAL')
        db.executescript(SCHEMA)
        db.executemany('INSERT OR REPLACE INTO analysis VALUES(?,?,?,?,?,?,?,?)', checked)
    return {'added': len(checked)}
