#!/usr/bin/env python3
"""Collect over-the-board games from chess.com Events into a broadcast collection.

chess.com broadcasts tournaments through its Events system (the former
Chessbomb).  The event record is public JSON, but the moves are only served
over the events websocket, so this tool speaks just enough Socket.IO to ask
for each game.  Games land in the same collection layout as
`tools/lichess_broadcasts.py` (per-broadcast PGN, manifest, merged PGN), and
a game broadcast on both sites is kept once.

    python3 tools/chesscom_events.py search massachusetts
    python3 tools/chesscom_events.py event 2025-massachusetts-open --collection massachusetts
    python3 tools/chesscom_events.py status --collection massachusetts

The event slug is the last part of `chess.com/events/<slug>`.  Search covers
community events too, so a state or club event is found by name.

Zero dependencies: `urllib`, `socket`, `ssl` and the standard library.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import socket
import ssl
import struct
import sys
import time
import urllib.request
import uuid
from pathlib import Path
from typing import Any, Callable

sys.path.insert(0, str(Path(__file__).resolve().parent))

from lichess_broadcasts import Collection, Game, collection_dir  # noqa: E402

EVENTS_API = "https://www.chess.com/events/v1/api/"
EVENTS_HOST = "nxt.chessbomb.com"
EVENTS_WS_PATH = "/pubsub/public/?EIO=4&transport=websocket&userId={user}"
NAMESPACE = "/public"
USER_AGENT = "Mozilla/5.0 (chess-auto-prep chesscom_events.py)"
ORIGIN = "https://www.chess.com"
REQUEST_GAP_SECONDS = 0.5
REPLY_TIMEOUT_SECONDS = 20.0


# ── HTTP ───────────────────────────────────────────────────────────────────


def http_json(path: str, body: dict[str, Any] | None = None) -> Any:
    data = json.dumps(body).encode() if body is not None else None
    headers = {"User-Agent": USER_AGENT}
    if data is not None:
        headers["Content-Type"] = "application/json"
    request = urllib.request.Request(EVENTS_API + path, data=data, headers=headers)
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.loads(response.read().decode("utf-8"))


def search_events(query: str) -> list[dict[str, Any]]:
    """Events whose name matches [query], past and current, community included."""
    body = {"searchFor": query, "timeFilter": "currentAndPast", "includeSelfServe": True}
    return [r["event"] for r in http_json("searchv2", body).get("results", [])]


def fetch_room(slug: str) -> dict[str, Any]:
    """The event record: room, rounds, groups and games (no moves)."""
    return http_json(f"room/{slug}", {})


# ── WebSocket (RFC 6455 client, text frames only) ──────────────────────────


def mask_frame(payload: bytes, mask: bytes, opcode: int = 1) -> bytes:
    """One masked client frame with FIN set."""
    header = bytes([0x80 | opcode])
    n = len(payload)
    if n < 126:
        header += bytes([0x80 | n])
    elif n < 65536:
        header += bytes([0x80 | 126]) + struct.pack(">H", n)
    else:
        header += bytes([0x80 | 127]) + struct.pack(">Q", n)
    return header + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(payload))


class WebSocket:
    def __init__(self, host: str, path: str, origin: str) -> None:
        context = ssl.create_default_context()
        raw = socket.create_connection((host, 443), timeout=30)
        self._sock = context.wrap_socket(raw, server_hostname=host)
        key = base64.b64encode(os.urandom(16)).decode()
        request = (
            f"GET {path} HTTP/1.1\r\nHost: {host}\r\nUpgrade: websocket\r\n"
            f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\n"
            f"Sec-WebSocket-Version: 13\r\nOrigin: {origin}\r\n"
            f"User-Agent: {USER_AGENT}\r\n\r\n"
        )
        self._sock.sendall(request.encode())
        response = b""
        while b"\r\n\r\n" not in response:
            chunk = self._sock.recv(4096)
            if not chunk:
                raise ConnectionError("websocket handshake: connection closed")
            response += chunk
        head, _, rest = response.partition(b"\r\n\r\n")
        status = head.split(b"\r\n", 1)[0]
        if b" 101 " not in status:
            raise ConnectionError(f"websocket handshake: {status.decode(errors='ignore')}")
        self._buf = rest

    def _read(self, n: int) -> bytes:
        while len(self._buf) < n:
            chunk = self._sock.recv(65536)
            if not chunk:
                raise ConnectionError("websocket closed")
            self._buf += chunk
        out, self._buf = self._buf[:n], self._buf[n:]
        return out

    def recv(self) -> tuple[int, bytes]:
        """(opcode, payload) of the next frame; fragments are not expected."""
        b1, b2 = self._read(2)
        opcode = b1 & 0x0F
        length = b2 & 0x7F
        if length == 126:
            length = struct.unpack(">H", self._read(2))[0]
        elif length == 127:
            length = struct.unpack(">Q", self._read(8))[0]
        mask = self._read(4) if b2 & 0x80 else None
        data = self._read(length)
        if mask:
            data = bytes(b ^ mask[i % 4] for i, b in enumerate(data))
        return opcode, data

    def send_text(self, text: str) -> None:
        self._sock.sendall(mask_frame(text.encode(), os.urandom(4)))

    def close(self) -> None:
        try:
            self._sock.sendall(mask_frame(b"", os.urandom(4), opcode=8))
        except OSError:
            pass
        self._sock.close()


# ── Socket.IO session on the events pubsub ─────────────────────────────────


class EventsSocket:
    """A connected Socket.IO namespace that answers get-game requests.

    Engine.IO v4 over one websocket: the server opens with `0{...}`, the
    client joins the namespace with `40/public,`, events travel as
    `42/public,["message", ...]`, and `2`/`3` are ping/pong.
    """

    def __init__(self, connect: Callable[[], WebSocket] | None = None) -> None:
        self._connect = connect or self._default_connect
        self._ws: WebSocket | None = None

    @staticmethod
    def _default_connect() -> WebSocket:
        user = f"guest-{uuid.uuid4().hex[:12]}"
        return WebSocket(EVENTS_HOST, EVENTS_WS_PATH.format(user=user), ORIGIN)

    def _open(self) -> WebSocket:
        if self._ws is not None:
            return self._ws
        ws = self._connect()
        opcode, data = ws.recv()
        if not data.startswith(b"0"):
            raise ConnectionError(f"unexpected engine.io open: {data[:80]!r}")
        ws.send_text(f"40{NAMESPACE},")
        opcode, data = ws.recv()
        if not data.startswith(f"40{NAMESPACE},".encode()):
            raise ConnectionError(f"namespace join refused: {data[:80]!r}")
        self._ws = ws
        return ws

    def close(self) -> None:
        if self._ws is not None:
            self._ws.close()
            self._ws = None

    def request(self, message: dict[str, Any]) -> dict[str, Any]:
        """Send one pubsub message and return the reply with the same type."""
        ws = self._open()
        ws.send_text(f"42{NAMESPACE}," + json.dumps(["message", ["message", message]]))
        deadline = time.monotonic() + REPLY_TIMEOUT_SECONDS
        while time.monotonic() < deadline:
            opcode, data = ws.recv()
            if opcode == 8:
                self._ws = None
                raise ConnectionError("events socket closed by server")
            text = data.decode("utf-8", errors="replace")
            if text == "2":
                ws.send_text("3")
                continue
            prefix = f"42{NAMESPACE},"
            if not text.startswith(prefix):
                continue
            packet = json.loads(text[len(prefix):])
            reply = packet[1] if len(packet) > 1 and isinstance(packet[1], dict) else {}
            inner = reply.get("message") if isinstance(reply.get("message"), dict) else reply
            if inner.get("type") == message["type"]:
                return inner
        raise TimeoutError(f"no reply to {message['type']}")

    def game(self, room_slug: str, round_slug: str, game_slug: str) -> dict[str, Any]:
        """Full game state: `data.game` plus `data.moves` (cbn = "uci_san")."""
        reply = self.request(
            {
                "type": "get-game",
                "roomSlug": room_slug,
                "roundSlug": round_slug,
                "gameSlug": game_slug,
                "markerMoves": 0,
                "markerAnalysis": 999999999,
                "fullState": True,
            }
        )
        return reply.get("data", {})


# ── PGN ────────────────────────────────────────────────────────────────────


def player_name(p: dict[str, Any]) -> str:
    """`Last, First` as TWIC writes it, whatever shape chess.com sent."""
    first = (p.get("firstName") or "").strip()
    last = (p.get("lastName") or "").strip()
    if first and last:
        return f"{last}, {first}"
    return (p.get("name") or p.get("preferredName") or last or first or "?").strip()


def clock_tag(ms: Any) -> str:
    try:
        seconds = int(ms) // 1000
    except (TypeError, ValueError):
        return ""
    if seconds < 0:
        seconds = 0
    h, rem = divmod(seconds, 3600)
    m, s = divmod(rem, 60)
    return f"{h}:{m:02d}:{s:02d}"


def movetext_from_cbn(moves: list[dict[str, Any]], result: str) -> str:
    """`1. e4 { [%clk 1:59:58] } 1... e5 ...` from chess.com's move list."""
    parts: list[str] = []
    for mv in sorted(moves, key=lambda m: m.get("ply", 0)):
        cbn = mv.get("cbn", "")
        san = cbn.split("_", 1)[1] if "_" in cbn else cbn
        if not san:
            continue
        ply = int(mv.get("ply", 0))
        number = ply // 2 + 1
        prefix = f"{number}." if ply % 2 == 0 else f"{number}..."
        clk = clock_tag(mv.get("clock"))
        token = f"{prefix} {san}"
        if clk:
            token += f" {{ [%clk {clk}] }}"
        parts.append(token)
    parts.append(result or "*")
    return " ".join(parts)


