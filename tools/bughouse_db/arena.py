"""Mine bughouse puzzles from engine games: the arena referee's BPGN files.

`python3 -m bughouse_db puzzles --arena DIR` runs the miner of `puzzles.py`
over the games `tools/bughouse_arena` writes (`games.bpgn` beside a
`manifest.json` in each match directory; DIR is a match directory or a
directory of them) instead of a FICS year. The scan, the verify and the
policy are the ones `puzzles.py` specifies; this module adds what engine
games need.

Reading. Two generations of the file exist. The newer one writes the whole
game in SAN, the opening included, with a comment after each move holding
the clock, the mover's own score and the game time:
`5A. Qg4 {[%clk 0:01:58.4] [%eval 2.69] 3.8s}`. `[%eval]` is in pawns, or
`#N` for a mate, from White's side on that board. The older one writes UCI
moves (`e7e5`, `P@h6`), no scores, and the opening only in the `Opening`
tag (`1g1f3 2e2e4 ...`, the digit naming the board: 1 is A, 2 is B), so the
movetext starts after it; the opening is put back in front when the
movetext does not already begin with it. Other comments (`{A-black sits
@30.0s}`, an illegal move the referee refused) are not moves.

Scan. Self-play at fixed nodes from a fixed opening list repeats long
stretches, so each distinct position is searched once (`SCAN_NODES`, as for
FICS) and every game then walks its own positions through the same scan
rules (`ScanState`).

Swing. A position also becomes an `advantage` candidate when the game's own
scores show a sharp swing on that board against the side that just moved
(`swing_flags`): the mover's score for the move just played is at least
`SWING_CP` worse for it than that seat's previous score on that board, or
the next score of the side now to move is at least `SWING_CP` better for it
than its previous one. A mate counts as beyond any centipawn score. The
position must be one the scan would look at (from the sixth move, game not
over, two legal moves), and the scan must see the side to move at least
`SWING_MIN_CP` ahead on the frozen board: the verify turns down anything
less at its first step, and engine scores swing on a quarter of all moves
(captures on the other board refill the hands), far more than can be verified. A candidate records which trigger flagged it:
`scan`, `swing` or `both`, merged over every game that reached the position.

Pre-check. In engine games the scan flags about one position in nine, and
most advantage candidates are positions where several moves win, which the
verify turns down ("no unique first move") after its first deep search. So
an advantage candidate first gets a two-line search at `SCAN_NODES`; when its
best move beats the second by less than `PRECHECK_GAP` in lila's win chances
(the verify asks for 0.7) and is not a mate in one, it is set aside without
the deep searches. Mate candidates are not pre-checked: a forced mate may have
a second move that also wins easily. A fixed `PRECHECK_SAMPLE` of the set-aside
candidates is verified in full anyway, which measures what the pre-check costs
and keeps any puzzle found that way.

Deduplication. Candidates are deduplicated on placement, side and pockets
(as for FICS), and against the positions of the FICS set already in
`WEB_OUT`; verified puzzles keep at most one per solution line among games
that share an opening (`dedupe_lines`).

Records. The page's version-2 records, with readable engine names
(`HypeBeast`, `HiveMind`, `Fairy-Stockfish`; never a build name), ratings
0, the match's start date, `game` a stable integer from the match and round,
and an id `e<6 hex of the match>-<round>-<board>-<ply>`, which no FICS id
(all digits first) can equal. `played`/`found` say what the engine played.
"""

from __future__ import annotations

import datetime as dt
import hashlib
import json
import multiprocessing as mp
import re
import sys
from collections import Counter
from dataclasses import asdict, dataclass, field
from pathlib import Path

from . import puzzles as P
from .paths import REPO

SWING_CP = 300
SWING_MIN_CP = 200
PRECHECK_GAP = 0.3
PRECHECK_SAMPLE = 3  # percent of set-aside candidates verified in full anyway
WEB_OUT = P.WEB_OUT / "engine"
ENGINE_NAMES = {"hypebeast": "HypeBeast", "hivemind": "HiveMind", "fsf": "Fairy-Stockfish"}

TOKEN_RE = re.compile(r"\{[^}]*\}|(\d+)([AaBb])\.\s*([^\s{}]+)")
TAG_RE = re.compile(r'\[([A-Za-z0-9_]+)\s+"([^"]*)"\]')
EVAL_RE = re.compile(r"\[%eval\s+(#?)([+-]?\d+(?:\.\d+)?)\]")


