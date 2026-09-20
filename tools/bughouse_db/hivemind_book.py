#!/usr/bin/env python3
"""Hivemind's own bughouse book: every legal move, scored for three clocks.

Modelled on the Chinese cloud database (chessdb.cn): a stored position lists
every legal move on both boards with the engine's score and principal
variation, so the Lab can show a table instead of waiting for a search.

Unlike the FICS book next to it, nothing here comes from games. Each position
is searched by Hivemind, one search at a time, by one engine process.

How a position is scored
------------------------
A move's score is the value of the position it leads to: the move is played,
and the team that has to answer it on that board is searched. Partners hold
opposite colours, so the teams are A + B and C + D. Hivemind's clock input is
one bit per team -- "up on the diagonal clock, so free to sit rather than
move" -- and each answer costs one search per bit:

    priority           C + D answers with    A + B answers with
    ahead  (A + B's)   bit off               bit on
    even   (nobody's)  bit off               bit off
    behind (C + D's)   bit on                bit off
    both               bit on                bit on

By default only ``even`` is searched, which halves the work: one search per
move instead of two, and two searches of the position instead of four. The
priority cases are computed for a run given ``--priority all``. ``both`` is
a curiosity -- no clock gives both teams the choice, and with neither team
obliged to move it lands within about a tenth of a pawn of ``even``.

A raw Hivemind score carries a large offset (see
``tools/mcp/bughouse/calibration.py``), measured once per position and clock
from both teams' searches of the position itself and subtracted from every
move's score, so 0.00 reads as level and + is good for A + B.

Scores are stored on the engine's scale (``to_score`` of the calibrated
value), the same scale as the MCP server's ``advantage_score``.

Usage (from the repository root)::

    python3 tools/bughouse_db/hivemind_book.py run
    python3 tools/bughouse_db/hivemind_book.py run --child-nodes 400 --max-ply 10
    python3 tools/bughouse_db/hivemind_book.py show "A:e4 B:d4"
    python3 tools/bughouse_db/hivemind_book.py stats
    python3 tools/bughouse_db/hivemind_book.py push --url https://api.chessautoprep.com

Which positions get searched
----------------------------
By default the book follows the FICS archive (``bughouse_book.db``): after a
position is done, its ``--width`` most-played FICS continuations are queued,
to ``--max-ply``, and the queue is worked most-played first (priority is the
number of FICS games that reached the position). ``--follow engine`` queues
Hivemind's own best moves instead.

`run` is resumable: stop it at any time (Ctrl-C, or `systemctl --user stop`)
and the next `run` continues from the queue. A position is committed only
when all of its moves are done.
"""

from __future__ import annotations

import argparse
import math
import re
import signal
import sqlite3
import sys
import time
from collections.abc import Sequence
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "mcp"))
sys.path.insert(0, str(HERE.parent))

import chess  # noqa: E402

from bughouse.analysis import answering_team  # noqa: E402
from bughouse.board import BOARD_NAMES, DualBoard, san  # noqa: E402
from bughouse.calibration import assumed_offset, to_q, to_score  # noqa: E402
from bughouse.engine import HivemindEngine, SearchResult  # noqa: E402
from bughouse_db.book import explore, open_book  # noqa: E402
from bughouse_db.paths import data_home  # noqa: E402
from bughouse_db.poskey import dual_key_fen, position_key  # noqa: E402

# Which team has priority -- the time to choose whether to move at all --
# named by Hivemind's two inputs: "ahead" is A + B's, "behind" is C + D's,
# "even" is nobody's. "both" is both inputs on, which no clock produces: with
# neither team obliged to move it lands within about a tenth of a pawn of
# "even", so it is not searched unless asked for.
CLOCKS = ("ahead", "even", "behind", "both")
DEFAULT_CLOCKS = ("even",)
TEAMS = (chess.WHITE, chess.BLACK)  # a team is named by its colour on board A
# Partners hold opposite colours, so the teams are A + B and C + D.
SEATS = {("A", chess.WHITE): "A", ("A", chess.BLACK): "C",
         ("B", chess.WHITE): "D", ("B", chess.BLACK): "B"}

