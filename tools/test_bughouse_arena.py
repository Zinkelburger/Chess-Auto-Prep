#!/usr/bin/env python3
"""Tests for the bughouse arena (tools/bughouse_arena).

Offline and unittest-only beyond python-chess. The referee cases are ported
one-for-one from Hivemind's engine/tests/test_mate_detection.cc, so a change to
the engine's mate rule that is not mirrored here fails loudly. Protocol tests
for the hivemind/hypebeast/fsf kinds run against a scripted fake UCI engine
(FAKE_ENGINE below), so no engine build is needed. The real-engine checks need
``--engine`` and a Hivemind build and/or ``$HYPEBEAST_HOME/bin/fsf-ref``.

Run:
    python3 tools/test_bughouse_arena.py
    python3 tools/test_bughouse_arena.py --engine    # include the slow ones
"""

from __future__ import annotations

import hashlib
import io
import json
import os
import random
import re
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

import chess
from chess.variant import CrazyhouseBoard

sys.path.insert(0, str(Path(__file__).resolve().parent))

from bughouse_arena import openings as opening_sets  # noqa: E402
from bughouse_arena import preflight  # noqa: E402
from bughouse_arena.match import (MatchConfig, PlayerFactory, _clock_tag, game_plan,  # noqa: E402
                                  load_openings, run_match,
                                  write_bpgn)
from bughouse_arena.players import (FSF_LABEL, EngineError, EngineSpec, FsfSeat,  # noqa: E402
                                    HivemindSeat, RandomPlayer, TeamEngineSeat, fsf_fen,
                                    hypebeast_home,
                                    _last_score)
from bughouse_arena.referee import (BOARD_A, BOARD_B, STARTING_FEN, Bughouse,  # noqa: E402
                                    IllegalMove)
from bughouse_arena.sim import (ClockConfig, MoveCosts, SeatView, play_game,  # noqa: E402
                                seat_index, time_advantage)
from bughouse_arena.stats import (pair_interval, paired_sprt, score_to_elo,  # noqa: E402
                                  summarize)

WANT_ENGINE = "--engine" in sys.argv

W, B = chess.WHITE, chess.BLACK
A_WHITE, A_BLACK, B_WHITE, B_BLACK = range(4)
FIXED = ClockConfig(initial_ms=120_000, move_cost_ms=(2_000, 2_000), react_cost_ms=500)

START = STARTING_FEN
SCHOLAR = "r1bqkb1r/pppp1Qpp/2n2n2/4p3/2B1P3/8/PPPP1PPP/RNB1K1NR b KQkq - 0 4"
BARE_KINGS_W = "4k3/8/8/8/8/8/8/4K3 w - - 0 1"
BUG_REPORT_A = "5k1R/pppbrp2/2p1pQ2/8/2B1P3/2PN4/PPP3K1/8[RB] b - - 4 31"
BUG_REPORT_B = ("r6r/pppk1Ppp/2n1q3/3n2N1/8/2P5/P1P1NPPP/R1B1K2R"
                "[QBNPPPPqrbbbnnppppp] w KQ - 0 18")
KNIGHT_DROP_DUAL = (
    "3q1r1k/1p4b1/p1r2p1p/3p1b1n/1npP1pB1/N1N1Q2P/PPP2PP1/1R3KR1[BPp] w - - 0 1|"
    "5r1k/1p2q1b1/p1r2p1p/3p1b1n/1npP1pB1/N1N4P/PPPQ1PP1/1R3KR1[BPp] w - - 0 1")


def play(game: Bughouse, tokens: str) -> Bughouse:
    for token in tokens.split():
        game.push(int(token[0]) - 1, token[1:])
    return game


# (name, board A, board B, moves, team, time advantage, mated)
MATE_CASES = [
    ("BackRankMate", SCHOLAR, BARE_KINGS_W, "", B, False, True),
    ("ScholarsMate", SCHOLAR, START, "", B, False, True),
    ("SimpleRookMate", "6Qk/5K2/8/8/8/8/8/8 b - - 0 1", BARE_KINGS_W, "", B, False, True),
    ("NotMatePartnerCanProvideBlocker", "4k3/8/8/8/8/8/8/4Q2K b - - 0 1",
     "4k3/4p3/8/8/8/8/8/4Q2K w - - 0 1", "", B, False, False),
    ("PartnerCanCaptureToProvideBlocker", "4k3/pppppppp/8/8/8/8/8/4R2K b - - 0 1",
     "4k3/8/8/3n4/8/8/8/4R2K w - - 0 1", "", B, False, False),
    ("DoubleCheckIsMate", "r4Qrk/5Npp/8/8/8/8/8/4K3 b - - 0 1",
     "4k3/8/8/8/8/8/3q4/4K3 w - - 0 1", "", B, False, True),
    ("PawnCantBlockOnBackRank", "4k3/8/8/8/8/8/8/4R2K b - - 0 1",
     "4k3/8/8/8/8/8/4p3/4R2K w - - 0 1", "", B, False, False),
    ("TimeAdvantageAllowsFutureCapture/no-advantage", SCHOLAR,
     "4k3/8/8/8/3n4/8/8/4K2R b - - 0 1", "", B, False, True),
    ("TimeAdvantageAllowsFutureCapture/advantage", SCHOLAR,
     "4k3/8/8/8/3n4/8/8/4K2R b - - 0 1", "", B, True, True),
    ("TimeAdvantageButNoPieces", SCHOLAR, BARE_KINGS_W, "", B, True, True),
    ("StalemateIsNotCheckmate", "k7/8/1Q6/8/8/8/8/1K6 b - - 0 1", START, "", B, False, False),
    ("TwoActiveStalematesLose/no-advantage", "k7/8/1Q6/8/8/8/8/1K6 b - - 0 1",
     "8/8/8/8/8/1q6/2k5/K7 w - - 0 1", "", B, False, True),
    ("TwoActiveStalematesLose/advantage", "k7/8/1Q6/8/8/8/8/1K6 b - - 0 1",
     "8/8/8/8/8/1q6/2k5/K7 w - - 0 1", "", B, True, True),
    ("InCheckButHasEscape", "4k3/8/8/8/8/8/8/4R2K b - - 0 1", START, "", B, False, False),
    ("KingCanCaptureChecker", "4k3/8/8/8/8/8/4r3/4K3 w - - 0 1", START, "", W, False, False),
    ("OwnPieceCanBlock", "4k3/8/8/8/8/8/3N4/R3K3 b - - 0 1", START, "", B, False, False),
    ("CheckmateOnBoardB", START, SCHOLAR, "", W, False, True),
    ("BughousePositionFromBugReport", BUG_REPORT_A, BUG_REPORT_B, "", B, False, False),
    ("CheckmateAfterNonBlockingPartnerMove", BUG_REPORT_A, BUG_REPORT_B, "2N@c5", B, False, True),
    ("RookDropBackRankMate", "6k1/pppbrp2/2p1pQ2/8/2B1P3/2PN4/PPP3K1/8[R] w - - 0 1",
     "r6r/pppk1Ppp/2n1q3/2Nn4/8/2P5/P1P1NPPP/R1B1K2R[QBNPPPPrbbbnnppppp] b KQ - 0 1",
     "1R@h8", B, False, True),
    ("VerifyCaptureProvidesPiece", "4k3/pppppppp/8/8/8/8/8/4R2K b - - 0 1",
     "4k3/8/8/8/8/8/8/q3R2K w - - 0 1", "", B, False, False),
    ("NoBlockingCapturesIsMate", SCHOLAR, "4k3/8/4q3/8/8/8/8/4K2R w - - 0 1", "", B, False, True),
    ("NoTurnIsNotCheckmate/black", "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 1",
     "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1", "", B, True, False),
    ("NoTurnIsNotCheckmate/white", "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 1",
     "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1", "", W, True, False),
]