@dataclass
class ArenaGame:
    """One referee game: tags, half-moves in the order played, and the mover's score for each."""

    match: str
    tags: dict[str, str] = field(default_factory=dict)
    #: `(board, move)`; the board letter's case names the mover, the move is SAN or UCI.
    moves: list[tuple[str, str]] = field(default_factory=list)
    #: The mover's own score for each move, from the mover's side; None when not recorded.
    evals: list[P.Score | None] = field(default_factory=list)
    date: str = ""
    #: Seat tag (`WhiteA`, ...) to the engine's readable name.
    names: dict[str, str] = field(default_factory=dict)

    @property
    def round(self) -> int:
        try:
            return int(self.tags.get("Round", "0"))
        except ValueError:
            return 0

    @property
    def opening(self) -> str:
        return self.tags.get("Opening", "")

    @property
    def game_no(self) -> int:
        """A stable integer for the game, from its match and round (48 bits, safe in JavaScript)."""
        return int(hashlib.sha1(f"{self.match}#{self.round}".encode()).hexdigest()[:12], 16)

    def puzzle_id(self, board: str, ply: int) -> str:
        return f"e{hashlib.sha1(self.match.encode()).hexdigest()[:6]}-{self.round}-{board}-{ply}"


def parse_eval(comment: str, white_moved: bool) -> P.Score | None:
    """The `[%eval]` in a move's comment, from the mover's side; None without one."""
    m = EVAL_RE.search(comment)
    if not m:
        return None
    sign = 1 if white_moved else -1
    if m.group(1):
        n = int(float(m.group(2)))
        return ("mate", sign * n) if n else None
    return ("cp", sign * round(float(m.group(2)) * 100))


def _build(match: str, tags: dict[str, str], movetext: str) -> ArenaGame:
    game = ArenaGame(match=match, tags=tags)
    for m in TOKEN_RE.finditer(movetext):
        if m.group(1) is None:
            # A comment: the clock and score of the move before it, or an event.
            if game.moves and game.evals[-1] is None:
                game.evals[-1] = parse_eval(m.group(0), game.moves[-1][0].isupper())
            continue
        game.moves.append((m.group(2), m.group(3)))
        game.evals.append(None)
    return game


def iter_arena_games(lines, match: str):
    """Yield an [ArenaGame] per record from an iterable of text lines."""
    tags: dict[str, str] = {}
    movetext: list[str] = []
    started = False
    for raw in lines:
        line = raw.rstrip("\r\n")
        if line.startswith("[Event "):
            if started:
                yield _build(match, tags, " ".join(movetext))
            tags, movetext, started = {}, [], True
        if not started:
            continue
        if line.startswith("[") and TAG_RE.match(line):
            tags.update(TAG_RE.findall(line))
        elif line:
            movetext.append(line)
    if started:
        yield _build(match, tags, " ".join(movetext))


def match_dirs(roots: list[Path]) -> list[Path]:
    """Every match directory (one holding `games.bpgn`) given, or under those given, sorted."""
    out: list[Path] = []
    for root in roots:
        if (root / "games.bpgn").is_file():
            out.append(root)
        else:
            out.extend(sorted(p.parent for p in root.glob("*/games.bpgn")))
    return out


def match_name(path: Path) -> str:
    """`HypeBeast-v5/cap0-b` for `~/Projects/HypeBeast-v5/logs/cap0-b`: stable while the logs stay put."""
    parent = path.parent.parent.name if path.parent.name == "logs" else path.parent.name
    return f"{parent}/{path.name}"


def display_name(seat: str, kinds: dict[str, str]) -> str:
    """The readable engine behind a seat name: the manifest's kind, else the name's prefix."""
    kind = kinds.get(seat, "")
    if kind in ENGINE_NAMES:
        return ENGINE_NAMES[kind]
    if seat.startswith("hm-"):
        return "HiveMind"
    if seat.startswith("fsf"):
        return "Fairy-Stockfish"
    return "HypeBeast"


