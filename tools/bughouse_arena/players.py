"""Players the arena can seat: UCI engines of three kinds, and a random mover.

Engine kinds (the first item of an engine spec):

``hivemind``
    The team engine the app ships, found the way the bughouse MCP server finds
    it (tools/mcp/bughouse/paths.py): ``HIVEMIND_BIN`` / ``HIVEMIND_MODEL``,
    the app's unpacked bundle, or ``assets/bughouse``. It is launched with
    ``--model``, takes ``Team``/``TimeAdvantage``, gets the dual-FEN
    ``position`` command and answers a joint ``bestmove (moveA,moveB)``. A
    spec without a kind is a Hivemind spec, as before.
``hypebeast``
    The HypeBeast Fairy-Stockfish fork in arena mode (``HypeBeast=true``). Same
    position format and joint answer as Hivemind, plus ``Seat`` and ``Clocks``
    and an optional ``info string hb_wake_after_ms=N`` wake request.
``fsf``
    Unmodified Fairy-Stockfish bughouse via a UCI snapshot adapter: each
    decision sends the seat's own board as a single FEN with the real pockets
    and counters (``position fen``), and reads an ordinary ``bestmove``. The
    engine sees no pre-root repetition history and no partner messages.

Every seat is its own process, so two different engines can share a team. A
team engine searches a joint action for both of its team's boards; a seat keeps
only the half for its own board and treats ``pass`` as sitting.

``Seat`` and ``Clocks`` are sent only to engines whose ``uci`` output advertises
them, so Hivemind never sees them.
"""

from __future__ import annotations

import os
import platform
import queue
import random
import re
import subprocess
import sys
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path

import chess
from chess.variant import CrazyhouseBoard

from .referee import STARTING_FEN, team_name
from .sim import SeatView

KINDS = ("hivemind", "hypebeast", "fsf")
FSF_LABEL = "unmodified FSF bughouse via UCI snapshot adapter"
FSF_LIMITATIONS = ("receives the seat's actual board, pockets and counters as one FEN; "
                   "no pre-root repetition history and no CECP partner messages, so this "
                   "does not measure Fairy-Stockfish's native CECP team play")
SEAT_OPTION_VALUES = ("Awhite", "Ablack", "Bwhite", "Bblack")
DEFAULT_NET_NAME = "bughouse-cd8cceab93fe.nnue"
WAKE_RE = re.compile(r"\bhb_wake_after_ms=(\d+)\b")


class EngineError(RuntimeError):
    pass


def bundled_hivemind():
    """The shipped engine's files, or EngineNotInstalled naming the fix."""
    mcp = Path(__file__).resolve().parents[1] / "mcp"
    if str(mcp) not in sys.path:
        sys.path.insert(0, str(mcp))
    from bughouse.paths import locate
    return locate()


def hypebeast_home() -> Path:
    """Where the HypeBeast project keeps ``bin/`` and ``nets/``."""
    return Path(os.environ.get("HYPEBEAST_HOME", Path.home() / "Projects/HypeBeast"))


def seat_option(board: int, color: chess.Color) -> str:
    """The ``Seat`` option value for a seat: ``Awhite`` ... ``Bblack``."""
    return SEAT_OPTION_VALUES[board * 2 + (0 if color == chess.WHITE else 1)]


def fsf_fen(position: CrazyhouseBoard) -> str:
    """One board as a Fairy-Stockfish bughouse FEN.

    Board with promoted pieces marked ``~``, the real pocket in brackets
    (white's pieces upper case, then black's lower case, ``QRBNP`` order;
    ``[]`` when empty), side to move, castling, the en-passant square only when
    a capture there is legal, then the halfmove clock and move number the
    referee tracks.
    """
    fields = position.fen(promoted=True, en_passant="legal").split(" ")
    order = (chess.QUEEN, chess.ROOK, chess.BISHOP, chess.KNIGHT, chess.PAWN)
    pocket = "".join(chess.piece_symbol(piece).upper() * position.pockets[chess.WHITE].count(piece)
                     for piece in order)
    pocket += "".join(chess.piece_symbol(piece) * position.pockets[chess.BLACK].count(piece)
                      for piece in order)
    return " ".join([f"{position.board_fen(promoted=True)}[{pocket}]", *fields[1:]])


