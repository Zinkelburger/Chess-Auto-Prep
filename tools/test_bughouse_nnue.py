#!/usr/bin/env python3
"""Tests for the bughouse NNUE training-data pipeline.

Offline and dependency-free beyond python-chess (unittest only): the replay,
sampling, labelling and file formats run off an inline BPGN fixture.  The
tests that need the built tools binary skip when it is absent.

Run:
    python3 tools/test_bughouse_nnue.py
"""

from __future__ import annotations

import contextlib
import io
import json
import math
import os
import random
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import chess  # noqa: E402
import chess.variant  # noqa: E402

from bughouse_db.bpgn import iter_games  # noqa: E402
from bughouse_nnue import __main__ as cli  # noqa: E402
from bughouse_nnue import convert, evaluate, extract, records, selfplay  # noqa: E402
from bughouse_nnue.engine import Engine  # noqa: E402
from bughouse_nnue.paths import tools_binary  # noqa: E402

# Board A: 1. e4 d5 2. exd5 -- the pawn goes to BlackB's hand, who drops it.
# Board B: 1. e4 P@e5 2. Nf3 Nc6.  Then Board A continues, and bob (BlackA)
# resigns, so the game ended on board A and WhiteA's team won.
GAME_ONE = (
    '[Event "FICS rated bughouse game"]\r\n'
    '[Date "2016.01.02"]\r\n'
    '[BughouseDBGameNo "100"]\r\n'
    '[WhiteA "alice"][WhiteAElo "2100"]\r\n'
    '[BlackA "bob"][BlackAElo "2050"]\r\n'
    '[WhiteB "carol"][WhiteBElo "1700"]\r\n'
    '[BlackB "dave"][BlackBElo "2200"]\r\n'
    '[Result "1-0"]\r\n'
    "\r\n"
    "{C:This is game number 100 at http://www.bughouse-db.org}\r\n"
    "1A. e4{119.000} 1a. d5{118.000} 2A. exd5{117.000} 1B. e4{119.500} "
    "1b. P@e5{118.900} 2B. Nf3{118.000} 2b. Nc6{117.500} 2a. Qxd5{116.000} "
    "3A. Nc3{115.000} 3a. Qa5{114.000}\r\n"
    "{bob resigns} 1-0\r\n"
    "\r\n"
)

# Same opening, mated on board B, Black's team (0-1) wins; no game number.
GAME_TWO = (
    '[Event "FICS rated bughouse game"]\r\n'
    '[Date "2017.05.06"]\r\n'
    '[WhiteA "eve"][WhiteAElo "2400"]\r\n'
    '[BlackA "mallory"][BlackAElo "2400"]\r\n'
    '[WhiteB "peggy"][WhiteBElo "2400"]\r\n'
    '[BlackB "trent"][BlackBElo "2400"]\r\n'
    '[Result "0-1"]\r\n'
    "\r\n"
    "{C:This is game number 101 at http://www.bughouse-db.org}\r\n"
    "1A. e4{119.000} 1a. d5{118.000} 2A. exd5{117.000} 1B. e4{119.500} "
    "1b. P@e5{118.900} 2B. Nf3{118.000} 2b. Nc6{117.500}\r\n"
    "{peggy checkmated} 0-1\r\n"
    "\r\n"
)

UNRATED = GAME_TWO.replace("FICS rated", "FICS unrated").replace("peggy checkmated", "trent resigns")
NO_CLOSING = GAME_TWO.replace("{peggy checkmated} 0-1", "0-1")


def games(text: str):
    return list(iter_games(io.StringIO(text)))


class Termination(unittest.TestCase):
    def test_closing_comment_and_board(self):
        one, two = games(GAME_ONE + GAME_TWO)
        self.assertEqual(one.termination, "bob resigns")
        self.assertEqual(one.ended_on(), "A")
        self.assertEqual(two.termination, "peggy checkmated")
        self.assertEqual(two.ended_on(), "B")

    def test_clocks_and_banner_are_not_terminations(self):
        (game,) = games(NO_CLOSING)
        self.assertEqual(game.termination, "")
        self.assertIsNone(game.ended_on())

    def test_moves_unchanged(self):
        (game,) = games(GAME_ONE)
        self.assertEqual(game.moves[:4], [("A", "e4"), ("a", "d5"), ("A", "exd5"), ("B", "e4")])
        self.assertEqual(extract.termination_kind("alice forfeits on time"), "forfeits on time")


