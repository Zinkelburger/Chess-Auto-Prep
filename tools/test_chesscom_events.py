#!/usr/bin/env python3
"""Offline tests for tools/chesscom_events.py (unittest, no network).

Run:
    python3 tools/test_chesscom_events.py
"""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import chesscom_events as ce  # noqa: E402
import lichess_broadcasts as lb  # noqa: E402

ROOM = {
    "id": 14468,
    "slug": "2025-massachusetts-open",
    "name": "Massachusetts Open 2025",
    "startAt": "2025-05-24T12:00:00.000Z",
    "endAt": "2025-05-26T21:55:00.000Z",
    "timeControl": "7200+30",
}
ROUND = {"id": 138894, "slug": "01", "startAt": "2025-05-24T14:14:39.741Z"}
GAME = {
    "id": 3370887,
    "roundId": 138894,
    "slug": "Wong_Wyatt-Alexander_Ivanov",
    "result": "0-1",
    "board": 1,
    "sourceType": "full",
    "site": "Westford, MA, US",
    "startAt": "2025-05-24T14:48:17.587Z",
    "whiteElo": 1834,
    "white": {"name": "Wong, Wyatt", "firstName": "Wyatt", "lastName": "Wong", "fideId": 30979935, "elo": 1834, "eloClassical": 1837, "title": ""},
    "black": {"name": "Alexander Ivanov", "firstName": "Alexander", "lastName": "Ivanov", "title": "GM"},
}
MOVES = [
    {"ply": 1, "cbn": "d7d6_d6", "clock": 7181000},
    {"ply": 0, "cbn": "e2e4_e4", "clock": 7198000},
    {"ply": 2, "cbn": "d2d4_d4", "clock": 7190500},
]


class BuildGameTest(unittest.TestCase):
    def test_tags_and_movetext(self):
        g = ce.build_game(ROOM, ROUND, GAME, MOVES, None)
        self.assertEqual(g.tags["Event"], "Massachusetts Open 2025")
        self.assertEqual(g.tags["Site"], "Westford, MA, US")
        self.assertEqual(g.tags["Date"], "2025.05.24")
        self.assertEqual(g.tags["Round"], "1.1")
        self.assertEqual(g.tags["White"], "Wong, Wyatt")
        self.assertEqual(g.tags["Black"], "Ivanov, Alexander")
        self.assertEqual(g.tags["WhiteElo"], "1837")
        self.assertEqual(g.tags["WhiteFideId"], "30979935")
        self.assertEqual(g.tags["BlackTitle"], "GM")
        self.assertNotIn("BlackElo", g.tags)
        self.assertEqual(g.tags["TimeControl"], "7200+30")
        self.assertEqual(
            g.tags["GameURL"],
            "https://www.chess.com/events/2025-massachusetts-open/01/Wong_Wyatt-Alexander_Ivanov",
        )
        self.assertEqual(
            g.movetext,
            "1. e4 { [%clk 1:59:58] } 1... d6 { [%clk 1:59:41] } 2. d4 { [%clk 1:59:50] } 0-1",
        )
        self.assertTrue(g.has_moves)

    def test_site_fallback_and_unfinished_result(self):
        game = dict(GAME, site="", result="")
        g = ce.build_game(ROOM, ROUND, game, MOVES, "Massachusetts, USA")
        self.assertEqual(g.tags["Site"], "Massachusetts, USA")
        self.assertEqual(g.tags["Result"], "*")
        self.assertTrue(g.movetext.endswith(" *"))

    def test_player_name_shapes(self):
        self.assertEqual(ce.player_name({"firstName": "A", "lastName": "B"}), "B, A")
        self.assertEqual(ce.player_name({"name": "Alexander Ivanov"}), "Alexander Ivanov")
        self.assertEqual(ce.player_name({}), "?")

    def test_clock_tag(self):
        self.assertEqual(ce.clock_tag(7198000), "1:59:58")
        self.assertEqual(ce.clock_tag(59000), "0:00:59")
        self.assertEqual(ce.clock_tag(None), "")