def event_date(game: dict[str, Any], rnd: dict[str, Any]) -> str:
    for key in ("startAt", "createAt"):
        value = game.get(key) or rnd.get(key) or ""
        if len(value) >= 10:
            return value[:10].replace("-", ".")
    return "????.??.??"


def build_game(
    room: dict[str, Any],
    rnd: dict[str, Any],
    game: dict[str, Any],
    moves: list[dict[str, Any]],
    site: str | None,
) -> Game:
    slug = room["slug"]
    result = game.get("result") or "*"
    round_slug = str(rnd.get("slug", "")).lstrip("0") or str(rnd.get("slug", ""))
    board = game.get("board")
    tags: dict[str, str] = {
        "Event": room.get("name", slug),
        "Site": (game.get("site") or site or "?").strip(),
        "Date": event_date(game, rnd),
        "Round": f"{round_slug}.{board}" if board else round_slug,
        "White": player_name(game.get("white") or {}),
        "Black": player_name(game.get("black") or {}),
        "Result": result,
    }
    for colour in ("white", "black"):
        p = game.get(colour) or {}
        elo = p.get("eloClassical") or p.get("elo") or game.get(f"{colour}Elo")
        if elo:
            tags[f"{colour.capitalize()}Elo"] = str(elo)
        if p.get("title"):
            tags[f"{colour.capitalize()}Title"] = p["title"]
        if p.get("fideId"):
            tags[f"{colour.capitalize()}FideId"] = str(p["fideId"])
    if room.get("timeControl"):
        tags["TimeControl"] = str(room["timeControl"])
    tags["BroadcastName"] = room.get("name", slug)
    tags["GameURL"] = f"{ORIGIN}/events/{slug}/{rnd.get('slug', '')}/{game.get('slug', '')}"
    return Game(tags, movetext_from_cbn(moves, result))