def _option_table(lines: list[str]) -> dict[str, dict[str, str]]:
    """``option name X type T default D ...`` lines as {name: {type, default}}.

    Option names may contain spaces (``Use NNUE``), so the name runs up to the
    ``type`` keyword."""
    options = {}
    for line in lines:
        if not line.startswith("option name "):
            continue
        rest = line[len("option name "):]
        name, _, tail = rest.partition(" type ")
        tokens = tail.split()
        entry = {"type": tokens[0] if tokens else ""}
        if "default" in tokens:
            index = tokens.index("default")
            stop = next((i for i in range(index + 1, len(tokens))
                         if tokens[i] in ("min", "max", "var")), len(tokens))
            entry["default"] = " ".join(tokens[index + 1:stop])
        options[name.strip()] = entry
    return options


@dataclass
class EngineSpec:
    """One engine configuration, parsed from ``[kind,]key=value,...``.

    ``kind`` is ``hivemind`` (the default), ``hypebeast`` or ``fsf``. Known
    keys: ``bin``, ``nodes``, ``movetime``, ``name``; for Hivemind only,
    ``model`` and ``lib`` (directory holding the ONNX Runtime library); for
    the Fairy-Stockfish kinds, ``net`` (sent as ``EvalFile``). Anything else is
    sent as ``setoption name <key> value <value>``. Whatever ``bin``/``model``/
    ``lib`` leave out of a Hivemind spec comes from the bundled engine;
    ``hypebeast``/``fsf`` default to ``$HYPEBEAST_HOME/bin/{hypebeast,fsf-ref}``
    and ``$HYPEBEAST_HOME/nets/bughouse-cd8cceab93fe.nnue``.
    """
    binary: Path
    model: Path | None
    nodes: int | None = 800
    movetime_ms: int | None = None
    name: str = ""
    options: dict[str, str] = field(default_factory=dict)
    library_dir: Path | None = None
    kind: str = "hivemind"
    net: Path | None = None

    @classmethod
    def parse(cls, text: str, default_binary: Path | None = None) -> "EngineSpec":
        items = [part.strip() for part in text.split(",") if part.strip()]
        kind = "hivemind"
        if items[:1] and "=" not in items[0]:
            if items[0] not in KINDS:
                raise ValueError(f"unknown engine kind {items[0]!r} (expected one of {KINDS})")
            kind = items.pop(0)
        values: dict[str, str] = {}
        for item in items:
            if "=" not in item:
                raise ValueError(f"expected key=value in engine spec, got {item!r}")
            key, value = item.split("=", 1)
            values[key.strip()] = value.strip()
        nodes = values.pop("nodes", None)
        movetime = values.pop("movetime", None)
        if nodes and movetime:
            raise ValueError("engine spec takes nodes= or movetime=, not both")
        name = values.pop("name", "")

        if kind == "hivemind":
            if "net" in values:
                raise ValueError("net= is for the Fairy-Stockfish kinds; Hivemind takes model=")
            binary = values.pop("bin", None) or default_binary
            model = values.pop("model", None)
            library = values.pop("lib", None)
            if binary is None or model is None:
                files = bundled_hivemind()
                binary = binary or files.binary
                model = model or files.model
                library = library or files.library_dir
            spec = cls(Path(binary), Path(model),
                       nodes=int(nodes) if nodes else (None if movetime else 800),
                       movetime_ms=int(movetime) if movetime else None,
                       name=name, options=values,
                       library_dir=Path(library) if library else None)
        else:
            for key in ("model", "lib"):
                if key in values:
                    raise ValueError(f"{key}= applies only to Hivemind, not {kind}")
            if not nodes and not movetime:
                raise ValueError(f"a {kind} spec needs nodes= or movetime=")
            home = hypebeast_home()
            binary = values.pop("bin", None) or home / "bin" / (
                "hypebeast" if kind == "hypebeast" else "fsf-ref")
            net = values.pop("net", None) or home / "nets" / DEFAULT_NET_NAME
            for reserved in ("UCI_Variant", "EvalFile", "HypeBeast", "Seat", "Clocks",
                             "Team", "TimeAdvantage"):
                if reserved in values:
                    raise ValueError(f"{reserved} is set by the arena, not the spec")
            if kind == "hypebeast":
                coordination = values.get("Coordination", "true").lower()
                if coordination not in ("true", "false"):
                    raise ValueError("Coordination must be true or false")
                values["Coordination"] = coordination
            elif "Coordination" in values:
                raise ValueError("Coordination applies only to hypebeast")
            spec = cls(Path(binary), None,
                       nodes=int(nodes) if nodes else None,
                       movetime_ms=int(movetime) if movetime else None,
                       name=name, options=values, kind=kind, net=Path(net))
        if not spec.name:
            budget = f"n{spec.nodes}" if spec.nodes else f"t{spec.movetime_ms}"
            if kind == "hivemind":
                spec.name = f"{spec.model.stem}-{budget}"
            elif kind == "hypebeast":
                mode = "coord" if spec.options["Coordination"] == "true" else "nocoord"
                spec.name = f"hypebeast-{mode}-{budget}"
            else:
                spec.name = f"fsf-{budget}"
        return spec

    @property
    def go_command(self) -> str:
        return (f"go nodes {self.nodes}" if self.nodes
                else f"go movetime {self.movetime_ms}")

    def describe(self) -> dict:
        info = {"kind": self.kind, "name": self.name, "binary": str(self.binary),
                "nodes": self.nodes, "movetime_ms": self.movetime_ms,
                "options": dict(self.options)}
        if self.kind == "hivemind":
            info["model"] = str(self.model)
            info["library_dir"] = str(self.library_dir) if self.library_dir else None
        else:
            info["net"] = str(self.net)
        if self.kind == "fsf":
            info["label"] = FSF_LABEL
            info["limitations"] = FSF_LIMITATIONS
        return info


