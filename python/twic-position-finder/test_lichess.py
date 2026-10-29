"""Lichess view-URL helper — imported games vs analysis fallback."""

import unittest

from lichess import game_url, view_lichess_url


class ViewLichessUrlTests(unittest.TestCase):
    def test_prefers_imported_url(self):
        self.assertEqual(
            view_lichess_url({
                "lichess_url": "https://lichess.org/abc",
                "pgn_text": "1. e4 e5",
            }),
            "https://lichess.org/abc",
        )

    def test_analysis_fallback_from_pgn(self):
        url = view_lichess_url({"pgn_text": "1. e4 e5"})
        self.assertIsNotNone(url)
        self.assertTrue(url.startswith("https://lichess.org/analysis/pgn/"))
        self.assertIn("1.", url)

    def test_none_without_pgn_or_url(self):
        self.assertIsNone(view_lichess_url({}))
        self.assertIsNone(view_lichess_url({"pgn_text": "  "}))


class GameUrlTests(unittest.TestCase):
    def test_old_game_links_move_under_game(self):
        self.assertEqual(game_url("https://lichess.org/llg88hct"),
                         "https://lichess.org/game/llg88hct")
        self.assertEqual(game_url("http://www.lichess.org/llg88hctAbCd/black"),
                         "https://lichess.org/game/llg88hct/black")

    def test_new_and_other_links_unchanged(self):
        for url in ["https://lichess.org/game/llg88hct",
                    "https://lichess.org/analysis/pgn/1.e4",
                    "https://lichess.org/tournament/abcdefgh",
                    "https://lichess.org/abc"]:
            self.assertEqual(game_url(url), url)

    def test_cached_old_link_is_served_new(self):
        self.assertEqual(
            view_lichess_url({"lichess_url": "https://lichess.org/DHo0Y3zA"}),
            "https://lichess.org/game/DHo0Y3zA",
        )


if __name__ == "__main__":
    unittest.main()
