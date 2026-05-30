# TWIC Position Finder

Index every position from [The Week in Chess](https://theweekinchess.com/) using Zobrist hashing, then get weekly email alerts when new games match your positions, players, or openings. One-click analysis on Lichess.

## Quick Start

```bash
cd python/twic-position-finder
pip install -r requirements.txt
```

## Architecture

```
python/twic-position-finder/
  models.py          # SQLite schema (games, positions, users, subscriptions)
  downloader.py      # Auto-download TWIC zips
  ingest.py          # Parse PGN, replay moves, Zobrist hash, store in SQLite
  query.py           # FEN lookup + filters + tree explorer CLI
  lichess.py         # Import games to Lichess via API
  email_sender.py    # HTML emails via Amazon SES
  server.py          # FastAPI backend (registration, subscriptions, queries)
  booking.py         # Lesson booking routes (SQLite bookings.db)
  weekly.py          # Weekly cron job: ingest -> match -> import -> email
  frontend/          # Astro static site (Cloudflare Pages)
```

## CLI Usage

### Ingest a PGN file

```bash
python ingest.py twic1637.pgn
```

### Auto-download and ingest the latest TWIC issues

```bash
python ingest.py                # from last ingested + 1
python ingest.py --from 1630    # start from a specific number
```

### Query by FEN

```bash
python query.py "rnbqkbnr/pppp1ppp/4p3/8/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2"
```

### Opening explorer (move tree)

```bash
python query.py --tree "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1"
```

### Filters

```bash
python query.py "..." --white "Carlsen"
python query.py "..." --exclude-site "chess.com"
python query.py "..." --min-elo 2600 --eco "B"
python query.py "..." --player "Nakamura" --json
```

## Web App

### Backend (FastAPI)

```bash
# Set environment variables
export TWIC_FROM_EMAIL="alerts@chessautoprep.com"
export TWIC_SITE_URL="https://chessautoprep.com"
export AWS_SES_REGION="us-east-1"
export LICHESS_API_TOKEN="lip_..."    # optional, for game import

# Run the server
python server.py
# or: uvicorn server:app --host 0.0.0.0 --port 8000
```

API endpoints:
- `POST /api/register` — sign up with email
- `GET /api/verify?token=...` — verify email
- `POST /api/login` — request login link
- `GET /api/subscriptions?token=...` — list subscriptions
- `POST /api/subscriptions?token=...` — create subscription
- `DELETE /api/subscriptions/{id}?token=...` — delete subscription
- `GET /api/query?fen=...&player=...` — query games
- `GET /api/tree?fen=...` — opening explorer
- `GET /api/stats` — database stats

### Frontend (Astro)

```bash
cd frontend
npm install
npm run dev     # dev server at localhost:4321
npm run build   # static build to dist/
```

Deploy `dist/` to Cloudflare Pages. Set `PUBLIC_API_URL` to `https://api.chessautoprep.com`.

### Lesson booking (`/book`)

Booking uses the same API server and `PUBLIC_API_URL`. Schedule env (defaults target the June 2026 promo window):

| Variable | Default | Purpose |
|----------|---------|---------|
| `BOOKING_DATE_START` | `2026-06-01` | First bookable calendar day (inclusive) |
| `BOOKING_DATE_END` | `2026-06-14` | Last bookable day (inclusive) |
| `BOOKING_BLOCKED_DATES` | `2026-06-06,2026-06-07` | Comma-separated dates with no slots |
| `BOOKING_SLOT_START_HOUR` | `12` | First offered start time (noon) |
| `BOOKING_SLOT_END_HOUR` | `21` | Latest lesson end time (9 PM); last start is 7:30 PM with 90-min lessons |
| `BOOKING_SLOT_INTERVAL_MINUTES` | `90` | Spacing between offered start times |
| `BOOKING_AVAILABLE_WEEKDAYS` | `0,1,2,3,4` | Weekdays allowed (`0`=Mon … `4`=Fri) |
| `BOOKING_AVAILABLE_DATES` | `2026-06-13,2026-06-14` | Extra bookable calendar dates (e.g. promo weekends) |
| `BOOKING_TIMEZONE` | `America/New_York` | Slot generation timezone |
| `BOOKING_OWNER_NAME`, `BOOKING_TAGLINE`, `BOOKING_API_KEY`, `BOOKING_DATABASE_PATH` | — | Display, admin API key, SQLite path |

Endpoints: `GET /health`, `GET /api/slots` (returns window, `blocked_dates`, `available_weekdays`, `available_date_exceptions`, slot grid metadata, and open `slots`), `POST /api/book`, `GET /api/bookings` (admin, `X-API-Key`). Offered times use a 90-minute grid from noon; each lesson is 90 minutes and the last start is 7:30 PM (ends 9 PM). Weekends are closed except dates listed in `BOOKING_AVAILABLE_DATES`. See `booking-service/README.md` for full API notes.

### Weekly Cron Job

```bash
# Dry run (prints actions, saves email preview HTML)
python weekly.py --dry-run

# Production run
python weekly.py
```

The weekly job:
1. Downloads any new TWIC issues
2. Ingests them into the position database
3. Matches all active user subscriptions
4. Imports matched games to Lichess (if `LICHESS_API_TOKEN` is set)
5. Sends HTML emails via Amazon SES

Add to crontab for automatic weekly runs:
```
0 12 * * 1 cd /path/to/twic-position-finder && python weekly.py >> weekly.log 2>&1
```

## Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `TWIC_FROM_EMAIL` | For emails | SES verified sender address |
| `TWIC_SITE_URL` | For emails | Frontend URL for links in emails |
| `AWS_SES_REGION` | For emails | AWS region (default: us-east-1) |
| `AWS_ACCESS_KEY_ID` | For emails | AWS credentials for SES |
| `AWS_SECRET_ACCESS_KEY` | For emails | AWS credentials for SES |
| `LICHESS_API_TOKEN` | Optional | Lichess PAT for game import |
| `TWIC_DB_PATH` | Optional | Custom database path |
| `TWIC_FRONTEND_ORIGIN` | Optional | CORS origin for the frontend |

## How It Works

1. **PGN Parsing**: `python-chess` reads each game from TWIC PGN files
2. **Move Replay**: Every move replayed to reconstruct each position
3. **Zobrist Hashing**: 64-bit Polyglot Zobrist hash at each ply — captures piece placement, side to move, castling rights, and en passant
4. **SQLite Storage**: Indexed for O(log n) position lookups
5. **Subscription Matching**: Each user's FEN/player/ECO filters matched against new games
6. **Lichess Import**: Matched games imported via `POST /api/import` for one-click analysis
7. **Email Delivery**: Rich HTML emails via Amazon SES with game summaries and Lichess buttons

## License

AGPL-3.0 — see main project [LICENSE](../../LICENSE) file.
