"""Tool registry for the bughouse MCP server.

Six tools, three of which need no engine at all:

    status        what engine is installed, and does it start
    position      play a line and read both boards back — FENs, reserves, and
                  each board's own movetext
    legal_moves   every legal move on one board, drops included, as SAN

and three that think:

    analyse       one search of the position, with a MultiPV shortlist
    compare       named candidate moves, each answered by the opponent and
                  ranked against each other
    playout       the engine on both sides for a few joint actions

The shape a position is written in is the same everywhere: a `dual_fen`, a
list of `moves`, or both (the moves are played on top of the FEN). Moves are
tagged with their board — `"A:e4"`, `"B:Nf6"` — and an untagged move means
board A, because a line of ordinary opening moves is the common case.
"""

from __future__ import annotations

from typing import Any, Callable

from . import analysis, engine as engine_mod, paths
from .board import BOARD_NAMES, DualBoard, IllegalMove, board_index, san


class ToolError(Exception):
    """A bad argument or an impossible request — reported to the model as
    readable text rather than a stack trace, so it can correct itself."""


def _obj(properties: dict, required: list[str] | None = None) -> dict:
    schema: dict[str, Any] = {
        "type": "object",
        "properties": properties,
        "additionalProperties": False,
    }
    if required:
        schema["required"] = required
    return schema


def _s(description: str) -> dict:
    return {"type": "string", "description": description}


def _i(description: str) -> dict:
    return {"type": "integer", "description": description}


def _b(description: str) -> dict:
    return {"type": "boolean", "description": description}


POSITION_ARGS = {
    "dual_fen": _s(
        'Two crazyhouse FENs joined by "|" — board A then board B. Omit for '
        "the starting position on both boards."
    ),
    "moves": {
        "type": ["string", "array"],
        "description": (
            'The line to play first, board-tagged: "e4 Nf6 e5 d5 B:d4 B:d5". '
            "SAN or UCI, drops as P@f7. An untagged move means board A."
        ),
        "items": {"type": "string"},
    },
    "team": _s(
        'Which colour we play on board A — "white" (default) or "black". Our '
        "partner plays the other colour on board B."
    ),
}

BUDGET_ARGS = {
    "movetime_ms": _i(
        f"Milliseconds per search (default {analysis.DEFAULT_MOVETIME_MS}). The "
        "CPU build runs at roughly 350 nodes/s, so a second is about 350 nodes."
    ),
    "nodes": _i("Node budget instead of a time budget — reproducible; overrides movetime_ms."),
}

RULE_ARGS = {
    "time_advantage": _b(
        "True when our team is ahead on the diagonal clock, which is the only "
        "thing that makes sitting on both boards legal. Default false. It also "
        "moves the scale's zero point (see `baseline` in the result), so never "
        "compare a score from one setting against a score from the other."
    ),
    "require_move_on": _s(
        'Forbid passing on a board: "A", "B", or "none" (default). This is how '
        "you ask what to actually play on a board rather than whether to sit."
    ),
}


