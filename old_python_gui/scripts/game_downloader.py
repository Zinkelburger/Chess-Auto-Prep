import os
import re
import requests
import json
from datetime import datetime, timedelta
from dotenv import load_dotenv
from typing import List


def _get_cache_dir():
    """Get the cache directory, creating it if it doesn't exist."""
    cache_dir = os.path.join(os.getcwd(), "game_cache")
    os.makedirs(cache_dir, exist_ok=True)
    return cache_dir

def _get_cache_filename(username: str, user_color: str):
    """Get the cache filename for a specific user and color."""
    cache_dir = _get_cache_dir()
    return os.path.join(cache_dir, f"{username}_{user_color}.json")

def _save_games_to_cache(username: str, user_color: str, games: List[str]):
    """Save games to cache with timestamp."""
    cache_file = _get_cache_filename(username, user_color)
    cache_data = {
        "timestamp": datetime.now().isoformat(),
        "games": games
    }
    with open(cache_file, "w", encoding="utf-8") as f:
        json.dump(cache_data, f, ensure_ascii=False, indent=2)

def _load_games_from_cache(username: str, user_color: str, max_age_days: int = 1) -> List[str]:
    """Load games from cache if they exist and are recent enough."""
    cache_file = _get_cache_filename(username, user_color)

    if not os.path.exists(cache_file):
        return None

    try:
        with open(cache_file, "r", encoding="utf-8") as f:
            cache_data = json.load(f)

        # Check if cache is recent enough
        cache_time = datetime.fromisoformat(cache_data["timestamp"])
        if datetime.now() - cache_time > timedelta(days=max_age_days):
            print(f"Cache for {username}_{user_color} is older than {max_age_days} days, will refresh.")
            return None

        print(f"Using cached games for {username}_{user_color} from {cache_time.strftime('%Y-%m-%d %H:%M')}")
        return cache_data["games"]

    except Exception as e:
        print(f"Error reading cache for {username}_{user_color}: {e}")
        return None

def download_games_for_last_two_months(username: str, user_color: str = "both", use_cache: bool = True, cache_max_age_days: int = 1) -> List[str]:
    """
    Downloads games for the last two months from Chess.com.
    Excludes bullet games (<3 minutes main time) and returns a list of PGN strings.

    Args:
        username: Chess.com username
        user_color: "white", "black", or "both"
        use_cache: Whether to use cached games if available
        cache_max_age_days: Maximum age of cache in days before refreshing
    """
    # Check cache first if enabled
    if use_cache:
        cached_games = _load_games_from_cache(username, user_color, cache_max_age_days)
        if cached_games is not None:
            return cached_games

    print(f"Downloading fresh games for {username}_{user_color}...")

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

    username_lower = username.lower()

    for year, month in year_months:
        url = f"https://api.chess.com/pub/player/{username}/games/{year}/{month:02d}/pgn"
        try:
            response = requests.get(url, headers=headers)
            response.raise_for_status()
            raw_pgn = response.text
            # Split the PGN file on '[Event ' (keeping the delimiter for each game)
            games = re.split(r'(?=\[Event )', raw_pgn)[1:]
            for game_text in games:
                # Filter by user color if specified
                if user_color != "both":
                    white_player = re.search(r'\[White "([^"]+)"\]', game_text)
                    black_player = re.search(r'\[Black "([^"]+)"\]', game_text)

                    if white_player and black_player:
                        is_user_white = white_player.group(1).lower() == username_lower
                        is_user_black = black_player.group(1).lower() == username_lower

                        if user_color == "white" and not is_user_white:
                            continue
                        elif user_color == "black" and not is_user_black:
                            continue

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

    # Save to cache if enabled
    if use_cache:
        _save_games_to_cache(username, user_color, collected_pgns)

    print(f"Downloaded {len(collected_pgns)} games for {username}_{user_color}")
    return collected_pgns

def clear_cache(username: str = None, user_color: str = None):
    """
    Clear cached games. If username and user_color are specified, clear only that cache.
    Otherwise, clear all cache files.
    """
    cache_dir = _get_cache_dir()

    if username and user_color:
        # Clear specific cache file
        cache_file = _get_cache_filename(username, user_color)
        if os.path.exists(cache_file):
            os.remove(cache_file)
            print(f"Cleared cache for {username}_{user_color}")
        else:
            print(f"No cache found for {username}_{user_color}")
    else:
        # Clear all cache files
        cache_files = [f for f in os.listdir(cache_dir) if f.endswith('.json')]
        for cache_file in cache_files:
            os.remove(os.path.join(cache_dir, cache_file))
        print(f"Cleared {len(cache_files)} cache files")

def list_cache():
    """List all cached games with their timestamps."""
    cache_dir = _get_cache_dir()
    cache_files = [f for f in os.listdir(cache_dir) if f.endswith('.json')]

    if not cache_files:
        print("No cached games found")
        return

    print("Cached games:")
    for cache_file in sorted(cache_files):
        try:
            with open(os.path.join(cache_dir, cache_file), "r") as f:
                cache_data = json.load(f)
            timestamp = datetime.fromisoformat(cache_data["timestamp"])
            game_count = len(cache_data["games"])
            age_days = (datetime.now() - timestamp).days
            print(f"  {cache_file}: {game_count} games, {timestamp.strftime('%Y-%m-%d %H:%M')} ({age_days} days old)")
        except Exception as e:
            print(f"  {cache_file}: Error reading cache - {e}")