class Labels(unittest.TestCase):
    def test_result_follows_the_crosswise_teams(self):
        # 1-0 is WhiteA's team: WhiteA and BlackB.
        self.assertEqual(extract.result_for("A", chess.WHITE, 1), 1)
        self.assertEqual(extract.result_for("A", chess.BLACK, 1), -1)
        self.assertEqual(extract.result_for("B", chess.WHITE, 1), -1)
        self.assertEqual(extract.result_for("B", chess.BLACK, 1), 1)
        self.assertEqual(extract.result_for("B", chess.WHITE, -1), 1)
        self.assertEqual(extract.result_for("A", chess.WHITE, 0), 0)

    def test_game_key_is_stable_without_an_id(self):
        (game,) = games(GAME_TWO)
        self.assertEqual(game.game_no, 0)
        self.assertEqual(extract.game_key(game), extract.game_key(games(GAME_TWO)[0]))
        self.assertEqual(extract.game_key(games(GAME_ONE)[0]), 100)


class Replay(unittest.TestCase):
    def snapshots(self, text=GAME_ONE):
        (game,) = games(text)
        stats = extract.new_stats("fixture")
        snaps = extract.replay(game, stats)
        self.assertIsNotNone(snaps)
        return game, snaps, stats

    def test_capture_arrives_on_the_other_board(self):
        _, snaps, stats = self.snapshots()
        # Board B, Black to move at its ply 1: the pawn alice took is in hand.
        before_drop = snaps["B"][1]
        self.assertEqual(before_drop.ply, 1)
        self.assertEqual(before_drop.turn, chess.BLACK)
        self.assertIn("[p]", before_drop.fen)
        self.assertEqual(before_drop.move, "P@e5")
        # Board A's White never gets a pawn: it went to the partner.
        self.assertIn("[]", snaps["A"][2].fen)  # before exd5
        self.assertIn("[]", snaps["A"][3].fen)  # after it, Black to move
        self.assertEqual(stats["arrivals"]["by_piece"], {"P": 2})  # exd5, Qxd5
        self.assertEqual(stats["arrivals"]["by_decile"], {"0": 2})

    def test_ply_counts_each_board_separately(self):
        _, snaps, _ = self.snapshots()
        self.assertEqual([s.ply for s in snaps["A"]], [0, 1, 2, 3, 4, 5])
        self.assertEqual([s.ply for s in snaps["B"]], [0, 1, 2, 3])

    def test_illegal_move_fails_the_game(self):
        (game,) = games(GAME_ONE.replace("1a. d5", "1a. d4"))
        self.assertIsNone(extract.replay(game, extract.new_stats("x")))


class Sampling(unittest.TestCase):
    def sample(self, text, **settings):
        (game,) = games(text)
        snaps = extract.replay(game, extract.new_stats("x"))
        s = extract.Settings(**{"quiet_only": False, **settings})
        out = extract.sample(game, snaps, s, random.Random(1), extract.RESULTS[game.result],
                             game.ended_on())
        return [records.parse(r) for r in out]

    def test_fewer_from_the_board_the_game_did_not_end_on(self):
        recs = self.sample(GAME_ONE, min_elo=0, per_board=4, min_ply=0, other_board=0.5)
        self.assertEqual(len(recs), 6)  # 4 from A (ended there) + 2 from B
        from_b = [r for r in recs if r["move"] in ("e2e4", "P@e5", "g1f3", "b8c6")
                  and not r["fen"].startswith("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR[] w")]
        self.assertLessEqual(len(from_b), 2)

    def test_min_elo_applies_per_board(self):
        # carol (WhiteB) is 1700: board B is out, board A (2100/2050) stays.
        recs = self.sample(GAME_ONE, min_elo=1800, per_board=10, min_ply=0, other_board=1.0)
        self.assertEqual(len(recs), 6)  # every board-A snapshot
        self.assertTrue(all(r["result"] in ("1", "-1") for r in recs))

    def test_labels_are_from_the_side_to_move(self):
        recs = self.sample(GAME_ONE, min_elo=0, per_board=10, min_ply=0, other_board=1.0)
        by_fen = {r["fen"]: r for r in recs}
        start_a = next(r for r in recs if r["fen"].startswith("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR[] w"))
        self.assertEqual(start_a["result"], "1")  # alice to move, her team won
        drop = next(r for r in recs if r["move"] == "P@e5")
        self.assertEqual(drop["result"], "1")  # dave (BlackB) is alice's partner
        white_b = next(r for r in recs if r["move"] == "g1f3")
        self.assertEqual(white_b["result"], "-1")
        self.assertEqual(start_a["score"], "0")
        self.assertEqual(start_a["ply"], "1")
        self.assertTrue(by_fen)

    def test_quiet_only_drops_captures_and_checks(self):
        every = self.sample(GAME_ONE, min_elo=0, per_board=10, min_ply=0, other_board=1.0)
        quiet = self.sample(GAME_ONE, min_elo=0, per_board=10, min_ply=0, other_board=1.0,
                            quiet_only=True)
        self.assertLess(len(quiet), len(every))
        for rec in quiet:
            board = chess.variant.CrazyhouseBoard(rec["fen"])
            self.assertFalse(board.is_check())
            move = chess.Move.from_uci(rec["move"])
            self.assertFalse(move.drop is None and board.is_capture(move))

    def test_min_ply_skips_the_opening(self):
        recs = self.sample(GAME_ONE, min_elo=0, per_board=10, min_ply=3, other_board=1.0)
        self.assertTrue(all(int(r["ply"]) >= 4 for r in recs))
        self.assertEqual(len(recs), 3 + 1)