class Registry:
    def __init__(self) -> None:
        self.tools: dict[str, dict] = {}
        self._handlers: dict[str, Callable[[dict], Any]] = {}
        self._register_all()

    # ── Registration ───────────────────────────────────────────────────────

    def _add(self, name: str, description: str, schema: dict, handler) -> None:
        self.tools[name] = {
            "name": name,
            "description": description,
            "inputSchema": schema,
        }
        self._handlers[name] = handler

    def definitions(self) -> list[dict]:
        return list(self.tools.values())

    def call(self, name: str, args: dict) -> Any:
        handler = self._handlers.get(name)
        if handler is None:
            raise ToolError(f'Unknown tool "{name}".')
        return handler(args or {})

    # ── Tools ──────────────────────────────────────────────────────────────

    def _register_all(self) -> None:
        self._add(
            "status",
            "Which Hivemind build this server will use, where it came from, "
            "and — unless you pass probe=false — whether it actually starts "
            "and which inference backend it loaded. Call this first if a "
            "search fails; it distinguishes 'no engine installed' from 'the "
            "engine is broken'.",
            _obj({"probe": _b("Start the engine to confirm it works (default true).")}),
            self.status,
        )

        self._add(
            "position",
            "Play a line and read the two boards back without starting the "
            "engine: each board's FEN, whose turn it is, what is in the four "
            "reserves, and each board's own movetext. Use it to check a line "
            "parses, to see where a captured piece landed, or to get a "
            "dual_fen to hand to the other tools.",
            _obj(dict(POSITION_ARGS)),
            self.position,
        )

        self._add(
            "legal_moves",
            "Every legal move on one board, in SAN, drops included. Use it to "
            "build the candidate list for `compare` rather than guessing what "
            "is playable — bughouse positions have drops a chess eye misses.",
            _obj(
                {
                    **POSITION_ARGS,
                    "board": _s('Which board — "A" (default) or "B".'),
                    "drops_only": _b("Only reserve drops, which are the moves easiest to miss."),
                }
            ),
            self.legal_moves,
        )

        self._add(
            "analyse",
            "Search the position once and return the engine's best joint "
            "action — one decision per board, where sitting is a real move — "
            "plus its principal variation. With multipv > 1 you also get its "
            "ranked shortlist of root moves from the same search, which is the "
            "cheapest way to see what it considered, ordered best-first by "
            "score rather than by the engine's own visit count. Read "
            "`relative` (0.00 = level) rather than the raw `score`: Hivemind's "
            "scale carries a large offset whose sign depends on "
            "time_advantage. See the note in the result.",
            _obj(
                {
                    **POSITION_ARGS,
                    **RULE_ARGS,
                    **BUDGET_ARGS,
                    "multipv": _i("How many ranked root moves to report (default 1)."),
                }
            ),
            self.analyse,
        )

        self._add(
            "compare",
            "Rank named candidate moves against each other. Each candidate is "
            "played, then the opponent is asked to answer it under the same "
            "budget, and the candidates are ordered by how good the position "
            "then looks *to the opponent* — lower is better for us. The "
            "answering team is worked out from the position, so candidates on "
            "either board and lines of any length are handled alike. This is "
            "the tool for 'what should I play here', because MultiPV only "
            "ranks moves the search chose to visit, and it also hands back the "
            "reply you have to be ready for.",
            _obj(
                {
                    **POSITION_ARGS,
                    **{k: v for k, v in RULE_ARGS.items() if k != "require_move_on"},
                    **BUDGET_ARGS,
                    "candidates": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "Moves to test, SAN or UCI, on `board`.",
                    },
                    "board": _s('Which board the candidates are played on — "A" (default) or "B".'),
                    "force_reply": _b(
                        "Forbid the opponent from sitting instead of answering "
                        "on that board (default true) — otherwise a strong "
                        "candidate is 'answered' by a pass and every row looks alike."
                    ),
                },
                ["candidates"],
            ),
            self.compare,
        )

        self._add(
            "playout",
            "Let the engine play both teams for a few joint actions from the "
            "position. This is the only way to see the piece flow a line "
            "really produces: what one team captures is in the other board's "
            "reserve before the next question is asked.",
            _obj({**POSITION_ARGS, **BUDGET_ARGS, "plies": _i("Joint actions to play (default 6)."), "time_advantage": RULE_ARGS["time_advantage"]}),
            self.playout,
        )

    # ── Handlers ───────────────────────────────────────────────────────────

    @staticmethod
    def _position(args: dict) -> DualBoard:
        try:
            return analysis.position_from(
                args.get("dual_fen"), args.get("moves"), args.get("team", "white")
            )
        except (IllegalMove, ValueError) as e:
            raise ToolError(str(e)) from None

    @staticmethod
    def _engine() -> engine_mod.HivemindEngine:
        try:
            return engine_mod.shared()
        except (paths.EngineNotInstalled, engine_mod.EngineError) as e:
            raise ToolError(str(e)) from None

    @staticmethod
    def _run(fn, **extra) -> Any:
        engine = Registry._engine()
        try:
            return fn(engine=engine, **extra)
        except (IllegalMove, ValueError) as e:
            raise ToolError(str(e)) from None
        except engine_mod.EngineError as e:
            engine_mod.close_shared()  # a wedged process must not poison the next call
            raise ToolError(str(e)) from None

    def status(self, args: dict) -> dict:
        try:
            files = paths.locate()
        except paths.EngineNotInstalled as e:
            raise ToolError(str(e)) from None
        result: dict[str, Any] = {"engine": files.as_dict()}
        if args.get("probe", True):
            engine = self._engine()
            result.update(
                {
                    "running": True,
                    "name": engine.name,
                    "backend": engine.backend,
                    # Workers, intra-op threads and inference batch, as the
                    # engine reported them. Fixed by the build: there is no
                    # `Threads` option to set.
                    "backend_detail": engine.backend_detail,
                }
            )
        return result

    def position(self, args: dict) -> dict:
        return self._position(args).describe()

    def legal_moves(self, args: dict) -> dict:
        dual = self._position(args)
        which = board_index(args.get("board", "A"))
        board = dual.boards[which]
        moves = [
            san(board, m)
            for m in board.legal_moves
            if not args.get("drops_only") or m.drop is not None
        ]
        return {
            "board": BOARD_NAMES[which],
            "fen": board.fen(),
            "turn": "white" if board.turn else "black",
            "count": len(moves),
            "moves": sorted(moves),
        }

    def analyse(self, args: dict) -> dict:
        return self._run(
            analysis.analyse,
            dual_fen=args.get("dual_fen"),
            moves=args.get("moves"),
            team=args.get("team", "white"),
            time_advantage=bool(args.get("time_advantage", False)),
            require_move_on=args.get("require_move_on", "none"),
            multipv=int(args.get("multipv", 1)),
            movetime_ms=args.get("movetime_ms"),
            nodes=args.get("nodes"),
        )

    def compare(self, args: dict) -> dict:
        candidates = args.get("candidates") or []
        if not candidates:
            raise ToolError("compare needs at least one candidate move.")
        return self._run(
            analysis.compare,
            candidates=[str(c) for c in candidates],
            board=args.get("board", "A"),
            dual_fen=args.get("dual_fen"),
            moves=args.get("moves"),
            team=args.get("team", "white"),
            time_advantage=bool(args.get("time_advantage", False)),
            force_reply=bool(args.get("force_reply", True)),
            movetime_ms=args.get("movetime_ms"),
            nodes=args.get("nodes"),
        )

    def playout(self, args: dict) -> dict:
        return self._run(
            analysis.playout,
            plies=int(args.get("plies", 6)),
            dual_fen=args.get("dual_fen"),
            moves=args.get("moves"),
            team=args.get("team", "white"),
            time_advantage=bool(args.get("time_advantage", False)),
            movetime_ms=args.get("movetime_ms"),
            nodes=args.get("nodes"),
        )
