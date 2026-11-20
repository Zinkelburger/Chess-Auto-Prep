#!/usr/bin/env python3
# A None here fails the test on its own, so pyright's None checks add nothing.
# pyright: reportOptionalMemberAccess=false, reportOptionalSubscript=false, reportOptionalIterable=false, reportOptionalOperand=false
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
from typing import Any
from unittest import mock

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

    def test_hivemind_book_follows_the_most_played_moves(self):
        from bughouse_db import hivemind_book as hb

        with tempfile.TemporaryDirectory() as tmp:
            con = hb.open_db(Path(tmp) / "hivemind_book.db")
            hb.expand_fics(con, self.con, hb.DualBoard(), "", 0, width=4)
            rows = con.execute("SELECT line, ply, priority, status FROM position").fetchall()
            con.close()
        # The fixture's only continuation from the start, queued by its games.
        self.assertEqual(rows, [("A:e4", 1, -2.0, "queued")])

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


class TestHivemindBook(unittest.TestCase):
    """The engine-free parts of hivemind_book.py."""

    def test_a_top_line_with_no_score_reports_nothing_instead_of_crashing(self):
        import chess
        from bughouse.engine import Line, SearchResult
        from bughouse_db import hivemind_book as hb

        result = SearchResult(None, None, [Line(depth=3)])
        self.assertEqual(hb.for_ac(result, chess.WHITE, 0.0), (None, None))

    def test_key_is_the_fics_book_key(self):
        from bughouse_db import hivemind_book as hb

        self.assertEqual(hb.key_of(hb.DualBoard()), position_key(dual_key_fen(START, START)))

    def test_clock_cases_map_onto_the_one_engine_bit(self):
        import chess
        from bughouse_db.hivemind_book import team_bits

        # A + B is White on board A. Only the team ahead has the bit on.
        self.assertEqual(team_bits("ahead"), {chess.WHITE: True, chess.BLACK: False})
        self.assertEqual(team_bits("even"), {chess.WHITE: False, chess.BLACK: False})
        self.assertEqual(team_bits("behind"), {chess.WHITE: False, chess.BLACK: True})
        self.assertEqual(team_bits("both"), {chess.WHITE: True, chess.BLACK: True})

    def test_both_is_filled_from_the_searches_already_made(self):
        import sqlite3

        import chess
        from bughouse_db import hivemind_book as hb

        # Raw Q of each team's own search, bit on and off, and of C + D
        # answering A's e4 (board A: C + D answers) with its bit on.
        raw = {("AC", True): 0.1, ("AC", False): -0.5, ("BD", True): 0.05, ("BD", False): -0.6}
        answer_on = 0.3
        off = {c: (raw[("AC", b[chess.WHITE])] + raw[("BD", b[chess.BLACK])]) / 2
               for c in hb.CLOCKS for b in [hb.team_bits(c)]}
        con = sqlite3.connect(":memory:")
        con.executescript(hb.SCHEMA)
        dual = hb.DualBoard()
        pos = hb.key_of(dual)
        con.execute("INSERT INTO position VALUES(?,?,?,?,?,?,?,?,?,?)",
                    (pos, dual.dual_fen, "", 0, 0, "done", 100, 10, 1.0, ""))
        for clock in ("ahead", "even", "behind"):
            bits = hb.team_bits(clock)
            for team, colour in (("AC", chess.WHITE), ("BD", chess.BLACK)):
                sign = 1 if team == "AC" else -1
                score = round(sign * hb.to_score(raw[(team, bits[colour])] - off[clock]), 3)
                con.execute("INSERT INTO pick VALUES(?,?,?,?,?,?,?,?)",
                            (pos, clock, team, "", score, None, "", round(off[clock], 4)))
            bd_bit = bits[chess.BLACK]
            q = answer_on if bd_bit else -0.4
            con.execute("INSERT INTO move VALUES(?,?,?,?,?,?,?,?,?)",
                        (pos, "A:e4", "A", "e2e4", clock, round(-hb.to_score(q - off[clock]), 3), None, "A e4", 0))
        self.assertEqual(hb.fill_both(con), 1)
        got = con.execute("SELECT score FROM move WHERE clock='both'").fetchone()[0]
        self.assertAlmostEqual(got, -hb.to_score(answer_on - off["both"]), places=2)
        picks = dict(con.execute("SELECT team, score FROM pick WHERE clock='both'").fetchall())
        self.assertAlmostEqual(picks["AC"], hb.to_score(raw[("AC", True)] - off["both"]), places=2)
        self.assertAlmostEqual(picks["BD"], -hb.to_score(raw[("BD", True)] - off["both"]), places=2)
        self.assertEqual(hb.fill_both(con), 0, "filled once")

    def test_workers_never_claim_the_same_position(self):
        from bughouse_db import hivemind_book as hb

        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "book.db"
            one, two = hb.open_db(path), hb.open_db(path)
            dual = hb.DualBoard()
            hb.enqueue(one, dual, "", 0, -2)
            dual.push("A", "e4")
            hb.enqueue(one, dual, "A:e4", 1, -1)
            one.commit()
            first, second = hb.claim(one), hb.claim(two)
            self.assertEqual(first[2], "")  # most-played first
            self.assertEqual(second[2], "A:e4")
            self.assertIsNone(hb.claim(one))
            one.close()
            two.close()

    def test_seats_follow_the_side_to_move(self):
        from bughouse_db import hivemind_book as hb

        dual = hb.DualBoard()
        self.assertEqual((hb.seat_of(dual, 0), hb.seat_of(dual, 1)), ("A", "D"))
        dual.push("A", "e4")
        dual.push("B", "d4")
        # Partners hold opposite colours: board 1 is A and C, board 2 D and B.
        self.assertEqual((hb.seat_of(dual, 0), hb.seat_of(dual, 1)), ("C", "B"))


class TestIndexReplacementSafety(unittest.TestCase):
    def test_failed_final_replace_preserves_the_previous_book(self):
        tmp = tempfile.TemporaryDirectory()
        try:
            os.environ["BUGHOUSE_DB_HOME"] = tmp.name
            corpus = Path(tmp.name) / "corpus"
            corpus.mkdir(parents=True)
            (corpus / "export2016.bpgn.bz2").write_bytes(
                bz2.compress(FIXTURE.encode("latin-1"))
            )
            old_book = Path(tmp.name) / "bughouse_book.db"
            old_book.write_bytes(b"previous usable book")
            from bughouse_db.index import build

            with mock.patch.object(
                Path,
                "replace",
                side_effect=OSError("injected commit failure"),
            ):
                with self.assertRaisesRegex(OSError, "injected commit failure"):
                    build(None, max_ply=16, min_games=1, min_elo=0, jobs=1)

            self.assertEqual(old_book.read_bytes(), b"previous usable book")
        finally:
            os.environ.pop("BUGHOUSE_DB_HOME", None)
            tmp.cleanup()


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


