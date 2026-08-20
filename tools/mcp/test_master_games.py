#!/usr/bin/env python3
"""Tests for the master-games MCP tools (read-only over the app's SQLite).

    python tools/mcp/test_master_games.py

Builds a tiny database with the app's schema, so no download is needed.
python-chess is required for `master_book` (as in the other opening tools).
"""

from __future__ import annotations

import os
import sqlite3
import zlib
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from chess_prep.master_games import MasterGamesDb, fen4_of, position_key
from chess_prep.tools import Registry, ToolError

START = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
AFTER_E4 = "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1"

SCHEMA = """
CREATE TABLE games(id INTEGER PRIMARY KEY, twic INTEGER, event TEXT, site TEXT,
  date TEXT, round TEXT, white TEXT, black TEXT, result TEXT, white_elo INTEGER,
  black_elo INTEGER, white_fide INTEGER, black_fide INTEGER, eco TEXT,
  ply_count INTEGER, movetext BLOB);
CREATE TABLE book(pos INTEGER, move TEXT, ply INTEGER, games INTEGER,
  white_wins INTEGER, draws INTEGER, black_wins INTEGER, elo_sum INTEGER,
  elo_n INTEGER, max_elo INTEGER, last_year INTEGER, top_game INTEGER,
  recent_game INTEGER, PRIMARY KEY(pos, move)) WITHOUT ROWID;
CREATE TABLE meta(key TEXT PRIMARY KEY, value BLOB NOT NULL);
CREATE TABLE twic_issues(issue INTEGER PRIMARY KEY, games INTEGER,
  imported_at INTEGER);
"""


ZDICT = b"1. e4 e5 2. Nf3 Nc6 3. Bb5 a6 4. Ba4 Nf6 5. O-O 1. d4 Nf6 2. c4 e6 "


def _z(movetext: str) -> bytes:
    # The app compresses with a preset dictionary stored in `meta`.
    c = zlib.compressobj(9, zdict=ZDICT)
    return c.compress(movetext.encode()) + c.flush()


def make_db(path: Path) -> None:
    c = sqlite3.connect(path)
    c.executescript(SCHEMA)
    c.execute("INSERT INTO meta VALUES('movetext_dict', ?)", (ZDICT,))
    c.execute(
        "INSERT INTO games VALUES(1,1650,'Tata Steel','Wijk aan Zee','2025.01.20',"
        "'3','Giri,A','Caruana,F','1/2-1/2',2740,2800,NULL,NULL,'C65',6,?)",
        (_z("1. e4 e5 2. Nf3 Nc6 3. Bb5"),),
    )
    c.execute(
        "INSERT INTO games VALUES(2,1650,'Open','Berlin','2025.02.01','1',"
        "'Keymer,V','Giri,A','1-0',2720,2740,NULL,NULL,'A45',4,?)",
        (_z("1. d4 Nf6 2. Bf4"),),
    )
    c.execute(
        "INSERT INTO book VALUES(?,?,0,30,12,15,3,160000,60,2800,2025,1,1)",
        (position_key(fen4_of(START)), "e2e4"),
    )
    c.execute(
        "INSERT INTO book VALUES(?,?,0,10,5,4,1,50000,20,2740,2025,2,2)",
        (position_key(fen4_of(START)), "d2d4"),
    )
    c.execute("INSERT INTO twic_issues VALUES(1650, 2, 0)")
    c.commit()
    c.close()


APP_SCHEMA = """
CREATE TABLE games(id INTEGER PRIMARY KEY, collection TEXT, game_key TEXT,
  white TEXT, black TEXT, result TEXT, date TEXT, played_at INTEGER, speed TEXT,
  white_elo INTEGER, black_elo INTEGER, eco TEXT, headers_json TEXT, pgn TEXT,
  imported_at INTEGER);
CREATE TABLE positions(pos INTEGER, game_id INTEGER, ply INTEGER,
  PRIMARY KEY(pos, game_id)) WITHOUT ROWID;
CREATE TABLE collections(collection TEXT PRIMARY KEY, updated_at INTEGER,
  meta_json TEXT);
"""


