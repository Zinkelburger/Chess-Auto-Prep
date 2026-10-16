"""Talk UCI to the tools binary.

The variant-nnue-tools build is a whole Fairy-Stockfish, so the same process
answers `go depth 4` for scoring, `eval`-style probes for the held-out test,
and the data commands (`convert_bin`, `validate_training_data`), which run
inside the UCI loop and finish before the next `isready` is answered.
"""

from __future__ import annotations

import subprocess
from pathlib import Path

#: Fairy-Stockfish reports `cp` as value * 100 / PawnValueEg; the training
#: data wants the engine's internal value back.
PAWN_VALUE_EG = 208

#: Where a mate score lands in the training data.  The generator's default
#: `eval_limit` is 3000; a mate is "as won as it gets" at that scale.
MATE_SCORE = 3000


def to_internal(cp: int) -> int:
    return round(cp * PAWN_VALUE_EG / 100)


class Engine:
    def __init__(self, binary: Path, variant: str, options: dict[str, str] | None = None):
        self.proc = subprocess.Popen(
            [str(binary)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, text=True, bufsize=1,
        )
        self.send("uci")
        self.read_until("uciok")
        self.setoption("UCI_Variant", variant)
        self.setoption("Threads", "1")
        for name, value in (options or {}).items():
            self.setoption(name, value)
        self.ready()
        if options and options.get("Use NNUE", "false") != "false":
            # A net that does not load is only reported on the first search,
            # after which the engine exits; find out now, with the message.
            # And a net whose file name does not start with the variant is
            # ignored without a word (evaluate.cpp restricts nets to their
            # variant by name), so insist on seeing it switched on.
            self.send("position startpos")
            self.send("go depth 1")
            lines = self.read_until("bestmove")
            errors = [l for l in lines if "ERROR" in l]
            if errors:
                raise RuntimeError("engine rejected the net:\n" + "\n".join(errors))
            if not any("NNUE evaluation using" in l for l in lines):
                raise RuntimeError(
                    f"engine kept its classical eval; a {variant} net's file name must "
                    f"start with '{variant}' (got {options.get('EvalFile')})"
                )

    # ── Plumbing ──────────────────────────────────────────────────────────

    def send(self, line: str) -> None:
        assert self.proc.stdin is not None
        self.proc.stdin.write(line + "\n")
        self.proc.stdin.flush()

    def read_until(self, prefix: str) -> list[str]:
        """Lines up to and including the first that starts with `prefix`."""
        assert self.proc.stdout is not None
        out: list[str] = []
        while True:
            line = self.proc.stdout.readline()
            if not line:
                raise RuntimeError(f"engine exited while waiting for {prefix!r}: {''.join(out[-5:])}")
            line = line.rstrip("\n")
            out.append(line)
            if line.startswith(prefix):
                return out
            if "The engine will be terminated now" in line:
                raise RuntimeError("engine terminated:\n" + "\n".join(out[-6:]))

    def setoption(self, name: str, value: str) -> None:
        self.send(f"setoption name {name} value {value}")

    def ready(self) -> list[str]:
        self.send("isready")
        return self.read_until("readyok")

    def new_game(self) -> None:
        """Clear the hash table, so one game's search does not steer the next."""
        self.send("ucinewgame")
        self.ready()

    def command(self, text: str) -> list[str]:
        """Run a synchronous tools command and return what it printed."""
        self.send(text)
        return self.ready()[:-1]

    def close(self) -> None:
        try:
            self.send("quit")
            self.proc.wait(timeout=10)
        except (OSError, subprocess.TimeoutExpired, ValueError):
            self.proc.kill()
        for pipe in (self.proc.stdin, self.proc.stdout):
            if pipe is not None:
                pipe.close()

    def __enter__(self) -> "Engine":
        return self

    def __exit__(self, *exc) -> None:
        self.close()

    # ── Searching ─────────────────────────────────────────────────────────

    def search(self, fen: str, depth: int | None = None, nodes: int | None = None) -> tuple[int, str]:
        """(score in internal units from the side to move, best move)."""
        if not nodes and not depth:
            raise ValueError("search needs nodes or depth; without one the engine never stops")
        self.send(f"position fen {fen}")
        self.send(f"go nodes {nodes}" if nodes else f"go depth {depth}")
        lines = self.read_until("bestmove")
        score = 0
        for line in lines:
            if not line.startswith("info") or " score " not in line:
                continue
            parts = line.split()
            i = parts.index("score")
            kind, value = parts[i + 1], int(parts[i + 2])
            if kind == "cp":
                score = to_internal(value)
            elif kind == "mate":
                score = MATE_SCORE if value > 0 else -MATE_SCORE
        best = lines[-1].split()
        return score, best[1] if len(best) > 1 else "(none)"
