"""Mine bughouse puzzles from the FICS archive.

A puzzle is one board of a real game where the side to move has a forced
win *on that board alone*. The board's reserves are frozen where they stand:
nothing arrives from the partner, and a capture goes to the partner rather
than back into the capturer's hand (`frozen.py`). Fairy-Stockfish's `bughouse`
variant plays one board under exactly that rule, so it both finds and checks
them. The rules follow lichess-puzzler's generator where bughouse allows it.

Scan. Every position from each board's sixth move gets a cheap search
(`SCAN_NODES`). Its score, from the side to move, is kept per board so the
next position knows `prev_score` = the negated score one ply earlier on that
board (`Cp(20)` for the first position looked at, as in lila). A position
with at least two legal moves becomes a candidate when

  * mate: the scan sees a forced mate in at most `MAX_MATE`, and the previous
    position for the same side on that board did not (so a run of mates
    yields its first position only);
  * advantage: the score is at least 200 cp (a longer mate counts) and
    `win_chances(score) > win_chances(prev_score) + 0.6`, unless
    `prev_score > 300 cp`. lila also skips positions where the winner is
    already up in material; material means little in bughouse, so that rule
    is dropped and the theme tagger measures material instead.

Verify. Candidates are deduplicated on placement, side and pockets, then each
one is solved with deep searches (`VERIFY_NODES`, two principal variations):

  * mate: the best move must be a forced mate; at every solver move but the
    last the second-best move is *not* a forced mate (one answer) and the
    move gives check: a quiet move lets the defender sit and wait for help
    from their partner, so only a line of checks is really forced. The final
    move may be any mate, and all mates are accepted;
  * advantage (lila's `cook_advantage`): at each solver move the attack must
    be valid, i.e. there is no alternative, or the best move is a sound mate
    in one, or `win_chances(best) > win_chances(second) + 0.7`; an invalid
    attack ends the line there. A valid best move below 200 cp busts the
    puzzle, as does a twofold repetition. The defender answers with the engine
    best at half the nodes. At most `MAX_ADVANTAGE` solver moves are searched.
    The line is then trimmed as lila trims it: trailing solver moves with no
    alternative are dropped (and the line always ends on a solver move). An
    advantage line that ends in checkmate and also meets the mate rules above
    is a mate puzzle; otherwise it needs at least two solver moves and stays
    an advantage puzzle even if its last move happens to mate (only the
    line's final move is then accepted).

Mate in one. Lila keeps mate-in-one only from its best games. Here a
mate-in-one is kept only when the player missed it in the game, or when the
mating move is a drop and the position has at least 20 legal moves
(`keep_mate_in_one`).

Themes come from `themes.py`. Difficulty is a static proxy (`rate_difficulty`),
since FICS games carry no puzzle ratings: points = solver moves, plus one each
when the first move is a drop or the line is a sacrifice, when the player
missed the first move in the game, and when the start is busy (a mate with
three or more checking moves to choose from, or an advantage whose first
move is quiet: no check and no capture). 1-2 points is Easy (1), 3-4 Medium
(2), 5 or more Hard (3).

Export (`export_web`) writes a directory for static serving (`WEB_OUT`):
`index.json` with one short entry per puzzle, and shards of `SHARD_SIZE` full
records named `sNN-<first 10 hex of the sha256 of the file>.json` so they
can be cached immutably. Puzzles are shuffled with a fixed seed so neighbours
come from different games; the page filters by kind, length, theme and
difficulty. Stale shard files in the directory are removed first. `--raw-out`
keeps the verified candidates, and `--from-raw` re-exports them without the
engine, e.g. after a change to the policy, tagger or layout.
"""

from __future__ import annotations

import datetime as dt
import hashlib
import json
import math
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
from .frozen import frozen_push, mating_moves, position_key, replay
from .paths import REPO, corpus_dir
from .themes import tag_themes

SCAN_NODES = 40_000
VERIFY_NODES = 1_500_000
MAX_MATE = 5
MAX_ADVANTAGE = 5
MIN_MOVE = 6  # skip each board's first five moves: no reserves yet
KINDS = ("mate", "advantage")
SHARD_SIZE = 50

WEB_OUT = REPO / "python/twic-position-finder/frontend/public/bughouse-puzzles"

Score = tuple[str, int]  # ("cp", 35) or ("mate", 3), from one side's point of view


@dataclass
class Candidate:
    """A position the scan flagged, and once verified, its solution."""

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
    kind: str = "mate"
    prev: str | None = None  # the board before the opponent's last move
    cp: int | None = None  # final eval of an advantage line (None for a mate score)
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


# ── Scores ────────────────────────────────────────────────────────────