class DedupeAcrossSourcesTest(unittest.TestCase):
    def test_lichess_and_chesscom_copies_are_one_game(self):
        ours = ce.build_game(ROOM, ROUND, GAME, MOVES, None)
        theirs = lb.parse_pgn(
            '[Event "Mass Open 2025"]\n[Site "Westford, MA"]\n[Date "2025.05.24"]\n'
            '[Round "1.1"]\n[White "Wong, Wyatt"]\n[Black "Ivanov, Alexander"]\n'
            '[Result "0-1"]\n[GameURL "https://lichess.org/broadcast/x/y/z"]\n\n'
            "1. e4 d6 2. d4 0-1\n"
        )[0]
        self.assertEqual(lb.game_key(ours), lb.game_key(theirs))
        merged = lb.merge_games([({}, [theirs]), ({}, [ours])])
        self.assertEqual(len(merged), 1)
        self.assertIn("%clk", merged[0].movetext)


class FrameTest(unittest.TestCase):
    def test_mask_frame_roundtrip(self):
        payload = b"42/public," + b"x" * 300
        frame = ce.mask_frame(payload, b"\x01\x02\x03\x04")
        self.assertEqual(frame[0], 0x81)
        self.assertEqual(frame[1], 0x80 | 126)
        self.assertEqual(int.from_bytes(frame[2:4], "big"), len(payload))
        masked = frame[8:]
        unmasked = bytes(b ^ b"\x01\x02\x03\x04"[i % 4] for i, b in enumerate(masked))
        self.assertEqual(unmasked, payload)


class FakeWebSocket:
    """Scripted server side of the pubsub handshake and one get-game reply."""

    def __init__(self):
        self.sent: list[str] = []
        self.queue = [b'0{"sid":"abc","pingInterval":25000}']

    def recv(self):
        if self.queue:
            return 1, self.queue.pop(0)
        raise AssertionError("no more frames")

    def send_text(self, text):
        self.sent.append(text)
        if text == "40/public,":
            self.queue.append(b'40/public,{"sid":"def"}')
        elif text.startswith("42/public,"):
            packet = json.loads(text[len("42/public,"):])
            request = packet[1][1]
            reply = {
                "type": "message",
                "channel": "global",
                "message": {
                    "type": request["type"],
                    "params": request,
                    "data": {"game": dict(GAME), "moves": MOVES},
                },
            }
            self.queue.append(b"2")
            self.queue.append(("42/public," + json.dumps(["message", reply])).encode())

    def close(self):
        pass


class EventsSocketTest(unittest.TestCase):
    def test_get_game_over_scripted_socket(self):
        fake = FakeWebSocket()
        sock = ce.EventsSocket(connect=lambda: fake)
        data = sock.game("2025-massachusetts-open", "01", "Wong_Wyatt-Alexander_Ivanov")
        self.assertEqual(len(data["moves"]), 3)
        self.assertIn("3", fake.sent)  # pong answered the ping
        self.assertEqual(fake.sent[0], "40/public,")

    def test_collect_event_writes_collection(self):
        ce.REQUEST_GAP_SECONDS = 0.0
        fake = FakeWebSocket()
        sock = ce.EventsSocket(connect=lambda: fake)
        room_data = {"room": ROOM, "rounds": [ROUND], "games": [GAME]}
        with tempfile.TemporaryDirectory() as tmp:
            col = lb.Collection(Path(tmp) / "massachusetts")
            entry = ce.collect_event(col, "2025-massachusetts-open", sock, room_data=room_data)
            self.assertEqual(entry["games"], 1)
            self.assertEqual(entry["source"], "chesscom")
            self.assertTrue(entry["finished"])
            self.assertEqual(col.merge(), 1)
            col.save()
            manifest = json.loads((Path(tmp) / "massachusetts" / "manifest.json").read_text())
            self.assertIn("chesscom-2025-massachusetts-open", manifest["tours"])
            self.assertTrue(col.is_complete("chesscom-2025-massachusetts-open"))


if __name__ == "__main__":
    unittest.main()
