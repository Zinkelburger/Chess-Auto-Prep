"""Lichess view-URL helper — imported games vs analysis fallback."""

import unittest

from lichess import view_lichess_url


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


if __name__ == "__main__":
    unittest.main()