SCHEMA = """
CREATE TABLE IF NOT EXISTS position(
  pos       INTEGER PRIMARY KEY,  -- same key as the FICS book (poskey.py)
  fen       TEXT NOT NULL,        -- dual FEN, board A | board B
  line      TEXT NOT NULL,        -- first line that reached it: 'A:e4 B:d4'
  ply       INTEGER NOT NULL,
  priority  REAL NOT NULL,        -- lower is searched first
  status    TEXT NOT NULL,        -- 'queued' | 'running' (claimed by a worker) | 'done'
  nodes     INTEGER,              -- per search of the position itself
  child_nodes INTEGER,            -- per search of each move
  seconds   REAL,
  done_at   TEXT
);
CREATE INDEX IF NOT EXISTS position_queue ON position(status, priority);

-- The engine's own choice in the position, per clock and team.
CREATE TABLE IF NOT EXISTS pick(
  pos    INTEGER NOT NULL,
  clock  TEXT NOT NULL,
  team   TEXT NOT NULL,           -- 'AB' | 'CD'
  best   TEXT,                    -- joint action, seat-lettered: 'A d4 · B sits'
  score  REAL,                    -- A + B, 0 = level
  mate   INTEGER,                 -- plies, + mates for A + B
  pv     TEXT,
  offset REAL,                    -- the calibration used for this clock
  PRIMARY KEY(pos, clock, team)
) WITHOUT ROWID;

-- Every legal move, scored.
CREATE TABLE IF NOT EXISTS move(
  pos    INTEGER NOT NULL,
  move   TEXT NOT NULL,           -- board-tagged SAN: 'A:e4', 'B:N@f3'
  seat   TEXT NOT NULL,           -- A B C D
  uci    TEXT NOT NULL,
  clock  TEXT NOT NULL,
  score  REAL,                    -- A + B, 0 = level
  mate   INTEGER,                 -- + mates for A + B
  pv     TEXT,                    -- starts with the move itself
  child  INTEGER NOT NULL,        -- pos key after the move
  PRIMARY KEY(pos, move, clock)
) WITHOUT ROWID;

CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
"""


def book_file() -> Path:
    return data_home() / "hivemind_book.db"


def key_of(dual: DualBoard) -> int:
    a, b = (board.fen() for board in dual.boards)
    return position_key(dual_key_fen(a, b))


def seat_of(dual: DualBoard, which: int) -> str:
    return SEATS[(BOARD_NAMES[which], dual.boards[which].turn)]


# ── Reading the engine ──────────────────────────────────────────────────────


_configured: dict[int, tuple] = {}


def search(engine: HivemindEngine, dual: DualBoard, team: chess.Color,
           ahead: bool, nodes: int, multipv: int = 1) -> SearchResult:
    # Setting options costs a round trip, so only when they change; the move
    # loop below is ordered so they change twice per board, not every search.
    settings = (team, ahead, multipv)
    if _configured.get(id(engine)) != settings:
        engine.configure(team="white" if team == chess.WHITE else "black",
                         time_advantage=ahead, require_move_on="none", multipv=multipv)
        _configured[id(engine)] = settings
    engine.set_position(dual.dual_fen)
    return engine.search(nodes=nodes)


def top_q(result: SearchResult) -> float | None:
    top = result.top
    if top is None or top.mate is not None:
        return None
    return to_q(top.score_cp)


def readable_pv(dual: DualBoard, joints: list, limit: int = 6) -> str:
    """Joint actions as seat-lettered SAN, '·' between joint actions."""
    board = dual.copy()
    out = []
    for joint in joints[:limit]:
        halves = []
        for which, uci in ((0, joint.a), (1, joint.b)):
            if uci is None:
                continue
            try:
                seat = seat_of(board, which)
                ply = board.push(BOARD_NAMES[which], uci)
                halves.append(f"{seat} {ply.san}")
            except Exception:
                return " · ".join(out)
        out.append(" ".join(halves) if halves else "sit")
    return " · ".join(out)


def joint_text(dual: DualBoard, joint, team: chess.Color) -> str:
    if joint is None:
        return ""
    parts = []
    for which, uci in ((0, joint.a), (1, joint.b)):
        board = dual.boards[which]
        mine = board.turn == (team if which == 0 else not team)
        if not mine:
            continue
        seat = seat_of(dual, which)
        if uci is None:
            parts.append(f"{seat} sits")
        else:
            try:
                parts.append(f"{seat} {san(board, board.parse_uci(uci))}")
            except Exception:
                parts.append(f"{seat} {uci}")
    return " · ".join(parts)


