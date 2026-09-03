"""A client for Hivemind, the neural-network bughouse engine.

It speaks UCI, but not the UCI a chess GUI expects, because a bughouse
decision is not a chess decision:

  * ``position fen <boardA>|<boardB>`` — two crazyhouse FENs, pipe-separated.
  * Moves carry a board digit: ``1e2e4`` is e2e4 on board A, ``2d7d5`` on B.
  * ``bestmove (d2d4,pass)`` — a *joint* action, one half per board, where
    ``pass`` (deliberately not moving) is legal and often correct.
  * Three options carry the rules a chess engine has no place for: ``Team``,
    ``TimeAdvantage`` (only a team ahead on the diagonal clock may sit) and
    ``RequireMoveOn`` (forbid passing on one board).

``go`` is asynchronous and the engine keeps thinking in a permanent-brain loop
after ``bestmove``, so a caller must wait for ``bestmove`` rather than firing
commands back to back.
"""

from __future__ import annotations

import os
import platform
import queue
import re
import subprocess
import threading
from dataclasses import dataclass, field
from pathlib import Path

from .paths import EngineFiles, locate

PASS = "pass"


class EngineError(Exception):
    """The engine could not be started, or did not answer in time."""


@dataclass(frozen=True)
class JointMove:
    """One decision about two boards at once. ``None`` means sitting."""

    a: str | None
    b: str | None

    @classmethod
    def parse(cls, text: str) -> "JointMove | None":
        text = text.strip()
        if not (text.startswith("(") and text.endswith(")")):
            return None
        parts = text[1:-1].split(",")
        if len(parts) != 2:
            return None  # "(none)" — the engine had nothing to say.
        half = lambda t: None if t.strip() in (PASS, "none", "(none)", "") else t.strip()
        return cls(half(parts[0]), half(parts[1]))

    def half(self, which: int) -> str | None:
        return self.a if which == 0 else self.b

    @property
    def is_empty(self) -> bool:
        return self.a is None and self.b is None

    def __str__(self) -> str:
        return f"({self.a or PASS},{self.b or PASS})"

    def as_dict(self) -> dict:
        return {"A": self.a or PASS, "B": self.b or PASS, "uci": str(self)}


@dataclass
class Line:
    """One ``info`` line: a score, and the joint moves it expects to follow."""

    depth: int = 0
    multipv: int = 1
    score_cp: int | None = None
    mate: int | None = None
    nodes: int = 0
    nps: int = 0
    time_ms: int = 0
    pv: list[JointMove] = field(default_factory=list)

    @property
    def pawns(self) -> float | None:
        return None if self.score_cp is None else self.score_cp / 100.0

    @property
    def score(self) -> str:
        if self.mate is not None:
            return f"#{self.mate}"
        return "?" if self.score_cp is None else f"{self.score_cp / 100.0:+.2f}"

    def as_dict(self) -> dict:
        return {
            "score": self.score,
            "cp": self.score_cp,
            "mate": self.mate,
            "depth": self.depth,
            "multipv": self.multipv,
            "nodes": self.nodes,
            "nps": self.nps,
            "time_ms": self.time_ms,
            "pv": [str(m) for m in self.pv],
            "best": self.pv[0].as_dict() if self.pv else None,
        }


@dataclass
class SearchResult:
    best: JointMove | None
    ponder: JointMove | None
    lines: list[Line]

    @property
    def top(self) -> Line | None:
        return self.lines[0] if self.lines else None

    def as_dict(self) -> dict:
        return {
            "best": self.best.as_dict() if self.best else None,
            "ponder": str(self.ponder) if self.ponder else None,
            "score": self.top.score if self.top else None,
            "cp": self.top.score_cp if self.top else None,
            "depth": self.top.depth if self.top else 0,
            "nodes": self.top.nodes if self.top else 0,
            "lines": [line.as_dict() for line in self.lines],
        }


_INFO = re.compile(r"\b(depth|multipv|nodes|nps|time)\s+(-?\d+)")
_SCORE = re.compile(r"\bscore\s+(cp|mate)\s+(-?\d+)")


