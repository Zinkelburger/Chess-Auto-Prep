#!/usr/bin/env python3
"""Offline tests for tools/lichess_broadcasts.py (unittest, no network).

Run:
    python3 tools/test_lichess_broadcasts.py
"""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import lichess_broadcasts as lb  # noqa: E402

TOUR = {
    "id": "GiQfOTDu",
    "name": "Massachusetts Open 2026",
    "slug": "massachusetts-open-2026",
    "info": {"location": "Marlborough, MA"},
    "dates": [1779571116804, 1779740081003],
    "communityOwner": {"name": "falstan"},
}

PGN = """[Event "Round 2: Barnakov, Yury - Ivanov, Alexander"]
[Site "https://lichess.org/broadcast/massachusetts-open-2026/round-2/U9sJaDkK/abc"]
[Date "2026.05.28"]
[Round "2.1"]
[White "Barnakov, Yury"]
[Black "Ivanov, Alexander"]
[Result "1-0"]
[GameURL "https://lichess.org/broadcast/massachusetts-open-2026/round-2/U9sJaDkK/abc"]

1. e4 { [%clk 1:30:00] } 1... c6 { [%clk 1:30:00] } 2. d4 d5 1-0

[Event "Mass Open 2026"]
[Site "Marlborough, MA"]
[Date "2026.05.28"]
[Round "2.2"]
[White "Second, Board"]
[Black "Two, Player"]
[Result "*"]
[GameURL "https://lichess.org/broadcast/massachusetts-open-2026/round-2/U9sJaDkK/def"]

*

[Event "Mass Open 2026"]
[Site "?"]
[Date "2026.05.24"]
[Round "1.3"]
[White "Early, Game"]
[Black "First, Round"]
[Result "1/2-1/2"]

1. d4 Nf6 2. c4 1/2-1/2
"""


class ParseTest(unittest.TestCase):
    def test_splits_games_and_keeps_tag_order(self):
        games = lb.parse_pgn(PGN)
        self.assertEqual(len(games), 3)
        self.assertEqual(list(games[0].tags)[:3], ["Event", "Site", "Date"])
        self.assertTrue(games[0].movetext.startswith("1. e4"))
        self.assertTrue(games[0].has_moves)

    def test_moveless_game_is_not_a_game(self):
        games = lb.parse_pgn(PGN)
        self.assertFalse(games[1].has_moves)
        self.assertTrue(games[2].has_moves)

    def test_render_round_trips(self):
        games = lb.parse_pgn(PGN)
        again = lb.parse_pgn(games[0].render())
        self.assertEqual(again[0].tags, games[0].tags)
        self.assertEqual(again[0].movetext, games[0].movetext)


class NormaliseTest(unittest.TestCase):
    def test_pairing_event_and_url_site_become_the_broadcast(self):
        g = lb.normalise_game(lb.parse_pgn(PGN)[0], TOUR, None)
        self.assertEqual(g.tags["Event"], "Massachusetts Open 2026")
        self.assertEqual(g.tags["Site"], "Marlborough, MA")

    def test_pairing_prefix_that_is_not_a_round_is_kept(self):
        name = "Massachusetts 1st State OPEN Championship"
        self.assertEqual(
            lb.event_name("Qualifier Blitz Playoffs #2: Felix Wu - Emma Zhang", name),
            f"{name} (Qualifier Blitz Playoffs #2)",
        )
        self.assertEqual(lb.event_name("Round 1: A, B - C, D", name), name)
        self.assertEqual(lb.event_name("Board 12: A - B", name), name)
        self.assertEqual(lb.event_name("", name), name)
        self.assertEqual(lb.event_name("Mass Open 2026", name), "Mass Open 2026")
        self.assertEqual(lb.event_name("Cup: Final", name), "Cup: Final")

    def test_real_event_name_is_kept(self):
        g = lb.normalise_game(lb.parse_pgn(PGN)[1], TOUR, None)
        self.assertEqual(g.tags["Event"], "Mass Open 2026")
        self.assertEqual(g.tags["Site"], "Marlborough, MA")

    def test_unknown_site_falls_back_to_collection_site(self):
        tour = dict(TOUR, info={})
        g = lb.normalise_game(lb.parse_pgn(PGN)[2], tour, "Massachusetts, USA")
        self.assertEqual(g.tags["Site"], "Massachusetts, USA")
        g = lb.normalise_game(lb.parse_pgn(PGN)[2], tour, None)
        self.assertEqual(g.tags["Site"], "?")


