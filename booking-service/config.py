"""Booking service configuration — edit these values for your schedule."""

import os
from zoneinfo import ZoneInfo

# Display name on the booking page (returned by GET /api/slots)
OWNER_NAME = os.getenv("BOOKING_OWNER_NAME", "Your Chess Coach")

# IANA timezone for slot generation and display
TIMEZONE = ZoneInfo(os.getenv("BOOKING_TIMEZONE", "America/New_York"))

# Slot length in minutes
SLOT_DURATION_MINUTES = 30

# Weekdays when lessons are offered (Monday=0 … Sunday=6)
AVAILABLE_WEEKDAYS = (0, 1, 2, 3, 4)  # Mon–Fri

# Daily window (24h, local TIMEZONE). Last slot starts before END_HOUR.
START_HOUR = 10
END_HOUR = 18

# SQLite database file (relative to booking-service/ or absolute path)
DATABASE_PATH = os.getenv("BOOKING_DATABASE_PATH", "bookings.db")

# Admin API key for GET /api/bookings (set BOOKING_API_KEY in production)
API_KEY = os.getenv("BOOKING_API_KEY", "change-me-in-production")

# CORS — comma-separated origins in BOOKING_CORS_ORIGINS, or defaults below
_default_cors = [
    "http://localhost:4321",
    "http://127.0.0.1:4321",
    "https://chessautoprep.com",
    "https://www.chessautoprep.com",
]
CORS_ORIGINS = [
    o.strip()
    for o in os.getenv("BOOKING_CORS_ORIGINS", "").split(",")
    if o.strip()
] or _default_cors

# Tagline shown on the booking page (optional override via API)
TAGLINE = os.getenv(
    "BOOKING_TAGLINE",
    "Pick a time that works for you — 30-minute lesson, all levels welcome.",
)