class YearFile(unittest.TestCase):
    def test_extract_year_writes_records_and_stats(self):
        with tempfile.TemporaryDirectory() as tmp:
            src = Path(tmp) / "export2016.bpgn"
            src.write_text(GAME_ONE + GAME_TWO + UNRATED + NO_CLOSING, encoding="latin-1")
            out = Path(tmp) / "plain"
            out.mkdir()
            settings = extract.Settings(min_elo=0, per_board=2, min_ply=0, other_board=1.0,
                                        validation_percent=1, terminations=(), quiet_only=False)
            name, stats = extract.extract_year((src, out, settings))
            self.assertEqual(name, "export2016.bpgn")
            self.assertEqual(stats["games"], 4)
            self.assertEqual(stats["used"], 3)
            self.assertEqual(stats["skipped"], {"unrated": 1})
            self.assertEqual(stats["ended_on"], {"A": 1, "B": 1, "unknown": 1})
            self.assertEqual(stats["termination"], {"resigns": 1, "checkmated": 1, "unknown": 1})
            train = out / "2016.plain"
            val = out / "2016.val.plain"
            # Game 100 has game_no % 100 == 0 < 1: it is the validation game.
            self.assertEqual(records.count(val), 4)
            self.assertEqual(records.count(train), 8)
            saved = json.loads((out / "2016.stats.json").read_text())
            self.assertEqual(saved["positions"], {"train": 8, "validation": 4})
            self.assertEqual(saved["settings"]["per_board"], 2)
            for text in records.iter_records(train):
                rec = records.parse(text)
                self.assertEqual(set(rec), set(records.FIELDS))
                self.assertRegex(rec["fen"], r"^\S+\[\w*\] [wb] ")


    def test_only_checkmates_by_default(self):
        with tempfile.TemporaryDirectory() as tmp:
            src = Path(tmp) / "export2016.bpgn"
            src.write_text(GAME_ONE + GAME_TWO + NO_CLOSING, encoding="latin-1")
            out = Path(tmp) / "plain"
            out.mkdir()
            settings = extract.Settings(min_elo=0, per_board=2, min_ply=0, quiet_only=False)
            _, stats = extract.extract_year((src, out, settings))
            self.assertEqual(stats["used"], 1)
            self.assertEqual(stats["termination"], {"checkmated": 1})
            self.assertEqual(stats["skipped"], {"termination": 2})
            self.assertEqual(stats["skipped_termination"], {"resigns": 1, "unknown": 1})


