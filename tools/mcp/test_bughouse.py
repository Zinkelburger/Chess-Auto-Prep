#!/usr/bin/env python3
"""Tests for the bughouse MCP server.

Zero dependencies beyond python-chess (unittest only). The engine-backed tests
are skipped unless a Hivemind build is installed, so the suite runs on a
machine that has never fetched the bundle.

Run:
    python3 tools/mcp/test_bughouse.py
    python3 tools/mcp/test_bughouse.py --engine    # include the slow ones
"""

from __future__ import annotations

import io
import json
import subprocess
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import chess  # noqa: E402

from bughouse import paths  # noqa: E402
from bughouse.board import (  # noqa: E402
    DualBoard,
    IllegalMove,
    board_index,
    parse_move_list,
)
from bughouse.engine import JointMove, HivemindEngine  # noqa: E402
from bughouse.server import Server  # noqa: E402
from bughouse.tools import Registry, ToolError  # noqa: E402

REPO = Path(__file__).resolve().parents[2]
WANT_ENGINE = "--engine" in sys.argv
ENGINE_FILES = paths.locate(required=False)


# ── The rule that makes bughouse bughouse ──────────────────────────────────


class CrossBoardFlow(unittest.TestCase):
    def test_a_capture_feeds_the_other_board_colour_intact(self):
        # 1.e4 d5 2.exd5 on board A: White takes a black pawn.
        dual = DualBoard()
        for move in ("e4", "d5", "exd5"):
            dual.push("A", move)

        # Crazyhouse would have given White a white pawn on this board.
        self.assertEqual(len(dual.boards[0].pockets[chess.WHITE]), 0)
        self.assertEqual(len(dual.boards[0].pockets[chess.BLACK]), 0)
        # Bughouse hands it to the partner on board B, still black.
        self.assertEqual(dual.boards[1].pockets[chess.BLACK].count(chess.PAWN), 1)
        self.assertEqual(len(dual.boards[1].pockets[chess.WHITE]), 0)

    def test_a_capture_on_b_feeds_a(self):
        dual = DualBoard()
        for move in ("d4", "e5", "dxe5"):
            dual.push("B", move)
        self.assertEqual(dual.boards[0].pockets[chess.BLACK].count(chess.PAWN), 1)
        self.assertEqual(len(dual.boards[1].pockets[chess.BLACK]), 0)

    def test_a_captured_promoted_piece_arrives_as_a_pawn(self):
        # White promotes on a8, Black's rook takes the new queen.
        fen = "r3k3/1P6/8/8/8/8/8/4K3[] w - - 0 1"
        dual = DualBoard.from_dual_fen(f"{fen}|{DualBoard().boards[1].fen()}")
        dual.push("A", "b8=Q+")
        dual.push("A", "Rxb8")
        # The queen was a pawn a move ago, and reverts on capture.
        self.assertEqual(dual.boards[1].pockets[chess.WHITE].count(chess.QUEEN), 0)
        self.assertEqual(dual.boards[1].pockets[chess.WHITE].count(chess.PAWN), 1)

    def test_en_passant_routes_the_pawn_it_actually_takes(self):
        fen = "4k3/3p4/8/4P3/8/8/8/4K3[] b - - 0 1"
        dual = DualBoard.from_dual_fen(f"{fen}|4k3/8/8/8/8/8/8/4K3[] w - - 0 1")
        dual.push("A", "d5")
        dual.push("A", "exd6")
        self.assertEqual(dual.boards[1].pockets[chess.BLACK].count(chess.PAWN), 1)

    def test_a_drop_captures_nothing(self):
        dual = DualBoard.from_dual_fen(
            "4k3/8/8/8/8/8/8/4K3[P] w - - 0 1|4k3/8/8/8/8/8/8/4K3[] b - - 0 1"
        )
        dual.push("A", "P@e4")
        self.assertEqual(len(dual.boards[1].pockets[chess.WHITE]), 0)
        self.assertEqual(len(dual.boards[0].pockets[chess.WHITE]), 0)


# ── Reading a position back ────────────────────────────────────────────────


