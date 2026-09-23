#!/usr/bin/env python3
"""Offline tests for tools/lichess_broadcast_archive.py.

    python3 tools/test_lichess_broadcast_archive.py
"""

from __future__ import annotations

import shutil
import sqlite3
import subprocess
import sys
import tempfile
import unittest
import zlib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import lichess_broadcast_archive as arc  # noqa: E402

MONTH = """[Event "World Open"]
[Site "https://lichess.org/broadcast/x"]
[Round "9.250"]
[White "Bernal, Andrew"]
[Black "Waters, Kai"]
[Result "1-0"]
[Variant "Standard"]
[UTCDate "2026.07.05"]
[WhiteFideId "30992060"]
[Opening "Queen's Pawn"]

1. d4 { [%clk 1:30:00] } 1... d5 { [%clk 1:30:00] } 2. Nf3 (2. c4 e6) 2... Nf6 $1 3. e3 1-0


[Event "Fischer Random"]
[White "A, B"]
[Black "C, D"]
[Result "1-0"]
[Variant "Chess960"]
[FEN "bbqnnrkr/pppppppp/8/8/8/8/PPPPPPPP/BBQNNRKR w HFhf - 0 1"]

1. e4 1-0


[Event "TCEC"]
[White "Stockfish"]
[Black "Leela"]
[Result "1/2-1/2"]
[WhiteTitle "BOT"]
[Variant "Standard"]

1. e4 e5 1/2-1/2


[Event "Mirror of the TWIC game"]
[White "Zhou Jianchao"]
[Black "Pan, Zachary"]
[Result "1-0"]
[Variant "Standard"]
[UTCDate "2025.09.21"]

1. e4 c5 2. Nf3 a6 1-0


[Event "Same moves, other people"]
[White "Somebody, Else"]
[Black "Pan, Zachary"]
[Result "1-0"]
[Variant "Standard"]

1. e4 c5 2. Nf3 a6 1-0
"""


class Parsing(unittest.TestCase):
    def test_sans_drops_comments_variations_numbers_and_nags(self):
        self.assertEqual(
            arc.sans("1. d4 { [%clk 1:30:00] } 1... d5 2. Nf3 (2. c4 e6 (2... c6)) 2... Nf6 $1 3. e3!? 1-0"),
            ["d4", "d5", "Nf3", "Nf6", "e3"],
        )

    def test_games_and_reasons(self):
        games = list(arc.games_in(MONTH.splitlines(True)))
        self.assertEqual(len(games), 5)
        reasons = [arc.keep_reason(t, arc.sans(m)) for t, m in games]
        self.assertEqual(reasons, [None, "variant", "engine", None, None])

    def test_render_takes_the_date_from_utc_and_drops_a_url_site(self):
        tags, movetext = next(arc.games_in(MONTH.splitlines(True)))
        out = arc.render(tags, arc.sans(movetext), "1-0")
        self.assertIn('[Date "2026.07.05"]', out)
        self.assertIn('[Site "?"]', out)
        self.assertIn('[WhiteFideId "30992060"]', out)
        self.assertNotIn("Opening", out)
        pairing = arc.render(
            {"Event": "Round 2: Denys K Shmelov - Zhu, Linxi", "BroadcastName": "Summer Open"},
            ["e4"], "1-0",
        )
        self.assertIn('[Event "Summer Open"]', pairing)
        self.assertIn("1. d4 d5 2. Nf3 Nf6 3. e3 1-0", out)


class Dedupe(unittest.TestCase):
    def test_name_forms_match_but_strangers_do_not(self):
        seen = arc.Seen()
        seen.add(["e4", "c5", "Nf3", "a6"], "1-0", "Zhou, Jianchao")
        self.assertTrue(seen.has(["e4", "c5", "Nf3", "a6"], "1-0", "Zhou Jianchao"))
        self.assertFalse(seen.has(["e4", "c5", "Nf3", "a6"], "1-0", "Somebody, Else"))
        self.assertFalse(seen.has(["e4", "c5", "Nf3", "a6"], "0-1", "Zhou Jianchao"))
        seen.add(["d4"], "1-0", "Shmeliov,D")
        self.assertTrue(seen.has(["d4"], "1-0", "Shmeliov, Denis"))


@unittest.skipUnless(shutil.which("zstd"), "needs the zstd command")
class Build(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.cache = root / "cache"
        self.cache.mkdir()
        (root / "month.pgn").write_text(MONTH)
        subprocess.run(
            ["zstd", "-q", str(root / "month.pgn"), "-o",
             str(self.cache / "lichess_db_broadcast_2025-09.pgn.zst")],
            check=True,
        )
        # A "TWIC" that already has the Zhou game.
        self.twic = root / "master_games.db"
        c = sqlite3.connect(self.twic)
        c.executescript(
            "CREATE TABLE games(white TEXT, result TEXT, movetext BLOB);"
            "CREATE TABLE meta(key TEXT PRIMARY KEY, value BLOB);"
        )
        c.execute(
            "INSERT INTO games VALUES('Zhou, Jianchao', '1-0', ?)",
            (zlib.compress(b"1. e4 c5 2. Nf3 a6"),),
        )
        c.commit()
        c.close()
        self.root = root / "lichess_broadcasts" / "lichess-official"

    def tearDown(self):
        self.tmp.cleanup()

    def test_keeps_only_new_standard_human_games(self):
        import os
        from unittest import mock

        with mock.patch.dict(
            os.environ,
            {"CHESS_PREP_BROADCAST_CACHE": str(self.cache), "CHESS_PREP_MASTER_DB": str(self.twic)},
        ):
            manifest = arc.build(self.root, list(self.cache.glob("*.zst")), import_db=False)
        self.assertEqual(
            manifest["totals"],
            {"read": 5, "kept": 2, "variant": 1, "engine": 1, "no_moves": 0, "duplicate": 1},
        )
        kept = (self.root / "months" / "2025-09.pgn").read_text()
        self.assertIn("Bernal, Andrew", kept)
        self.assertIn("Somebody, Else", kept)
        self.assertNotIn("Zhou", kept)


if __name__ == "__main__":
    unittest.main()
