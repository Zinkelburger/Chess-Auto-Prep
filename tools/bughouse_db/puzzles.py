"""Mine bughouse puzzles from the FICS archive.

A puzzle is one board of a real game where the side to move has a forced
win *on that board alone*. The board's reserves are frozen where they stand:
nothing arrives from the partner, and a capture goes to the partner rather
than back into the capturer's hand (`frozen.py`). Fairy-Stockfish plays that
rule as `frozenhouse` (`frozenhouse.ini`: crazyhouse with `capturesToHand =
false`), so it both finds and checks them. Its own `bughouse` variant must not
be used: it also searches drops of pieces the side does not hold, as if the
partner might send them, and scores the mates they lead to near 1,400 cp.
A check that a dropped piece could block is not mate (`frozen.bughouse_mate`):
on FICS the player may wait for the piece. The rules follow lichess-puzzler's
generator where bughouse allows it.

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
  * advantage (lila's `cook_advantage`, then `TacticRules`): at each solver
    move the attack must be valid, i.e. there is no alternative, or the best
    move is a sound mate in one, or `win_chances(best) > win_chances(second)
    + 0.7`, or (with `unique_cp`) the best beats the second by that many cp;
    an invalid attack ends the line there, after one more collecting step
    when its best move is a capture (`collect_cp`: any capture or check that
    wins nearly as much is accepted). A valid best move below 200 cp busts
    the puzzle, as does a twofold repetition. The defender answers with the
    engine best at half the nodes. At most `MAX_ADVANTAGE` solver moves. The
    line is trimmed as lila trims it. An advantage line that ends in mate and
    meets the mate rules is a mate puzzle; otherwise it is a tactic when every
    solver move before the last is forcing (`forcing`: checks, or checks and
    captures, so the defender has no quiet moment to sit and wait for their
    partner), a one-move line is a check or a capture, the solver is still at
    least 300 cp ahead, it wins `min_gain` material counted `settle_plies`
    into the engine's line against the board before the opponent's last move
    (so a recapture wins nothing), and it stays `sit_cp` ahead when the
    defender is handed each piece of `sit` in turn. A rejected candidate
    records why, and a run prints the reasons.

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
from collections import Counter
from dataclasses import asdict, dataclass, field
from pathlib import Path

import chess
from chess.variant import CrazyhouseBoard

from .bpgn import BpgnGame, iter_games, open_bpgn
from .frozen import bughouse_mate, frozen_push, mating_moves, position_key, replay
from .paths import REPO, corpus_dir
from .themes import material_diff, tag_themes

SCAN_NODES = 40_000
VERIFY_NODES = 1_500_000
MAX_MATE = 5
MAX_ADVANTAGE = 5
MIN_MOVE = 6  # skip each board's first five moves: no reserves yet
KINDS = ("mate", "advantage")
SHARD_SIZE = 50

WEB_OUT = REPO / "python/twic-position-finder/frontend/public/bughouse-puzzles"
VARIANT_INI = Path(__file__).with_name("frozenhouse.ini")


@dataclass(frozen=True)
class TacticRules:
    """What a material tactic must do beyond lila's one-best-move rule.

    `forcing`: what every solver move but the last must be. `checks` leaves the
    defender no time to sit and wait for their partner; `captures` also allows
    a capture; `any` is lila's rule. `min_gain`: material won (board plus
    hand, P1 N3 B3 R5 Q9), counted `settle_plies` into the engine's best line
    after the last move, against the board before the opponent's last move, so
    neither a recapture nor a piece simply taken back counts. `sit`: the
    pieces handed to the defender one at a time at the end, as their partner
    might; the solver must still be `sit_cp` ahead with each.
    """

    forcing: str = "checks"
    min_gain: int = 3
    sit: str = "pn"
    sit_cp: int = 200
    # A one-move tactic is kept when that move is a check or a capture and the
    # engine's best line after it collects the material (a fork, a skewer).
    min_moves: int = 1
    # How far the engine's best line is followed past the end before the
    # material is counted, so a piece simply taken back does not count.
    settle_plies: int = 4
    # Where several moves win, the line takes one more step anyway and accepts
    # every move within this many centipawns of the best that still wins: a
    # fork is played out to the capture. None ends the line there, as lila does.
    collect_cp: int | None = 150
    # A move is the only one worth the name by lila's win-chance gap, or, when
    # set, by this many centipawns over the second best: frozen-reserve scores
    # run high, and lila's win chances cannot tell +15 from +9.
    unique_cp: int | None = None


RULES = TacticRules()

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
    gain: int | None = None  # material won by an advantage line, settled
    sit_cp: int | None = None  # the solver's worst score once the defender is handed a piece
    reject: str | None = None  # why verification turned it down; never exported


class FairyEngine:
    """One Fairy-Stockfish process playing one bughouse board with its reserves
    frozen (`frozenhouse.ini`)."""

    def __init__(self, path: str) -> None:
        self.proc = subprocess.Popen(
            [path], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1
        )
        self._send("uci")
        self._until("uciok")
        for option in (f"VariantPath value {VARIANT_INI}", "UCI_Variant value frozenhouse",
                       "Threads value 1", "Hash value 32"):
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
_RULES: TacticRules = RULES


def _init_worker(path: str, kinds: frozenset[str] = frozenset(KINDS), rules: TacticRules = RULES,
                 verify_nodes: int = VERIFY_NODES) -> None:
    global _ENGINE, _KINDS, _RULES, VERIFY_NODES
    _ENGINE = FairyEngine(path)
    _KINDS = kinds
    _RULES = rules
    VERIFY_NODES = verify_nodes


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
    gain: int | None = None
    sit_cp: int | None = None


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


def is_valid_attack(engine, board: CrazyhouseBoard, best: Score, second: Score | None,
                    unique_cp: int | None = None) -> bool:
    """lila: the best move is the only continuation worth the name."""
    return (second is None or is_valid_mate_in_one(engine, board, best, second)
            or win_chances(best) > win_chances(second) + 0.7
            or (unique_cp is not None and best[0] == second[0] == "cp" and best[1] - second[1] >= unique_cp))


@dataclass
class _Step:
    move: str
    best: Score
    second: Score | None
    check: bool
    capture: bool
    accept: list[str] = field(default_factory=list)  # a collecting step's accepted moves


def _forcing(step: _Step, rule: str) -> bool:
    return rule == "any" or step.check or (rule == "captures" and step.capture)


def _collect(engine, board: CrazyhouseBoard, within: int) -> _Step | None:
    """The step after the line's last unique move, when it takes the material:
    the best move is a capture, and every capture or check that wins nearly
    as much is accepted too. None when the best move takes nothing, so the
    material was already won and the line ends before it."""
    ranks, _ = engine.search(board.fen(), VERIFY_NODES, multipv=5)
    scores = {rank: (_rank_score(r), r[2][0]) for rank, r in ranks.items()}
    best_score, move = scores[1]
    uci = chess.Move.from_uci(move)
    if not board.is_capture(uci):
        return None
    floor = max(300, as_cp(best_score) - within)

    def takes(m: str) -> bool:
        candidate = chess.Move.from_uci(m)
        return board.is_capture(candidate) or board.gives_check(candidate)

    accept = [m for score, m in scores.values() if as_cp(score) >= floor and takes(m)]
    return _Step(move, best_score, scores.get(2, (None, ""))[0], board.gives_check(uci), True, accept)


def _solver_cp(engine, board: CrazyhouseBoard, nodes: int) -> int:
    """The solver's score with the defender to move."""
    return _solver_line(engine, board, nodes)[0]


