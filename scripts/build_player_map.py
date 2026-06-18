#!/usr/bin/env python3
"""
Build USCF → Chess.com player mapping database.

Uses two strategies depending on data availability:
1. Opponent-Graph BFS (post Jan 2020): 100% confidence by matching round-by-round
   opponents. If USCF player A played opponent B in round 3, and their chess.com
   equivalent played username Y in round 3, then B = Y.
2. Score-based matching (pre-2020, no game data): lower confidence, records all
   possibilities when ambiguous.

Output: scripts/data/player_mapping.json
"""

import asyncio
import json
import sys
import time
from collections import Counter
from dataclasses import dataclass, field
from pathlib import Path

import aiohttp
import requests

USCF_API = "https://ratings-api.uschess.org/api/v1"
CHESSCOM_API = "https://api.chess.com/pub"
INDEX_PATH = Path(__file__).parent / "data" / "chesscom_tournament_index.json"
OUTPUT_PATH = Path(__file__).parent / "data" / "player_mapping.json"
EVENT_MAP_PATH = Path(__file__).parent / "data" / "event_mapping.json"
USCF_EVENTS_CACHE = Path(__file__).parent / "data" / "uscf_events_cache.json"
AFFILIATE_ID = "A6044892"  # CHESSCOM LLC

SESSION = requests.Session()
SESSION.headers.update({"User-Agent": "USCF-ChessCom-Mapper/1.0"})

# Game data cutoff: chess.com retains full game records only after this date
GAME_DATA_CUTOFF = "2020-01-09"


# ─── Data Structures ─────────────────────────────────────────────────────────


@dataclass
class PlayerMatch:
    uscf_id: str
    uscf_name: str
    chesscom_username: str | None
    confidence: str  # "exact", "high", "medium", "low", "ambiguous", "unmappable"
    method: str  # "opponent_graph", "forfeit_correlation", "signature", "score_position", "elimination"
    candidates: list[str] = field(default_factory=list)
    notes: str = ""


# ─── USCF API ────────────────────────────────────────────────────────────────


def uscf_request(url: str, params: dict | None = None, retries: int = 3) -> dict | None:
    """Make a USCF API request with retry and rate-limit handling."""
    for attempt in range(retries):
        try:
            resp = SESSION.get(url, params=params, timeout=30)
        except (requests.exceptions.Timeout, requests.exceptions.ConnectionError) as e:
            wait = 10 * (attempt + 1)
            print(f"    [timeout/connection error, waiting {wait}s...]")
            time.sleep(wait)
            continue
        if resp.status_code == 429:
            wait = 10 * (attempt + 1)
            print(f"    [rate limited, waiting {wait}s...]")
            time.sleep(wait)
            continue
        if resp.status_code != 200:
            return None
        return resp.json()
    return None


def uscf_get_all_affiliate_events(use_cache: bool = True) -> list[dict]:
    """Fetch all events from the CHESSCOM LLC affiliate. Uses disk cache."""
    if use_cache and USCF_EVENTS_CACHE.exists():
        with open(USCF_EVENTS_CACHE) as f:
            cached = json.load(f)
        print(f"  (loaded {len(cached)} events from cache)")
        return cached

    events = []
    offset = 0
    while True:
        data = uscf_request(
            f"{USCF_API}/affiliates/{AFFILIATE_ID}/events",
            params={"offset": offset, "limit": 100},
        )
        if not data:
            break
        items = data.get("items", [])
        if not items:
            break
        events.extend(items)
        print(f"  fetched {len(events)} events...", end="\r")
        if not data.get("hasNextPage", False):
            break
        offset += len(items)
        time.sleep(1.0)

    # Cache to disk
    if events:
        USCF_EVENTS_CACHE.parent.mkdir(parents=True, exist_ok=True)
        with open(USCF_EVENTS_CACHE, "w") as f:
            json.dump(events, f)
        print(f"  cached {len(events)} events to disk")

    return events


def uscf_get_standings(event_id: str, section_number: int = 1) -> list[dict] | None:
    """Get full standings with round outcomes for an event section."""
    data = uscf_request(
        f"{USCF_API}/rated-events/{event_id}/sections/{section_number}/standings",
    )
    if not data:
        return None
    return data.get("items", [])


