"""Find a chess.com account from rating clues: "blitz 2701 on June 13".

The public API exposes no rating history and only the top 50 of each
leaderboard, but every monthly game archive records *both* players'
post-game ratings. So the rating history of any player — and of every
opponent they faced — can be rebuilt from archives. This module caches
archives on disk and indexes them into SQLite (ratings and opening moves), so
"who was 2701 on that day" and "who plays this line as White" are single
queries over everything ever downloaded.

The opponent side of every cached game is the important trick: it multiplies
coverage roughly fourfold for free, and the September 2026 search found an
account that had never been on any leaderboard snapshot because it turned up
as somebody's opponent. A search therefore alternates between two queues —
verify partial matches the index already knows about (fetch their own
archives), and widen the pool from the website leaderboard, which pages 50 at
a time far past the API's top 50.

The search itself runs as a background process (`python3 -m
chess_prep.chesscom --job DIR`) so an MCP call never blocks on thousands of
polite serial requests: `chesscom_search` starts it, `chesscom_search_status`
polls it and reads matches straight from the shared index.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import signal
import sqlite3
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from collections import Counter, deque
from pathlib import Path
from typing import Any, Callable

from .paths import data_dir

PUBLIC_API = "https://api.chess.com/pub"
LEADERBOARD_CALLBACK = "https://www.chess.com/callback/leaderboard/live"
USER_AGENT = "chess-auto-prep/1.0 (+https://chessautoprep.com)"

#: Serial requests with this spacing were fine over ~20k calls in Sept 2026.
RATE_LIMIT_SECONDS = 0.15
CATEGORIES = ("bullet", "blitz", "rapid")
OPENING_PLIES = 20
LEADERBOARD_TTL_SECONDS = 24 * 3600
PAGE_SIZE = 50
MAX_PAGE = 1000
DEFAULT_BAND = 200
DEFAULT_BUDGET = 1500
PROGRESS_EVERY = 10
HIT_ENRICH_LIMIT = 25

SEARCH_FILE = "search.json"
PROGRESS_FILE = "progress.json"
RESULTS_FILE = "results.json"
LOG_FILE = "search.log"

Fetch = Callable[[str], Any]


class ChesscomError(Exception):
    pass


class Stopped(Exception):
    """Raised inside the job when it receives SIGTERM."""


# ── HTTP ─────────────────────────────────────────────────────────────────────

_last_request_at = 0.0


def fetch_json(url: str, timeout: int = 30) -> Any:
    """GET a JSON document politely. 404 → None (a missing player or an
    empty month); 429 and 5xx back off and retry."""
    global _last_request_at
    last_error: Exception | None = None
    for attempt in range(6):
        elapsed = time.monotonic() - _last_request_at
        if elapsed < RATE_LIMIT_SECONDS:
            time.sleep(RATE_LIMIT_SECONDS - elapsed)
        request = urllib.request.Request(
            url, headers={"User-Agent": USER_AGENT, "Accept": "application/json"}
        )
        _last_request_at = time.monotonic()
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                return json.load(response)
        except urllib.error.HTTPError as e:
            if e.code == 404:
                return None
            if e.code == 429 or e.code >= 500:
                last_error = e
                time.sleep(min(60.0, 10.0 * (attempt + 1)))
                continue
            raise ChesscomError(f"chess.com returned HTTP {e.code} for {url}") from e
        except (urllib.error.URLError, TimeoutError, ConnectionError) as e:
            last_error = e
            time.sleep(5.0)
            continue
        except json.JSONDecodeError as e:
            raise ChesscomError(f"chess.com returned unreadable JSON for {url}") from e
    raise ChesscomError(f"Gave up on {url}: {last_error}")


# ── Paths ────────────────────────────────────────────────────────────────────


def chesscom_dir() -> Path:
    """Archive cache, index and search jobs. Override with
    CHESS_PREP_CHESSCOM_DIR (tests do; so can a user with an older cache)."""
    override = os.environ.get("CHESS_PREP_CHESSCOM_DIR")
    if override:
        return Path(override).expanduser()
    return data_dir() / "chesscom"


def _write_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as handle:
            json.dump(payload, handle, indent=2)
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def _read_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return None


# ── PGN and dates ────────────────────────────────────────────────────────────

_RESULT_TOKENS = {"1-0", "0-1", "1/2-1/2", "*"}
_COMMENT = re.compile(r"\{[^}]*\}")
_MOVE_NUMBER = re.compile(r"\d+\.(\.\.)?")


def san_moves(text: str, limit: int = OPENING_PLIES) -> list[str]:
    """SAN tokens of a PGN body or a bare line ("1.e4 e5 2.Nf3"), without
    comments, move numbers, results, checks or mates."""
    body = text.split("\n\n", 1)[1] if "\n\n" in text else text
    body = _MOVE_NUMBER.sub(" ", _COMMENT.sub(" ", body))
    out: list[str] = []
    for token in body.split():
        if token in _RESULT_TOKENS:
            break
        token = token.rstrip("+#")
        if token:
            out.append(token)
        if len(out) >= limit:
            break
    return out


def parse_date(text: str) -> dt.date:
    try:
        return dt.date.fromisoformat(str(text).strip())
    except ValueError:
        raise ChesscomError(f'Dates are YYYY-MM-DD, not "{text}".') from None


def day_window(date: dt.date, tz: str = "US") -> tuple[int, int]:
    """UTC epoch range for "on this date". ``US`` (the default) is the union of
    the US time zones — a player's profile shows local time, and a remembered
    date is a local one. ``UTC`` is the exact UTC day; any IANA zone name is
    that zone's local day."""
    utc = dt.timezone.utc
    zone = (tz or "US").strip()
    if zone.upper() == "US":
        start = dt.datetime(date.year, date.month, date.day, 4, tzinfo=utc)
        return int(start.timestamp()), int((start + dt.timedelta(hours=30)).timestamp())
    if zone.upper() == "UTC":
        start = dt.datetime(date.year, date.month, date.day, tzinfo=utc)
        return int(start.timestamp()), int((start + dt.timedelta(days=1)).timestamp())
    try:
        from zoneinfo import ZoneInfo

        info = ZoneInfo(zone)
    except Exception:
        raise ChesscomError(
            f'Unknown time zone "{tz}". Use US, UTC or an IANA name such as '
            "America/New_York."
        ) from None
    start = dt.datetime(date.year, date.month, date.day, tzinfo=info)
    end = start + dt.timedelta(days=1)
    return int(start.timestamp()), int(end.timestamp())