class RefereeMateRule(unittest.TestCase):
    """Ported from Hivemind's engine/tests/test_mate_detection.cc."""

    def test_cases(self):
        for name, fen_a, fen_b, moves, team, advantage, mated in MATE_CASES:
            with self.subTest(name):
                game = play(Bughouse(fen_a, fen_b), moves)
                self.assertIs(game.is_checkmate(team, advantage), mated)

    def test_only_back_rank_blocking_square_is_mate(self):
        game = Bughouse("Q6k/8/8/8/8/8/8/7K b - - 0 1", "4k3/8/8/8/8/8/4p3/4K2R w - - 0 1")
        if not game.legal_moves(BOARD_A):
            self.assertTrue(game.is_checkmate(B, False))

    def test_adjacent_check_cannot_be_blocked(self):
        game = Bughouse("4k3/3P4/8/8/8/8/8/4K3 b - - 0 1", "4k3/8/8/8/3q4/8/8/4K3 w - - 0 1")
        if not game.legal_moves(BOARD_A):
            self.assertTrue(game.is_checkmate(B, False))

    def test_reported_king_move_allows_queen_drop_mate(self):
        game = Bughouse.from_dual_fen(
            "r4r2/ppp2pkp/5B2/3pP1p1/8/2P5/PPP2bPP/RN1rNK1R[QBBPbpp] b - - 1 27|"
            "rnb3k1/ppp1qqpp/2P1pnbQ/1B2N3/8/2P2N2/P1P2PPP/R3K2R[Pnnp] w KQ - 0 24")
        play(game, "1g7g8 1Q@g7")
        self.assertTrue(game.boards[BOARD_A].is_check())
        self.assertFalse(game.legal_moves(BOARD_A))
        self.assertTrue(game.is_checkmate(B, False) and game.is_checkmate(B, True))

    def test_reported_knight_drop_is_immediate_mate(self):
        game = play(Bughouse.from_dual_fen(KNIGHT_DROP_DUAL), "2g4f5 1g4h5 1f4e3 1f2e3 2N@h2")
        self.assertTrue(game.is_checkmate(B, False) and game.is_checkmate(B, True))

    def test_g4h5_leaves_unavoidable_knight_drop_mate(self):
        game = play(Bughouse.from_dual_fen(KNIGHT_DROP_DUAL), "2g4h5 1g4h5")
        replies = game.legal_moves(BOARD_A)
        self.assertTrue(replies)
        for reply in replies:
            with self.subTest(reply):
                future = game.copy()
                future.push(BOARD_A, reply)
                future.push(BOARD_B, "N@h2")
                self.assertTrue(future.is_checkmate(B, False))

    def test_queen_drop_d2_mate_after_long_transfer_sequence(self):
        """97 moves of drops and captures: the pockets only line up if every
        capture went to the right partner, demoted promotions included."""
        game = play(Bughouse(), (
            "1e2e4 1e7e5 1g1f3 1b8c6 1f1c4 2e2e4 2c7c6 2b1c3 2d7d5 2e4d5 "
            "1P@e6 1d2d4 1e5d4 1c1g5 1f8e7 1g5e7 1d8e7 1e4e5 1d7d6 2c6d5 "
            "1P@f6 1g8f6 1e5f6 1g7f6 1e1g1 2d2d4 2g8f6 2g1f3 2b8c6 2f1b5 "
            "2c8g4 2P@a6 2d8c7 2a6b7 2c7b7 2P@a6 2b7c7 2b5c6 1N@f4 1P@g3 "
            "2c7c6 2B@b5 2g4f3 2d1f3 1B@h3 1N@g7 1e8d8 1B@h1 1h3g2 1h1g2 "
            "2c6b5 2c3b5 2B@d6 2b5d6 1B@h3 1B@h1 1h3g2 1h1g2 1Q@h3 2e7d6 "
            "2P@b7 2a8d8 2b7b8q 2d8b8 2P@c7 2b8c8 2B@a4 2B@d7 2a4d7 2f6d7 "
            "1B@h1 1f4g2 1h1g2 1h3g2 1g1g2 1B@g4 1h2h3 1g4h3 1g2h3 1P@g4 "
            "1h3g4 1h7h5 1g4h3 2f3d5 2c8c7 2d5a8 2B@d8 2B@g5 2B@f6 2g5f6 "
            "1B@g4 1h3h2 1g4f3 1d1f3 2d7f6 2B@b5 2P@d7 2c1g5 2f8e7 2g5f6 "
            "1N@g4 1h2g2 1c6e5 1g7e6 1c8e6 2e7f6 2N@d5 2B@d2 2e1d2 2N@e4 2d2d1"))
        self.assertTrue(game.is_legal(BOARD_B, "Q@d2"))
        opponent_team = game.turn(BOARD_B)  # the mover's team plays the other colour on B
        game.push(BOARD_B, "Q@d2")
        self.assertTrue(game.boards[BOARD_B].is_check())
        self.assertFalse(game.legal_moves(BOARD_B))
        self.assertTrue(game.is_checkmate(opponent_team, False))
        self.assertTrue(game.is_checkmate(opponent_team, True))

    def test_queen_drop_e8_with_slash_pockets(self):
        game = Bughouse.from_dual_fen(
            "r1bk1b1r/ppp1p1pp/8/6Nn/B7/2Nn4/PP1B1PPP/5K1R/PPNBRQpbbbq w - - 0 2|"
            "r2qr1k1/p1p1ppP1/2p3nQ/3p2Pp/3P3n/2N1PP2/PPPp3P/R2K2R1/pP w - - 1 2")
        game.push(BOARD_A, "Q@e8")
        self.assertTrue(game.is_checkmate(B, False) and game.is_checkmate(B, True))


class RefereeTransfers(unittest.TestCase):
    def test_capture_goes_to_partner_not_capturer(self):
        game = play(Bughouse(), "1e2e4 1d7d5 1e4d5")
        self.assertEqual(game.boards[BOARD_A].pockets[W].count(chess.PAWN), 0)
        # White captured on A, so black on B (white's partner) receives the pawn.
        self.assertEqual(game.boards[BOARD_B].pockets[B].count(chess.PAWN), 1)
        self.assertEqual(game.boards[BOARD_B].pockets[W].count(chess.PAWN), 0)

    def test_captured_promoted_piece_goes_back_as_pawn(self):
        game = play(Bughouse("1r5k/P7/8/8/8/8/8/K7[] w - - 0 1", BARE_KINGS_W), "1a7a8q 1b8a8")
        # Black captured a promoted queen: its partner (white on B) gets a pawn.
        self.assertEqual(game.boards[BOARD_B].pockets[W].count(chess.PAWN), 1)
        self.assertEqual(game.boards[BOARD_B].pockets[W].count(chess.QUEEN), 0)

    def test_en_passant_capture_sends_a_pawn(self):
        game = play(Bughouse(), "1e2e4 1a7a6 1e4e5 1d7d5 1e5d6")
        self.assertEqual(game.boards[BOARD_B].pockets[B].count(chess.PAWN), 1)

    def test_illegal_move_is_rejected(self):
        game = Bughouse()
        with self.assertRaises(IllegalMove):
            game.push(BOARD_A, "e2e5")
        with self.assertRaises(IllegalMove):
            game.push(BOARD_B, "P@e4")

    def test_engine_move_tokens(self):
        self.assertEqual(play(Bughouse(), "1e2e4 2d2d4").engine_moves(), ["1e2e4", "2d2d4"])

    def test_threefold_on_board_position_is_a_draw(self):
        game = Bughouse()
        for _ in range(2):
            play(game, "1g1f3 1g8f6 1f3g1 1f6g8")
        self.assertTrue(game.is_draw())

    def test_repetition_ignores_pockets(self):
        game = play(Bughouse(), "2e2e4 2d7d5 2e4d5")  # board A's black pocket gains a pawn
        play(game, "1g1f3 1g8f6 1f3g1 1f6g8 1g1f3 1g8f6 1f3g1 1f6g8")
        self.assertTrue(game.is_draw())


class Scripted:
    """Sits while ``sit(view)`` is true, otherwise plays the first legal move."""

    def __init__(self, sit=lambda view: False):
        self.sit = sit
        self.name = "scripted"
        self.calls = []

    def new_game(self, board, color):
        pass

    def decide(self, view):
        self.calls.append((view.now_ms, view.time_advantage, view.sitting))
        moves = sorted(view.game.legal_moves(view.board))
        if not moves or self.sit(view):
            return None
        return moves[0]


def seats(**overrides):
    players = {index: Scripted() for index in range(4)}
    names = {"aw": A_WHITE, "ab": A_BLACK, "bw": B_WHITE, "bb": B_BLACK}
    players.update({names[key]: value for key, value in overrides.items()})
    return players


def moves_of(result):
    return [(e["t"], e["seat"], e["uci"]) for e in result.events if e["kind"] == "move"]


