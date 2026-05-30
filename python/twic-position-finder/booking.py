"""Chess lesson booking — slots and reservations (SQLite)."""

from __future__ import annotations

import os
import sqlite3
from contextlib import contextmanager
from datetime import date, datetime, time, timedelta
from pathlib import Path
from typing import Iterator
from zoneinfo import ZoneInfo

from fastapi import APIRouter, Depends, Header, HTTPException, Query
from pydantic import BaseModel, Field

# ── Schedule & display (env overrides) ─────────────────────────────────

OWNER_NAME = os.getenv("BOOKING_OWNER_NAME", "Bookings")
TIMEZONE = ZoneInfo(os.getenv("BOOKING_TIMEZONE", "America/New_York"))
SLOT_DURATION_MINUTES = 90  # lesson length (display); offered start times use SLOT_GRID_INTERVAL_MINUTES
SLOT_GRID_INTERVAL_MINUTES = int(os.getenv("BOOKING_SLOT_INTERVAL_MINUTES", "90"))
SLOT_GRID_START_HOUR = int(os.getenv("BOOKING_SLOT_START_HOUR", "12"))  # noon
SLOT_GRID_END_HOUR = int(os.getenv("BOOKING_SLOT_END_HOUR", "21"))  # lessons must finish by this hour
TAGLINE = os.getenv(
    "BOOKING_TAGLINE",
    "Pick a time to meet the incredibly handsome, funny, wannabe chess master",
)
API_KEY = os.getenv("BOOKING_API_KEY", "change-me-in-production")


def _env_date(name: str, default: str) -> date:
    return date.fromisoformat(os.getenv(name, default))


BOOKING_DATE_START = _env_date("BOOKING_DATE_START", "2026-06-01")
BOOKING_DATE_END = _env_date("BOOKING_DATE_END", "2026-06-14")


def _parse_blocked_dates() -> frozenset[date]:
    raw = os.getenv("BOOKING_BLOCKED_DATES", "2026-06-06,2026-06-07")
    if not raw.strip():
        return frozenset()
    return frozenset(
        date.fromisoformat(part.strip())
        for part in raw.split(",")
        if part.strip()
    )


def _blocked_dates() -> frozenset[date]:
    """Read blocked dates from env on each use (picks up BOOKING_BLOCKED_DATES without restart)."""
    return _parse_blocked_dates()


def _parse_weekdays() -> frozenset[int]:
    """Weekdays bookable by default: 0=Mon … 4=Fri."""
    raw = os.getenv("BOOKING_AVAILABLE_WEEKDAYS", "0,1,2,3,4")
    return frozenset(int(part.strip()) for part in raw.split(",") if part.strip())


AVAILABLE_WEEKDAYS = _parse_weekdays()


def _parse_available_date_exceptions() -> frozenset[date]:
    """Explicit calendar dates that are bookable outside weekday rules (e.g. promo weekends)."""
    raw = os.getenv("BOOKING_AVAILABLE_DATES", "2026-06-13,2026-06-14")
    if not raw.strip():
        return frozenset()
    return frozenset(
        date.fromisoformat(part.strip())
        for part in raw.split(",")
        if part.strip()
    )


BOOKING_AVAILABLE_DATES = _parse_available_date_exceptions()

_DB_DEFAULT = Path(__file__).parent / "bookings.db"
_db_env = os.getenv("BOOKING_DATABASE_PATH", "")
DB_PATH = Path(_db_env) if _db_env else _DB_DEFAULT
if not DB_PATH.is_absolute():
    DB_PATH = Path(__file__).resolve().parent / DB_PATH


@contextmanager
def _get_db() -> Iterator[sqlite3.Connection]:
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    try:
        yield conn
        conn.commit()
    finally:
        conn.close()