class Reading(unittest.TestCase):
    def test_each_board_keeps_its_own_move_numbers(self):
        dual = DualBoard()
        for which, move in parse_move_list("e4 Nf6 e5 Nd5 B:d4 B:d5 B:c4 B:dxc4"):
            dual.push(which, move)
        self.assertEqual(dual.movetext("A"), "1. e4 Nf6 2. e5 Nd5")
        self.assertEqual(dual.movetext("B"), "1. d4 d5 2. c4 dxc4")

    def test_a_movetext_that_opens_on_black_says_so(self):
        dual = DualBoard.from_dual_fen(
            "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR[] b KQkq - 0 1"
        )
        dual.push("A", "e5")
        self.assertEqual(dual.movetext("A"), "1... e5")

    def test_a_pawn_drop_is_written_with_its_letter(self):
        dual = DualBoard.from_dual_fen(
            "4k3/8/8/8/8/8/8/4K3[P] w - - 0 1|4k3/8/8/8/8/8/8/4K3[] b - - 0 1"
        )
        ply = dual.push("A", "P@e4")
        self.assertEqual(ply.san, "P@e4")
        self.assertEqual(dual.movetext("A"), "1. P@e4")

    def test_our_seat_is_white_on_a_and_black_on_b(self):
        dual = DualBoard()
        self.assertEqual(dual.side_on("A"), chess.WHITE)
        self.assertEqual(dual.side_on("B"), chess.BLACK)
        black = DualBoard(team=chess.BLACK)
        self.assertEqual(black.side_on("A"), chess.BLACK)
        self.assertEqual(black.side_on("B"), chess.WHITE)

    def test_dual_fen_round_trips(self):
        dual = DualBoard()
        dual.push("A", "e4")
        again = DualBoard.from_dual_fen(dual.dual_fen)
        self.assertEqual(again.dual_fen, dual.dual_fen)

    def test_a_single_fen_means_board_b_starts_fresh(self):
        dual = DualBoard.from_dual_fen(DualBoard().boards[0].fen())
        self.assertEqual(dual.boards[1].fen(), DualBoard().boards[1].fen())

    def test_an_illegal_move_names_the_board_and_the_position(self):
        dual = DualBoard()
        with self.assertRaises(IllegalMove) as caught:
            dual.push("A", "e5")
        self.assertIn("board A", str(caught.exception))


class MoveListShapes(unittest.TestCase):
    def test_every_shape_means_the_same_line(self):
        expected = [("A", "e4"), ("B", "d4")]
        for written in (
            "e4 B:d4",
            ["A:e4", "B:d4"],
            [["A", "e4"], ["B", "d4"]],
            [{"board": "A", "move": "e4"}, {"board": "B", "move": "d4"}],
        ):
            self.assertEqual(parse_move_list(written), expected, written)

    def test_boards_can_be_named_however_a_caller_thinks_of_them(self):
        for name in ("A", "a", 1, "1"):
            self.assertEqual(board_index(name), 0)
        for name in ("B", "b", 2, "2"):
            self.assertEqual(board_index(name), 1)
        # 0 is not a board. Accepting it as "the first one" would make the
        # integer form mean two different things depending on the caller.
        for name in ("C", 0, 3):
            with self.assertRaises(ValueError, msg=name):
                board_index(name)


# ── The engine's dialect, parsed without an engine ─────────────────────────


