"""BughouseDB — a shared, precomputed Hivemind book for bughouse positions.

Like the Chinese cloud database (chessdb.cn): a stored position lists every
legal move on both boards with Hivemind's score for A + C (White on board A,
Black on board B) in three clock cases, ahead, even and behind on the diagonal
clock, and a principal variation.

The server never runs an engine. A position that is not in the book is
analysed in the visitor's browser (the static WASM Hivemind that /bughouse
already uses) and uploaded here. Uploading takes a one-time ticket for that
exact position; the server checks every upload against its own move
generation and derives every score itself from the raw searches, so the
browser only reports what the engine said. Nothing can prove a browser
computed honestly, so every submission records its ticket and a hash of the
uploader's IP, and `purge` removes a contributor. The first upload supplies a
position's scores; a later upload from another computer counts as a
confirmation, and the page shows how many computers have analysed it.

Positions computed on the owner's machine (`tools/bughouse_db/hivemind_book.py
push`) arrive through the admin-key import endpoint.

Scores are stored as Hivemind's calibrated value Q in [-1, 1] (expected result
for A + C, 0 = level) and served with a Lichess-style centipawn figure,
cp = 543.17 * atanh(Q): the chess evaluation that wins as often on Lichess.

Run `python3 bughousedb.py stats` or `purge --contributor HASH` on the server.
"""

from __future__ import annotations

import hashlib
import math
import os
import re
import secrets
import sqlite3
import time
from pathlib import Path
from typing import Iterator

import chess
from chess.variant import CrazyhouseBoard
from fastapi import APIRouter, Depends, Header, HTTPException, Query, Request
from pydantic import BaseModel, Field

DB_PATH = Path(os.getenv("BUGHOUSEDB_PATH", Path(__file__).parent / "bughousedb.db"))
ADMIN_KEY = os.getenv("BUGHOUSEDB_ADMIN_KEY", "")
TICKET_TTL = 30 * 60           # seconds a ticket stays valid
MIN_SECONDS_PER_SEARCH = 0.05  # an upload faster than this per search is not real

# A + C's clock cases: "ahead" is A > D, "behind" is B > C, "both" is both.
CLOCKS = ("ahead", "even", "behind", "both")
TEAMS = ("AB", "CD")           # AB = White on board A + Black on board B
SIT_BIT_Q = 0.5814             # tools/mcp/bughouse/calibration.py
LICHESS_K = 0.00368208         # lila's winning-chances curve
JOINT = re.compile(r"^\((?:[A-Za-z0-9@]{2,6}|pass),(?:[A-Za-z0-9@]{2,6}|pass)\)$")

router = APIRouter(prefix="/api/bughousedb", tags=["bughousedb"])

SCHEMA = """
CREATE TABLE IF NOT EXISTS position(
  pos         INTEGER PRIMARY KEY,   -- FNV-1a of the canonical dual FEN (tools/bughouse_db/poskey.py)
  fen         TEXT NOT NULL,
  source      TEXT NOT NULL,         -- 'browser' | 'desktop'
  engine      TEXT NOT NULL,
  nodes       INTEGER,
  child_nodes INTEGER,
  contributor TEXT NOT NULL,         -- sha256(ip)[:16], or 'admin'
  ticket      TEXT,
  created_at  REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS position_contributor ON position(contributor);
CREATE TABLE IF NOT EXISTS pick(
  pos INTEGER NOT NULL, clock TEXT NOT NULL, team TEXT NOT NULL,
  best TEXT, q REAL, mate INTEGER, pv TEXT,
  PRIMARY KEY(pos, clock, team)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS move(
  pos INTEGER NOT NULL, board TEXT NOT NULL, uci TEXT NOT NULL, clock TEXT NOT NULL,
  q REAL, mate INTEGER, pv TEXT,
  PRIMARY KEY(pos, board, uci, clock)
) WITHOUT ROWID;
-- Every computer that analysed a position; the first one supplied its scores.
CREATE TABLE IF NOT EXISTS submission(
  pos         INTEGER NOT NULL,
  contributor TEXT NOT NULL,         -- sha256(ip)[:16], or 'admin'
  ticket      TEXT,
  created_at  REAL NOT NULL,
  PRIMARY KEY(pos, contributor)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS ticket(
  id TEXT PRIMARY KEY, pos INTEGER NOT NULL, contributor TEXT NOT NULL,
  issued REAL NOT NULL, used REAL
);
"""


