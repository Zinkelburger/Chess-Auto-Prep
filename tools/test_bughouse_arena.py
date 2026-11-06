#!/usr/bin/env python3
"""Tests for the bughouse arena (tools/bughouse_arena).

Offline and unittest-only beyond python-chess. The referee cases are ported
one-for-one from Hivemind's engine/tests/test_mate_detection.cc, so a change to
the engine's mate rule that is not mirrored here fails loudly. The engine
checks need a Hivemind build and ``--engine``.

Run:
    python3 tools/test_bughouse_arena.py
    python3 tools/test_bughouse_arena.py --engine    # include the slow ones
"""

from __future__ import annotations

import io
import json
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

import chess

sys.path.insert(0, str(Path(__file__).resolve().parent))

from bughouse_arena.match import MatchConfig, PlayerFactory, run_match  # noqa: E402
from bughouse_arena.players import EngineSpec, HivemindSeat, RandomPlayer  # noqa: E402
from bughouse_arena.referee import (BOARD_A, BOARD_B, STARTING_FEN, Bughouse,  # noqa: E402
                                    IllegalMove)
from bughouse_arena.sim import (ClockConfig, MoveCosts, play_game, seat_index,  # noqa: E402
                                time_advantage)
from bughouse_arena.stats import paired_sprt, score_to_elo, summarize  # noqa: E402

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


if __name__ == "__main__":
    sys.argv = [a for a in sys.argv if a != "--engine"]
    unittest.main(verbosity=2)
