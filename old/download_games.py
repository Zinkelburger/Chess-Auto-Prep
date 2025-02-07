import requests
from datetime import datetime, timedelta
import os
from dotenv import load_dotenv
import re

load_dotenv()
email = os.getenv('EMAIL')

def download_games_for_last_two_months(username, is_black=False):
    """
    Downloads games for the last two months for a specific player from Chess.com API.
    Removes bullet games

    Args:
    username (str): The username of the player.
    is_black (bool): Whether the player is black or not

    Returns:
    list: A list of PGN strings for the games of the last two months.
    """
    current_date = datetime.now()
    last_month = current_date - timedelta(days=current_date.day)
    two_months_ago = last_month - timedelta(days=last_month.day)

    headers = {'User-Agent': email}
    filtered_games = []

    for year, month in [(two_months_ago.year, two_months_ago.month), 
                        (last_month.year, last_month.month),
                        (current_date.year, current_date.month)]:
        api_url = f"https://api.chess.com/pub/player/{username}/games/{year}/{month:02d}/pgn"
        try:
            response = requests.get(api_url, headers=headers)
            response.raise_for_status()
            games_data = response.text

            # Split games using '[Event ' as delimiter but keep it as part of the game string
            games = re.split(r'(?=\[Event )', games_data)[1:]  # Skip the first empty string if any

            for game in games:
                # Filter by time control
                time_control_match = re.search(r'\[TimeControl "(\d+)\+(\d+)"\]', game)
                if time_control_match:
                    main_time, increment = map(int, time_control_match.groups())
                    if main_time < 180:
                        continue

                # Filter by player color
                player_color_match = re.search(rf'\[{("Black" if is_black else "White")} "{username}"\]', game, re.IGNORECASE)
                if not player_color_match:
                    continue

                # Optionally remove clock times from moves
                game = re.sub(r' \{\[%clk [^\]]+\]\}', '', game)

                filtered_games.append(game)
        except requests.RequestException as e:
            print(f"Error during API request for {year}-{month:02d}: {e}")

    return filtered_games
