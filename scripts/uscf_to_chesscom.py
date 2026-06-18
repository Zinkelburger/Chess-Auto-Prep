#!/usr/bin/env python3
"""
USCF ID → Chess.com Username Resolver

Given a USCF ID, finds their chess.com username by cross-referencing
USCF-rated online events held on chess.com.

Strategy:
1. Confirm the player has online ratings (proving they've played online USCF events)
2. Find chess.com-hosted events in their USCF tournament history
3. Get the player's finishing position/score from the USCF standings API
4. Find the matching tournament on chess.com (by date + known player lookup)
5. Match by score/position to identify the chess.com username

Usage:
    python uscf_to_chesscom.py 14688723
    python uscf_to_chesscom.py 14688723 --list-events
    python uscf_to_chesscom.py 14688723 --event 201712188332
"""

import argparse
import json
import re
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

import requests

USCF_API = "https://ratings-api.uschess.org/api/v1"
CHESSCOM_API = "https://api.chess.com/pub"
CHESSCOM_CLUB = "uschess-members-only"
INDEX_PATH = Path(__file__).parent / "data" / "chesscom_tournament_index.json"

SESSION = requests.Session()
SESSION.headers.update({
    "User-Agent": "USCF-ChessCom-Resolver/1.0 (chess research tool)"
})

CHESSCOM_EVENT_KEYWORDS = ["CHESS.COM", "CHESSCOM"]
ONLINE_SYSTEMS = {"OR": "Online-Regular", "OQ": "Online-Quick", "OB": "Online-Blitz"}


@dataclass
class PlayerInfo:
    uscf_id: str
    first_name: str
    last_name: str
    online_ratings: dict = field(default_factory=dict)


@dataclass
class USCFEvent:
    event_id: str
    name: str
    start_date: str
    end_date: str
    player_count: int


@dataclass
class Standing:
    """A player's position in a USCF event section."""
    ordinal: int
    member_id: str
    first_name: str
    last_name: str
    score: float
    rounds: list = field(default_factory=list)


# ─── USCF API ────────────────────────────────────────────────────────────────


def uscf_get_player(uscf_id: str) -> PlayerInfo:
    """Fetch player profile from USCF API."""
    resp = SESSION.get(f"{USCF_API}/members/{uscf_id}", timeout=15)
    resp.raise_for_status()
    data = resp.json()

    online_ratings = {}
    for r in data.get("ratings", []):
        sys_code = r.get("ratingSystem", "")
        if sys_code in ONLINE_SYSTEMS:
            rating = r.get("rating")
            games = r.get("gamesPlayed", 0)
            if rating or (games and games > 0):
                online_ratings[sys_code] = {
                    "rating": rating,
                    "games": games or 0,
                    "provisional": r.get("isProvisional", True),
                }

    return PlayerInfo(
        uscf_id=uscf_id,
        first_name=data.get("firstName", ""),
        last_name=data.get("lastName", ""),
        online_ratings=online_ratings,
    )


def uscf_get_chesscom_events(uscf_id: str) -> list[USCFEvent]:
    """Get all chess.com-hosted events from a player's tournament history."""
    events = []
    offset = 0

    while True:
        resp = SESSION.get(
            f"{USCF_API}/members/{uscf_id}/events",
            params={"offset": offset},
            timeout=15,
        )
        resp.raise_for_status()
        data = resp.json()

        for item in data.get("items", []):
            name_upper = item["name"].upper()
            if any(kw in name_upper for kw in CHESSCOM_EVENT_KEYWORDS):
                events.append(USCFEvent(
                    event_id=item["id"],
                    name=item["name"],
                    start_date=item["startDate"],
                    end_date=item["endDate"],
                    player_count=item.get("playerCount", 0),
                ))

        if not data.get("hasNextPage", False):
            break
        offset += data.get("pageSize", 100)
        time.sleep(0.3)

    return events


def uscf_get_event_info(event_id: str) -> dict:
    """Get event metadata including sections."""
    resp = SESSION.get(f"{USCF_API}/rated-events/{event_id}", timeout=15)
    resp.raise_for_status()
    return resp.json()