class UciProcess:
    """A line-oriented engine process that waits for each answer."""

    def __init__(self, command: list[str], env: dict[str, str] | None = None,
                 log_path: Path | None = None):
        self.process = subprocess.Popen(
            command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, text=True, bufsize=1, env=env)
        self.lines: queue.Queue[str | None] = queue.Queue()
        self.log = open(log_path, "a") if log_path else None
        self.reader = threading.Thread(target=self._read, daemon=True)
        self.reader.start()

    def _read(self) -> None:
        assert self.process.stdout is not None
        for line in self.process.stdout:
            self.lines.put(line.rstrip("\n"))
        self.lines.put(None)

    def send(self, command: str) -> None:
        if self.log:
            self.log.write(f">>> {command}\n")
        try:
            assert self.process.stdin is not None
            self.process.stdin.write(command + "\n")
            self.process.stdin.flush()
        except (BrokenPipeError, OSError) as error:
            raise EngineError(f"engine exited (sending {command!r})") from error

    def read_until(self, prefix: str, timeout: float) -> list[str]:
        deadline = time.monotonic() + timeout
        seen: list[str] = []
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise EngineError(f"timed out after {timeout:.0f}s waiting for {prefix!r}")
            try:
                line = self.lines.get(timeout=remaining)
            except queue.Empty:
                continue
            if line is None:
                tail = " | ".join(seen[-5:])
                raise EngineError(f"engine exited waiting for {prefix!r}: {tail}")
            if self.log:
                self.log.write(line + "\n")
            seen.append(line)
            if line.startswith(prefix):
                return seen

    def close(self) -> None:
        if self.process.poll() is None:
            try:
                self.send("quit")
                self.process.wait(timeout=10)
            except (EngineError, subprocess.TimeoutExpired):
                self.process.kill()
                self.process.wait()
        self.reader.join(timeout=5)
        for pipe in (self.process.stdin, self.process.stdout):
            if pipe:
                try:
                    pipe.close()
                except OSError:
                    pass
        if self.log:
            self.log.close()


