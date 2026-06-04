# Chess Lesson Booking

> **Integrated into the TWIC API server.** The standalone `booking-service/` directory is no longer required for deployment and can be removed once you are satisfied with the integration.

Booking endpoints live on the same FastAPI app as TWIC Position Finder (`python/twic-position-finder/server.py`), served at `https://api.chessautoprep.com`. Implementation is in `python/twic-position-finder/booking.py`.

The Astro booking page is at `/book` on the main site (`python/twic-position-finder/frontend/src/pages/book.astro`). It uses `PUBLIC_API_URL` like the rest of the frontend — not a separate booking API URL.

## Run locally

```bash
cd python/twic-position-finder
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt   # FastAPI, uvicorn, pydantic — no extra booking deps

export BOOKING_API_KEY="your-secret-key"
export BOOKING_OWNER_NAME="Alex"
export BOOKING_TIMEZONE="America/New_York"

uvicorn server:app --host 0.0.0.0 --port 8000
```

Health check: `http://localhost:8000/health`

Frontend dev (API on 8000, Astro on 4321):

```bash
cd python/twic-position-finder/frontend
npm run dev
# book page calls http://localhost:8000 by default (PUBLIC_API_URL)
```

## Configuration

Set environment variables on the TWIC API process (or edit defaults in `booking.py`):

| Variable | Default | Description |
|----------|---------|-------------|
| `BOOKING_OWNER_NAME` | Your Chess Coach | Name on the booking page |
| `BOOKING_TAGLINE` | (see `booking.py`) | Short description |
| `BOOKING_TIMEZONE` | America/New_York | IANA timezone for slots |
| `BOOKING_API_KEY` | change-me-in-production | `X-API-Key` for admin endpoint |
| `BOOKING_DATABASE_PATH` | `bookings.db` next to server | SQLite file path |

Schedule options in `booking.py`:

- `SLOT_DURATION_MINUTES` — length of each lesson (default 30)
- `AVAILABLE_WEEKDAYS` — tuple of weekday numbers (0=Monday … 6=Sunday)
- `START_HOUR` / `END_HOUR` — daily window in local timezone

CORS for the booking page is handled by the main server (`TWIC_FRONTEND_ORIGIN` / debug localhost origins).

## API

### `GET /health`

```json
{ "status": "ok", "service": "booking" }
```

### `GET /api/slots?week_start=YYYY-MM-DD`

Returns available slots for the 7-day window starting `week_start` (typically Monday).

```json
{
  "owner_name": "Alex",
  "tagline": "Pick a time…",
  "timezone": "America/New_York",
  "slot_duration_minutes": 30,
  "week_start": "2026-06-02",
  "slots": ["2026-06-02T10:00:00-04:00", "..."]
}
```

### `POST /api/book`

```json
{
  "slot": "2026-06-02T10:00:00-04:00",
  "name": "Friend",
  "message": "Want to work on the Italian Game"
}
```

### `GET /api/bookings`

List all bookings. Requires header:

```
X-API-Key: your-secret-key
```

## Production notes

- Use a strong `BOOKING_API_KEY` and never expose it in the frontend.
- Persist `bookings.db` on the same volume as `positions.db` (or set `BOOKING_DATABASE_PATH`).
- The `/book` page is not linked from site navigation; share the URL directly.

## Legacy standalone service

The files in this directory (`server.py`, `config.py`) were the original standalone service on port 8080. They are superseded by `python/twic-position-finder/booking.py`. You may delete `booking-service/` after migrating any existing `bookings.db` path and env vars to the TWIC server host.