def win_chances(score: Score) -> float:
    """lila's winning chances, -1..1: a mate is certain, else a logistic of the centipawns."""
    kind, value = score
    if kind == "mate":
        return 1.0 if value > 0 else -1.0
    return 2 / (1 + math.exp(-0.00368208 * value)) - 1


def negate(score: Score) -> Score:
    return (score[0], -score[1])


def as_cp(score: Score) -> int:
    """Centipawns for comparison; a mate counts as beyond any centipawn score."""
    kind, value = score
    if kind == "cp":
        return value
    return 100_000 - value if value > 0 else -100_000 - value


def is_mate(score: Score | None) -> bool:
    return bool(score and score[0] == "mate" and score[1] > 0)


# ── Scan ──────────────────────────────────────────────────────────────

_ENGINE: FairyEngine | None = None
_KINDS: frozenset[str] = frozenset(KINDS)


def _init_worker(path: str, kinds: frozenset[str] = frozenset(KINDS)) -> None:
    global _ENGINE, _KINDS
    _ENGINE = FairyEngine(path)
    _KINDS = kinds


def _elo(tags: dict[str, str], key: str) -> int:
    try:
        return int(tags.get(key, "0"))
    except ValueError:
        return 0


def wants_advantage(score: Score, prev_score: Score) -> bool:
    """lila's advantage trigger: a jump to a clearly winning score."""
    return (as_cp(score) >= 200 and win_chances(score) > win_chances(prev_score) + 0.6
            and not as_cp(prev_score) > 300)


def scan_game(game: BpgnGame) -> list[Candidate]:
    """Positions the scan flags on either board: first position of a mate run, or an eval jump."""
    sys.path.insert(0, str(REPO / "tools/mcp"))
    from bughouse.board import DualBoard  # noqa: PLC0415 -- worker-local import

    assert _ENGINE
    dual = DualBoard()
    out: list[Candidate] = []
    in_run: dict[tuple[str, bool], bool] = {}
    last_score: dict[str, Score] = {}
    try:
        for i, (which, san) in enumerate(game.moves):
            name = which.upper()
            prev_fen = dual.board(name).fen()
            ply = dual.push(which, san)
            board = dual.board(name)
            if board.is_game_over() or board.fullmove_number < MIN_MOVE:
                continue
            ranks, _ = _ENGINE.search(board.fen(), SCAN_NODES)
            best = ranks.get(1)
            if not best:
                continue
            score: Score = (best[0], best[1])
            prev_score = negate(last_score[name]) if name in last_score else ("cp", 20)
            last_score[name] = score
            mate = score[0] == "mate" and 0 < score[1] <= MAX_MATE
            key = (name, board.turn)
            kind = None
            if board.legal_moves.count() >= 2:
                if mate:
                    if not in_run.get(key) and "mate" in _KINDS:
                        kind = "mate"
                elif "advantage" in _KINDS and wants_advantage(score, prev_score):
                    kind = "advantage"
            in_run[key] = mate
            if kind:
                played = next((s for w, s in game.moves[i + 1:] if w.upper() == name), None)
                tags = game.tags
                out.append(Candidate(
                    fen=board.fen(), dual=dual.dual_fen, board=name, ply=i, last=ply.uci,
                    played=played, game=game.game_no, date=tags.get("Date", ""),
                    tc=tags.get("TimeControl", ""), white=tags.get(f"White{name}", ""),
                    black=tags.get(f"Black{name}", ""), welo=_elo(tags, f"White{name}Elo"),
                    belo=_elo(tags, f"Black{name}Elo"), kind=kind, prev=prev_fen,
                ))
    except Exception:  # noqa: BLE001 -- a corrupt record must not stop the run
        pass
    return out


# ── Verify ────────────────────────────────────────────────────────────


@dataclass
class Solution:
    kind: str
    line: list[str]
    mates: list[str] = field(default_factory=list)
    cp: int | None = None


def _rank_score(rank: tuple[str, int, list[str]] | None) -> Score | None:
    return (rank[0], rank[1]) if rank else None


def solve_mate(engine, fen: str) -> Solution | None:
    """The unique all-checks mating line from `fen` and the accepted final moves."""
    engine.new_game()
    board = CrazyhouseBoard(fen)
    line: list[str] = []
    while len(line) < 2 * MAX_MATE:
        ranks, _ = engine.search(board.fen(), VERIFY_NODES, multipv=2)
        best = ranks.get(1)
        if not best or not is_mate(_rank_score(best)):
            return None
        move = best[2][0]
        if best[1] == 1:
            mates = mating_moves(board)
            return Solution("mate", line + [move], mates) if move in mates else None
        if is_mate(_rank_score(ranks.get(2))):
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


