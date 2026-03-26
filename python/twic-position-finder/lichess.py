"""Lichess game import — POST /api/import to get analysis URLs."""

import os
import time

import requests

LICHESS_API_BASE = "https://lichess.org"
IMPORT_ENDPOINT = f"{LICHESS_API_BASE}/api/import"

# Rate limit: stay well under 30 req/min
_MIN_INTERVAL = 2.5
_last_request_time = 0.0


def _get_token() -> str | None:
    return (os.getenv("LICHESS_API_TOKEN")
            or os.getenv("LICHESS")
            or _read_token_file())


def _read_token_file() -> str | None:
    for path in [".lichess_token",
                 os.path.expanduser("~/.config/tree_builder/token")]:
        try:
            with open(path) as f:
                token = f.read().strip()
                if token:
                    return token
        except FileNotFoundError:
            continue
    return None


_MAX_RETRIES = 3


def import_game(pgn_text: str, token: str | None = None) -> str | None:
    """Import a PGN to Lichess and return the game URL.

    Returns None if import fails (no token, rate limited, etc.).
    """
    global _last_request_time

    token = token or _get_token()
    if not token:
        return None

    for attempt in range(_MAX_RETRIES):
        elapsed = time.time() - _last_request_time
        if elapsed < _MIN_INTERVAL:
            time.sleep(_MIN_INTERVAL - elapsed)

        headers = {"Authorization": f"Bearer {token}"}
        data = {"pgn": pgn_text}

        try:
            resp = requests.post(IMPORT_ENDPOINT, headers=headers, data=data, timeout=30)
            _last_request_time = time.time()

            if resp.status_code == 200:
                result = resp.json()
                game_id = result.get("id")
                if game_id:
                    return f"{LICHESS_API_BASE}/{game_id}"
                return None
            elif resp.status_code == 429:
                wait = 60 * (attempt + 1)
                print(f"  Lichess rate limited, waiting {wait}s (attempt {attempt + 1}/{_MAX_RETRIES})...")
                time.sleep(wait)
                continue
            else:
                print(f"  Lichess import failed ({resp.status_code}): {resp.text[:200]}")
                return None
        except requests.RequestException as e:
            print(f"  Lichess import error: {e}")
            return None

    print(f"  Lichess import failed after {_MAX_RETRIES} retries (rate limited)")
    return None


def import_games_batch(games: list[dict], db=None,
                       token: str | None = None) -> dict[int, str]:
    """Import multiple games, return {game_id: lichess_url}.

    If db is provided, caches lichess_url in the games table.
    """
    results = {}
    for i, game in enumerate(games):
        game_id = game.get("id")
        pgn = game.get("pgn_text", "")

        existing_url = game.get("lichess_url")
        if existing_url:
            results[game_id] = existing_url
            continue

        if not pgn.strip():
            continue

        print(f"  Importing game {i+1}/{len(games)} to Lichess...")
        url = import_game(pgn, token)
        if url:
            results[game_id] = url
            if db:
                db.execute("UPDATE games SET lichess_url = ? WHERE id = ?",
                           (url, game_id))
                db.commit()

    return results


def analysis_url_from_fen(fen: str) -> str:
    """Generate a Lichess analysis URL from a FEN (no auth required)."""
    fen_path = fen.replace(" ", "_")
    return f"{LICHESS_API_BASE}/analysis/{fen_path}"