class VirtualTime(unittest.TestCase):
    def test_both_boards_move_concurrently_and_charge_only_the_mover(self):
        result = play_game(Bughouse(), seats(), FIXED, max_decisions=4)
        self.assertEqual([(t, seat) for t, seat, _ in moves_of(result)[:4]], [
            (2000, "A-white"), (2000, "B-white"), (4000, "A-black"), (4000, "B-black")])
        event = [e for e in result.events if e["kind"] == "move"][3]
        self.assertEqual(event["clocks"], [118_000] * 4)

    def test_sitting_burns_only_the_sitters_clock_until_it_flags(self):
        # Board B makes one move and then stalls too, so B-black's clock (running
        # since 2000) would only run out at 122000: A-white flags first.
        players = seats(aw=Scripted(sit=lambda v: True),
                        bw=Scripted(sit=lambda v: v.now_ms > 2_000),
                        bb=Scripted(sit=lambda v: True))
        result = play_game(Bughouse(), players, FIXED)
        self.assertEqual(result.termination, "flag")
        self.assertEqual(result.winner, B)          # A-white belongs to team white
        self.assertEqual(result.duration_ms, 120_000)
        self.assertEqual(result.clocks_ms[A_WHITE], 0)
        # Team white is A-white (sat 2000..120000) and B-black (sat 4000..120000).
        self.assertEqual(result.sit_ms[W], (120_000 - 2_000) + (120_000 - 4_000))

    def test_sitter_wakes_react_cost_after_the_other_board_moves(self):
        sitter = Scripted(sit=lambda view: view.now_ms < 2_500)
        result = play_game(Bughouse(), seats(aw=sitter), FIXED, max_decisions=6)
        # Sits at 2000 (end of its first think); B-white moves at 2000, so A-white
        # is asked again at 2500 and plays then.
        self.assertEqual([t for t, _, _ in sitter.calls[:2]], [2000, 2500])
        self.assertIn((2500, "A-white"), [(t, s) for t, s, _ in moves_of(result)])

    def test_sitter_is_not_asked_again_while_nothing_changes(self):
        sitter, other = Scripted(sit=lambda view: True), Scripted(sit=lambda view: True)
        play_game(Bughouse(), seats(aw=sitter, bw=other), FIXED)
        self.assertEqual((len(sitter.calls), len(other.calls)), (1, 1))

    def test_time_advantage_uses_board_a_seat_versus_diagonal(self):
        clocks = [100, 50, 80, 60]
        self.assertTrue(time_advantage(clocks, W))    # A-white 100 > B-white 80
        self.assertFalse(time_advantage(clocks, B))   # A-black 50 < B-black 60

    def test_advantage_flip_is_scheduled(self):
        # A-black sits for good; after B-black moves at 4000, B-white burns while
        # A-white (waiting on A-black) does not, so team white goes ahead at 4001.
        result = play_game(Bughouse(), seats(ab=Scripted(sit=lambda v: True)), FIXED,
                           max_decisions=12)
        flips = [e for e in result.events if e["kind"] == "flip"]
        self.assertTrue(flips)
        self.assertEqual((flips[0]["t"], flips[0]["team"], flips[0]["advantage"]),
                         (4001, "white", True))

    def test_checkmate_ends_the_game_at_the_mating_move(self):
        game = Bughouse("r1bqkb1r/pppp1ppp/2n2n2/4p2Q/2B1P3/8/PPPP1PPP/RNB1K1NR w KQkq - 4 4")

        class Mater(Scripted):
            def decide(self, view):
                return "h5f7"

        result = play_game(game, seats(aw=Mater()), FIXED)
        self.assertEqual((result.termination, result.winner, result.duration_ms),
                         ("checkmate", W, 2000))

    def test_illegal_move_forfeits(self):
        class Cheater(Scripted):
            def decide(self, view):
                return "e2e5"

        result = play_game(Bughouse(), seats(bw=Cheater()), FIXED)
        self.assertEqual((result.termination, result.winner), ("illegal move", W))

    def test_costs_are_reproducible_per_seat_and_move(self):
        config = ClockConfig(move_cost_ms=(1_500, 2_500))
        a, b = MoveCosts(config, "1:7"), MoveCosts(config, "1:7")
        samples = [a.sample(seat, n) for seat in range(4) for n in range(20)]
        self.assertEqual(samples, [b.sample(seat, n) for seat in range(4) for n in range(20)])
        self.assertTrue(all(1_500 <= s <= 2_500 for s in samples))
        self.assertGreater(len(set(samples)), 10)

    def test_random_games_always_terminate(self):
        for seed in range(20):
            players = {i: RandomPlayer(seed * 4 + i, sit_probability=0.3) for i in range(4)}
            result = play_game(Bughouse(), players, ClockConfig(initial_ms=30_000))
            self.assertIn(result.termination, {"checkmate", "flag", "draw"})
            self.assertLessEqual(result.duration_ms, 2 * 30_000)

    def test_seat_index_layout(self):
        self.assertEqual((seat_index(BOARD_A, W), seat_index(BOARD_B, B)), (A_WHITE, B_BLACK))


class EngineProtocol(unittest.TestCase):
    def test_parse_joint_bestmove(self):
        for line, board, expected in [
            ("bestmove (e2e4,pass) ponder (d7d5,d2d4)", BOARD_A, "e2e4"),
            ("bestmove (e2e4,pass)", BOARD_B, None),
            ("bestmove (pass,P@e5)", BOARD_B, "P@e5"),
            ("bestmove (none)", BOARD_A, None),
        ]:
            with self.subTest(line):
                self.assertEqual(HivemindSeat.parse_bestmove(line, board), expected)

    def test_spec_with_explicit_files_needs_no_bundle(self):
        spec = EngineSpec.parse("bin=/x/hm,model=/x/net.onnx,lib=/x,nodes=50,Hash=64,name=t")
        self.assertEqual((spec.binary, spec.model, spec.library_dir), (Path("/x/hm"),
                         Path("/x/net.onnx"), Path("/x")))
        self.assertEqual((spec.nodes, spec.name, spec.options), (50, "t", {"Hash": "64"}))
        with self.assertRaises(ValueError):
            EngineSpec.parse("bin=/x/hm,model=/x/n.onnx,nodes=5,movetime=9")


class Statistics(unittest.TestCase):
    def test_elo_and_sprt_match_tournament_formulas(self):
        self.assertEqual(score_to_elo(0.5), 0.0)
        self.assertAlmostEqual(score_to_elo(0.75), 190.85, places=2)
        # Each perfect pair adds 2*ln(p1/p0) ~= 0.0576 against an upper bound
        # of ln(0.95/0.05) ~= 2.944, so 51 pairs continue and 52 accept.
        self.assertEqual(paired_sprt([1.0] * 51, 0.0, 10.0).decision, "continue")
        self.assertEqual(paired_sprt([1.0] * 52, 0.0, 10.0).decision, "accept_h1")
        self.assertEqual(paired_sprt([0.0] * 52, 0.0, 10.0).decision, "accept_h0")

    def test_summary_counts_pairs_and_pentanomial(self):
        def record(game, pair, team, score):
            empty = {"white": 0, "black": 0}
            return {"game": game, "pair": pair, "contender_team": team, "contender_score": score,
                    "result": {"termination": "flag", "duration_ms": 1000, "decisions": empty,
                               "sits": empty, "sit_ms": empty, "advantage_decisions": empty}}

        summary = summarize([record(0, 0, "white", 1.0), record(1, 0, "black", 1.0),
                             record(2, 1, "white", 0.0), record(3, 1, "black", 1.0)])
        self.assertEqual((summary["contender_wins"], summary["contender_losses"]), (3, 1))
        self.assertEqual(summary["pentanomial"], [0, 0, 1, 0, 1])
        self.assertEqual(summary["complete_pairs"], 2)


class MatchFiles(unittest.TestCase):
    def test_random_match_writes_results_and_resumes(self):
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp) / "m"
            config = MatchConfig(pairs=2, clock=ClockConfig(initial_ms=20_000), output=output)
            sides = (PlayerFactory("random,sit=0.1", None, None, None),
                     PlayerFactory("random", None, None, None))
            with redirect_stdout(io.StringIO()):
                summary = run_match(config, *sides, log=lambda _: None)
                self.assertEqual(summary["counted_games"], 4)
                with self.assertRaises(FileExistsError):
                    run_match(config, *sides, log=lambda _: None)
                config.resume, config.pairs = True, 3
                summary = run_match(config, *sides, log=lambda _: None)
            self.assertEqual(summary["counted_games"], 6)
            lines = (output / "results.jsonl").read_text().splitlines()
            self.assertEqual(sorted(json.loads(line)["game"] for line in lines), list(range(6)))
            self.assertIn('[WhiteA "random"]', (output / "games.bpgn").read_text())

    def test_bpgn_is_the_whole_game_in_san_with_clocks_and_scores(self):
        clocks = {"initial_ms": 120000}
        record = {
            "game": 0, "clock": clocks,
            "opening": {"dual_fen": None, "moves": ["1e2e4", "1d7d5"]},
            "result": {"winner": "white", "termination": "checkmate", "events": [
                {"t": 1900, "kind": "move", "seat": "A-white", "board": "A", "uci": "e4d5",
                 "clocks": [118100, 120000, 120000, 120000], "eval": {"cp": 319}},
                {"t": 2000, "kind": "move", "seat": "B-white", "board": "B", "uci": "g1f3",
                 "clocks": [118100, 120000, 118000, 120000]},
                {"t": 2100, "kind": "flip", "seat": None, "clocks": [118100] * 4},
                {"t": 3000, "kind": "sit", "seat": "A-black", "board": "A",
                 "clocks": [118100, 118900, 118000, 120000], "eval": {"cp": -40}},
                {"t": 4000, "kind": "move", "seat": "B-black", "board": "B", "uci": "P@e4",
                 "clocks": [118100, 118900, 118000, 3598000], "eval": {"mate": 2}},
                {"t": 4100, "kind": "illegal", "seat": "A-black", "board": "A", "uci": "e2e5",
                 "clocks": [118100, 117800, 118000, 3598000]},
            ]}}
        names = {"A-white": "hb", "B-black": "hb", "A-black": "hm", "B-white": "hm"}
        stream = io.StringIO()
        write_bpgn(stream, record, names)
        text = stream.getvalue()
        self.assertIn('[WhiteA "hb"]\n[BlackA "hm"]\n[WhiteB "hm"]\n[BlackB "hb"]', text)
        self.assertIn(
            "1A. e4 1a. d5 2A. exd5 {[%clk 0:01:58.1] [%eval 3.19] 1.9s} "
            "1B. Nf3 {[%clk 0:01:58.0] 2.0s}\n"
            "{A-black sits @3.0s} 1b. P@e4 {[%clk 0:59:58.0] [%eval #-2] 4.0s} "
            "{A-black illegal e2e5 @4.1s} 1-0\n", text)
        # What the app's reader does: drop the tags, then every move token
        # must play in order on its own board.
        game = Bughouse()
        body = re.sub(r"\{[^}]*\}", " ", re.sub(r"\[[^\]]*\]", " ", text))
        for number, letter, san in re.findall(r"(\d+)([AaBb])\.\s*(\S+)", body):
            board = "ab".index(letter.lower())
            position = game.boards[board]
            self.assertEqual((position.fullmove_number, position.turn), (int(number), letter.isupper()))
            game.push(board, position.parse_san(san).uci())
        self.assertEqual(len(game.moves), 5)

    def test_clock_is_rounded_before_it_is_split(self):
        self.assertEqual(_clock_tag(59_960), "[%clk 0:01:00.0]")
        self.assertEqual(_clock_tag(119_970), "[%clk 0:02:00.0]")
        self.assertEqual(_clock_tag(3_599_960), "[%clk 1:00:00.0]")
        self.assertEqual(_clock_tag(7_449), "[%clk 0:00:07.4]")
        self.assertEqual(_clock_tag(-5), "[%clk 0:00:00.0]")

    def test_last_score_is_the_final_info_line_before_bestmove(self):
        lines = ["info depth 3 score cp 12 nodes 9 pv e2e4",
                 "info string hb_summary main_score_cp=999",
                 "info depth 4 score mate -3 nodes 20 time 5 pv e2e4",
                 "info depth 5 currmove e2e4 currmovenumber 1",
                 "bestmove e2e4"]
        self.assertEqual(_last_score(lines), {"mate": -3})
        self.assertEqual(_last_score(lines[:2]), {"cp": 12})
        self.assertIsNone(_last_score(["info string no score here", "bestmove e2e4"]))


