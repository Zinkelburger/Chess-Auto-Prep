#!/usr/bin/env python3
"""Tests for the ChessDB tool and the reply-gap half of pgn_audit.

Requires python-chess (see tools/mcp/requirements.txt). No network: every
test scripts the fetch.

    python tools/mcp/test_chessdb.py
"""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
import urllib.parse
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from chess_prep.chessdb import ChessDbClient, fen4, parse_queryall, within
from chess_prep.tools import Registry, ToolError

# White to move after 1.e4 e5 2.Nf3 Nc6 3.Bc4 Nf6 4.d4 exd4 5.e5 Ng4 6.O-O d6
AFTER_D6 = "r1bqkb1r/ppp2ppp/2np4/4P3/2Bp2n1/5N2/PPP2PPP/RNBQ1RK1 w kq -"
# Black to move after 6.O-O
AFTER_OO = "r1bqkb1r/pppp1ppp/2n5/4P3/2Bp2n1/5N2/PPP2PPP/RNBQ1RK1 b kq -"
# White to move after 6...Be7
AFTER_BE7 = "r1bqk2r/ppppbppp/2n5/4P3/2Bp2n1/5N2/PPP2PPP/RNBQ1RK1 w kq -"


def _body(*moves: tuple[str, str, int]) -> str:
    return json.dumps(
        {
            "status": "ok",
            "moves": [
                {"uci": uci, "san": san, "score": score, "rank": 1, "note": "!"}
                for uci, san, score in moves
            ],
        }
    )


SCRIPT = {
    AFTER_D6: _body(("e5d6", "exd6", 1), ("c1g5", "Bg5", 0), ("f3d4", "Nxd4", -80)),
    AFTER_OO: _body(("f8e7", "Be7", 0), ("d7d6", "d6", -1), ("f8c5", "Bc5", -11)),
    AFTER_BE7: _body(("f1e1", "Re1", 0), ("c1f4", "Bf4", -1), ("d1e2", "Qe2", -4)),
}


class FakeFetch:
    def __init__(self, script: dict[str, str]) -> None:
        self.script = script
        self.urls: list[str] = []

    def __call__(self, url: str) -> str:
        self.urls.append(url)
        board = urllib.parse.parse_qs(urllib.parse.urlparse(url).query)["board"][0]
        return self.script.get(board, '{"status":"unknown"}')


REPERTOIRE_PGN = """
[Event "Two Knights, 4.d4"]
[White "Book"]
[Black "Main line"]
[Result "*"]

1. e4 e5 2. Nf3 Nc6 3. Bc4 Nf6 4. d4 exd4 5. e5 Ng4 6. O-O d6 7. exd6 Qxd6 *
"""


import contextlib

from chess_prep import opening as _opening
from chess_prep.chessdb import fen4 as _fen4


@contextlib.contextmanager
def _fake_engine(script: dict[str, list[tuple[str, int]]]):
    """Replace Stockfish with scripted White-POV MultiPV lines per position."""

    def eval_board(board, depth, multipv):
        lines = script.get(_fen4(board.fen()), [])
        return [
            {"san": san, "score_cp_white": cp, "mate_white": None, "pv": [san]}
            for san, cp in lines
        ]

    real = _opening._eval_board
    _opening._eval_board = eval_board
    try:
        yield
    finally:
        _opening._eval_board = real


@contextlib.contextmanager
def _no_engine():
    def eval_board(board, depth, multipv):
        raise ToolError("Stockfish not found.")

    real = _opening._eval_board
    _opening._eval_board = eval_board
    try:
        yield
    finally:
        _opening._eval_board = real


class Parsing(unittest.TestCase):
    def test_sorts_by_score_and_keeps_notes(self):
        moves = parse_queryall(_body(("a2a3", "a3", -50), ("e2e4", "e4", 30)))
        self.assertEqual([m["san"] for m in moves], ["e4", "a3"])
        self.assertEqual(moves[0]["note"], "!")

    def test_unknown_and_garbage_are_misses(self):
        self.assertEqual(parse_queryall('{"status":"unknown"}'), [])
        self.assertEqual(parse_queryall("<html>"), [])
        self.assertEqual(parse_queryall(""), [])

    def test_within_window(self):
        moves = parse_queryall(SCRIPT[AFTER_D6])
        self.assertEqual([m["san"] for m in within(moves, 30)], ["exd6", "Bg5"])
        self.assertEqual([m["san"] for m in within(moves, 0)], ["exd6"])

    def test_fen4(self):
        self.assertEqual(fen4(AFTER_D6 + " 0 7"), AFTER_D6)


class Client(unittest.TestCase):
    def test_caches_per_position(self):
        fetch = FakeFetch(SCRIPT)
        client = ChessDbClient(fetch=fetch)
        client.query(AFTER_D6 + " 0 7")
        client.query(AFTER_D6 + " 3 9")
        self.assertEqual(len(fetch.urls), 1)
        self.assertEqual(client.requests, 1)

    def test_outage_is_an_error_not_a_miss(self):
        def down(url: str) -> str:
            raise ToolError("ChessDB unreachable: boom")

        with self.assertRaises(ToolError):
            ChessDbClient(fetch=down).query(AFTER_D6)