def event_summary(room: dict[str, Any], rounds: list[dict[str, Any]], games: list[dict[str, Any]]) -> dict[str, Any]:
    """Manifest entry in the shape lichess_broadcasts uses."""
    dates = []
    for key in ("startAt", "endAt"):
        value = room.get(key)
        if value:
            dates.append(int(time.mktime(time.strptime(value[:19], "%Y-%m-%dT%H:%M:%S"))) * 1000)
    sites = sorted({g.get("site", "") for g in games if g.get("site")})
    return {
        "id": room["slug"],
        "name": room.get("name", room["slug"]),
        "slug": room["slug"],
        "url": f"{ORIGIN}/events/{room['slug']}",
        "location": sites[0] if len(sites) == 1 else "",
        "dates": dates,
        "owner": "chess.com",
        "rounds": len(rounds),
        "finished": all(g.get("result") not in (None, "", "*") for g in games) if games else False,
        "source": "chesscom",
    }


def collect_event(
    collection: Collection,
    slug: str,
    sock: EventsSocket,
    refresh: bool = False,
    room_data: dict[str, Any] | None = None,
) -> dict[str, Any]:
    key = f"chesscom-{slug}"
    if collection.is_complete(key, refresh):
        entry = collection.manifest["tours"][key]
        print(f"{key}: {entry['name']} — already complete, skipped", file=sys.stderr)
        return entry
    data = room_data or fetch_room(slug)
    room = data["room"]
    rounds = {r["id"]: r for r in data.get("rounds", [])}
    games: list[Game] = []
    for g in data.get("games", []):
        rnd = rounds.get(g.get("roundId"), {})
        if g.get("sourceType") == "meta" or not rnd:
            continue
        state = sock.game(slug, str(rnd.get("slug", "")), g.get("slug", ""))
        moves = state.get("moves") or []
        merged = dict(g)
        merged.update(state.get("game") or {})
        games.append(build_game(room, rnd, merged, moves, collection.site))
        time.sleep(REQUEST_GAP_SECONDS)
    entry = event_summary(room, list(rounds.values()), data.get("games", []))
    return collection.store(key, entry, games)