def _last_nodes(lines: list[str]) -> int | None:
    for line in reversed(lines):
        tokens = line.split()
        if (tokens[:1] == ["info"] and tokens[1:2] != ["string"]
                and "nodes" in tokens[:-1]):
            value = tokens[tokens.index("nodes") + 1]
            return int(value) if value.isdigit() else None
    return None


class UciSeat:
    """What every UCI seat shares: the handshake, option bookkeeping, timed
    searches and per-game statistics."""

    def __init__(self, spec: EngineSpec, command: list[str], env: dict[str, str] | None,
                 search_timeout: float, log_path: Path | None):
        self.spec = spec
        self.name = spec.name
        self.search_timeout = search_timeout
        self.uci = UciProcess(command, env=env, log_path=log_path)
        self.uci.send("uci")
        self.uci_lines = self.uci.read_until("uciok", 120)
        self.advertised = _option_table(self.uci_lines)
        self.sent_options: dict[str, str] = {}
        self.board = 0
        self.color = chess.WHITE
        self.searches = 0
        self.nodes = 0
        self.seconds = 0.0
        self.game_stats = self._fresh_stats()

    @staticmethod
    def _fresh_stats() -> dict:
        return {"searches": 0, "nodes": 0, "latency_ms": [], "passes": 0,
                "mandatory_sits": 0, "wake_requests": 0, "null_outputs": 0}

    def identity(self) -> dict:
        """The engine's self-description, for the run manifest."""
        return {
            "id": {line.split(None, 2)[1]: line.split(None, 2)[2]
                   for line in self.uci_lines
                   if line.startswith("id ") and len(line.split(None, 2)) == 3},
            "info_strings": [line for line in self.uci_lines if line.startswith("info string")],
            "banner": [line for line in self.uci_lines
                       if line and not line.startswith(("option ", "id ", "uciok", "info "))],
            "advertised_options": self.advertised,
            "sent_options": dict(self.sent_options),
        }

    def _setoption(self, name: str, value: str) -> None:
        self.uci.send(f"setoption name {name} value {value}")
        self.sent_options[name] = value

    def _require(self, name: str) -> None:
        if name not in self.advertised:
            raise EngineError(f"{self.spec.binary} does not advertise option {name!r}")

    def _apply_spec_options(self) -> None:
        for key, value in self.spec.options.items():
            if key not in self.advertised:
                raise EngineError(f"{self.spec.binary} has no option {key!r}")
            self._setoption(key, value)

    def _sync(self) -> None:
        self.uci.send("isready")
        self.uci.read_until("readyok", 120)

    def _search(self, go: str) -> tuple[list[str], float]:
        started = time.monotonic()
        self.uci.send(go)
        lines = self.uci.read_until("bestmove", self.search_timeout)
        elapsed = time.monotonic() - started
        self.seconds += elapsed
        self.searches += 1
        nodes = _last_nodes(lines)
        if nodes is not None:
            self.nodes += nodes
        stats = self.game_stats
        stats["searches"] += 1
        stats["nodes"] += nodes or 0
        stats["latency_ms"].append(round(elapsed * 1000, 1))
        return lines, elapsed

    def new_game(self, board: int, color: chess.Color) -> None:
        self.board = board
        self.color = color
        self.game_stats = self._fresh_stats()

    def close(self) -> None:
        self.uci.close()


