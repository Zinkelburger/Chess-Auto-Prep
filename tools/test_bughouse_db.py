#!/usr/bin/env python3
"""Tests for the FICS bughouse archive pipeline.

Zero dependencies beyond python-chess (unittest only).  Everything runs off
inline BPGN fixtures, so the suite passes on a checkout that has never
downloaded the 2.1 GB archive.

Run:
    python3 tools/test_bughouse_db.py
"""

from __future__ import annotations

import bz2
import io
import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from bughouse_db.bpgn import iter_games  # noqa: E402
from bughouse_db.poskey import (  # noqa: E402
    canonical_fen4,
    dual_key_fen,
    position_key,
)

START = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR[] w KQkq - 0 1"

# Two games sharing their first four half-moves, so the fixture exercises
# both aggregation and branching.
FIXTURE = (
    '[Event "FICS rated bughouse game"]\r\n'
    '[Site "FICS - freechess.org"]\r\n'
    '[Date "2016.01.02"]\r\n'
    '[BughouseDBGameNo "100"]\r\n'
    '[WhiteA "alice"][WhiteAElo "2100"]\r\n'
    '[BlackA "bob"][BlackAElo "2100"]\r\n'
    '[WhiteB "carol"][WhiteBElo "2100"]\r\n'
    '[BlackB "dave"][BlackBElo "2100"]\r\n'
    '[Result "1-0"]\r\n'
    "\r\n"
    "{C:This is game number 100 at http://www.bughouse-db.org}\r\n"
    "1A. e4{299.000} 1B. d4{295.000} 1a. e5{299.000} 1b. d5{298.000} "
    "2A. Nf3{295.000}\r\n"
    "{bob resigns} 1-0\r\n"
    "\r\n"
    '[Event "FICS rated bughouse game"]\r\n'
    '[Date "2017.05.06"]\r\n'
    '[BughouseDBGameNo "101"]\r\n'
    '[WhiteA "eve"][WhiteAElo "2400"]\r\n'
    '[BlackA "mallory"][BlackAElo "2400"]\r\n'
    '[WhiteB "peggy"][WhiteBElo "2400"]\r\n'
    '[BlackB "trent"][BlackBElo "2400"]\r\n'
    '[Result "0-1"]\r\n'
    "\r\n"
    "1A. e4{299.000} 1B. d4{295.000} 1a. e5{299.000} 1b. d5{298.000} "
    "2A. Bc4{295.000}\r\n"
    "{eve forfeits on time} 0-1\r\n"
    "\r\n"
    '[Event "FICS unrated bughouse game"]\r\n'
    '[Date "2018.01.01"]\r\n'
    '[BughouseDBGameNo "102"]\r\n'
    '[WhiteA "gu\xefllaume"][WhiteAElo "0"]\r\n'
    '[Result "1-0"]\r\n'
    "\r\n"
    "{nobody moved} 1-0\r\n"
)


class TestBpgn(unittest.TestCase):
    def games(self):
        return list(iter_games(io.StringIO(FIXTURE)))

    def test_splits_records(self):
        self.assertEqual(len(self.games()), 3)

    def test_keeps_interleaved_order_and_mover_case(self):
        # The whole point of BPGN: board A's and board B's half-moves arrive
        # in the order they were actually played, not board by board.
        self.assertEqual(
            self.games()[0].moves,
            [("A", "e4"), ("B", "d4"), ("a", "e5"), ("b", "d5"), ("A", "Nf3")],
        )

    def test_strips_comments_and_clocks(self):
        for _, san in self.games()[0].moves:
            self.assertNotIn("{", san)
            self.assertNotIn("}", san)

    def test_tags_and_derived_fields(self):
        game = self.games()[0]
        self.assertEqual(game.game_no, 100)
        self.assertEqual(game.result, "1-0")
        self.assertEqual(game.year, 2016)
        self.assertTrue(game.rated)
        self.assertEqual(game.avg_elo, 2100)

    def test_unrated_and_latin1_handles(self):
        game = self.games()[2]
        self.assertFalse(game.rated)
        self.assertEqual(game.tags["WhiteA"], "gu\xefllaume")

    def test_a_game_with_no_moves_is_not_an_error(self):
        # Resigning before a move is played is common in the archive.
        self.assertEqual(self.games()[2].moves, [])

    def test_drops_and_promotions_survive(self):
        text = (
            '[Event "x"]\r\n[Result "*"]\r\n\r\n'
            "1A. N@f3{1.0} 1a. bxa8=Q{2.0} 1B. B@c4{3.0}\r\n"
        )
        moves = list(iter_games(io.StringIO(text)))[0].moves
        self.assertEqual(
            moves, [("A", "N@f3"), ("a", "bxa8=Q"), ("B", "B@c4")]
        )


