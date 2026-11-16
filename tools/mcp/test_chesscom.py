#!/usr/bin/env python3
"""Tests for `chess_prep.chesscom`: finding a chess.com account from rating
clues without touching the network.

The property that matters is the opponent-graph path: a player who is *not*
on any leaderboard page must still be found because their post-game rating
appears in a leaderboard player's archive, and must then be verified from
their own archive. Everything runs against a fake fetcher and a temp cache.

Run:
    python tools/mcp/test_chesscom.py
"""

from __future__ import annotations

import datetime as dt
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from chess_prep import chesscom  # noqa: E402
from chess_prep.chesscom import (  # noqa: E402
    Index,
    day_window,
    months_covering,
    parse_clues,
    ratings_seen,
    run_search,
    san_moves,
)

UTC = dt.timezone.utc


def ts(year: int, month: int, day: int, hour: int = 12) -> int:
    return int(dt.datetime(year, month, day, hour, tzinfo=UTC).timestamp())


SCOTCH = "1. e4 {[%clk 0:03:00]} 1... e5 {[%clk 0:02:59]} 2. Nf3 {[%clk 0:02:58]} 2... Nc6 3. d4 exd4 4. Nxd4 Nf6 5. Nxc6 bxc6 6. Bd3 d5 1-0"
ITALIAN = "1. e4 e5 2. Nf3 Nc6 3. Bc4 Bc5 4. c3 Nf6 0-1"


def game(white: str, wr: int, black: str, br: int, end: int, pgn: str = SCOTCH, time_class: str = "blitz") -> dict:
    return {
        "rules": "chess",
        "time_class": time_class,
        "end_time": end,
        "white": {"username": white, "rating": wr},
        "black": {"username": black, "rating": br},
        "pgn": "[Event \"Live Chess\"]\n\n" + pgn,
    }


class FakeFetch:
    """URL → payload, counting requests. Unknown archive months are empty
    (as chess.com answers 404 → None for a month with no games)."""

    def __init__(self, routes: dict[str, object]) -> None:
        self.routes = routes
        self.calls: list[str] = []

    def __call__(self, url: str):
        self.calls.append(url)
        if url in self.routes:
            return self.routes[url]
        if "/games/" in url or "leaderboard" in url:
            return None
        raise AssertionError(f"unexpected request {url}")


def archive_url(user: str, ym: str) -> str:
    y, m = ym.split("-")
    return f"{chesscom.PUBLIC_API}/player/{user}/games/{y}/{m}"


def leaderboard_url(category: str, page: int) -> str:
    return f"{chesscom.LEADERBOARD_CALLBACK}/{category}?page={page}"


def leaders(rows: list[tuple]) -> dict:
    return {
        "leaders": [
            {"rank": rank, "score": score, "user": {"username": name, "chess_title": title, "country_name": country}}
            for rank, name, score, title, country in rows
        ]
    }