class SnapshotTests(unittest.TestCase):
    def test_wal_backup_roundtrip_and_corruption(self):
        import sqlite3
        import json
        from bughouse_db import snapshot
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            live = root / "live"
            live.mkdir()
            connections = []
            try:
                for name in snapshot.NAMES:
                    con = sqlite3.connect(live / name)
                    connections.append(con)
                    con.execute("PRAGMA journal_mode=WAL")
                    con.execute("CREATE TABLE sample(value TEXT)")
                    con.execute("INSERT INTO sample VALUES('committed in WAL')")
                    con.commit()
                backup = root / "backup"
                with mock.patch.object(snapshot, "CHUNK", 64):
                    snapshot.export(live, backup)
                snapshot.restore(backup, root / "restored")
                for name in snapshot.NAMES:
                    con = sqlite3.connect(root / "restored" / name)
                    self.assertEqual(con.execute("SELECT value FROM sample").fetchone()[0], "committed in WAL")
                    con.close()
                with self.assertRaises(ValueError):
                    snapshot.restore(backup, root / "restored")
                manifest = json.loads((backup / "manifest.json").read_text())
                part = backup / manifest["databases"][0]["chunks"][0]["name"]
                part.write_bytes(b"damaged")
                with self.assertRaisesRegex(ValueError, "Checksum mismatch"):
                    snapshot.restore(backup, root / "corrupt")
                self.assertFalse((root / "corrupt" / snapshot.NAMES[0]).exists())
            finally:
                for con in connections:
                    con.close()

    def test_provenance_preserves_legacy_before_replacement(self):
        import json
        from bughouse_db import hivemind_book as hb, provenance
        with tempfile.TemporaryDirectory() as tmp:
            con = hb.open_db(Path(tmp) / "book.db")
            con.execute("INSERT INTO position VALUES(1,'fen','',0,0,'done',1500,200,1,'old date')")
            con.execute("INSERT INTO move VALUES(1,'A:e4','A','e2e4','even',0.2,NULL,'A e4',2)")
            provenance.preserve_legacy(con, 1)
            con.execute("UPDATE move SET score=0.4")
            provenance.snapshot(con, 1, "even", {"engine_name": "new build", "nodes": 3000, "child_nodes": 400})
            provenance.preserve_legacy(con, 1)
            rows = con.execute("SELECT provenance,moves FROM analysis_history").fetchall()
            self.assertEqual(len(rows), 2)
            old = next(row for row in rows if "Unknown" in row[0])
            self.assertEqual(json.loads(old[1])[0]["score"], 0.2)
            current = con.execute("SELECT provenance FROM current_analysis JOIN analysis_history USING(id)").fetchone()
            self.assertEqual(json.loads(current[0])["nodes"], 3000)
            con.close()


class FakeEngine:
    """Scripted search results, consumed in call order."""

    def __init__(self, results):
        self.results = list(results)
        self.calls = []

    def new_game(self):
        pass

    def search(self, fen, nodes, multipv=1):
        self.calls.append((fen, nodes, multipv))
        ranks = self.results.pop(0)
        return ranks, ranks[1][2][0] if ranks else "(none)"


def cp(move, value, second=None):
    """A two-rank result: `move` at `value` cp, and the second-best if given."""
    ranks = {1: ("cp", value, [move])}
    if second:
        ranks[2] = second
    return ranks