def uscf_get_event_info(event_id: str) -> dict | None:
    """Get event metadata including sections."""
    return uscf_request(f"{USCF_API}/rated-events/{event_id}")


# ─── Chess.com API (async) ───────────────────────────────────────────────────


async def cc_fetch(session: aiohttp.ClientSession, url: str) -> dict | None:
    """Fetch a chess.com API endpoint with rate limiting."""
    try:
        async with session.get(url) as resp:
            if resp.status == 429:
                await asyncio.sleep(5)
                async with session.get(url) as retry:
                    if retry.status == 200:
                        return await retry.json()
                return None
            if resp.status != 200:
                return None
            return await resp.json()
    except (aiohttp.ClientError, asyncio.TimeoutError):
        return None


async def cc_get_tournament_games(slug: str) -> dict:
    """
    Fetch all game data for a chess.com tournament.
    Returns {username: [{round, color, opponent, result}]} or empty if no game data.
    """
    timeout = aiohttp.ClientTimeout(total=60)
    async with aiohttp.ClientSession(
        headers={"User-Agent": "USCF-ChessCom-Mapper/1.0"},
        timeout=timeout,
    ) as session:
        tourn = await cc_fetch(session, f"{CHESSCOM_API}/tournament/{slug}")
        if not tourn or not tourn.get("rounds"):
            return {}

        rounds_urls = tourn["rounds"]
        cc_games: dict[str, list[dict]] = {}

        for rnd_idx, rnd_url in enumerate(rounds_urls, 1):
            rnd_data = await cc_fetch(session, rnd_url)
            if not rnd_data:
                continue

            for group_url in rnd_data.get("groups", []):
                group = await cc_fetch(session, group_url)
                if not group:
                    continue

                for game in group.get("games", []):
                    w = game.get("white", {})
                    b = game.get("black", {})
                    w_user = w.get("username", "")
                    b_user = b.get("username", "")
                    if not w_user or not b_user:
                        continue

                    cc_games.setdefault(w_user, []).append({
                        "round": rnd_idx,
                        "color": "W",
                        "opponent": b_user,
                        "result": w.get("result", ""),
                    })
                    cc_games.setdefault(b_user, []).append({
                        "round": rnd_idx,
                        "color": "B",
                        "opponent": w_user,
                        "result": b.get("result", ""),
                    })

            await asyncio.sleep(0.3)

        # Check if there's actual game data (not just empty player lists)
        has_games = any(len(games) > 0 for games in cc_games.values())
        return cc_games if has_games else {}


async def cc_get_tournament_scores(slug: str) -> dict[str, float]:
    """Get final scores for all players in a tournament (for pre-2020 fallback)."""
    timeout = aiohttp.ClientTimeout(total=60)
    async with aiohttp.ClientSession(
        headers={"User-Agent": "USCF-ChessCom-Mapper/1.0"},
        timeout=timeout,
    ) as session:
        tourn = await cc_fetch(session, f"{CHESSCOM_API}/tournament/{slug}")
        if not tourn:
            return {}

        scores: dict[str, float] = {}
        rounds_urls = tourn.get("rounds", [])
        if not rounds_urls:
            return {}

        # Last round has cumulative scores
        rnd_data = await cc_fetch(session, rounds_urls[-1])
        if not rnd_data:
            return {}

        for group_url in rnd_data.get("groups", []):
            group = await cc_fetch(session, group_url)
            if not group:
                continue
            for p in group.get("players", []):
                scores[p["username"]] = p.get("points", 0)

        # Also check earlier rounds for withdrawn players
        for rnd_url in rounds_urls[:-1]:
            rnd_data = await cc_fetch(session, rnd_url)
            if not rnd_data:
                continue
            for group_url in rnd_data.get("groups", []):
                group = await cc_fetch(session, group_url)
                if not group:
                    continue
                for p in group.get("players", []):
                    uname = p["username"]
                    if uname not in scores:
                        scores[uname] = p.get("points", 0)

        return scores


# ─── Opponent-Graph BFS (100% confidence) ────────────────────────────────────


