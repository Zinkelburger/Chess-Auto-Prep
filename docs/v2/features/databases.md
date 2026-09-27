# Databases

Status: draft from the old app
Old code (oracle only): `lib/features/databases/`, `lib/services/{master_games,eval,scid}/`,
`lib/widgets/{master_games_settings_panel,lichess_eval_*,eval_database_*}.dart`, `tools/*broadcast*`
Plan step: 11

## Purpose
Someone wants the app to answer from disk instead of the network — master practice for builds, stored
evaluations for reviews — or wants to know why 30 GB disappeared. They leave with a store downloaded,
repaired, repointed or removed, and one honest total for everything the app keeps.

## Screen
Reached from the mode menu, where `Databases` is its own group under the heading `Data`, and embedded
whole as Settings ▸ `Data & storage` (the settings gear on this mode lands there). No screenshot.

- **Total line** — `Chess Auto Prep is using 34.2 GB on this machine. Everything below is optional
  except your own games…`, or `Measuring what is on disk…`; then one **folder link** per directory.
- **Card form** — every store answers the same questions in the same place: title, what it is, what it
  buys, a badge (`Ready` / `Not set up` / `Unavailable` with a reason), a status (`N games`, the real count)
  plus a measured size, freshness, one primary button, an overflow menu, a `Settings` disclosure, and
  on the recommended store a `START HERE` badge.
- **Master games card** — `Titled-player games from The Week in Chess, kept locally and indexed by
  position.` Freshness `Checked 2 days ago · auto`. Menu: `Build classical index` / `Rebuild classical
  index`, `Stop the download`, `theweekinchess.com`. Disclosure: `Years of games` (stepper, 1 – all,
  default 5, `roughly 0.6 GB per year`), `Check for new issues at startup`, `Use master games when
  generating`, and the TWIC copyright note.
- **Your games card** — status only: `8,412 from Player Analysis (6 players), 2,190 in the games library
  (2 accounts), 340 in the tactics archive.` Empty: `Downloading your recent games from the Tactics or
  Player Analysis screen fills this.`
- **Lichess evaluations card** — `Positions already analysed by Stockfish on the Lichess analysis
  board, answered from your disk instead of over the network.` Body is the download card in one of
  three states (idle / transferring / complete); disclosure holds `Use saved Lichess evaluations`.
- **ChessDB dump card** — `The same job as the Lichess evaluations at about sixty times the size: tens
  of billions of scored positions, on an SSD you supply.` `Unavailable` off Linux (`…needs a native
  component that is only built for Linux…`). Disclosure: the data directory picker, `Use offline
  ChessDB`, `Read in larger blocks`, a `Download it yourself instead` rsync block.
- **Bughouse archive card** — the FICS book, freshness `2004–2025 · to 24 plies`; when missing, a
  copyable `tools/$ python3 -m bughouse_db fetch && python3 -m bughouse_db index` instead of a button,
  with `The archive is a 2.1 GB download from bughouse-db.org that is indexed into a 177 MB book.`
- **Caches and leftovers card** — the evaluation cache, then a row per leftover with its size and why it
  is safe to lose (`A copy kept by an upgrade. The current database replaced it.`, `Left behind by an
  interrupted write.`), or `No leftovers found.`; quarantined bytes read `1.9 GB is waiting in .trash.`
- **`Re-measure what is on disk`** — the app-bar overflow item (`Refresh storage usage` when embedded).