def connect(path: Path | None = None) -> sqlite3.Connection:
    # A request's connection is opened by the `db` dependency and used by the
    # endpoint, which FastAPI may run on a different worker thread; overlapping
    # requests then land on different threads and sqlite3 refuses the handle.
    # Each request still gets its own connection, used by one thread at a time.
    conn = sqlite3.connect(path or DB_PATH, timeout=10, check_same_thread=False)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.executescript(SCHEMA)
    relabel_seats(conn)
    record_first_submissions(conn)
    return conn


def record_first_submissions(conn: sqlite3.Connection) -> None:
    """Positions stored before submissions were counted have one each: their uploader."""
    if conn.execute("SELECT 1 FROM meta WHERE key='submissions'").fetchone():
        return
    with conn:
        if not conn.execute(
                "INSERT OR IGNORE INTO meta(key, value) VALUES('submissions', '1')").rowcount:
            return
        conn.execute("INSERT OR IGNORE INTO submission "
                     "SELECT pos, contributor, ticket, created_at FROM position")


# The seats were once lettered A and B on board A, D and C on board B, which
# put a team's letters on different boards (A + C). They now read A + B and
# C + D. Seats are derived from board and colour, so only the text written
# before the change carries the old letters: the stored team names and the
# seat tags inside `best` and `pv`.
SEAT_SWAP = {"B": "C", "C": "B"}


def relabel_seats(conn: sqlite3.Connection) -> None:
    """Rewrite one database's stored seat letters, once."""
    if conn.execute("SELECT 1 FROM meta WHERE key='seats'").fetchone():
        return
    def swap(text: str | None) -> str | None:
        if not text:
            return text
        return re.sub(r"\b([BC])\b", lambda m: SEAT_SWAP[m.group(1)], text)

    renamed = {"AC": "AB", "BD": "CD"}
    with conn:
        # Claim it inside the transaction: two requests arriving together after
        # a restart both pass the check above, and swapping twice would put the
        # old letters back. The loser of the write lock sees the row and stops.
        if not conn.execute(
                "INSERT OR IGNORE INTO meta(key, value) VALUES('seats', 'AB/CD')").rowcount:
            return
        # `team` is part of the pick key, so those rows are rewritten wholesale.
        picks = conn.execute("SELECT pos, clock, team, best, q, mate, pv FROM pick").fetchall()
        conn.execute("DELETE FROM pick")
        conn.executemany(
            "INSERT INTO pick(pos, clock, team, best, q, mate, pv) VALUES(?,?,?,?,?,?,?)",
            [(p["pos"], p["clock"], renamed.get(p["team"], p["team"]), swap(p["best"]),
              p["q"], p["mate"], swap(p["pv"])) for p in picks])
        moves = conn.execute("SELECT pos, board, uci, clock, pv FROM move").fetchall()
        conn.executemany(
            "UPDATE move SET pv=? WHERE pos=? AND board=? AND uci=? AND clock=?",
            [(swap(m["pv"]), m["pos"], m["board"], m["uci"], m["clock"]) for m in moves])


def db() -> Iterator[sqlite3.Connection]:
    conn = connect()
    try:
        yield conn
    finally:
        conn.close()


# ── Bughouse positions ────────────────────────────────────────────────
# python-chess plays crazyhouse; bughouse differs in one rule: a captured
# piece keeps its colour and goes to the partner's pocket on the other board.


MAX_LINE = 400


class BadPosition(ValueError):
    pass


def parse_dual(fen: str) -> list[CrazyhouseBoard]:
    parts = [p.strip() for p in (fen or "").split("|")]
    if len(parts) != 2 or len(fen) > 400:
        raise BadPosition('A dual FEN is two crazyhouse FENs joined by "|".')
    try:
        boards = [CrazyhouseBoard(p) for p in parts]
    except ValueError as e:
        raise BadPosition(f"Not a valid position: {e}") from None
    for b in boards:
        if b.king(chess.WHITE) is None or b.king(chess.BLACK) is None:
            raise BadPosition("Each board needs both kings.")
    return boards


