"""Shared, node-budgeted Lab evaluations; searches still run in the browser."""
import json
import secrets
import time
from typing import Literal

from fastapi import HTTPException
from pydantic import BaseModel, Field
import bughousedb as bh

SCHEMA = '''
CREATE TABLE IF NOT EXISTS lab_evaluation(
 pos INTEGER NOT NULL, fen TEXT NOT NULL, profile TEXT NOT NULL,
 nodes INTEGER NOT NULL, data TEXT NOT NULL, contributor TEXT NOT NULL,
 updated REAL NOT NULL, PRIMARY KEY(pos,fen,profile));
CREATE TABLE IF NOT EXISTS lab_ticket(
 id TEXT PRIMARY KEY, pos INTEGER NOT NULL, fen TEXT NOT NULL,
 contributor TEXT NOT NULL, issued REAL NOT NULL, used REAL);
'''


class Settings(BaseModel):
    fen: str = Field(max_length=400)
    team: Literal['white', 'black'] = 'white'
    required: Literal['none', 'A', 'B'] = 'none'
    clock: Literal['even', 'AB', 'CD'] = 'even'
    nodes: int = Field(default=800, ge=100, le=100000)

    @property
    def profile(self):
        return f'hivemind-web-v1:{self.team}:{self.required}:{self.clock}'


class Upload(Settings):
    ticket: str = Field(max_length=64)
    ours: bh.Search
    theirs: bh.Search | None = None


def identify(fen):
    try:
        boards = bh.parse_dual(fen)
    except bh.BadPosition as error:
        raise HTTPException(400, str(error)) from None
    # Keep move counters out of the cache identity, as for the expectimax book.
    canonical = bh.bughouse_expectimax.canonical(boards)
    return boards, bh.position_key(boards), canonical


def ticket(conn, fen, contributor):
    conn.executescript(SCHEMA)
    _, pos, canonical = identify(fen)
    token = secrets.token_urlsafe(24)
    now = time.time()
    with conn:
        conn.execute('DELETE FROM lab_ticket WHERE issued < ?', (now - bh.TICKET_TTL,))
        conn.execute('INSERT INTO lab_ticket VALUES(?,?,?,?,?,NULL)',
                     (token, pos, canonical, contributor, now))
    return {'ticket': token}


def read(conn, settings):
    conn.executescript(SCHEMA)
    _, pos, canonical = identify(settings.fen)
    row = conn.execute('SELECT data FROM lab_evaluation WHERE pos=? AND fen=? AND profile=? AND nodes>=?',
                       (pos, canonical, settings.profile, settings.nodes)).fetchone()
    return {'analysis': json.loads(row['data']) if row else None}


def joint(boards, text, team, required='none'):
    """Validate and label a joint action, allowing a capture to supply a drop."""
    if not text or not bh.JOINT.fullmatch(text):
        raise HTTPException(422, 'The analysis has no valid best move.')
    moves = text[1:-1].split(',')
    colour = team == 'white'
    if all(move == 'pass' for move in moves):
        raise HTTPException(422, 'The analysis must contain a move.')
    if required in ('A', 'B') and moves[0 if required == 'A' else 1] == 'pass':
        raise HTTPException(422, 'The selected board must move.')
    for order in ((0, 1), (1, 0)):
        current = [board.copy() for board in boards]
        labels = ['sit', 'sit']
        try:
            for which in order:
                if moves[which] == 'pass':
                    continue
                board = current[which]
                if board.turn != (colour if which == 0 else not colour):
                    raise ValueError('Wrong team')
                move = board.parse_uci(moves[which])
                labels[which] = board.san(move)
                current = bh.push(current, which, move)
            return {'A': labels[0], 'B': labels[1], 'uci': text}
        except ValueError:
            continue
    raise HTTPException(422, 'The best move is not legal for this team.')


def store(conn, upload, contributor):
    conn.executescript(SCHEMA)
    boards, pos, canonical = identify(upload.fen)
    ours, theirs = upload.ours, upload.theirs
    best = joint(boards, ours.best, upload.team, upload.required)
    for search in (ours, theirs):
        if search is None:
            continue
        if search.q is None and search.mate is None:
            raise HTTPException(422, 'An evaluation needs a value or a mate proof.')
        # A time-capped search is useful locally but must not masquerade as a
        # completed node budget in the shared cache.
        if search.mate is None and (search.nodes or 0) < upload.nodes:
            raise HTTPException(422, 'The search stopped before its node budget. Retry to finish it.')
        bh._check_joints(search.pv)
    if ours.mate is None and theirs is None:
        raise HTTPException(422, 'The other team is needed to calibrate the evaluation.')
    if theirs and theirs.best:
        joint(boards, theirs.best, 'black' if upload.team == 'white' else 'white')
    measured = theirs is not None and ours.mate is None and theirs.mate is None
    result = dict(best=best, lines=[], advantage=(ours.q - theirs.q) / 2 if measured else None,
                  mate=ours.mate, nodes=ours.nodes or 0,
                  total_nodes=(ours.nodes or 0) + (theirs.nodes or 0 if theirs else 0),
                  calibration={'source': 'measured' if measured else 'unavailable'}, shared=True)
    now = time.time()
    with conn:
        # Claim in the write transaction: overlapping POSTs cannot reuse a ticket.
        changed = conn.execute('UPDATE lab_ticket SET used=? WHERE id=? AND pos=? AND fen=? '
                               'AND contributor=? AND used IS NULL AND issued>=?',
                               (now, upload.ticket, pos, canonical, contributor, now - bh.TICKET_TTL)).rowcount
        if not changed:
            raise HTTPException(403, 'The upload ticket expired or was already used. Retry saving.')
        conn.execute('INSERT INTO lab_evaluation VALUES(?,?,?,?,?,?,?) '
                     'ON CONFLICT(pos,fen,profile) DO UPDATE SET nodes=excluded.nodes,data=excluded.data,'
                     'contributor=excluded.contributor,updated=excluded.updated '
                     'WHERE excluded.nodes > lab_evaluation.nodes',
                     (pos, canonical, upload.profile, upload.nodes, json.dumps(result), contributor, now))
    return read(conn, upload)