# ── CLI ────────────────────────────────────────────────────────────────────


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    def add_collection_args(p: argparse.ArgumentParser) -> None:
        p.add_argument("--collection", default="broadcasts", help="collection name (default: broadcasts)")
        p.add_argument("--out", help="collection directory (default: Documents/lichess_broadcasts/<collection>)")
        p.add_argument("--site", help="Site tag for games whose event gives no venue")
        p.add_argument("--refresh", action="store_true", help="re-fetch events already complete")

    p_search = sub.add_parser("search", help="find events by name (community events included)")
    p_search.add_argument("query")

    p_event = sub.add_parser("event", help="fetch events by slug")
    p_event.add_argument("slug", nargs="+")
    add_collection_args(p_event)

    p_status = sub.add_parser("status", help="list a collection and rebuild its merged PGN")
    add_collection_args(p_status)

    args = parser.parse_args(argv)

    if args.command == "search":
        for e in search_events(args.query):
            start = (e.get("startAt") or "")[:10]
            print(f"{e.get('slug'):<50} {start}  {e.get('name')}")
        return 0

    collection = Collection(collection_dir(args.collection, args.out), args.site)
    if args.command == "event":
        sock = EventsSocket()
        try:
            for slug in args.slug:
                try:
                    collect_event(collection, slug, sock, refresh=args.refresh)
                except (OSError, TimeoutError, KeyError, ValueError) as e:
                    print(f"{slug}: {e}", file=sys.stderr)
                collection.save()
        finally:
            sock.close()
    collection.merge()
    collection.save()
    for line in collection.status_lines():
        print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main())