def uscf_get_standings(event_id: str, section_number: int = 1) -> list[Standing]:
    """Get standings for an event section from USCF API."""
    resp = SESSION.get(
        f"{USCF_API}/rated-events/{event_id}/sections/{section_number}/standings",
        timeout=15,
    )
    resp.raise_for_status()
    data = resp.json()

    standings = []
    for item in data.get("items", []):
        rounds = []
        for ro in item.get("roundOutcomes", []):
            rounds.append({
                "round": ro["roundNumber"],
                "outcome": ro["outcome"],
                "opponent_id": ro.get("opponentMemberId", ""),
            })
        standings.append(Standing(
            ordinal=item["ordinal"],
            member_id=item["memberId"],
            first_name=item.get("firstName", ""),
            last_name=item.get("lastName", ""),
            score=item["score"],
            rounds=rounds,
        ))

    return standings


# ─── Chess.com API ───────────────────────────────────────────────────────────


def chesscom_get_player_tournaments(username: str) -> list[str]:
    """Get a player's finished tournament URLs."""
    resp = SESSION.get(f"{CHESSCOM_API}/player/{username}/tournaments", timeout=15)
    if resp.status_code != 200:
        return []
    data = resp.json()
    return [
        t.get("url", t) if isinstance(t, dict) else t
        for t in data.get("finished", [])
    ]


def chesscom_get_tournament(slug: str) -> dict | None:
    """Get tournament metadata from chess.com API."""
    resp = SESSION.get(f"{CHESSCOM_API}/tournament/{slug}", timeout=15)
    if resp.status_code != 200:
        return None
    return resp.json()


def chesscom_get_tournament_players_with_scores(slug: str) -> list[dict]:
    """
    Get all players and their final scores from a chess.com tournament.
    Combines the top-level player list with scores from round groups.
    """
    tourn = chesscom_get_tournament(slug)
    if not tourn:
        return []

    # Top-level players list (includes withdrawn)
    all_players = {
        p["username"]: {"username": p["username"], "status": p.get("status", ""), "score": 0.0}
        for p in tourn.get("players", [])
    }

    # Get scores from round groups (final round has cumulative scores)
    rounds = tourn.get("rounds", [])
    if rounds:
        # Try the last round first for final scores
        for round_url in reversed(rounds):
            resp = SESSION.get(round_url, headers=SESSION.headers, timeout=15)
            if resp.status_code != 200:
                continue
            round_data = resp.json()
            for group_url in round_data.get("groups", []):
                resp2 = SESSION.get(group_url, headers=SESSION.headers, timeout=15)
                if resp2.status_code != 200:
                    continue
                group_data = resp2.json()
                for p in group_data.get("players", []):
                    uname = p["username"]
                    score = p.get("points", 0)
                    if uname in all_players:
                        all_players[uname]["score"] = max(all_players[uname]["score"], score)
                    else:
                        all_players[uname] = {"username": uname, "status": "registered", "score": score}
            break  # Only need the last round

    # Also check earlier rounds for withdrawn players who might not be in the last round
    if rounds and len(rounds) > 1:
        for round_url in rounds[:-1]:
            resp = SESSION.get(round_url, headers=SESSION.headers, timeout=15)
            if resp.status_code != 200:
                continue
            round_data = resp.json()
            for group_url in round_data.get("groups", []):
                resp2 = SESSION.get(group_url, headers=SESSION.headers, timeout=15)
                if resp2.status_code != 200:
                    continue
                group_data = resp2.json()
                for p in group_data.get("players", []):
                    uname = p["username"]
                    score = p.get("points", 0)
                    if uname in all_players and all_players[uname]["score"] == 0:
                        all_players[uname]["score"] = score
            time.sleep(0.3)

    # Sort by score descending (mimics standings order)
    result = sorted(all_players.values(), key=lambda p: -p["score"])
    return result


def load_tournament_index() -> list[dict]:
    """Load the local chess.com tournament index."""
    if INDEX_PATH.exists():
        with open(INDEX_PATH) as f:
            data = json.load(f)
        return data.get("tournaments", [])
    return []