class HivemindEngine:
    """One engine process. Not thread-safe: one search at a time, by design —
    the network already saturates the cores it was given."""

    def __init__(
        self,
        files: EngineFiles | None = None,
        *,
        hash_mb: int | None = None,
        batch_size: int | None = None,
    ):
        self.files = files or locate()
        env = dict(os.environ)
        # Windows needs nothing here: the loader searches the executable's own
        # directory, which is the cwd we start it in. (`os.uname` does not even
        # exist there, so asking would raise rather than degrade.)
        key = {"Darwin": "DYLD_LIBRARY_PATH", "Windows": None}.get(
            platform.system(), "LD_LIBRARY_PATH"
        )
        if self.files.library_dir and key:
            env[key] = os.pathsep.join(
                p for p in (str(self.files.library_dir), env.get(key)) if p
            )
        try:
            self._proc = subprocess.Popen(
                [str(self.files.binary), "--model", str(self.files.model)],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                bufsize=1,
                env=env,
                cwd=str(Path(self.files.binary).parent),
            )
        except OSError as e:
            raise EngineError(f"Could not start {self.files.binary}: {e}") from None

        self._lines: queue.Queue[str] = queue.Queue()
        self._stderr: list[str] = []
        self.name = "hivemind"
        self.backend = ""
        self.backend_detail = ""
        self._reader = threading.Thread(target=self._pump, daemon=True)
        self._reader.start()
        threading.Thread(target=self._pump_stderr, daemon=True).start()
        self._handshake(hash_mb, batch_size)

    # ── Process plumbing ──────────────────────────────────────────────────

    def _pump(self) -> None:
        try:
            for line in self._proc.stdout:
                self._lines.put(line.rstrip("\n"))
        except ValueError:
            pass  # the pipe was closed under us by close()
        self._lines.put(None)  # type: ignore[arg-type]

    def _pump_stderr(self) -> None:
        try:
            for line in self._proc.stderr:
                self._stderr.append(line.rstrip("\n"))
                del self._stderr[:-40]
        except ValueError:
            pass

    def send(self, command: str) -> None:
        if self._proc.poll() is not None:
            raise EngineError(f"Engine exited ({self._proc.returncode}). {self.why()}")
        self._proc.stdin.write(command + "\n")
        self._proc.stdin.flush()

    def why(self) -> str:
        return "\n".join(self._stderr[-8:])

    def _read_until(self, predicate, timeout: float, what: str) -> list[str]:
        """Collects output until `predicate(line)` is true, then returns it."""
        import time

        deadline = time.monotonic() + timeout
        collected: list[str] = []
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise EngineError(
                    f"Engine did not answer {what!r} within {timeout:.0f}s. {self.why()}"
                )
            try:
                line = self._lines.get(timeout=min(remaining, 1.0))
            except queue.Empty:
                continue
            if line is None:
                raise EngineError(f"Engine exited while waiting for {what!r}. {self.why()}")
            collected.append(line)
            self._observe(line)
            if predicate(line):
                return collected

    def _observe(self, line: str) -> None:
        if line.startswith("id name "):
            self.name = line[len("id name ") :].strip()
        elif line.startswith("info string backend "):
            rest = line[len("info string backend ") :]
            self.backend = rest.split(" model ")[0].strip()
            # "... batch 8 workers 4 intra-op threads 5" — what the engine
            # chose, which is the only answer there is to "how many cores".
            self.backend_detail = rest

    # ── Protocol ──────────────────────────────────────────────────────────

    def _handshake(self, hash_mb: int | None, batch_size: int | None) -> None:
        self.send("uci")
        self._read_until(lambda l: l.strip() == "uciok", 120, "uci")
        # These two are the only resource knobs Hivemind advertises. There is
        # deliberately no `Threads`: `uci` never offers one, and a
        # `setoption name Threads` is swallowed without changing the "workers
        # N intra-op threads N" the engine reports — so setting it, as this
        # did, only looked like it was doing something.
        if hash_mb:
            self.set_option("Hash", hash_mb)
        if batch_size:
            self.set_option("BatchSize", batch_size)
        self.is_ready()

    def is_ready(self, timeout: float = 120) -> None:
        self.send("isready")
        self._read_until(lambda l: l.strip() == "readyok", timeout, "isready")

    def set_option(self, name: str, value) -> None:
        if isinstance(value, bool):
            value = "true" if value else "false"
        self.send(f"setoption name {name} value {value}")

    def configure(
        self,
        *,
        team: str = "white",
        time_advantage: bool = False,
        require_move_on: str = "none",
        multipv: int = 1,
    ) -> None:
        # Accepts "white"/"black" in any case, and a bare bool the way the
        # engine's own option reads. `team in (True, "white")` used to make 1
        # mean white and "White" mean black.
        self.set_option("Team", "white" if str(team).lower().startswith(("w", "t")) else "black")
        self.set_option("TimeAdvantage", bool(time_advantage))
        self.set_option("RequireMoveOn", {"a": "A", "b": "B"}.get(str(require_move_on).lower(), "none"))
        self.set_option("MultiPV", max(1, int(multipv)))
        self.is_ready()

    def new_game(self) -> None:
        self.send("ucinewgame")
        self.is_ready()

    def set_position(self, dual_fen: str, moves: list[str] | None = None) -> None:
        suffix = f" moves {' '.join(moves)}" if moves else ""
        self.send(f"position fen {dual_fen}{suffix}")
        self.is_ready()

    def search(self, *, movetime_ms: int | None = None, nodes: int | None = None) -> SearchResult:
        """Runs one search and returns when ``bestmove`` arrives."""
        if nodes:
            self.send(f"go nodes {int(nodes)}")
            budget = 600.0
        else:
            ms = int(movetime_ms or 1000)
            self.send(f"go movetime {ms}")
            budget = ms / 1000.0 + 120.0
        output = self._read_until(lambda l: l.startswith("bestmove"), budget, "go")
        result = self._collect(output)
        # The engine would otherwise keep a permanent-brain search running on
        # every core between calls, starving the next one.
        self.send("stop")
        return result

    @staticmethod
    def _collect(output: list[str]) -> SearchResult:
        by_pv: dict[int, Line] = {}
        best = ponder = None
        for text in output:
            if text.startswith("bestmove"):
                head, _, tail = text[len("bestmove ") :].partition(" ponder ")
                best = JointMove.parse(head)
                ponder = JointMove.parse(tail) if tail else None
            elif text.startswith("info ") and " depth " in text:
                line = HivemindEngine._parse_info(text)
                if line is not None:
                    by_pv[line.multipv] = line
        return SearchResult(best, ponder, [by_pv[k] for k in sorted(by_pv)])

    @staticmethod
    def _parse_info(text: str) -> Line | None:
        line = Line()
        for key, value in _INFO.findall(text):
            setattr(line, {"time": "time_ms"}.get(key, key), int(value))
        score = _SCORE.search(text)
        if score:
            if score.group(1) == "cp":
                line.score_cp = int(score.group(2))
            else:
                line.mate = int(score.group(2))
        _, _, pv = text.partition(" pv ")
        line.pv = [m for m in (JointMove.parse(t) for t in pv.split()) if m]
        if line.depth == 0 and not line.pv:
            return None
        return line

    # ── Lifetime ──────────────────────────────────────────────────────────

    def close(self) -> None:
        if self._proc.poll() is None:
            try:
                self.send("stop")
                self.send("quit")
                self._proc.wait(timeout=5)
            except Exception:
                self._proc.kill()
                self._proc.wait(timeout=5)
        self._reader.join(timeout=2)
        for pipe in (self._proc.stdin, self._proc.stdout, self._proc.stderr):
            try:
                if pipe is not None:
                    pipe.close()
            except Exception:
                pass

    def __enter__(self) -> "HivemindEngine":
        return self

    def __exit__(self, *exc) -> None:
        self.close()


_SHARED: HivemindEngine | None = None


def shared() -> HivemindEngine:
    """One engine per server process. Loading the 54 MB network costs a couple
    of seconds, and every tool here wants the same one."""
    global _SHARED
    if _SHARED is None or _SHARED._proc.poll() is not None:
        _SHARED = HivemindEngine()
    return _SHARED


def close_shared() -> None:
    global _SHARED
    if _SHARED is not None:
        _SHARED.close()
        _SHARED = None