class GameKeyTest(unittest.TestCase):
    def _game(self, white, black, date, moves, result="1-0"):
        return lb.parse_pgn(
            f'[Event "E"]\n[Date "{date}"]\n[White "{white}"]\n[Black "{black}"]\n'
            f'[Result "{result}"]\n\n{moves} {result}\n'
        )[0]

    def test_name_order_initials_and_dates_do_not_split_a_game(self):
        a = self._game("Zhou, Jianchao", "Pan, Zachary", "2025.09.15", "1. e4 c5 2. Nf3 a6")
        b = self._game("Jianchao Zhou", "Zachary A Pan", "2025.09.21", "1. e4 { [%clk 1:00:00] } 1... c5 2. Nf3 a6")
        self.assertEqual(lb.game_key(a), lb.game_key(b))

    def test_different_result_or_moves_stay_apart(self):
        a = self._game("Wong, Wyatt", "Ivanov, Alexander", "2025.01.01", "1. e4 e5")
        self.assertNotEqual(lb.game_key(a), lb.game_key(self._game("Wong, Wyatt", "Ivanov, Alexander", "2025.01.01", "1. e4 e5", "0-1")))
        self.assertNotEqual(lb.game_key(a), lb.game_key(self._game("Wong, Wyatt", "Ivanov, Alexander", "2025.01.01", "1. d4 e5")))
        self.assertNotEqual(lb.game_key(a), lb.game_key(self._game("Ivanov, Alexander", "Wong, Wyatt", "2025.01.01", "1. e4 e5")))


class MergeTest(unittest.TestCase):
    def test_merge_drops_moveless_dedupes_and_sorts(self):
        games = [lb.normalise_game(g, TOUR, None) for g in lb.parse_pgn(PGN)]
        merged = lb.merge_games([(TOUR, games), (TOUR, games)])
        self.assertEqual(len(merged), 2)
        self.assertEqual([g.tags["Round"] for g in merged], ["1.3", "2.1"])


class FakeFetcher(lb.Fetcher):
    """Serves canned responses; records what was asked."""

    def __init__(self):
        super().__init__(opener=self._serve)
        self.calls: list[str] = []
        self.rounds = [{"id": "r1", "name": "Round 1", "finished": True}]

    def _serve(self, url: str) -> bytes:
        self.calls.append(url)
        if url.endswith("/api/broadcast/GiQfOTDu"):
            return json.dumps({"tour": TOUR, "rounds": self.rounds}).encode()
        if url.endswith("/api/broadcast/GiQfOTDu.pgn"):
            return PGN.encode()
        if "/api/broadcast/by/falstan" in url:
            return json.dumps({"currentPageResults": [{"tour": TOUR}], "nbPages": 1}).encode()
        raise AssertionError(f"unexpected {url}")


class CollectionTest(unittest.TestCase):
    def setUp(self):
        lb.REQUEST_GAP_SECONDS = 0.0
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name) / "massachusetts"

    def tearDown(self):
        self.tmp.cleanup()

    def test_fetch_writes_tour_manifest_and_merged_pgn(self):
        fetcher = FakeFetcher()
        col = lb.Collection(self.dir)
        entry = col.fetch(fetcher, "GiQfOTDu")
        self.assertEqual(entry["games"], 2)
        self.assertTrue(entry["finished"])
        self.assertEqual(entry["owner"], "falstan")
        self.assertEqual(col.merge(), 2)
        col.save()
        manifest = json.loads((self.dir / "manifest.json").read_text())
        self.assertIn("GiQfOTDu", manifest["tours"])
        merged = (self.dir / "massachusetts.pgn").read_text()
        self.assertIn('[Event "Massachusetts Open 2026"]', merged)
        self.assertNotIn("lichess.org/broadcast", merged.split("[Site")[1].split("]")[0])
        self.assertEqual(merged.count("[Event "), 2)

    def test_finished_tour_is_not_refetched_without_refresh(self):
        fetcher = FakeFetcher()
        col = lb.Collection(self.dir)
        col.fetch(fetcher, "GiQfOTDu")
        col.save()
        again = lb.Collection(self.dir)
        n = len(fetcher.calls)
        again.fetch(fetcher, "GiQfOTDu")
        self.assertEqual(len(fetcher.calls), n)
        again.fetch(fetcher, "GiQfOTDu", refresh=True)
        self.assertEqual(len(fetcher.calls), n + 2)

    def test_unfinished_tour_is_refetched(self):
        fetcher = FakeFetcher()
        fetcher.rounds = [{"id": "r1", "name": "Round 1", "finished": False}]
        col = lb.Collection(self.dir)
        col.fetch(fetcher, "GiQfOTDu")
        n = len(fetcher.calls)
        col.fetch(fetcher, "GiQfOTDu")
        self.assertEqual(len(fetcher.calls), n + 2)

    def test_tours_by_user(self):
        fetcher = FakeFetcher()
        self.assertEqual([t["id"] for t in fetcher.tours_by("falstan")], ["GiQfOTDu"])

    def test_cli_by_user(self):
        fetcher = FakeFetcher()
        original = lb.Fetcher
        lb.Fetcher = lambda: fetcher  # type: ignore[assignment]
        try:
            rc = lb.main(["by", "falstan", "--out", str(self.dir)])
        finally:
            lb.Fetcher = original
        self.assertEqual(rc, 0)
        self.assertTrue((self.dir / "massachusetts.pgn").exists())


if __name__ == "__main__":
    unittest.main()
