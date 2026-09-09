#!/usr/bin/env python3
"""Collect over-the-board games from Lichess broadcasts into one PGN corpus.

The Week in Chess only carries the large events, so a state or club
tournament whose top boards were broadcast on Lichess is otherwise lost.
This tool pulls those broadcasts and keeps them as a collection: one
normalised PGN per broadcast, a manifest, and one merged PGN ready for
`dart run tools/master_import_pgn.dart` (a queryable master-format
database) or for opening in the app.

    python3 tools/lichess_broadcasts.py by falstan --collection massachusetts
    python3 tools/lichess_broadcasts.py tour GiQfOTDu --collection massachusetts
    python3 tools/lichess_broadcasts.py search "World Open"
    python3 tools/lichess_broadcasts.py status --collection massachusetts

Finding broadcasts: `search` only sees the official (tiered) broadcasts;
community broadcasts such as a state association's are reachable by the
account that ran them (`by USER`) or by tour id from the broadcast URL
(`lichess.org/broadcast/<slug>/<tourId>`).

Collections live under `Documents/lichess_broadcasts/<collection>/`
(override with --out).  A broadcast whose rounds are all finished is not
fetched again unless --refresh is given.

Zero dependencies: `urllib` and the standard library.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, Iterable

LICHESS = "https://lichess.org"
USER_AGENT = "chess-auto-prep/1.0 (lichess_broadcasts.py)"
REQUEST_GAP_SECONDS = 1.0
RATE_LIMIT_WAIT_SECONDS = 60.0

MANIFEST_NAME = "manifest.json"
TOURS_DIR = "tours"

_TAG_RE = re.compile(r'^\[(\w+)\s+"(.*)"\]\s*$')
#: Broadcasters who name each game's Event after its pairing:
#: "Round 2: A - B", "Qualifier Blitz Playoffs #2: A - B".
_PAIRING_EVENT_RE = re.compile(r"^(?P<prefix>[^:]+):\s*\S.* - \S.*$")
_ROUND_PREFIX_RE = re.compile(r"^(round|board|game)\s*\d+\s*$", re.IGNORECASE)


# ── Locations ──────────────────────────────────────────────────────────────


def documents_dir() -> Path:
    """Mirror of what path_provider hands the app for documents."""
    home = Path.home()
    if sys.platform == "darwin":
        return home / "Documents"
    if sys.platform == "win32":
        profile = os.environ.get("USERPROFILE")
        return (Path(profile) if profile else home) / "Documents"
    xdg = os.environ.get("XDG_DOCUMENTS_DIR")
    return Path(xdg) if xdg else home / "Documents"


def collection_dir(name: str, out: str | None = None) -> Path:
    if out:
        return Path(out).expanduser()
    return documents_dir() / "lichess_broadcasts" / name


# ── PGN ────────────────────────────────────────────────────────────────────


@dataclass
class Game:
    tags: dict[str, str] = field(default_factory=dict)
    movetext: str = ""

    @property
    def has_moves(self) -> bool:
        """Whether any move was recorded (a bare result is not a game)."""
        body = re.sub(r"\{[^}]*\}", " ", self.movetext)
        return re.search(r"\b\d+\.", body) is not None

    def render(self) -> str:
        lines = [f'[{k} "{v}"]' for k, v in self.tags.items()]
        return "\n".join(lines) + "\n\n" + self.movetext.strip() + "\n"


def parse_pgn(text: str) -> list[Game]:
    """Split a multi-game PGN into games, keeping tag order."""
    games: list[Game] = []
    current: Game | None = None
    body: list[str] = []
    in_tags = False
    for line in text.splitlines():
        m = _TAG_RE.match(line)
        if m:
            if not in_tags:
                if current is not None:
                    current.movetext = "\n".join(body).strip()
                    games.append(current)
                current = Game()
                body = []
                in_tags = True
            current.tags[m.group(1)] = m.group(2)
            continue
        if current is None:
            continue
        if line.strip():
            in_tags = False
            body.append(line)
    if current is not None:
        current.movetext = "\n".join(body).strip()
        games.append(current)
    return games


def game_key(g: Game) -> str:
    """Identity for de-duplication across re-fetches and overlapping tours."""
    url = g.tags.get("GameURL")
    if url:
        return url
    return "|".join(
        g.tags.get(k, "") for k in ("White", "Black", "Date", "Round", "Event")
    )


def normalise_game(g: Game, tour: dict[str, Any], site: str | None) -> Game:
    """Repair the tags broadcasters get wrong before the corpus keeps them.

    A per-pairing Event ("Round 2: A - B") becomes the broadcast's name (see
    [event_name]); a Site that is a Lichess URL, missing or "?" becomes the broadcast's
    location, or [site] when the broadcast gives none.
    """
    tags = dict(g.tags)
    tags["Event"] = event_name(tags.get("Event", ""), tour["name"])
    cur_site = tags.get("Site", "").strip()
    if not cur_site or cur_site == "?" or cur_site.startswith(("http://", "https://")):
        location = (tour.get("info") or {}).get("location", "").strip()
        tags["Site"] = location or site or "?"
    return Game(tags, g.movetext)


def event_name(event: str, tour_name: str) -> str:
    """The broadcast's name for a pairing-style Event, else the Event itself.

    A prefix that is not just a round number ("Qualifier Blitz Playoffs #2")
    is kept in brackets: it is the only place the speed of play is recorded.
    """
    event = event.strip()
    if not event:
        return tour_name
    m = _PAIRING_EVENT_RE.match(event)
    if not m:
        return event
    prefix = m.group("prefix").strip()
    if _ROUND_PREFIX_RE.match(prefix):
        return tour_name
    return f"{tour_name} ({prefix})"


def merge_games(per_tour: Iterable[tuple[dict[str, Any], list[Game]]]) -> list[Game]:
    """Union of all tours' games with moves, newest broadcast last."""
    seen: dict[str, Game] = {}
    for _tour, games in per_tour:
        for g in games:
            if not g.has_moves:
                continue
            seen[game_key(g)] = g
    return sorted(seen.values(), key=_sort_key)