TOOLS = Path(__file__).resolve().parent

FAKE_ENGINE = r'''#!{python}
"""Scripted UCI engine for the arena tests: kind {kind!r}, behaviour {behaviour!r}."""
import json
import sys
import time

sys.path.insert(0, {tools!r})
from chess.variant import CrazyhouseBoard  # noqa: E402
from bughouse_arena.referee import Bughouse  # noqa: E402

KIND = {kind!r}
BEHAVIOUR = {behaviour!r}
log = open({log!r}, "a")
log.write("ARGV " + json.dumps(sys.argv) + "\n")
log.flush()
COMMON = ["option name Threads type spin default 1 min 1 max 512",
          "option name Hash type spin default 16 min 1 max 33554432",
          "option name Ponder type check default false"]
FSF = ["option name UCI_Variant type combo default chess var bughouse var chess",
       "option name Use NNUE type check default true",
       "option name EvalFile type string default <empty>"]
TEAM = ["option name Team type combo default white var white var black",
        "option name TimeAdvantage type check default false"]
HYPEBEAST = ["option name HypeBeast type check default false",
             "option name Coordination type check default true",
             "option name Seat type combo default Awhite var Awhite var Ablack var Bwhite var Bblack",
             "option name Clocks type string"]
ADVERTISED = {{"hivemind": ["option name Hash type spin default 16 min 1 max 1024",
                           "option name Ponder type check default true"] + TEAM,
              "hypebeast": COMMON + FSF + TEAM + HYPEBEAST,
              "fsf": COMMON + FSF}}[KIND]
ADVERTISED = [line for line in ADVERTISED
              if line.split()[2] not in BEHAVIOUR.get("hide", [])]
ADVERTISED += [line for line in TEAM + HYPEBEAST if line.split()[2] in BEHAVIOUR.get("advertise", [])]
options = {{}}
position = "position startpos"
searches = 0


def say(text):
    sys.stdout.write(text + "\n")
    sys.stdout.flush()


def team_answer():
    tokens = position.split()
    game = Bughouse()
    if tokens[1] == "fen":
        game = Bughouse.from_dual_fen(" ".join(tokens[2:tokens.index("moves")] if "moves" in tokens
                                               else tokens[2:]))
    if "moves" in tokens:
        for token in tokens[tokens.index("moves") + 1:]:
            game.push(int(token[0]) - 1, token[1:])
    team_white = options.get("Team", "white") == "white"
    halves = []
    for board in (0, 1):
        colour = team_white if board == 0 else not team_white
        mine = KIND == "hivemind" or board == "AB".index(options.get("Seat", "Awhite")[0])
        moves = sorted(game.legal_moves(board))
        halves.append(moves[0] if mine and game.turn(board) == colour and moves else "pass")
    if BEHAVIOUR.get("pass"):
        halves = ["pass", "pass"]
    if "wake" in BEHAVIOUR:
        say(f"info string hb_wake_after_ms={{BEHAVIOUR['wake']}}")
    return f"({{halves[0]}},{{halves[1]}})"


def fsf_answer():
    tokens = position.split()
    board = CrazyhouseBoard(" ".join(tokens[2:]) if tokens[1] == "fen" else CrazyhouseBoard.starting_fen)
    if BEHAVIOUR.get("null"):
        return "(none)"
    if BEHAVIOUR.get("illegal"):
        return "e2e5"
    moves = sorted(move.uci() for move in board.legal_moves)
    return moves[0] if moves else "(none)"


for raw in sys.stdin:
    line = raw.strip()
    log.write(line + "\n")
    log.flush()
    if line == "uci":
        say(f"id name Fake-{{KIND}}")
        say("id author arena tests")
        for option in ADVERTISED:
            say(option)
        say("uciok")
    elif line == "isready":
        say("readyok")
    elif line.startswith("setoption name "):
        name, _, value = line[len("setoption name "):].partition(" value ")
        options[name] = value
    elif line.startswith("position"):
        position = line
    elif line.startswith("go"):
        searches += 1
        if searches > BEHAVIOUR.get("hang_after", 10 ** 9):
            continue   # never answers this search, but keeps reading input
        tokens = line.split()
        if "movetime" in tokens:
            time.sleep(int(tokens[tokens.index("movetime") + 1]) / 1000 * BEHAVIOUR.get("slow", 1))
        if KIND != "hivemind" and not BEHAVIOUR.get("no_nnue"):
            say(f"info string NNUE evaluation using {{options.get('EvalFile', '')}} enabled")
        say("info depth 1 seldepth 1 multipv 1 score cp 0 nodes 42 nps 4200 time 10 pv a2a3")
        say("bestmove " + (fsf_answer() if KIND == "fsf" else team_answer()))
    elif line == "quit":
        break
'''


class FakeEngines:
    """Writes fake engines into a temporary directory; ``commands(name)``
    returns what one received."""

    def __init__(self, directory: Path):
        self.directory = directory
        self.net = directory / "bughouse-test.nnue"
        self.net.write_bytes(b"not really a net")
        self.model = directory / "model.onnx"
        self.model.write_bytes(b"not really a model")

    def make(self, name: str, kind: str, **behaviour) -> Path:
        path = self.directory / name
        path.write_text(FAKE_ENGINE.format(python=sys.executable, kind=kind, behaviour=behaviour,
                                           tools=str(TOOLS), log=str(self.log(name))))
        path.chmod(0o755)
        return path

    def log(self, name: str) -> Path:
        return self.directory / f"{name}.commands"

    def commands(self, name: str) -> list[str]:
        return self.log(name).read_text().splitlines()

    def spec(self, kind: str, name: str, extra: str = "", **behaviour) -> EngineSpec:
        binary = self.make(name, kind, **behaviour)
        if kind == "hivemind":
            text = f"hivemind,bin={binary},model={self.model},nodes=5"
        else:
            text = f"{kind},bin={binary},net={self.net},nodes=5"
        return EngineSpec.parse(text + extra)


def view_of(game, board, color, advantage=False, clocks=(120_000,) * 4, now=0):
    team = color if board == BOARD_A else not color
    return SeatView(game, board, color, team, advantage, clocks, now, False)


class TempDir(unittest.TestCase):
    def setUp(self):
        self._temp = tempfile.TemporaryDirectory()
        self.dir = Path(self._temp.name)
        self.fakes = FakeEngines(self.dir)

    def tearDown(self):
        self._temp.cleanup()


class EngineKinds(unittest.TestCase):
    def test_kind_prefix_and_backward_compatible_hivemind_specs(self):
        for text in ("hivemind,bin=/x/hm,model=/x/n.onnx,nodes=9", "bin=/x/hm,model=/x/n.onnx,nodes=9"):
            with self.subTest(text):
                spec = EngineSpec.parse(text)
                self.assertEqual((spec.kind, spec.model, spec.nodes), ("hivemind", Path("/x/n.onnx"), 9))

    def test_fsf_and_hypebeast_defaults(self):
        home = hypebeast_home()
        fsf = EngineSpec.parse("fsf,movetime=250")
        self.assertEqual((fsf.kind, fsf.binary, fsf.net, fsf.movetime_ms, fsf.model),
                         ("fsf", home / "bin/fsf-ref", home / "nets/bughouse-cd8cceab93fe.nnue",
                          250, None))
        self.assertEqual(fsf.name, "fsf-t250")
        self.assertEqual(fsf.describe()["label"], FSF_LABEL)
        hb = EngineSpec.parse("hypebeast,nodes=1000")
        self.assertEqual((hb.binary, hb.options, hb.name),
                         (home / "bin/hypebeast", {"Coordination": "true"}, "hypebeast-coord-n1000"))
        off = EngineSpec.parse("hypebeast,nodes=1000,Coordination=false,Hash=64")
        self.assertEqual((off.options, off.name),
                         ({"Coordination": "false", "Hash": "64"}, "hypebeast-nocoord-n1000"))

    def test_hivemind_only_arguments_are_rejected_elsewhere(self):
        for text in ("fsf,model=/x.onnx,nodes=5", "hypebeast,lib=/x,nodes=5", "fsf",
                     "hypebeast,movetime=5,nodes=5", "fsf,nodes=5,EvalFile=/x",
                     "hypebeast,nodes=5,Seat=Awhite", "fsf,nodes=5,Coordination=false",
                     "hypebeast,nodes=5,Coordination=maybe", "stockfish,nodes=5",
                     "hivemind,bin=/x,model=/y,net=/z"):
            with self.subTest(text), self.assertRaises(ValueError):
                EngineSpec.parse(text)