class TeamEngineSeat(UciSeat):
    """One seat played by a team engine (Hivemind or HypeBeast): dual-FEN
    position, joint ``bestmove (moveA,moveB)``."""

    def __init__(self, spec: EngineSpec, ort_threads: int | None = None,
                 search_timeout: float = 300.0, log_path: Path | None = None):
        env = dict(os.environ)
        if spec.kind == "hivemind":
            library_key = {"Darwin": "DYLD_LIBRARY_PATH", "Windows": "PATH"}.get(
                platform.system(), "LD_LIBRARY_PATH")
            if spec.library_dir:
                env[library_key] = os.pathsep.join(
                    p for p in (str(spec.library_dir), env.get(library_key)) if p)
            if ort_threads:
                env["HIVEMIND_ORT_THREADS"] = str(ort_threads)
            command = [str(spec.binary), "--model", str(spec.model)]
        else:
            command = [str(spec.binary)]
        super().__init__(spec, command, env, search_timeout, log_path)
        advertised = self.advertised
        if spec.kind == "hivemind":
            # Pondering off: an idle seat must not search on another seat's
            # time. Builds without the PermanentBrain option get an explicit
            # stop after every bestmove instead.
            self.stop_after_bestmove = "PermanentBrain" not in advertised
            self._setoption("Ponder", "false")
            if not self.stop_after_bestmove:
                self._setoption("PermanentBrain", "false")
        else:
            # HypeBeast computes nothing between calls and answers each go once.
            self.stop_after_bestmove = False
            for name in ("HypeBeast", "Coordination", "Seat", "Team", "TimeAdvantage"):
                self._require(name)
            if "Ponder" in advertised:
                self._setoption("Ponder", "false")
            self._setoption("UCI_Variant", "bughouse")
            self._setoption("EvalFile", str(spec.net))
            self._setoption("HypeBeast", "true")
        self._apply_spec_options()
        self.sends_seat = "Seat" in advertised
        self.sends_clocks = "Clocks" in advertised
        self._sync()
        self.advantage: bool | None = None
        self.nnue_lines: list[str] = []

    def new_game(self, board: int, color: chess.Color) -> None:
        super().new_game(board, color)
        team = color if board == 0 else not color
        self.uci.send("ucinewgame")
        self._setoption("Team", team_name(team))
        if self.sends_seat:
            self._setoption("Seat", seat_option(board, color))
        self.advantage = None
        self._sync()

    def position_command(self, view: SeatView) -> str:
        game = view.game
        moves = " ".join(game.engine_moves())
        if game.start_fens == (STARTING_FEN, STARTING_FEN):
            base = "position startpos"
        else:
            base = f"position fen {game.start_fens[0]}|{game.start_fens[1]}"
        return f"{base} moves {moves}" if moves else base

    def decide(self, view: SeatView) -> str | None:
        self.requested_wake_ms = None
        if view.time_advantage != self.advantage:
            self._setoption("TimeAdvantage", "true" if view.time_advantage else "false")
            self.advantage = view.time_advantage
        if self.sends_clocks:
            self._setoption("Clocks", ",".join(str(int(c)) for c in view.clocks_ms))
        self.uci.send(self.position_command(view))
        lines, _ = self._search(self.spec.go_command)
        if self.stop_after_bestmove:
            self.uci.send("stop")
        if self.spec.kind != "hivemind" and not self.nnue_lines:
            self.nnue_lines = [line for line in lines if "NNUE evaluation using" in line]
        move = self.parse_bestmove(lines[-1], self.board)
        if move is None:
            self.game_stats["passes"] += 1
            # Opt-in wake request: only engines that print it get one, and only
            # the request made during this search counts.
            for line in lines:
                if line.startswith("info string"):
                    match = WAKE_RE.search(line)
                    if match:
                        self.requested_wake_ms = int(match.group(1))
            if self.requested_wake_ms is not None:
                self.game_stats["wake_requests"] += 1
        return move

    @staticmethod
    def parse_bestmove(line: str, board: int) -> str | None:
        tokens = line.split()
        if len(tokens) < 2 or tokens[1] == "(none)":
            return None
        joint = tokens[1]
        if not (joint.startswith("(") and joint.endswith(")")) or joint.count(",") != 1:
            raise EngineError(f"unexpected bestmove {line!r}")
        move = joint[1:-1].split(",")[board]
        return None if move == "pass" else move