def _sort_key(g: Game) -> tuple[str, str, float, int]:
    rnd = g.tags.get("Round", "")
    parts = rnd.split(".")
    try:
        r = float(parts[0])
    except ValueError:
        r = 0.0
    try:
        board = int(parts[1]) if len(parts) > 1 else 0
    except ValueError:
        board = 0
    return (g.tags.get("Date", ""), g.tags.get("Event", ""), r, board)


# ── Lichess API ────────────────────────────────────────────────────────────


class Fetcher:
    """Throttled GET against lichess.org; retries once after a 429."""

    def __init__(self, opener: Callable[[str], bytes] | None = None) -> None:
        self._open = opener or self._urlopen
        self._last = 0.0

    def _urlopen(self, url: str) -> bytes:
        request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
        with urllib.request.urlopen(request, timeout=60) as response:
            return response.read()

    def get(self, path: str) -> bytes:
        url = path if path.startswith("http") else LICHESS + path
        wait = self._last + REQUEST_GAP_SECONDS - time.monotonic()
        if wait > 0:
            time.sleep(wait)
        try:
            data = self._open(url)
        except urllib.error.HTTPError as e:
            if e.code != 429:
                raise
            print(f"rate limited, waiting {RATE_LIMIT_WAIT_SECONDS:.0f}s", file=sys.stderr)
            time.sleep(RATE_LIMIT_WAIT_SECONDS)
            data = self._open(url)
        finally:
            self._last = time.monotonic()
        return data

    def json(self, path: str) -> Any:
        return json.loads(self.get(path).decode("utf-8"))

    def tour(self, tour_id: str) -> dict[str, Any]:
        """Tour metadata plus its rounds."""
        return self.json(f"/api/broadcast/{tour_id}")

    def tour_pgn(self, tour_id: str) -> str:
        return self.get(f"/api/broadcast/{tour_id}.pgn").decode("utf-8")

    def tours_by(self, user: str) -> list[dict[str, Any]]:
        tours: list[dict[str, Any]] = []
        page = 1
        while True:
            data = self.json(f"/api/broadcast/by/{urllib.parse.quote(user)}?page={page}")
            results = data.get("currentPageResults", [])
            tours.extend(r["tour"] for r in results)
            if not results or page >= int(data.get("nbPages") or 1):
                return tours
            page += 1

    def search(self, query: str, limit: int = 30) -> list[dict[str, Any]]:
        q = urllib.parse.quote(query)
        data = self.json(f"/api/broadcast/search?q={q}&nb={limit}")
        return [r["tour"] for r in data.get("currentPageResults", [])]


# ── Collection ─────────────────────────────────────────────────────────────


def tour_summary(tour: dict[str, Any], rounds: list[dict[str, Any]]) -> dict[str, Any]:
    info = tour.get("info") or {}
    owner = tour.get("communityOwner") or {}
    return {
        "id": tour["id"],
        "name": tour["name"],
        "slug": tour.get("slug", ""),
        "url": tour.get("url", f"{LICHESS}/broadcast/{tour.get('slug', '-')}/{tour['id']}"),
        "location": info.get("location", ""),
        "dates": tour.get("dates", []),
        "owner": owner.get("name", ""),
        "rounds": len(rounds),
        "finished": bool(rounds) and all(r.get("finished") for r in rounds),
    }