def dual_fen(boards: list[CrazyhouseBoard]) -> str:
    return "|".join(b.fen() for b in boards)


def position_key(boards: list[CrazyhouseBoard]) -> int:
    """Signed 64-bit FNV-1a, exactly tools/bughouse_db/poskey.py."""
    text = " | ".join(" ".join(b.fen().split(" ")[:4]) for b in boards)
    h = 0xCBF29CE484222325
    for byte in text.encode("utf-8"):
        h = ((h ^ byte) * 0x100000001B3) & ((1 << 64) - 1)
    return h - (1 << 64) if h >= (1 << 63) else h


def seat(which: int, colour: chess.Color) -> str:
    # Partners hold opposite colours, so the teams read A + B and C + D.
    return (("C", "A"), ("B", "D"))[which][colour]


def team_of(which: int, colour: chess.Color) -> str:
    """AB holds White on board A and Black on board B."""
    return "AB" if (colour == chess.WHITE) == (which == 0) else "CD"


def san(board: CrazyhouseBoard, move: chess.Move) -> str:
    text = board.san(move)
    return f"P{text}" if text.startswith("@") else text


def push(boards: list[CrazyhouseBoard], which: int, move: chess.Move) -> list[CrazyhouseBoard]:
    """A copy of the position after `move`, with the capture routed across."""
    out = [b.copy(stack=False) for b in boards]
    board = out[which]
    captured = None
    if move.drop is None:
        if board.is_en_passant(move):
            captured = chess.PAWN
        elif board.piece_at(move.to_square) is not None:
            captured = chess.PAWN if board.promoted & chess.BB_SQUARES[move.to_square] \
                else board.piece_at(move.to_square).piece_type
    mover = board.turn
    board.push(move)
    if captured is not None:
        board.pockets[mover].remove(captured)
        out[1 - which].pockets[not mover].add(captured)
    return out


def legal_moves(boards: list[CrazyhouseBoard]) -> list[dict]:
    rows = []
    for which in (0, 1):
        board = boards[which]
        for move in board.legal_moves:
            child = push(boards, which, move)
            mover = team_of(which, board.turn)
            rows.append({
                "board": "AB"[which], "uci": move.uci(), "san": san(board, move),
                "seat": seat(which, board.turn),
                "answerer": "CD" if mover == "AB" else "AB",
                "child_fen": dual_fen(child),
            })
    return rows


def team_can_move(boards: list[CrazyhouseBoard], team: str) -> bool:
    return any(team_of(w, boards[w].turn) == team and any(boards[w].legal_moves) for w in (0, 1))


def render_pv(boards: list[CrazyhouseBoard], joints: list[str], limit: int = 8) -> str:
    """Joint actions as seat-lettered SAN, '·' between joint actions."""
    out, cur = [], boards
    for joint in joints[:limit]:
        halves = joint.strip("()").split(",")
        if len(halves) != 2:
            break
        text = []
        for which, uci in enumerate(halves):
            if uci in ("pass", "none", "0000", ""):
                continue
            try:
                move = cur[which].parse_uci(uci)
                if move not in cur[which].legal_moves:
                    return " · ".join(out)
                text.append(f"{seat(which, cur[which].turn)} {san(cur[which], move)}")
                cur = push(cur, which, move)
            except ValueError:
                return " · ".join(out)
        out.append(" ".join(text) if text else "sit")
    return " · ".join(out)


def joint_text(boards: list[CrazyhouseBoard], joint: str | None, team: str) -> str:
    """The team's own halves of a joint action: 'A d4 · C sits'."""
    if not joint:
        return ""
    halves = joint.strip("()").split(",")
    parts = []
    for which, uci in enumerate(halves[:2]):
        board = boards[which]
        if team_of(which, board.turn) != team:
            continue
        who = seat(which, board.turn)
        if uci in ("pass", "none", "0000", ""):
            parts.append(f"{who} sits")
            continue
        try:
            move = board.parse_uci(uci)
        except ValueError:
            continue
        if move in board.legal_moves:
            parts.append(f"{who} {san(board, move)}")
    return " · ".join(parts)