class OptionGating(TempDir):
    def test_hivemind_gets_team_and_advantage_but_never_seat_or_clocks(self):
        seat = HivemindSeat(self.fakes.spec("hivemind", "hm"))
        try:
            seat.new_game(BOARD_B, B)
            game = play(Bughouse(), "1e2e4 2e2e4")
            move = seat.decide(view_of(game, BOARD_B, B, advantage=True, clocks=(1, 2, 3, 4)))
        finally:
            seat.close()
        commands = self.fakes.commands("hm")
        self.assertIn("--model", json.loads(commands[0][len("ARGV "):]))
        self.assertIn("setoption name Team value white", commands)   # B-black is team white
        self.assertIn("setoption name TimeAdvantage value true", commands)
        self.assertIn("position startpos moves 1e2e4 2e2e4", commands)
        self.assertFalse([c for c in commands if c.startswith(("setoption name Seat",
                                                                "setoption name Clocks"))])
        self.assertIn("stop", commands)   # no PermanentBrain: stop after bestmove
        self.assertTrue(game.is_legal(BOARD_B, move))

    def test_seat_and_clocks_follow_the_advertisement_not_the_kind(self):
        seat = HivemindSeat(self.fakes.spec("hivemind", "hm2", advertise=["Seat", "Clocks"]))
        try:
            seat.new_game(BOARD_A, W)
            seat.decide(view_of(Bughouse(), BOARD_A, W, clocks=(5, 6, 7, 8)))
        finally:
            seat.close()
        commands = self.fakes.commands("hm2")
        self.assertIn("setoption name Seat value Awhite", commands)
        self.assertIn("setoption name Clocks value 5,6,7,8", commands)

    def test_hypebeast_handshake_seat_once_and_clocks_before_every_go(self):
        spec = self.fakes.spec("hypebeast", "hb", ",Coordination=false")
        seat = TeamEngineSeat(spec)
        game = Bughouse()
        try:
            seat.new_game(BOARD_B, B)
            play(game, "2e2e4")
            first = seat.decide(view_of(game, BOARD_B, B, clocks=(120_000, 119_000, 118_000, 117_500)))
            play(game, f"2{first} 2d2d4")
            seat.decide(view_of(game, BOARD_B, B, clocks=(110_000, 109_000, 108_000, 107_001)))
        finally:
            seat.close()
        commands = self.fakes.commands("hb")
        self.assertNotIn("--model", json.loads(commands[0][len("ARGV "):]))
        for expected in ("setoption name UCI_Variant value bughouse",
                         f"setoption name EvalFile value {self.fakes.net}",
                         "setoption name HypeBeast value true",
                         "setoption name Coordination value false",
                         "setoption name Team value white"):
            self.assertIn(expected, commands)
        self.assertEqual([c for c in commands if c.startswith("setoption name Seat")],
                         ["setoption name Seat value Bblack"])
        clocks = [i for i, c in enumerate(commands) if c.startswith("setoption name Clocks")]
        goes = [i for i, c in enumerate(commands) if c.startswith("go ")]
        self.assertEqual([commands[i] for i in clocks],
                         ["setoption name Clocks value 120000,119000,118000,117500",
                          "setoption name Clocks value 110000,109000,108000,107001"])
        self.assertEqual(len(goes), 2)
        self.assertTrue(clocks[0] < goes[0] < clocks[1] < goes[1])
        self.assertTrue(commands[goes[1] - 1].startswith("position startpos moves 2e2e4"))
        self.assertNotIn("stop", commands)

    def test_seat_values_for_every_seat(self):
        spec = self.fakes.spec("hypebeast", "hb4")
        seat = TeamEngineSeat(spec)
        try:
            for board, color in ((BOARD_A, W), (BOARD_A, B), (BOARD_B, W), (BOARD_B, B)):
                seat.new_game(board, color)
        finally:
            seat.close()
        commands = self.fakes.commands("hb4")
        self.assertEqual([c.split()[-1] for c in commands if c.startswith("setoption name Seat")],
                         ["Awhite", "Ablack", "Bwhite", "Bblack"])
        self.assertEqual([c.split()[-1] for c in commands if c.startswith("setoption name Team")],
                         ["white", "black", "black", "white"])

    def test_hypebeast_kind_requires_its_options(self):
        for hidden in ("HypeBeast", "Seat", "Coordination"):
            with self.subTest(hidden), self.assertRaises(EngineError):
                TeamEngineSeat(self.fakes.spec("hypebeast", f"no-{hidden}", hide=[hidden])).close()

    def test_wake_request_is_read_only_from_a_passing_search(self):
        seat = TeamEngineSeat(self.fakes.spec("hypebeast", "waker", **{"pass": True, "wake": 3000}))
        mover = TeamEngineSeat(self.fakes.spec("hypebeast", "mover", wake=3000))
        try:
            for player in (seat, mover):
                player.new_game(BOARD_A, W)
            self.assertIsNone(seat.decide(view_of(Bughouse(), BOARD_A, W)))
            self.assertEqual(seat.requested_wake_ms, 3000)
            self.assertIsNotNone(mover.decide(view_of(Bughouse(), BOARD_A, W)))
            self.assertIsNone(mover.requested_wake_ms)
            self.assertEqual(seat.game_stats["wake_requests"], 1)
        finally:
            seat.close()
            mover.close()


class FsfFen(unittest.TestCase):
    def test_bracket_pockets_promoted_marks_and_counters(self):
        board = CrazyhouseBoard("r1bqkb1r/pppp1Q~pp/2n2n2/4p3/2B1P3/8/PPPP1PPP/RNB1K1NR"
                                "[NPQqnp] b KQkq - 0 4")
        self.assertEqual(fsf_fen(board), "r1bqkb1r/pppp1Q~pp/2n2n2/4p3/2B1P3/8/PPPP1PPP/"
                                         "RNB1K1NR[QNPqnp] b KQkq - 0 4")
        self.assertEqual(fsf_fen(CrazyhouseBoard("r3k2r/8/8/8/8/8/8/R3K2R[] w Kq - 3 20")),
                         "r3k2r/8/8/8/8/8/8/R3K2R[] w Kq - 3 20")

    def test_promotion_and_transfers_from_the_referee(self):
        game = play(Bughouse("1r5k/P7/8/8/8/8/8/K7[] w - - 0 1", BARE_KINGS_W), "1a7a8q")
        self.assertEqual(fsf_fen(game.boards[BOARD_A]), "Qr5k/8/8/8/8/8/8/K7[] b - - 0 1"
                         .replace("Qr", "Q~r"))
        play(game, "1b8a8")   # the promoted queen goes to board B's white as a pawn
        self.assertEqual(fsf_fen(game.boards[BOARD_B]), "4k3/8/8/8/8/8/8/4K3[P] w - - 0 1")

    def test_en_passant_square_only_when_capturable(self):
        game = play(Bughouse(), "1e2e4")
        self.assertIn(" b KQkq - 0 1", fsf_fen(game.boards[BOARD_A]))
        play(game, "1a7a6 1e4e5 1d7d5")
        self.assertIn(" w KQkq d6 0 3", fsf_fen(game.boards[BOARD_A]))

    def test_round_trips_through_python_chess(self):
        rng = random.Random(7)
        pockets = promoted = 0
        for _ in range(30):
            game = Bughouse()
            for _ in range(80):
                board = rng.choice((BOARD_A, BOARD_B))
                moves = sorted(game.legal_moves(board))
                if not moves:
                    continue
                game.push(board, rng.choice(moves))
                for position in game.boards:
                    fen = fsf_fen(position)
                    back = CrazyhouseBoard(fen)
                    self.assertEqual(fsf_fen(back), fen)
                    self.assertEqual(back.board_fen(promoted=True), position.board_fen(promoted=True))
                    for color in (W, B):
                        for piece in chess.PIECE_TYPES[:-1]:
                            self.assertEqual(back.pockets[color].count(piece),
                                             position.pockets[color].count(piece))
                    self.assertEqual((back.turn, back.clean_castling_rights(), back.halfmove_clock,
                                      back.fullmove_number, back.promoted),
                                     (position.turn, position.clean_castling_rights(),
                                      position.halfmove_clock, position.fullmove_number,
                                      position.promoted))
                    self.assertEqual(set(back.legal_moves), set(position.legal_moves))
                    pockets += "[]" not in fen
                    promoted += "~" in fen
        self.assertGreater(pockets, 100)
        self.assertGreater(promoted, 0)


