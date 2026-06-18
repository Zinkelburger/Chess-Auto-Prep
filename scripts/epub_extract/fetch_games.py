#!/usr/bin/env python3
"""
Fetch unmatched games from 365chess.com.

Searches 365chess.com for each game, extracts the moves from the HTML,
and outputs a combined PGN file.

Usage:
    python3 fetch_games.py --output fetched_games.pgn
"""

import json
import re
import sys
import time
import urllib.parse
import urllib.request
from html.parser import HTMLParser


SEARCH_URL = (
    "https://www.365chess.com/search_result.php?"
    "wid=&bid=&submit_search=1"
    "&wlname={white}&open=&blname={black}"
    "&eco={eco}&nocolor=on"
    "&yeari={year}&yeare={year}&sply=1&ply=&res="
)

HEADERS = {
    'User-Agent': 'Mozilla/5.0 (X11; Linux x86_64; rv:137.0) Gecko/20100101 Firefox/137.0',
    'Accept': 'text/html,application/xhtml+xml,*/*',
    'Accept-Language': 'en-US,en;q=0.5',
}


class MoveExtractor(HTMLParser):
    """Extract move links and game metadata from 365chess search results HTML."""

    def __init__(self):
        super().__init__()
        self.in_move_link = False
        self.moves: list[str] = []
        self.white_full = ''
        self.black_full = ''
        self.result = '*'
        self._current_href = ''
        self._capture_player = ''
        self._player_text = ''
        self._found_game_row = False

    def handle_starttag(self, tag, attrs):
        attr_dict = dict(attrs)
        href = attr_dict.get('href', '')
        cls = attr_dict.get('class', '')

        if tag == 'a':
            if 'view_game.php' in href or 'game.php' in href:
                self._found_game_row = True
            if href.startswith('javascript:GoToMove'):
                self.in_move_link = True
            if 'players/' in href and not self.white_full:
                self._capture_player = 'white'
                self._player_text = ''
            elif 'players/' in href and self.white_full and not self.black_full:
                self._capture_player = 'black'
                self._player_text = ''

    def handle_endtag(self, tag):
        if tag == 'a':
            if self.in_move_link:
                self.in_move_link = False
            if self._capture_player == 'white' and self._player_text:
                self.white_full = self._player_text.strip()
                self._capture_player = ''
            elif self._capture_player == 'black' and self._player_text:
                self.black_full = self._player_text.strip()
                self._capture_player = ''

    def handle_data(self, data):
        if self.in_move_link:
            text = data.strip()
            if text:
                self.moves.append(text)
        if self._capture_player:
            self._player_text += data
        text = data.strip()
        if text in ('1-0', '0-1', '1/2-1/2'):
            self.result = text


def search_and_extract(white: str, black: str, year: str, eco: str) -> dict | None:
    """Search 365chess.com and extract moves from the first result."""
    url = SEARCH_URL.format(
        white=urllib.parse.quote(white),
        black=urllib.parse.quote(black),
        eco=urllib.parse.quote(eco),
        year=urllib.parse.quote(year),
    )
    try:
        req = urllib.request.Request(url, headers=HEADERS)
        resp = urllib.request.urlopen(req, timeout=20)
        html = resp.read().decode('utf-8', errors='replace')

        parser = MoveExtractor()
        parser.feed(html)

        if parser.moves and len(parser.moves) >= 4:
            return {
                'moves': parser.moves,
                'white_full': parser.white_full,
                'black_full': parser.black_full,
                'result': parser.result,
            }
    except Exception as e:
        print(f"  Search error: {e}", file=sys.stderr)
    return None


def build_pgn(game_info: dict, white: str, black: str, year: str, eco: str) -> str:
    """Build a PGN string from extracted game data."""
    moves = game_info['moves']
    result = game_info['result']
    w_name = game_info.get('white_full') or white
    b_name = game_info.get('black_full') or black

    move_text_parts = []
    for i, m in enumerate(moves):
        if i % 2 == 0:
            move_text_parts.append(f"{i // 2 + 1}.{m}")
        else:
            move_text_parts.append(m)
    move_text = ' '.join(move_text_parts) + ' ' + result

    pgn = (
        f'[Event "?"]\n'
        f'[Site "?"]\n'
        f'[Date "{year}.??.??"]\n'
        f'[White "{w_name}"]\n'
        f'[Black "{b_name}"]\n'
        f'[Result "{result}"]\n'
        f'[ECO "{eco}"]\n'
        f'\n'
        f'{move_text}\n'
    )
    return pgn