def outcomes_match(uscf_outcome: str, cc_result: str) -> bool:
    """Check if USCF outcome corresponds to chess.com result."""
    if uscf_outcome in ("Win", "WinForfeit") and cc_result == "win":
        return True
    if uscf_outcome == "Loss" and cc_result in (
        "checkmated", "resigned", "timeout", "abandoned",
    ):
        return True
    if uscf_outcome == "Draw" and cc_result in (
        "agreed", "stalemate", "repetition", "insufficient",
        "50move", "timevsinsufficient",
    ):
        return True
    return False


def cc_result_to_wld(result: str) -> str:
    """Convert chess.com result to W/L/D."""
    if result == "win":
        return "W"
    if result in ("agreed", "stalemate", "repetition", "insufficient",
                  "50move", "timevsinsufficient"):
        return "D"
    return "L"


def find_seed(standings: list[dict], cc_games: dict[str, list[dict]]) -> tuple[str, str] | None:
    """
    Find a unique seed mapping by matching (round, outcome) signatures.
    Returns (uscf_member_id, cc_username) or None.
    """
    # Build all CC signatures
    cc_signatures: dict[str, list[tuple]] = {}
    for username, games in cc_games.items():
        sig = tuple(
            (g["round"], cc_result_to_wld(g["result"]))
            for g in sorted(games, key=lambda x: x["round"])
        )
        cc_signatures.setdefault(sig, []).append(username)

    # Try USCF players from highest score down - prefer unique signatures
    for s in sorted(standings, key=lambda x: -x["score"]):
        sig = []
        for r in sorted(s["roundOutcomes"], key=lambda x: x["roundNumber"]):
            if r["outcome"] in ("Win", "WinForfeit"):
                sig.append((r["roundNumber"], "W"))
            elif r["outcome"] == "Loss":
                sig.append((r["roundNumber"], "L"))
            elif r["outcome"] == "Draw":
                sig.append((r["roundNumber"], "D"))

        sig_tuple = tuple(sig)
        matches = cc_signatures.get(sig_tuple, [])
        if len(matches) == 1:
            return (s["memberId"], matches[0])

    return None


def opponent_graph_bfs(
    standings: list[dict],
    cc_games: dict[str, list[dict]],
) -> dict[str, str]:
    """
    Map USCF member IDs to chess.com usernames via opponent-graph BFS.
    Returns {uscf_member_id: cc_username}.
    """
    seed = find_seed(standings, cc_games)
    if not seed:
        return {}

    mapping: dict[str, str] = {seed[0]: seed[1]}
    processed: set[str] = set()
    queue: list[str] = [seed[0]]

    while queue:
        uid = queue.pop(0)
        if uid in processed:
            continue
        processed.add(uid)

        uscf_player = next((s for s in standings if s["memberId"] == uid), None)
        if not uscf_player:
            continue
        cc_username = mapping.get(uid)
        if not cc_username:
            continue

        cc_player_games = {
            g["round"]: g for g in cc_games.get(cc_username, [])
        }

        for r in uscf_player["roundOutcomes"]:
            rnd = r["roundNumber"]
            opp_id = r.get("opponentMemberId", "")

            if r["outcome"] == "WinForfeit" and not opp_id:
                # Forfeit: CC game exists but USCF has no opponent ID
                # Handle in forfeit_correlation phase
                continue

            if not opp_id or opp_id in mapping:
                continue

            cc_game = cc_player_games.get(rnd)
            if not cc_game:
                continue

            if outcomes_match(r["outcome"], cc_game["result"]):
                mapping[opp_id] = cc_game["opponent"]
                queue.append(opp_id)

    return mapping


def forfeit_correlation(
    standings: list[dict],
    cc_games: dict[str, list[dict]],
    mapping: dict[str, str],
) -> dict[str, str]:
    """
    Match forfeit players by correlating WinForfeit rounds with CC game data.
    Returns additional mappings.
    """
    additions: dict[str, str] = {}

    for s in standings:
        if s["memberId"] not in mapping:
            continue
        cc_username = mapping[s["memberId"]]
        cc_player_games = {g["round"]: g for g in cc_games.get(cc_username, [])}

        for r in s["roundOutcomes"]:
            if r["outcome"] != "WinForfeit":
                continue

            cc_game = cc_player_games.get(r["roundNumber"])
            if not cc_game:
                continue
            cc_opponent = cc_game["opponent"]
            if cc_opponent in mapping.values() or cc_opponent in additions.values():
                continue

            # Find the USCF player who forfeited in this round
            for s2 in standings:
                if s2["memberId"] in mapping or s2["memberId"] in additions:
                    continue
                for r2 in s2["roundOutcomes"]:
                    if (r2["roundNumber"] == r["roundNumber"]
                            and r2["outcome"] == "Forfeit"):
                        additions[s2["memberId"]] = cc_opponent
                        break

    return additions


