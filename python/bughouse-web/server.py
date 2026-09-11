"""Public, bounded HTTP adapter for the existing two-board engine.

Run one ASGI worker. Each analysis has a separate process group, a hard
deadline and no waiting queue; legality requests remain available during it.
"""

import asyncio
from collections import OrderedDict, deque
from contextlib import asynccontextmanager
import json
import logging
import os
from pathlib import Path
import signal
import sys
import time
from typing import Literal

import chess
from fastapi import FastAPI, HTTPException, Request
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, ConfigDict, Field, field_validator

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools/mcp"))
from bughouse.analysis import position_from
from bughouse.board import IllegalMove, san
from bughouse.paths import locate

LOG = logging.getLogger("bughouse.web")
MAX_BODY = 16_384
SEARCH_TIMEOUT = 35


class PositionRequest(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)
    dual_fen: str | None = Field(default=None, max_length=1024)
    moves: list[str] = Field(default_factory=list, max_length=256)
    team: Literal["white", "black"] = "white"

    @field_validator("dual_fen")
    @classmethod
    def safe_fen(cls, value):
        if value and (not value.isascii() or any(ord(c) < 32 for c in value)):
            raise ValueError("FEN must be one line of ASCII text.")
        return value

    @field_validator("moves")
    @classmethod
    def safe_moves(cls, moves):
        if any(not 1 <= len(m) <= 20 or not m.isascii()
               or any(c.isspace() or ord(c) < 32 for c in m) for m in moves):
            raise ValueError("Use up to 256 board-tagged SAN or UCI moves.")
        return moves


class AnalysisRequest(PositionRequest):
    time_advantage: bool = False
    require_move_on: Literal["none", "A", "B"] = "none"
    movetime_ms: int = Field(default=1500, ge=250, le=3000)
    multipv: int = Field(default=3, ge=1, le=3)


def position(data: PositionRequest):
    try:
        dual = position_from(data.dual_fen, data.moves, data.team)
        for board in dual.boards:
            # Crazyhouse's per-board material limits do not apply to bughouse:
            # pieces arrive from another board. Check the structural rules only.
            bad = (chess.STATUS_NO_WHITE_KING | chess.STATUS_NO_BLACK_KING
                   | chess.STATUS_TOO_MANY_KINGS | chess.STATUS_PAWNS_ON_BACKRANK
                   | chess.STATUS_OPPOSITE_CHECK | chess.STATUS_BAD_CASTLING_RIGHTS
                   | chess.STATUS_INVALID_EP_SQUARE)
            if board.status() & bad:
                raise ValueError("Each board needs a legal king, pawn, castling and turn setup.")
            if any(pocket.count(chess.KING) for pocket in board.pockets):
                raise ValueError("Kings cannot be held in reserve.")
            if board.promoted & (board.kings | board.pawns):
                raise ValueError("Only knights, bishops, rooks and queens can be marked promoted.")
            if sum(len(p) for p in board.pockets) > 60:
                raise ValueError("Too many pieces in reserve.")
        if sum(len(b.piece_map()) + sum(len(p) for p in b.pockets)
               for b in dual.boards) > 64:
            raise ValueError("A two-board position cannot contain more than 64 pieces.")
        return dual
    except (ValueError, IllegalMove) as exc:
        raise HTTPException(422, str(exc)) from None


def describe(dual):
    result = dual.describe()
    result["history"] = [ply.as_dict() for ply in dual.history]
    for name, info in result["boards"].items():
        board = dual.board(name)
        info["pieces"] = {chess.square_name(sq): p.symbol()
                          for sq, p in board.piece_map().items()}
        info["legal_moves"] = [{"uci": m.uci(), "san": san(board, m)}
                               for m in board.legal_moves]
        # No live clocks: a player without a move may still receive a rescue
        # drop from their partner. Do not declare a match over here.
        info.pop("over", None)
    return result


class RateLimit:
    """Bounded per-client sliding windows; never trust arbitrary forwarded IPs."""

    def __init__(self, requests, seconds=60, capacity=4096):
        self.requests, self.seconds, self.capacity = requests, seconds, capacity
        self.clients = OrderedDict()

    def accept(self, key):
        now = time.monotonic()
        while self.clients:
            first = next(iter(self.clients))
            if self.clients[first][-1] > now - self.seconds:
                break
            del self.clients[first]
        hits = self.clients.get(key)
        if hits is None:
            if len(self.clients) >= self.capacity:
                return False
            hits = self.clients[key] = deque()
        while hits and hits[0] <= now - self.seconds:
            hits.popleft()
        if len(hits) >= self.requests:
            return False
        hits.append(now)
        self.clients.move_to_end(key)
        return True