# ── Scores ────────────────────────────────────────────────────────────


def team_bits(clock: str) -> dict[str, bool]:
    """Hivemind's only clock input, one bit per team: A + C's is A > D, B + D's
    is B > C (hivemind src/domain/board2planes.py). Equal is both off."""
    return {"AB": clock in ("ahead", "both"), "CD": clock in ("behind", "both")}


def centipawns(q: float | None) -> int | None:
    if q is None:
        return None
    q = max(-0.9999, min(0.9999, q))
    return round(2 / LICHESS_K * math.atanh(q))


class Search(BaseModel):
    q: float | None = Field(default=None, ge=-1, le=1)
    mate: int | None = Field(default=None, ge=-500, le=500)
    pv: list[str] = Field(default_factory=list, max_length=16)
    best: str | None = Field(default=None, max_length=32)
    nodes: int | None = Field(default=None, ge=0, le=10_000_000)


def _check_joints(joints: list[str]) -> None:
    for j in joints:
        if not JOINT.match(j):
            raise HTTPException(422, f"Not a joint action: {j[:20]!r}")


def derive(boards: list[CrazyhouseBoard], own: dict[tuple[str, bool], Search],
           moves: dict[tuple[str, str], dict[bool, Search | None]]) -> tuple[list, list]:
    """Pick and move rows (Q for A + C) from the raw searches — the same
    arithmetic as tools/bughouse_db/hivemind_book.py."""
    def q_of(s: Search | None) -> float | None:
        return None if s is None or s.mate is not None else s.q

    offsets = {}
    for clock in CLOCKS:
        bits = team_bits(clock)
        qa, qb = q_of(own.get(("AB", bits["AB"]))), q_of(own.get(("CD", bits["CD"])))
        offsets[clock] = (qa + qb) / 2 if qa is not None and qb is not None else (
            (SIT_BIT_Q if bits["AB"] else -SIT_BIT_Q) + (SIT_BIT_Q if bits["CD"] else -SIT_BIT_Q)) / 2

    def value(s: Search | None, team: str, clock: str) -> tuple[float | None, int | None]:
        if s is None:
            return None, None
        sign = 1 if team == "AB" else -1
        if s.mate is not None:
            return (1.0 if sign * s.mate > 0 else -1.0), sign * s.mate
        if s.q is None:
            return None, None
        return round(sign * max(-1.0, min(1.0, s.q - offsets[clock])), 5), None

    picks, rows = [], []
    for clock in CLOCKS:
        bits = team_bits(clock)
        for team in TEAMS:
            s = own.get((team, bits[team]))
            if s is None:
                continue
            q, mate = value(s, team, clock)
            picks.append((clock, team, joint_text(boards, s.best, team), q, mate, render_pv(boards, s.pv)))
    by_uci = {(m["board"], m["uci"]): m for m in legal_moves(boards)}
    for (board, uci), searches in moves.items():
        meta = by_uci[(board, uci)]
        which = "AB".index(board)
        child = push(boards, which, boards[which].parse_uci(uci))
        for clock in CLOCKS:
            s = searches.get(team_bits(clock)[meta["answerer"]])
            q, mate = value(s, meta["answerer"], clock)
            pv = f"{meta['seat']} {meta['san']}"
            rest = render_pv(child, s.pv) if s is not None else ""
            rows.append((board, uci, clock, q, mate, pv + (" · " + rest if rest else "")))
    return picks, rows


# ── Reading ───────────────────────────────────────────────────────────


def play_line(boards: list[CrazyhouseBoard], moves: str) -> list[CrazyhouseBoard]:
    """`moves` played in order: board-tagged UCI such as "A:e2e4 B:P@e6"."""
    tokens = moves.split()
    if len(tokens) > MAX_LINE:
        raise BadPosition(f"Use up to {MAX_LINE} moves.")
    for token in tokens:
        tag, _, uci = token.partition(":")
        if tag not in ("A", "B") or not uci:
            raise BadPosition(f"Tag each move with its board, like A:e2e4, not {token[:12]!r}.")
        which = "AB".index(tag)
        try:
            move = boards[which].parse_uci(uci)
        except ValueError:
            move = None
        if move is None or move not in boards[which].legal_moves:
            raise BadPosition(f"{token} is not legal there.")
        boards = push(boards, which, move)
    return boards