def months_covering(start: int, end: int, lead_days: int = 3) -> list[str]:
    """Archive months (YYYY-MM) needed to know the rating throughout
    ``[start, end)``: the window's months plus a few days of lead so the last
    game *before* the window is included when it starts a month."""
    first = dt.datetime.fromtimestamp(start, dt.timezone.utc) - dt.timedelta(days=lead_days)
    last = dt.datetime.fromtimestamp(end - 1, dt.timezone.utc)
    months: list[str] = []
    year, month = first.year, first.month
    while (year, month) <= (last.year, last.month):
        months.append(f"{year:04d}-{month:02d}")
        month += 1
        if month > 12:
            year, month = year + 1, 1
    return months


def ratings_seen(events: list[tuple[int, int]], window: tuple[int, int]) -> tuple[int | None, list[int]]:
    """From sorted ``(end_time, post-game rating)`` events: the rating in force
    when the window opened, and every rating shown during it."""
    start, end = window
    before = [r for t, r in events if t < start]
    during = [r for t, r in events if start <= t < end]
    return (before[-1] if before else None), during


def _iso_day(ts: int | None) -> str | None:
    if not ts:
        return None
    return dt.datetime.fromtimestamp(ts, dt.timezone.utc).strftime("%Y-%m-%d")


# ── Index ────────────────────────────────────────────────────────────────────

_SCHEMA = """
CREATE TABLE IF NOT EXISTS archives(
    username TEXT NOT NULL, ym TEXT NOT NULL, fetched_at INTEGER NOT NULL,
    games INTEGER NOT NULL, PRIMARY KEY(username, ym));
CREATE TABLE IF NOT EXISTS events(
    username TEXT NOT NULL, time_class TEXT NOT NULL, end_time INTEGER NOT NULL,
    rating INTEGER NOT NULL, PRIMARY KEY(username, time_class, end_time));
CREATE INDEX IF NOT EXISTS events_by_rating ON events(time_class, rating, end_time);
CREATE TABLE IF NOT EXISTS openings(
    username TEXT NOT NULL, end_time INTEGER NOT NULL, side TEXT NOT NULL,
    time_class TEXT NOT NULL, opponent TEXT NOT NULL, moves TEXT NOT NULL,
    PRIMARY KEY(username, end_time));
CREATE INDEX IF NOT EXISTS openings_by_moves ON openings(side, moves);
CREATE TABLE IF NOT EXISTS leaderboard(
    category TEXT NOT NULL, page INTEGER NOT NULL, rank INTEGER NOT NULL,
    username TEXT NOT NULL, rating INTEGER NOT NULL, title TEXT, country TEXT,
    fetched_at INTEGER NOT NULL, PRIMARY KEY(category, rank));
CREATE INDEX IF NOT EXISTS leaderboard_by_page ON leaderboard(category, page);
CREATE TABLE IF NOT EXISTS leaderboard_pages(
    category TEXT NOT NULL, page INTEGER NOT NULL, fetched_at INTEGER NOT NULL,
    rows INTEGER NOT NULL, PRIMARY KEY(category, page));
"""