class Collection:
    def __init__(self, directory: Path, site: str | None = None) -> None:
        self.dir = directory
        self.site = site
        self.manifest_path = directory / MANIFEST_NAME
        self.manifest: dict[str, Any] = {"tours": {}}
        if self.manifest_path.exists():
            self.manifest = json.loads(self.manifest_path.read_text(encoding="utf-8"))
        self.manifest.setdefault("tours", {})

    @property
    def merged_path(self) -> Path:
        return self.dir / f"{self.dir.name}.pgn"

    def tour_path(self, tour_id: str) -> Path:
        return self.dir / TOURS_DIR / f"{tour_id}.pgn"

    def fetch(self, fetcher: Fetcher, tour_id: str, refresh: bool = False) -> dict[str, Any]:
        entry = self.manifest["tours"].get(tour_id)
        if entry and entry.get("finished") and not refresh and self.tour_path(tour_id).exists():
            print(f"{tour_id}: {entry['name']} — already complete, skipped", file=sys.stderr)
            return entry
        data = fetcher.tour(tour_id)
        tour = data["tour"]
        rounds = data.get("rounds", [])
        games = [normalise_game(g, tour, self.site) for g in parse_pgn(fetcher.tour_pgn(tour_id))]
        path = self.tour_path(tour_id)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("".join(g.render() + "\n" for g in games), encoding="utf-8")
        entry = tour_summary(tour, rounds)
        entry["games"] = sum(1 for g in games if g.has_moves)
        entry["fetched_at"] = int(time.time())
        self.manifest["tours"][tour_id] = entry
        print(f"{tour_id}: {entry['name']} — {entry['games']} games", file=sys.stderr)
        return entry

    def merge(self) -> int:
        per_tour = []
        for tour_id, entry in self.manifest["tours"].items():
            path = self.tour_path(tour_id)
            if path.exists():
                per_tour.append((entry, parse_pgn(path.read_text(encoding="utf-8"))))
        games = merge_games(per_tour)
        self.dir.mkdir(parents=True, exist_ok=True)
        self.merged_path.write_text("".join(g.render() + "\n" for g in games), encoding="utf-8")
        return len(games)

    def save(self) -> None:
        self.dir.mkdir(parents=True, exist_ok=True)
        self.manifest_path.write_text(
            json.dumps(self.manifest, indent=1, sort_keys=True) + "\n", encoding="utf-8"
        )

    def status_lines(self) -> list[str]:
        lines = []
        total = 0
        for entry in sorted(self.manifest["tours"].values(), key=lambda e: e.get("dates") or [0]):
            date = _date_of(entry)
            total += entry.get("games", 0)
            lines.append(
                f"{entry['id']}  {date}  {entry.get('games', 0):4d} games  "
                f"{entry['name']}  ({entry.get('location') or 'no location'})"
            )
        lines.append(f"{len(self.manifest['tours'])} broadcasts, {total} games -> {self.merged_path}")
        return lines


def _date_of(entry: dict[str, Any]) -> str:
    dates = entry.get("dates") or []
    if not dates:
        return "????-??-??"
    return time.strftime("%Y-%m-%d", time.gmtime(dates[0] / 1000))


# ── CLI ────────────────────────────────────────────────────────────────────


def _print_tours(tours: list[dict[str, Any]]) -> None:
    for t in tours:
        info = t.get("info") or {}
        print(f"{t['id']}  {_date_of(t)}  {t['name']}  ({info.get('location') or 'no location'})")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    def add_collection_args(p: argparse.ArgumentParser) -> None:
        p.add_argument("--collection", default="broadcasts", help="collection name (default: broadcasts)")
        p.add_argument("--out", help="collection directory (default: Documents/lichess_broadcasts/<collection>)")
        p.add_argument("--site", help="Site tag for games whose broadcast gives no location")
        p.add_argument("--refresh", action="store_true", help="re-fetch broadcasts already complete")

    p_by = sub.add_parser("by", help="fetch every broadcast run by a Lichess user")
    p_by.add_argument("user")
    add_collection_args(p_by)

    p_tour = sub.add_parser("tour", help="fetch broadcasts by tour id")
    p_tour.add_argument("tour_id", nargs="+")
    add_collection_args(p_tour)

    p_search = sub.add_parser("search", help="find official broadcasts by name")
    p_search.add_argument("query")
    p_search.add_argument("--limit", type=int, default=30)

    p_status = sub.add_parser("status", help="list a collection and rebuild its merged PGN")
    add_collection_args(p_status)

    args = parser.parse_args(argv)
    fetcher = Fetcher()

    if args.command == "search":
        _print_tours(fetcher.search(args.query, args.limit))
        return 0

    collection = Collection(collection_dir(args.collection, args.out), args.site)
    if args.command == "by":
        tours = fetcher.tours_by(args.user)
        if not tours:
            print(f"no broadcasts by {args.user}", file=sys.stderr)
            return 1
        ids = [t["id"] for t in tours]
    elif args.command == "tour":
        ids = args.tour_id
    else:
        ids = []

    for tour_id in ids:
        try:
            collection.fetch(fetcher, tour_id, refresh=args.refresh)
        except urllib.error.HTTPError as e:
            print(f"{tour_id}: HTTP {e.code}", file=sys.stderr)
        collection.save()
    n = collection.merge()
    collection.save()
    for line in collection.status_lines():
        print(line)
    return 0 if n or not ids else 1


if __name__ == "__main__":
    sys.exit(main())