class QueryTool(unittest.TestCase):
    def setUp(self):
        self.registry = Registry()
        self.fetch = FakeFetch(SCRIPT)
        self.registry._chessdb = ChessDbClient(fetch=self.fetch)

    def test_counts_opponent_good_replies(self):
        out = self.registry.call(
            "chessdb_query",
            {"moves": "1. e4 e5 2. Nf3 Nc6 3. Bc4 Nf6 4. d4 exd4 5. e5 Ng4 6. O-O"},
        )
        self.assertTrue(out["known"])
        self.assertEqual(out["side_to_move"], "black")
        good = {m["san"]: m for m in out["good_moves"]}
        # Be7 (0) and d6 (-1) are level; Bc5 (-11) is inside 30cp too.
        self.assertEqual(set(good), {"Be7", "d6", "Bc5"})
        self.assertEqual(good["d6"]["score_cp"], -1)
        self.assertEqual(good["d6"]["opponent_good_replies"], 2)
        self.assertEqual(good["Be7"]["opponent_good_replies"], 3)
        # The position after Bc5 is not scripted: unknown, not zero.
        self.assertIsNone(good["Bc5"]["opponent_good_replies"])

    def test_unknown_position(self):
        out = self.registry.call("chessdb_query", {"moves": "1. a4 h5"})
        self.assertFalse(out["known"])

    def test_bad_moves(self):
        with self.assertRaises(ToolError):
            self.registry.call("chessdb_query", {"moves": "1. e4 e4"})


class AuditGaps(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.NamedTemporaryFile("w", suffix=".pgn", delete=False, encoding="utf-8")
        tmp.write(REPERTOIRE_PGN)
        tmp.close()
        self.path = Path(tmp.name)
        self.registry = Registry()
        self.fetch = FakeFetch(SCRIPT)
        self.registry._chessdb = ChessDbClient(fetch=self.fetch)
        self.registry.call("pgn_open", {"path": str(self.path)})

    def tearDown(self):
        self.path.unlink(missing_ok=True)

    def _audit(self, **extra):
        args = {
            "path": str(self.path),
            "moves": "1. e4 e5 2. Nf3 Nc6 3. Bc4 Nf6 4. d4 exd4 5. e5 Ng4 6. O-O d6 7. exd6 Qxd6",
            "side": "black",
            "check_mistakes": False,  # no engine work in a unit test
        }
        args.update(extra)
        return self.registry.call("pgn_audit", args)

    def test_flags_the_uncovered_level_reply(self):
        with _no_engine():
            out = self._audit()
        self.assertEqual(out["reply_check"], "ok")
        gaps = out["gaps"]
        self.assertEqual([g["uncovered_reply"] for g in gaps], ["Bg5"])
        self.assertEqual(gaps[0]["behind_best_cp"], 1)
        self.assertEqual(gaps[0]["opponent_good_moves"], 2)
        self.assertEqual(gaps[0]["file_replies"], ["exd6"])
        self.assertEqual(gaps[0]["moves"][-1], "d6")

    def test_window_excludes_the_weak_reply(self):
        with _no_engine():
            out = self._audit(reply_window_cp=0)
        self.assertEqual(out["gaps"], [])

    def test_can_be_switched_off(self):
        out = self._audit(check_replies=False)
        self.assertEqual(out["reply_check"], "skipped")
        self.assertEqual(self.fetch.urls, [])

    def test_outage_is_reported_not_raised(self):
        def down(url: str) -> str:
            raise ToolError("ChessDB unreachable: boom")

        self.registry._chessdb = ChessDbClient(fetch=down)
        with _no_engine():
            out = self._audit()
        self.assertTrue(out["reply_check"].startswith("chessdb unavailable"))
        self.assertEqual(out["gaps"], [])

    def test_stockfish_stands_in_where_chessdb_knows_nothing(self):
        # Nothing scripted: every position is unknown to ChessDB.
        self.registry._chessdb = ChessDbClient(fetch=FakeFetch({}))
        with _fake_engine(
            {
                AFTER_D6: [("exd6", 45), ("Bg5", 4), ("Bb5", -55)],
            }
        ):
            out = self._audit()
        gaps = [g for g in out["gaps"] if g["uncovered_reply"] == "Bg5"]
        self.assertEqual(len(gaps), 1)
        self.assertEqual(gaps[0]["source"], "stockfish")
        self.assertEqual(gaps[0]["behind_best_cp"], 41)
        self.assertEqual(gaps[0]["opponent_good_moves"], 2)
        self.assertNotIn("Bb5", [g["uncovered_reply"] for g in out["gaps"]])


if __name__ == "__main__":
    unittest.main()