class JointMoves(unittest.TestCase):
    def test_a_joint_move_carries_one_decision_per_board(self):
        move = JointMove.parse("(d2d4,pass)")
        self.assertEqual(move.a, "d2d4")
        self.assertIsNone(move.b)
        self.assertEqual(str(move), "(d2d4,pass)")

    def test_bestmove_none_is_not_a_move(self):
        self.assertIsNone(JointMove.parse("(none)"))
        self.assertIsNone(JointMove.parse("garbage"))

    def test_sitting_on_both_boards_is_empty(self):
        self.assertTrue(JointMove.parse("(pass,pass)").is_empty)

    def test_an_info_line_yields_score_rank_and_variation(self):
        line = HivemindEngine._parse_info(
            "info depth 5 multipv 2 score cp -230 nodes 1844 nps 361 "
            "hashfull 1 tbhits 0 time 5095 pv (d2d4,pass) (d7d5,d2d4)"
        )
        self.assertEqual((line.depth, line.multipv, line.score_cp), (5, 2, -230))
        self.assertEqual((line.nodes, line.nps, line.time_ms), (1844, 361, 5095))
        self.assertEqual(line.score, "-2.30")
        self.assertEqual([str(m) for m in line.pv], ["(d2d4,pass)", "(d7d5,d2d4)"])

    def test_a_mate_score_is_reported_as_a_mate(self):
        line = HivemindEngine._parse_info("info depth 3 score mate 2 nodes 9 pv (a1a8,pass)")
        self.assertEqual(line.mate, 2)
        self.assertEqual(line.score, "#2")

    def test_an_empty_line_is_dropped(self):
        self.assertIsNone(HivemindEngine._parse_info("info depth 0 score cp 0 nodes 0"))

    def test_only_the_last_state_of_each_rank_survives(self):
        result = HivemindEngine._collect(
            [
                "info depth 3 multipv 1 score cp -240 nodes 10 pv (e2e4,pass)",
                "info depth 5 multipv 1 score cp -230 nodes 90 pv (d2d4,pass)",
                "info depth 5 multipv 2 score cp -234 nodes 90 pv (e2e4,pass)",
                "bestmove (d2d4,pass) ponder (d7d5,d2d4)",
            ]
        )
        self.assertEqual([line.multipv for line in result.lines], [1, 2])
        self.assertEqual(result.top.score_cp, -230)
        self.assertEqual(str(result.best), "(d2d4,pass)")


# ── Tools, without touching the engine ─────────────────────────────────────


class EngineFreeTools(unittest.TestCase):
    def setUp(self):
        self.registry = Registry()

    def test_position_reports_both_boards_and_where_the_piece_went(self):
        out = self.registry.call("position", {"moves": "e4 Nf6 e5 Nd5 B:d4 B:d5 B:c4 B:dxc4"})
        self.assertEqual(out["boards"]["A"]["movetext"], "1. e4 Nf6 2. e5 Nd5")
        self.assertEqual(out["boards"]["B"]["movetext"], "1. d4 d5 2. c4 dxc4")
        # Black took a white pawn on B, so we hold a white pawn on A.
        self.assertEqual(out["boards"]["A"]["pockets"]["white"], "p")
        self.assertTrue(out["boards"]["A"]["our_turn"])

    def test_legal_moves_can_be_narrowed_to_drops(self):
        line = "e4 Nf6 e5 Nd5 B:d4 B:d5 B:c4 B:dxc4"
        drops = self.registry.call("legal_moves", {"moves": line, "drops_only": True})
        self.assertTrue(drops["moves"])
        self.assertTrue(all(m.startswith("P@") for m in drops["moves"]), drops["moves"])
        every = self.registry.call("legal_moves", {"moves": line})
        self.assertGreater(every["count"], drops["count"])

    def test_a_bad_move_is_a_tool_error_not_a_crash(self):
        with self.assertRaises(ToolError) as caught:
            self.registry.call("position", {"moves": "e4 e4"})
        self.assertIn("board A", str(caught.exception))

    def test_compare_refuses_an_empty_candidate_list(self):
        with self.assertRaises(ToolError):
            self.registry.call("compare", {"candidates": []})

    def test_unknown_tool(self):
        with self.assertRaises(ToolError):
            self.registry.call("nope", {})

    def test_every_tool_declares_a_description_and_a_schema(self):
        for tool in self.registry.definitions():
            self.assertTrue(tool["description"].strip(), tool["name"])
            self.assertEqual(tool["inputSchema"]["type"], "object", tool["name"])


