#!/usr/bin/env python3
"""Tests for `chess_prep.chessgames`: collection parsing and the paced,
resumable download job, against a fake fetcher and a temp data dir.

Run:
    python tools/mcp/test_chessgames.py
"""

from __future__ import annotations

import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from chess_prep import chessgames  # noqa: E402
from chess_prep.chessgames import (  # noqa: E402
    ChessgamesError,
    _write_json,
    classify_pgn_response,
    extract_game_ids,
    extract_title,
    parse_collection_id,
    resolve_collection,
    run_job,
)

PAGE = """<html><head><title>Chess Game Collection: Kasparov on The King&#39;s Indian - chessgames.com</title></head>
<a href="/perl/chessgame?gid=111">x</a> <a href="/perl/chessgame?gid=222">y</a>
<a href="/perl/chessgame?gid=111">again</a> <a href="/perl/chessgame?gid=333">z</a></html>"""


def pgn(gid: str) -> str:
    return f'[Event "E{gid}"]\n[Result "*"]\n\n1.e4 *'


class ParsingTest(unittest.TestCase):
    def test_collection_id_from_url_or_number(self):
        self.assertEqual(parse_collection_id("https://www.chessgames.com/perl/chesscollection?cid=1014220"), "1014220")
        self.assertEqual(parse_collection_id(" 1042947 "), "1042947")
        with self.assertRaises(ChessgamesError):
            parse_collection_id("https://www.chessgames.com/perl/chessgame?gid=5")

    def test_game_ids_in_page_order_without_duplicates(self):
        self.assertEqual(extract_game_ids(PAGE), ["111", "222", "333"])

    def test_title_drops_site_boilerplate(self):
        self.assertEqual(extract_title(PAGE), "Kasparov on The King's Indian")

    def test_soft_ban_is_throttled_not_failed(self):
        self.assertEqual(classify_pgn_response(200, pgn("1"))[0], "ok")
        self.assertEqual(classify_pgn_response(429, "")[0], "throttled")
        self.assertEqual(classify_pgn_response(200, "<html>Too Many Requests</html>")[0], "throttled")
        self.assertEqual(classify_pgn_response(404, "nope")[0], "failed")

    def test_challenge_page_asks_for_saved_html(self):
        with self.assertRaisesRegex(ChessgamesError, "html_file"):
            resolve_collection("9", Path("/x"), fetch=lambda url, ref: (200, "<html>challenge</html>"))


class JobTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        os.environ["CHESS_PREP_DATA_DIR"] = self.tmp.name
        self.out = Path(self.tmp.name) / "out"
        self.collection = resolve_collection("7", self.out, fetch=lambda url, ref: (200, PAGE))
        self.job = chessgames.jobs_dir() / "job1"
        _write_json(self.job / chessgames.JOB_FILE, {"delay_seconds": 22, "collections": [self.collection]})

    def tearDown(self):
        os.environ.pop("CHESS_PREP_DATA_DIR", None)
        self.tmp.cleanup()

    def test_writes_games_in_collection_order_and_backs_off_when_throttled(self):
        answers = {"111": [(429, "")], "222": [(404, "")]}
        sleeps: list[float] = []

        def fetch(url, gid):
            queue = answers.get(gid)
            return queue.pop(0) if queue else (200, pgn(gid))

        status = run_job(self.job, fetch=fetch, sleep=sleeps.append)
        self.assertEqual(status["state"], "done")
        row = status["collections"][0]
        self.assertEqual((row["saved"], row["failed"]), (2, ["222"]))
        text = Path(self.collection["out"]).read_text()
        self.assertLess(text.index("E111"), text.index("E333"))
        self.assertIn(60, sleeps)  # first back-off step
        self.assertTrue(all(s >= 22 for s in sleeps))

    def test_rerun_fetches_only_missing_games(self):
        run_job(self.job, fetch=lambda url, gid: (200, pgn(gid)) if gid != "333" else (404, ""), sleep=lambda s: None)
        asked: list[str] = []

        def fetch(url, gid):
            asked.append(gid)
            return 200, pgn(gid)

        status = run_job(self.job, fetch=fetch, sleep=lambda s: None)
        self.assertEqual(asked, ["333"])
        self.assertEqual(status["collections"][0]["saved"], 3)


if __name__ == "__main__":
    unittest.main()
