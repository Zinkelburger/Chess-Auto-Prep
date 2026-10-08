"""Mine bughouse mate puzzles from the FICS archive.

A puzzle is one board of a real game where the side to move has a forced
mate *on that board alone*. The board's reserves are frozen where they stand:
nothing arrives from the partner, and a capture goes to the partner rather
than back into the capturer's hand. Fairy-Stockfish's `bughouse` variant
plays one board under exactly that rule, so it both finds and checks them.

The rules a line must pass, in the order they are checked:

  * a short forced mate shows up in a cheap scan of the position;
  * a deep search confirms it, and at every solver move but the last the
    second-best move is *not* a forced mate, so there is one answer;
  * every solver move but the last gives check. In real bughouse a quiet
    move lets the defender sit and wait for help from their partner, so only
    a line of checks is really forced;
  * the final move may be any mate, and all of them are accepted.

`export_web` turns verified puzzles into the JSON the website's
`/bughouse-puzzles` page loads: SAN for the line, legal moves at each solver
step (for the board's move dots), and the full two-board position at the
puzzle so the page can open it in Bughouse Lab.
"""

from __future__ import annotations

import json
import multiprocessing as mp
import os
import random
import re
import subprocess
import sys
from dataclasses import asdict, dataclass, field
from pathlib import Path

import chess
from chess.variant import CrazyhouseBoard

from .bpgn import BpgnGame, iter_games, open_bpgn
from .paths import REPO, corpus_dir

SCAN_NODES = 40_000
VERIFY_NODES = 1_500_000
MAX_MATE = 5
MIN_MOVE = 6  # skip each board's first five moves: no reserves yet

WEB_OUT = REPO / "python/twic-position-finder/frontend/public/bughouse-puzzles.json"


@dataclass
class Candidate:
    """A position where the scan saw a short forced mate."""

    fen: str
    dual: str
    board: str
    ply: int
    last: str | None
    played: str | None
    game: int
    date: str
    tc: str
    white: str
    black: str
    welo: int
    belo: int
    line: list[str] = field(default_factory=list)
    mates: list[str] = field(default_factory=list)


class FairyEngine:
    """One Fairy-Stockfish process in its single-board `bughouse` variant."""

    def __init__(self, path: str) -> None:
        self.proc = subprocess.Popen(
            [path], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1
        )
        self._send("uci")
        self._until("uciok")
        for option in ("UCI_Variant value bughouse", "Threads value 1", "Hash value 32"):
            self._send(f"setoption name {option}")
        self._send("isready")
        self._until("readyok")

    def _send(self, line: str) -> None:
        assert self.proc.stdin
        self.proc.stdin.write(line + "\n")

    def _until(self, prefix: str) -> list[str]:
        assert self.proc.stdout
        lines = []
        while True:
            line = self.proc.stdout.readline()
            if not line:
                raise RuntimeError("Fairy-Stockfish exited")
            lines.append(line.strip())
            if line.startswith(prefix):
                return lines

    def search(self, fen: str, nodes: int, multipv: int = 1) -> tuple[dict[int, tuple[str, int, list[str]]], str]:
        """`{rank: (kind, value, pv)}` from the last info line per rank, and the best move."""
        self._send(f"setoption name MultiPV value {multipv}")
        self._send(f"position fen {fen}")
        self._send(f"go nodes {nodes}")
        lines = self._until("bestmove")
        ranks: dict[int, tuple[str, int, list[str]]] = {}
        for line in lines:
            if not line.startswith("info") or " pv " not in line or " score " not in line:
                continue
            rank = re.search(r" multipv (\d+)", line)
            score = re.search(r" score (cp|mate) (-?\d+)", line)
            if score:
                ranks[int(rank.group(1)) if rank else 1] = (
                    score.group(1), int(score.group(2)), line.split(" pv ")[1].split()
                )
        return ranks, lines[-1].split()[1]

    def new_game(self) -> None:
        self._send("ucinewgame")

    def close(self) -> None:
        self._send("quit")
        self.proc.wait(timeout=5)


# ── Frozen-reserve moves ──────────────────────────────────────────────