def for_ac(result: SearchResult, team: chess.Color, offset: float) -> tuple[float | None, int | None]:
    """A searched team's top line as (A + B score, A + B mate)."""
    top = result.top
    if top is None:
        return None, None
    sign = 1 if team == chess.WHITE else -1
    if top.mate is not None:
        return None, sign * top.mate
    adv = max(-1.0, min(1.0, to_q(top.score_cp) - offset))
    return round(sign * to_score(adv), 3), None


# ── One position ────────────────────────────────────────────────────────────


def clocks_of(args: argparse.Namespace) -> tuple[str, ...]:
    """The priority cases a run searches: nobody's, or every case."""
    return CLOCKS if getattr(args, "priority", "even") == "all" else DEFAULT_CLOCKS


def team_bits(clock: str) -> dict[chess.Color, bool]:
    """Which team has the clock bit on, for one A + C clock case."""
    return {chess.WHITE: clock in ("ahead", "both"), chess.BLACK: clock in ("behind", "both")}


def analyse_position(engine: HivemindEngine, dual: DualBoard, nodes: int,
                     child_nodes: int, clocks: Sequence[str] = DEFAULT_CLOCKS,
                     ) -> tuple[list[tuple], list[tuple], dict]:
    """Returns (pick rows, move rows, per-move A+B score by clock for expansion)."""
    pos = key_of(dual)

    # Only the bits the asked-for clocks read: one search of the position per
    # team and bit (two for "even" alone, four for every case). They give the
    # engine's own pick for each clock and the offset to read it by.
    wanted = {(team, team_bits(clock)[team]) for clock in clocks for team in TEAMS}
    own = {(team, bit): search(engine, dual, team, bit, nodes, multipv=1)
           for team, bit in sorted(wanted)}
    offsets = {}
    for clock in clocks:
        bits = team_bits(clock)
        qw, qb = top_q(own[(chess.WHITE, bits[chess.WHITE])]), top_q(own[(chess.BLACK, bits[chess.BLACK])])
        offsets[clock] = (qw + qb) / 2 if qw is not None and qb is not None \
            else assumed_offset(bits[chess.WHITE], bits[chess.BLACK])

    picks = []
    for clock in clocks:
        bits = team_bits(clock)
        for team in TEAMS:
            res = own[(team, bits[team])]
            if res.top is None:
                continue
            score, mate = for_ac(res, team, offsets[clock])
            picks.append((pos, clock, "AB" if team == chess.WHITE else "CD",
                          joint_text(dual, res.best, team), score, mate,
                          readable_pv(dual, res.top.pv), round(offsets[clock], 4)))

    # Every legal move on both boards: play it, search whoever answers it.
    moves, scores = [], {}
    for which in (0, 1):
        name = BOARD_NAMES[which]
        board = dual.boards[which]
        seat = seat_of(dual, which)
        answers = answering_team(dual, which)  # judged before the move
        children = []
        for move in list(board.legal_moves):
            after = dual.copy()
            ply = after.push(name, move.uci())
            children.append((move, after, ply))
        bits = {team_bits(clock)[answers] for clock in clocks}
        found = {bit: [search(engine, after, answers, bit, child_nodes) for _, after, _ in children]
                 for bit in sorted(bits)}
        for i, (move, after, ply) in enumerate(children):
            tag = f"{name}:{ply.san}"
            child = key_of(after)
            by_bit = {bit: found[bit][i] for bit in found}
            scores[tag] = {"after": after, "seat": seat}
            for clock in clocks:
                res = by_bit[team_bits(clock)[answers]]
                score, mate = for_ac(res, answers, offsets[clock])
                pv = f"{seat} {ply.san}"
                rest = readable_pv(after, res.top.pv if res.top else [])
                if rest:
                    pv += " · " + rest
                moves.append((pos, tag, seat, move.uci(), clock, score, mate, pv, child))
                scores[tag][clock] = (score, mate)
    return picks, moves, scores


def mover_value(entry: tuple, seat: str) -> float:
    """A move's value for the team that plays it, for ranking."""
    score, mate = entry
    sign = 1 if seat in "AC" else -1
    if mate is not None:
        return sign * (1000 - abs(mate)) * (1 if mate > 0 else -1)
    return -1e9 if score is None else sign * score


# ── The queue ───────────────────────────────────────────────────────────────