def read_position(conn: sqlite3.Connection, fen: str, moves: str = "") -> dict:
    try:
        boards = play_line(parse_dual(fen), moves)
    except BadPosition as e:
        raise HTTPException(400, str(e)) from None
    key = position_key(boards)
    row = conn.execute("SELECT *, (SELECT COUNT(*) FROM submission s WHERE s.pos = position.pos)"
                       " AS computers FROM position WHERE pos=?", (key,)).fetchone()
    scores: dict[tuple[str, str], dict] = {}
    picks = []
    if row:
        for m in conn.execute("SELECT board, uci, clock, q, mate, pv FROM move WHERE pos=?", (key,)):
            scores.setdefault((m["board"], m["uci"]), {})[m["clock"]] = {
                "q": m["q"], "cp": centipawns(m["q"]) if m["mate"] is None else None,
                "mate": m["mate"], "pv": m["pv"]}
        for p in conn.execute("SELECT clock, team, best, q, mate, pv FROM pick WHERE pos=?", (key,)):
            picks.append({"clock": p["clock"], "team": p["team"], "best": p["best"], "q": p["q"],
                          "cp": centipawns(p["q"]) if p["mate"] is None else None,
                          "mate": p["mate"], "pv": p["pv"]})
    moves = [{**m, "scores": scores.get((m["board"], m["uci"]))} for m in legal_moves(boards)]
    return {
        "key": str(key), "fen": dual_fen(boards), "found": bool(row),
        "turn": {"A": "white" if boards[0].turn else "black", "B": "white" if boards[1].turn else "black"},
        "teams": [t for t in TEAMS if team_can_move(boards, t)],
        "moves": moves, "picks": picks,
        "meta": None if not row else {
            "source": row["source"], "engine": row["engine"], "nodes": row["nodes"],
            "child_nodes": row["child_nodes"], "created_at": row["created_at"],
            "computers": row["computers"]},
    }


@router.get("/position")
def get_position(fen: str = Query(..., max_length=400), moves: str = Query("", max_length=4000),
                 conn=Depends(db)):
    """The position after `moves` (board-tagged UCI) from `fen`: each board
    can be stepped through on its own by replaying the moves kept."""
    return read_position(conn, fen, moves)


# ── Browser uploads ───────────────────────────────────────────────────


def client_ip(request: Request) -> str:
    """Cloudflare sets CF-Connecting-IP and overwrites any the client sent;
    X-Forwarded-For keeps the client's own first entry, so it is not used."""
    return (request.headers.get("CF-Connecting-IP")
            or (request.client.host if request.client else "") or "unknown")


def contributor_of(request: Request) -> str:
    return hashlib.sha256(("bughousedb:" + client_ip(request)).encode()).hexdigest()[:16]


class TicketRequest(BaseModel):
    fen: str = Field(max_length=400)


class MoveUpload(BaseModel):
    board: str = Field(pattern="^[AB]$")
    uci: str = Field(max_length=8)
    on: Search | None = None    # the answering team's clock bit on
    off: Search | None = None


class OwnUpload(BaseModel):
    team: str = Field(pattern="^(AB|CD)$")
    ahead: bool
    search: Search


class PositionUpload(BaseModel):
    ticket: str = Field(max_length=64)
    fen: str = Field(max_length=400)
    engine: str = Field(max_length=80)
    nodes: int = Field(ge=1, le=1_000_000)
    child_nodes: int = Field(ge=1, le=1_000_000)
    own: list[OwnUpload] = Field(max_length=4)
    moves: list[MoveUpload] = Field(max_length=600)