def frozen_push(board: CrazyhouseBoard, uci: str) -> str:
    """Play `uci` with the reserves frozen; return its SAN.

    python-chess plays crazyhouse, which banks a capture in the capturer's
    own pocket. Here the capture leaves for the partner board, so the pockets
    are put back as they were, less the piece a drop used.
    """
    move = chess.Move.from_uci(uci)
    pockets = [board.pockets[chess.WHITE].copy(), board.pockets[chess.BLACK].copy()]
    mover = board.turn
    text = board.san(move)
    board.push(move)
    board.pockets[chess.WHITE], board.pockets[chess.BLACK] = pockets
    if move.drop:
        board.pockets[mover].remove(move.drop)
    return text


def mating_moves(board: CrazyhouseBoard) -> list[str]:
    out = []
    for move in board.legal_moves:
        after = board.copy(stack=False)
        frozen_push(after, move.uci())
        if after.is_checkmate():
            out.append(move.uci())
    return out


# ── Scan ──────────────────────────────────────────────────────────────

_ENGINE: FairyEngine | None = None


def _init_worker(path: str) -> None:
    global _ENGINE
    _ENGINE = FairyEngine(path)


def _elo(tags: dict[str, str], key: str) -> int:
    try:
        return int(tags.get(key, "0"))
    except ValueError:
        return 0


def scan_game(game: BpgnGame) -> list[Candidate]:
    """The first position of each run of short forced mates, per board and side."""
    sys.path.insert(0, str(REPO / "tools/mcp"))
    from bughouse.board import DualBoard  # noqa: PLC0415 -- worker-local import

    assert _ENGINE
    dual = DualBoard()
    out: list[Candidate] = []
    in_run: dict[tuple[str, bool], bool] = {}
    try:
        for i, (which, san) in enumerate(game.moves):
            name = which.upper()
            ply = dual.push(which, san)
            board = dual.board(name)
            if board.is_game_over() or board.fullmove_number < MIN_MOVE:
                continue
            ranks, _ = _ENGINE.search(board.fen(), SCAN_NODES)
            best = ranks.get(1)
            mate = bool(best and best[0] == "mate" and 0 < best[1] <= MAX_MATE)
            key = (name, board.turn)
            if mate and not in_run.get(key):
                played = next((s for w, s in game.moves[i + 1:] if w.upper() == name), None)
                tags = game.tags
                out.append(Candidate(
                    fen=board.fen(), dual=dual.dual_fen, board=name, ply=i, last=ply.uci,
                    played=played, game=game.game_no, date=tags.get("Date", ""),
                    tc=tags.get("TimeControl", ""), white=tags.get(f"White{name}", ""),
                    black=tags.get(f"Black{name}", ""), welo=_elo(tags, f"White{name}Elo"),
                    belo=_elo(tags, f"Black{name}Elo"),
                ))
            in_run[key] = mate
    except Exception:  # noqa: BLE001 -- a corrupt record must not stop the run
        pass
    return out


# ── Verify ────────────────────────────────────────────────────────────


