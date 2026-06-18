#!/usr/bin/env python3
"""
Chess.com USCF Tournament Index

Builds and maintains a local index of all USCF-rated tournaments from the
"USChess - Members Only" club on chess.com.

The chess.com PubAPI has no endpoint for listing club tournaments, so we
scrape the paginated club archive. Pages are ordered newest-first.

Index is stored as a JSON file and supports:
- Full rebuild (~170 pages, ~3 min)
- Incremental update (fetch newest pages until overlap)
- Binary search by date (for when index is unavailable)
"""

import json
import re
import time
from datetime import datetime
from pathlib import Path

import requests
from bs4 import BeautifulSoup

CLUB_URL = "https://www.chess.com/club/live-tournaments/uschess-members-only"
INDEX_PATH = Path(__file__).parent / "data" / "chesscom_tournament_index.json"

SESSION = requests.Session()
SESSION.headers.update({
    "User-Agent": "USCF-ChessCom-Resolver/1.0 (chess research tool)"
})

RATE_LIMIT = 1.0  # seconds between requests


def scrape_page(page: int) -> list[dict]:
    """
    Scrape a single page of the club tournament archive.
    Returns list of {slug, name, date, date_iso, players, rating_section}.
    Empty list if page is past the end.
    """
    resp = SESSION.get(CLUB_URL, params={"page": page}, timeout=15)
    resp.raise_for_status()

    soup = BeautifulSoup(resp.text, "html.parser")
    table = soup.find("table")
    if not table:
        return []

    rows = table.find_all("tr")
    entries = []

    for row in rows[1:]:  # skip header
        cells = row.find_all("td")
        if len(cells) < 4:
            continue

        # Cell 0: tournament name (link has slug)
        # Slugs may or may not start with a dash (e.g. "-us-chess-..." or "us-chess-...")
        link = cells[0].find("a", href=re.compile(r"/tournament/live/"))
        if not link:
            continue
        href = link.get("href", "")
        slug_match = re.search(r"/tournament/live/(.+?)(?:\?|$)", href)
        if not slug_match:
            continue
        slug = slug_match.group(1)
        # Skip the arena/completed link that shows up in navigation
        if slug == "arena/completed" or slug.startswith("arena"):
            continue

        # Derive canonical name from the slug (more reliable than HTML text parsing).
        # Slug patterns:
        #   "-us-chess-100-blitz-796054"    → "US Chess 10|0 Blitz"
        #   "-us-chess-1510-rapid-794496"   → "US Chess 15|10 Rapid"
        #   "-us-chess-32-blitz-793513"     → "US Chess 3|2 Blitz"
        #   "-us-chess-50-blitz-792540"     → "US Chess 5|0 Blitz"
        #   "us-chess-rapid-open-6542381"   → "US Chess Rapid Open"
        #   "us-chess-rapid-u1450-6542379"  → "US Chess Rapid U1450"
        #   "us-chess-blitz-u1450-6542375"  → "US Chess Blitz U1450"
        #   "-us-chess-15--10-rapid-6557709"→ "US Chess 15+10 Rapid"
        slug_clean = slug.lstrip("-")
        # Remove trailing numeric ID
        slug_clean = re.sub(r"-(\d{5,})$", "", slug_clean)
        # Convert known time control patterns in slug → display format
        TC_MAP = {
            "us-chess-100-": "US Chess 10|0 ",
            "us-chess-1510-": "US Chess 15|10 ",
            "us-chess-32-": "US Chess 3|2 ",
            "us-chess-50-": "US Chess 5|0 ",
            "us-chess-10-": "US Chess 10|0 ",
            "us-chess-15--10-": "US Chess 15+10 ",
            "us-chess-15-10-": "US Chess 15|10 ",
        }
        name = None
        for prefix, replacement in TC_MAP.items():
            if slug_clean.startswith(prefix):
                remainder = slug_clean[len(prefix):]
                name = replacement + remainder.replace("-", " ").title()
                break
        if not name:
            name = slug_clean.replace("-", " ").title()
        # Fix "Us Chess" → "US Chess", preserve "U1450"
        name = name.replace("Us Chess", "US Chess")
        name = re.sub(r"U(\d+)", lambda m: f"U{m.group(1)}", name)

        # Cell 1: rating section
        rating_section = cells[1].get_text(strip=True)

        # Cell 2: player count
        try:
            players = int(cells[2].get_text(strip=True))
        except ValueError:
            players = 0

        # Cell 3: date string like "Feb 27, 2017, 3:00 PM"
        # May contain unicode narrow no-break space (\u202f) before AM/PM
        date_str = cells[3].get_text(strip=True)
        date_normalized = date_str.replace("\u202f", " ").replace("\xa0", " ")
        try:
            dt = datetime.strptime(date_normalized, "%b %d, %Y, %I:%M %p")
            date_iso = dt.strftime("%Y-%m-%d")
        except ValueError:
            date_iso = ""

        entries.append({
            "slug": slug,
            "name": name,
            "date": date_str,
            "date_iso": date_iso,
            "players": players,
            "rating_section": rating_section,
        })

    return entries