def match_disconnected_components(
    standings: list[dict],
    cc_games: dict[str, list[dict]],
    mapping: dict[str, str],
) -> dict[str, str]:
    """
    Match players in disconnected components (only played each other).
    Uses signature matching + internal opponent consistency.
    """
    unmapped_uscf = [s for s in standings if s["memberId"] not in mapping]
    mapped_cc = set(mapping.values())
    unmapped_cc = {u for u in cc_games if u not in mapped_cc}

    if not unmapped_uscf or not unmapped_cc:
        return {}

    additions: dict[str, str] = {}

    # Build CC signatures for unmapped players
    cc_sigs: dict[str, list[tuple]] = {}
    for username in unmapped_cc:
        games = cc_games[username]
        sig = tuple(
            (g["round"], cc_result_to_wld(g["result"]))
            for g in sorted(games, key=lambda x: x["round"])
        )
        cc_sigs.setdefault(sig, []).append(username)

    # Try to match each unmapped USCF player by signature
    for s in unmapped_uscf:
        if s["memberId"] in additions:
            continue
        sig = []
        for r in sorted(s["roundOutcomes"], key=lambda x: x["roundNumber"]):
            if r["outcome"] in ("Win", "WinForfeit"):
                sig.append((r["roundNumber"], "W"))
            elif r["outcome"] == "Loss":
                sig.append((r["roundNumber"], "L"))
            elif r["outcome"] == "Draw":
                sig.append((r["roundNumber"], "D"))

        sig_tuple = tuple(sig)
        candidates = [u for u in cc_sigs.get(sig_tuple, [])
                      if u not in mapping.values() and u not in additions.values()]

        if len(candidates) == 1:
            additions[s["memberId"]] = candidates[0]

    # Verify opponent consistency within disconnected pairs
    # For each newly mapped pair, check their opponents also match
    verified: dict[str, str] = {}
    for uid, cc_user in additions.items():
        uscf_player = next((s for s in standings if s["memberId"] == uid), None)
        if not uscf_player:
            continue

        consistent = True
        for r in uscf_player["roundOutcomes"]:
            opp_id = r.get("opponentMemberId", "")
            if not opp_id:
                continue
            cc_game = next(
                (g for g in cc_games.get(cc_user, []) if g["round"] == r["roundNumber"]),
                None,
            )
            if not cc_game:
                consistent = False
                break
            # Check opponent is also consistently mapped
            if opp_id in additions:
                if additions[opp_id] != cc_game["opponent"]:
                    consistent = False
                    break

        if consistent:
            verified[uid] = cc_user

    return verified


# ─── Score-Based Fallback (pre-2020) ─────────────────────────────────────────