class Wire(unittest.TestCase):
    """The transport, driven the way an MCP client drives it."""

    @staticmethod
    def _exchange(requests: list[dict]) -> dict[int, dict]:
        stdin = io.StringIO("".join(json.dumps(r) + "\n" for r in requests))
        stdout = io.StringIO()
        Server(stdin=stdin, stdout=stdout).serve_forever()
        replies = {}
        for line in stdout.getvalue().splitlines():
            message = json.loads(line)
            replies[message.get("id")] = message
        return replies

    def test_initialize_names_the_server(self):
        reply = self._exchange(
            [{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}}]
        )[1]
        self.assertEqual(reply["result"]["serverInfo"]["name"], "bughouse")

    def test_tools_list_and_call(self):
        replies = self._exchange(
            [
                {"jsonrpc": "2.0", "id": 1, "method": "tools/list"},
                {
                    "jsonrpc": "2.0",
                    "id": 2,
                    "method": "tools/call",
                    "params": {"name": "position", "arguments": {"moves": "e4"}},
                },
            ]
        )
        names = {t["name"] for t in replies[1]["result"]["tools"]}
        self.assertEqual(
            names, {"status", "position", "legal_moves", "analyse", "compare", "playout"}
        )
        payload = json.loads(replies[2]["result"]["content"][0]["text"])
        self.assertEqual(payload["boards"]["A"]["movetext"], "1. e4")

    def test_a_tool_error_comes_back_as_readable_content(self):
        reply = self._exchange(
            [
                {
                    "jsonrpc": "2.0",
                    "id": 1,
                    "method": "tools/call",
                    "params": {"name": "position", "arguments": {"moves": "Ke2"}},
                }
            ]
        )[1]
        self.assertTrue(reply["result"]["isError"])
        self.assertIn("Error:", reply["result"]["content"][0]["text"])

    def test_the_server_starts_from_a_bare_command_line(self):
        """What `.mcp.json` actually does — no PYTHONPATH, no install."""
        proc = subprocess.run(
            [sys.executable, "tools/mcp/bughouse/__main__.py"],
            input=json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/list"}) + "\n",
            capture_output=True,
            text=True,
            timeout=120,
            cwd=REPO,
        )
        reply = json.loads(proc.stdout.splitlines()[0])
        self.assertIn("tools", reply["result"], proc.stderr)


# ── With the real engine ───────────────────────────────────────────────────


@unittest.skipUnless(
    ENGINE_FILES is not None and WANT_ENGINE,
    "needs a Hivemind build and --engine",
)
class WithEngine(unittest.TestCase):
    registry: Registry

    @classmethod
    def setUpClass(cls):
        cls.registry = Registry()

    @classmethod
    def tearDownClass(cls):
        from bughouse.engine import close_shared

        close_shared()

    def test_status_reports_a_running_backend(self):
        out = self.registry.call("status", {})
        self.assertTrue(out["running"])
        self.assertTrue(out["backend"])

    def test_analyse_returns_a_joint_move_and_a_shortlist(self):
        out = self.registry.call(
            "analyse", {"nodes": 400, "multipv": 3, "require_move_on": "A"}
        )
        self.assertIsNotNone(out["best"])
        self.assertNotEqual(out["best"]["A"], "sit")
        # Board B is not ours to move at the start, so the only honest half
        # there is a pass.
        self.assertEqual(out["best"]["B"], "sit")
        self.assertGreaterEqual(len(out["lines"]), 2)

    def test_compare_ranks_winning_a_piece_over_losing_the_queen(self):
        # After 1.e4 Nf6 2.e5 d5?? (the pawn, not the knight) White can just
        # take the knight; 3.Qh5?? drops the queen to 3...Nxh5. Two moves that
        # far apart must come out in that order at any budget.
        out = self.registry.call(
            "compare",
            {
                "moves": ["e4", "Nf6", "e5", "d5"],
                "candidates": ["exf6", "Qh5"],
                "nodes": 1500,
            },
        )
        self.assertEqual([r["move"] for r in out["ranked"]], ["exf6", "Qh5"])
        self.assertEqual(out["best"], "exf6")

    def test_playout_moves_the_position_on(self):
        out = self.registry.call("playout", {"plies": 2, "nodes": 300})
        self.assertEqual(len(out["plies"]), 2)
        self.assertNotEqual(
            out["final"]["dual_fen"], DualBoard().dual_fen, "nothing was played"
        )


if __name__ == "__main__":
    sys.argv = [a for a in sys.argv if a != "--engine"]
    unittest.main(verbosity=2)