class TestPositionKey(unittest.TestCase):
    def test_truncates_to_four_fields(self):
        self.assertEqual(
            canonical_fen4(START),
            "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR[] w KQkq -",
        )

    def test_move_counters_do_not_change_the_key(self):
        later = START.replace(" 0 1", " 7 21")
        self.assertEqual(
            position_key(dual_key_fen(START, START)),
            position_key(dual_key_fen(later, later)),
        )

    def test_matches_dart_position_key(self):
        # Pinned against Dart's `positionKey` (FNV-1a, signed 64-bit) so the
        # book the Python indexer writes is readable by the Flutter app.
        # Regenerate with tools/bughouse_db/README.md if this ever moves.
        self.assertEqual(
            position_key(dual_key_fen(START, START)), -1476275556734231047
        )

    def test_boards_are_not_interchangeable(self):
        other = START.replace("RNBQKBNR", "RNBQKB1R")
        self.assertNotEqual(
            position_key(dual_key_fen(START, other)),
            position_key(dual_key_fen(other, START)),
        )


class TestIndexAndBook(unittest.TestCase):
    """End to end: fixture -> book -> explorer query."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        os.environ["BUGHOUSE_DB_HOME"] = cls.tmp.name
        corpus = Path(cls.tmp.name) / "corpus"
        corpus.mkdir(parents=True)
        (corpus / "export2016.bpgn.bz2").write_bytes(
            bz2.compress(FIXTURE.encode("latin-1"))
        )
        from bughouse_db.index import build

        build(None, max_ply=16, min_games=1, min_elo=0, jobs=1)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()
        os.environ.pop("BUGHOUSE_DB_HOME", None)

    def setUp(self):
        from bughouse_db.book import open_book

        self.con = open_book()

    def tearDown(self):
        self.con.close()

    def test_start_position_sees_both_games(self):
        from bughouse_db.book import explore

        data = explore(self.con, START, START)
        self.assertEqual(data["games"], 2)
        self.assertEqual(len(data["moves"]), 1)
        move = data["moves"][0]
        self.assertEqual((move["board"], move["san"]), ("A", "e4"))
        self.assertEqual(move["games"], 2)
        self.assertEqual(move["play_rate"], 100.0)

    def test_results_are_team_relative(self):
        from bughouse_db.book import explore

        move = explore(self.con, START, START)["moves"][0]
        # One game each way: 1-0 is WhiteA's team, 0-1 is BlackA's.
        self.assertEqual((move["team_a"], move["team_b"]), (1, 1))

    def test_branch_after_the_shared_opening(self):
        from bughouse_db.book import explore
        from bughouse.board import DualBoard

        board = DualBoard()
        for which, san in [("A", "e4"), ("B", "d4"), ("a", "e5"), ("b", "d5")]:
            board.push(which, san)
        data = explore(
            self.con, board.board("A").fen(), board.board("B").fen()
        )
        self.assertEqual(data["games"], 2)
        self.assertEqual(
            sorted((m["board"], m["san"]) for m in data["moves"]),
            [("A", "Bc4"), ("A", "Nf3")],
        )

    def test_elo_and_provenance_are_carried(self):
        from bughouse_db.book import explore

        move = explore(self.con, START, START)["moves"][0]
        self.assertEqual(move["avg_elo"], 2250)  # (2100 + 2400) / 2
        self.assertEqual(move["max_elo"], 2400)
        self.assertEqual(move["top_game"], 101)  # the 2400 game
        self.assertEqual(move["last_year"], 2017)

    def test_unknown_position_is_empty_not_an_error(self):
        from bughouse_db.book import explore

        empty = "8/8/8/8/8/8/8/K6k[] w - - 0 1"
        data = explore(self.con, empty, empty)
        self.assertEqual(data["games"], 0)
        self.assertEqual(data["moves"], [])


class TestUnreplayableGamesLeaveNoTrace(unittest.TestCase):
    """A game the replay rejects must not reach the book at all.

    Real archive records sometimes start mid-play — an adjournment resumed, a
    truncated dump — so their first move is illegal from the opening position.
    Counting an edge before pushing it filed those replies against the
    *starting* position, which is how the opening node came to list 339
    impossible continuations (`1A. e6`, `1A. Nf6`) alongside the twenty real
    first moves on each board.
    """

    FIXTURE = (
        '[Event "FICS rated bughouse game"]\r\n'
        '[Date "2016.01.02"]\r\n'
        '[BughouseDBGameNo "200"]\r\n'
        '[WhiteA "alice"][WhiteAElo "2100"]\r\n'
        '[Result "1-0"]\r\n'
        "\r\n"
        "1A. e4{299.000} 1B. d4{295.000}\r\n"
        "{bob resigns} 1-0\r\n"
        "\r\n"
        # Starts on a black reply, filed as White's first move: illegal, and
        # illegal on the very first half-move, which is the case that used to
        # slip through.
        '[Event "FICS rated bughouse game"]\r\n'
        '[Date "2016.03.04"]\r\n'
        '[BughouseDBGameNo "201"]\r\n'
        '[WhiteA "eve"][WhiteAElo "2400"]\r\n'
        '[Result "0-1"]\r\n'
        "\r\n"
        "1A. e6{299.000} 1B. d4{295.000}\r\n"
        "{eve forfeits on time} 0-1\r\n"
    )

    def test_an_illegal_first_move_is_not_banked(self):
        tmp = tempfile.TemporaryDirectory()
        try:
            os.environ["BUGHOUSE_DB_HOME"] = tmp.name
            corpus = Path(tmp.name) / "corpus"
            corpus.mkdir(parents=True)
            (corpus / "export2016.bpgn.bz2").write_bytes(
                bz2.compress(self.FIXTURE.encode("latin-1"))
            )
            from bughouse_db.book import explore, open_book
            from bughouse_db.index import build

            build(None, max_ply=16, min_games=1, min_elo=0, jobs=1)
            con = open_book()
            data = explore(con, START, START)
            self.assertEqual(
                [(m["board"], m["san"]) for m in data["moves"]], [("A", "e4")]
            )
            self.assertEqual(data["games"], 1)
            con.close()
        finally:
            os.environ.pop("BUGHOUSE_DB_HOME", None)
            tmp.cleanup()


class TestPruningKeepsTotals(unittest.TestCase):
    """The two-table design's load-bearing invariant.

    Pruning rare continuations must not deflate what a position reports, or
    the explorer quietly understates every node it shows.
    """

    def test_node_total_survives_edge_pruning(self):
        tmp = tempfile.TemporaryDirectory()
        try:
            os.environ["BUGHOUSE_DB_HOME"] = tmp.name
            corpus = Path(tmp.name) / "corpus"
            corpus.mkdir(parents=True)
            (corpus / "export2016.bpgn.bz2").write_bytes(
                bz2.compress(FIXTURE.encode("latin-1"))
            )
            from bughouse_db.book import explore, open_book
            from bughouse.board import DualBoard
            from bughouse_db.index import build

            # min_games=2 drops both singleton branches at ply 4.
            build(None, max_ply=16, min_games=2, min_elo=0, jobs=1)
            con = open_book()
            board = DualBoard()
            for which, san in [("A", "e4"), ("B", "d4"), ("a", "e5"), ("b", "d5")]:
                board.push(which, san)
            data = explore(
                con, board.board("A").fen(), board.board("B").fen()
            )
            self.assertEqual(data["moves"], [])  # both branches pruned
            self.assertEqual(data["games"], 2)  # but the node still counts 2
            con.close()
        finally:
            os.environ.pop("BUGHOUSE_DB_HOME", None)
            tmp.cleanup()


if __name__ == "__main__":
    sys.path.insert(0, str(Path(__file__).resolve().parent / "mcp"))
    unittest.main(verbosity=2)