def chesscom_find_tournament_by_date(
    target_date: str,
    time_class: str | None = None,
    expected_players: int | None = None,
) -> str | None:
    """
    Find a chess.com USCF tournament by date using the local index.
    Falls back to binary search if index is missing.
    """
    index = load_tournament_index()

    if index:
        # Fast path: local index lookup
        matches = []
        for entry in index:
            if entry["date_iso"] != target_date:
                continue
            slug = entry["slug"]
            slug_lower = slug.lower()

            # Filter by time class
            if time_class:
                if time_class == "blitz" and "blitz" not in slug_lower:
                    continue
                if time_class == "rapid" and "rapid" not in slug_lower:
                    continue

            # Score by player count similarity
            score = 10
            if expected_players and entry.get("players"):
                count_ratio = min(entry["players"], expected_players) / max(entry["players"], expected_players)
                score += int(count_ratio * 10)
            matches.append((score, slug, entry))

        if matches:
            matches.sort(reverse=True)
            return matches[0][1]
        return None

    # No index available - fall back to binary search via chesscom_index module
    try:
        from scripts.chesscom_index import find_tournament_by_date as idx_search
        results = idx_search(target_date, time_class)
        if results:
            # Pick best match by player count
            if expected_players:
                results.sort(
                    key=lambda e: -min(e["players"], expected_players) / max(e["players"], expected_players)
                    if e["players"] else 0
                )
            return results[0]["slug"]
    except ImportError:
        pass

    return None


# ─── Matching Logic ──────────────────────────────────────────────────────────


def match_by_score(
    uscf_standings: list[Standing],
    chesscom_players: list[dict],
    target_uscf_id: str,
) -> list[dict]:
    """
    Match a USCF player to a chess.com username using score-based correlation.
    
    Returns candidate matches ranked by confidence.
    """
    # Find target in USCF standings
    target = None
    for s in uscf_standings:
        if s.member_id == target_uscf_id:
            target = s
            break

    if not target:
        return []

    target_score = target.score
    target_ordinal = target.ordinal

    # Find chess.com players with matching score
    candidates = []
    for i, p in enumerate(chesscom_players):
        if abs(p["score"] - target_score) < 0.01:
            candidates.append({
                "username": p["username"],
                "score": p["score"],
                "chesscom_rank": i + 1,
                "status": p.get("status", ""),
            })

    if len(candidates) == 1:
        candidates[0]["confidence"] = "HIGH"
        candidates[0]["reason"] = f"Unique score match ({target_score} pts)"
    elif len(candidates) > 1:
        # Try to narrow down by ordinal position proximity
        for c in candidates:
            rank_diff = abs(c["chesscom_rank"] - target_ordinal)
            c["rank_diff"] = rank_diff
            if rank_diff == 0:
                c["confidence"] = "HIGH"
                c["reason"] = "Exact position + score match"
            elif rank_diff <= 2:
                c["confidence"] = "MEDIUM"
                c["reason"] = f"Score match, position off by {rank_diff}"
            else:
                c["confidence"] = "LOW"
                c["reason"] = f"Score match only, position off by {rank_diff}"

        candidates.sort(key=lambda c: c.get("rank_diff", 999))

    return candidates


def match_by_round_results(
    uscf_standings: list[Standing],
    chesscom_players: list[dict],
    chesscom_slug: str,
    target_uscf_id: str,
) -> str | None:
    """
    Advanced matching using round-by-round game results.
    Maps USCF opponents to chess.com opponents to find the target player.
    """
    # Find target's round outcomes
    target = None
    for s in uscf_standings:
        if s.member_id == target_uscf_id:
            target = s
            break
    if not target:
        return None

    # Build a USCF ID → ordinal map
    id_to_ordinal = {s.member_id: s.ordinal for s in uscf_standings}

    # Get games from chess.com for pattern matching
    tourn = chesscom_get_tournament(chesscom_slug)
    if not tourn:
        return None

    rounds = tourn.get("rounds", [])
    # Build a map of (username, round) → (opponent, result)
    chesscom_games = {}  # username → [{round, opponent, result}]
    for round_url in rounds:
        resp = SESSION.get(round_url, timeout=15)
        if resp.status_code != 200:
            continue
        round_data = resp.json()
        for group_url in round_data.get("groups", []):
            resp2 = SESSION.get(group_url, timeout=15)
            if resp2.status_code != 200:
                continue
            for game in resp2.json().get("games", []):
                white = game.get("white", {}).get("username", "")
                black = game.get("black", {}).get("username", "")
                w_result = game.get("white", {}).get("result", "")
                b_result = game.get("black", {}).get("result", "")
                if white and black:
                    chesscom_games.setdefault(white, []).append({
                        "opponent": black,
                        "result": w_result,
                    })
                    chesscom_games.setdefault(black, []).append({
                        "opponent": white,
                        "result": b_result,
                    })
        time.sleep(0.3)

    # Match by number of games played and result pattern
    target_num_games = len(target.rounds)
    target_wins = sum(1 for r in target.rounds if r["outcome"] == "Win")
    target_losses = sum(1 for r in target.rounds if r["outcome"] == "Loss")

    best_match = None
    best_score = -1
    for username, games in chesscom_games.items():
        if len(games) != target_num_games:
            continue
        wins = sum(1 for g in games if g["result"] == "win")
        losses = sum(1 for g in games if g["result"] in ("checkmated", "resigned", "timeout", "abandoned"))
        score = 0
        if wins == target_wins:
            score += 3
        if losses == target_losses:
            score += 2
        if score > best_score:
            best_score = score
            best_match = username

    return best_match if best_score >= 4 else None