def init_booking_db() -> None:
    with _get_db() as conn:
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS bookings (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                slot TEXT NOT NULL UNIQUE,
                name TEXT NOT NULL,
                message TEXT,
                created_at TEXT NOT NULL DEFAULT (datetime('now'))
            )
            """
        )


def _parse_slot(iso: str) -> datetime:
    try:
        dt = datetime.fromisoformat(iso.replace("Z", "+00:00"))
    except ValueError as exc:
        raise HTTPException(status_code=400, detail="Invalid slot datetime") from exc
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=TIMEZONE)
    return dt.astimezone(TIMEZONE)


def _booked_slots(conn: sqlite3.Connection) -> set[str]:
    rows = conn.execute("SELECT slot FROM bookings").fetchall()
    return {row["slot"] for row in rows}


def _is_day_bookable(day: date) -> bool:
    if day < BOOKING_DATE_START or day > BOOKING_DATE_END:
        return False
    if day in _blocked_dates():
        return False
    if day in BOOKING_AVAILABLE_DATES:
        return True
    return day.weekday() in AVAILABLE_WEEKDAYS


def _grid_start_minutes() -> int:
    return SLOT_GRID_START_HOUR * 60


def _grid_end_minutes() -> int:
    """Latest minute-of-day a lesson may end (e.g. 21:00 = 9 PM)."""
    return SLOT_GRID_END_HOUR * 60


def _latest_start_minutes() -> int:
    """Last offered start so start + lesson length ends on or before grid end."""
    return _grid_end_minutes() - SLOT_DURATION_MINUTES


def _minutes_on_grid(total_minutes: int) -> bool:
    offset = total_minutes - _grid_start_minutes()
    if offset < 0:
        return False
    return offset % SLOT_GRID_INTERVAL_MINUTES == 0


def _slot_aligns_grid(slot_dt: datetime) -> bool:
    if slot_dt.second != 0 or slot_dt.microsecond != 0:
        return False
    total = slot_dt.hour * 60 + slot_dt.minute
    if total < _grid_start_minutes() or total > _latest_start_minutes():
        return False
    return _minutes_on_grid(total)


def _slot_within_hours(slot_dt: datetime) -> bool:
    return _slot_aligns_grid(slot_dt)


def _is_slot_available(slot_dt: datetime, booked: set[str], now: datetime) -> bool:
    if slot_dt <= now:
        return False
    if not _is_day_bookable(slot_dt.date()):
        return False
    if not _slot_within_hours(slot_dt):
        return False
    iso = slot_dt.isoformat()
    return iso not in booked


def _grid_start_times_for_day(day: date) -> list[datetime]:
    """All offered start times on the 90-minute grid (noon–9 PM)."""
    if not _is_day_bookable(day):
        return []
    starts: list[datetime] = []
    total = _grid_start_minutes()
    last_start = _latest_start_minutes()
    while total <= last_start:
        h, m = divmod(total, 60)
        starts.append(datetime.combine(day, time(h, m), tzinfo=TIMEZONE))
        total += SLOT_GRID_INTERVAL_MINUTES
    return starts


def _generate_slots_for_day(day: date, booked: set[str], now: datetime) -> list[str]:
    slots: list[str] = []
    for current in _grid_start_times_for_day(day):
        if _is_slot_available(current, booked, now):
            slots.append(current.isoformat())
    return slots


def slots_for_week(week_start: date) -> list[str]:
    now = datetime.now(TIMEZONE)
    result: list[str] = []
    with _get_db() as conn:
        booked = _booked_slots(conn)
    for offset in range(7):
        day = week_start + timedelta(days=offset)
        result.extend(_generate_slots_for_day(day, booked, now))
    return result


class BookRequest(BaseModel):
    slot: str = Field(..., description="ISO 8601 datetime of the slot")
    name: str = Field(..., min_length=1, max_length=120)
    message: str | None = Field(None, max_length=2000)
    rating: int | None = Field(None, ge=1, le=10, description="Website coolness 1–10")


class BookingOut(BaseModel):
    id: int
    slot: str
    name: str
    message: str | None
    created_at: str


router = APIRouter(tags=["booking"])


def require_api_key(x_api_key: str | None = Header(None, alias="X-API-Key")) -> None:
    if not x_api_key or x_api_key != API_KEY:
        raise HTTPException(status_code=401, detail="Invalid or missing API key")


@router.get("/health")
def booking_health():
    return {"status": "ok", "service": "booking"}


@router.get("/api/slots")
def get_slots(week_start: str = Query(..., description="First day of week (YYYY-MM-DD)")):
    try:
        start = date.fromisoformat(week_start)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail="week_start must be YYYY-MM-DD") from exc
    return {
        "owner_name": OWNER_NAME,
        "tagline": TAGLINE,
        "timezone": str(TIMEZONE),
        "slot_duration_minutes": SLOT_DURATION_MINUTES,
        "slot_interval_minutes": SLOT_GRID_INTERVAL_MINUTES,
        "slot_start_hour": SLOT_GRID_START_HOUR,
        "slot_end_hour": SLOT_GRID_END_HOUR,
        "week_start": start.isoformat(),
        "booking_date_start": BOOKING_DATE_START.isoformat(),
        "booking_date_end": BOOKING_DATE_END.isoformat(),
        "blocked_dates": sorted(d.isoformat() for d in _blocked_dates()),
        "available_weekdays": sorted(AVAILABLE_WEEKDAYS),
        "available_date_exceptions": sorted(d.isoformat() for d in BOOKING_AVAILABLE_DATES),
        "slots": slots_for_week(start),
    }


@router.post("/api/book")
def create_booking(body: BookRequest):
    slot_dt = _parse_slot(body.slot)
    now = datetime.now(TIMEZONE)
    if slot_dt <= now:
        raise HTTPException(status_code=400, detail="Cannot book a past time slot")
    iso = slot_dt.isoformat()
    with _get_db() as conn:
        booked = _booked_slots(conn)
    if not _is_slot_available(slot_dt, booked, now):
        if not _is_day_bookable(slot_dt.date()):
            raise HTTPException(status_code=400, detail="This day is not available")
        if not _slot_within_hours(slot_dt):
            raise HTTPException(
                status_code=400,
                detail=(
                    f"Choose a start time on the {SLOT_GRID_INTERVAL_MINUTES}-minute grid "
                    f"from {SLOT_GRID_START_HOUR}:00 through {_latest_start_minutes() // 60}:{_latest_start_minutes() % 60:02d}"
                ),
            )
        if iso in booked:
            raise HTTPException(status_code=409, detail="This slot is already booked")
        raise HTTPException(status_code=409, detail="This slot is no longer available")
    name = body.name.strip()
    if not name:
        raise HTTPException(status_code=400, detail="Name is required")
    message = body.message.strip() if body.message else None
    if body.rating is not None:
        rating_line = f"Website rating: {body.rating}/10"
        message = f"{rating_line}\n{message}" if message else rating_line
    try:
        with _get_db() as conn:
            conn.execute(
                "INSERT INTO bookings (slot, name, message) VALUES (?, ?, ?)",
                (iso, name, message),
            )
    except sqlite3.IntegrityError:
        raise HTTPException(status_code=409, detail="This slot is already booked")
    return {"ok": True, "slot": iso, "name": name}


@router.get("/api/bookings", response_model=list[BookingOut])
def list_bookings(_: None = Depends(require_api_key)):
    with _get_db() as conn:
        rows = conn.execute(
            "SELECT id, slot, name, message, created_at FROM bookings ORDER BY slot ASC"
        ).fetchall()
    return [
        BookingOut(
            id=row["id"],
            slot=row["slot"],
            name=row["name"],
            message=row["message"],
            created_at=row["created_at"],
        )
        for row in rows
    ]