def read_match(path: Path) -> list[ArenaGame]:
    """The games of one match directory, with names and the date from its manifest."""
    kinds: dict[str, str] = {}
    date = ""
    try:
        manifest = json.loads((path / "manifest.json").read_text())
        for side in (manifest.get("sides") or {}).values():
            if isinstance(side, dict) and side.get("name"):
                kinds[side["name"]] = str(side.get("kind", ""))
        sessions = manifest.get("sessions") or []
        if sessions and isinstance(sessions[0], dict):
            date = str(sessions[0].get("started", ""))[:10]
    except (OSError, ValueError):
        pass
    bpgn = path / "games.bpgn"
    if not date:
        date = dt.date.fromtimestamp(bpgn.stat().st_mtime).isoformat()
    date = date.replace("-", ".")
    name = match_name(path)
    with bpgn.open(encoding="utf-8", errors="replace") as stream:
        games = list(iter_arena_games(stream, name))
    for game in games:
        game.date = date
        game.names = {tag: display_name(game.tags.get(tag, ""), kinds) for tag in ("WhiteA", "BlackA", "WhiteB", "BlackB")}
    return games


# ── Replay ────────────────────────────────────────────────────────────


def _dual_board():
    sys.path.insert(0, str(REPO / "tools/mcp"))
    from bughouse.board import DualBoard  # noqa: PLC0415 -- worker-local import

    return DualBoard


def full_moves(game: ArenaGame) -> tuple[list[tuple[str, str]], list[P.Score | None]]:
    """The whole game from its start: the opening put in front when the movetext lacks it."""
    tokens = game.opening.split()
    if not tokens:
        return game.moves, game.evals
    opening = [("AB"[int(t[0]) - 1], t[1:]) for t in tokens]
    if len(game.moves) >= len(opening):
        dual = _dual_board()()
        try:
            same = True
            for (board, uci), (which, text) in zip(opening, game.moves):
                ply = dual.push(board, uci)
                if which.upper() != board or text.rstrip("+#") not in (ply.san.rstrip("+#"), uci):
                    same = False
                    break
            if same:
                return game.moves, game.evals
        except Exception:  # noqa: BLE001 -- an unplayable opening fails the replay below
            pass
    return opening + game.moves, [None] * len(opening) + game.evals


@dataclass
class Step:
    """One half-move replayed: what the scan and the swing trigger need, and the candidate's fields."""

    board: str
    white: bool  # the mover
    san: str
    uci: str
    fen: str  # the board after the move
    prev: str  # the board before it
    dual: str
    eligible: bool  # a position the scan looks at
    legal: int
    eval: P.Score | None


def replay(game: ArenaGame) -> list[Step]:
    """Every half-move with the positions around it; raises on a move that does not replay."""
    DualBoard = _dual_board()
    setup = game.tags.get("SetUpDualFEN")
    dual = DualBoard.from_dual_fen(setup) if setup else DualBoard()
    moves, evals = full_moves(game)
    steps: list[Step] = []
    for (which, text), score in zip(moves, evals):
        name = which.upper()
        before = dual.board(name)
        prev, white = before.fen(), before.turn
        ply = dual.push(name, text)
        board = dual.board(name)
        eligible = not board.is_game_over() and board.fullmove_number >= P.MIN_MOVE
        steps.append(Step(name, white, ply.san, ply.uci, board.fen(), prev, dual.dual_fen, eligible,
                          board.legal_moves.count() if eligible else 0, score))
    return steps


def scan_positions(game: ArenaGame) -> tuple[list[str], str | None]:
    """The positions of a game the scan searches, or why the game does not replay."""
    try:
        return [s.fen for s in replay(game) if s.eligible], None
    except Exception as error:  # noqa: BLE001 -- a corrupt record must not stop the run
        return [], f"{type(error).__name__}"


# ── Triggers ──────────────────────────────────────────────────────────


def swing_flags(steps: list[tuple[str, bool, P.Score | None]], threshold: int = SWING_CP) -> list[bool]:
    """Per half-move `(board, mover is White, mover's score)`: whether the
    position after it shows a swing against its mover (module docstring)."""
    n = len(steps)
    flags = [False] * n
    last: dict[tuple[str, bool], int] = {}  # a seat's latest recorded score so far
    before: list[int | None] = [None] * n  # the mover's previous score on that board
    opp_before: list[int | None] = [None] * n  # the opponent's latest score before this move
    for i, (board, white, score) in enumerate(steps):
        before[i] = last.get((board, white))
        opp_before[i] = last.get((board, not white))
        if score is not None:
            last[(board, white)] = P.as_cp(score)
    following: dict[tuple[str, bool], int] = {}  # a seat's next recorded score after this move
    for i in range(n - 1, -1, -1):
        board, white, score = steps[i]
        mine = P.as_cp(score) if score is not None else None
        mine_before, theirs_before = before[i], opp_before[i]
        drop = mine is not None and mine_before is not None and mine_before - mine >= threshold
        nxt = following.get((board, not white))
        rise = nxt is not None and theirs_before is not None and nxt - theirs_before >= threshold
        flags[i] = drop or rise
        if mine is not None:
            following[(board, white)] = mine
    return flags