class TempCache(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        os.environ["CHESS_PREP_CHESSCOM_DIR"] = str(self.root)
        self.addCleanup(self.tmp.cleanup)
        self.addCleanup(os.environ.pop, "CHESS_PREP_CHESSCOM_DIR", None)


# ── Parsing ─────────────────────────────────────────────────────────────────


class Parsing(unittest.TestCase):
    def test_san_moves_strips_clocks_numbers_results_and_checks(self):
        self.assertEqual(
            san_moves(SCOTCH),
            ["e4", "e5", "Nf3", "Nc6", "d4", "exd4", "Nxd4", "Nf6", "Nxc6", "bxc6", "Bd3", "d5"],
        )
        self.assertEqual(san_moves("1.e4 e5 2.Nf3 Nc6 3.Bb5+ a6#"), ["e4", "e5", "Nf3", "Nc6", "Bb5", "a6"])
        self.assertEqual(san_moves(""), [])
        self.assertEqual(len(san_moves(" ".join(["a1"] * 40))), chesscom.OPENING_PLIES)

    def test_us_window_spans_every_us_zone(self):
        start, end = day_window(dt.date(2026, 6, 13), "US")
        self.assertEqual(start, ts(2026, 6, 13, 4))  # midnight Eastern
        self.assertEqual(end, ts(2026, 6, 14, 10))  # midnight Hawaii, next day
        self.assertEqual(day_window(dt.date(2026, 6, 13), "UTC"), (ts(2026, 6, 13, 0), ts(2026, 6, 14, 0)))
        ny = day_window(dt.date(2026, 6, 13), "America/New_York")
        self.assertEqual(ny, (ts(2026, 6, 13, 4), ts(2026, 6, 14, 4)))
        with self.assertRaises(chesscom.ChesscomError):
            day_window(dt.date(2026, 6, 13), "Mars/Olympus")

    def test_months_include_lead_for_the_last_game_before_the_window(self):
        self.assertEqual(months_covering(ts(2026, 6, 13), ts(2026, 6, 14)), ["2026-06"])
        self.assertEqual(months_covering(ts(2026, 6, 1, 4), ts(2026, 6, 2, 10)), ["2026-05", "2026-06"])
        self.assertEqual(months_covering(ts(2026, 12, 31), ts(2027, 1, 1, 10)), ["2026-12", "2027-01"])

    def test_ratings_seen(self):
        events = [(10, 2690), (20, 2701), (30, 2710), (40, 2705)]
        self.assertEqual(ratings_seen(events, (25, 35)), (2701, [2710]))
        self.assertEqual(ratings_seen(events, (5, 15)), (None, [2690]))
        self.assertEqual(ratings_seen(events, (50, 60)), (2705, []))

    def test_clues_are_validated(self):
        clues = parse_clues('[{"rating": 2701, "date": "2026-06-13"}]', "US")
        self.assertEqual(clues[0]["category"], "blitz")
        self.assertEqual(clues[0]["months"], ["2026-06"])
        for bad in ("[]", '[{"rating": "x", "date": "2026-06-13"}]', '[{"rating": 1, "date": "June 13"}]',
                    '[{"category": "daily", "rating": 1, "date": "2026-06-13"}]'):
            with self.assertRaises(chesscom.ChesscomError):
                parse_clues(bad, "US")


# ── Index ───────────────────────────────────────────────────────────────────


class IndexBehaviour(TempCache):
    def test_opponent_ratings_are_indexed_and_matched(self):
        index = Index(self.root)
        self.addCleanup(index.close)
        june13 = ts(2026, 6, 13, 20)
        index.store_archive("Alice", "2026-06", {"games": [
            game("Alice", 2650, "Bob", 2695, june13 - 3600),
            game("Bob", 2701, "Alice", 2644, june13),
            game("Alice", 2650, "Carol", 2500, june13 + 3600, pgn=ITALIAN, time_class="bullet"),
        ]})
        self.assertTrue(index.has_archive("alice", "2026-06"))
        self.assertFalse(index.has_archive("bob", "2026-06"))

        clue = parse_clues([{"rating": 2701, "date": "2026-06-13"}], "US")[0]
        found = index.matches(clue)
        self.assertIn("bob", found)
        self.assertFalse(found["bob"]["complete"], "opponent-derived until Bob's own archive is cached")
        self.assertEqual(found["bob"]["during"], [2695, 2701])
        self.assertNotIn("alice", found)

        # Alice's rating in force when the window opened (her last blitz game) counts too.
        clue14 = parse_clues([{"rating": 2644, "date": "2026-06-14"}], "US")[0]
        self.assertIn("alice", index.matches(clue14))
        self.assertTrue(index.matches(clue14)["alice"]["complete"])

        # Bullet games never satisfy a blitz clue.
        self.assertEqual(index.matches(parse_clues([{"rating": 2500, "date": "2026-06-13"}], "US")[0]), {})

    def test_who_plays_and_opening_counts(self):
        index = Index(self.root)
        self.addCleanup(index.close)
        t = ts(2026, 6, 13)
        index.store_archive("alice", "2026-06", {"games": [
            game("alice", 2650, "bob", 2700, t),
            game("alice", 2650, "bob", 2700, t + 1, pgn=ITALIAN),
            game("bob", 2700, "alice", 2650, t + 2),
        ]})
        rows = index.who_plays(san_moves("1.e4 e5 2.Nf3 Nc6 3.d4"), "white")
        self.assertEqual([(r["username"], r["games_with_line"], r["games_as_white"]) for r in rows],
                         [("alice", 1, 2), ("bob", 1, 1)])
        self.assertEqual(index.opening_count("bob", ["e4", "e5"], "black"), {"games_with_line": 2, "games_as_black": 2})
        self.assertEqual(index.who_plays(["d4"], "white"), [])
        self.assertEqual(index.activity("bob")["games"], {"blitz": 3})

    def test_dropped_in_files_from_an_older_cache_are_indexed(self):
        index = Index(self.root)
        self.addCleanup(index.close)
        (self.root / "archives" / "the_root_beer_float_2026-06.json").write_text(json.dumps(
            {"games": [game("the_root_beer_float", 2701, "x", 2600, ts(2026, 6, 13, 20))]}
        ))
        (self.root / "archives" / "nobody_2026-05.json").write_text("null")
        pending = index.pending_files()
        self.assertEqual([p.name for p in pending], ["nobody_2026-05.json", "the_root_beer_float_2026-06.json"])
        for path in pending:
            index.index_file(path)
        self.assertEqual(index.pending_files(), [])
        self.assertTrue(index.has_archive("nobody", "2026-05"))
        clue = parse_clues([{"rating": 2701, "date": "2026-06-13"}], "US")[0]
        self.assertEqual(list(index.matches(clue)), ["the_root_beer_float"])
        self.assertEqual(index.stats()["archives"], 2)

    def test_an_unreadable_archive_is_set_aside_not_indexed_as_empty(self):
        index = Index(self.root)
        self.addCleanup(index.close)
        torn = '{"games": [{"rules": "chess", "time_class": "blitz", "end_ti'
        (self.root / "archives" / "bob_2026-06.json").write_text(torn)
        for path in index.pending_files():
            index.index_file(path)
        # Not "cached with no games": the month is fetched again next time.
        self.assertFalse(index.has_archive("bob", "2026-06"))
        self.assertEqual(index.pending_files(), [])
        kept = [p for p in (self.root / "archives").iterdir() if p.name != "bob_2026-06.json"]
        self.assertEqual([p.read_text() for p in kept], [torn])
        fetch = FakeFetch({archive_url("bob", "2026-06"): {"games": []}})
        self.assertTrue(index.ensure_archive("bob", "2026-06", fetch))

    def test_leaderboard_band_bisects_then_reads_forward(self):
        index = Index(self.root)
        self.addCleanup(index.close)
        pages = {}
        for page in range(1, 41):
            rows = [(50 * (page - 1) + i + 1, f"p{page}_{i}", 3000 - (50 * (page - 1) + i) * 2, None, "United States")
                    for i in range(50)]
            pages[leaderboard_url("blitz", page)] = leaders(rows)
        fetch = FakeFetch(pages)
        band = index.leaderboard_band("blitz", 2700, 2750, fetch)
        self.assertEqual({r[2] for r in band}, set(range(2700, 2751, 2)))
        self.assertLess(len(fetch.calls), 20, "bisection, not a linear crawl")
        again = index.leaderboard_band("blitz", 2700, 2750, fetch)
        self.assertEqual(len(again), len(band))
        self.assertLess(len(fetch.calls), 25, "fresh pages are served from the cache")


# ── The search job ──────────────────────────────────────────────────────────


class SearchJob(TempCache):
    def routes(self) -> dict:
        june13, june20 = ts(2026, 6, 13, 22), ts(2026, 6, 20, 23)
        return {
            leaderboard_url("blitz", 1): leaders([
                (1, "Star", 2900, "GM", "Norway"),
                (2, "Alice", 2710, "IM", "United States"),
                (3, "Zed", 2705, None, "Germany"),
            ]),
            # Alice's June: she plays Bob, whose post-game ratings hit both clues.
            archive_url("alice", "2026-06"): {"games": [
                game("Alice", 2700, "Bob", 2701, june13),
                game("Bob", 2724, "Alice", 2690, june20),
            ]},
            archive_url("zed", "2026-06"): {"games": [game("Zed", 2705, "Alice", 2700, june13 + 5)]},
            archive_url("star", "2026-06"): {"games": []},
            # Bob's own archive confirms both readings.
            archive_url("bob", "2026-06"): {"games": [
                game("Bob", 2690, "Alice", 2700, june13 - 100),
                game("Alice", 2700, "Bob", 2701, june13),
                game("Bob", 2724, "Alice", 2690, june20),
            ]},
            f"{chesscom.PUBLIC_API}/player/bob": {"username": "Bob", "country": "https://api.chess.com/pub/country/US",
                                                  "joined": ts(2024, 1, 5), "last_online": ts(2026, 9, 1)},
            f"{chesscom.PUBLIC_API}/player/bob/stats": {"chess_blitz": {
                "last": {"rating": 2507, "date": ts(2026, 9, 1)},
                "best": {"rating": 2724, "date": june20},
                "record": {"win": 1, "loss": 2, "draw": 3}}},
        }

    def job(self, **spec) -> Path:
        job = self.root / "searches" / "test"
        job.mkdir(parents=True)
        base = {"clues": [{"rating": 2701, "date": "2026-06-13"}, {"rating": 2724, "date": "2026-06-20"}],
                "band": 100, "max_requests": 100}
        chesscom._write_json(job / chesscom.SEARCH_FILE, {**base, **spec})
        return job

    def test_finds_an_account_that_is_not_on_the_leaderboard(self):
        fetch = FakeFetch(self.routes())
        results = run_search(self.job(opening="1.e4 e5 2.Nf3 Nc6 3.d4"), fetch=fetch)
        self.assertEqual(results["state"], "done")
        self.assertEqual([h["username"] for h in results["hits"]], ["bob"])
        hit = results["hits"][0]
        self.assertTrue(hit["complete"])
        self.assertEqual(hit["profile"]["country"], "US")
        self.assertEqual(hit["profile"]["ratings"]["blitz"]["best"], 2724)
        self.assertEqual(hit["opening"]["games_with_line"], 2)
        self.assertEqual([c["during"] for c in hit["clues"]], [[2690, 2701], [2724]])
        self.assertIn(archive_url("bob", "2026-06"), fetch.calls, "verified from Bob's own archive")
        self.assertFalse(results["budget"]["exhausted"])
        self.assertEqual(results["verified_hits"], 1)
        progress = json.loads((self.root / "searches" / "test" / chesscom.PROGRESS_FILE).read_text())
        self.assertEqual(progress["state"], "done")

    def test_country_filter_narrows_the_pool_but_not_opponent_hits(self):
        fetch = FakeFetch(self.routes())
        results = run_search(self.job(country="Germany"), fetch=fetch)
        self.assertNotIn(archive_url("star", "2026-06"), fetch.calls)
        self.assertNotIn(archive_url("alice", "2026-06"), fetch.calls)
        self.assertIn(archive_url("zed", "2026-06"), fetch.calls)
        # Zed's archive only shows Alice at 2700, so Bob is never sighted.
        self.assertEqual(results["hits"], [])

    def test_budget_stops_cleanly_and_a_rerun_resumes_from_cache(self):
        fetch = FakeFetch(self.routes())
        first = run_search(self.job(max_requests=12), fetch=fetch)
        self.assertEqual(first["state"], "done")
        self.assertTrue(first["budget"]["exhausted"])
        spent = len(fetch.calls)
        second = run_search(self.root / "searches" / "test", fetch=fetch)
        self.assertEqual([h["username"] for h in second["hits"]], ["bob"])
        self.assertLess(len(fetch.calls) - spent, spent, "the rerun reused cached pages and archives")

    def test_matches_are_visible_from_a_second_connection_mid_job(self):
        fetch = FakeFetch(self.routes())
        run_search(self.job(), fetch=fetch)
        reader = Index(self.root)
        self.addCleanup(reader.close)
        clues = parse_clues([{"rating": 2701, "date": "2026-06-13"}], "US")
        self.assertEqual(list(reader.matches_all(clues)), ["bob"])


# ── Registry ────────────────────────────────────────────────────────────────


class Tools(TempCache):
    def test_tools_are_registered_and_status_lists_nothing(self):
        from chess_prep.tools import Registry, ToolError

        registry = Registry()
        self.addCleanup(registry.close)
        names = [n for n in registry.tools if n.startswith("chesscom_")]
        self.assertEqual(names, ["chesscom_profile", "chesscom_rating_on", "chesscom_who_plays",
                                 "chesscom_search", "chesscom_search_status", "chesscom_search_stop"])
        status = registry.call("chesscom_search_status", {})
        self.assertEqual(status["searches"], [])
        self.assertEqual(status["index"]["archives"], 0)
        with self.assertRaises(ToolError):
            registry.call("chesscom_search_status", {"id": "nope"})
        with self.assertRaises(ToolError):
            registry.call("chesscom_search", {"clues": [{"rating": 1, "date": "yesterday"}]})
        with self.assertRaises(ToolError):
            registry.call("chesscom_who_plays", {"opening": ""})

    def test_who_plays_reads_the_cache_without_requests(self):
        from chess_prep.tools import Registry

        index = Index(self.root)
        index.store_archive("alice", "2026-06", {"games": [game("alice", 1, "bob", 2, ts(2026, 6, 1))]})
        index.close()
        registry = Registry()
        self.addCleanup(registry.close)
        out = registry.call("chesscom_who_plays", {"opening": "1. e4 e5 2. Nf3", "side": "black"})
        self.assertEqual([p["username"] for p in out["players"]], ["bob"])


class ToolInputs(TempCache):
    """What an agent passes in is a name, never a path."""

    def setUp(self) -> None:
        super().setUp()
        from chess_prep.tools import Registry

        # Two levels down, so a `../..` escape still lands inside the temp dir.
        self.cache = self.root / "deep" / "cache"
        os.environ["CHESS_PREP_CHESSCOM_DIR"] = str(self.cache)
        self.registry = Registry()
        self.addCleanup(self.registry.close)
        self.fetched: list[str] = []

        def fetch(url: str):
            self.fetched.append(url)
            if url.endswith("/stats"):
                return {}
            if "/games/" in url:
                return {"games": []}
            return {"username": "x"}

        from unittest import mock

        patch = mock.patch.object(chesscom, "fetch_json", fetch)
        patch.start()
        self.addCleanup(patch.stop)

    def files_outside_archives(self) -> list[str]:
        archives = self.cache / "archives"
        return sorted(
            str(p.relative_to(self.root))
            for p in self.root.rglob("*.json")
            if archives not in p.parents and (self.cache / "searches") not in p.parents
        )

    def test_a_username_with_path_parts_is_refused(self):
        from chess_prep.tools import ToolError

        for name in ("../../escape", "a/b", "..\\x", "a b"):
            with self.subTest(username=name):
                with self.assertRaises(ToolError):
                    self.registry.call(
                        "chesscom_rating_on", {"username": name, "date": "2026-06-13"}
                    )
                with self.assertRaises(ToolError):
                    self.registry.call("chesscom_profile", {"username": name})
        self.assertEqual(self.files_outside_archives(), [])
        self.assertEqual(self.fetched, [])

    def test_a_real_username_still_works(self):
        out = self.registry.call(
            "chesscom_rating_on", {"username": "@Some_Player-1", "date": "2026-06-13"}
        )
        self.assertEqual(out["username"], "Some_Player-1")

    def test_a_search_id_with_path_parts_is_refused(self):
        from chess_prep.tools import ToolError

        outside = self.cache / "elsewhere"
        outside.mkdir(parents=True)
        (outside / chesscom.SEARCH_FILE).write_text(json.dumps({"clues": []}))
        (self.cache / "searches").mkdir()
        for tool in ("chesscom_search_status", "chesscom_search_stop"):
            with self.subTest(tool=tool):
                with self.assertRaises(ToolError):
                    self.registry.call(tool, {"id": "../elsewhere"})


class StoppingAJob(TempCache):
    """The server started the job, so a finished job is the server's own
    unreaped child until somebody waits for it."""

    def test_stop_reports_a_stopped_job_as_stopped(self):
        import subprocess
        import time

        from chess_prep.tools import Registry

        child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])
        self.addCleanup(lambda: child.poll() is None and child.kill())
        job = self.root / "searches" / "20260613-000000-test"
        job.mkdir(parents=True)
        (job / chesscom.SEARCH_FILE).write_text(json.dumps({"clues": []}))
        (job / chesscom.PROGRESS_FILE).write_text(
            json.dumps({"state": "scanning", "pid": child.pid})
        )
        registry = Registry()
        self.addCleanup(registry.close)
        started = time.monotonic()
        out = registry.call("chesscom_search_stop", {"id": job.name})
        self.assertTrue(out["stopped"], out)
        self.assertLess(time.monotonic() - started, 5)

    def test_a_killed_job_does_not_block_the_next_search(self):
        import signal
        import subprocess
        import time

        child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])
        os.kill(child.pid, signal.SIGKILL)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:  # dead, but not yet reaped
            with open(f"/proc/{child.pid}/stat") as stat:
                if stat.read().split()[2] == "Z":
                    break
            time.sleep(0.05)
        self.assertFalse(chesscom._pid_alive(child.pid))


if __name__ == "__main__":
    unittest.main()