## Actions
**Download master games** — `Download master games`, or `Check for new issues` once it exists → probes
theweekinchess.com for the newest issue, then downloads and imports every missing weekly zip from the
start issue up (5 years ≈ 3 GB over hours; a top-up is one ~7,500-game issue in seconds), prefetching
issue N+1 while N imports, as a resumable Jobs-pane job: `Checking The Week in Chess…`, `TWIC 1659 —
downloading… (3/12)`, `TWIC 1659 — importing… (3/12)`, ending `Imported 12 issues, 84,213 games.` or
`Up to date (issue 1661).` → `Master games sync failed: TWIC 0: could not reach theweekinchess.com`.
**Stop the download** — `Stopping after the current issue…`, then `Paused after 3 of 12 issues (21,004
games added).` Finished issues stay; running again resumes at the gap.
**Automatic check** — with the database in place and the switch on, a launch probes TWIC at most once
per 20 hours, and only when the weekly cadence says a newer issue is due.
**Build classical index** — the explorer's classical-OTB counts and citations only exist on a database
imported after they were added → replays classical games in 5,000-game chunks off the UI thread:
`Indexing classical games…`, `Indexed {done} of {total} classical games`, `Classical index built`;
stopping leaves `Classical index stopped — run it again to finish`, failure `Classical index failed: …`.
It never runs while a sync does: both write the book.
**First-run prompt** — until master games exist or the banner is dismissed, the repertoire screen shows
`Local master games · Download TWIC (5 years, ~3 GB)` with `Download` / `Not now`, and `Downloading
master games — <status>` with `Jobs` / `Stop` while it runs.
**Wait for a download during a build** — a build wanting master replies parks on a running sync and
offers to start without them; the form's `Download master games first (about 3 GB, once)` starts one.
**Download the Lichess evaluations** — `Download evaluations…` → a dialog probes database.lichess.org
for the real size, asks `Where should it go?` and warns about the drive (`This is a hard disk. It will
work…`, `This is a network share…`), then two stages behind one bar: a resumable range download of
`lichess_db_eval.jsonl.zst` (~21.7 GB, `12.0 GB of 21.7 GB — 8.4 MB/s, 40 minutes left`) then an import
(`Read 120M positions of 394.7M. Nothing but the store is written to disk.`, `Sorting — 37 of 256
blocks. The download can be deleted once this finishes.`), ending `394.7M positions ready · 5.9 GB ·
built 2 September 2026` → `Not enough room on that drive: 4.1 GB free, 9.7 GB still to download.`,
`Cannot write to <dir>: <reason>`, `Could not read download details. Retry`, and offline `Could not
reach database.lichess.org, so these are the sizes as of…`.
**Pause, resume, free, delete** — `Pause` / `Resume` survive an app restart; `Free 21.7 GB` keeps the
store and drops the archive (`Removes the compressed download and keeps the store the app actually
reads.`); `Delete` removes both (`Getting it back means downloading 21.7 GB again.`); `Rebuild from a
newer file…` starts over against today's published file.
**Download the ChessDB dump** — `Download database…` → about 1.2 TB over four parallel range requests
from the Hugging Face mirror, per-file resume, pause across restarts and a free-space guard that parks
the job rather than filling the disk: `Downloading chess-20260702 — 41/120 files`, `Checking files…`,
`Download stopped`. `Check files` compares local lengths against the manifest (`3 files do not match
the manifest. Resuming re-fetches them.`) → `No snapshots are published right now.`, `Snapshot mirror
answered 503 for <url>`.
**Point at an existing dump** — `Browse for the data/ folder` (`The folder holding CURRENT and the .sst
files — …/chess-YYYYMMDD/data`), then `Use offline ChessDB`. The panel reads the drive and advises on
`Read in larger blocks`: `That folder is on an SSD — leave this off; it only adds work.` / `…on a
spinning disk — turn this on.` / `…on a network share. Random 4 kB reads over a network make the dump
slower than the engine it replaces.` **Use online ChessDB during builds** sits beside it: `Uses your
daily ChessDB quota.`
**Move leftovers to .trash** — `Move 1.9 GB to .trash` confirms, then *renames* each file into a
`.trash` beside it, freeing nothing; **Empty .trash** — `Empty .trash — frees 1.9 GB` (`Nothing in
there can be recovered afterwards.`) is what frees the space. Every card with a path can reveal it.
**Browse the master corpus** — no browse UI today: the TWIC browser dialog (filters on player, opponent,
event, ECO, minimum Elo, date, issue and classical/speed/online authority, newest or strongest first,
plus a "which of these walked into my books" scan capped at 20,000 games) was retired as unreachable.
What survives is the explorer's `TWIC · All games` / `TWIC · Classical OTB only` source, from the local
book with per-move counts, the citation and the latest game; without the index, `Classical-only counts
need a one-time index: Databases page → Master games → Build classical index.`
**Open a game from a database** — from the explorer's games list: the PGN is fetched (local database,
Lichess masters endpoint or game export), filed without duplicates into the shared
`explorer-games.pgn` collection, and opened at the ply that reaches the position. Reading and
annotating it is the shared workspace — see `workspace.md` and `pgn-viewer.md`.
**Export to Scid** — from the PGN Viewer's collection, not this mode: a folder, then `Name the
database` (`Scid stores a database as three files sharing one name: .si5, .sg5 and .sn5.`, renamed into
place together), a blocking `Wrote 400 of 1,204 games…`, then `Wrote openings.si5 — 1,204 games, 2 cut
short at an illegal move, 1 skipped` with `Show` → `Scid export failed: <error>`.
**Collect broadcast games** — outside the app: `python3 tools/lichess_broadcasts.py by falstan
--collection massachusetts` and `tools/chesscom_events.py event <slug>` write one normalised PGN per
broadcast, a manifest and a merged PGN under `Documents/lichess_broadcasts/<collection>/`; a game
broadcast on both sites is kept once, a finished broadcast is not refetched without `--refresh`.
`MASTER_IMPORT_ARGS="out.db in.pgn" scripts/ci.sh test tools/master_import_pgn.dart` turns that PGN
into the app's own master format — rerunning it on the same file adds the games again.

## Data
- **Master games** — `master_games.db` in the app support directory, SQLite, schema 4: `games` (headers
  plus zlib-compressed movetext against a per-database dictionary in `meta`, ~714 B a game), `book` (one
  aggregated row per position+move to ply 30 with counts, results, Elo, a strongest and a most recent
  sample game, and the same again for classical OTB only) and `twic_issues`. Five years ≈ 3 GB, and it
  is *derived*: a corrupt file is moved aside and re-synced rather than repaired. Read by generation
  (opponent replies, model games, `improves on … in <game>` notes), the coverage check, the explorer's
  TWIC source, and the chess-prep MCP tools read-only.
- **Your games** — `app_games.db` in support, filled by Player Analysis, the library and Tactics.
- **Lichess evaluations** — a directory the user chooses (routinely another drive): the downloaded
  `lichess_db_eval.jsonl.zst` plus a sorted flat store of 15-byte records keyed by the same position key
  the master book uses, sparse-indexed every 1024 keys — ~5.9 GB for 394.7M positions, one read a lookup.
- **ChessDB dump** — a `chess-YYYYMMDD/data` folder the user supplies, ~1.2 TB, read through a native
  component built only for Linux. **Bughouse archive** — built outside the app, read by the lab.
- **Eval lookups** ask, in order: transposition, the project cache, the ChessDB dump, a local ChessDB,
  the Lichess store, the chessdb.cn API, then Stockfish. Builds, reviews and checks all take this chain.
- **Caches and leftovers** — `eval_cache.db` in support, plus whatever is left directly in that
  directory that no store claims and matches a known shape (`.bak`, `.pre-v*`, `.db-journal`, `.tmp`).
  Measuring is read-only, counts `-wal`/`-shm` sidecars with their database, and never throws: a missing
  drive is a missing row. Removal renames into `<support>/.trash`, still counted until it is emptied.
- Settings kept: TWIC start issue, auto-sync, last check, use-in-generation, prompt dismissed; both eval
  store paths and their switches; the Lichess download directory.

## Keep / Change / Drop
Keep — Total line
Keep — Card form
Keep — Master games card
Keep — Your games card
Keep — Lichess evaluations card
Keep — ChessDB dump card
Keep — Bughouse archive card
Keep — Caches and leftovers card
Keep — `Re-measure what is on disk`
Keep — Download master games
Keep — Stop the download
Keep — Automatic check
Keep — Build classical index
Keep — First-run prompt
Keep — Wait for a download during a build
Keep — Download the Lichess evaluations
Keep — Pause, resume, free, delete
Keep — Download the ChessDB dump
Keep — Point at an existing dump
Keep — Use online ChessDB during builds
Keep — Move leftovers to .trash / Empty .trash
Keep — Browse the master corpus
Keep — Open a game from a database
Keep — Export to Scid
Keep — Collect broadcast games

Quirks to rule on: the classical index is a second manual pass over a database the app just downloaded,
and the explorer nags for it; the mode is duplicated as a settings section, so the controls exist twice;
the bughouse card prints a shell command at users with no checkout; leftover removal says "delete" but
only quarantines; the TWIC browse query has no UI on top of it; broadcast collections are two Python
scripts and a `flutter test` invocation the app never mentions.

## Questions for the owner
- Does the TWIC browser come back (filters, authority, "which of these tested my prep"), or is the
  explorer's position view the only way into two million local games?
- Should broadcast collections become an in-app download beside TWIC, or stay command-line tooling?
- Is the ChessDB dump worth keeping now that the Lichess store does the same job at 1/60 the size,
  on every platform?
- Should the classical index build itself during import instead of being a menu item?
- Does Databases stay a mode, or is it only the Settings ▸ Data & storage section?