def is_valid_mate_in_one(engine, board: CrazyhouseBoard, best: Score, second: Score | None) -> bool:
    """lila: a mate in one is a fair puzzle unless a non-mating move also wins clearly."""
    if best != ("mate", 1):
        return False
    threshold = 0.6
    if second is None or win_chances(second) <= threshold:
        return True
    if second == ("mate", 1):
        mates = len(mating_moves(board))
        ranks, _ = engine.search(board.fen(), VERIFY_NODES, multipv=mates + 1)
        last = _rank_score(ranks.get(max(ranks))) if ranks else None
        return not (last and last != ("mate", 1) and win_chances(last) > threshold)
    return False


def is_valid_attack(engine, board: CrazyhouseBoard, best: Score, second: Score | None) -> bool:
    """lila: the best move is the only continuation worth the name."""
    return (second is None or is_valid_mate_in_one(engine, board, best, second)
            or win_chances(best) > win_chances(second) + 0.7)


@dataclass
class _Step:
    move: str
    best: Score
    second: Score | None
    check: bool


def solve_advantage(engine, fen: str) -> Solution | None:
    """lila's `cook_advantage` with its trimming, on one frozen bughouse board."""
    engine.new_game()
    board = CrazyhouseBoard(fen)
    seen = {position_key(board)}
    steps: list[_Step] = []
    replies: list[str] = []
    while len(steps) < MAX_ADVANTAGE:
        ranks, _ = engine.search(board.fen(), VERIFY_NODES, multipv=2)
        rank = ranks.get(1)
        if not rank:
            return None
        best, second = _rank_score(rank), _rank_score(ranks.get(2))
        assert best
        if not is_valid_attack(engine, board, best, second):
            break
        if as_cp(best) < 200:
            return None
        move = rank[2][0]
        steps.append(_Step(move, best, second, board.gives_check(chess.Move.from_uci(move))))
        frozen_push(board, move)
        if board.is_game_over():
            break
        if position_key(board) in seen:
            return None
        seen.add(position_key(board))
        _, reply = engine.search(board.fen(), VERIFY_NODES // 2)
        if reply in ("(none)", "0000"):
            break
        frozen_push(board, reply)
        if position_key(board) in seen:
            return None
        seen.add(position_key(board))
        replies.append(reply)
    while steps and steps[-1].second is None:
        steps.pop()
    if not steps:
        return None
    line = [steps[0].move]
    for step, reply in zip(steps[1:], replies):
        line += [reply, step.move]
    final = replay(fen, line)[-1]
    if (final.is_checkmate() and len(steps) <= MAX_MATE
            and all(s.check and not is_mate(s.second) for s in steps[:-1])):
        return Solution("mate", line, mating_moves(replay(fen, line)[-2]))
    if len(steps) < 2:
        return None
    last = steps[-1].best
    return Solution("advantage", line, [], last[1] if last[0] == "cp" else None)


def _verify(candidate: Candidate) -> Candidate | None:
    assert _ENGINE
    try:
        solver = solve_mate if candidate.kind == "mate" else solve_advantage
        solved = solver(_ENGINE, candidate.fen)
    except Exception:  # noqa: BLE001
        return None
    if not solved:
        return None
    candidate.kind, candidate.line, candidate.mates, candidate.cp = (
        solved.kind, solved.line, solved.mates, solved.cp)
    return candidate


# ── Policy ────────────────────────────────────────────────────────────


def keep_mate_in_one(found: bool, drop: bool, legal: int) -> bool:
    """A mate in one stays only if the player missed it, or it is a drop in a busy position."""
    return not found or (drop and legal >= 20)


def rate_difficulty(kind: str, moves: int, themes: list[str], found: bool,
                    start: CrazyhouseBoard, first: str) -> int:
    """1 Easy, 2 Medium, 3 Hard; see the module docstring."""
    first_move = chess.Move.from_uci(first)
    points = moves
    if first_move.drop or "sacrifice" in themes:
        points += 1
    if not found:
        points += 1
    if kind == "mate":
        checks = sum(1 for m in start.legal_moves if start.gives_check(m))
        if checks >= 3:
            points += 1
    elif not start.gives_check(first_move) and not start.is_capture(first_move):
        points += 1
    return 1 if points <= 2 else 2 if points <= 4 else 3


# ── Export ────────────────────────────────────────────────────────────


def _strip(san: str) -> str:
    return san.rstrip("+#")


def _san(board: CrazyhouseBoard, uci: str) -> str:
    return frozen_push(board.copy(stack=False), uci)


def web_puzzle(c: Candidate) -> dict | None:
    """One full puzzle record, or None if the line does not replay or the policy rejects it."""
    board = CrazyhouseBoard(c.fen)
    legal: list[str] = []
    sans: list[str] = []
    for i, uci in enumerate(c.line):
        if i % 2 == 0:
            legal.append(" ".join(m.uci() for m in board.legal_moves))
        sans.append(frozen_push(board, uci))
    mate = c.kind == "mate"
    if mate and not board.is_checkmate():
        return None
    moves = (len(c.line) + 1) // 2
    start = CrazyhouseBoard(c.fen)
    first = _strip(sans[0])
    accepted = {first} if len(c.line) > 1 else {_strip(_san(start, m)) for m in c.mates}
    found = c.played is not None and _strip(c.played) in accepted
    if mate and moves == 1 and not keep_mate_in_one(found, "@" in c.line[0], len(legal[0].split())):
        return None
    themes = tag_themes(c.fen, c.line, c.cp)
    return {
        "id": f"{c.game}-{c.board}-{c.ply}", "kind": c.kind, "fen": c.fen, "prev": c.prev,
        "dual": c.dual, "board": c.board, "last": c.last, "mate": moves if mate else 0,
        "moves": moves, "cp": c.cp, "themes": themes,
        "difficulty": rate_difficulty(c.kind, moves, themes, found, start, c.line[0]),
        "line": c.line, "san": sans, "legal": legal, "mates": c.mates, "played": c.played,
        "found": found, "game": c.game, "date": c.date, "tc": c.tc,
        "white": c.white, "black": c.black, "welo": c.welo, "belo": c.belo,
    }


def index_entry(p: dict, shard: int) -> dict:
    return {
        "id": p["id"], "kind": p["kind"], "mate": p["mate"], "moves": p["moves"],
        "themes": p["themes"], "difficulty": p["difficulty"], "side": p["fen"].split()[1],
        "board": p["board"], "found": p["found"], "shard": shard,
    }


def export_web(candidates: list[Candidate], out: Path, source: str) -> int:
    puzzles = [p for p in (web_puzzle(c) for c in candidates) if p]
    # A fixed shuffle so neighbouring puzzles come from different games.
    random.Random(7).shuffle(puzzles)
    out.mkdir(parents=True, exist_ok=True)
    for stale in out.glob("s[0-9][0-9]*.json"):
        stale.unlink()
    shards: list[str] = []
    entries: list[dict] = []
    for n in range(0, len(puzzles), SHARD_SIZE):
        chunk = puzzles[n:n + SHARD_SIZE]
        text = json.dumps({"puzzles": chunk}, separators=(",", ":")) + "\n"
        name = f"s{len(shards):02d}-{hashlib.sha256(text.encode()).hexdigest()[:10]}.json"
        (out / name).write_text(text)
        entries += [index_entry(p, len(shards)) for p in chunk]
        shards.append(name)
    index = {
        "version": 2, "source": source, "generated": dt.date.today().isoformat(),
        "count": len(puzzles), "shards": shards, "puzzles": entries,
    }
    (out / "index.json").write_text(json.dumps(index, separators=(",", ":")) + "\n")
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


def source_text(year: int, games: int, min_elo: int) -> str:
    return (f"{games} rated FICS bughouse games from {year} with an average rating of "
            f"{min_elo} or more, from the bughouse-db.org archive")


def export_raw(raw: Path, out: Path, source: str) -> int:
    """Re-export the verified candidates a previous run kept with `--raw-out`."""
    candidates = [Candidate(**record) for record in json.loads(raw.read_text())]
    n = export_web(candidates, out, source)
    print(f"{n} puzzles written to {out} from {len(candidates)} verified candidates", file=sys.stderr)
    return 0


def run(year: int, games: int, min_elo: int, jobs: int, engine: str | None,
        out: Path, raw_out: Path | None, kinds: frozenset[str] = frozenset(KINDS),
        from_raw: Path | None = None) -> int:
    if from_raw:
        return export_raw(from_raw, out, source_text(year, games, min_elo))
    path = _engine_path(engine)
    unknown = kinds - set(KINDS)
    if unknown or not kinds:
        raise SystemExit(f"--kinds takes a subset of {','.join(KINDS)}")
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
                 initargs=(path, kinds)) as pool:
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
        by_kind = {k: sum(1 for c in unique if c.kind == k) for k in KINDS}
        print(f"verifying {len(unique)} candidates {by_kind}", file=sys.stderr, flush=True)
        verified: list[Candidate] = []
        for n, c in enumerate(pool.imap_unordered(_verify, unique), 1):
            if c:
                verified.append(c)
            if n % 100 == 0:
                print(f"verified {n}/{len(unique)}, {len(verified)} sound", file=sys.stderr, flush=True)

    if raw_out:
        raw_out.parent.mkdir(parents=True, exist_ok=True)
        raw_out.write_text(json.dumps([asdict(c) for c in verified]) + "\n")
    n = export_web(verified, out, source_text(year, len(picked), min_elo))
    print(f"{n} puzzles written to {out}", file=sys.stderr)
    return 0