# Existing callers and tests know the joint-protocol seat by this name.
HivemindSeat = TeamEngineSeat


class FsfSeat(UciSeat):
    """Unmodified Fairy-Stockfish bughouse via the UCI snapshot adapter."""

    label = FSF_LABEL

    def __init__(self, spec: EngineSpec, search_timeout: float = 300.0,
                 log_path: Path | None = None, **_ignored):
        super().__init__(spec, [str(spec.binary)], dict(os.environ), search_timeout, log_path)
        for name in ("UCI_Variant", "EvalFile"):
            self._require(name)
        if "Ponder" in self.advertised:
            self._setoption("Ponder", "false")
        self._setoption("UCI_Variant", "bughouse")
        self._setoption("EvalFile", str(spec.net))
        self._apply_spec_options()
        self._sync()
        self.nnue_lines: list[str] = []
        self.requested_wake_ms = None

    def new_game(self, board: int, color: chess.Color) -> None:
        super().new_game(board, color)
        self.uci.send("ucinewgame")
        self._sync()

    def position_command(self, view: SeatView) -> str:
        return f"position fen {fsf_fen(view.game.boards[view.board])}"

    def decide(self, view: SeatView) -> str | None:
        if not view.game.has_legal_move(view.board):
            # The referee says play goes on (else it would not ask), but this
            # seat cannot move: it has to sit. That is protocol plumbing, not
            # an engine decision, so the engine is not consulted.
            self.game_stats["mandatory_sits"] += 1
            return None
        self.uci.send(self.position_command(view))
        lines, _ = self._search(self.spec.go_command)
        if not self.nnue_lines:
            expected = Path(str(self.spec.net)).name
            self.nnue_lines = [line for line in lines
                               if "NNUE evaluation using" in line and expected in line]
            if not self.nnue_lines:
                raise EngineError(
                    f"{self.spec.binary} did not report NNUE evaluation with {expected}: "
                    + " | ".join(line for line in lines if line.startswith("info string")))
        tokens = lines[-1].split()
        if len(tokens) < 2:
            raise EngineError(f"unexpected bestmove {lines[-1]!r}")
        move = tokens[1]
        if move in ("(none)", "0000"):
            # Legal moves exist, so a null answer is a failure. Hand it to the
            # referee unchanged: it rejects it as an illegal move, which loses
            # and is logged. Never substitute a move.
            self.game_stats["null_outputs"] += 1
        return move


class RandomPlayer:
    """Uniformly random legal moves, sitting with a fixed probability."""

    def __init__(self, seed: int = 0, sit_probability: float = 0.0, name: str = "random"):
        self.rng = random.Random(seed)
        self.sit_probability = sit_probability
        self.name = name

    def new_game(self, board: int, color: chess.Color) -> None:
        pass

    def decide(self, view: SeatView) -> str | None:
        moves = sorted(view.game.legal_moves(view.board))
        if not moves or self.rng.random() < self.sit_probability:
            return None
        return self.rng.choice(moves)

    def close(self) -> None:
        pass


def make_seat(spec: EngineSpec, ort_threads: int | None = None,
              log_path: Path | None = None, search_timeout: float = 300.0):
    if spec.kind == "fsf":
        return FsfSeat(spec, search_timeout=search_timeout, log_path=log_path)
    return TeamEngineSeat(spec, ort_threads=ort_threads, search_timeout=search_timeout,
                          log_path=log_path)