# ─── Main Resolver ───────────────────────────────────────────────────────────


def resolve(uscf_id: str, event_id: str | None = None, verbose: bool = True) -> dict:
    """
    Resolve a USCF ID to a chess.com username.
    
    Returns dict with resolution results and metadata.
    """
    result = {
        "uscf_id": uscf_id,
        "resolved_username": None,
        "confidence": None,
        "event_used": None,
    }

    # Step 1: Get player info
    if verbose:
        print(f"\n{'═'*60}")
        print(f"  USCF → Chess.com Username Resolver")
        print(f"{'═'*60}")
        print(f"\n[1/5] Fetching player info...")

    player = uscf_get_player(uscf_id)
    result["name"] = f"{player.first_name} {player.last_name}"

    if verbose:
        print(f"  Player: {player.first_name} {player.last_name}")
        if player.online_ratings:
            for sys_code, info in player.online_ratings.items():
                prov = " (provisional)" if info["provisional"] else ""
                print(f"  {ONLINE_SYSTEMS[sys_code]}: {info['rating']}{prov} [{info['games']} games]")
        else:
            print("  No current online ratings (may still have historical chess.com events)")

    # Step 2: Find chess.com events
    if verbose:
        print(f"\n[2/5] Searching for chess.com events...")

    if event_id:
        events = [USCFEvent(event_id=event_id, name="(specified)", start_date="", end_date="", player_count=0)]
    else:
        events = uscf_get_chesscom_events(uscf_id)

    if verbose:
        print(f"  Found {len(events)} chess.com events")
        for e in events[:8]:
            print(f"    {e.event_id} | {e.start_date} | {e.name} ({e.player_count}p)")
        if len(events) > 8:
            print(f"    ... +{len(events) - 8} more")

    if not events:
        if verbose:
            print("  ✗ No chess.com events in history.")
        return result

    # Step 3: Pick event and get USCF standings
    # Prefer MORE RECENT events (better chess.com API data retention)
    # with reasonable player count (10+ for unique score matching)
    events_sorted = sorted(events, key=lambda e: e.start_date, reverse=True)
    target_event = events_sorted[0]
    # If the most recent one is too small, try the next one
    for e in events_sorted:
        if e.player_count >= 15:
            target_event = e
            break
    if event_id:
        target_event = events[0]

    if verbose:
        print(f"\n[3/5] Getting USCF standings for: {target_event.name}")
        print(f"  Event ID: {target_event.event_id}")

    event_info = uscf_get_event_info(target_event.event_id)
    sections = event_info.get("sections", [])
    if not sections:
        if verbose:
            print("  ✗ No sections found for event.")
        return result

    section_num = sections[0]["number"]
    standings = uscf_get_standings(target_event.event_id, section_num)

    # Find our player
    target_standing = None
    for s in standings:
        if s.member_id == uscf_id:
            target_standing = s
            break

    if not target_standing:
        if verbose:
            print(f"  ✗ Player {uscf_id} not found in standings.")
        return result

    result["event_used"] = {
        "id": target_event.event_id,
        "name": event_info.get("name", target_event.name),
        "date": event_info.get("startDate", target_event.start_date),
    }

    if verbose:
        print(f"  Player standing: #{target_standing.ordinal} with {target_standing.score} pts")
        print(f"  Total players: {len(standings)}")
        games_played = len(target_standing.rounds)
        print(f"  Games played: {games_played}")

    # Step 4: Find matching chess.com tournament
    if verbose:
        print(f"\n[4/5] Finding chess.com tournament...")

    event_date = event_info.get("startDate", target_event.start_date)

    # Determine time class from event name
    time_class = None
    name_upper = event_info.get("name", "").upper()
    if "BLITZ" in name_upper:
        time_class = "blitz"
    elif "RAPID" in name_upper:
        time_class = "rapid"

    chesscom_slug = chesscom_find_tournament_by_date(
        event_date, time_class=time_class, expected_players=len(standings)
    )

    if not chesscom_slug:
        if verbose:
            print("  ✗ Could not auto-find tournament on chess.com")
            print(f"\n  Manual lookup instructions:")
            print(f"  1. Open: https://www.chess.com/club/live-tournaments/{CHESSCOM_CLUB}")
            print(f"  2. Look for a tournament around {event_date}")
            print(f"     Name pattern: {event_info.get('name', '?')}")
            print(f"  3. The player finished #{target_standing.ordinal} with {target_standing.score} pts")
            print(f"  4. Run again with: --tournament <chess.com-tournament-slug>")
        return result

    if verbose:
        print(f"  Found: {chesscom_slug}")

    # Step 5: Match player
    if verbose:
        print(f"\n[5/5] Matching player in chess.com standings...")

    chesscom_players = chesscom_get_tournament_players_with_scores(chesscom_slug)

    if not chesscom_players:
        if verbose:
            print("  ✗ Could not get chess.com standings.")
        return result

    if verbose:
        print(f"  Chess.com players: {len(chesscom_players)}")

    candidates = match_by_score(standings, chesscom_players, uscf_id)

    if candidates:
        best = candidates[0]
        result["resolved_username"] = best["username"]
        result["confidence"] = best.get("confidence", "LOW")
        result["candidates"] = candidates

        if verbose:
            print(f"\n  {'─'*50}")
            if best.get("confidence") == "HIGH":
                print(f"  ✓ MATCH: {best['username']}")
                print(f"    Confidence: HIGH - {best.get('reason', '')}")
            else:
                print(f"  ? Candidates (sorted by likelihood):")
                for c in candidates[:5]:
                    print(f"    • {c['username']} ({c.get('confidence','?')}) - {c.get('reason','')}")
    else:
        if verbose:
            print(f"  ✗ No score match found.")
            print(f"    USCF score: {target_standing.score}")
            print(f"    Chess.com scores available:")
            scores = sorted(set(p["score"] for p in chesscom_players), reverse=True)
            print(f"    {scores[:10]}")

    if verbose and result["resolved_username"]:
        print(f"\n{'═'*60}")
        print(f"  RESULT: {player.first_name} {player.last_name} (USCF {uscf_id})")
        print(f"        → chess.com/{result['resolved_username']}")
        print(f"{'═'*60}")

    return result