def open_db(path: Path) -> sqlite3.Connection:
    path.parent.mkdir(parents=True, exist_ok=True)
    con = sqlite3.connect(path, timeout=60)  # several workers share the file
    con.executescript(SCHEMA)
    con.execute("PRAGMA journal_mode=WAL")
    relabel_seats(con)
    return con


def relabel_seats(con: sqlite3.Connection) -> None:
    """Rewrite a book written before the seats were lettered A + B and C + D.

    Board 1's black seat was B and board 2's was C, which split each team's
    letters across the boards. Only stored text carries the old letters: the
    team names, the seat of each move, and the seat tags inside `best` and
    `pv`.
    """
    if con.execute("SELECT 1 FROM meta WHERE key='seats'").fetchone():
        return
    swap = lambda text: None if not text else re.sub(  # noqa: E731
        r"\b([BC])\b", lambda m: {"B": "C", "C": "B"}[m.group(1)], text)
    renamed = {"AC": "AB", "BD": "CD"}
    with con:
        picks = con.execute("SELECT * FROM pick").fetchall()
        con.execute("DELETE FROM pick")
        con.executemany("INSERT INTO pick VALUES(?,?,?,?,?,?,?,?)",
                        [(pos, clock, renamed.get(team, team), swap(best), score, mate,
                          swap(pv), offset)
                         for pos, clock, team, best, score, mate, pv, offset in picks])
        moves = con.execute("SELECT pos, move, seat, clock, pv FROM move").fetchall()
        con.executemany("UPDATE move SET seat=?, pv=? WHERE pos=? AND move=? AND clock=?",
                        [(swap(seat), swap(pv), pos, move, clock)
                         for pos, move, seat, clock, pv in moves])
        con.execute("INSERT INTO meta(key, value) VALUES('seats', 'AB/CD')")


def claim(con: sqlite3.Connection) -> tuple | None:
    """The next queued position, marked 'running' so no other worker takes it."""
    with con:
        con.execute("BEGIN IMMEDIATE")
        row = con.execute(
            "SELECT pos, fen, line, ply FROM position WHERE status='queued' "
            "ORDER BY priority, ply LIMIT 1").fetchone()
        if row:
            con.execute("UPDATE position SET status='running' WHERE pos=?", (row[0],))
    return row


def run_workers(args: argparse.Namespace) -> int:
    """`--workers N`: N builder processes on one queue, each with its own
    engine (one engine keeps about five cores busy). Positions a stopped run
    had claimed go back to the queue first."""
    import subprocess

    con = open_db(args.db)
    con.execute("UPDATE position SET status='queued' WHERE status='running'")
    con.commit()
    con.close()
    base = [sys.executable, "-u", str(Path(__file__).resolve()), "--db", str(args.db), "run",
            "--root", args.root, "--nodes", str(args.nodes), "--child-nodes", str(args.child_nodes),
            "--max-ply", str(args.max_ply), "--follow", args.follow, "--width", str(args.width),
            "--priority", args.priority]
    procs = [subprocess.Popen(base + ["--worker", str(i + 1)]) for i in range(args.workers)]

    def forward(sig, _frame):
        for p in procs:
            p.send_signal(sig)

    signal.signal(signal.SIGINT, forward)
    signal.signal(signal.SIGTERM, forward)
    return max(p.wait() for p in procs)


def enqueue(con: sqlite3.Connection, dual: DualBoard, line: str, ply: int, priority: float) -> None:
    con.execute(
        "INSERT INTO position(pos, fen, line, ply, priority, status) VALUES(?,?,?,?,?,'queued') "
        "ON CONFLICT(pos) DO UPDATE SET priority = MIN(priority, excluded.priority) "
        "WHERE status = 'queued'",
        (key_of(dual), dual.dual_fen, line, ply, priority))