def issue_ticket(conn: sqlite3.Connection, fen: str, contributor: str) -> dict:
    try:
        boards = parse_dual(fen)
    except BadPosition as e:
        raise HTTPException(400, str(e)) from None
    key = position_key(boards)
    if conn.execute("SELECT 1 FROM submission WHERE pos=? AND contributor=?",
                    (key, contributor)).fetchone():
        raise HTTPException(409, "This computer has already analysed this position.")
    if not any(boards[w].legal_moves for w in (0, 1)):
        raise HTTPException(400, "Nobody can move in this position.")
    ticket = secrets.token_urlsafe(24)
    now = time.time()
    with conn:
        conn.execute("DELETE FROM ticket WHERE issued < ?", (now - 7 * 86400,))
        conn.execute("INSERT INTO ticket VALUES(?,?,?,?,NULL)", (ticket, key, contributor, now))
    return {"ticket": ticket, "key": str(key), "expires_in": TICKET_TTL}


def store_upload(conn: sqlite3.Connection, up: PositionUpload, contributor: str) -> dict:
    try:
        boards = parse_dual(up.fen)
    except BadPosition as e:
        raise HTTPException(400, str(e)) from None
    key = position_key(boards)
    t = conn.execute("SELECT * FROM ticket WHERE id=?", (up.ticket,)).fetchone()
    now = time.time()
    if t is None or t["pos"] != key:
        raise HTTPException(403, "This upload has no valid ticket for this position.")
    if t["used"] is not None:
        raise HTTPException(403, "This ticket was already used.")
    if now - t["issued"] > TICKET_TTL:
        raise HTTPException(403, "This ticket expired. Analyse the position again.")

    legal = {(m["board"], m["uci"]) for m in legal_moves(boards)}
    sent = {(m.board, m.uci) for m in up.moves}
    if sent != legal or len(up.moves) != len(legal):
        raise HTTPException(422, "The upload must score exactly the legal moves of this position.")
    own = {}
    for o in up.own:
        _check_joints(o.search.pv + ([o.search.best] if o.search.best else []))
        own[(o.team, o.ahead)] = o.search
    for team in TEAMS:
        if team_can_move(boards, team) and not all((team, bit) in own for bit in (True, False)):
            raise HTTPException(422, f"Missing the searches of the position for {team}.")
    moves: dict[tuple[str, str], dict[bool, Search | None]] = {}
    for m in up.moves:
        for s in (m.on, m.off):
            if s is not None:
                _check_joints(s.pv)
        moves[(m.board, m.uci)] = {True: m.on, False: m.off}
    # A browser scores only each board's top few moves; the rest carry no search.
    searches = len(own) + sum(s is not None for m in up.moves for s in (m.on, m.off))
    if now - t["issued"] < searches * MIN_SECONDS_PER_SEARCH:
        raise HTTPException(429, "That was faster than the engine can search. Try again.")

    picks, rows = derive(boards, own, moves)
    with conn:
        if conn.execute("SELECT 1 FROM submission WHERE pos=? AND contributor=?",
                        (key, contributor)).fetchone():
            raise HTTPException(409, "This computer has already analysed this position.")
        conn.execute("UPDATE ticket SET used=? WHERE id=?", (now, up.ticket))
        conn.execute("INSERT INTO submission VALUES(?,?,?,?)", (key, contributor, up.ticket, now))
        # The first computer's searches are the book's; a later one confirms them.
        if not conn.execute("SELECT 1 FROM position WHERE pos=?", (key,)).fetchone():
            conn.execute("INSERT INTO position VALUES(?,?,?,?,?,?,?,?,?)",
                         (key, dual_fen(boards), "browser", up.engine, up.nodes, up.child_nodes,
                          contributor, up.ticket, now))
            conn.executemany("INSERT INTO pick VALUES(?,?,?,?,?,?,?)", [(key, *p) for p in picks])
            conn.executemany("INSERT INTO move VALUES(?,?,?,?,?,?,?)", [(key, *r) for r in rows])
        computers = conn.execute("SELECT COUNT(*) FROM submission WHERE pos=?", (key,)).fetchone()[0]
    return {"key": str(key), "moves": len(moves), "computers": computers}


# ── Owner imports (desktop builder) ───────────────────────────────────


class ImportPick(BaseModel):
    clock: str = Field(pattern="^(ahead|even|behind|both)$")
    team: str = Field(pattern="^(AB|CD)$")
    best: str = Field(default="", max_length=80)
    q: float | None = Field(default=None, ge=-1, le=1)
    mate: int | None = None
    pv: str = Field(default="", max_length=400)


