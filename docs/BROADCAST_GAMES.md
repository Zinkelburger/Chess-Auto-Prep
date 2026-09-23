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
- Neither the website search (`/broadcast/search`) nor the monthly calendar
  (`/broadcast/calendar/YYYY/M`) lists community broadcasts either; the
  calendar is the official ones only. The monthly downloads on
  `database.lichess.org` (about 1.2M broadcast games since 2023) are official
  only too: July 2025 has the World Open but not the community-broadcast
  US Open run in the same month.
- Operators worth following besides `falstan`: `jsr12345` runs the DGT
  boards for Mid-Atlantic events (World Open, Washington International,
  Cherry Blossom, Colonial and Skyline Opens — these official) and for US
  Chess nationals, the US Open, Chess for Cure and George Washington Open
  (community). The owner of any broadcast is `ownerId` in its page's
  embedded JSON.
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
| `tools/lichess_broadcast_archive.py` | `fetch`, `build`, `status`. Every official Lichess broadcast from the monthly downloads, minus variants, engine games and anything TWIC or another collection already holds; builds the collection `lichess-official`. Needs `zstd` |
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

The merged PGN writes each player one way: per order-free name key, the
comma form some source used (`Wu, Felix`), else the name turned
surname-first (`Emma Linyue Zhang` → `Zhang, Emma Linyue`). Lichess
broadcasters often write `First Last` where chess.com and TWIC write
`Last, First`, which listed the same player twice. Real respellings
(`Shmelov, Denys` / `Shmeliov, Denis`) are different keys and stay as
written; the player lookup joins them.

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

`player_lookup` and `people_populate` search every collection database
(`Documents/lichess_broadcasts/<name>/<name>.db`; override the root with
`CHESS_PREP_BROADCASTS_DIR`) alongside TWIC, and report the games per source
under `otb.sources` — see [OPPONENT_PREP.md](OPPONENT_PREP.md#filling-the-players-directory).

## The official archive and US community broadcasts

`Documents/lichess_broadcasts/lichess-official/` holds every official Lichess
broadcast since January 2020 that is not already in TWIC or another
collection:

```
python3 tools/lichess_broadcast_archive.py fetch     # cached in ~/.cache/chess-prep/lichess-broadcast-db/
python3 tools/lichess_broadcast_archive.py build     # months/<YYYY-MM>.pgn, manifest.json, lichess-official.db
```

The first build (23 September 2026, months 2020-01 to 2026-08) read
1,235,275 games and kept 596,200: 530,299 were already in TWIC, a curated
collection or an earlier month, 88,128 had no moves, 13,629 were Chess960
and 7,019 were engine games. The 80 downloads are 693 MB; the kept month
files 605 MB.

The downloads carry no `Date` tag, so the game's `UTCDate` stands in, and a
Lichess URL in `Site` becomes `?`. A game counts as already held when its
full move list and result match one in TWIC, a curated collection or an
earlier month and White shares a name part with it (`Zhou Jianchao`,
`Zhou, Jianchao`), so a lookup never counts a game twice. Build the curated
collections first: `build` reads whatever `*/<name>.db` exist beside it.
Re-run both commands monthly; `build` refilters every cached month from
scratch.

A compressed copy is committed so the archive survives losing both the
Documents copy and the download cache:

```
python3 tools/lichess_broadcast_archive.py export    # after build: xz months into scripts/data/broadcasts/lichess-official/
python3 tools/lichess_broadcast_archive.py restore   # unpack that copy and rebuild lichess-official.db
```

The copy is one `months/<YYYY-MM>.pgn.xz` per month (about 100 MB in all,
no file near GitHub's limits), the manifest and a README carrying the
CC BY-SA 4.0 attribution the Lichess broadcast database requires. `export`
recompresses only months whose PGN changed; `restore` needs only the
standard library.

Community broadcasts are not in the downloads. `us-community` collects the
operators found so far:

```
python3 tools/lichess_broadcasts.py by jsr12345 --community-only --collection us-community
MASTER_IMPORT_ARGS="$HOME/Documents/lichess_broadcasts/us-community/us-community.db \
  $HOME/Documents/lichess_broadcasts/us-community/us-community.pgn" \
  scripts/ci.sh test tools/master_import_pgn.dart
```

`--community-only` skips an owner's official broadcasts, which the archive
already has. As of 23 September 2026 it holds `jsr12345`'s 28 community
broadcasts, 2,400 unique games: the US Open 2025 (main event and
invitationals), the National High School, Middle School, Elementary and K-12
Grade championships 2024-2026, SuperNationals VIII, the Cherry Blossom
Classic 2023, Maryland Action/Blitz 2024, the George Washington Open 2026 and
more. A few are operator tests (`test`, `CB Test Tournament1`, `MCA Tnmt
Test`); they relay real boards and are kept. The 126th U.S. Open (August
2026) broadcast has no games. The committed copy is `scripts/data/broadcasts/us-community/`.

## The Massachusetts collection

`scripts/data/broadcasts/massachusetts/` holds everything found for the state
as of 23 September 2026: 94 games fetched from eight broadcasts, 75 unique
games after merging. The eighth, `falstan`'s 2026 Masters vs Challengers
Invitational (tour `2QchhP2O`, 11 October 2026), has no games yet; re-run
step 2 after it.

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
either site; a second pass on 23 September 2026 (MetroWest, Wachusett,
Marlborough, Bay State, Greater Boston, Northeast Open, Eastern and
Continental Class, Spiegel) found nothing new either. To grow the collection, add a broadcaster account or tour id on
Lichess, or an event slug on chess.com, and re-run step 2.

The database file itself is generated and not committed; step 3 rebuilds it
in seconds.
