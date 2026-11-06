"""Players the arena can seat: Hivemind over UCI, and a random mover for tests.

``hivemind`` on its own means the engine the app ships, found the way the
bughouse MCP server finds it (tools/mcp/bughouse/paths.py): ``HIVEMIND_BIN`` /
``HIVEMIND_MODEL``, the app's unpacked bundle, or ``assets/bughouse``.

Every seat gets its own engine process, so two different engines can share a
team and a later per-seat engine (an NNUE searcher, say) plugs into the same
interface. Hivemind is a team engine: it searches a joint action for both of
its team's boards. A seat keeps only the half for its own board and treats
``pass`` as sitting; the partner seat asks its own process when it is on turn.
"""

from __future__ import annotations

import os
import platform
import queue
import random
import subprocess
import sys
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path

import chess

from .referee import STARTING_FEN, team_name
from .sim import SeatView


class EngineError(RuntimeError):
    pass


def bundled_hivemind():
    """The shipped engine's files, or EngineNotInstalled naming the fix."""
    mcp = Path(__file__).resolve().parents[1] / "mcp"
    if str(mcp) not in sys.path:
        sys.path.insert(0, str(mcp))
    from bughouse.paths import locate
    return locate()


@dataclass
class EngineSpec:
    """One engine configuration, parsed from ``[hivemind,]key=value,...``.

    Known keys: ``bin``, ``model``, ``lib`` (directory holding the ONNX
    Runtime library), ``nodes``, ``movetime``, ``name``. Anything else is sent
    as ``setoption name <key> value <value>``. Whatever ``bin``/``model``/``lib``
    leave out comes from the bundled engine.
    """
    binary: Path
    model: Path
    nodes: int | None = 800
    movetime_ms: int | None = None
    name: str = ""
    options: dict[str, str] = field(default_factory=dict)
    library_dir: Path | None = None

    @classmethod
    def parse(cls, text: str, default_binary: Path | None = None) -> "EngineSpec":
        items = [part.strip() for part in text.split(",") if part.strip()]
        if items[:1] == ["hivemind"]:
            items = items[1:]
        values: dict[str, str] = {}
        for item in items:
            if "=" not in item:
                raise ValueError(f"expected key=value in engine spec, got {item!r}")
            key, value = item.split("=", 1)
            values[key.strip()] = value.strip()
        binary = values.pop("bin", None) or default_binary
        model = values.pop("model", None)
        library = values.pop("lib", None)
        if binary is None or model is None:
            files = bundled_hivemind()
            binary = binary or files.binary
            model = model or files.model
            library = library or files.library_dir
        nodes = values.pop("nodes", None)
        movetime = values.pop("movetime", None)
        if nodes and movetime:
            raise ValueError("engine spec takes nodes= or movetime=, not both")
        spec = cls(Path(binary), Path(model),
                   nodes=int(nodes) if nodes else (None if movetime else 800),
                   movetime_ms=int(movetime) if movetime else None,
                   name=values.pop("name", ""),
                   options=values,
                   library_dir=Path(library) if library else None)
        if not spec.name:
            budget = f"n{spec.nodes}" if spec.nodes else f"t{spec.movetime_ms}"
            spec.name = f"{spec.model.stem}-{budget}"
        return spec

    def describe(self) -> dict:
        return {"name": self.name, "binary": str(self.binary), "model": str(self.model),
                "library_dir": str(self.library_dir) if self.library_dir else None,
                "nodes": self.nodes, "movetime_ms": self.movetime_ms,
                "options": dict(self.options)}


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


class HivemindSeat:
    """One seat played by a Hivemind process."""

    def __init__(self, spec: EngineSpec, ort_threads: int | None = None,
                 search_timeout: float = 300.0, log_path: Path | None = None):
        self.spec = spec
        self.name = spec.name
        self.search_timeout = search_timeout
        env = dict(os.environ)
        library_key = {"Darwin": "DYLD_LIBRARY_PATH", "Windows": "PATH"}.get(
            platform.system(), "LD_LIBRARY_PATH")
        if spec.library_dir:
            env[library_key] = os.pathsep.join(
                p for p in (str(spec.library_dir), env.get(library_key)) if p)
        if ort_threads:
            env["HIVEMIND_ORT_THREADS"] = str(ort_threads)
        self.uci = UciProcess([str(spec.binary), "--model", str(spec.model)],
                              env=env, log_path=log_path)
        self.uci.send("uci")
        lines = self.uci.read_until("uciok", 120)
        advertised = {line.split()[2] for line in lines
                      if line.startswith("option name ") and len(line.split()) > 2}
        # Pondering off: an idle seat must not search on another seat's time.
        # Builds without the PermanentBrain option get an explicit stop after
        # every bestmove instead.
        self.stop_after_bestmove = "PermanentBrain" not in advertised
        self._setoption("Ponder", "false")
        if not self.stop_after_bestmove:
            self._setoption("PermanentBrain", "false")
        for key, value in spec.options.items():
            if key not in advertised:
                raise EngineError(f"{spec.binary} has no option {key!r}")
            self._setoption(key, value)
        self._sync()
        self.board = 0
        self.advantage: bool | None = None
        self.searches = 0
        self.nodes = 0
        self.seconds = 0.0

    def _setoption(self, name: str, value: str) -> None:
        self.uci.send(f"setoption name {name} value {value}")

    def _sync(self) -> None:
        self.uci.send("isready")
        self.uci.read_until("readyok", 120)

    def new_game(self, board: int, color: chess.Color) -> None:
        self.board = board
        team = color if board == 0 else not color
        self.uci.send("ucinewgame")
        self._setoption("Team", team_name(team))
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
        if view.time_advantage != self.advantage:
            self._setoption("TimeAdvantage", "true" if view.time_advantage else "false")
            self.advantage = view.time_advantage
        self.uci.send(self.position_command(view))
        go = (f"go nodes {self.spec.nodes}" if self.spec.nodes
              else f"go movetime {self.spec.movetime_ms}")
        started = time.monotonic()
        self.uci.send(go)
        lines = self.uci.read_until("bestmove", self.search_timeout)
        self.seconds += time.monotonic() - started
        self.searches += 1
        for line in reversed(lines):
            tokens = line.split()
            if (tokens[:1] == ["info"] and tokens[1:2] != ["string"]
                    and "nodes" in tokens[:-1]):
                value = tokens[tokens.index("nodes") + 1]
                if value.isdigit():
                    self.nodes += int(value)
                break
        if self.stop_after_bestmove:
            self.uci.send("stop")
        return self.parse_bestmove(lines[-1], self.board)

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

    def close(self) -> None:
        self.uci.close()


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