def build_full_index(progress_callback=None) -> list[dict]:
    """
    Build the complete tournament index by scraping all pages.
    Returns the full list of tournaments (newest first).
    """
    all_entries = []
    page = 1
    empty_count = 0

    while empty_count < 3:  # stop after 3 consecutive empty pages
        if progress_callback:
            progress_callback(page, len(all_entries))

        entries = scrape_page(page)
        if not entries:
            empty_count += 1
        else:
            empty_count = 0
            all_entries.extend(entries)

        page += 1
        time.sleep(RATE_LIMIT)

    return all_entries


def update_index(existing: list[dict]) -> list[dict]:
    """
    Incrementally update the index by fetching newest pages until
    we find tournaments already in the index.
    """
    if not existing:
        return build_full_index()

    existing_slugs = {e["slug"] for e in existing}
    new_entries = []
    page = 1

    while True:
        entries = scrape_page(page)
        if not entries:
            break

        found_overlap = False
        for entry in entries:
            if entry["slug"] in existing_slugs:
                found_overlap = True
                break
            new_entries.append(entry)

        if found_overlap:
            break

        page += 1
        time.sleep(RATE_LIMIT)

    # Prepend new entries to existing (newest first)
    return new_entries + existing


def binary_search_page_for_date(target_date: str) -> int:
    """
    Binary search across pages to find which page contains the target date.
    Returns the page number.
    """
    target_dt = datetime.strptime(target_date, "%Y-%m-%d")

    # Establish bounds
    lo, hi = 1, 200

    # First, find the upper bound (last non-empty page)
    while lo < hi:
        mid = (lo + hi) // 2
        entries = scrape_page(mid)
        time.sleep(RATE_LIMIT)
        if entries:
            lo = mid + 1
        else:
            hi = mid

    max_page = lo - 1

    # Now binary search within [1, max_page] for the target date
    lo, hi = 1, max_page

    while lo < hi:
        mid = (lo + hi) // 2
        entries = scrape_page(mid)
        time.sleep(RATE_LIMIT)

        if not entries:
            hi = mid - 1
            continue

        # Pages are newest-first, so page_date is the oldest entry on the page
        page_newest = entries[0].get("date_iso", "")
        page_oldest = entries[-1].get("date_iso", "")

        if not page_newest or not page_oldest:
            lo = mid + 1
            continue

        if target_date >= page_oldest and target_date <= page_newest:
            return mid  # Found the page
        elif target_date > page_newest:
            hi = mid - 1  # Target is more recent, go to earlier pages
        else:
            lo = mid + 1  # Target is older, go to later pages

    return lo


def find_tournament_by_date(
    target_date: str,
    time_class: str | None = None,
    index: list[dict] | None = None,
) -> list[dict]:
    """
    Find tournaments matching a target date (and optional time class).
    Uses local index if available, otherwise binary search.
    Returns matching entries.
    """
    if index:
        matches = []
        for entry in index:
            if entry["date_iso"] == target_date:
                if time_class:
                    slug_lower = entry["slug"].lower()
                    name_lower = entry["name"].lower()
                    if time_class == "blitz" and "blitz" not in slug_lower and "blitz" not in name_lower:
                        continue
                    if time_class == "rapid" and "rapid" not in slug_lower and "rapid" not in name_lower:
                        continue
                matches.append(entry)
        return matches

    # No index - use binary search
    page = binary_search_page_for_date(target_date)
    entries = scrape_page(page)

    # Also check adjacent pages (date might span page boundary)
    if page > 1:
        entries = scrape_page(page - 1) + entries
        time.sleep(RATE_LIMIT)

    matches = [e for e in entries if e["date_iso"] == target_date]
    if time_class:
        matches = [
            e for e in matches
            if time_class in e["slug"].lower() or time_class in e["name"].lower()
        ]

    return matches