class FsfAdapter(TempDir):
    def test_sends_the_seats_board_as_fen_and_plays_legal_moves(self):
        seat = FsfSeat(self.fakes.spec("fsf", "fsf"))
        game = play(Bughouse(), "1e2e4 1d7d5 1e4d5 2d2d4")   # board B black now holds a pawn
        try:
            seat.new_game(BOARD_B, B)
            move = seat.decide(view_of(game, BOARD_B, B))
        finally:
            seat.close()
        commands = self.fakes.commands("fsf")
        self.assertNotIn("--model", json.loads(commands[0][len("ARGV "):]))
        self.assertIn("setoption name UCI_Variant value bughouse", commands)
        self.assertIn(f"setoption name EvalFile value {self.fakes.net}", commands)
        self.assertIn("position fen rnbqkbnr/pppppppp/8/8/3P4/8/PPP1PPPP/RNBQKBNR[p] b KQkq - 0 1",
                      commands)
        self.assertFalse([c for c in commands if c.startswith(("setoption name Team",
                                                                "setoption name Seat",
                                                                "setoption name Clocks"))])
        self.assertTrue(game.is_legal(BOARD_B, move))

    def test_full_game_against_random(self):
        players = {A_WHITE: FsfSeat(self.fakes.spec("fsf", "f1")),
                   A_BLACK: RandomPlayer(1), B_WHITE: RandomPlayer(2),
                   B_BLACK: FsfSeat(self.fakes.spec("fsf", "f2"))}
        try:
            result = play_game(Bughouse(), players, ClockConfig(initial_ms=20_000))
        finally:
            for player in players.values():
                player.close()
        self.assertIsNone(result.error)
        self.assertIn(result.termination, {"checkmate", "flag", "draw"})
        self.assertGreater(players[A_WHITE].game_stats["searches"], 3)

    def test_no_legal_move_sits_without_asking_the_engine(self):
        seat = FsfSeat(self.fakes.spec("fsf", "stuck"))
        game = Bughouse("k7/8/1Q6/8/8/8/8/1K6 b - - 0 1", START)  # stalemated, game goes on
        self.assertFalse(game.is_checkmate(B, False))
        try:
            seat.new_game(BOARD_A, B)
            self.assertIsNone(seat.decide(view_of(game, BOARD_A, B)))
        finally:
            seat.close()
        self.assertFalse([c for c in self.fakes.commands("stuck") if c.startswith("go")])
        self.assertEqual(seat.game_stats["mandatory_sits"], 1)

    def test_null_or_illegal_output_loses_and_is_logged(self):
        for name, behaviour in (("null", {"null": True}), ("illegal", {"illegal": True})):
            with self.subTest(name):
                players = seats()
                players[A_WHITE] = FsfSeat(self.fakes.spec("fsf", name, **behaviour))
                try:
                    result = play_game(Bughouse(), players, FIXED)
                finally:
                    players[A_WHITE].close()
                self.assertEqual((result.termination, result.winner), ("illegal move", B))
                illegal = [e for e in result.events if e["kind"] == "illegal"]
                self.assertEqual(illegal[0]["uci"], "(none)" if name == "null" else "e2e5")

    def test_missing_nnue_confirmation_is_an_engine_failure(self):
        seat = FsfSeat(self.fakes.spec("fsf", "classical", no_nnue=True))
        try:
            seat.new_game(BOARD_A, W)
            with self.assertRaises(EngineError):
                seat.decide(view_of(Bughouse(), BOARD_A, W))
        finally:
            seat.close()


class WakeScheduling(unittest.TestCase):
    """Wake requests with no other-board events: board B never moves."""

    class Waker(Scripted):
        def __init__(self, wake_ms, sit=lambda view: True):
            super().__init__(sit)
            self.wake_ms = wake_ms

        def decide(self, view):
            move = super().decide(view)
            self.requested_wake_ms = self.wake_ms if move is None else None
            return move

    def frozen_b(self):
        return {"bw": Scripted(sit=lambda v: True), "bb": Scripted(sit=lambda v: True)}

    def test_timer_wakes_the_seat_with_no_other_board_events(self):
        waker = self.Waker(3000, sit=lambda view: view.now_ms < 5_000)
        result = play_game(Bughouse(), seats(aw=waker, **self.frozen_b()), FIXED, max_decisions=4)
        self.assertEqual([t for t, _, _ in waker.calls[:2]], [2000, 5000])
        self.assertIn((5000, "A-white"), [(t, s) for t, s, _ in moves_of(result)])
        wakes = [e for e in result.events if e["kind"] == "wake"]
        self.assertEqual([(e["t"], e["seat"], e["reason"]) for e in wakes], [(5000, "A-white", "timer")])
        self.assertEqual(result.timer_wakes[W], 1)

    def test_no_indefinite_renewal(self):
        waker = self.Waker(3000)   # sits and asks again every time
        result = play_game(Bughouse(), seats(aw=waker, **self.frozen_b()), FIXED)
        self.assertEqual([t for t, _, _ in waker.calls], [2000, 5000])
        self.assertEqual(result.termination, "flag")

    def test_intervening_wakes_keep_the_original_expiry(self):
        # Board B moves at 2000 (B-white) and 4000 (B-black) and then stalls, so
        # A-white is react-woken at 2500 and 4500 and still timer-woken at 5000,
        # not at 5500 or 7500.
        waker = self.Waker(3000, sit=lambda view: view.now_ms < 5_000)
        stall = {"bw": Scripted(sit=lambda v: v.now_ms > 2_000),
                 "bb": Scripted(sit=lambda v: v.now_ms > 4_000)}
        result = play_game(Bughouse(), seats(aw=waker, **stall), FIXED, max_decisions=12)
        self.assertEqual([t for t, _, _ in waker.calls[:4]], [2000, 2500, 4500, 5000])
        sits = [e for e in result.events if e["kind"] == "sit" and e["seat"] == "A-white"]
        self.assertEqual([e["wake_at"] for e in sits], [5000, 5000, 5000])

    def test_a_new_turn_gets_a_new_deadline(self):
        # Plays at 5000 when woken, then sits again on its next turn (asked at
        # 2000 + 2000 + react) with a fresh request.
        waker = self.Waker(1000, sit=lambda view: view.now_ms != 3_000 and view.now_ms < 9_000)
        play_game(Bughouse(), seats(aw=waker, **self.frozen_b()), FIXED, max_decisions=10)
        times = [t for t, _, _ in waker.calls]
        self.assertEqual(times[:2], [2000, 3000])   # timer wake, plays
        self.assertIn(times[2] + 1000, times)       # its next turn's own timer

    def test_engine_wake_line_drives_the_timer(self):
        with tempfile.TemporaryDirectory() as temp:
            fakes = FakeEngines(Path(temp))
            waker = TeamEngineSeat(fakes.spec("hypebeast", "w", **{"pass": True, "wake": 3000}))
            try:
                play_game(Bughouse(), seats(aw=waker, **self.frozen_b()), FIXED)
            finally:
                waker.close()
            self.assertEqual(len([c for c in fakes.commands("w") if c.startswith("go ")]), 2)