def run(args: argparse.Namespace) -> int:
    if args.workers > 1 and not args.worker:
        return run_workers(args)
    con = open_db(args.db)
    if not args.worker:
        con.execute("UPDATE position SET status='queued' WHERE status='running'")
    root = DualBoard()
    for tag in (args.root or "").split():
        b, text = tag.split(":", 1)
        root.push(b, text)
    enqueue(con, root, args.root or "", len((args.root or "").split()), -1e12)
    con.commit()

    stop = {"now": False}

    def on_signal(*_):
        stop["now"] = True
        print("stopping after this position…", flush=True)

    signal.signal(signal.SIGINT, on_signal)
    signal.signal(signal.SIGTERM, on_signal)

    fics = open_book() if args.follow == "fics" else None
    engine = HivemindEngine()
    started, done_here = time.time(), 0
    try:
        while not stop["now"]:
            row = claim(con)
            if row is None:
                print("queue empty", flush=True)
                break
            pos, fen, line, ply = row
            dual = DualBoard.from_dual_fen(fen)
            t0 = time.time()
            picks, moves, scores = analyse_position(engine, dual, args.nodes, args.child_nodes,
                                                    clocks=clocks_of(args))
            with con:
                con.executemany("INSERT OR REPLACE INTO pick VALUES(?,?,?,?,?,?,?,?)", picks)
                con.executemany("INSERT OR REPLACE INTO move VALUES(?,?,?,?,?,?,?,?,?)", moves)
                con.execute(
                    "UPDATE position SET status='done', nodes=?, child_nodes=?, seconds=?, "
                    "done_at=datetime('now') WHERE pos=?",
                    (args.nodes, args.child_nodes, round(time.time() - t0, 1), pos))
                if ply < args.max_ply:
                    if fics is not None:
                        expand_fics(con, fics, dual, line, ply, args.width)
                    else:
                        expand(con, line, ply, scores, args.width, clocks_of(args))
            done_here += 1
            queued = con.execute("SELECT COUNT(*) FROM position WHERE status='queued'").fetchone()[0]
            total = con.execute("SELECT COUNT(*) FROM position WHERE status='done'").fetchone()[0]
            print(f"{time.strftime('%H:%M:%S')}  {f'w{args.worker} ' if args.worker else ''}done {total:5d}  queue {queued:5d}  "
                  f"ply {ply}  {len(scores):3d} moves  {time.time() - t0:5.0f}s  "
                  f"{line or '(start)'}", flush=True)
    finally:
        engine.close()
        con.close()
    rate = (time.time() - started) / max(1, done_here)
    print(f"stopped: {done_here} positions this run, {rate:.0f}s each", flush=True)
    return 0


def expand(con: sqlite3.Connection, line: str, ply: int, scores: dict, width: int,
           clocks: Sequence[str] = DEFAULT_CLOCKS) -> None:
    """Queue each board's best `width` moves (even clock) and the best move of
    each other priority case searched. Priority favours main lines: rank costs
    0.75 ply."""
    chosen: dict[str, float] = {}
    by_board: dict[str, list[str]] = {}
    for tag in scores:
        by_board.setdefault(tag[0], []).append(tag)
    for tags in by_board.values():
        for clock in clocks:
            ranked = sorted(tags, key=lambda t: -mover_value(scores[t][clock], scores[t]["seat"]))
            for rank, tag in enumerate(ranked[: width if clock == "even" else 1]):
                chosen[tag] = min(chosen.get(tag, 99.0), rank)
    for tag, rank in chosen.items():
        enqueue(con, scores[tag]["after"], (line + " " + tag).strip(), ply + 1, ply + 1 + 0.75 * rank)


def expand_fics(con: sqlite3.Connection, fics: sqlite3.Connection, dual: DualBoard,
                line: str, ply: int, width: int) -> None:
    """Queue the `width` most-played FICS continuations, both boards together,
    most-played first. A position FICS never saw is a leaf."""
    a, b = (board.fen() for board in dual.boards)
    queued = 0
    for m in explore(fics, a, b)["moves"]:
        if queued >= width:
            break
        name = "A" if m["board"] in "aA" else "B"
        after = dual.copy()
        try:
            ply_done = after.push(name, m["san"])
        except Exception:
            continue  # the archive's few impossible edges (see project notes)
        enqueue(con, after, (line + " " + f"{name}:{ply_done.san}").strip(), ply + 1, -float(m["games"]))
        queued += 1


def rescore(score: float | None, team: str, old: float, new: float) -> float | None:
    """A stored A + C score read against another offset."""
    if score is None:
        return None
    sign = 1 if team == "AC" else -1
    raw = sign * to_q(score * 100) + old
    return round(sign * to_score(max(-1.0, min(1.0, raw - new))), 3)


