"""Replay the archive into the explorer's opening book.

One worker per archive year, each writing a partial book, then a single
merge pass.  The split is not just for speed: a node seen once in each of
twenty years is a twenty-game node, so pruning can only happen *after* the
years are merged, and a worker that pruned locally would throw that away.

Replay uses `DualBoard` from the bughouse MCP server -- the same two-board
model Bughouse Lab drives, including the rule that makes bughouse bughouse:
a captured piece goes to the *partner board's* reserve, and a promoted piece
reverts to a pawn when it is captured.  Measured on the 2017 archive, it
replays 99.97% of real FICS games without complaint.
"""

from __future__ import annotations

import multiprocessing as mp
import os
import sqlite3
import sys
import time
from collections import defaultdict
from pathlib import Path

from .bpgn import iter_games, open_bpgn
from .paths import REPO, book_path, corpus_dir
from .poskey import dual_key_fen, position_key
from .schema import CREATE_SQL, MERGE_SQL, SCHEMA_VERSION

sys.path.insert(0, str(REPO / "tools" / "mcp"))

#: How deep to index, counted in half-moves across *both* boards.  The
#: explorer runs dry around ply 11 on the full corpus, so 16 leaves headroom
#: without paying for the singleton tail.
DEFAULT_MAX_PLY = 16

#: Games buffered before a worker flushes to its partial book.  Bounds a
#: worker to a few hundred MB on the 390k-game years.
FLUSH_EVERY = 40_000


def _connect(path: Path) -> sqlite3.Connection:
    con = sqlite3.connect(path)
    con.executescript(CREATE_SQL)
    con.execute("PRAGMA journal_mode=OFF")
    con.execute("PRAGMA synchronous=OFF")
    return con


def _flush(con: sqlite3.Connection, edges: dict) -> None:
    if not edges:
        return
    con.executemany(
        "INSERT INTO edge VALUES(?,?,?,?,?,?,?,?,?,?,?,?) "
        "ON CONFLICT(pos, move) DO UPDATE SET "
        "  games=edge.games+excluded.games, team_a=edge.team_a+excluded.team_a,"
        "  team_b=edge.team_b+excluded.team_b, draws=edge.draws+excluded.draws,"
        "  unknown=edge.unknown+excluded.unknown,"
        "  elo_sum=edge.elo_sum+excluded.elo_sum, elo_n=edge.elo_n+excluded.elo_n,"
        "  top_game=CASE WHEN excluded.max_elo > edge.max_elo"
        "                THEN excluded.top_game ELSE edge.top_game END,"
        "  max_elo=MAX(edge.max_elo, excluded.max_elo),"
        "  last_year=MAX(edge.last_year, excluded.last_year)",
        [(pos, move, *vals) for (pos, move), vals in edges.items()],
    )
    con.commit()
    edges.clear()


def index_year(args) -> tuple[str, int, int, int, float]:
    """Replay one archive file into its own partial book."""
    source, partial, max_ply, min_elo = args
    from bughouse.board import DualBoard  # noqa: PLC0415 -- worker-local import

    if partial.exists():
        partial.unlink()
    con = _connect(partial)
    edges: dict[tuple[int, str], list[int]] = defaultdict(
        lambda: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
    )
    seen = used = failed = 0
    started = time.time()
    for game in iter_games(open_bpgn(source)):
        seen += 1
        if not game.moves:
            continue
        elo = game.avg_elo
        if min_elo and elo < min_elo:
            continue
        result = game.result
        year, game_no = game.year, game.game_no
        board = DualBoard()
        try:
            for which, san in game.moves[:max_ply]:
                key = position_key(
                    dual_key_fen(board.board("A").fen(), board.board("B").fen())
                )
                # Play it first, count it second.  A game whose record starts
                # mid-play -- an adjournment resumed, a truncated dump -- has
                # an illegal first move, and counting before pushing banked
                # that move against the *starting* position before the push
                # rejected it.  It put 339 impossible continuations on the
                # opening node (3,174 games, 0.09%): `1A. e6`, `1A. Nf6`,
                # black replies filed as White's first move.
                board.push(which, san)
                row = edges[(key, f"{which}:{san}")]
                row[0] += 1
                if result == "1-0":
                    row[1] += 1
                elif result == "0-1":
                    row[2] += 1
                elif result == "1/2-1/2":
                    row[3] += 1
                else:
                    row[4] += 1
                if elo:
                    row[5] += elo
                    row[6] += 1
                if elo > row[7]:
                    row[7] = elo
                    row[9] = game_no
                row[8] = max(row[8], year)
            used += 1
        except Exception:  # noqa: BLE001 -- a corrupt game must not stop a year
            failed += 1
        if seen % FLUSH_EVERY == 0:
            _flush(con, edges)
    _flush(con, edges)
    con.close()
    return (source.name, seen, used, failed, time.time() - started)