class TestPuzzleExport(unittest.TestCase):
    """The puzzle miner's engine-free half: frozen reserves, policy and the web layout."""

    FEN = "r4k1r/ppN2ppp/3Pp3/2Np4/1n1P4/4Pq2/PPPKBb1P/R2Q1Bq1[Nrnp] w - - 4 27"
    PREV = "r4rk1/ppN2ppp/3Pp3/2Np4/1n1P4/4Pq2/PPPKBb1P/R2Q1Bq1[Nrnp] b - - 3 26"

    def candidate(self, **over):
        from bughouse_db.puzzles import Candidate

        base: dict[str, Any] = dict(
            fen=self.FEN, dual=f"{START}|{self.FEN}", board="B", ply=101, last="f8g8",
            played="Nd7+", game=3677428, date="2017.12.31", tc="120+0", white="W",
            black="B", welo=1853, belo=1666, line=["c5d7", "f8g8", "N@e7"], mates=["N@e7"],
            prev=self.PREV,
        )
        base.update(over)
        return Candidate(**base)

    def test_capture_does_not_reach_the_capturers_hand(self):
        from chess.variant import CrazyhouseBoard
        from bughouse_db.frozen import frozen_push

        board = CrazyhouseBoard("rnbqkbnr/ppp1pppp/8/3p4/4P3/8/PPPP1PPP/RNBQKBNR[Nn] w KQkq - 0 2")
        self.assertEqual(frozen_push(board, "e4d5"), "exd5")
        self.assertEqual(board.fen().split()[0].split("[")[1], "Nn]")
        frozen_push(board, "N@f6")
        self.assertEqual(board.fen().split()[0].split("[")[1], "N]")

    def test_pawn_drops_are_written_with_the_piece_letter(self):
        from chess.variant import CrazyhouseBoard
        from bughouse_db.frozen import frozen_push
        from bughouse_db.puzzles import web_puzzle

        board = CrazyhouseBoard("rnbqkbnr/ppp1pppp/8/3p4/4P3/8/PPPP1PPP/RNBQKBNR[Pp] w KQkq - 0 2")
        self.assertEqual(frozen_push(board, "P@f6"), "P@f6")
        p = web_puzzle(self.candidate(fen="6rk/6pp/8/8/8/8/8/K7[PN] w - - 0 1",
                                      line=["P@g6", "h7g6", "N@f7"], mates=[], kind="advantage",
                                      cp=900, played="P@g6"))
        self.assertEqual(p["san"], ["P@g6", "hxg6", "N@f7+"])
        self.assertTrue(p["found"], "a FICS pawn drop matches the line's first move")

    def test_web_puzzle_carries_san_legal_moves_and_whether_it_was_found(self):
        from bughouse_db.puzzles import web_puzzle

        p = web_puzzle(self.candidate())
        self.assertIsNotNone(p)
        self.assertEqual(p["san"], ["Nd7+", "Kg8", "N@e7#"])
        self.assertEqual((p["kind"], p["mate"], p["moves"]), ("mate", 2, 2))
        self.assertEqual(len(p["legal"]), 2, "one legal-move list per solver step")
        self.assertIn("c5d7", p["legal"][0].split())
        self.assertIn("N@e7", p["legal"][1].split())
        self.assertTrue(p["found"])
        self.assertEqual(p["prev"], self.PREV)
        self.assertIn("mateIn2", p["themes"])
        self.assertIn("dropMate", p["themes"])
        self.assertIn(p["difficulty"], (1, 2, 3))
        self.assertFalse(web_puzzle(self.candidate(played="Nb7"))["found"])

    def test_a_mate_line_that_does_not_end_in_mate_is_dropped(self):
        from bughouse_db.puzzles import web_puzzle

        self.assertIsNone(web_puzzle(self.candidate(line=["c5d7", "f8g8", "N@e6"])))

    def test_a_one_move_tactic_played_in_the_game_was_found(self):
        from bughouse_db.puzzles import web_puzzle

        # A one-move tactic with no other collecting moves has an empty `mates`;
        # the line's own move still counts as found.
        p = web_puzzle(self.candidate(kind="advantage", line=["c5d7"], mates=[], cp=700, played="Nd7+"))
        self.assertTrue(p["found"])
        p = web_puzzle(self.candidate(kind="advantage", line=["c5d7"], mates=["c5b7"], cp=700, played="Nxb7"))
        self.assertTrue(p["found"], "another collecting move counts too")
        self.assertFalse(web_puzzle(self.candidate(kind="advantage", line=["c5d7"], mates=[], cp=700,
                                                   played="Nb3"))["found"])

    def test_a_one_move_tactic_out_of_check_is_not_kept(self):
        from bughouse_db.puzzles import web_puzzle

        # White is in check from the knight on c2 and takes it: not a puzzle.
        checked = "4k3/8/8/8/8/8/2n5/K2B4[] w - - 0 30"
        self.assertIsNone(web_puzzle(self.candidate(fen=checked, kind="advantage", line=["d1c2"], mates=[],
                                                    cp=700, played="Bxc2", prev=None)))
        # The same capture without the check is kept, and a longer line from check is too.
        quiet = "4k3/8/8/8/8/8/2n5/3B3K[] w - - 0 30"
        self.assertIsNotNone(web_puzzle(self.candidate(fen=quiet, kind="advantage", line=["d1c2"], mates=[],
                                                       cp=700, played="Bxc2", prev=None)))
        self.assertIsNotNone(web_puzzle(self.candidate(fen=checked, kind="advantage", line=["d1c2", "e8d7", "c2b3"],
                                                       mates=[], cp=700, played="Bxc2", prev=None)))

    def test_advantage_record_has_no_mate_and_keeps_cp(self):
        from bughouse_db.puzzles import web_puzzle

        p = web_puzzle(self.candidate(kind="advantage", line=["c5d7", "f8g8", "d7b8"],
                                      mates=[], cp=850, played="Nxe6"))
        self.assertEqual((p["kind"], p["mate"], p["moves"], p["cp"]), ("advantage", 0, 2, 850))
        self.assertEqual(p["mates"], [])
        self.assertFalse(p["found"])
        self.assertIn("crushing", p["themes"])

    def test_advantage_line_may_end_in_mate_and_stays_advantage(self):
        from bughouse_db.puzzles import web_puzzle

        # The solver kept this line as an advantage (e.g. the mate rules failed):
        # its mating last move is accepted as-is, not re-verified or rejected.
        p = web_puzzle(self.candidate(kind="advantage", mates=[], cp=None, played="Nb7"))
        self.assertIsNotNone(p)
        self.assertEqual((p["kind"], p["mate"], p["moves"]), ("advantage", 0, 2))
        self.assertIn("mateIn2", p["themes"])
        self.assertEqual(p["san"][-1], "N@e7#")

    def test_export_from_raw_rebuilds_the_directory_without_an_engine(self):
        import json
        from bughouse_db import puzzles as api
        from dataclasses import asdict

        with tempfile.TemporaryDirectory() as tmp:
            raw = Path(tmp) / "raw.json"
            raw.write_text(json.dumps([asdict(self.candidate())]))
            out = Path(tmp) / "out"
            self.assertEqual(api.run(2017, 5, 1800, 0, None, out, None, from_raw=raw), 0)
            index = json.loads((out / "index.json").read_text())
        self.assertEqual(index["count"], 1)
        self.assertIn("5 rated FICS bughouse games from 2017", index["source"])

    # ── Scores and triggers ─────────────────────────────────────────

    def test_win_chances_follow_lila(self):
        from bughouse_db.puzzles import win_chances

        self.assertEqual(win_chances(("mate", 3)), 1.0)
        self.assertEqual(win_chances(("mate", -1)), -1.0)
        self.assertAlmostEqual(win_chances(("cp", 0)), 0.0)
        self.assertAlmostEqual(win_chances(("cp", 200)), 0.3522, places=3)
        self.assertAlmostEqual(win_chances(("cp", -200)), -0.3522, places=3)

    def test_advantage_trigger_needs_a_jump_from_a_not_yet_winning_position(self):
        from bughouse_db.puzzles import wants_advantage

        self.assertTrue(wants_advantage(("cp", 450), ("cp", 20)))
        self.assertFalse(wants_advantage(("cp", 250), ("cp", 20)), "not enough of a jump")
        self.assertFalse(wants_advantage(("cp", 900), ("cp", 350)), "already winning")
        self.assertTrue(wants_advantage(("mate", 9), ("cp", -100)), "a long mate counts")
        self.assertFalse(wants_advantage(("cp", 150), ("cp", -900)), "not winning enough")

    # ── Mate-in-one policy ──────────────────────────────────────────

    def test_mate_in_one_policy(self):
        from bughouse_db.puzzles import keep_mate_in_one

        self.assertTrue(keep_mate_in_one(found=False, drop=False, legal=5))
        self.assertTrue(keep_mate_in_one(found=True, drop=True, legal=20))
        self.assertFalse(keep_mate_in_one(found=True, drop=True, legal=19))
        self.assertFalse(keep_mate_in_one(found=True, drop=False, legal=40))

    def test_found_plain_mate_in_one_is_not_exported(self):
        from bughouse_db.puzzles import web_puzzle

        one = self.candidate(fen=self.SMOTHER, line=["d6f7"], mates=["d6f7"], played="Nf7#")
        self.assertIsNone(web_puzzle(one))
        missed = web_puzzle(self.candidate(fen=self.SMOTHER, line=["d6f7"], mates=["d6f7"], played="Nb5"))
        self.assertIsNotNone(missed)
        self.assertIn("smotheredMate", missed["themes"])

    def test_a_check_a_drop_could_block_is_not_mate(self):
        from chess.variant import CrazyhouseBoard
        from bughouse_db.frozen import bughouse_mate, mating_moves
        from bughouse_db.puzzles import web_puzzle

        back_rank = CrazyhouseBoard("4R1k1/5ppp/8/8/8/8/8/K7[] b - - 0 1")
        self.assertTrue(back_rank.is_checkmate(), "mate in chess and in crazyhouse")
        self.assertFalse(bughouse_mate(back_rank), "f8 could take a dropped piece")
        self.assertTrue(bughouse_mate(CrazyhouseBoard("6rk/5Npp/8/8/8/8/8/K7[] b - - 0 1")))
        self.assertEqual(mating_moves(CrazyhouseBoard("6k1/5ppp/8/8/8/8/8/K3R3[] w - - 0 30")), [])
        self.assertIsNone(web_puzzle(self.candidate(fen="6k1/5ppp/8/8/8/8/8/K3R3[] w - - 0 30",
                                                    line=["e1e8"], mates=["e1e8"], played="Re7")))

    # ── Advantage solving ───────────────────────────────────────────

    ROOK = "k7/ppp5/8/8/8/8/8/K6R[] w - - 0 1"
    SMOTHER = "6rk/6pp/3N4/8/8/8/8/K7[] w - - 0 30"
    def loose(self):
        """Rules that check only lila's one-best-move line."""
        from bughouse_db.puzzles import TacticRules

        return TacticRules(forcing="any", min_gain=-99, sit="", collect_cp=None)

    def lila(self):
        """The default rules, ending the line at the first move that is not unique, as lila does."""
        from bughouse_db.puzzles import TacticRules

        return TacticRules(collect_cp=None)

    def test_advantage_line_is_trimmed_to_moves_with_an_alternative(self):
        from bughouse_db.puzzles import solve_advantage

        engine = FakeEngine([
            cp("h1h2", 450, ("cp", -50, ["h1g1"])),   # valid: 0.68 vs -0.09
            cp("c7c6", -450),                           # defender
            cp("h2h3", 500, ("cp", -100, ["h2g2"])),
            cp("a8b8", -500),
            cp("h3h4", 520),                            # no alternative: trimmed
            cp("b8a8", -520),
            cp("h4h5", 300, ("cp", 250, ["h4g4"])),    # not a valid attack: stop
            cp("a8b8", -500),                           # the final score and line
        ])
        s = solve_advantage(engine, self.ROOK, self.loose())
        assert not isinstance(s, str)
        self.assertEqual((s.kind, s.line, s.cp), ("advantage", ["h1h2", "c7c6", "h2h3"], 500))
        self.assertEqual(engine.calls[0][2], 2, "solver moves use two principal variations")
        self.assertEqual(engine.calls[1][1], engine.calls[0][1] // 2, "defender at half the nodes")

    def test_one_mover_is_discarded(self):
        from bughouse_db.puzzles import solve_advantage

        engine = FakeEngine([
            cp("h1h2", 450, ("cp", -50, ["h1g1"])),
            cp("c7c6", -450),
            cp("h2h3", 300, ("cp", 250, ["h2g2"])),
        ])
        self.assertEqual(solve_advantage(engine, self.ROOK, self.lila()), "one quiet move")

    def test_a_later_move_below_200_busts_the_puzzle(self):
        from bughouse_db.puzzles import solve_advantage

        engine = FakeEngine([
            cp("h1h2", 450, ("cp", -50, ["h1g1"])),
            cp("c7c6", -450),
            cp("h2h3", 150, ("cp", -500, ["h2g2"])),
        ])
        self.assertEqual(solve_advantage(engine, self.ROOK, self.lila()), "not winning")

    def test_advantage_line_ending_in_mate_becomes_a_mate_puzzle(self):
        from bughouse_db.puzzles import solve_advantage

        engine = FakeEngine([{1: ("mate", 1, ["d6f7"]), 2: ("cp", 350, ["d6b5"])}])
        s = solve_advantage(engine, self.SMOTHER)
        assert not isinstance(s, str)
        self.assertEqual((s.kind, s.line, s.mates), ("mate", ["d6f7"], ["d6f7"]))
        engine = FakeEngine([{1: ("mate", 1, ["h1h8"]), 2: ("cp", 350, ["h1h7"])}])
        self.assertEqual(solve_advantage(engine, self.ROOK), "blockable mate")

    # A knight check forks king and rook; the rook falls on the next move.
    FORK = "r3k3/8/8/1N6/8/8/P7/K7[] w - - 0 1"

    def fork_engine(self, *tail):
        return FakeEngine([
            cp("b5c7", 600, ("cp", 0, ["b5d4"])),       # Nc7+ forks e8 and a8
            cp("e8d7", -600),
            cp("c7a8", 650, ("cp", 50, ["c7b5"])),      # Nxa8 collects the rook
            cp("d7c8", -650),
            cp("a8b6", 600, ("cp", 550, ["a1b2"])),     # nothing unique left: the line ends
            *tail,
        ])

    def test_a_forcing_material_win_is_a_tactic(self):
        from bughouse_db.puzzles import solve_advantage

        engine = self.fork_engine(
            cp("d7c8", -650),                           # final score; its line takes nothing back
            cp("d7c8", -600),                           # handed a pawn
            cp("d7c8", -450),                           # handed a knight
        )
        s = solve_advantage(engine, self.FORK, self.lila())
        assert not isinstance(s, str)
        self.assertEqual((s.kind, s.line, s.gain, s.sit_cp), ("advantage", ["b5c7", "e8d7", "c7a8"], 5, 450))

    def test_a_fork_is_played_out_to_the_capture_accepting_any_that_wins(self):
        from bughouse_db.puzzles import TacticRules, solve_advantage

        engine = FakeEngine([
            cp("b5c7", 600, ("cp", 0, ["b5d4"])),       # Nc7+ forks e8 and a8
            cp("e8d7", -600),
            cp("c7a8", 650, ("cp", 600, ["c7e6"])),     # two moves win: not unique
            {1: ("cp", 650, ["c7a8"]), 2: ("cp", 560, ["a2a4"]), 3: ("cp", 100, ["c7e6"])},  # a4 takes nothing
            cp("d7c8", -650),                           # final score and line
            cp("d7c8", -600),
            cp("d7c8", -450),
        ])
        s = solve_advantage(engine, self.FORK, TacticRules())
        assert not isinstance(s, str)
        self.assertEqual((s.line, s.mates, s.gain), (["b5c7", "e8d7", "c7a8"], ["c7a8"], 5))
        self.assertEqual(engine.calls[3][2], 5, "the collecting step weighs five moves")

    def test_partner_help_or_a_small_gain_turns_a_tactic_down(self):
        from bughouse_db.puzzles import TacticRules, solve_advantage

        helped = self.fork_engine(cp("d7c8", -650), cp("d7c8", -600), cp("d7c8", 100))
        self.assertEqual(solve_advantage(helped, self.FORK, self.lila()), "partner help saves them")
        greedy = self.fork_engine(cp("d7c8", -650))
        self.assertEqual(solve_advantage(greedy, self.FORK, TacticRules(min_gain=6, collect_cp=None)), "wins too little")

    def test_a_recapture_wins_nothing(self):
        from bughouse_db.puzzles import solve_advantage

        # Before Black's last move White also had the rook's worth: Black took a knight.
        before = "r3k3/8/8/1N6/8/8/P7/K7[N] b - - 0 1"
        engine = self.fork_engine(cp("d7c8", -650))
        self.assertEqual(solve_advantage(engine, self.FORK, self.lila(), prev=before), "wins too little")

    def test_a_quiet_move_before_the_win_lets_them_sit(self):
        from bughouse_db.puzzles import solve_advantage

        engine = FakeEngine([
            cp("b5d4", 600, ("cp", 0, ["b5a3"])),       # quiet: no check, no capture
            cp("e8e7", -600),
            cp("d4c6", 650, ("cp", 50, ["d4b5"])),      # Nc6+
            cp("e7d7", -650),
            cp("c6a5", 600, ("cp", 550, ["a1b2"])),     # nothing unique left: the line ends
        ])
        self.assertEqual(solve_advantage(engine, self.FORK, self.lila()), "lets them sit")

    def test_mate_in_one_with_a_strong_quiet_alternative_is_not_a_valid_attack(self):
        from bughouse_db.puzzles import is_valid_mate_in_one
        from chess.variant import CrazyhouseBoard

        board = CrazyhouseBoard(self.ROOK)
        self.assertTrue(is_valid_mate_in_one(FakeEngine([]), board, ("mate", 1), ("cp", 300)))
        self.assertFalse(is_valid_mate_in_one(FakeEngine([]), board, ("mate", 1), ("cp", 900)))
        self.assertFalse(is_valid_mate_in_one(FakeEngine([]), board, ("mate", 1), ("mate", 2)))

    # ── Themes ──────────────────────────────────────────────────────

    def themes(self, fen, line, cp=None):
        from bughouse_db.themes import tag_themes

        return tag_themes(fen, line, cp)

    def test_smothered_and_drop_mates(self):
        t = self.themes("6rk/6pp/3N4/8/8/8/8/K7[] w - - 0 1", ["d6f7"])
        self.assertEqual(t[:3], ["mateIn1", "mate", "smotheredMate"])
        self.assertNotIn("drop", t)
        t = self.themes("6rk/6pp/8/8/8/8/8/K7[N] w - - 0 1", ["N@f7"])
        self.assertIn("smotheredMate", t)
        self.assertIn("drop", t)
        self.assertIn("dropMate", t)
        self.assertNotIn("contactMate", t)

    def test_back_rank_and_contact_mates(self):
        t = self.themes("6k1/5ppp/8/8/8/8/8/K3R3[] w - - 0 1", ["e1e8"])
        self.assertNotIn("mate", t, "a drop on f8 would block it, so it is not mate in bughouse")
        t = self.themes("6k1/5ppp/8/8/8/Q7/8/K7[R] w - - 0 1", ["R@f8"])
        self.assertIn("contactMate", t)
        self.assertIn("dropMate", t)

    def test_double_and_discovered_check(self):
        fen = "4k3/8/8/8/4B3/8/8/K3R3[] w - - 0 1"
        t = self.themes(fen, ["e4c6", "e8d8", "e1e7"], cp=700)
        self.assertIn("doubleCheck", t)
        self.assertIn("crushing", t)
        t = self.themes(fen, ["e4d3", "e8d8", "e1e7"], cp=700)
        self.assertIn("discoveredCheck", t)
        self.assertNotIn("doubleCheck", t)

    def test_fork(self):
        self.assertIn("fork", self.themes("r3k3/8/8/1N6/8/8/P7/K7[] w - - 0 1",
                                          ["b5c7", "e8d7", "c7a8"], cp=650))
        self.assertIn("fork", self.themes("r3k3/8/8/8/8/8/P7/K7[N] w - - 0 1", ["N@c7", "e8d7", "c7a8"], cp=650))
        self.assertNotIn("fork", self.themes("r3k3/8/8/1N6/8/8/P7/K7[] w - - 0 1", ["b5d4", "e8d7", "d4c6"], cp=650))

    def test_one_move_and_hanging_piece(self):
        t = self.themes("k7/8/8/3r4/8/8/8/K2R4[] w - - 0 1", ["d1d5"], cp=500)
        self.assertIn("oneMove", t)
        self.assertIn("hangingPiece", t)
        t = self.themes("k7/8/4p3/3r4/8/8/8/K2R4[] w - - 0 1", ["d1d5"], cp=300)
        self.assertNotIn("hangingPiece", t, "e6 takes back")

    def test_sacrifice_counts_a_dropped_piece_that_is_taken(self):
        fen = "6k1/5ppp/8/8/8/8/8/K6R[N] w - - 0 1"
        self.assertIn("sacrifice", self.themes(fen, ["N@f6", "g7f6", "h1g1"], cp=300))
        self.assertNotIn("sacrifice", self.themes(fen, ["N@f6", "g8h8", "f6h7"], cp=300))
        self.assertIn("advantage", self.themes(fen, ["N@f6", "g8h8", "f6h7"], cp=300))

    def test_quiet_move_and_long(self):
        t = self.themes("k7/ppp5/8/8/8/8/8/K6R[] w - - 0 1",
                        ["h1h2", "c7c6", "h2h3", "c6c5", "h3h4", "c5c4", "h4h8"])
        self.assertIn("quietMove", t)
        self.assertIn("long", t)
        self.assertNotIn("mateIn4", t, "Rh8+ could be blocked on b8")

    # ── Difficulty ──────────────────────────────────────────────────

    def test_difficulty_adds_points_for_length_drops_and_misses(self):
        from chess.variant import CrazyhouseBoard
        from bughouse_db.puzzles import rate_difficulty

        start = CrazyhouseBoard(self.FEN)
        self.assertEqual(rate_difficulty("mate", 1, [], True, start, "c5d7"), 1)
        self.assertEqual(rate_difficulty("mate", 2, [], False, start, "c5d7"), 2)
        self.assertEqual(rate_difficulty("mate", 3, ["sacrifice"], False, start, "N@e7"), 3)

    # ── Layout ──────────────────────────────────────────────────────

    def test_export_writes_an_index_and_hashed_shards(self):
        import hashlib
        import json
        from bughouse_db import puzzles as api

        adv = self.candidate(kind="advantage", line=["c5d7", "f8g8", "d7b8"], mates=[],
                             cp=850, played="Nxe6", ply=55)
        missed = self.candidate(fen=self.SMOTHER, dual="x|y",
                                line=["d6f7"], mates=["d6f7"], played="Nb5", ply=7, prev=None)
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "bughouse-puzzles"
            out.mkdir()
            (out / "s00-stale00000.json").write_text("{}")
            with mock.patch.object(api, "SHARD_SIZE", 2):
                self.assertEqual(api.export_web([adv, self.candidate(), missed], out, "test"), 3)
            index = json.loads((out / "index.json").read_text())
            files = sorted(p.name for p in out.iterdir())
            self.assertEqual(len(index["shards"]), 2)
            self.assertEqual(files, sorted(["index.json", *index["shards"]]), "stale shards are gone")
            for n, name in enumerate(index["shards"]):
                text = (out / name).read_text()
                self.assertEqual(name, f"s{n:02d}-{hashlib.sha256(text.encode()).hexdigest()[:10]}.json")
                records = json.loads(text)["puzzles"]
                self.assertTrue(all(e["shard"] == n for e in index["puzzles"] if e["id"] in {r["id"] for r in records}))
            self.assertEqual((index["version"], index["count"], index["source"]), (2, 3, "test"))
            self.assertRegex(index["generated"], r"^\d{4}-\d{2}-\d{2}$")
            self.assertEqual(set(index["puzzles"][0]), {"id", "kind", "mate", "moves", "themes",
                                                        "difficulty", "side", "board", "found", "shard"})
            by_id = {e["id"]: e for e in index["puzzles"]}
            self.assertEqual(by_id["3677428-B-55"]["kind"], "advantage")
            self.assertEqual(by_id["3677428-B-55"]["side"], "w")
            full = [r for name in index["shards"] for r in json.loads((out / name).read_text())["puzzles"]]
            prevs = {r["id"]: r["prev"] for r in full}
            self.assertEqual(prevs["3677428-B-101"], self.PREV)
            self.assertIsNone(prevs["3677428-B-7"])


# The arena referee's two generations of BPGN. The newer writes SAN from the
# start with the opening inside the movetext and a score per move; the older
# writes UCI after the opening, which only its tag holds. Comments that are not
# a move's clock (sits, refused moves) must not shift the scores.
ARENA_NEW = (
    '[Event "Hivemind Arena"]\n[Round "3"]\n[WhiteA "hb-cap0"]\n[BlackA "hb-l50"]\n'
    '[WhiteB "hb-l50"]\n[BlackB "hb-cap0"]\n[TimeControl "120"]\n'
    '[Opening "2e2e4 1d2d4 2d7d5 1e7e6 2b1c3 2e7e6 1b1c3 1g8f6 1e2e4 1f8b4 2e4d5 2e6d5 1e4e5 2d2d4 2g8f6 2g1f3"]\n'
    '[Result "1-0"]\n[Termination "checkmate"]\n\n'
    "1B. e4 1A. d4 1b. d5 1a. e6 2B. Nc3 2b. e6 2A. Nc3 2a. Nf6 3A. e4 3a. Bb4 3B. exd5 3b. exd5 4A. e5\n"
    "4B. d4 4b. Nf6 5B. Nf3 4a. Nd5 {[%clk 0:01:57.8] [%eval 2.60] 2.2s}\n"
    "5b. Be7 {[%clk 0:01:57.7] [%eval 0.09] 2.3s} {B-white sits @2.9s} 6B. Bd3 {[%clk 0:01:58.5] [%eval 0.21] 3.8s}\n"
    "5A. Qg4 {[%clk 0:01:58.4] [%eval #3] 3.8s} {A-black illegal e8e7 @4.0s} 5a. Rg8 {[%clk 0:01:55.7] [%eval -2.75] 5.9s}\n"
    "6b. O-O {[%clk 0:01:55.3] [%eval 3.50] 6.2s} 1-0\n\n"
)
ARENA_OLD = (
    '[Event "Hivemind Arena"]\n[Round "1"]\n[WhiteA "hb-v4"]\n[BlackA "hm-n400"]\n'
    '[WhiteB "hm-n400"]\n[BlackB "hb-v4"]\n[TimeControl "120"]\n'
    '[Opening "1g1f3 1g8f6 2d2d4 1g2g3 2e7e6 2b1c3 1d7d6 1f1g2 2g8f6 2e2e4 2d7d5 2g1f3 1b8c6 1h2h3 2f6e4 2f3e5"]\n'
    '[Result "1-0"]\n[Termination "flag"]\n\n'
    "1a. e7e5 {1.9s 118.1} 1b. f8b4 {2.1s 117.9} 1A. e1g1 {3.7s 118.1} 1B. c1d2 {4.2s 117.9} "
    "2a. f8e7 {5.3s 116.6} 2b. e4d2 {6.3s 115.8} 2A. d2d4 {6.9s 116.5} 2B. d1d2 {8.3s 115.9} "
    "3a. e5d4 {9.4s 114.1} 3b. e8g8 {10.3s 113.8} 3A. P@h6 {11.5s 114.4} 3B. P@h6 {12.3s 113.9}\n"
    "{A-black sits @30.0s} {B-white sits @31.4s} 1-0\n\n"
)


class TestArenaGames(unittest.TestCase):
    """Engine games as a puzzle source: reading both generations, the swing trigger, deduplication."""

    def games(self, text, match="HypeBeast-v5/cap0-b"):
        from bughouse_db.arena import iter_arena_games

        return list(iter_arena_games(io.StringIO(text), match))

    def test_scores_attach_to_their_move_and_events_are_not_moves(self):
        (game,) = self.games(ARENA_NEW)
        self.assertEqual(len(game.moves), 22)
        self.assertEqual(game.moves[16], ("a", "Nd5"))
        self.assertEqual(game.evals[:16], [None] * 16, "the opening carries no scores")
        # Black's 2.60 from White's side is -260 for the mover; White's #3 is a mate for White.
        self.assertEqual(game.evals[16:], [("cp", -260), ("cp", -9), ("cp", 21), ("mate", 3),
                                           ("cp", 275), ("cp", -350)])
        self.assertEqual(game.opening.split()[0], "2e2e4")

    def test_new_files_already_hold_the_opening(self):
        from bughouse_db.arena import full_moves, replay

        (game,) = self.games(ARENA_NEW)
        moves, evals = full_moves(game)
        self.assertEqual(len(moves), len(game.moves), "the opening is not played twice")
        steps = replay(game)
        self.assertEqual([s.san for s in steps[:2]], ["e4", "d4"])
        self.assertEqual(steps[19].san, "Qg4")

    def test_old_files_get_the_opening_from_the_tag(self):
        from bughouse_db.arena import full_moves, replay

        (game,) = self.games(ARENA_OLD, "HypeBeast/v4-vs-hivemind-screen5")
        moves, evals = full_moves(game)
        self.assertEqual(len(moves), 16 + 12)
        self.assertEqual(moves[0], ("A", "g1f3"))
        self.assertEqual(moves[16], ("a", "e7e5"))
        self.assertTrue(all(e is None for e in evals))
        steps = replay(game)
        self.assertEqual(steps[18].san, "O-O", "UCI castling reads as SAN for `played`")
        self.assertEqual(steps[26].san, "P@h6")
        self.assertIn("[BPn]", steps[26].prev, "board B's captures reached board A's hands")
        self.assertIn("[Bn]", steps[26].fen, "the drop spent the pawn")

    def test_names_ids_and_dates(self):
        import re
        from bughouse_db.arena import display_name, read_match

        kinds = {"hb-v4": "hypebeast", "hm-n400": "hivemind"}
        self.assertEqual(display_name("hb-v4", kinds), "HypeBeast")
        self.assertEqual(display_name("hm-n400", kinds), "HiveMind")
        self.assertEqual(display_name("fsf", {"fsf": "fsf"}), "Fairy-Stockfish")
        self.assertEqual(display_name("v7-selfplay-flags-a", {}), "HypeBeast", "a build name is never shown")
        with tempfile.TemporaryDirectory() as tmp:
            match = Path(tmp) / "logs" / "screen5"
            match.mkdir(parents=True)
            (match / "games.bpgn").write_text(ARENA_OLD)
            (match / "manifest.json").write_text(
                '{"sides": {"contender": {"kind": "hypebeast", "name": "hb-v4"},'
                ' "baseline": {"kind": "hivemind", "name": "hm-n400"}},'
                ' "sessions": [{"started": "2026-11-09T21:06:58-0500"}]}')
            (game,) = read_match(match)
        self.assertEqual(game.match, f"{Path(tmp).name}/screen5")
        self.assertEqual(game.date, "2026.11.09")
        self.assertEqual(game.names, {"WhiteA": "HypeBeast", "BlackA": "HiveMind",
                                      "WhiteB": "HiveMind", "BlackB": "HypeBeast"})
        pid = game.puzzle_id("A", 41)
        self.assertRegex(pid, r"^e[0-9a-f]{6}-1-A-41$")
        self.assertRegex(pid, r"^[A-Za-z0-9][\w-]{0,63}$", "the page's id pattern")
        self.assertLess(game.game_no, 2 ** 53)
        self.assertNotEqual(game.game_no, self.games(ARENA_NEW)[0].game_no)
        self.assertIsNone(re.match(r"^\d", pid), "no FICS id starts with a letter")

    def test_a_swing_flags_the_position_after_the_move(self):
        from bughouse_db.arena import swing_flags

        a = "A"
        # White's score falls from +100 to -250 on its next move: the position after that move.
        drop = swing_flags([(a, True, ("cp", 100)), (a, False, ("cp", -100)),
                            (a, True, ("cp", -250)), (a, False, ("cp", 250))])
        self.assertEqual(drop, [False, False, True, False])
        # Black's next score jumps from -100 to +300 after White's move 3: that move is flagged.
        rise = swing_flags([(a, True, ("cp", 100)), (a, False, ("cp", -100)),
                            (a, True, ("cp", 100)), (a, False, ("cp", 300))])
        self.assertEqual(rise, [False, False, True, False])
        # 299 is not enough; the other board's scores never mix in; unrecorded scores are skipped.
        self.assertEqual(swing_flags([(a, True, ("cp", 100)), ("B", True, ("cp", -900)),
                                      (a, False, None), (a, True, ("cp", -199))]), [False] * 4)
        self.assertEqual(swing_flags([(a, True, ("cp", 100)), (a, False, None),
                                      (a, True, ("cp", -200))]), [False, False, True])

    def test_a_mate_is_beyond_any_centipawn_score(self):
        from bughouse_db.arena import swing_flags

        a = "A"
        self.assertEqual(swing_flags([(a, True, ("cp", 2000)), (a, False, None), (a, True, ("mate", -4))]),
                         [False, False, True], "+20 to being mated is a swing")
        self.assertEqual(swing_flags([(a, True, ("mate", 5)), (a, False, None), (a, True, ("mate", 3))]),
                         [False, False, False], "a shorter mate is not a swing")
        self.assertEqual(swing_flags([(a, False, ("cp", -50)), (a, True, None), (a, False, ("mate", 2))]),
                         [False, True, False], "a mate found next flags the move before it")

    def test_flags_say_which_trigger_and_merge_over_games(self):
        from bughouse_db import arena
        from bughouse_db.arena import flag_game, merge, replay

        (game,) = self.games(ARENA_NEW)
        steps = replay(game)
        eligible = [i for i, s in enumerate(steps) if s.eligible]
        self.assertTrue(eligible)
        # Black's score falls from -9 to -350 with 6b. O-O: a swing on board B.
        scores = {s.fen: ("cp", 0) for s in steps if s.eligible}
        with mock.patch.object(arena, "_SCORES", scores):
            quiet = flag_game(game, frozenset({"mate", "advantage"}))
        self.assertTrue(all(c.trigger == "swing" for c in quiet))
        self.assertEqual(quiet, [], "a swing the frozen board does not confirm is not a candidate")
        swung = [i for i, f in enumerate(arena.swing_flags([(s.board, s.white, s.eval) for s in steps]))
                 if f and steps[i].eligible]
        self.assertTrue(swung, "the fixture swings somewhere the scan looks")
        at = swung[0]
        scores[steps[at].fen] = ("cp", 450)
        with mock.patch.object(arena, "_SCORES", scores):
            flagged = flag_game(game, frozenset({"mate", "advantage"}))
        by_ply = {c.ply: c for c in flagged}
        self.assertIn(at, by_ply)
        c = by_ply[at]
        self.assertEqual((c.kind, c.trigger), ("advantage", "both"), "the scan's jump and the swing agree")
        self.assertEqual((c.welo, c.belo, c.tc, c.opening), (0, 0, "120+0", game.opening))
        self.assertEqual(c.played, next((s.san for s in steps[at + 1:] if s.board == c.board), None))
        self.assertTrue(c.pid.startswith("e"))
        twin = arena.P.Candidate(**{**c.__dict__, "trigger": "scan", "kind": "mate", "pid": "other"})
        (merged,) = merge([c, twin])
        self.assertEqual((merged.pid, merged.trigger, merged.kind), (c.pid, "both", "mate"))
        (alone,) = merge([arena.P.Candidate(**{**c.__dict__, "trigger": "swing"}),
                          arena.P.Candidate(**{**c.__dict__, "trigger": "scan"})])
        self.assertEqual(alone.trigger, "both", "a position the scan flagged anywhere is not swing-only")

    def test_the_pre_check_sets_aside_only_positions_with_two_good_moves(self):
        from bughouse_db.arena import precheck_passes, sampled
        from bughouse_db.puzzles import Candidate

        self.assertFalse(precheck_passes(("cp", 900), ("cp", 700)), "two winning moves")
        self.assertTrue(precheck_passes(("cp", 900), ("cp", 0)))
        self.assertTrue(precheck_passes(("cp", 900), None), "one legal move is the verify's call")
        self.assertTrue(precheck_passes(("mate", 1), ("mate", 1)), "mates in one are the verify's call")
        self.assertFalse(precheck_passes(("mate", 3), ("cp", 2500)))
        picks = [sampled(Candidate(fen="", dual="", board="A", ply=i, last=None, played=None, game=1, date="",
                                   tc="", white="", black="", welo=0, belo=0, pid=f"eabcdef-1-A-{i}"))
                 for i in range(2000)]
        self.assertTrue(20 < sum(picks) < 100, "about 3 in 100, fixed by id")

    def test_a_stopped_run_exports_what_it_verified(self):
        import json
        from dataclasses import asdict
        from bughouse_db import arena
        from bughouse_db.puzzles import Candidate

        fen = "r4k1r/ppN2ppp/3Pp3/2Np4/1n1P4/4Pq2/PPPKBb1P/R2Q1Bq1[Nrnp] w - - 4 27"
        base: dict[str, Any] = dict(fen=fen, dual="", board="B", ply=9, last=None, played="Nd7+", game=1,
                    date="2026.11.10", tc="120+0", white="HypeBeast", black="HiveMind", welo=0, belo=0,
                    kind="mate", line=["c5d7", "f8g8", "N@e7"], mates=["N@e7"], pid="eabcdef-1-B-9")
        first = Candidate(**{**base, "reject": "mate: mate not forced"})
        again = Candidate(**base)  # verified again later: the last record wins
        other = Candidate(**{**base, "pid": "eabcdef-2-B-9", "fen": fen.replace("4 27", "4 28"),
                             "reject": "advantage: no clear best move (pre-check)"})
        with tempfile.TemporaryDirectory() as tmp:
            log, out, raw, cands = (Path(tmp) / n for n in ("verify.jsonl", "out", "raw.json", "cands.json"))
            log.write_text("".join(json.dumps(asdict(c)) + "\n" for c in (first, other, again)) + '{"fen": "cut sh')
            cands.write_text(json.dumps([asdict(first), asdict(other), {}]))
            with mock.patch.object(arena, "fics_keys", return_value=set()):
                arena.export_verified(log, out, raw, "3 engine games", cands)
            self.assertEqual([r["pid"] for r in json.loads(raw.read_text())], ["eabcdef-1-B-9"])
            index = json.loads((out / "index.json").read_text())
            self.assertEqual(index["count"], 1)
            self.assertEqual(index["source"], "3 engine games", "the share checked stays out of the players' sentence")
            self.assertEqual(index["puzzles"][0]["id"], "eabcdef-1-B-9")

    def test_source_reads_as_a_player_would_say_it(self):
        from bughouse_db.arena import ArenaGame, source_text

        def game(*names):
            return ArenaGame(match="m", names=dict(zip(("WhiteA", "BlackA", "WhiteB", "BlackB"), names)))

        own = game("HypeBeast", "HypeBeast", "HypeBeast", "HypeBeast")
        other = game("HypeBeast", "HiveMind", "HiveMind", "HypeBeast")
        self.assertEqual(source_text([own] * 1500 + [other]),
                         "1,501 engine games played by HypeBeast, most of them against other builds of itself")
        self.assertEqual(source_text([own] * 3), "3 engine games played by HypeBeast, all against other builds of itself")
        self.assertEqual(source_text([own, other, other]), "3 engine games played by HypeBeast")

    def test_one_puzzle_per_line_per_opening_and_none_from_the_fics_set(self):
        import json
        from bughouse_db import arena
        from bughouse_db.puzzles import Candidate

        def cand(fen, line, opening, pid):
            return Candidate(fen=fen, dual="", board="A", ply=1, last=None, played=None, game=1,
                             date="2026.11.10", tc="120+0", white="HypeBeast", black="HypeBeast",
                             welo=0, belo=0, line=line, opening=opening, pid=pid)

        a = cand("8/8/8/8/8/8/8/K6k[] w - - 0 30", ["a1a2"], "1e2e4", "e1")
        b = cand("8/8/8/8/8/8/8/K5k1[] w - - 0 30", ["a1a2"], "1e2e4", "e2")
        c = cand("8/8/8/8/8/8/8/K5k1[] w - - 0 30", ["a1a2"], "1d2d4", "e3")
        self.assertEqual([x.pid for x in arena.dedupe_lines([a, b, c])], ["e1", "e3"])
        with tempfile.TemporaryDirectory() as tmp:
            web = Path(tmp)
            (web / "s00-0000000000.json").write_text(json.dumps({"puzzles": [{"fen": "8/8/8/8/8/8/8/K6k[] w - - 7 51"}]}))
            self.assertEqual(arena.fics_keys(web), {"8/8/8/8/8/8/8/K6k[] w -"},
                             "move counters do not matter")


if __name__ == "__main__":
    sys.path.insert(0, str(Path(__file__).resolve().parent / "mcp"))
    unittest.main(verbosity=2)
