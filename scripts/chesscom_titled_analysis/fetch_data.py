"""
Fetch chess.com titled player data with local JSON caching.

Phases:
  1. fetch-titles    — pull username lists for GM/IM/FM/NM/CM  (~10 API calls)
  2. fetch-stats     — pull blitz/rapid/bullet ratings          (~14k calls, ~4h)
  3. fetch-nm-detail — pull profiles + recent games for NMs     (~5k calls, ~1.5h)

Each phase is resumable: cached results are skipped on re-run.

Usage:
  python fetch_data.py fetch-titles
  python fetch_data.py fetch-stats
  python fetch_data.py fetch-nm-detail
  python fetch_data.py all              # runs everything in order
"""

import argparse
import json
import os
import sys
import time
from pathlib import Path

import requests

SCRIPT_DIR = Path(__file__).resolve().parent
DATA_DIR = SCRIPT_DIR / "data"
DATA_DIR.mkdir(exist_ok=True)

TITLES = ["GM", "IM", "FM", "NM", "CM"]
API_BASE = "https://api.chess.com/pub"
HEADERS = {"User-Agent": "Chess-Auto-Prep/1.0 (titled-analysis script)"}
REQUEST_DELAY = 0.35  # seconds between requests — stay well under limits


# ── Helpers ──────────────────────────────────────────────────────────

def api_get(url: str, retries: int = 3) -> dict | None:
    for attempt in range(retries):
        try:
            resp = requests.get(url, headers=HEADERS, timeout=15)
            if resp.status_code == 429:
                wait = 60 * (attempt + 1)
                print(f"  Rate limited, waiting {wait}s…")
                time.sleep(wait)
                continue
            if resp.status_code == 404:
                return None
            resp.raise_for_status()
            return resp.json()
        except requests.RequestException as e:
            if attempt < retries - 1:
                time.sleep(5)
            else:
                print(f"  FAILED {url}: {e}")
                return None
    return None


def load_json(path: Path) -> dict | list | None:
    if path.exists():
        with open(path) as f:
            return json.load(f)
    return None


def save_json(path: Path, data):
    with open(path, "w") as f:
        json.dump(data, f, indent=2)


def progress(i: int, total: int, label: str = "", every: int = 50):
    if i % every == 0 or i == total - 1:
        pct = (i + 1) * 100 // total
        print(f"\r  [{pct:3d}%] {i+1}/{total} {label}", end="", flush=True)
        if i == total - 1:
            print()


# ── Phase 1: Fetch title lists ──────────────────────────────────────

def fetch_titles():
    print("Phase 1: Fetching titled player lists…")
    for title in TITLES:
        cache = DATA_DIR / f"titled_{title}.json"
        if cache.exists():
            players = load_json(cache)
            print(f"  {title}: {len(players)} (cached)")
            continue
        data = api_get(f"{API_BASE}/titled/{title}")
        if data and "players" in data:
            save_json(cache, data["players"])
            print(f"  {title}: {len(data['players'])} players")
        else:
            print(f"  {title}: FAILED")
        time.sleep(REQUEST_DELAY)


# ── Phase 2: Fetch stats for all titled players ─────────────────────

def fetch_stats():
    """Fetch /player/{username}/stats for every titled player.
    Saves one big JSON file per title: stats_{TITLE}.json = {username: stats_dict}.
    """
    print("Phase 2: Fetching player stats…")
    for title in TITLES:
        title_file = DATA_DIR / f"titled_{title}.json"
        if not title_file.exists():
            print(f"  {title}: no title list — run fetch-titles first")
            continue

        players = load_json(title_file)
        cache_file = DATA_DIR / f"stats_{title}.json"
        cached = load_json(cache_file) or {}

        remaining = [u for u in players if u not in cached]
        if not remaining:
            print(f"  {title}: {len(cached)} stats (all cached)")
            continue

        print(f"  {title}: {len(cached)} cached, {len(remaining)} to fetch")
        for i, username in enumerate(remaining):
            data = api_get(f"{API_BASE}/player/{username}/stats")
            if data:
                cached[username] = data
            else:
                cached[username] = {}  # mark as attempted
            progress(i, len(remaining), title)
            time.sleep(REQUEST_DELAY)

            # save every 200 to avoid losing progress
            if (i + 1) % 200 == 0:
                save_json(cache_file, cached)

        save_json(cache_file, cached)
        print(f"  {title}: done — {len(cached)} total")