def build(
    years: list[int] | None,
    max_ply: int,
    min_games: int,
    min_elo: int,
    jobs: int,
) -> int:
    sources = sorted(corpus_dir().glob("export*.bpgn.bz2"))
    if years:
        sources = [p for p in sources if int(p.name[6:10]) in years]
    if not sources:
        raise SystemExit(
            f"no archive files in {corpus_dir()} -- run "
            "`python3 -m bughouse_db fetch` first"
        )
    out = book_path()
    out.parent.mkdir(parents=True, exist_ok=True)
    scratch = out.parent / "partials"
    scratch.mkdir(exist_ok=True)

    tasks = [
        (src, scratch / f"{src.name}.db", max_ply, min_elo) for src in sources
    ]
    jobs = max(1, min(jobs or os.cpu_count() or 1, len(tasks)))
    print(
        f"indexing {len(tasks)} year(s) to ply {max_ply} on {jobs} core(s)"
        + (f", Elo >= {min_elo}" if min_elo else "")
    )
    started = time.time()
    totals = [0, 0, 0]
    with mp.Pool(jobs) as pool:
        for name, seen, used, failed, secs in pool.imap_unordered(index_year, tasks):
            totals[0] += seen
            totals[1] += used
            totals[2] += failed
            rate = seen / secs if secs else 0
            print(
                f"  {name}: {seen:>7} games, {failed} unreplayable "
                f"({secs:.0f}s, {rate:.0f}/s)"
            )
    print(
        f"replayed {totals[1]}/{totals[0]} games "
        f"({totals[2]} unreplayable) in {time.time() - started:.0f}s"
    )

    print("merging…")
    building = out.with_name(out.name + ".building")
    building.unlink(missing_ok=True)
    con = _connect(building)
    for _, partial, _, _ in tasks:
        if not partial.exists():
            continue
        con.execute("ATTACH ? AS part", (str(partial),))
        con.execute(MERGE_SQL)
        con.commit()
        con.execute("DETACH part")

    print("aggregating nodes…")
    con.execute(
        "INSERT INTO node "
        "SELECT pos, SUM(games), SUM(team_a), SUM(team_b), SUM(draws), "
        "       SUM(unknown), COUNT(*) FROM edge GROUP BY pos"
    )
    raw_edges = con.execute("SELECT COUNT(*) FROM edge").fetchone()[0]
    if min_games > 1:
        print(f"pruning continuations under {min_games} games…")
        con.execute("DELETE FROM edge WHERE games < ?", (min_games,))
        # Prune a position on its *own* total, never on whether any single
        # continuation survived.  A position reached by five games that each
        # branched differently keeps all five -- deleting it because no edge
        # cleared the bar is what would make the explorer understate itself.
        con.execute("DELETE FROM node WHERE games < ?", (min_games,))
        con.execute(
            "UPDATE node SET moves = "
            "(SELECT COUNT(*) FROM edge WHERE edge.pos = node.pos)"
        )
    kept_edges = con.execute("SELECT COUNT(*) FROM edge").fetchone()[0]
    nodes = con.execute("SELECT COUNT(*) FROM node").fetchone()[0]
    for key, value in {
        "schema_version": SCHEMA_VERSION,
        "max_ply": max_ply,
        "min_games": min_games,
        "min_elo": min_elo,
        "games": totals[1],
        "years": ",".join(sorted(p.name[6:10] for p in sources)),
        "built_at": int(time.time()),
    }.items():
        con.execute("INSERT OR REPLACE INTO meta VALUES(?,?)", (key, str(value)))
    con.commit()
    con.execute("VACUUM")
    con.close()
    # Keep the previous, usable book until the new database has completed and
    # closed successfully. os.replace is one same-filesystem commit.
    building.replace(out)
    for _, partial, _, _ in tasks:
        partial.unlink(missing_ok=True)
    scratch.rmdir()
    size = out.stat().st_size / 1e6
    print(
        f"book: {nodes} positions, {kept_edges} continuations "
        f"(of {raw_edges} seen), {size:.1f} MB -> {out}"
    )
    return 0