def make_app_db(path: Path) -> None:
    c = sqlite3.connect(path)
    c.executescript(APP_SCHEMA)
    c.execute(
        "INSERT INTO games VALUES(1,'analysis:chesscom_me','chesscom_1','me','them',"
        "'1-0','2025.06.01',1748736000000,'blitz',1900,1850,'C60',"
        "'{\"White\":\"me\"}','1. e4 e5 2. Nf3 Nc6 1-0',0)"
    )
    c.execute(
        "INSERT INTO positions VALUES(?,1,1)", (position_key(fen4_of(AFTER_E4)),)
    )
    c.execute("INSERT INTO collections VALUES('analysis:chesscom_me', 0, '{}')")
    c.commit()
    c.close()


class AppGamesToolsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.db = Path(self.tmp.name) / "app_games.db"
        make_app_db(self.db)
        os.environ["CHESS_PREP_APP_GAMES_DB"] = str(self.db)
        self.registry = Registry()

    def tearDown(self):
        os.environ.pop("CHESS_PREP_APP_GAMES_DB", None)
        self.tmp.cleanup()

    def test_status_and_lookups(self):
        s = self.registry.call("my_games_status", {})
        self.assertEqual(s["collections"][0]["games"], 1)
        g = self.registry.call("my_game", {"id": 1})
        self.assertEqual(g["headers"]["White"], "me")
        by = self.registry.call("my_games_by_player", {"player": "ME"})
        self.assertEqual(by["count"], 1)

    def test_games_at_position(self):
        try:
            import chess  # noqa: F401
        except ImportError:
            self.skipTest("python-chess not installed")
        r = self.registry.call("my_games_at", {"moves": "1. e4"})
        self.assertEqual(r["count"], 1)
        self.assertEqual(r["games"][0]["collection"], "analysis:chesscom_me")
        none = self.registry.call("my_games_at", {"moves": "1. d4"})
        self.assertEqual(none["count"], 0)


class PositionKeyTest(unittest.TestCase):
    def test_matches_dart_reference_values(self):
        # Pinned in test/services/master_games/master_games_db_test.dart too.
        self.assertEqual(position_key(fen4_of(START)), -1777514259035056900)
        self.assertEqual(position_key(fen4_of(AFTER_E4)), 3107432833210105763)


class ToolsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.db = Path(self.tmp.name) / "master_games.db"
        make_db(self.db)
        os.environ["CHESS_PREP_MASTER_DB"] = str(self.db)
        self.registry = Registry()

    def tearDown(self):
        os.environ.pop("CHESS_PREP_MASTER_DB", None)
        self.tmp.cleanup()

    def test_status(self):
        s = self.registry.call("master_status", {})
        self.assertEqual(s["games"], 2)
        self.assertEqual(s["first_issue"], 1650)

    def test_book_and_citation(self):
        try:
            import chess  # noqa: F401
        except ImportError:
            self.skipTest("python-chess not installed")
        r = self.registry.call("master_book", {"moves": ""})
        self.assertEqual(r["games"], 40)
        self.assertEqual([m["san"] for m in r["moves"]], ["e4", "d4"])
        self.assertEqual(r["moves"][0]["share"], 0.75)
        self.assertEqual(
            r["moves"][0]["top_game"]["citation"], "Giri–Caruana, Wijk aan Zee 2025"
        )

    def test_game_and_player(self):
        g = self.registry.call("master_game", {"id": 2})
        self.assertIn('[White "Keymer,V"]', g["pgn"])
        self.assertIn("1. d4 Nf6 2. Bf4 1-0", g["pgn"])
        games = self.registry.call("master_games", {"player": "Giri"})
        self.assertEqual(games["count"], 2)
        self.assertEqual(games["games"][0]["id"], 2)  # newest first
        with self.assertRaises(ToolError):
            self.registry.call("master_game", {"id": 99})

    def test_missing_db_is_a_tool_error(self):
        os.environ["CHESS_PREP_MASTER_DB"] = str(self.db) + ".missing"
        with self.assertRaises(ToolError):
            MasterGamesDb()


if __name__ == "__main__":
    unittest.main()