def fill_both(con: sqlite3.Connection) -> int:
    """'both' rows for positions scored before that clock existed. No search
    is needed: A + C's bit-on search is the 'ahead' one and B + D's the
    'behind' one; only the offset they are read by changes, and it is
    (A+C on + B+D on)/2 = ahead + behind - even."""
    todo = con.execute("SELECT pos, fen FROM position WHERE status='done' AND pos NOT IN "
                       "(SELECT pos FROM pick WHERE clock='both')").fetchall()
    for pos, fen in todo:
        off = dict(con.execute("SELECT clock, offset FROM pick WHERE pos=?", (pos,)).fetchall())
        if not all(c in off for c in ("ahead", "even", "behind")):
            continue
        both = off["ahead"] + off["behind"] - off["even"]
        same = {"AC": "ahead", "BD": "behind"}
        for team, clock in same.items():
            row = con.execute("SELECT best, score, mate, pv FROM pick WHERE pos=? AND clock=? AND team=?",
                              (pos, clock, team)).fetchone()
            if row:
                con.execute("INSERT OR REPLACE INTO pick VALUES(?,?,?,?,?,?,?,?)",
                            (pos, "both", team, row[0], rescore(row[1], team, off[clock], both),
                             row[2], row[3], round(both, 4)))
        dual = DualBoard.from_dual_fen(fen)
        answers = {name: "AC" if answering_team(dual, which) == chess.WHITE else "BD"
                   for which, name in enumerate(BOARD_NAMES)}
        for move, seat, uci, clock, score, mate, pv, child in con.execute(
                "SELECT move, seat, uci, clock, score, mate, pv, child FROM move WHERE pos=?", (pos,)).fetchall():
            team = answers[move[0]]
            if clock == same[team]:
                con.execute("INSERT OR REPLACE INTO move VALUES(?,?,?,?,?,?,?,?,?)",
                            (pos, move, seat, uci, "both", rescore(score, team, off[clock], both), mate, pv, child))
    con.commit()
    return len(todo)


# ── Reading the book ────────────────────────────────────────────────────────


def show(args: argparse.Namespace) -> int:
    con = open_db(args.db)
    dual = DualBoard()
    for tag in (args.line or "").split():
        b, text = tag.split(":", 1)
        dual.push(b, text)
    pos = key_of(dual)
    status = con.execute("SELECT status FROM position WHERE pos=?", (pos,)).fetchone()
    print(f"{args.line or '(start)'}   {dual.dual_fen}")
    if not status or status[0] != "done":
        print("not in the book" + (" (queued)" if status else ""))
        return 1
    for clock, team, best, score, mate, pv in con.execute(
            "SELECT clock, team, best, score, mate, pv FROM pick WHERE pos=? ORDER BY clock, team", (pos,)):
        print(f"  pick {clock:6} {team}  {best:18}  {fmt(score, mate):>7}  {pv}")
    rows: dict[str, dict] = {}
    for move, seat, clock, score, mate, pv in con.execute(
            "SELECT move, seat, clock, score, mate, pv FROM move WHERE pos=?", (pos,)):
        r = rows.setdefault(move, {"seat": seat})
        r[clock] = (score, mate)
        if clock == "even":
            r["pv"] = pv
    # A book built without `--priority all` has only the one case.
    present = [c for c in CLOCKS if any(c in r for r in rows.values())]
    print(f"\n  {'move':12} " + " ".join(f"{c:>7}" for c in present) + "  pv (even)")
    for move, r in sorted(rows.items(),
                          key=lambda kv: (kv[0][0], -mover_value(kv[1].get("even", (None, None)),
                                                                 kv[1]["seat"]))):
        cells = " ".join(f"{fmt(*r[c]) if c in r else '—':>7}" for c in present)
        print(f"  {r['seat']} {move[2:]:10} " + cells + f"  {r.get('pv', '')}")
    return 0


def fmt(score, mate) -> str:
    """Lichess-style pawns: the chess evaluation that wins as often."""
    if mate is not None:
        return f"#{mate}"
    if score is None:
        return "—"
    q = max(-0.9999, min(0.9999, to_q(score * 100)))
    return f"{543.17 * math.atanh(q) / 100:+.2f}"


def stats(args: argparse.Namespace) -> int:
    con = open_db(args.db)
    for status, n, secs in con.execute(
            "SELECT status, COUNT(*), AVG(seconds) FROM position GROUP BY status"):
        print(f"{status:7} {n:6d}" + (f"   {secs:.0f}s a position" if secs else ""))
    for ply, n in con.execute("SELECT ply, COUNT(*) FROM position WHERE status='done' GROUP BY ply"):
        print(f"  ply {ply}: {n}")
    print(con.execute("SELECT COUNT(*) FROM move WHERE clock='even'").fetchone()[0], "moves scored")
    return 0