class Records(unittest.TestCase):
    TEXT = "fen k7/8/8/8/8/8/8/K7[] w - - 0 1\nmove a1a2\nscore 0\nply 1\nresult 1\ne\n"

    def test_with_score_touches_only_the_score(self):
        self.assertEqual(records.with_score(self.TEXT, -312), self.TEXT.replace("score 0", "score -312"))

    def test_iter_and_count(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "x.plain"
            path.write_text(self.TEXT * 3)
            self.assertEqual(list(records.iter_records(path)), [self.TEXT] * 3)
            self.assertEqual(records.count(path), 3)


class Interleave(unittest.TestCase):
    def test_every_record_once_in_a_shuffled_order(self):
        with tempfile.TemporaryDirectory() as tmp:
            paths = []
            expected = []
            for year in range(3):
                path = Path(tmp) / f"{year}.plain"
                texts = [Records.TEXT.replace("ply 1", f"ply {year * 100 + i}") for i in range(50)]
                path.write_text("".join(texts))
                paths.append(path)
                expected.extend(texts)
            got = list(convert.interleave(paths, random.Random(3), buffer=20))
            self.assertEqual(sorted(got), sorted(expected))
            self.assertNotEqual(got, expected)
            again = list(convert.interleave(paths, random.Random(3), buffer=20))
            self.assertEqual(got, again)


class Summary(unittest.TestCase):
    def test_perfect_signs_beat_chance(self):
        pairs = [(300, 1), (-200, -1), (50, 1), (-900, -1), (0, 0)]
        out = evaluate.summarise(pairs)
        self.assertEqual(out["positions"], 5)
        self.assertEqual(out["decisive"], 4)
        self.assertEqual(out["sign_accuracy"], 1.0)
        self.assertLess(out["log_loss"], math.log(2))

    def test_wrong_signs_are_worse_than_chance(self):
        out = evaluate.summarise([(300, -1), (-300, 1)])
        self.assertEqual(out["sign_accuracy"], 0.0)
        self.assertGreater(out["log_loss"], math.log(2) - 0.01)


class EngineGames(unittest.TestCase):
    def test_a_check_a_drop_could_block_is_not_mate(self):
        # No legal move now, but any piece dropped on b1-g1 blocks the rook.
        board = chess.variant.CrazyhouseBoard("4k3/8/8/8/8/8/PP6/K6r[] w - - 0 1")
        self.assertFalse(any(True for _ in board.legal_moves))
        self.assertTrue(selfplay.could_be_rescued(board))

    def test_contact_mate_is_mate(self):
        board = chess.variant.CrazyhouseBoard("4k3/8/8/8/8/2n5/PP6/Kq6[] w - - 0 1")
        self.assertTrue(board.is_checkmate())
        self.assertFalse(selfplay.could_be_rescued(board))

    def test_a_reused_opening_gets_random_plies_after_it(self):
        settings = selfplay.Settings(opening_plies=10)
        starts = [[("A", "e4")]] * 3
        self.assertIs(selfplay.game_settings(settings, 2, starts), settings)
        reused = selfplay.game_settings(settings, 3, starts)
        self.assertEqual(reused.random_plies, 10 + selfplay.REUSE_RANDOM_PLIES)

    def test_search_refuses_an_unbounded_search(self):
        with self.assertRaises(ValueError):
            Engine.search(None, chess.STARTING_FEN)  # type: ignore[arg-type]

    def test_cli_rejects_unknown_terminations_and_zero_nodes(self):
        with contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit):
                cli.main(["extract", "--terminations", "checkmate"])
            with self.assertRaises(SystemExit):
                cli.main(["selfplay", "--nodes", "0"])


@unittest.skipUnless(tools_binary().exists(), "tools binary not built (python3 -m bughouse_nnue setup)")
class WithEngine(unittest.TestCase):
    def test_trainer_config_has_pockets_and_room_for_arrivals(self):
        from bughouse_nnue import toolchain

        with tempfile.TemporaryDirectory() as tmp:
            files = toolchain.write_trainer_config(tools_binary(), Path(tmp))
            self.assertIn("#define POCKETS true", files["variant.h"])
            self.assertIn(f"#define PIECE_COUNT {toolchain.MAX_PIECES}", files["variant.h"])
            self.assertEqual((Path(tmp) / "variant.h").read_text(), files["variant.h"])
            self.assertIn("USE_POCKETS = True", files["variant.py"])

    def test_search_and_pack(self):
        from bughouse_nnue.engine import Engine
        from bughouse_nnue.paths import VARIANT

        with Engine(tools_binary(), VARIANT, {"Use NNUE": "false"}) as engine:
            score, best = engine.search("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR[Nn] w KQkq - 0 1", 2)
            self.assertIsInstance(score, int)
            self.assertRegex(best, r"^([a-h][1-8][a-h][1-8]|N@[a-h][1-8])$")
            with tempfile.TemporaryDirectory() as tmp:
                plain = Path(tmp) / "x.plain"
                plain.write_text(Records.TEXT.replace("[]", "[Qp]") * 5)
                target = Path(tmp) / "x.bin"
                convert.pack(engine, plain, target)
                self.assertEqual(target.stat().st_size, 5 * 72)


if __name__ == "__main__":
    unittest.main()