class FixedSampleStatistics(unittest.TestCase):
    def test_boundaries_never_have_zero_width(self):
        for n in (1, 2, 20, 200):
            with self.subTest(n=n):
                low, high = pair_interval([1.0] * n)
                self.assertEqual(high, 1.0)
                self.assertLess(low, 1.0)
                low, high = pair_interval([0.0] * n)
                self.assertEqual(low, 0.0)
                self.assertGreater(high, 0.0)
                for value in (0.25, 0.5, 0.75):
                    low, high = pair_interval([value] * n)
                    self.assertLess(low, value)
                    self.assertGreater(high, value)
        self.assertIsNone(pair_interval([]))

    def test_interval_contains_the_mean_and_shrinks(self):
        rng = random.Random(3)
        values = [0, 0.25, 0.5, 0.75, 1]
        for _ in range(200):
            sample = rng.choices(values, k=rng.randint(1, 40))
            low, high = pair_interval(sample)
            self.assertLessEqual(low, sum(sample) / len(sample))
            self.assertGreaterEqual(high, sum(sample) / len(sample))
        widths = [pair_interval([1.0, 0.5, 0.75, 0.25] * k) for k in (5, 50)]
        self.assertLess(widths[1][1] - widths[1][0], widths[0][1] - widths[0][0])

    def test_coverage_is_about_95_percent(self):
        rng = random.Random(11)
        values = [0, 0.25, 0.5, 0.75, 1]
        for probs in ([0.1, 0.2, 0.4, 0.2, 0.1], [0.02, 0.08, 0.3, 0.35, 0.25]):
            mean = sum(p * v for p, v in zip(probs, values))
            hits = 0
            for _ in range(1000):
                low, high = pair_interval(rng.choices(values, probs, k=20))
                hits += low <= mean <= high
            self.assertGreaterEqual(hits / 1000, 0.92, probs)
            self.assertLessEqual(hits / 1000, 0.99, probs)

    @staticmethod
    def record(game, pair, team, score, termination="flag"):
        empty = {"white": 0, "black": 0}
        return {"game": game, "pair": pair, "contender_team": team, "contender_score": score,
                "result": {"termination": termination, "duration_ms": 1000, "decisions": empty,
                           "sits": empty, "sit_ms": empty, "advantage_decisions": empty}}

    def test_all_winning_has_no_finite_elo(self):
        games = [self.record(2 * p + i, p, team, 1.0) for p in range(3)
                 for i, team in enumerate(("white", "black"))]
        block = summarize(games, declared_pairs=3)["fixed_sample"]
        self.assertEqual((block["wins"], block["draws"], block["losses"], block["score"]), (6, 0, 0, 1.0))
        self.assertIsNone(block["elo"])
        self.assertIsNotNone(block["elo_interval_95"][0])
        self.assertIsNone(block["elo_interval_95"][1])
        self.assertEqual(block["score_interval_95"][1], 1.0)
        self.assertEqual(block["pentanomial"], {"0-2": 0, "0.5-1.5": 0, "1-1": 0, "1.5-0.5": 0, "2-0": 3})
        self.assertTrue(block["sample_complete"] and block["reliability"]["ok"])

    def test_errors_and_illegal_moves_are_reported_not_dropped(self):
        games = [self.record(0, 0, "white", 1.0), self.record(1, 0, "black", 0.5),
                 self.record(2, 1, "white", 0.0, "illegal move"),
                 self.record(3, 1, "black", 0.5, "error")]
        block = summarize(games, declared_pairs=2, replayed_errors=1)["fixed_sample"]
        self.assertEqual(block["reliability"], {"errors": 1, "illegal_moves": 1,
                                                "replayed_errors": 1, "ok": False})
        self.assertEqual((block["complete_pairs"], block["incomplete_pairs"]), (1, [1]))
        self.assertFalse(block["sample_complete"])
        self.assertEqual(block["pentanomial"]["1.5-0.5"], 1)

    def test_fixed_sample_rejects_sprt_and_short_opening_sets(self):
        with tempfile.TemporaryDirectory() as temp:
            config = MatchConfig(pairs=2, clock=ClockConfig(initial_ms=5_000), output=Path(temp),
                                 fixed_sample=True, sprt=(0.0, 10.0, 0.05, 0.05))
            sides = (PlayerFactory("random", None, None, None),) * 2
            with self.assertRaises(ValueError):
                run_match(config, *sides, log=lambda _: None)
        config = MatchConfig(pairs=3, clock=FIXED, output=Path("."), fixed_sample=True,
                             openings=[load_openings(SETS / "debug.txt")[0]] * 2)
        with self.assertRaises(ValueError):
            game_plan(config)

    def test_fixed_sample_plays_every_declared_pair(self):
        with tempfile.TemporaryDirectory() as temp:
            config = MatchConfig(pairs=3, clock=ClockConfig(initial_ms=10_000), output=Path(temp),
                                 fixed_sample=True, openings=load_openings(SETS / "debug.txt"),
                                 openings_path=SETS / "debug.txt")
            summary = run_match(config, PlayerFactory("random", None, None, None),
                                PlayerFactory("random,sit=0.2", None, None, None),
                                log=lambda _: None)
        block = summary["fixed_sample"]
        self.assertEqual((summary["counted_games"], block["complete_pairs"]), (6, 3))
        self.assertTrue(block["sample_complete"])


SETS = TOOLS / "bughouse_arena" / "opening_sets"