def score_based_matching(
    standings: list[dict],
    cc_scores: dict[str, float],
) -> list[PlayerMatch]:
    """
    Match players by score and ordinal position (for tournaments without game data).
    Returns matches with confidence levels and all candidates when ambiguous.
    """
    results: list[PlayerMatch] = []

    # Sort CC players by score descending
    cc_sorted = sorted(cc_scores.items(), key=lambda x: -x[1])

    for s in standings:
        uid = s["memberId"]
        name = f"{s.get('firstName', '')} {s.get('lastName', '')}".strip()
        target_score = s["score"]
        target_ordinal = s["ordinal"]

        # Count real games played (not byes/unpaired)
        real_games = sum(
            1 for r in s["roundOutcomes"]
            if r.get("opponentMemberId")
        )

        # Players with no real games can't be matched
        if real_games == 0:
            results.append(PlayerMatch(
                uscf_id=uid,
                uscf_name=name,
                chesscom_username=None,
                confidence="unmappable",
                method="score_position",
                notes="No real games played (all byes/unpaired)",
            ))
            continue

        # Find CC players with same score
        same_score = [u for u, sc in cc_sorted if sc == target_score]

        if not same_score:
            # Try +/- 0.5 for scoring discrepancies (byes/forfeits)
            near_score = [
                u for u, sc in cc_sorted
                if abs(sc - target_score) <= 0.5
            ]
            if len(near_score) == 1:
                results.append(PlayerMatch(
                    uscf_id=uid,
                    uscf_name=name,
                    chesscom_username=near_score[0],
                    confidence="low",
                    method="score_position",
                    candidates=near_score,
                    notes="Score ±0.5 match (possible bye/forfeit scoring difference)",
                ))
            elif near_score:
                results.append(PlayerMatch(
                    uscf_id=uid,
                    uscf_name=name,
                    chesscom_username=None,
                    confidence="ambiguous",
                    method="score_position",
                    candidates=near_score,
                    notes=f"No exact score match; {len(near_score)} candidates at ±0.5",
                ))
            else:
                results.append(PlayerMatch(
                    uscf_id=uid,
                    uscf_name=name,
                    chesscom_username=None,
                    confidence="ambiguous",
                    method="score_position",
                    notes="No score match found",
                ))
            continue

        if len(same_score) == 1:
            results.append(PlayerMatch(
                uscf_id=uid,
                uscf_name=name,
                chesscom_username=same_score[0],
                confidence="high",
                method="score_position",
                candidates=same_score,
                notes="Unique score match",
            ))
        else:
            # Multiple players with same score - use ordinal proximity
            # Find the CC player at similar ordinal position
            score_group_uscf = [
                st for st in standings if st["score"] == target_score
            ]
            rank_in_group = next(
                (i for i, st in enumerate(score_group_uscf)
                 if st["memberId"] == uid),
                0,
            )

            if rank_in_group < len(same_score):
                best_guess = same_score[rank_in_group]
                conf = "medium" if len(same_score) <= 3 else "low"
            else:
                best_guess = same_score[-1]
                conf = "low"

            results.append(PlayerMatch(
                uscf_id=uid,
                uscf_name=name,
                chesscom_username=best_guess,
                confidence=conf,
                method="score_position",
                candidates=same_score,
                notes=f"{len(same_score)} players with score {target_score}; matched by ordinal position",
            ))

    return results


# ─── Event Mapping ───────────────────────────────────────────────────────────


def load_tournament_index() -> list[dict]:
    """Load the local chess.com tournament index."""
    if INDEX_PATH.exists():
        with open(INDEX_PATH) as f:
            return json.load(f).get("tournaments", [])
    return []


def infer_time_class(event_name: str) -> str | None:
    """Infer time class from USCF event name."""
    name_upper = event_name.upper()
    if "BLITZ" in name_upper:
        return "blitz"
    if "RAPID" in name_upper:
        return "rapid"
    return None


def build_event_mapping(uscf_events: list[dict], index: list[dict]) -> dict[str, dict]:
    """
    Map USCF event IDs to chess.com tournament slugs.
    Returns {uscf_event_id: {slug, confidence, ...}}.
    Handles same-day duplicates (#1/#2 events) by assigning different slugs.
    """
    # Index by date for fast lookup
    index_by_date: dict[str, list[dict]] = {}
    for entry in index:
        index_by_date.setdefault(entry["date_iso"], []).append(entry)

    # Group USCF events by (date, time_class, is_u1450) to detect duplicates
    uscf_groups: dict[tuple, list[dict]] = {}
    for evt in uscf_events:
        key = (evt["startDate"], infer_time_class(evt["name"]), "U1450" in evt["name"].upper())
        uscf_groups.setdefault(key, []).append(evt)

    # Track which slugs have been assigned to avoid double-mapping
    assigned_slugs: dict[str, str] = {}  # slug → uscf_event_id

    event_map: dict[str, dict] = {}

    for evt in uscf_events:
        eid = evt["id"]
        date = evt["startDate"]
        name = evt["name"]
        players = evt.get("playerCount", 0)
        time_class = infer_time_class(name)
        is_u1450 = "U1450" in name.upper()

        candidates = index_by_date.get(date, [])

        if not candidates:
            event_map[eid] = {
                "slug": None,
                "confidence": "none",
                "note": f"No chess.com tournament found on {date}",
            }
            continue

        # Score candidates
        scored = []
        for c in candidates:
            slug_lower = c["slug"].lower()
            score = 0

            # Time class match
            if time_class == "blitz" and "blitz" in slug_lower:
                score += 10
            elif time_class == "rapid" and "rapid" in slug_lower:
                score += 10
            elif time_class and time_class not in slug_lower:
                score -= 5

            # U1450 section match
            if is_u1450 and "u1450" in slug_lower:
                score += 20
            elif is_u1450 and "u1450" not in slug_lower:
                score -= 20
            elif not is_u1450 and "u1450" in slug_lower:
                score -= 20

            # Player count similarity
            if players and c.get("players"):
                ratio = min(players, c["players"]) / max(players, c["players"])
                score += int(ratio * 10)

            # Penalize already-assigned slugs (avoid double-mapping)
            if c["slug"] in assigned_slugs and assigned_slugs[c["slug"]] != eid:
                score -= 15

            scored.append((score, c))

        scored.sort(key=lambda x: -x[0])
        best_score, best = scored[0]

        if best_score >= 15:
            conf = "high"
        elif best_score >= 5:
            conf = "medium"
        else:
            conf = "low"

        event_map[eid] = {
            "slug": best["slug"],
            "confidence": conf,
            "cc_players": best.get("players"),
            "date": date,
        }
        assigned_slugs[best["slug"]] = eid

    return event_map