class Index:
    """Archive cache + SQLite index. Safe to read from the server while the
    search job writes (WAL)."""

    def __init__(self, root: Path | None = None) -> None:
        self.root = root or chesscom_dir()
        self.archives = self.root / "archives"
        self.archives.mkdir(parents=True, exist_ok=True)
        self.db = sqlite3.connect(str(self.root / "index.sqlite"), timeout=120)
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.execute("PRAGMA synchronous=NORMAL")
        self.db.executescript(_SCHEMA)

    def close(self) -> None:
        self.db.close()

    # ── archives ───────────────────────────────────────────────────────────

    def archive_path(self, username: str, ym: str) -> Path:
        return self.archives / f"{username.lower()}_{ym}.json"

    def has_archive(self, username: str, ym: str) -> bool:
        row = self.db.execute(
            "SELECT 1 FROM archives WHERE username=? AND ym=?", (username.lower(), ym)
        ).fetchone()
        return row is not None

    def cached_months(self, username: str) -> list[str]:
        return [
            r[0]
            for r in self.db.execute(
                "SELECT ym FROM archives WHERE username=? ORDER BY ym", (username.lower(),)
            )
        ]

    def pending_files(self) -> list[Path]:
        """Archive files on disk the index has not seen — an older cache
        dropped into the directory, or a job that died mid-write."""
        known = {
            (u, ym) for u, ym in self.db.execute("SELECT username, ym FROM archives")
        }
        pending = []
        for path in sorted(self.archives.glob("*_????-??.json")):
            username, ym = path.name[: -len(".json")].rsplit("_", 1)
            if (username, ym) not in known:
                pending.append(path)
        return pending

    def index_file(self, path: Path) -> int:
        username, ym = path.name[: -len(".json")].rsplit("_", 1)
        payload = _read_json(path)
        return self.index_archive(username, ym, payload)

    def store_archive(self, username: str, ym: str, payload: Any) -> int:
        _write_json(self.archive_path(username, ym), payload)
        return self.index_archive(username, ym, payload)

    def index_archive(self, username: str, ym: str, payload: Any) -> int:
        username = username.lower()
        games = (payload or {}).get("games", []) if isinstance(payload, dict) else []
        events: list[tuple[str, str, int, int]] = []
        openings: list[tuple[str, int, str, str, str, str]] = []
        for game in games:
            if game.get("rules") != "chess":
                continue
            time_class = game.get("time_class")
            end_time = game.get("end_time")
            if time_class not in CATEGORIES or not isinstance(end_time, int):
                continue
            white = game.get("white") or {}
            black = game.get("black") or {}
            names = {
                "white": (white.get("username") or "").lower(),
                "black": (black.get("username") or "").lower(),
            }
            for side, player in (("white", white), ("black", black)):
                rating = player.get("rating")
                if names[side] and isinstance(rating, int):
                    events.append((names[side], time_class, end_time, rating))
            pgn = game.get("pgn")
            if pgn and names["white"] and names["black"]:
                line = " ".join(san_moves(pgn))
                if line:
                    openings.append((names["white"], end_time, "white", time_class, names["black"], line))
                    openings.append((names["black"], end_time, "black", time_class, names["white"], line))
        with self.db:
            self.db.executemany(
                "INSERT OR IGNORE INTO events(username, time_class, end_time, rating) VALUES (?,?,?,?)",
                events,
            )
            self.db.executemany(
                "INSERT OR IGNORE INTO openings(username, end_time, side, time_class, opponent, moves) "
                "VALUES (?,?,?,?,?,?)",
                openings,
            )
            self.db.execute(
                "INSERT OR REPLACE INTO archives(username, ym, fetched_at, games) VALUES (?,?,?,?)",
                (username, ym, int(time.time()), len(games)),
            )
        return len(games)

    def ensure_archive(
        self, username: str, ym: str, fetch: Fetch, counter: "Budget | None" = None
    ) -> bool:
        """True when a request was made."""
        if self.has_archive(username, ym):
            return False
        if counter is not None:
            counter.spend()
        year, month = ym.split("-")
        payload = fetch(f"{PUBLIC_API}/player/{username.lower()}/games/{year}/{month}")
        self.store_archive(username, ym, payload if payload is not None else {"games": []})
        return True

    # ── ratings ────────────────────────────────────────────────────────────

    def events_for(self, username: str, time_class: str, before: int) -> list[tuple[int, int]]:
        return [
            (t, r)
            for t, r in self.db.execute(
                "SELECT end_time, rating FROM events WHERE username=? AND time_class=? "
                "AND end_time<? ORDER BY end_time",
                (username.lower(), time_class, before),
            )
        ]

    def rating_on(self, username: str, time_class: str, window: tuple[int, int]) -> dict[str, Any]:
        at_start, during = ratings_seen(self.events_for(username, time_class, window[1]), window)
        return {"at_start": at_start, "during": during, "games_during": len(during)}

    def matches(self, clue: dict[str, Any]) -> dict[str, dict[str, Any]]:
        """Every indexed username whose ``clue['category']`` rating read
        ``clue['rating']`` at some moment in the clue window. ``complete`` says
        whether the user's *own* archives for the window months are cached;
        an opponent-derived history is sparse and only reliable in-window."""
        window = (clue["start"], clue["end"])
        candidates = [
            r[0]
            for r in self.db.execute(
                "SELECT DISTINCT username FROM events WHERE time_class=? AND rating=? AND end_time<?",
                (clue["category"], clue["rating"], window[1]),
            )
        ]
        out: dict[str, dict[str, Any]] = {}
        for username in candidates:
            seen = self.rating_on(username, clue["category"], window)
            if clue["rating"] == seen["at_start"] or clue["rating"] in seen["during"]:
                seen["complete"] = all(self.has_archive(username, ym) for ym in clue["months"])
                out[username] = seen
        return out

    def matches_all(self, clues: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
        """Users matching every clue: ``{username: {"complete": bool, "clues": [...]}}``."""
        per_clue = [self.matches(clue) for clue in clues]
        if not per_clue:
            return {}
        users = set(per_clue[0])
        for found in per_clue[1:]:
            users &= set(found)
        out = {}
        for username in sorted(users):
            details = [found[username] for found in per_clue]
            out[username] = {
                "complete": all(d["complete"] for d in details),
                "clues": [
                    {
                        "category": clue["category"],
                        "rating": clue["rating"],
                        "date": clue["date"],
                        "at_start": d["at_start"],
                        "during": d["during"][:40],
                        "games_during": d["games_during"],
                    }
                    for clue, d in zip(clues, details)
                ],
            }
        return out

    def matches_any(self, clues: list[dict[str, Any]]) -> dict[str, bool]:
        """``{username: complete}`` for users matching at least one clue."""
        out: dict[str, bool] = {}
        for clue in clues:
            for username, seen in self.matches(clue).items():
                out[username] = out.get(username, True) and seen["complete"]
        return out

    # ── openings ───────────────────────────────────────────────────────────

    def who_plays(
        self,
        moves: list[str],
        side: str,
        time_class: str | None = None,
        min_games: int = 1,
        limit: int = 25,
    ) -> list[dict[str, Any]]:
        line = " ".join(moves)
        params: list[Any] = [side, line, line + " %"]
        where = "side=? AND (moves=? OR moves LIKE ?)"
        if time_class:
            where += " AND time_class=?"
            params.append(time_class)
        rows = self.db.execute(
            f"SELECT username, COUNT(*) AS n FROM openings WHERE {where} "
            "GROUP BY username HAVING n>=? ORDER BY n DESC, username LIMIT ?",
            [*params, min_games, limit],
        ).fetchall()
        out = []
        for username, n in rows:
            total_params: list[Any] = [username, side]
            total_where = "username=? AND side=?"
            if time_class:
                total_where += " AND time_class=?"
                total_params.append(time_class)
            total = self.db.execute(
                f"SELECT COUNT(*) FROM openings WHERE {total_where}", total_params
            ).fetchone()[0]
            out.append(
                {
                    "username": username,
                    "games_with_line": n,
                    "games_as_" + side: total,
                    "share": round(n / total, 3) if total else None,
                    "own_archives_cached": bool(self.cached_months(username)),
                }
            )
        return out

    def opening_count(self, username: str, moves: list[str], side: str) -> dict[str, int]:
        line = " ".join(moves)
        n = self.db.execute(
            "SELECT COUNT(*) FROM openings WHERE username=? AND side=? AND (moves=? OR moves LIKE ?)",
            (username.lower(), side, line, line + " %"),
        ).fetchone()[0]
        total = self.db.execute(
            "SELECT COUNT(*) FROM openings WHERE username=? AND side=?", (username.lower(), side)
        ).fetchone()[0]
        return {"games_with_line": n, "games_as_" + side: total}

    def activity(self, username: str, months: list[str] | None = None) -> dict[str, Any]:
        """Games per time class and busiest UTC hours, from every indexed game
        of this user (own archives and appearances as an opponent)."""
        params: list[Any] = [username.lower()]
        where = "username=?"
        if months:
            first = dt.datetime.strptime(min(months), "%Y-%m").replace(tzinfo=dt.timezone.utc)
            last_y, last_m = map(int, max(months).split("-"))
            last = dt.datetime(last_y + (last_m // 12), last_m % 12 + 1, 1, tzinfo=dt.timezone.utc)
            where += " AND end_time>=? AND end_time<?"
            params += [int(first.timestamp()), int(last.timestamp())]
        by_class: Counter = Counter()
        hours: Counter = Counter()
        for time_class, end_time in self.db.execute(
            f"SELECT time_class, end_time FROM events WHERE {where}", params
        ):
            by_class[time_class] += 1
            hours[dt.datetime.fromtimestamp(end_time, dt.timezone.utc).hour] += 1
        return {
            "games": dict(by_class),
            "busiest_hours_utc": [f"{h:02d}" for h, _ in sorted(hours.most_common(4))],
        }

    # ── leaderboard ────────────────────────────────────────────────────────

    def leaderboard_page(self, category: str, page: int) -> list[tuple] | None:
        """Cached rows for a page, ``[]`` for a cached empty page (past the end
        of the list), None when unknown or stale."""
        meta = self.db.execute(
            "SELECT fetched_at FROM leaderboard_pages WHERE category=? AND page=?",
            (category, page),
        ).fetchone()
        if meta is None or meta[0] < time.time() - LEADERBOARD_TTL_SECONDS:
            return None
        return self.db.execute(
            "SELECT rank, username, rating, title, country FROM leaderboard "
            "WHERE category=? AND page=? ORDER BY rank",
            (category, page),
        ).fetchall()

    def store_leaderboard_page(self, category: str, page: int, leaders: list[dict]) -> list[tuple]:
        now = int(time.time())
        rows = []
        for entry in leaders:
            user = entry.get("user") or {}
            if not user.get("username"):
                continue
            rows.append(
                (
                    int(entry.get("rank") or 0),
                    user["username"],
                    int(entry.get("score") or 0),
                    user.get("chess_title"),
                    user.get("country_name"),
                )
            )
        with self.db:
            self.db.execute(
                "DELETE FROM leaderboard WHERE category=? AND page=?", (category, page)
            )
            self.db.executemany(
                "INSERT OR REPLACE INTO leaderboard(category, page, rank, username, rating, title, "
                "country, fetched_at) VALUES (?,?,?,?,?,?,?,?)",
                [(category, page, *row, now) for row in rows],
            )
            self.db.execute(
                "INSERT OR REPLACE INTO leaderboard_pages(category, page, fetched_at, rows) "
                "VALUES (?,?,?,?)",
                (category, page, now, len(rows)),
            )
        return rows

    def fetch_leaderboard_page(
        self, category: str, page: int, fetch: Fetch, counter: "Budget | None" = None
    ) -> list[tuple]:
        cached = self.leaderboard_page(category, page)
        if cached is not None:
            return cached
        if counter is not None:
            counter.spend()
        payload = fetch(f"{LEADERBOARD_CALLBACK}/{category}?page={page}") or {}
        return self.store_leaderboard_page(category, page, payload.get("leaders") or [])

    def leaderboard_band(
        self, category: str, low: int, high: int, fetch: Fetch, counter: "Budget | None" = None
    ) -> list[tuple]:
        """Leaderboard rows with ``low <= rating <= high``. Pages are sorted by
        rating, so bisect to the first page that reaches ``high`` and read
        forward until a page drops below ``low``."""
        lo, hi = 1, MAX_PAGE
        first = MAX_PAGE
        while lo <= hi:
            mid = (lo + hi) // 2
            rows = self.fetch_leaderboard_page(category, mid, fetch, counter)
            if not rows:
                hi = mid - 1
                continue
            page_min = min(r[2] for r in rows)
            if page_min <= high:
                first = mid
                hi = mid - 1
            else:
                lo = mid + 1
        out: list[tuple] = []
        page = first
        while page <= MAX_PAGE:
            rows = self.fetch_leaderboard_page(category, page, fetch, counter)
            if not rows:
                break
            out.extend(r for r in rows if low <= r[2] <= high)
            if min(r[2] for r in rows) < low:
                break
            page += 1
        return out

    def stats(self) -> dict[str, Any]:
        one = lambda sql: self.db.execute(sql).fetchone()[0]  # noqa: E731
        return {
            "directory": str(self.root),
            "archives": one("SELECT COUNT(*) FROM archives"),
            "players_with_own_archives": one("SELECT COUNT(DISTINCT username) FROM archives"),
            "players_with_any_rating": one("SELECT COUNT(DISTINCT username) FROM events"),
            "rating_events": one("SELECT COUNT(*) FROM events"),
            "games_with_moves": one("SELECT COUNT(*) FROM openings") // 2,
            "leaderboard_rows": one("SELECT COUNT(*) FROM leaderboard"),
            "unindexed_files": len(self.pending_files()),
        }


# ── Profiles ─────────────────────────────────────────────────────────────────


def _country(url: str | None) -> str | None:
    return url.rstrip("/").rsplit("/", 1)[-1] if url else None


def fetch_profile(username: str, fetch: Fetch) -> dict[str, Any] | None:
    player = fetch(f"{PUBLIC_API}/player/{username.lower()}")
    if not player:
        return None
    stats = fetch(f"{PUBLIC_API}/player/{username.lower()}/stats") or {}
    ratings = {}
    for category in CATEGORIES:
        block = stats.get(f"chess_{category}")
        if not block:
            continue
        last = block.get("last") or {}
        best = block.get("best") or {}
        record = block.get("record") or {}
        ratings[category] = {
            "now": last.get("rating"),
            "now_date": _iso_day(last.get("date")),
            "best": best.get("rating"),
            "best_date": _iso_day(best.get("date")),
            "record": f"+{record.get('win', 0)} -{record.get('loss', 0)} ={record.get('draw', 0)}",
        }
    return {
        "username": player.get("username") or username,
        "name": player.get("name"),
        "title": player.get("title"),
        "country": _country(player.get("country")),
        "location": player.get("location"),
        "joined": _iso_day(player.get("joined")),
        "last_online": _iso_day(player.get("last_online")),
        "followers": player.get("followers"),
        "status": player.get("status"),
        "url": player.get("url"),
        "ratings": ratings,
        "note": "Friend counts are not visible logged out; followers are not friends.",
    }


# ── Clues ────────────────────────────────────────────────────────────────────


def parse_clues(raw: Any, tz: str) -> list[dict[str, Any]]:
    if isinstance(raw, str):
        try:
            raw = json.loads(raw)
        except ValueError:
            raise ChesscomError("clues must be a JSON list of {category, rating, date}.") from None
    if isinstance(raw, dict):
        raw = [raw]
    if not isinstance(raw, list) or not raw:
        raise ChesscomError("Give at least one clue: {category, rating, date}.")
    clues = []
    for item in raw:
        if not isinstance(item, dict):
            raise ChesscomError("Each clue is an object {category, rating, date}.")
        category = str(item.get("category") or "blitz").lower()
        if category not in CATEGORIES:
            raise ChesscomError(f"category must be one of {', '.join(CATEGORIES)}.")
        try:
            rating = int(item["rating"])
        except (KeyError, TypeError, ValueError):
            raise ChesscomError("Each clue needs an integer rating.") from None
        date = parse_date(item.get("date"))
        start, end = day_window(date, str(item.get("tz") or tz))
        clues.append(
            {
                "category": category,
                "rating": rating,
                "date": date.isoformat(),
                "start": start,
                "end": end,
                "months": months_covering(start, end),
            }
        )
    return clues


def clue_months(clues: list[dict[str, Any]]) -> list[str]:
    return sorted({ym for clue in clues for ym in clue["months"]})


# ── Search job ───────────────────────────────────────────────────────────────


class Budget:
    def __init__(self, limit: int) -> None:
        self.limit = limit
        self.spent = 0

    @property
    def left(self) -> int:
        return self.limit - self.spent

    def spend(self) -> None:
        if self.spent >= self.limit:
            raise BudgetExhausted()
        self.spent += 1


class BudgetExhausted(Exception):
    pass


class Progress:
    def __init__(self, job: Path, state: dict[str, Any]) -> None:
        self.path = job / PROGRESS_FILE
        self.state = state
        self.write()

    def update(self, **fields: Any) -> None:
        self.state.update(fields)
        self.write()

    def write(self) -> None:
        self.state["updated_at"] = time.strftime("%Y-%m-%dT%H:%M:%S")
        _write_json(self.path, self.state)


def _install_stop_handler() -> None:
    def handler(signum, frame):  # noqa: ARG001
        raise Stopped()

    signal.signal(signal.SIGTERM, handler)


def run_search(job: Path, fetch: Fetch = fetch_json, index: Index | None = None) -> dict[str, Any]:
    """The whole job, in-process (tests) or as the background entry point."""
    spec = _read_json(job / SEARCH_FILE) or {}
    clues = parse_clues(spec["clues"], spec.get("tz") or "US")
    band = int(spec.get("band") or DEFAULT_BAND)
    budget = Budget(int(spec.get("max_requests") or DEFAULT_BUDGET))
    country = (spec.get("country") or "").strip().lower() or None
    title = (spec.get("title") or "").strip().upper() or None
    opening = san_moves(spec.get("opening") or "")
    opening_side = (spec.get("opening_side") or "white").lower()
    own = index or Index()
    progress = Progress(
        job,
        {
            "state": "indexing",
            "pid": os.getpid(),
            "requests": 0,
            "max_requests": budget.limit,
            "started_at": time.strftime("%Y-%m-%dT%H:%M:%S"),
        },
    )
    months = clue_months(clues)
    results: dict[str, Any] = {"state": "failed"}

    def tick(**fields: Any) -> None:
        progress.update(requests=budget.spent, **fields)

    try:
        pending = own.pending_files()
        for i, path in enumerate(pending, 1):
            own.index_file(path)
            if i % 50 == 0 or i == len(pending):
                tick(indexed=i, unindexed=len(pending) - i)

        tick(state="leaderboard")
        pool: dict[str, tuple[int, int, str | None, str | None]] = {}
        try:
            for category in sorted({c["category"] for c in clues}):
                targets = [c["rating"] for c in clues if c["category"] == category]
                low, high = min(targets) - band, max(targets) + band
                for rank, username, rating, ptitle, pcountry in own.leaderboard_band(
                    category, low, high, fetch, budget
                ):
                    distance = min(abs(rating - t) for t in targets)
                    key = username.lower()
                    if key not in pool or distance < pool[key][0]:
                        pool[key] = (distance, rank, ptitle, pcountry)
        except BudgetExhausted:
            pass
        if country:
            pool = {u: v for u, v in pool.items() if (v[3] or "").lower() == country}
        if title:
            pool = {u: v for u, v in pool.items() if (v[2] or "").upper() == title}
        pool_order = deque(sorted(pool, key=lambda u: (pool[u][0], pool[u][1])))
        tick(state="scanning", pool_size=len(pool_order), pool_done=0, verified=0)

        attempted: set[str] = set()
        verify_queue: deque[str] = deque()
        pool_done = verified = since_refresh = 0

        def refresh_verify_queue() -> None:
            for username, complete in own.matches_any(clues).items():
                if not complete and username not in attempted and username not in verify_queue:
                    verify_queue.append(username)

        refresh_verify_queue()
        try:
            while True:
                if since_refresh >= PROGRESS_EVERY or (not verify_queue and not pool_order):
                    refresh_verify_queue()
                    since_refresh = 0
                if verify_queue:
                    username, kind = verify_queue.popleft(), "verify"
                elif pool_order:
                    username, kind = pool_order.popleft(), "pool"
                    if username in attempted or all(own.has_archive(username, ym) for ym in months):
                        pool_done += 1
                        continue
                else:
                    break
                attempted.add(username)
                for ym in months:
                    own.ensure_archive(username, ym, fetch, budget)
                since_refresh += 1
                if kind == "verify":
                    verified += 1
                else:
                    pool_done += 1
                if since_refresh % PROGRESS_EVERY == 0:
                    tick(
                        pool_done=pool_done,
                        verified=verified,
                        hits=sum(1 for m in own.matches_all(clues).values() if m["complete"]),
                    )
            exhausted = False
        except BudgetExhausted:
            exhausted = True

        tick(state="enriching", pool_done=pool_done, verified=verified)
        hits = own.matches_all(clues)
        rows = []
        for username, match in sorted(hits.items(), key=lambda kv: (not kv[1]["complete"], kv[0])):
            row: dict[str, Any] = {"username": username, **match}
            if len(rows) < HIT_ENRICH_LIMIT:
                try:
                    profile = fetch_profile(username, fetch)
                except ChesscomError as e:
                    profile = {"error": str(e)}
                if profile:
                    row["profile"] = profile
                    if country and (profile.get("country") or "").lower() != country:
                        row["filtered_out"] = f"country {profile.get('country')} != {country.upper()}"
                    if title and (profile.get("title") or "").upper() != title:
                        row["filtered_out"] = f"title {profile.get('title')} != {title}"
                if opening:
                    row["opening"] = own.opening_count(username, opening, opening_side)
                row["activity"] = own.activity(username)
            rows.append(row)
        results = {
            "state": "done",
            "hits": rows,
            "hit_count": len(rows),
            "verified_hits": sum(1 for r in rows if r["complete"] and not r.get("filtered_out")),
            "budget": {"requests": budget.spent, "max_requests": budget.limit, "exhausted": exhausted},
            "pool": {"size": len(pool), "scanned": pool_done, "verified": verified},
            "next": (
                "Budget exhausted before the pool was scanned: run chesscom_search again "
                "with the same clues (cached work is free) or a larger max_requests."
                if exhausted
                else "Pool scanned. Widen band or add another clue date to expand."
            ),
        }
        _write_json(job / RESULTS_FILE, results)
        tick(state="done", pool_done=pool_done, verified=verified, hits=len(rows))
    except Stopped:
        results = {"state": "stopped"}
        tick(state="stopped")
    except Exception as e:  # noqa: BLE001 - the job must always leave a status
        results = {"state": "failed", "error": f"{type(e).__name__}: {e}"}
        tick(state="failed", error=results["error"])
        raise
    finally:
        if index is None:
            own.close()
    return results


def _jobs_root() -> Path:
    return chesscom_dir() / "searches"


def start_search_process(job: Path) -> int:
    log_path = job / LOG_FILE
    package_root = Path(__file__).resolve().parent.parent
    with log_path.open("ab") as log:
        process = subprocess.Popen(  # noqa: S603 - our own module
            [sys.executable, "-m", "chess_prep.chesscom", "--job", str(job)],
            stdout=log,
            stderr=subprocess.STDOUT,
            stdin=subprocess.DEVNULL,
            cwd=str(package_root),
            start_new_session=True,
        )
    return process.pid


def _pid_alive(pid: int | None) -> bool:
    if not pid:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--job", required=True, help="search job directory")
    args = parser.parse_args(argv)
    _install_stop_handler()
    result = run_search(Path(args.job))
    return 0 if result.get("state") in ("done", "stopped") else 1


# ── Tools ────────────────────────────────────────────────────────────────────


def register_chesscom_tools(registry: Any) -> None:
    from .tools import ToolError, _i, _obj, _s

    def index() -> Index:
        return Index()

    def guard(fn: Callable[[dict], Any]) -> Callable[[dict], Any]:
        def wrapped(args: dict) -> Any:
            try:
                return fn(args)
            except ChesscomError as e:
                raise ToolError(str(e)) from None

        return wrapped

    def category_arg(args: dict) -> str:
        category = str(args.get("category") or "blitz").lower()
        if category not in CATEGORIES:
            raise ToolError(f"category must be one of {', '.join(CATEGORIES)}.")
        return category

    def username_arg(args: dict) -> str:
        username = (args.get("username") or "").strip().lstrip("@")
        if not username:
            raise ToolError("username is required.")
        return username

    def chesscom_profile(args: dict) -> dict:
        username = username_arg(args)
        profile = fetch_profile(username, fetch_json)
        if profile is None:
            raise ToolError(f'chess.com has no player "{username}".')
        own = index()
        try:
            months = args.get("months") or []
            if isinstance(months, str):
                months = [m.strip() for m in months.split(",") if m.strip()]
            for ym in months:
                if not re.fullmatch(r"\d{4}-\d{2}", ym):
                    raise ToolError(f'months are YYYY-MM, not "{ym}".')
                own.ensure_archive(username, ym, fetch_json)
            cached = own.cached_months(username)
            profile["cached_months"] = cached
            if cached:
                profile["activity"] = own.activity(username, months or None)
            opening = san_moves(args.get("opening") or "")
            if opening:
                profile["opening"] = {
                    "line": " ".join(opening),
                    "as_white": own.opening_count(username, opening, "white"),
                    "as_black": own.opening_count(username, opening, "black"),
                    "note": "Counts cover indexed games only: this player's cached months "
                    "plus appearances as an opponent of other cached players.",
                }
        finally:
            own.close()
        return profile

    def chesscom_rating_on(args: dict) -> dict:
        username = username_arg(args)
        category = category_arg(args)
        date = parse_date(args.get("date"))
        window = day_window(date, str(args.get("tz") or "US"))
        months = months_covering(*window)
        own = index()
        try:
            requests = sum(own.ensure_archive(username, ym, fetch_json) for ym in months)
            seen = own.rating_on(username, category, window)
            games = {ym: own.db.execute(
                "SELECT games FROM archives WHERE username=? AND ym=?", (username.lower(), ym)
            ).fetchone()[0] for ym in months}
        finally:
            own.close()
        out = {
            "username": username,
            "category": category,
            "date": date.isoformat(),
            "window_utc": [
                dt.datetime.fromtimestamp(window[0], dt.timezone.utc).isoformat(),
                dt.datetime.fromtimestamp(window[1], dt.timezone.utc).isoformat(),
            ],
            "rating_at_start": seen["at_start"],
            "ratings_during": seen["during"],
            "games_during": seen["games_during"],
            "archived_games_by_month": games,
            "requests": requests,
        }
        if args.get("rating") is not None:
            target = int(args["rating"])
            out["matches"] = target == seen["at_start"] or target in seen["during"]
        if not any(games.values()):
            out["note"] = "No games in these months — no account by that name, or it was idle."
        return out

    def chesscom_who_plays(args: dict) -> dict:
        moves = san_moves(args.get("opening") or "")
        if not moves:
            raise ToolError('opening is required, e.g. "1.e4 e5 2.Nf3 Nc6 3.d4".')
        side = str(args.get("side") or "white").lower()
        if side not in ("white", "black"):
            raise ToolError("side is white or black.")
        category = category_arg(args) if args.get("category") else None
        own = index()
        try:
            players = own.who_plays(
                moves, side, category, int(args.get("min_games") or 1), int(args.get("limit") or 25)
            )
            stats = own.stats()
        finally:
            own.close()
        return {
            "line": " ".join(moves),
            "side": side,
            "players": players,
            "index": {k: stats[k] for k in ("players_with_any_rating", "games_with_moves", "unindexed_files")},
            "note": "Cache only — nobody is downloaded here. A player absent from this list may "
            "simply have no indexed games; chesscom_profile with months= fetches theirs.",
        }

    def chesscom_search(args: dict) -> dict:
        clues = parse_clues(args.get("clues"), str(args.get("tz") or "US"))
        root = _jobs_root()
        root.mkdir(parents=True, exist_ok=True)
        for existing in root.iterdir():
            progress = _read_json(existing / PROGRESS_FILE) or {}
            if progress.get("state") in ("indexing", "leaderboard", "scanning", "enriching") and _pid_alive(
                progress.get("pid")
            ):
                raise ToolError(
                    f"Search {existing.name} is still running (pid {progress['pid']}). "
                    "Poll chesscom_search_status or stop it first; chess.com wants one polite client."
                )
        label = "-".join(f"{c['category']}{c['rating']}-{c['date']}" for c in clues)[:80]
        job = root / f"{time.strftime('%Y%m%d-%H%M%S')}-{label}"
        job.mkdir()
        spec = {
            "clues": args.get("clues"),
            "tz": args.get("tz") or "US",
            "band": int(args.get("band") or DEFAULT_BAND),
            "max_requests": int(args.get("max_requests") or DEFAULT_BUDGET),
            "country": args.get("country"),
            "title": args.get("title"),
            "opening": args.get("opening"),
            "opening_side": args.get("opening_side") or "white",
        }
        _write_json(job / SEARCH_FILE, spec)
        own = index()
        try:
            unindexed = len(own.pending_files())
            known = {} if unindexed else own.matches_all(clues)
        finally:
            own.close()
        try:
            pid = start_search_process(job)
        except OSError as e:
            raise ToolError(f"Could not start the search: {e}") from None
        _write_json(job / PROGRESS_FILE, {"state": "starting", "pid": pid, "requests": 0})
        return {
            "started": True,
            "id": job.name,
            "directory": str(job),
            "pid": pid,
            "clues": [
                {k: c[k] for k in ("category", "rating", "date")} | {"months": c["months"]}
                for c in clues
            ],
            "budget": spec["max_requests"],
            "band": spec["band"],
            "already_matching_in_cache": [
                {"username": u, "complete": m["complete"]} for u, m in known.items()
            ][:25],
            "unindexed_files": unindexed,
            "next": "Poll chesscom_search_status with this id; matches appear as they are indexed.",
        }

    def job_dir(args: dict) -> Path:
        ident = (args.get("id") or "").strip()
        if not ident:
            raise ToolError("id is required (chesscom_search_status with no id lists searches).")
        job = _jobs_root() / ident
        if not (job / SEARCH_FILE).exists():
            raise ToolError(f'No search "{ident}".')
        return job

    def chesscom_search_status(args: dict) -> dict:
        root = _jobs_root()
        if not args.get("id"):
            jobs = []
            if root.exists():
                for entry in sorted(root.iterdir(), reverse=True)[:15]:
                    progress = _read_json(entry / PROGRESS_FILE) or {}
                    jobs.append(
                        {
                            "id": entry.name,
                            "state": progress.get("state"),
                            "requests": progress.get("requests"),
                            "hits": progress.get("hits"),
                            "running": _pid_alive(progress.get("pid"))
                            and progress.get("state") not in ("done", "stopped", "failed"),
                        }
                    )
            own = index()
            try:
                stats = own.stats()
            finally:
                own.close()
            return {"searches": jobs, "index": stats}
        job = job_dir(args)
        spec = _read_json(job / SEARCH_FILE) or {}
        progress = _read_json(job / PROGRESS_FILE) or {}
        running = _pid_alive(progress.get("pid")) and progress.get("state") not in (
            "done",
            "stopped",
            "failed",
        )
        if not running and progress.get("state") not in ("done", "stopped", "failed"):
            progress["state"] = "died"
        out: dict[str, Any] = {"id": job.name, "running": running, "progress": progress}
        results = _read_json(job / RESULTS_FILE)
        if results:
            out["results"] = results
        else:
            clues = parse_clues(spec.get("clues"), spec.get("tz") or "US")
            own = index()
            try:
                matches = own.matches_all(clues)
            finally:
                own.close()
            out["matches_so_far"] = [
                {"username": u, **m}
                for u, m in sorted(matches.items(), key=lambda kv: (not kv[1]["complete"], kv[0]))
            ][:25]
            out["note"] = (
                "complete=true means the player's own archives for the clue months are cached "
                "and the match is verified; false is an opponent-derived sighting the job "
                "verifies next."
            )
        return out

    def chesscom_search_stop(args: dict) -> dict:
        job = job_dir(args)
        progress = _read_json(job / PROGRESS_FILE) or {}
        pid = progress.get("pid")
        if not _pid_alive(pid):
            return {"id": job.name, "stopped": False, "note": "Not running."}
        os.kill(pid, signal.SIGTERM)
        for _ in range(40):
            if not _pid_alive(pid):
                break
            time.sleep(0.25)
        return {
            "id": job.name,
            "stopped": not _pid_alive(pid),
            "note": "Everything downloaded so far stays cached and indexed; a new search "
            "with the same clues continues from it.",
        }

    clue_schema = {
        "type": "array",
        "description": (
            'Rating sightings, e.g. [{"category":"blitz","rating":2701,"date":"2026-06-13"}]. '
            "A match must show every clue. Two dates a week apart beat one."
        ),
        "items": {
            "type": "object",
            "properties": {
                "category": _s("bullet, blitz or rapid (default blitz)."),
                "rating": _i("The exact rating shown that day (post-game ratings are matched)."),
                "date": _s("YYYY-MM-DD, as the friend remembers it (local)."),
                "tz": _s("Per-clue override of the search's tz."),
            },
            "required": ["rating", "date"],
        },
    }

    registry._add(
        "chesscom_profile",
        "One chess.com account: name, title, country, join date, current and "
        "best rating per category with dates (public API, two requests). With "
        "months=[YYYY-MM,...] it also caches those game archives and reports "
        "games per category, busiest UTC hours and — with opening=SAN line — "
        "how often the player opens with that line as White and as Black. "
        "Friend counts are never visible logged out.",
        _obj(
            {
                "username": _s("chess.com username (case-insensitive)."),
                "months": {
                    "type": "array",
                    "items": _s("YYYY-MM"),
                    "description": "Archive months to cache and summarise (one request each).",
                },
                "opening": _s('SAN line to count, e.g. "1.e4 e5 2.Nf3 Nc6 3.d4 exd4 4.Nxd4 Nf6 5.Nxc6 bxc6 6.Bd3".'),
            },
            ["username"],
        ),
        guard(chesscom_profile),
    )
    registry._add(
        "chesscom_rating_on",
        "What did this account's rating read on a given day? Rebuilt from the "
        "monthly game archives (post-game ratings): the rating in force when "
        "the day began and every rating shown during it. Caches the needed "
        "months (at most three requests, none if cached). Pass rating= to get "
        "a plain matches=true/false. Dates are local to the player: tz=US "
        "(default) spans every US zone, tz=UTC is exact, or an IANA zone.",
        _obj(
            {
                "username": _s("chess.com username."),
                "category": _s("bullet, blitz or rapid (default blitz)."),
                "date": _s("YYYY-MM-DD."),
                "rating": _i("Optional expected rating; sets matches."),
                "tz": _s("US (default), UTC, or an IANA zone such as America/New_York."),
            },
            ["username", "date"],
        ),
        guard(chesscom_rating_on),
    )
    registry._add(
        "chesscom_who_plays",
        "Who in the local archive index opens with this line? Reads the cache "
        "only (no requests): every indexed game of every cached player and "
        "their opponents, first 20 plies. Returns players by number of games "
        "with the line and their share of games on that side. Use it to rank "
        "search hits by an opening clue, not as a search on its own — a player "
        "with no cached games cannot appear.",
        _obj(
            {
                "opening": _s('SAN line, e.g. "1.e4 e5 2.Nf3 Nc6 3.d4". Move numbers optional.'),
                "side": _s("white (default) or black — the side that plays the line."),
                "category": _s("Restrict to bullet, blitz or rapid."),
                "min_games": _i("Minimum games with the line (default 1)."),
                "limit": _i("Max players (default 25)."),
            },
            ["opening"],
        ),
        guard(chesscom_who_plays),
    )
    registry._add(
        "chesscom_search",
        "Find the account that showed these ratings on these days. Starts a "
        "background job (returns at once; poll chesscom_search_status): it "
        "indexes any unindexed archives, pages the website blitz/bullet/rapid "
        "leaderboard for players currently within band of each clue rating, "
        "downloads their archives for the clue months, and — the part that "
        "works — verifies every opponent seen at the clue rating inside those "
        "archives, so accounts that have since dropped off the leaderboard are "
        "found through the people they played. Requests are serial and polite "
        "(~0.15 s apart); max_requests bounds the run, and every download is "
        "cached, so rerunning with the same clues resumes for free. "
        "country/title filter the pool by leaderboard data; opening only "
        "annotates hits. Never start one the user did not ask for.",
        _obj(
            {
                "clues": clue_schema,
                "tz": _s("US (default), UTC or an IANA zone for every clue date."),
                "band": _i(
                    "Leaderboard pool: players whose CURRENT rating is within this of a clue "
                    "rating (default 200; a player who dropped 300 is still found via opponents)."
                ),
                "max_requests": _i("HTTP request budget for this run (default 1500, ~5 min)."),
                "country": _s("Two-letter code or country name to restrict the pool, e.g. US."),
                "title": _s("Restrict the pool to this title (GM, IM, ...) or leave unset."),
                "opening": _s("SAN line to count for each hit (annotation only)."),
                "opening_side": _s("white (default) or black for the opening count."),
            },
            ["clues"],
        ),
        guard(chesscom_search),
    )
    registry._add(
        "chesscom_search_status",
        "Progress and matches of a chesscom_search: state (indexing → "
        "leaderboard → scanning → enriching → done), requests spent, pool "
        "size/scanned, and the players matching every clue so far — read live "
        "from the shared index, so partial results are visible before the job "
        "ends. complete=true is verified from the player's own archives. With "
        "no id: recent searches and index statistics (cached archives, players, "
        "rating events).",
        _obj({"id": _s("Search id from chesscom_search (omit to list).")}),
        guard(chesscom_search_status),
    )
    registry._add(
        "chesscom_search_stop",
        "Stop a running chesscom_search. The cache and index keep everything "
        "downloaded so far; the same clues resume from it.",
        _obj({"id": _s("Search id.")}, ["id"]),
        guard(chesscom_search_stop),
    )


if __name__ == "__main__":  # pragma: no cover - background entry point
    sys.exit(main())