_SCORES: dict[str, P.Score] = {}
_FLAG_KINDS: frozenset[str] = frozenset(P.KINDS)


def _init_flagger(scores: dict[str, P.Score], kinds: frozenset[str] = frozenset(P.KINDS)) -> None:
    global _SCORES, _FLAG_KINDS
    _SCORES, _FLAG_KINDS = scores, kinds


def flag_game(game: ArenaGame, kinds: frozenset[str] | None = None) -> list[P.Candidate]:
    """The candidates of one game: the scan's flags from the shared scores, plus the swings."""
    try:
        steps = replay(game)
    except Exception:  # noqa: BLE001
        return []
    kinds = _FLAG_KINDS if kinds is None else kinds
    swings = swing_flags([(s.board, s.white, s.eval) for s in steps])
    state = P.ScanState()
    out: list[P.Candidate] = []
    for i, s in enumerate(steps):
        if not s.eligible:
            continue
        score = _SCORES.get(s.fen)
        kind = state.step(s.board, not s.white, score, s.legal, kinds) if score else None
        # The verify turns down any start the solver is not 200 cp up in, so
        # a swing is worth verifying only where the scan already sees that.
        swing = (swings[i] and s.legal >= 2 and "advantage" in kinds
                 and score is not None and P.as_cp(score) >= SWING_MIN_CP)
        if not kind and not swing:
            continue
        played = next((t.san for t in steps[i + 1:] if t.board == s.board), None)
        color = ("White", "Black")
        out.append(P.Candidate(
            fen=s.fen, dual=s.dual, board=s.board, ply=i, last=s.uci, played=played,
            game=game.game_no, date=game.date, tc=f"{game.tags.get('TimeControl', '')}+0",
            white=game.names.get(f"{color[0]}{s.board}", ""), black=game.names.get(f"{color[1]}{s.board}", ""),
            welo=0, belo=0, kind=kind or "advantage", prev=s.prev,
            trigger="both" if kind and swing else "scan" if kind else "swing",
            opening=game.opening, pid=game.puzzle_id(s.board, i),
        ))
    return out


def position_key(fen: str) -> str:
    """The FICS miner's deduplication key: placement with pockets, side and castling."""
    return " ".join(fen.split()[:3])


def merge(candidates: list[P.Candidate]) -> list[P.Candidate]:
    """One candidate per position, the first seen; triggers merge, and a mate flag wins."""
    seen: dict[str, P.Candidate] = {}
    for c in candidates:
        key = position_key(c.fen)
        first = seen.get(key)
        if first is None:
            seen[key] = c
            continue
        if first.trigger != c.trigger:
            first.trigger = "both"
        if c.kind == "mate":
            first.kind = "mate"
    return list(seen.values())


def fics_keys(web_dir: Path = P.WEB_OUT) -> set[str]:
    """The positions of the FICS set already published."""
    keys: set[str] = set()
    for shard in web_dir.glob("s[0-9][0-9]*.json"):
        try:
            keys.update(position_key(p["fen"]) for p in json.loads(shard.read_text())["puzzles"])
        except (OSError, ValueError, KeyError, TypeError):
            continue
    return keys


def dedupe_lines(candidates: list[P.Candidate]) -> list[P.Candidate]:
    """At most one puzzle per solution line among games that share an opening, the first kept."""
    seen: set[tuple[str, tuple[str, ...]]] = set()
    out: list[P.Candidate] = []
    for c in candidates:
        key = (c.opening, tuple(c.line))
        if key in seen:
            continue
        seen.add(key)
        out.append(c)
    return out


# ── Run ───────────────────────────────────────────────────────────────