def _solver_line(engine, board: CrazyhouseBoard, nodes: int) -> tuple[int, list[str]]:
    """The solver's score with the defender to move, and the engine's best line."""
    ranks, _ = engine.search(board.fen(), nodes)
    best = ranks.get(1)
    return (-as_cp((best[0], best[1])), best[2]) if best else (0, [])


def _settle(board: CrazyhouseBoard, pv: list[str], plies: int) -> CrazyhouseBoard:
    """`board` after up to `plies` legal moves of the engine's line."""
    settled = board.copy(stack=False)
    for uci in pv[:plies]:
        try:
            move = chess.Move.from_uci(uci)
        except ValueError:
            break
        if move not in settled.legal_moves:
            break
        frozen_push(settled, uci)
    return settled


def solve_advantage(engine, fen: str, rules: TacticRules | None = None,
                    prev: str | None = None) -> Solution | str:
    """lila's `cook_advantage` with its trimming, on one frozen bughouse board,
    then the material rules of `TacticRules`. A rejected line returns why."""
    rules = rules or RULES
    engine.new_game()
    board = CrazyhouseBoard(fen)
    pov = board.turn
    seen = {position_key(board)}
    steps: list[_Step] = []
    replies: list[str] = []
    while len(steps) < MAX_ADVANTAGE:
        ranks, _ = engine.search(board.fen(), VERIFY_NODES, multipv=2)
        rank = ranks.get(1)
        if not rank:
            return "no move"
        best, second = _rank_score(rank), _rank_score(ranks.get(2))
        assert best
        if not is_valid_attack(engine, board, best, second, rules.unique_cp):
            if steps and rules.collect_cp is not None and as_cp(best) >= 300:
                collect = _collect(engine, board, rules.collect_cp)
                if collect:
                    steps.append(collect)
            break
        if as_cp(best) < 200:
            return "not winning"
        move = rank[2][0]
        uci = chess.Move.from_uci(move)
        steps.append(_Step(move, best, second, board.gives_check(uci), board.is_capture(uci)))
        frozen_push(board, move)
        if board.is_game_over():
            break
        if position_key(board) in seen:
            return "repetition"
        seen.add(position_key(board))
        _, reply = engine.search(board.fen(), VERIFY_NODES // 2)
        if reply in ("(none)", "0000"):
            break
        frozen_push(board, reply)
        if position_key(board) in seen:
            return "repetition"
        seen.add(position_key(board))
        replies.append(reply)
    while steps and steps[-1].second is None and not steps[-1].accept:
        steps.pop()
    if not steps:
        return "no unique first move"
    line = [steps[0].move]
    for step, reply in zip(steps[1:], replies):
        line += [reply, step.move]
    boards = replay(fen, line)
    final = boards[-1]
    if (bughouse_mate(final) and len(steps) <= MAX_MATE
            and all(s.check and not is_mate(s.second) for s in steps[:-1])):
        return Solution("mate", line, mating_moves(boards[-2]))
    if final.is_checkmate():
        return "blockable mate"
    if len(steps) < rules.min_moves:
        return "too short"
    if len(steps) == 1 and not _forcing(steps[0], "captures"):
        return "one quiet move"
    if not all(_forcing(step, rules.forcing) for step in steps[:-1]):
        return "lets them sit"
    cp, pv = _solver_line(engine, final, VERIFY_NODES // 2)
    if cp < 300:
        return "not winning at the end"
    # Count the material a few moves on, against the board before the
    # opponent's last move: a recapture wins nothing.
    base = material_diff(boards[0], pov)
    if prev:
        base = max(base, material_diff(CrazyhouseBoard(prev), pov))
    gain = material_diff(_settle(final, pv, rules.settle_plies), pov) - base
    if gain < rules.min_gain:
        return "wins too little"
    worst = cp
    for letter in rules.sit:
        helped = final.copy(stack=False)
        helped.pockets[not pov].add(chess.Piece.from_symbol(letter).piece_type)
        worst = min(worst, _solver_cp(engine, helped, VERIFY_NODES // 2))
    if worst < rules.sit_cp:
        return "partner help saves them"
    solution = Solution("advantage", line, steps[-1].accept, cp)
    solution.gain, solution.sit_cp = gain, worst
    return solution


def _verify(candidate: Candidate) -> Candidate:
    """The candidate with its solution, or with `reject` saying why there is none."""
    assert _ENGINE
    try:
        if candidate.kind == "mate":
            solved: Solution | str = solve_mate(_ENGINE, candidate.fen) or "mate not forced"
        else:
            solved = solve_advantage(_ENGINE, candidate.fen, _RULES, candidate.prev)
    except Exception as error:  # noqa: BLE001
        solved = f"error: {type(error).__name__}"
    if isinstance(solved, str):
        candidate.reject = f"{candidate.kind}: {solved}"
        return candidate
    candidate.kind, candidate.line, candidate.mates, candidate.cp = (
        solved.kind, solved.line, solved.mates, solved.cp)
    candidate.gain, candidate.sit_cp = solved.gain, solved.sit_cp
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
    if mate and not bughouse_mate(board):
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
        "moves": moves, "cp": c.cp, "gain": c.gain, "themes": themes,
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
        from_raw: Path | None = None, rules: TacticRules = RULES, skip: int = 0,
        candidates_out: Path | None = None, from_candidates: Path | None = None,
        verify_nodes: int = VERIFY_NODES) -> int:
    if from_raw:
        return export_raw(from_raw, out, source_text(year, games, min_elo))
    path = _engine_path(engine)
    unknown = kinds - set(KINDS)
    if unknown or not kinds:
        raise SystemExit(f"--kinds takes a subset of {','.join(KINDS)}")
    workers = jobs or max(1, (os.cpu_count() or 2) - 1)
    with mp.Pool(workers, initializer=_init_worker, initargs=(path, kinds, rules, verify_nodes)) as pool:
        if from_candidates:
            # Verify a saved scan again, e.g. under other rules: no rescanning.
            unique = [Candidate(**record) for record in json.loads(from_candidates.read_text())]
            unique = [c for c in unique if c.kind in kinds]
            for c in unique:
                c.reject = None
            n_games = games
        else:
            source_file = corpus_dir() / f"export{year}.bpgn.bz2"
            if not source_file.exists():
                raise SystemExit(f"{source_file} is missing. Run `python3 -m bughouse_db fetch --only {year}`.")
            picked: list[BpgnGame] = []
            eligible = 0
            for game in iter_games(open_bpgn(source_file)):
                elos = game.elos()
                if (game.rated and len(game.moves) > 30 and game.avg_elo >= min_elo
                        and min(elos) >= min_elo - 300):
                    eligible += 1
                    if eligible <= skip:
                        continue
                    picked.append(game)
                    if len(picked) >= games:
                        break
            n_games = len(picked)
            print(f"{n_games} games from {year} (after skipping {skip})", file=sys.stderr, flush=True)
            found: list[Candidate] = []
            for n, batch in enumerate(pool.imap_unordered(scan_game, picked, chunksize=2), 1):
                found.extend(batch)
                if n % 100 == 0:
                    print(f"scanned {n}/{n_games} games, {len(found)} candidates",
                          file=sys.stderr, flush=True)
            seen: set[str] = set()
            unique = []
            for c in found:
                key = " ".join(c.fen.split()[:3])
                if key not in seen:
                    seen.add(key)
                    unique.append(c)
            if candidates_out:
                candidates_out.parent.mkdir(parents=True, exist_ok=True)
                candidates_out.write_text(json.dumps([asdict(c) for c in unique]) + "\n")
        by_kind = {k: sum(1 for c in unique if c.kind == k) for k in KINDS}
        print(f"verifying {len(unique)} candidates {by_kind}", file=sys.stderr, flush=True)
        verified: list[Candidate] = []
        rejects: Counter[str] = Counter()
        for n, c in enumerate(pool.imap_unordered(_verify, unique), 1):
            if c.reject:
                rejects[c.reject] += 1
            else:
                verified.append(c)
            if n % 100 == 0:
                print(f"verified {n}/{len(unique)}, {len(verified)} sound", file=sys.stderr, flush=True)
    kept = Counter(c.kind for c in verified)
    print(f"sound: {dict(kept)}; turned down: " + ", ".join(f"{k} {v}" for k, v in rejects.most_common()),
          file=sys.stderr, flush=True)
    if raw_out:
        raw_out.parent.mkdir(parents=True, exist_ok=True)
        raw_out.write_text(json.dumps([asdict(c) for c in verified]) + "\n")
    n = export_web(verified, out, source_text(year, n_games, min_elo))
    print(f"{n} puzzles written to {out}", file=sys.stderr)
    return 0