def load_index() -> list[dict]:
    """Load the index from disk. Returns empty list if not found."""
    if INDEX_PATH.exists():
        with open(INDEX_PATH) as f:
            data = json.load(f)
        return data.get("tournaments", [])
    return []


def save_index(tournaments: list[dict]):
    """Save the index to disk with metadata."""
    INDEX_PATH.parent.mkdir(parents=True, exist_ok=True)
    data = {
        "updated_at": datetime.now().isoformat(),
        "count": len(tournaments),
        "source": CLUB_URL,
        "tournaments": tournaments,
    }
    with open(INDEX_PATH, "w") as f:
        json.dump(data, f, indent=1)


# ─── CLI ─────────────────────────────────────────────────────────────────────


def main():
    import argparse

    parser = argparse.ArgumentParser(
        description="Chess.com USCF tournament index manager"
    )
    sub = parser.add_subparsers(dest="command")

    # Build full index
    build_cmd = sub.add_parser("build", help="Build full index from scratch (~3 min)")
    build_cmd.add_argument("--rate", type=float, default=1.0,
                           help="Seconds between requests (default: 1.0)")

    # Update index (incremental)
    sub.add_parser("update", help="Update index with new tournaments")

    # Search by date
    search_cmd = sub.add_parser("search", help="Search index for a date")
    search_cmd.add_argument("date", help="Date to search (YYYY-MM-DD)")
    search_cmd.add_argument("--time-class", "-t", choices=["blitz", "rapid", "bullet"],
                            help="Filter by time class")
    search_cmd.add_argument("--no-index", action="store_true",
                            help="Force binary search (skip local index)")

    # Info
    sub.add_parser("info", help="Show index stats")

    args = parser.parse_args()

    if args.command == "build":
        global RATE_LIMIT
        RATE_LIMIT = args.rate
        print(f"Building full index (rate: {RATE_LIMIT}s/request)...")
        print(f"This will take ~{int(170 * RATE_LIMIT / 60)} minutes.\n")

        def progress(page, count):
            print(f"  Page {page:3d} | {count} tournaments indexed", end="\r")

        tournaments = build_full_index(progress_callback=progress)
        print(f"\n\nDone! {len(tournaments)} tournaments indexed.")
        save_index(tournaments)
        print(f"Saved to: {INDEX_PATH}")

    elif args.command == "update":
        existing = load_index()
        print(f"Current index: {len(existing)} tournaments")
        print("Fetching new tournaments...")
        updated = update_index(existing)
        new_count = len(updated) - len(existing)
        print(f"Added {new_count} new tournaments.")
        if new_count > 0:
            save_index(updated)
            print(f"Saved to: {INDEX_PATH}")

    elif args.command == "search":
        index = None if args.no_index else load_index()
        if not index and not args.no_index:
            print("No local index found. Using binary search (slower).")
            print("Run 'python chesscom_index.py build' to create local index.\n")

        matches = find_tournament_by_date(args.date, args.time_class, index)
        if matches:
            print(f"Tournaments on {args.date}:")
            for m in matches:
                print(f"  {m['slug']}")
                print(f"    {m['name']} | {m['players']}p | {m['rating_section']}")
        else:
            print(f"No tournaments found for {args.date}")

    elif args.command == "info":
        tournaments = load_index()
        if not tournaments:
            print("No index found. Run 'python chesscom_index.py build' first.")
            return

        # Load raw data for metadata
        with open(INDEX_PATH) as f:
            data = json.load(f)

        print(f"Index file: {INDEX_PATH}")
        print(f"Last updated: {data.get('updated_at', '?')}")
        print(f"Total tournaments: {data.get('count', len(tournaments))}")
        if tournaments:
            print(f"Date range: {tournaments[-1]['date_iso']} → {tournaments[0]['date_iso']}")
            size_kb = INDEX_PATH.stat().st_size / 1024
            print(f"File size: {size_kb:.1f} KB")

    else:
        parser.print_help()


if __name__ == "__main__":
    main()