def source_text(games: list[ArenaGame]) -> str:
    against: Counter[str] = Counter()
    for g in games:
        others = set(g.names.values()) - {"HypeBeast"}
        against[next(iter(others)) if others else "HypeBeast"] += 1
    parts = [f"{against[name]:,} against {'other builds of itself' if name == 'HypeBeast' else name}"
             for name in ("HypeBeast", "HiveMind", "Fairy-Stockfish") if against[name]]
    return f"{len(games):,} engine games played by HypeBeast: " + ", ".join(parts)


def _sort_key(c: P.Candidate) -> tuple:
    return (c.date, c.pid or "")


def export(verified: list[P.Candidate], out: Path, source: str) -> int:
    """The engine set: the FICS positions and repeated lines left out, then the usual layout."""
    known = fics_keys()
    kept = dedupe_lines(sorted((c for c in verified if position_key(c.fen) not in known), key=_sort_key))
    n = P.export_web(kept, out, source)
    print(f"{n} puzzles written to {out} from {len(verified)} verified candidates "
          f"({len(verified) - len(kept)} repeated a FICS position or a line)", file=sys.stderr)
    return n


def precheck_passes(best: P.Score | None, second: P.Score | None, gap: float = PRECHECK_GAP) -> bool:
    """Whether an advantage candidate's two-line search leaves one move clearly best."""
    if best is None or second is None or best == ("mate", 1):
        return True
    return P.win_chances(best) - P.win_chances(second) >= gap


def sampled(c: P.Candidate, percent: int = PRECHECK_SAMPLE) -> bool:
    """A fixed share of candidates, by id, verified in full even when the pre-check fails."""
    return int(hashlib.sha1((c.pid or c.fen).encode()).hexdigest()[:8], 16) % 100 < percent


def _check(c: P.Candidate) -> P.Candidate:
    """Pre-check an advantage candidate, then verify it unless it was set aside."""
    assert P._ENGINE
    if c.kind == "advantage":
        try:
            P._ENGINE.new_game()
            ranks, _ = P._ENGINE.search(c.fen, P.SCAN_NODES, multipv=2)
            c.precheck = "pass" if precheck_passes(P._rank_score(ranks.get(1)), P._rank_score(ranks.get(2))) else "fail"
        except Exception:  # noqa: BLE001 -- the verify reports a broken engine
            c.precheck = "pass"
        if c.precheck == "fail" and not sampled(c):
            c.reject = "advantage: no clear best move (pre-check)"
            return c
    return P._verify(c)


def _scan_cache_load(path: Path | None) -> dict[str, P.Score]:
    if not path or not path.exists():
        return {}
    return {fen: (kind, value) for fen, (kind, value) in json.loads(path.read_text()).items()}


def _scan_cache_save(path: Path | None, scores: dict[str, P.Score]) -> None:
    if not path:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(scores, separators=(",", ":")))
    tmp.replace(path)


def _score(fen: str) -> tuple[str, P.Score | None]:
    assert P._ENGINE
    ranks, _ = P._ENGINE.search(fen, P.SCAN_NODES)
    best = ranks.get(1)
    return fen, ((best[0], best[1]) if best else None)