# ── Phase 3: NM detail — profiles + recent games ───────────────────

def fetch_nm_detail():
    """For every NM, fetch profile (country check) and for US NMs fetch
    most recent blitz game to extract time control.
    """
    print("Phase 3: Fetching NM profiles + recent games…")

    nm_file = DATA_DIR / f"titled_NM.json"
    if not nm_file.exists():
        print("  No NM list — run fetch-titles first")
        return

    players = load_json(nm_file)
    profile_cache_file = DATA_DIR / "nm_profiles.json"
    profiles = load_json(profile_cache_file) or {}

    # 3a: fetch profiles for country filtering
    remaining = [u for u in players if u not in profiles]
    if remaining:
        print(f"  Profiles: {len(profiles)} cached, {len(remaining)} to fetch")
        for i, username in enumerate(remaining):
            data = api_get(f"{API_BASE}/player/{username}")
            if data:
                profiles[username] = {
                    "name": data.get("name", ""),
                    "country": data.get("country", ""),
                    "location": data.get("location", ""),
                    "username": username,
                }
            else:
                profiles[username] = {"username": username, "country": ""}
            progress(i, len(remaining), "profiles")
            time.sleep(REQUEST_DELAY)
            if (i + 1) % 200 == 0:
                save_json(profile_cache_file, profiles)
        save_json(profile_cache_file, profiles)
    else:
        print(f"  Profiles: {len(profiles)} (all cached)")

    # filter to US NMs
    us_nms = [u for u, p in profiles.items() if p.get("country", "").endswith("/US")]
    print(f"  US NMs: {len(us_nms)}")

    # 3b: fetch most recent blitz game for each US NM
    games_cache_file = DATA_DIR / "nm_recent_blitz.json"
    games_cache = load_json(games_cache_file) or {}

    remaining = [u for u in us_nms if u not in games_cache]
    if not remaining:
        print(f"  Recent blitz games: {len(games_cache)} (all cached)")
        return

    print(f"  Recent blitz: {len(games_cache)} cached, {len(remaining)} to fetch")
    for i, username in enumerate(remaining):
        game_info = _fetch_recent_blitz(username)
        games_cache[username] = game_info
        progress(i, len(remaining), "recent blitz")
        time.sleep(REQUEST_DELAY)
        if (i + 1) % 100 == 0:
            save_json(games_cache_file, games_cache)

    save_json(games_cache_file, games_cache)
    print(f"  Recent blitz: done — {len(games_cache)} total")


def _fetch_recent_blitz(username: str) -> dict:
    """Find the most recent blitz game for a player and return its time control."""
    archives = api_get(f"{API_BASE}/player/{username}/games/archives")
    if not archives or "archives" not in archives or not archives["archives"]:
        return {"time_control": None, "error": "no archives"}

    # walk backwards through monthly archives until we find a blitz game
    for archive_url in reversed(archives["archives"][-3:]):  # check last 3 months max
        time.sleep(REQUEST_DELAY)
        month_data = api_get(archive_url)
        if not month_data or "games" not in month_data:
            continue
        for game in reversed(month_data["games"]):
            if game.get("time_class") == "blitz":
                tc = game.get("time_control", "")
                return {
                    "time_control": tc,
                    "time_class": "blitz",
                    "url": game.get("url", ""),
                }
    return {"time_control": None, "error": "no recent blitz"}


# ── Main ─────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="Fetch chess.com titled player data")
    parser.add_argument(
        "phase",
        choices=["fetch-titles", "fetch-stats", "fetch-nm-detail", "all"],
        help="Which phase to run",
    )
    args = parser.parse_args()

    if args.phase in ("fetch-titles", "all"):
        fetch_titles()
    if args.phase in ("fetch-stats", "all"):
        fetch_stats()
    if args.phase in ("fetch-nm-detail", "all"):
        fetch_nm_detail()


if __name__ == "__main__":
    main()
