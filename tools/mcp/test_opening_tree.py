#!/usr/bin/env python3
"""Tests for the PGN opening-tree MCP tools (FEN-keyed, transpositions).

Requires python-chess (see tools/mcp/requirements.txt).

    python tools/mcp/test_opening_tree.py
"""

from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from chess_prep.opening import OpeningGraph, fen4, parse_move_list
from chess_prep.tools import Registry, ToolError

TRANSPOSE_PGN = """
[Event "Order A"]
[White "Book"]
[Black "Line A"]
[Result "*"]

1. d4 Nf6 2. e3 c5 *

[Event "Order A with a White reply"]
[White "Book"]
[Black "Line A2"]
[Result "*"]

1. d4 Nf6 2. e3 c5 3. c3 *
"""

COLLE_SNIPPET = """
[Event "Anti-Benoni"]
[White "19) The Anti-Benoni"]
[Black "2...c5"]
[Result "*"]

1. d4 Nf6 2. Nf3 c5 3. e3 e6 4. Bd3 *
"""


def _write(pgn: str) -> Path:
    tmp = tempfile.NamedTemporaryFile("w", suffix=".pgn", delete=False, encoding="utf-8")
    tmp.write(pgn)
    tmp.close()
    return Path(tmp.name)


class ParseMoves(unittest.TestCase):
    def test_movetext_and_list(self):
        self.assertEqual(parse_move_list("1. d4 Nf6 2. c4 c5"), ["d4", "Nf6", "c4", "c5"])
        self.assertEqual(parse_move_list(["d4", "Nf6"]), ["d4", "Nf6"])


class TranspositionGraph(unittest.TestCase):
    def setUp(self):
        self.path = _write(TRANSPOSE_PGN)
        self.graph = OpeningGraph(str(self.path))
        self.graph.load(self.path.read_text(encoding="utf-8"))

    def tearDown(self):
        self.path.unlink(missing_ok=True)

    def test_same_fen_either_move_order(self):
        a, _ = self.graph.play(["d4", "Nf6", "e3", "c5"])
        b, _ = self.graph.play(["d4", "c5", "e3", "Nf6"])
        self.assertEqual(fen4(a), fen4(b))
        self.assertTrue(self.graph.query(a, [])["in_book"])
        self.assertTrue(self.graph.query(b, [])["in_book"])

    def test_off_book_parent_lists_transposing_nf6(self):
        board, played = self.graph.play(["d4", "c5", "e3"])
        q = self.graph.query(board, played)
        self.assertFalse(q["in_book"])
        sans = [m["san"] for m in q["transposing_moves"]]
        self.assertIn("Nf6", sans)
        nf6 = next(m for m in q["transposing_moves"] if m["san"] == "Nf6")
        self.assertTrue(nf6["via_transposition"])
        self.assertEqual(nf6["transposes_to"], ["d4", "Nf6", "e3", "c5"])

    def test_book_replies_after_transposed_arrival(self):
        board, played = self.graph.play(["d4", "c5", "e3", "Nf6"])
        q = self.graph.query(board, played)
        self.assertTrue(q["in_book"])
        self.assertEqual([m["san"] for m in q["moves"]], ["c3"])

    def test_walk_flags_the_transposition(self):
        walked = self.graph.walk(["d4", "c5", "e3", "Nf6"])
        self.assertTrue(walked["in_book_at_end"])
        nf6 = next(p for p in walked["plies"] if p["san"] == "Nf6")
        self.assertTrue(nf6["via_transposition"])
        self.assertFalse(nf6["played_from_this_move_order"])
        self.assertIn("c3", nf6["book_replies"])


class RegistryTools(unittest.TestCase):
    def setUp(self):
        self.registry = Registry()
        self.path = _write(TRANSPOSE_PGN)

    def tearDown(self):
        self.path.unlink(missing_ok=True)

    def test_pgn_open_and_position(self):
        opened = self.registry.call("pgn_open", {"path": str(self.path)})
        self.assertEqual(opened["games"], 2)
        self.assertGreater(opened["positions"], 4)
        pos = self.registry.call(
            "pgn_position",
            {"path": str(self.path), "moves": "1. d4 c5 2. e3"},
        )
        self.assertFalse(pos["in_book"])
        self.assertIn("Nf6", [m["san"] for m in pos["transposing_moves"]])

    def test_pgn_walk(self):
        self.registry.call("pgn_open", {"path": str(self.path)})
        walked = self.registry.call(
            "pgn_walk",
            {"path": str(self.path), "moves": ["d4", "c5", "e3", "Nf6"]},
        )
        self.assertTrue(walked["in_book_at_end"])

    def test_missing_file(self):
        with self.assertRaises(ToolError):
            self.registry.call("pgn_open", {"path": "/no/such/file.pgn"})


class DummyMainline(unittest.TestCase):
    def test_chessable_z0_intro_is_promoted(self):
        pgn = (
            '[Event "?"]\n[White "Introduction"]\n[Black "Introduction"]\n'
            '[Result "*"]\n\n'
            "1. Z0 ({Welcome} 1. d4 {we play} Z0 2. Nf3) *\n"
        )
        path = _write(pgn)
        try:
            g = OpeningGraph(str(path))
            g.load(path.read_text(encoding="utf-8"))
            board, _ = g.play(["d4"])
            self.assertTrue(g.query(board, ["d4"])["in_book"])
        finally:
            path.unlink(missing_ok=True)


class ColleSnippet(unittest.TestCase):
    def test_nf6_c5_is_anti_benoni_not_colle_with_c4(self):
        path = _write(COLLE_SNIPPET)
        try:
            g = OpeningGraph(str(path))
            g.load(path.read_text(encoding="utf-8"))
            walked = g.walk(["d4", "Nf6", "c4"])
            c4 = next(p for p in walked["plies"] if p["san"] == "c4")
            self.assertFalse(c4["in_book"])
            walked2 = g.walk(["d4", "Nf6", "Nf3", "c5"])
            self.assertTrue(walked2["in_book_at_end"])
            self.assertIn("e3", walked2["plies"][-1]["book_replies"])
        finally:
            path.unlink(missing_ok=True)


if __name__ == "__main__":
    unittest.main()