class SearchRunner:
    def __init__(self):
        self.busy = False
        self.process = None

    @staticmethod
    async def reap(proc):
        # The engine inherits this fresh group. Kill descendants even if the
        # Python worker exited unexpectedly, then reap our direct child.
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        await proc.wait()

    async def close(self):
        if self.process is not None:
            await self.reap(self.process)

    async def run(self, payload):
        if self.busy:
            raise HTTPException(429, "The engine is helping someone else. Try again shortly.",
                                headers={"Retry-After": "5"})
        self.busy = True
        proc = None
        try:
            proc = await asyncio.create_subprocess_exec(
                sys.executable, str(Path(__file__).with_name("worker.py")),
                stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE, start_new_session=True,
            )
            self.process = proc
            try:
                out, err = await asyncio.wait_for(
                    proc.communicate(json.dumps(payload).encode()), SEARCH_TIMEOUT)
            except TimeoutError:
                raise HTTPException(504, "The search timed out. Try a shorter search.") from None
            if proc.returncode:
                LOG.error("Search failed: %s", err.decode(errors="replace")[-4000:])
                raise HTTPException(503, "The engine is unavailable. Please try again later.")
            return json.loads(out)
        except (OSError, json.JSONDecodeError):
            LOG.exception("Could not run Hivemind")
            raise HTTPException(503, "The engine is unavailable. Please try again later.") from None
        finally:
            if proc is not None:
                await self.reap(proc)
            self.process = None
            self.busy = False


class BodyLimit:
    """Reject large streamed/chunked bodies before JSON parsing allocates them."""

    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http" or scope["method"] != "POST":
            return await self.app(scope, receive, send)
        body = bytearray()
        deadline = time.monotonic() + 10
        while True:
            try:
                message = await asyncio.wait_for(receive(), max(0, deadline - time.monotonic()))
            except TimeoutError:
                return await JSONResponse({"detail": "Request body timed out."}, 408)(scope, receive, send)
            if message["type"] == "http.disconnect":
                return
            body.extend(message.get("body", b""))
            if len(body) > MAX_BODY:
                return await JSONResponse({"detail": "Request is too large."}, 413)(scope, receive, send)
            if not message.get("more_body", False):
                break
        delivered = False

        async def replay():
            nonlocal delivered
            if delivered:
                return await receive()
            delivered = True
            return {"type": "http.request", "body": bytes(body), "more_body": False}

        await self.app(scope, replay, send)


def create_app(runner=None):
    runner = runner or SearchRunner()

    @asynccontextmanager
    async def lifespan(app):
        yield
        await runner.close()

    app = FastAPI(title="Bughouse Lab", lifespan=lifespan, docs_url=None, redoc_url=None)
    origins = [s.strip() for s in os.environ.get(
        "BUGHOUSE_ORIGINS", "https://chessautoprep.com,https://andrewbernal.com"
    ).split(",") if s.strip()]
    app.add_middleware(BodyLimit)
    app.add_middleware(CORSMiddleware, allow_origins=origins,
                       allow_methods=["GET", "POST"], allow_headers=["Content-Type"],
                       expose_headers=["Retry-After"])
    searches, positions = RateLimit(6), RateLimit(180)

    @app.exception_handler(RequestValidationError)
    async def invalid_request(request, exc):
        # Do not echo user-supplied payloads or internal Pydantic context.
        return JSONResponse({"detail": "Invalid position or search settings."}, 422)

    def limit(request, limiter):
        ip = request.client.host if request.client else "unknown"
        if not limiter.accept(ip):
            raise HTTPException(429, "Too many requests. Try again in a minute.",
                                headers={"Retry-After": "60"})

    @app.get("/api/bughouse/health")
    async def health():
        # Liveness/configuration only: monitoring must not trigger engine work.
        try:
            files = locate(required=False)
            available = bool(files and files.binary.is_file() and files.model.is_file())
        except OSError:
            available = False
        return {"status": "ok", "engine_installed": available,
                "busy": runner.busy, "max_movetime_ms": 3000}

    @app.post("/api/bughouse/position")
    async def read_position(data: PositionRequest, request: Request):
        limit(request, positions)
        return describe(position(data))

    @app.post("/api/bughouse/analyse")
    async def analyse_position(data: AnalysisRequest, request: Request):
        limit(request, searches)
        dual = position(data)
        if not any(dual.our_turn_on(n) and any(dual.board(n).legal_moves) for n in ("A", "B")):
            raise HTTPException(422, "This team has no move available. Choose the other team or update the position.")
        if data.require_move_on != "none" and (
            not dual.our_turn_on(data.require_move_on)
            or not any(dual.board(data.require_move_on).legal_moves)
        ):
            raise HTTPException(422, "The selected team cannot move on the required board.")
        payload = data.model_dump(exclude={"moves", "dual_fen"})
        # Only normalized, validated FEN goes across the UCI process boundary.
        payload.update(dual_fen=dual.dual_fen, calibrate=True)
        return await runner.run(payload)

    static = os.environ.get("BUGHOUSE_STATIC_DIR")
    if static:
        app.mount("/", StaticFiles(directory=static, html=True), name="website")
    else:
        @app.get("/")
        async def home():
            return RedirectResponse("/api/bughouse/health")
    return app


app = create_app()