# Games to fetch — from the EPUB extraction
UNMATCHED_GAMES = [
    {"white": "Kramnik", "black": "Topalov", "year": "1999", "eco": "A40"},
    {"white": "Vaganian", "black": "Khalifman", "year": "1996", "eco": "D76"},
    {"white": "Pigusov", "black": "Ye Jiangchuan", "year": "1993", "eco": "D76"},
    {"white": "Ippolito", "black": "Nakamura", "year": "2003", "eco": "D76"},
    {"white": "Ippolito", "black": "Evdokimov", "year": "2012", "eco": "D76"},
    {"white": "Wojtkiewicz", "black": "Yanayt", "year": "2004", "eco": "D75"},
    {"white": "Tomashevsky", "black": "Mamedyarov", "year": "2009", "eco": "D75"},
    {"white": "Kotsur", "black": "Rakhmanov", "year": "2008", "eco": "D74"},
    {"white": "Dvoirys", "black": "Berntsen", "year": "2005", "eco": "D74"},
    {"white": "Filippov", "black": "Odeev", "year": "2001", "eco": "D74"},
    {"white": "Ippolito", "black": "Hilton", "year": "2008", "eco": "D78"},
    {"white": "Karpov", "black": "Georgiev", "year": "1988", "eco": "D78"},
    {"white": "Khalifman", "black": "Ruck", "year": "1996", "eco": "D78"},
    {"white": "Romanishin", "black": "Gulko", "year": "1991", "eco": "D78"},
    {"white": "Wojtkiewicz", "black": "Mohring", "year": "1988", "eco": "D78"},
    {"white": "Tregubov", "black": "Bezemer", "year": "2004", "eco": "D78"},
    {"white": "Melkumyan", "black": "Kozul", "year": "2012", "eco": "D78"},
    {"white": "Ivanchuk", "black": "Leko", "year": "1995", "eco": "D73"},
    {"white": "Lerner", "black": "Serebro", "year": "2002", "eco": "D73"},
    {"white": "Wojtkiewicz", "black": "Sasikiran", "year": "1999", "eco": "D73"},
    {"white": "Wojtkiewicz", "black": "Boudreaux", "year": "2005", "eco": "B38"},
    {"white": "Wojtkiewicz", "black": "Whaley", "year": "2006", "eco": "B39"},
    {"white": "Vitiugov", "black": "Sedlak", "year": "2012", "eco": "B36"},
    {"white": "Goloshchapov", "black": "Wirig", "year": "2004", "eco": "B36"},
    {"white": "Wojtkiewicz", "black": "Langenberg", "year": "1996", "eco": "A39"},
    {"white": "Hilton", "black": "Hanken", "year": "2006", "eco": "A30"},
    {"white": "Hilton", "black": "Sprague", "year": "2008", "eco": "A39"},
    {"white": "Hilton", "black": "Whorton", "year": "2007", "eco": "A39"},
    {"white": "Hilton", "black": "Casden", "year": "2009", "eco": "A39"},
    {"white": "Hilton", "black": "Dennis", "year": "2008", "eco": "A39"},
    {"white": "Wojtkiewicz", "black": "La Flair", "year": "1993", "eco": "A39"},
    {"white": "Kasparov", "black": "Uko", "year": "1994", "eco": "A38"},
    {"white": "Lenderman", "black": "Kudrin", "year": "2010", "eco": "A33"},
    {"white": "Wojtkiewicz", "black": "Shahade", "year": "2002", "eco": "A33"},
    {"white": "Miton", "black": "Bocharov", "year": "2007", "eco": "A33"},
    {"white": "Hilton", "black": "Michaelides", "year": "2009", "eco": "A30"},
    {"white": "Hilton", "black": "Sadvakasov", "year": "2007", "eco": "A30"},
    {"white": "Pigusov", "black": "Yudasin", "year": "1990", "eco": "A34"},
    {"white": "Bauer", "black": "Riva Aguado", "year": "2001", "eco": "A81"},
    {"white": "Wojtkiewicz", "black": "Santos", "year": "2004", "eco": "A87"},
    {"white": "Salem", "black": "Gleizerov", "year": "2011", "eco": "A90"},
    {"white": "Spyrou", "black": "Limbourg", "year": "2007", "eco": "A84"},
    {"white": "Miles", "black": "Roos", "year": "1981", "eco": "A99"},
    {"white": "Hilton", "black": "Burgess", "year": "2009", "eco": "A55"},
    {"white": "Arnason", "black": "Angelis", "year": "1993", "eco": "A13"},
    {"white": "Wojtkiewicz", "black": "Hilton", "year": "2005", "eco": "D76"},
]


def main():
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', '-o', default='scripts/epub_extract/output/fetched_games.pgn')
    parser.add_argument('--delay', type=float, default=4.0,
                        help='Delay between requests (seconds)')
    args = parser.parse_args()

    all_pgn = []
    found = 0
    not_found = 0
    not_found_list = []

    for i, game in enumerate(UNMATCHED_GAMES):
        label = f"{game['white']} vs {game['black']} ({game['year']}) [{game['eco']}]"
        print(f"[{i+1}/{len(UNMATCHED_GAMES)}] Searching: {label}")

        result = search_and_extract(
            game['white'], game['black'], game['year'], game['eco']
        )

        if not result:
            time.sleep(args.delay)
            result = search_and_extract(
                game['white'], game['black'], game['year'], ''
            )

        if not result:
            time.sleep(args.delay)
            result = search_and_extract(
                game['black'], game['white'], game['year'], game['eco']
            )

        if result:
            pgn = build_pgn(result, game['white'], game['black'],
                            game['year'], game['eco'])
            all_pgn.append(pgn)
            found += 1
            print(f"  ✓ Found ({len(result['moves'])} moves) {result['result']}")
        else:
            not_found += 1
            not_found_list.append(label)
            print(f"  ✗ Not found")

        time.sleep(args.delay)

    with open(args.output, 'w') as f:
        f.write('\n\n'.join(all_pgn))

    print(f"\nDone: {found} found, {not_found} not found")
    print(f"Written to {args.output}")
    if not_found_list:
        print("\nNot found:")
        for g in not_found_list:
            print(f"  - {g}")


if __name__ == '__main__':
    main()