# ─── Main Pipeline ───────────────────────────────────────────────────────────


def process_tournament(
    event_id: str,
    slug: str,
    uscf_standings: list[dict],
    has_game_data: bool,
) -> list[PlayerMatch]:
    """Process a single tournament and return all player matches."""
    results: list[PlayerMatch] = []

    if has_game_data:
        # Primary method: opponent-graph BFS
        cc_games = asyncio.run(cc_get_tournament_games(slug))

        if not cc_games:
            # Game data expected but not available - fall back
            has_game_data = False
        else:
            # Phase 1: BFS
            mapping = opponent_graph_bfs(uscf_standings, cc_games)

            # Phase 2: Forfeit correlation
            forfeit_adds = forfeit_correlation(uscf_standings, cc_games, mapping)
            mapping.update(forfeit_adds)

            # Phase 3: Disconnected components
            disconnected_adds = match_disconnected_components(
                uscf_standings, cc_games, mapping,
            )
            mapping.update(disconnected_adds)

            # Build results
            mapped_cc = set(mapping.values())
            unmapped_cc = set(cc_games.keys()) - mapped_cc

            for s in uscf_standings:
                uid = s["memberId"]
                name = f"{s.get('firstName', '')} {s.get('lastName', '')}".strip()

                if uid in mapping:
                    method = "opponent_graph"
                    if uid in forfeit_adds:
                        method = "forfeit_correlation"
                    elif uid in disconnected_adds:
                        method = "signature"

                    results.append(PlayerMatch(
                        uscf_id=uid,
                        uscf_name=name,
                        chesscom_username=mapping[uid],
                        confidence="exact",
                        method=method,
                    ))
                else:
                    # Unmapped - check if they ever played a real game
                    real_games = sum(
                        1 for r in s["roundOutcomes"]
                        if r.get("opponentMemberId")
                    )

                    if real_games == 0:
                        # Never played - check if there are unmapped CC users
                        # who could be them (by signature)
                        sig = []
                        for r in sorted(s["roundOutcomes"], key=lambda x: x["roundNumber"]):
                            if r["outcome"] in ("Win", "WinForfeit"):
                                sig.append((r["roundNumber"], "W"))
                            elif r["outcome"] == "Loss":
                                sig.append((r["roundNumber"], "L"))
                            elif r["outcome"] == "Draw":
                                sig.append((r["roundNumber"], "D"))

                        if not sig:
                            results.append(PlayerMatch(
                                uscf_id=uid,
                                uscf_name=name,
                                chesscom_username=None,
                                confidence="unmappable",
                                method="opponent_graph",
                                notes="Never played a game (all byes/unpaired/withdrew)",
                            ))
                        else:
                            candidates = list(unmapped_cc)
                            results.append(PlayerMatch(
                                uscf_id=uid,
                                uscf_name=name,
                                chesscom_username=None,
                                confidence="ambiguous",
                                method="opponent_graph",
                                candidates=candidates,
                                notes=f"Could not reach via graph; {len(candidates)} unmapped CC users remain",
                            ))
                    else:
                        # Has games but couldn't be reached - shouldn't happen often
                        candidates = list(unmapped_cc)
                        results.append(PlayerMatch(
                            uscf_id=uid,
                            uscf_name=name,
                            chesscom_username=None,
                            confidence="ambiguous",
                            method="opponent_graph",
                            candidates=candidates,
                            notes=f"Has {real_games} games but unreachable via BFS; possible outcome mismatch",
                        ))

            return results

    # Fallback: score-based matching
    cc_scores = asyncio.run(cc_get_tournament_scores(slug))
    if not cc_scores:
        for s in uscf_standings:
            name = f"{s.get('firstName', '')} {s.get('lastName', '')}".strip()
            results.append(PlayerMatch(
                uscf_id=s["memberId"],
                uscf_name=name,
                chesscom_username=None,
                confidence="ambiguous",
                method="score_position",
                notes="Could not fetch chess.com tournament data",
            ))
        return results

    return score_based_matching(uscf_standings, cc_scores)