class ImportMove(BaseModel):
    board: str = Field(pattern="^[AB]$")
    uci: str = Field(max_length=8)
    clock: str = Field(pattern="^(ahead|even|behind|both)$")
    q: float | None = Field(default=None, ge=-1, le=1)
    mate: int | None = None
    pv: str = Field(default="", max_length=400)


class ImportPosition(BaseModel):
    fen: str = Field(max_length=400)
    engine: str = Field(max_length=80)
    nodes: int
    child_nodes: int
    picks: list[ImportPick] = Field(max_length=8)
    moves: list[ImportMove] = Field(max_length=2400)


class ImportBatch(BaseModel):
    positions: list[ImportPosition] = Field(max_length=200)
    replace: bool = False


def store_import(conn: sqlite3.Connection, batch: ImportBatch) -> dict:
    added = skipped = 0
    errors = []
    now = time.time()
    for p in batch.positions:
        try:
            boards = parse_dual(p.fen)
        except BadPosition as e:
            errors.append(str(e))
            continue
        key = position_key(boards)
        legal = {(m["board"], m["uci"]) for m in legal_moves(boards)}
        if {(m.board, m.uci) for m in p.moves} != legal:
            errors.append(f"{p.fen}: moves are not the legal set")
            continue
        with conn:
            if conn.execute("SELECT 1 FROM position WHERE pos=?", (key,)).fetchone():
                if not batch.replace:
                    skipped += 1
                    continue
                # The earlier confirmations were of the scores being replaced.
                for table in ("position", "pick", "move", "submission"):
                    conn.execute(f"DELETE FROM {table} WHERE pos=?", (key,))
            conn.execute("INSERT OR IGNORE INTO submission VALUES(?,?,?,?)", (key, "admin", None, now))
            conn.execute("INSERT INTO position VALUES(?,?,?,?,?,?,?,?,?)",
                         (key, dual_fen(boards), "desktop", p.engine, p.nodes, p.child_nodes,
                          "admin", None, now))
            conn.executemany("INSERT INTO pick VALUES(?,?,?,?,?,?,?)",
                             [(key, x.clock, x.team, x.best, x.q, x.mate, x.pv) for x in p.picks])
            conn.executemany("INSERT INTO move VALUES(?,?,?,?,?,?,?)",
                             [(key, m.board, m.uci, m.clock, m.q, m.mate, m.pv) for m in p.moves])
        added += 1
    return {"added": added, "skipped": skipped, "errors": errors[:20]}


@router.post("/import")
def import_positions(batch: ImportBatch, x_api_key: str = Header(default=""), conn=Depends(db)):
    if not ADMIN_KEY or not secrets.compare_digest(x_api_key, ADMIN_KEY):
        raise HTTPException(401, "Invalid API key")
    return store_import(conn, batch)


# ── Admin CLI ─────────────────────────────────────────────────────────


def main(argv: list[str] | None = None) -> int:
    import argparse

    ap = argparse.ArgumentParser(description="BughouseDB maintenance")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("stats")
    p = sub.add_parser("purge", help="delete every position one contributor supplied, and their confirmations")
    p.add_argument("--contributor", required=True)
    args = ap.parse_args(argv)
    conn = connect()
    if args.cmd == "stats":
        for r in conn.execute("SELECT source, contributor, COUNT(*) n FROM position "
                              "GROUP BY source, contributor ORDER BY n DESC LIMIT 30"):
            print(f"{r['source']:8} {r['contributor']:18} {r['n']}")
        return 0
    keys = [r[0] for r in conn.execute("SELECT pos FROM position WHERE contributor=?", (args.contributor,))]
    with conn:
        for table in ("position", "pick", "move", "submission"):
            conn.executemany(f"DELETE FROM {table} WHERE pos=?", [(k,) for k in keys])
        confirmations = conn.execute("DELETE FROM submission WHERE contributor=?",
                                     (args.contributor,)).rowcount
    print(f"purged {len(keys)} positions and {confirmations} confirmations")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