def run(roots: list[Path], jobs: int, engine: str | None, out: Path, raw_out: Path | None,
        kinds: frozenset[str] = frozenset(P.KINDS), from_raw: Path | None = None,
        rules: P.TacticRules = P.RULES, candidates_out: Path | None = None,
        from_candidates: Path | None = None, verify_nodes: int = P.VERIFY_NODES,
        scan_cache: Path | None = None, verify_log: Path | None = None) -> int:
    dirs = match_dirs(roots)
    games = [g for d in dirs for g in read_match(d)]
    source = source_text(games)
    print(f"{len(games)} games in {len(dirs)} matches", file=sys.stderr, flush=True)
    if from_raw:
        export([P.Candidate(**r) for r in json.loads(from_raw.read_text())], out, source)
        return 0
    path = P._engine_path(engine)
    workers = jobs or 1
    ctx = mp.get_context("spawn")
    if from_candidates:
        unique = [P.Candidate(**r) for r in json.loads(from_candidates.read_text())]
    else:
        with ctx.Pool(workers) as pool:
            replays = list(pool.imap(scan_positions, games, chunksize=8))
        skipped = Counter(why for _, why in replays if why)
        wanted = {fen for fens, _ in replays for fen in fens}
        print(f"replayed {len(games) - sum(skipped.values())} games, skipped {dict(skipped)}; "
              f"{sum(len(f) for f, _ in replays)} positions, {len(wanted)} distinct",
              file=sys.stderr, flush=True)
        del replays
        scores = _scan_cache_load(scan_cache)
        todo = sorted(wanted - scores.keys())
        print(f"scanning {len(todo)} positions ({len(scores)} cached)", file=sys.stderr, flush=True)
        if todo:
            with ctx.Pool(workers, initializer=P._init_worker, initargs=(path, kinds, rules, verify_nodes)) as pool:
                for n, (fen, score) in enumerate(pool.imap_unordered(_score, todo, chunksize=32), 1):
                    if score:
                        scores[fen] = score
                    if n % 20_000 == 0:
                        print(f"scanned {n}/{len(todo)}", file=sys.stderr, flush=True)
                        _scan_cache_save(scan_cache, scores)
            _scan_cache_save(scan_cache, scores)
        with ctx.Pool(workers, initializer=_init_flagger, initargs=({f: scores[f] for f in wanted if f in scores}, kinds)) as pool:
            found = [c for batch in pool.imap(flag_game, games, chunksize=8) for c in batch]
        by = Counter(c.trigger for c in found)
        unique = merge(found)
        print(f"{len(found)} flags {dict(by)}; {len(unique)} distinct positions "
              f"{dict(Counter(c.trigger for c in unique))}", file=sys.stderr, flush=True)
        known = fics_keys()
        before = len(unique)
        unique = [c for c in unique if position_key(c.fen) not in known]
        print(f"{before - len(unique)} already in the FICS set", file=sys.stderr, flush=True)
        if candidates_out:
            candidates_out.parent.mkdir(parents=True, exist_ok=True)
            candidates_out.write_text(json.dumps([asdict(c) for c in unique]) + "\n")
    unique = [c for c in unique if c.kind in kinds]
    for c in unique:
        c.reject, c.precheck = None, None
    done: dict[str, P.Candidate] = {}
    if verify_log and verify_log.exists():
        for line in verify_log.read_text().splitlines():
            try:
                record = P.Candidate(**json.loads(line))
            except (ValueError, TypeError):
                continue
            done[record.pid or position_key(record.fen)] = record
    todo_v = [c for c in unique if (c.pid or position_key(c.fen)) not in done]
    print(f"verifying {len(todo_v)} candidates ({len(unique) - len(todo_v)} done before) "
          f"{dict(Counter(c.kind for c in todo_v))}", file=sys.stderr, flush=True)
    if todo_v:
        log = verify_log.open("a") if verify_log else None
        with ctx.Pool(workers, initializer=P._init_worker, initargs=(path, kinds, rules, verify_nodes)) as pool:
            for n, c in enumerate(pool.imap_unordered(_check, todo_v), 1):
                done[c.pid or position_key(c.fen)] = c
                if log:
                    log.write(json.dumps(asdict(c)) + "\n")
                    log.flush()
                if n % 100 == 0:
                    sound = sum(1 for d in done.values() if not d.reject)
                    print(f"verified {n}/{len(todo_v)}, {sound} sound so far", file=sys.stderr, flush=True)
        if log:
            log.close()
    results = [done[c.pid or position_key(c.fen)] for c in unique if (c.pid or position_key(c.fen)) in done]
    verified = [c for c in results if not c.reject]
    rejects = Counter(c.reject for c in results if c.reject)
    tried = [c for c in results if c.precheck == "fail" and sampled(c)]
    print(f"pre-check: {sum(1 for c in results if c.precheck == 'fail')} set aside; of the "
          f"{len(tried)} verified in full anyway, {sum(1 for c in tried if not c.reject)} were sound",
          file=sys.stderr, flush=True)
    print(f"sound: {dict(Counter(c.kind for c in verified))} by trigger "
          f"{dict(Counter(c.trigger for c in verified))}; turned down: "
          + ", ".join(f"{k} {v}" for k, v in rejects.most_common()), file=sys.stderr, flush=True)
    if raw_out:
        raw_out.parent.mkdir(parents=True, exist_ok=True)
        raw_out.write_text(json.dumps([asdict(c) for c in verified]) + "\n")
    export(verified, out, source)
    return 0