def load_existing_output() -> dict:
    """Load existing output for resume support."""
    if OUTPUT_PATH.exists():
        with open(OUTPUT_PATH) as f:
            return json.load(f)
    return {"players": {}, "events_processed": [], "stats": {}}


def save_output(data: dict):
    """Save output atomically."""
    OUTPUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    tmp = OUTPUT_PATH.with_suffix(".tmp")
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2)
    tmp.rename(OUTPUT_PATH)


def main():
    import argparse
    parser = argparse.ArgumentParser(description="Build USCF→Chess.com player mapping")
    parser.add_argument("--resume", action="store_true", help="Resume from last checkpoint")
    parser.add_argument("--limit", type=int, help="Limit number of events to process")
    parser.add_argument("--start-date", help="Only process events on or after this date (YYYY-MM-DD)")
    parser.add_argument("--end-date", help="Only process events on or before this date (YYYY-MM-DD)")
    parser.add_argument("--event", help="Process a single event ID")
    parser.add_argument("--dry-run", action="store_true", help="Show plan without processing")
    args = parser.parse_args()

    print("Loading chess.com tournament index...")
    index = load_tournament_index()
    if not index:
        print("ERROR: No tournament index found. Run: python scripts/chesscom_index.py build")
        sys.exit(1)
    print(f"  {len(index)} tournaments in index")

    # Load or initialize output
    output = load_existing_output() if args.resume else {"players": {}, "events_processed": [], "stats": {}}
    processed_events = set(output.get("events_processed", []))

    # Fetch all USCF events from affiliate
    print("Fetching USCF events from CHESSCOM LLC affiliate...")
    uscf_events = uscf_get_all_affiliate_events()
    print(f"  {len(uscf_events)} total events")

    # Build event mapping
    print("Building event mapping (USCF → chess.com)...")
    event_map = build_event_mapping(uscf_events, index)

    # Filter events to process
    events_to_process = []
    for evt in uscf_events:
        eid = evt["id"]
        if eid in processed_events:
            continue
        if args.event and eid != args.event:
            continue
        if args.start_date and evt["startDate"] < args.start_date:
            continue
        if args.end_date and evt["startDate"] > args.end_date:
            continue
        em = event_map.get(eid, {})
        if not em.get("slug"):
            continue
        events_to_process.append(evt)

    if args.limit:
        events_to_process = events_to_process[:args.limit]

    # Sort by date (newest first for more relevant data)
    events_to_process.sort(key=lambda e: e["startDate"], reverse=True)

    # Determine which have game data
    game_data_events = [e for e in events_to_process if e["startDate"] > GAME_DATA_CUTOFF]
    score_only_events = [e for e in events_to_process if e["startDate"] <= GAME_DATA_CUTOFF]

    print(f"\nEvents to process: {len(events_to_process)}")
    print(f"  With game data (100% confidence): {len(game_data_events)}")
    print(f"  Score-only fallback: {len(score_only_events)}")

    if args.dry_run:
        print("\n[DRY RUN] Would process these events:")
        for e in events_to_process[:20]:
            em = event_map.get(e["id"], {})
            has_gd = "✓" if e["startDate"] > GAME_DATA_CUTOFF else "✗"
            print(f"  {e['startDate']} {e['name'][:50]:<50} → {em.get('slug','?')[:40]} [{has_gd}]")
        if len(events_to_process) > 20:
            print(f"  ... and {len(events_to_process) - 20} more")
        return

    # Process events
    total = len(events_to_process)
    stats = Counter()
    start_time = time.time()

    for i, evt in enumerate(events_to_process, 1):
        eid = evt["id"]
        date = evt["startDate"]
        name = evt["name"]
        slug = event_map[eid]["slug"]
        has_game_data = date > GAME_DATA_CUTOFF

        # Skip if event mapping confidence is too low (likely wrong slug)
        em_conf = event_map[eid].get("confidence", "")
        if em_conf == "low":
            stats["skipped_low_conf"] += 1
            output["events_processed"].append(eid)
            if i % 10 == 0:
                output["stats"] = dict(stats)
                save_output(output)
            continue

        print(f"\n[{i}/{total}] {date} {name[:60]}")
        print(f"  → {slug} ({'graph' if has_game_data else 'score'})")

        try:
            # Get USCF standings
            event_info = uscf_get_event_info(eid)
            if not event_info:
                print("  ✗ Could not fetch event info")
                stats["error"] += 1
                continue

            sections = event_info.get("sections", [])
            if not sections:
                print("  ✗ No sections found")
                stats["error"] += 1
                continue

            time.sleep(1.0)

            for section in sections:
                section_num = section["number"]
                standings = uscf_get_standings(eid, section_num)
                if not standings:
                    print(f"  ✗ Could not fetch standings for section {section_num}")
                    stats["error"] += 1
                    continue

                # Process this tournament section
                try:
                    matches = process_tournament(eid, slug, standings, has_game_data)
                except Exception as e:
                    print(f"  ✗ Error: {e}")
                    stats["error"] += 1
                    continue

                # Record results
                exact = 0
                ambiguous = 0
                for m in matches:
                    stats[m.confidence] += 1
                    if m.confidence == "exact":
                        exact += 1
                    elif m.confidence == "ambiguous":
                        ambiguous += 1

                    # Store in output
                    entry = {
                        "chesscom_username": m.chesscom_username,
                        "uscf_name": m.uscf_name,
                        "confidence": m.confidence,
                        "method": m.method,
                        "event_id": eid,
                        "event_date": date,
                    }
                    if m.candidates:
                        entry["candidates"] = m.candidates
                    if m.notes:
                        entry["notes"] = m.notes

                    # Keep the highest-confidence match for each player
                    existing = output["players"].get(m.uscf_id)
                    conf_rank = {"exact": 5, "high": 4, "medium": 3, "low": 2, "ambiguous": 1, "unmappable": 0}
                    if (not existing
                            or conf_rank.get(m.confidence, 0) > conf_rank.get(existing.get("confidence"), 0)):
                        output["players"][m.uscf_id] = entry

                print(f"  ✓ {len(standings)} players: {exact} exact, {ambiguous} ambiguous")

        except Exception as e:
            print(f"  ✗ Unexpected error: {e}")
            stats["error"] += 1

        # Mark event as processed
        output["events_processed"].append(eid)
        processed_events.add(eid)

        # Save checkpoint every 10 events
        if i % 10 == 0:
            output["stats"] = dict(stats)
            save_output(output)
            elapsed = time.time() - start_time
            rate = i / elapsed if elapsed > 0 else 0
            remaining = (total - i) / rate if rate > 0 else 0
            print(f"  [checkpoint: {len(output['players'])} players | {elapsed/60:.1f}min elapsed | ~{remaining/60:.0f}min remaining]")

        time.sleep(2.0)

    # Final save
    output["stats"] = dict(stats)
    output["last_run"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    save_output(output)

    # Print summary
    print("\n" + "=" * 70)
    print("COMPLETE")
    print("=" * 70)
    print(f"Events processed: {len(output['events_processed'])}")
    print(f"Players mapped: {len(output['players'])}")
    print(f"\nConfidence breakdown:")
    for conf in ["exact", "high", "medium", "low", "ambiguous", "unmappable"]:
        count = stats.get(conf, 0)
        if count:
            print(f"  {conf:<12} {count:>6}")
    print(f"\nOutput saved to: {OUTPUT_PATH}")


if __name__ == "__main__":
    main()