def resolve_with_slug(uscf_id: str, event_id: str, chesscom_slug: str, verbose: bool = True) -> dict:
    """
    Resolve when the user provides both the USCF event and chess.com tournament slug.
    This is the most direct path.
    """
    result = {"uscf_id": uscf_id, "resolved_username": None}

    if verbose:
        print(f"\n{'═'*60}")
        print(f"  Direct Resolution Mode")
        print(f"{'═'*60}")

    # Get USCF standings
    if verbose:
        print(f"\n  USCF Event: {event_id}")
    event_info = uscf_get_event_info(event_id)
    sections = event_info.get("sections", [])
    section_num = sections[0]["number"] if sections else 1
    standings = uscf_get_standings(event_id, section_num)

    target = None
    for s in standings:
        if s.member_id == uscf_id:
            target = s
            break

    if not target:
        if verbose:
            print(f"  ✗ Player not found in USCF standings")
        return result

    if verbose:
        print(f"  Player: {target.first_name} {target.last_name}")
        print(f"  Position: #{target.ordinal}, Score: {target.score}")

    # Get chess.com data
    if verbose:
        print(f"\n  Chess.com Tournament: {chesscom_slug}")

    chesscom_players = chesscom_get_tournament_players_with_scores(chesscom_slug)
    if verbose:
        print(f"  Players found: {len(chesscom_players)}")

    candidates = match_by_score(standings, chesscom_players, uscf_id)

    if candidates:
        best = candidates[0]
        result["resolved_username"] = best["username"]
        result["confidence"] = best.get("confidence")
        result["candidates"] = candidates

        if verbose:
            print(f"\n  {'─'*50}")
            print(f"  USCF #{target.ordinal} ({target.score} pts) → chess.com candidates:")
            for c in candidates[:5]:
                conf = c.get("confidence", "?")
                print(f"    [{conf:6s}] {c['username']} ({c['score']} pts, rank #{c['chesscom_rank']})")

            print(f"\n{'═'*60}")
            print(f"  BEST MATCH: {best['username']}")
            print(f"{'═'*60}")

    return result


