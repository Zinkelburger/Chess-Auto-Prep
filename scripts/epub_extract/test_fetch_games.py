#!/usr/bin/env python3
"""The 365chess result parser: real pages have attributes with no value."""
import unittest

from fetch_games import MoveExtractor


class MoveExtractorTest(unittest.TestCase):
    def test_a_link_with_a_bare_href_is_ignored(self):
        parser = MoveExtractor()
        parser.feed('<a href>skip</a><a href="javascript:GoToMove(1)">e4</a>')
        self.assertEqual(parser.moves, ['e4'])


if __name__ == '__main__':
    unittest.main()
