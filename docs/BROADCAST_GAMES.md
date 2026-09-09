# Broadcast games: collecting over-the-board games that TWIC never sees

How a regional tournament game ends up in public databases, how to find the
broadcasts it came from, and the tools that turn them into a corpus the app
and the chess-prep MCP can query. Written up from the September 2026
investigation that produced the Massachusetts collection in
`scripts/data/broadcasts/massachusetts/`.

## Where a published game comes from

The app's master games database is built from The Week in Chess (TWIC).
TWIC carries the large events only. Two personal games traced end to end:

| Game | Chain |
|---|---|
| World Open 2026, round 9 board 250 | Lichess broadcast (tour `2WsZz8R3`, ~27 electronic boards per round) → TWIC issue 1652 → chess.ceo, chess.com and the app's master DB |
| Massachusetts Open 2025, round 1 board 4 | chess.com Events broadcast (`2025-massachusetts-open`) → chess.com master games (`games/view/17887220`). Never in TWIC or on Lichess |

Aggregators such as chess.ceo ingest TWIC plus Lichess broadcasts plus an old
historical database. Their `/board/<hex>` URLs are local browser-tab ids;
`/board/g/<id>` is the shareable form.

TWIC has no Massachusetts event at all across the 264 issues in the local
database. Only the top three or four boards of a regional event are
broadcast, and only when the organiser runs a broadcast, so for an ordinary
weekend tournament the scoresheet is the only copy.

## Finding broadcasts

### Lichess

- `GET /api/broadcast/search?q=` and `GET /api/broadcast/top` index only the
  official, tiered broadcasts. Community broadcasts (a state association's)
  are invisible there.
- Community broadcasts are reachable by the account that ran them:
  `GET /api/broadcast/by/<user>` (paged). The Massachusetts Chess Association
  broadcasts as `falstan`; the owner name is in the broadcast page's embedded
  JSON (`communityOwner`).
- Any tour is downloadable as one PGN, no login:
  `GET /api/broadcast/<tourId>.pgn`. `GET /api/broadcast/<tourId>` gives the
  rounds and whether they are finished.
- Some broadcasters name every game's `Event` after its pairing
  ("Round 2: A - B") and put the Lichess game URL in `Site`; the collector
  repairs both so the app's authority rules see a venue and, for
  "Qualifier Blitz Playoffs #2: A - B", the speed of play.

### chess.com Events (the former Chessbomb)

- Search: `POST https://www.chess.com/events/v1/api/searchv2` with
  `{"searchFor": "...", "timeFilter": "currentAndPast", "includeSelfServe": true}`.
  This does find community events by name.
- Event record: `POST https://www.chess.com/events/v1/api/room/<slug>` with
  `{}` returns the room, rounds, groups and games (players, FIDE ids, ratings,
  board, result, venue) but no moves.
- Moves are served only over the events websocket. `/events/pgn/<eventId>/<roundId>`
  redirects to login, and the master-games search (`/games/search?p1=&p2=`)
  answers 429 after a handful of requests.
- Websocket: Socket.IO v4 at `wss://nxt.chessbomb.com/pubsub/public/?EIO=4&transport=websocket&userId=guest-<id>`
  (websocket transport only; polling is refused). Join the namespace with
  `40/public,`, then send
  `42/public,["message",["message",{"type":"get-game","roomSlug":"<event>","roundSlug":"<round>","gameSlug":"<game>","markerMoves":0,"markerAnalysis":999999999,"fullState":true}]]`.
  The reply (`42/public,["message",{...}]`) carries `message.data.moves`, each
  move as `cbn` = `uci_san` with a clock in milliseconds. Answer engine.io
  pings (`2`) with `3`.
- chess.com master-game pages (`/games/view/<id>`) embed the moves in
  chess.com's TCN encoding (two characters per move over a 64+ symbol
  alphabet; promotions in the upper range). Decoded and legality-checked
  during the investigation but not used by the tools, since the websocket
  gives SAN directly.

## Tools

| Tool | Role |
|---|---|
| `tools/lichess_broadcasts.py` | `by USER`, `tour ID...`, `search QUERY`, `status`. Writes a collection: `tours/<tourId>.pgn` per broadcast, `manifest.json`, and the merged `<collection>.pgn`. Zero dependencies |
| `tools/chesscom_events.py` | `search QUERY`, `event SLUG...`, `status`. Same collection layout; `tours/chesscom-<slug>.pgn`. Contains the stdlib RFC 6455 + Socket.IO client |
| `tools/master_import_pgn.dart` | Runs the app's TWIC importer on PGN files to build a master-format database (`games` + position `book`). Runs under `flutter test` because the PGN parser depends on Flutter foundation |

Collections live under `Documents/lichess_broadcasts/<collection>/` by
default; `--out DIR` points both collectors at any directory, including the
committed copy. A broadcast whose rounds are all finished is not fetched again
unless `--refresh` is given.

Game identity in the merged PGN is the two players (order-free name tokens,
initials ignored), the result and the first sixteen plies. The same board
arrives from Lichess and chess.com with different URLs, name orders and even
dates (one site stamps the round, the other the broadcast), so no tag the
broadcaster set is trusted. When both sites have a game the copy with more
information is kept, which is the chess.com one with clocks.

Tests: `tools/test_lichess_broadcasts.py`, `tools/test_chesscom_events.py`
(both offline; the websocket client is exercised against a scripted fake).

## Workflow

```
# 1. Find broadcasts
python3 tools/chesscom_events.py search massachusetts
python3 tools/lichess_broadcasts.py search "World Open"          # official only

# 2. Fetch into the committed collection
python3 tools/lichess_broadcasts.py by falstan \
    --out scripts/data/broadcasts/massachusetts --site "Massachusetts, USA"
python3 tools/chesscom_events.py event 2025-massachusetts-open \
    --out scripts/data/broadcasts/massachusetts --site "Massachusetts, USA"

# 3. Build the queryable database (delete first: the importer appends)
MASTER_IMPORT_ARGS="$HOME/Documents/lichess_broadcasts/massachusetts/massachusetts.db \
  scripts/data/broadcasts/massachusetts/massachusetts.pgn" \
  scripts/ci.sh test tools/master_import_pgn.dart

# 4. Query it
#    chess-prep MCP: master_status / master_games / master_book with
#    db=/home/<you>/Documents/lichess_broadcasts/massachusetts/massachusetts.db
#    App: open massachusetts.pgn in PGN Viewer
```

The MCP reopens a cached handle when the database file is replaced, so a
rebuild is picked up without restarting the server (fixed alongside this work).

## The Massachusetts collection

`scripts/data/broadcasts/massachusetts/` holds everything found for the state
as of 9 September 2026: 94 games fetched from seven broadcasts, 75 unique
games after merging.

| Event | Where | Source | Games |
|---|---|---|---|
| Massachusetts Open 2025 | Westford | chess.com only | 23 |
| Masters vs Challengers Invitational 2025 | Burlington | both | 7 |
| MA State Open / Spiegel Cup Qualifier 2025 | Medfield | Lichess only | 17 (one blitz playoff) |
| Greater Boston Open 2025 | Westford | both | 12 |
| Massachusetts Open 2026 | Marlborough | Lichess only | 16 |

chess.com also lists a Massachusetts Girls Championship 2026 and a New
England Blitz 2025, both with empty game lists. Searches for Boylston,
Harvard, MIT, Worcester and the other New England states found nothing on
either site. To grow the collection, add a broadcaster account or tour id on
Lichess, or an event slug on chess.com, and re-run step 2.

The database file itself is generated and not committed; step 3 rebuilds it
in seconds.