# ─── CLI ─────────────────────────────────────────────────────────────────────


def main():
    parser = argparse.ArgumentParser(
        description="Resolve USCF ID → chess.com username via online tournament cross-reference",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  %(prog)s 14688723                    # Auto-resolve
  %(prog)s 14688723 --list-events      # Show chess.com events
  %(prog)s 14688723 --event 201712188332 --tournament -us-chess-100-blitz-915554
  %(prog)s --build-index               # Build/rebuild local chess.com tournament index
  %(prog)s --update-index              # Update index with recent tournaments
        """,
    )
    parser.add_argument("uscf_id", nargs="?", help="USCF member ID")
    parser.add_argument("--list-events", "-l", action="store_true",
                        help="List chess.com events for the player")
    parser.add_argument("--event", "-e",
                        help="Specific USCF event ID to use")
    parser.add_argument("--tournament", "-t",
                        help="Chess.com tournament slug (if known)")
    parser.add_argument("--json", action="store_true",
                        help="Output as JSON")
    parser.add_argument("--quiet", "-q", action="store_true",
                        help="Minimal output")
    parser.add_argument("--build-index", action="store_true",
                        help="Build chess.com tournament index from scratch")
    parser.add_argument("--update-index", action="store_true",
                        help="Update chess.com tournament index with new events")

    args = parser.parse_args()

    # Index management commands
    if args.build_index or args.update_index:
        from scripts.chesscom_index import build_full_index, update_index, load_index, save_index
        if args.build_index:
            print("Building chess.com tournament index...")
            def progress(page, count):
                print(f"  Page {page:3d} | {count} tournaments", end="\r")
            tournaments = build_full_index(progress_callback=progress)
            print(f"\n  Done! {len(tournaments)} tournaments indexed.")
            save_index(tournaments)
            print(f"  Saved to: {INDEX_PATH}")
        else:
            existing = load_index()
            print(f"  Current index: {len(existing)} tournaments")
            updated = update_index(existing)
            new_count = len(updated) - len(existing)
            print(f"  Added {new_count} new tournaments.")
            if new_count > 0:
                save_index(updated)
        return

    if not args.uscf_id:
        parser.print_help()
        return

    if args.list_events:
        player = uscf_get_player(args.uscf_id)
        print(f"\nChess.com events for {player.first_name} {player.last_name} (USCF {args.uscf_id}):\n")
        events = uscf_get_chesscom_events(args.uscf_id)
        if not events:
            print("  No chess.com events found.")
            return
        for e in events:
            print(f"  {e.event_id} | {e.start_date} | {e.name} ({e.player_count}p)")
        print(f"\n  Total: {len(events)} events")
        return

    if args.event and args.tournament:
        # Direct mode: both USCF event and chess.com tournament provided
        slug = args.tournament
        if "chess.com" in slug:
            m = re.search(r"/tournament/(?:live/)?(.+?)(?:\?|$)", slug)
            if m:
                slug = m.group(1)

        result = resolve_with_slug(args.uscf_id, args.event, slug, verbose=not args.quiet)
    else:
        result = resolve(args.uscf_id, event_id=args.event, verbose=not args.quiet)

    if args.json:
        print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
