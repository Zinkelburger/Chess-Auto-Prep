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
import time
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
    def setUp(self):
        # resolve_collection writes the request ledger: keep it out of the user's data.
        self.tmp = tempfile.TemporaryDirectory()
        os.environ["CHESS_PREP_DATA_DIR"] = self.tmp.name

    def tearDown(self):
        os.environ.pop("CHESS_PREP_DATA_DIR", None)
        self.tmp.cleanup()

    def test_collection_id_from_url_or_number(self):
        self.assertEqual(parse_collection_id("https://www.chessgames.com/perl/chesscollection?cid=1014220"), "1014220")
        self.assertEqual(parse_collection_id(" 1042947 "), "1042947")
        with self.assertRaises(ChessgamesError):
            parse_collection_id("https://www.chessgames.com/perl/chessgame?gid=5")

    def test_game_ids_in_page_order_without_duplicates(self):
        self.assertEqual(extract_game_ids(PAGE), ["111", "222", "333"])

    def test_title_drops_site_boilerplate(self):
        self.assertEqual(extract_title(PAGE), "Kasparov on The King's Indian")

    def test_ban_pages_are_bans_and_maintenance_is_throttled(self):
        self.assertEqual(classify_pgn_response(200, pgn("1"))[0], "ok")
        self.assertEqual(classify_pgn_response(429, "")[0], "banned")
        self.assertEqual(classify_pgn_response(403, "")[0], "banned")
        self.assertEqual(
            classify_pgn_response(200, "<html>You have had too many requests. Please email us</html>")[0],
            "banned",
        )
        self.assertEqual(classify_pgn_response(503, "")[0], "throttled")
        self.assertEqual(classify_pgn_response(200, "<html>under maintenance</html>")[0], "throttled")
        self.assertEqual(classify_pgn_response(404, "nope")[0], "failed")

    def test_challenge_page_asks_for_saved_html(self):
        with self.assertRaisesRegex(ChessgamesError, "html_file"):
            resolve_collection("9", Path("/x"), fetch=lambda url, ref: (200, "<html>challenge</html>"))


class FakeClock:
    """A clock that `sleep` advances, so ledger gaps pass instantly."""

    def __init__(self):
        self.now = time.time()
        self.sleeps: list[float] = []

    def __call__(self) -> float:
        return self.now

    def sleep(self, seconds: float) -> None:
        self.sleeps.append(seconds)
        self.now += seconds


class JobTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        os.environ["CHESS_PREP_DATA_DIR"] = self.tmp.name
        self.out = Path(self.tmp.name) / "out"
        self.collection = resolve_collection("7", self.out, fetch=lambda url, ref: (200, PAGE))
        self.job = chessgames.jobs_dir() / "job1"
        _write_json(self.job / chessgames.JOB_FILE, {"delay_seconds": chessgames.DEFAULT_DELAY, "collections": [self.collection]})

    def tearDown(self):
        os.environ.pop("CHESS_PREP_DATA_DIR", None)
        self.tmp.cleanup()

    def test_writes_games_in_collection_order_and_backs_off_when_throttled(self):
        answers = {"111": [(503, "")], "222": [(404, "")]}
        clock = FakeClock()

        def fetch(url, gid):
            queue = answers.get(gid)
            return queue.pop(0) if queue else (200, pgn(gid))

        status = run_job(self.job, fetch=fetch, sleep=clock.sleep, clock=clock)
        self.assertEqual(status["state"], "done")
        row = status["collections"][0]
        self.assertEqual((row["saved"], row["failed"]), (2, ["222"]))
        text = Path(self.collection["out"]).read_text()
        self.assertLess(text.index("E111"), text.index("E333"))
        self.assertIn(60, clock.sleeps)  # first back-off step

    def test_ban_stops_the_job_and_blocks_the_next_run(self):
        asked: list[str] = []

        def fetch(url, gid):
            asked.append(gid)
            return (200, "<html>You have had too many requests.</html>") if gid == "222" else (200, pgn(gid))

        clock = FakeClock()
        status = run_job(self.job, fetch=fetch, sleep=clock.sleep, clock=clock)
        self.assertEqual(status["state"], "banned")
        self.assertEqual(asked, ["111", "222"], "no retry and no next game after a ban")
        self.assertEqual(status["collections"][0]["saved"], 1)

        status = run_job(self.job, fetch=fetch, sleep=clock.sleep, clock=clock)
        self.assertEqual(status["state"], "banned")
        self.assertEqual(asked, ["111", "222"], "the cooldown refuses before any request")
        self.assertIsNotNone(chessgames.blocked_message(clock()))

        clock.now += chessgames.BAN_COOLDOWN
        status = run_job(self.job, fetch=lambda url, gid: (200, pgn(gid)), sleep=clock.sleep, clock=clock)
        self.assertEqual(status["state"], "done")

    def test_requests_stay_apart_across_runs(self):
        clock = FakeClock()
        times: list[float] = []

        def fetch(url, gid):
            times.append(clock())
            return 200, pgn(gid)

        run_job(self.job, fetch=fetch, sleep=clock.sleep, clock=clock)
        gaps = [b - a for a, b in zip(times, times[1:])]
        self.assertTrue(all(g >= chessgames.DEFAULT_DELAY for g in gaps), gaps)

    def test_daily_limit_blocks_further_requests(self):
        clock = FakeClock()
        clock.now += chessgames.MIN_GAP  # past setUp's collection-page request
        for _ in range(chessgames.DAILY_LIMIT - 1):
            self.assertEqual(chessgames.reserve_request(clock()), 0.0)
            clock.now += chessgames.MIN_GAP
        self.assertIn("daily limit", chessgames.blocked_message(clock()))
        status = run_job(self.job, fetch=lambda url, gid: (200, pgn(gid)), sleep=clock.sleep, clock=clock)
        self.assertEqual(status["state"], "banned")

    def test_rerun_fetches_only_missing_games(self):
        clock = FakeClock()
        run_job(self.job, fetch=lambda url, gid: (200, pgn(gid)) if gid != "333" else (404, ""),
                sleep=clock.sleep, clock=clock)
        asked: list[str] = []

        def fetch(url, gid):
            asked.append(gid)
            return 200, pgn(gid)

        status = run_job(self.job, fetch=fetch, sleep=clock.sleep, clock=clock)
        self.assertEqual(asked, ["333"])
        self.assertEqual(status["collections"][0]["saved"], 3)


if __name__ == "__main__":
    unittest.main()