def solve(engine: FairyEngine, fen: str) -> tuple[list[str], list[str]] | None:
    """The unique all-checks mating line from `fen` and the accepted final moves."""
    engine.new_game()
    board = CrazyhouseBoard(fen)
    line: list[str] = []
    while len(line) < 2 * MAX_MATE:
        ranks, _ = engine.search(board.fen(), VERIFY_NODES, multipv=2)
        best = ranks.get(1)
        if not best or best[0] != "mate" or best[1] <= 0:
            return None
        move = best[2][0]
        if best[1] == 1:
            mates = mating_moves(board)
            return (line + [move], mates) if move in mates else None
        second = ranks.get(2)
        if second and second[0] == "mate" and second[1] > 0:
            return None
        if not board.gives_check(chess.Move.from_uci(move)):
            return None
        frozen_push(board, move)
        _, reply = engine.search(board.fen(), VERIFY_NODES // 2)
        if reply in ("(none)", "0000"):
            return None
        frozen_push(board, reply)
        line += [move, reply]
    return None


def _verify(candidate: Candidate) -> Candidate | None:
    assert _ENGINE
    try:
        solved = solve(_ENGINE, candidate.fen)
    except Exception:  # noqa: BLE001
        return None
    if not solved:
        return None
    candidate.line, candidate.mates = solved
    return candidate


# ── Export ────────────────────────────────────────────────────────────


def _strip(san: str) -> str:
    return san.rstrip("+#")


def web_puzzle(c: Candidate) -> dict | None:
    """One puzzle as the page loads it, or None if the line does not replay to mate."""
    board = CrazyhouseBoard(c.fen)
    legal: list[str] = []
    sans: list[str] = []
    for i, uci in enumerate(c.line):
        if i % 2 == 0:
            legal.append(" ".join(m.uci() for m in board.legal_moves))
        sans.append(frozen_push(board, uci))
    if not board.is_checkmate():
        return None
    start = CrazyhouseBoard(c.fen)
    first = _strip(start.san(chess.Move.from_uci(c.line[0])))
    accepted = {first} if len(c.line) > 1 else {_strip(start.san(chess.Move.from_uci(m))) for m in c.mates}
    return {
        "id": f"{c.game}-{c.board}-{c.ply}", "fen": c.fen, "dual": c.dual, "board": c.board,
        "last": c.last, "mate": (len(c.line) + 1) // 2, "line": c.line, "san": sans,
        "legal": legal, "mates": c.mates, "played": c.played,
        "found": c.played is not None and _strip(c.played) in accepted,
        "game": c.game, "date": c.date, "tc": c.tc,
        "white": c.white, "black": c.black, "welo": c.welo, "belo": c.belo,
    }


def export_web(candidates: list[Candidate], out: Path, source: str) -> int:
    puzzles = [p for p in (web_puzzle(c) for c in candidates) if p]
    # A fixed shuffle so neighbouring puzzles come from different games, with
    # the longer mates first and the mate-in-ones after them.
    random.Random(7).shuffle(puzzles)
    puzzles.sort(key=lambda p: p["mate"] == 1)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps({"version": 1, "source": source, "puzzles": puzzles},
                              separators=(",", ":")) + "\n")
    return len(puzzles)


# ── Run ───────────────────────────────────────────────────────────────


def _engine_path(explicit: str | None) -> str:
    path = explicit or os.environ.get("FAIRY_STOCKFISH")
    if not path or not Path(path).exists():
        raise SystemExit(
            "Fairy-Stockfish not found. Download a release binary from "
            "https://github.com/fairy-stockfish/Fairy-Stockfish/releases and pass "
            "--engine PATH or set FAIRY_STOCKFISH."
        )
    return path


def run(year: int, games: int, min_elo: int, jobs: int, engine: str | None,
        out: Path, raw_out: Path | None) -> int:
    path = _engine_path(engine)
    source_file = corpus_dir() / f"export{year}.bpgn.bz2"
    if not source_file.exists():
        raise SystemExit(f"{source_file} is missing. Run `python3 -m bughouse_db fetch --only {year}`.")
    picked: list[BpgnGame] = []
    for game in iter_games(open_bpgn(source_file)):
        elos = game.elos()
        if (game.rated and len(game.moves) > 30 and game.avg_elo >= min_elo
                and min(elos) >= min_elo - 300):
            picked.append(game)
            if len(picked) >= games:
                break
    print(f"{len(picked)} games from {year}", file=sys.stderr, flush=True)

    with mp.Pool(jobs or max(1, (os.cpu_count() or 2) - 1), initializer=_init_worker,
                 initargs=(path,)) as pool:
        found: list[Candidate] = []
        for n, batch in enumerate(pool.imap_unordered(scan_game, picked, chunksize=2), 1):
            found.extend(batch)
            if n % 100 == 0:
                print(f"scanned {n}/{len(picked)} games, {len(found)} candidates",
                      file=sys.stderr, flush=True)
        seen: set[str] = set()
        unique = []
        for c in found:
            key = " ".join(c.fen.split()[:3])
            if key not in seen:
                seen.add(key)
                unique.append(c)
        print(f"verifying {len(unique)} candidates", file=sys.stderr, flush=True)
        verified = [c for c in pool.imap_unordered(_verify, unique) if c]

    if raw_out:
        raw_out.write_text(json.dumps([asdict(c) for c in verified]) + "\n")
    source = (f"{len(picked)} rated FICS bughouse games from {year} with an average rating of "
              f"{min_elo} or more, from the bughouse-db.org archive")
    n = export_web(verified, out, source)
    print(f"{n} puzzles written to {out}", file=sys.stderr)
    return 0
