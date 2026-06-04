"""Chess lesson booking API — run with: uvicorn server:app --host 0.0.0.0 --port 8080"""

from __future__ import annotations

import sqlite3
from contextlib import contextmanager
from datetime import date, datetime, time, timedelta
from pathlib import Path
from typing import Iterator

from fastapi import Depends, FastAPI, Header, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field

import config

DB_PATH = Path(config.DATABASE_PATH)
if not DB_PATH.is_absolute():
    DB_PATH = Path(__file__).resolve().parent / DB_PATH


@contextmanager
def get_db() -> Iterator[sqlite3.Connection]:
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    try:
        yield conn
        conn.commit()
    finally:
        conn.close()


def init_db() -> None:
    with get_db() as conn:
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
        dt = dt.replace(tzinfo=config.TIMEZONE)
    return dt.astimezone(config.TIMEZONE)


def _booked_slots(conn: sqlite3.Connection) -> set[str]:
    rows = conn.execute("SELECT slot FROM bookings").fetchall()
    return {row["slot"] for row in rows}


def _generate_slots_for_day(day: date, booked: set[str], now: datetime) -> list[str]:
    if day.weekday() not in config.AVAILABLE_WEEKDAYS:
        return []
    slots: list[str] = []
    duration = timedelta(minutes=config.SLOT_DURATION_MINUTES)
    current = datetime.combine(day, time(config.START_HOUR, 0), tzinfo=config.TIMEZONE)
    end = datetime.combine(day, time(config.END_HOUR, 0), tzinfo=config.TIMEZONE)
    while current + duration <= end:
        iso = current.isoformat()
        if iso not in booked and current > now:
            slots.append(iso)
        current += duration
    return slots


def slots_for_week(week_start: date) -> list[str]:
    """All available slot ISO strings from week_start through week_start + 6 days."""
    now = datetime.now(config.TIMEZONE)
    result: list[str] = []
    with get_db() as conn:
        booked = _booked_slots(conn)
    for offset in range(7):
        day = week_start + timedelta(days=offset)
        result.extend(_generate_slots_for_day(day, booked, now))
    return result


class BookRequest(BaseModel):
    slot: str = Field(..., description="ISO 8601 datetime of the slot")
    name: str = Field(..., min_length=1, max_length=120)
    message: str | None = Field(None, max_length=2000)


class BookingOut(BaseModel):
    id: int
    slot: str
    name: str
    message: str | None
    created_at: str


app = FastAPI(title="Chess Lesson Booking", version="1.0.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=config.CORS_ORIGINS,
    allow_credentials=True,
    allow_methods=["GET", "POST", "OPTIONS"],
    allow_headers=["*"],
)


@app.on_event("startup")
def on_startup() -> None:
    init_db()


def require_api_key(x_api_key: str | None = Header(None, alias="X-API-Key")) -> None:
    if not x_api_key or x_api_key != config.API_KEY:
        raise HTTPException(status_code=401, detail="Invalid or missing API key")


@app.get("/api/slots")
def get_slots(week_start: str = Query(..., description="First day of week (YYYY-MM-DD)")):
    try:
        start = date.fromisoformat(week_start)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail="week_start must be YYYY-MM-DD") from exc
    return {
        "owner_name": config.OWNER_NAME,
        "tagline": config.TAGLINE,
        "timezone": str(config.TIMEZONE),
        "slot_duration_minutes": config.SLOT_DURATION_MINUTES,
        "week_start": start.isoformat(),
        "slots": slots_for_week(start),
    }


@app.post("/api/book")
def create_booking(body: BookRequest):
    slot_dt = _parse_slot(body.slot)
    now = datetime.now(config.TIMEZONE)
    if slot_dt <= now:
        raise HTTPException(status_code=400, detail="Cannot book a past time slot")
    if slot_dt.weekday() not in config.AVAILABLE_WEEKDAYS:
        raise HTTPException(status_code=400, detail="This day is not available")
    hour = slot_dt.hour + slot_dt.minute / 60
    if hour < config.START_HOUR or hour >= config.END_HOUR:
        raise HTTPException(status_code=400, detail="Time is outside available hours")
    iso = slot_dt.isoformat()
    available = slots_for_week(slot_dt.date() - timedelta(days=slot_dt.weekday()))
    if iso not in available:
        raise HTTPException(status_code=409, detail="This slot is no longer available")
    name = body.name.strip()
    if not name:
        raise HTTPException(status_code=400, detail="Name is required")
    message = body.message.strip() if body.message else None
    try:
        with get_db() as conn:
            conn.execute(
                "INSERT INTO bookings (slot, name, message) VALUES (?, ?, ?)",
                (iso, name, message),
            )
    except sqlite3.IntegrityError:
        raise HTTPException(status_code=409, detail="This slot is already booked")
    return {"ok": True, "slot": iso, "name": name}


@app.get("/api/bookings", response_model=list[BookingOut])
def list_bookings(_: None = Depends(require_api_key)):
    with get_db() as conn:
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


@app.get("/health")
def health():
    return {"status": "ok"}
