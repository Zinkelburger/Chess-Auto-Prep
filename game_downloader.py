import os
import re
import requests
from datetime import datetime, timedelta
from dotenv import load_dotenv
from typing import List


def download_games_for_last_two_months(username: str) -> List[str]:
    """
    Downloads games for the last two months from Chess.com (example implementation).
    Excludes bullet games (<3 minutes main time) and returns a list of PGN strings.
    """
    load_dotenv()
    email = os.getenv("EMAIL")
    if email is None:
        raise ValueError("failed to load email from .env")

    current_date = datetime.now()
    last_month = current_date.replace(day=1) - timedelta(days=1)  # Last day of previous month
    two_months_ago = last_month.replace(day=1) - timedelta(days=1)  # Last day of the month before that

    headers = {"User-Agent": email}
    collected_pgns = []

    # We want to fetch these three sets: two months ago, last month, current month
    year_months = [
        (two_months_ago.year, two_months_ago.month),
        (last_month.year, last_month.month),
        (current_date.year, current_date.month)
    ]

    for year, month in year_months:
        url = f"https://api.chess.com/pub/player/{username}/games/{year}/{month:02d}/pgn"
        try:
            response = requests.get(url, headers=headers)
            response.raise_for_status()
            raw_pgn = response.text
            # Split the PGN file on '[Event ' (keeping the delimiter for each game)
            games = re.split(r'(?=\[Event )', raw_pgn)[1:]
            for game_text in games:
                # Filter out bullet games using the TimeControl tag.
                time_control_match = re.search(r'\[TimeControl "(\d+)\+(\d+)"\]', game_text)
                if time_control_match:
                    main_time, inc = map(int, time_control_match.groups())
                    if main_time < 180:  # bullet threshold
                        continue

                # Optionally remove clock times from moves.
                game_text = re.sub(r' \{\[%clk [^\]]+\]\}', '', game_text)
                
                collected_pgns.append(game_text)

        except Exception as e:
            print(f"Error fetching {url}: {e}")

    return collected_pgns
