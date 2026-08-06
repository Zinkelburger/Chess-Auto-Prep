"""US Chess ratings API client.

The `mappable` check here is the most useful diagnostic in the whole feature
and had no home before: the bundled directory can only ever resolve a player
who has actually played a USCF-rated event *on chess.com*, and the API says
whether they have. On a real 29-player field it turned "7% hit rate, cause
unknown" into "16 of 29 are mappable; the gap is the un-backfilled 2020-2022
window" — which is a completely different conclusion to act on.
"""

from __future__ import annotations

import json
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Any

API = "https://ratings-api.uschess.org/api/v1"
USER_AGENT = "chess-auto-prep/1.0 (tournament prep tool)"

#: US Chess rating systems that only exist because of online play.
ONLINE_SYSTEMS = {
    "OR": "Online-Regular",
    "OQ": "Online-Quick",
    "OB": "Online-Blitz",
}

#: Polite spacing between calls. The API is public and unauthenticated; a
#: roster sweep is dozens of requests and should not look like a scrape.
RATE_LIMIT_SECONDS = 0.7

_last_request_at = 0.0


class UscfError(Exception):
    pass


def _get(path: str, timeout: int = 20) -> Any:
    global _last_request_at

    elapsed = time.monotonic() - _last_request_at
    if elapsed < RATE_LIMIT_SECONDS:
        time.sleep(RATE_LIMIT_SECONDS - elapsed)

    request = urllib.request.Request(
        f"{API}{path}", headers={"User-Agent": USER_AGENT}
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            payload = json.load(response)
    except urllib.error.HTTPError as e:
        raise UscfError(f"US Chess API returned HTTP {e.code} for {path}") from e
    except (urllib.error.URLError, TimeoutError) as e:
        raise UscfError(f"Could not reach the US Chess API: {e}") from e
    except json.JSONDecodeError as e:
        raise UscfError(f"US Chess API returned unreadable JSON: {e}") from e
    finally:
        _last_request_at = time.monotonic()

    return payload


def member(uscf_id: str) -> dict:
    """Profile plus a summary of what it implies for directory coverage."""
    data = _get(f"/members/{urllib.parse.quote(str(uscf_id).strip(), safe='')}")

    online: dict[str, dict] = {}
    otb: dict[str, dict] = {}
    for entry in data.get("ratings", []) or []:
        system = entry.get("ratingSystem", "")
        rating = entry.get("rating")
        games = entry.get("gamesPlayed") or 0
        if not rating and not games:
            continue
        row = {
            "rating": rating,
            "games": games,
            "provisional": entry.get("isProvisional", True),
        }
        if system in ONLINE_SYSTEMS:
            online[ONLINE_SYSTEMS[system]] = row
        else:
            otb[system] = row

    return {
        "uscf_id": str(uscf_id).strip(),
        "name": " ".join(
            p for p in [data.get("firstName"), data.get("lastName")] if p
        ),
        "state": data.get("state"),
        "otb_ratings": otb,
        "online_ratings": online,
        "mappable": bool(online),
        "note": (
            "Has USCF online ratings, so they played USCF-rated events on "
            "chess.com and the directory can in principle resolve them. A "
            "directory miss for this player means the mapping has not "
            "processed their events yet, not that no account exists."
            if online
            else "No USCF online ratings — this player has not played "
            "USCF-rated events on chess.com, so the bundled directory can "
            "never resolve them. Web search is the only route."
        ),
    }


def coverage_report(uscf_ids: list[str]) -> dict:
    """Sweep a field and report how many are mappable in principle.

    Run this before spending effort on web search: it separates "the mapping
    needs a backfill" from "this player was never online-rated".
    """
    mappable: list[dict] = []
    not_mappable: list[dict] = []
    errors: list[dict] = []

    for uscf_id in uscf_ids:
        try:
            info = member(uscf_id)
        except UscfError as e:
            errors.append({"uscf_id": uscf_id, "error": str(e)})
            continue
        row = {
            "uscf_id": info["uscf_id"],
            "name": info["name"],
            "online_ratings": info["online_ratings"],
        }
        (mappable if info["mappable"] else not_mappable).append(row)

    checked = len(mappable) + len(not_mappable)
    return {
        "checked": checked,
        "mappable": len(mappable),
        "not_mappable": len(not_mappable),
        "mappable_fraction": (len(mappable) / checked) if checked else 0.0,
        "mappable_players": mappable,
        "not_mappable_players": not_mappable,
        "errors": errors,
        "interpretation": (
            "'mappable' players have played USCF-rated events on chess.com, "
            "so a directory miss for them is a backfill gap. 'not_mappable' "
            "players can only be found by web search."
        ),
    }