def push(args: argparse.Namespace) -> int:
    """Send finished positions to BughouseDB (python/twic-position-finder/
    bughousedb.py). Scores go as Hivemind's calibrated Q for A + C, which the
    stored engine-scale score converts back to exactly."""
    import json
    import os
    import urllib.request

    key = args.key or os.environ.get("BUGHOUSEDB_ADMIN_KEY", "")
    if not key:
        print("set --key or BUGHOUSEDB_ADMIN_KEY", file=sys.stderr)
        return 2
    con = open_db(args.db)
    fill_both(con)
    done = con.execute("SELECT pos, fen, nodes, child_nodes FROM position WHERE status='done' "
                       "ORDER BY done_at").fetchall()

    def q(score):
        return None if score is None else round(to_q(score * 100), 5)

    totals = {"added": 0, "skipped": 0, "errors": 0}
    for start in range(0, len(done), args.batch):
        batch = []
        for pos, fen, nodes, child_nodes in done[start:start + args.batch]:
            picks = [{"clock": c, "team": t, "best": b or "", "q": q(sc), "mate": m, "pv": pv or ""}
                     for c, t, b, sc, m, pv in con.execute(
                         "SELECT clock, team, best, score, mate, pv FROM pick WHERE pos=?", (pos,))]
            moves = [{"board": mv[0], "uci": u, "clock": c, "q": q(sc), "mate": m, "pv": pv or ""}
                     for mv, u, c, sc, m, pv in con.execute(
                         "SELECT move, uci, clock, score, mate, pv FROM move WHERE pos=?", (pos,))]
            batch.append({"fen": fen, "engine": "hivemind-native", "nodes": nodes,
                          "child_nodes": child_nodes, "picks": picks, "moves": moves})
        req = urllib.request.Request(
            args.url.rstrip("/") + "/api/bughousedb/import",
            data=json.dumps({"positions": batch, "replace": args.replace}).encode(),
            # Cloudflare turns away Python's default user agent.
            headers={"Content-Type": "application/json", "X-API-Key": key,
                     "User-Agent": "chess-auto-prep hivemind_book"}, method="POST")
        with urllib.request.urlopen(req, timeout=120) as resp:
            out = json.load(resp)
        totals["added"] += out["added"]
        totals["skipped"] += out["skipped"]
        totals["errors"] += len(out["errors"])
        for err in out["errors"]:
            print("  error:", err, file=sys.stderr)
        print(f"{start + len(batch):5d}/{len(done)}  added {totals['added']}  "
              f"already there {totals['skipped']}  errors {totals['errors']}", flush=True)
    return 0 if not totals["errors"] else 1


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--db", type=Path, default=book_file())
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run", help="search queued positions, one at a time")
    r.add_argument("--root", default="", help="start line, board-tagged: 'A:e4 B:d4'")
    r.add_argument("--nodes", type=int, default=1500, help="per search of the position itself")
    r.add_argument("--child-nodes", type=int, default=200, help="per search of each move")
    r.add_argument("--max-ply", type=int, default=10)
    r.add_argument("--follow", choices=("fics", "engine"), default="fics",
                   help="queue the most-played FICS moves, or the engine's best")
    r.add_argument("--width", type=int, default=4,
                   help="moves queued after each position (engine: per board)")
    r.add_argument("--priority", choices=("even", "all"), default="even",
                   help="which priority cases to search: nobody's (the default, "
                        "half the searches) or every case")
    r.add_argument("--workers", type=int, default=1,
                   help="builder processes sharing the queue; each engine uses about 5 cores")
    r.add_argument("--worker", type=int, default=0, help=argparse.SUPPRESS)
    s = sub.add_parser("show", help="print one position's table")
    s.add_argument("line", nargs="?", default="")
    sub.add_parser("stats")
    p = sub.add_parser("push", help="upload finished positions to BughouseDB")
    p.add_argument("--url", default="https://api.chessautoprep.com")
    p.add_argument("--key", default="", help="admin key (or BUGHOUSEDB_ADMIN_KEY)")
    p.add_argument("--batch", type=int, default=40)
    p.add_argument("--replace", action="store_true", help="overwrite positions already there")
    args = ap.parse_args(argv)
    return {"run": run, "show": show, "stats": stats, "push": push}[args.cmd](args)


if __name__ == "__main__":
    raise SystemExit(main())