class OpeningSets(unittest.TestCase):
    SIZES = {"debug.txt": 20, "preflight.txt": 24, "screen20.txt": 20, "heldout200.txt": 200}

    def test_sets_are_legal_real_pocket_positions_and_disjoint(self):
        keys = {}
        for name, size in self.SIZES.items():
            with self.subTest(name):
                openings = load_openings(SETS / name)
                self.assertEqual(len(openings), size)
                self.assertEqual(sum("swapped=1" in o.source for o in openings), size // 2)
                for opening in openings:
                    game = opening.build()
                    self.assertTrue(opening.source.startswith("fics="))
                    self.assertTrue(any(len(game.boards[b].pockets[c]) for b in (0, 1) for c in (W, B)))
                    for board in (BOARD_A, BOARD_B):
                        self.assertFalse(game.boards[board].is_check())
                        self.assertTrue(game.has_legal_move(board))
                keys[name] = {opening_sets.position_key(o.build()) for o in openings}
                self.assertEqual(len(keys[name]), size)
        names = list(keys)
        for i, first in enumerate(names):
            for second in names[i + 1:]:
                self.assertFalse(keys[first] & keys[second], (first, second))

    def test_board_swap_is_a_legal_mirror(self):
        tokens = load_openings(SETS / "screen20.txt")[0].moves
        swapped = opening_sets.swap_boards(list(tokens))
        game = Bughouse()
        for token in swapped:
            game.push(int(token[0]) - 1, token[1:])
        original = load_openings(SETS / "screen20.txt")[0].build()
        self.assertEqual(game.boards[BOARD_A].fen(), original.boards[BOARD_B].fen())

    def test_each_opening_is_played_twice_with_teams_swapped(self):
        openings = load_openings(SETS / "screen20.txt")
        plan = game_plan(MatchConfig(pairs=20, clock=FIXED, output=Path("."), fixed_sample=True,
                                     openings=openings))
        self.assertEqual(len(plan), 40)
        for first, second in zip(plan[::2], plan[1::2]):
            self.assertEqual((first[1], first[3]), (second[1], second[3]))
            self.assertEqual((first[2], second[2]), (W, B))
        self.assertEqual(len({item[3] for item in plan}), 20)


class Manifest(TempDir):
    def test_manifest_pins_files_settings_and_openings(self):
        output = self.dir / "match"
        openings = self.dir / "openings.txt"
        openings.write_text((SETS / "debug.txt").read_text())
        contender = PlayerFactory(f"fsf,bin={self.fakes.make('fsf', 'fsf')},net={self.fakes.net},"
                                  "nodes=5,Hash=32", None, None, None)
        config = MatchConfig(pairs=1, clock=ClockConfig(initial_ms=8_000), output=output,
                             fixed_sample=True, openings=load_openings(openings),
                             openings_path=openings, argv=["python3", "-m", "bughouse_arena", "x"])
        summary = run_match(config, contender, PlayerFactory("random", None, None, None),
                            log=lambda _: None)
        manifest = json.loads((output / "manifest.json").read_text())
        sha = lambda path: hashlib.sha256(Path(path).read_bytes()).hexdigest()  # noqa: E731
        side = manifest["sides"]["contender"]
        self.assertEqual(side["kind"], "fsf")
        self.assertEqual(side["label"], FSF_LABEL)
        self.assertEqual(side["files"]["binary"]["sha256"], sha(self.dir / "fsf"))
        self.assertEqual(side["files"]["net"]["sha256"], sha(self.fakes.net))
        self.assertEqual(side["options"], {"Hash": "32"})
        identity = side["identity"]
        self.assertEqual(identity["id"]["name"], "Fake-fsf")
        self.assertTrue(identity["probe_search"]["nnue"])
        self.assertEqual(identity["sent_options"]["UCI_Variant"], "bughouse")
        self.assertEqual(identity["sent_options"]["Hash"], "32")
        self.assertEqual(identity["advertised_options"]["Hash"], {"type": "spin", "default": "16"})
        self.assertEqual(manifest["openings"]["sha256"], sha(openings))
        self.assertEqual(manifest["pins"]["openings"], {"sha256": sha(openings), "count": 20})
        self.assertEqual(manifest["pins"]["clock"]["initial_ms"], 8_000)
        self.assertTrue(manifest["pins"]["fixed_sample"])
        self.assertIn("players.py", manifest["arena"]["files_sha256"])
        for key in ("cpu_model", "logical_cpus", "physical_cores", "cgroup_cpu_max", "env"):
            self.assertIn(key, manifest["environment"])
        self.assertEqual(manifest["argv"][-1], "x")
        self.assertEqual(summary["openings_sha256"], sha(openings))
        record = json.loads((output / "results.jsonl").read_text().splitlines()[0])
        fsf_seats = {"white": ("A-white", "B-black"), "black": ("A-black", "B-white")}[
            record["contender_team"]]
        self.assertEqual(set(record["seat_stats"]), set(fsf_seats))
        self.assertTrue(all(isinstance(x, float) for s in record["seat_stats"].values()
                            for x in s["latency_ms"]))

        # Changing the net under a match refuses to resume it.
        self.fakes.net.write_bytes(b"another net")
        config.resume = True
        with self.assertRaises(RuntimeError):
            run_match(config, contender, PlayerFactory("random", None, None, None),
                      log=lambda _: None)

    def test_hivemind_side_hashes_model_and_runtime(self):
        (self.dir / "libonnxruntime.so.1").write_bytes(b"runtime")
        binary = self.fakes.make("hm", "hivemind")
        factory = PlayerFactory(f"hivemind,bin={binary},model={self.fakes.model},lib={self.dir},"
                                "nodes=5", None, None, None)
        files = factory.files()
        self.assertEqual(files["model"]["sha256"], hashlib.sha256(b"not really a model").hexdigest())
        self.assertEqual([r["sha256"] for r in files["runtime"]], [hashlib.sha256(b"runtime").hexdigest()])
        identity = factory.identity()
        self.assertFalse(identity["sends_seat"] or identity["sends_clocks"])
        self.assertNotIn("probe_search", identity)


class EngineTimeouts(TempDir):
    def test_a_search_without_bestmove_kills_the_engine_and_fails_the_seat(self):
        seat = TeamEngineSeat(self.fakes.spec("hivemind", "hang", hang_after=1))
        seat.search_timeout = 0.5
        try:
            seat.new_game(BOARD_A, W)
            seat.decide(view_of(Bughouse(), BOARD_A, W))
            with self.assertRaises(EngineError) as caught:
                seat.decide(view_of(Bughouse(), BOARD_A, W))
            self.assertIn("gave no bestmove", str(caught.exception))
            self.assertFalse(seat.uci.alive())
            with self.assertRaises(EngineError):
                seat.new_game(BOARD_A, W)
        finally:
            seat.close()

    def test_default_deadline_follows_the_budget(self):
        seat = FsfSeat(self.fakes.spec("fsf", "deadline"))
        try:
            self.assertEqual(seat.search_deadline("go movetime 1000"), 18.0)
            self.assertEqual(seat.search_deadline("go nodes 400"), 120.0)
            seat.search_timeout = 7
            self.assertEqual(seat.search_deadline("go movetime 1000"), 7)
        finally:
            seat.close()

    def test_a_hung_engine_voids_the_game_as_an_error_not_a_sit(self):
        players = seats()
        players[A_WHITE] = FsfSeat(self.fakes.spec("fsf", "hang2", hang_after=2), search_timeout=0.5)
        try:
            result = play_game(Bughouse(), players, FIXED)
        finally:
            players[A_WHITE].close()
        self.assertEqual(result.termination, "error")
        self.assertIn("gave no bestmove", result.error)
        self.assertFalse([e for e in result.events if e["kind"] == "sit" and e["seat"] == "A-white"])

    def test_match_restarts_engines_after_a_timeout(self):
        output = self.dir / "m"
        binary = self.fakes.make("hang3", "fsf", hang_after=3)
        contender = PlayerFactory(f"fsf,bin={binary},net={self.fakes.net},nodes=5", None, None, None)
        contender.search_timeout = 0.5
        config = MatchConfig(pairs=1, clock=ClockConfig(initial_ms=30_000), output=output,
                             probe_engines=False)
        summary = run_match(config, contender, PlayerFactory("random", None, None, None),
                            log=lambda _: None)
        # Each fresh process answers three searches and then hangs, so both
        # games fail; the second ran on restarted engines.
        self.assertEqual(summary["terminations"], {"error": 2})
        self.assertEqual(summary["fixed_sample"]["reliability"]["errors"], 2)
        starts = [c for c in self.fakes.commands("hang3") if c.startswith("ARGV")]
        self.assertGreaterEqual(len(starts), 3)


class FreshProcesses(TempDir):
    def test_fsf_seats_restart_every_game_hivemind_seats_persist(self):
        fsf = PlayerFactory(f"fsf,bin={self.fakes.make('f', 'fsf')},net={self.fakes.net},nodes=5",
                            None, None, None)
        hm = PlayerFactory(f"hivemind,bin={self.fakes.make('h', 'hivemind')},"
                           f"model={self.fakes.model},nodes=5", None, None, None)
        config = MatchConfig(pairs=2, clock=ClockConfig(initial_ms=6_000), output=self.dir / "m")
        summary = run_match(config, fsf, hm, log=lambda _: None)
        self.assertEqual(summary["counted_games"], 4)
        starts = lambda name: sum(c.startswith("ARGV") for c in self.fakes.commands(name))  # noqa: E731
        self.assertEqual(starts("f"), 1 + 4 * 2)   # identity probe + two seats per game
        self.assertEqual(starts("h"), 1 + 2)       # identity probe + two persistent seats


class Preflight(TempDir):
    def test_reports_latency_and_whether_movetime_is_honoured(self):
        positions = self.dir / "positions.txt"
        positions.write_text("\n".join((SETS / "preflight.txt").read_text().splitlines()[:6]) + "\n")
        for slow, honoured in ((1, True), (3, False)):
            with self.subTest(slow=slow):
                binary = self.fakes.make(f"hm{slow}", "hivemind", slow=slow)
                report = preflight.run(f"hivemind,bin={binary},model={self.fakes.model},nodes=400",
                                       positions, [40], warmup=2, ort_threads=1, log=lambda _: None)
                self.assertEqual(set(report["phases"]), {"nodes=400", "movetime=40"})
                self.assertEqual(report["phases"]["nodes=400"]["searches"][0]["nodes"], 42)
                self.assertEqual(report["phases"]["movetime=40"]["latency"]["count"], 4)
                self.assertIs(report["movetime_reliably_honoured"], honoured)
                self.assertEqual(report["recommendation"]["mode"],
                                 "same movetime for all arms" if honoured else "matched mean compute")
                self.assertEqual(report["concurrency"], 1)
                self.assertIn("cpu_model", report["environment"])
                self.assertEqual(report["warmup"]["searches"], 2)
                self.assertIn("sha256", report["engine"]["files"]["binary"])
                self.assertTrue(report["complete"])

    def test_timeouts_are_failures_and_the_engine_restarts(self):
        positions = self.dir / "positions.txt"
        positions.write_text("\n".join((SETS / "preflight.txt").read_text().splitlines()[:6]) + "\n")
        binary = self.fakes.make("hmhang", "hivemind", hang_after=3)
        checkpoints = []
        report = preflight.run(f"hivemind,bin={binary},model={self.fakes.model},nodes=400",
                               positions, [20], warmup=0, ort_threads=1, log=lambda _: None,
                               search_timeout=0.3, checkpoint=checkpoints.append)
        nodes = report["phases"]["nodes=400"]
        self.assertEqual((len(nodes["searches"]), nodes["failures"]), (4, 1))
        self.assertTrue(nodes["searches"][3]["timeout"])
        movetime = report["phases"]["movetime=20"]
        self.assertGreaterEqual(movetime["failures"], 1)
        self.assertFalse(movetime["honoured"])
        self.assertGreaterEqual(report["engine"]["restarts_after_failure"], 2)
        self.assertFalse(report["movetime_reliably_honoured"])
        self.assertEqual(len(checkpoints), 2)

    def test_total_runtime_is_bounded(self):
        binary = self.fakes.make("hmslow", "hivemind")
        report = preflight.run(f"hivemind,bin={binary},model={self.fakes.model},nodes=400",
                               SETS / "preflight.txt", [200, 400], warmup=0, ort_threads=1,
                               log=lambda _: None, max_seconds=0.5)
        self.assertFalse(report["complete"])
        self.assertTrue(report["truncated_by_max_seconds"])
        self.assertLess(report["wall_seconds"], 10)


def _engine_files():
    try:
        return EngineSpec.parse("hivemind,nodes=16")
    except Exception:
        return None


@unittest.skipUnless(WANT_ENGINE and _engine_files(), "needs a Hivemind build and --engine")
class RealEngine(unittest.TestCase):
    def test_engine_moves_are_legal_for_the_referee(self):
        players = [HivemindSeat(_engine_files(), ort_threads=1) for _ in range(4)]
        try:
            result = play_game(Bughouse(), dict(enumerate(players)), ClockConfig(),
                               max_decisions=24)
        finally:
            for player in players:
                player.close()
        self.assertIsNone(result.error)
        self.assertIn(result.termination, {"decision limit", "checkmate", "flag", "draw"})
        self.assertGreaterEqual(len(result.moves), 12)
        self.assertTrue(all(player.searches > 0 for player in players))


def _fsf_files(name: str):
    home = hypebeast_home()
    binary, net = home / "bin" / name, home / "nets" / "bughouse-cd8cceab93fe.nnue"
    return (binary, net) if binary.exists() and net.exists() else None


@unittest.skipUnless(WANT_ENGINE and _fsf_files("fsf-ref"), "needs bin/fsf-ref, its net and --engine")
class RealFsf(unittest.TestCase):
    def play(self, contender: str, baseline: str, decisions: int):
        binary, net = _fsf_files("fsf-ref")
        spec = f"fsf,bin={binary},net={net},nodes=2000"
        factories = {"fsf": PlayerFactory(spec, None, None, None),
                     "random": PlayerFactory("random", None, None, None)}
        players = {A_WHITE: factories[contender].make("aw", 1),
                   B_BLACK: factories[contender].make("bb", 2),
                   A_BLACK: factories[baseline].make("ab", 3),
                   B_WHITE: factories[baseline].make("bw", 4)}
        try:
            result = play_game(Bughouse(), players, ClockConfig(), max_decisions=decisions)
        finally:
            for player in players.values():
                player.close()
        return result, players

    def test_unmodified_fsf_plays_legal_moves_with_real_pockets(self):
        result, players = self.play("fsf", "random", 80)
        self.assertIsNone(result.error)
        self.assertNotEqual(result.termination, "illegal move")
        self.assertTrue(players[A_WHITE].nnue_lines)
        self.assertGreater(players[A_WHITE].searches, 5)

    def test_adapter_symmetry_fsf_against_fsf(self):
        result, _ = self.play("fsf", "fsf", 80)
        self.assertIsNone(result.error)
        self.assertNotEqual(result.termination, "illegal move")


if __name__ == "__main__":
    sys.argv = [a for a in sys.argv if a != "--engine"]
    unittest.main(verbosity=2)
