# Databases

The player opens Databases to get master games onto this machine, so that the
explorer's TWIC source and the Search tab's TWIC replies can answer offline, or
to look up one game in them. They leave with the database downloaded, topped
up or extended with a PGN file, a game open in the PGN Viewer, or disk space
freed.

Code: `lib/features/databases/` (`DatabaseLibrary`, `DatabasesScreen`,
`TwicDownload`, `showTwicDownload`), mode wiring `lib/app/database_view.dart`,
storage `lib/storage/master_games_import.dart` (the only writer),
`lib/storage/master_corpus.dart` (browse reads), `lib/storage/master_book.dart`
(explorer and Search reads), `lib/storage/disk_usage.dart` (Storage list), and
the store list in `nativeStoragePlaces` (`lib/app/environment.dart`).

## Screen

Reached from the mode menu (`Databases`, in the `Data & engines` group of
`lib/app/mode.dart`). The page has no list column.

- **Heading** — `Databases`, then `Download TWIC…` (filled; only where the
  environment has a master games path), `Import PGN…`, `Storage · 4.1 GB`
  (`Storage · measuring…` before the first measurement) and a refresh button
  (`Refresh database counts and storage`).
- **Summary line** — `Master games · 1,944,320 games · 2.0 GB · Sep 2020 – Sep
  2026 · TWIC issues 1340–1612 · 2 PGN files imported`, or `Master games ·
  empty`; under it a sentence (`databaseAbout`) saying the games come from The
  Week in Chess and imported PGN files, and that the explorer's TWIC source
  reads them.
- **Filters** — `Player`, `Event`, `ECO`, `From date (YYYY.MM.DD)`, `Min Elo`
  (a `NumberField`, 0–3500), a `Strongest first` chip and `Clear filters`.
  Changes apply 300 ms after the last edit.
- **Status line** — a progress bar while reading or importing, then the
  problem (error colour), the last message (`Imported 120 games · 3 skipped.`,
  `This file was already imported.`, `Deleted Master games · freed 2.0 GB.`)
  or `Importing games…` / `Reading games…`.
- **Game list** — one row per game: `White — Black`, then `date · event · ECO
  · whiteElo / blackElo` (`—` for an unknown rating), the result at the right
  (`Opening…` while that game is being kept). Empty: `Download TWIC or import a
  PGN to browse games.` (`Import a PGN to add your own games here.` without
  TWIC) or `No games match these filters.`
- **Pager** — `Page N`, `Previous`, `Next`; 100 games a page.
- **Actions menu** — `Refresh databases` and `Import PGN…` in a `Databases`
  group.

## Actions

**Download TWIC** — `Download TWIC…` here, or `Download TWIC database` in the
explorer when the TWIC source has no database → dialog `Download TWIC
database` with `Weeks` (1–520, default 52) → reads theweekinchess.com/twic for
the newest issue and imports issues newest first, skipping ones already in the
file, so the same action starts the database and brings it up to date. Status
reads `Finding the latest TWIC issue…`, `Downloading TWIC 1612 · 3 of 52`,
`Importing TWIC 1612 · 3 of 52`, ending `TWIC database ready.` (plus `Skipped
N unsupported or unfinished games.`). `Stop` ends after the current issue
(`Stopped. Download again to resume.`). The dialog cannot be dismissed while
it runs. Failure: `Could not finish the TWIC download. <reason>` with
`Completed issues are saved. Try again to resume.` and a `Try again` button; a
full disk reads `The disk is full.` The explorer refreshes when the dialog
closes.

**Import PGN** — `Import PGN…` → file picker → the file's games are added to
the same database → `Imported N games · M skipped.`, or `This file was already
imported.` (by SHA-256 of the bytes, so a renamed copy is also caught), or
`Import failed: <detail>`, which stays until a retry or refresh. The source
PGN is never changed.

**Browse and open a game** — filters and pager → a row click copies the game
to `pgn_collections/database games/<name>.pgn` (an existing copy is reused)
and opens it in the PGN Viewer. Leaving the mode before the copy is ready
drops the open. `Could not keep the game: <detail>` on a write failure.

**Storage** — the heading button opens a dialog `Storage · <total>` with one
row per store that has bytes, its measured size and its path as a tooltip.
Only derived data has a delete button: `Master games` and leftover copies of
derived databases (`Leftover master_games.db.pre-v3.bak`, `…unreadable-<stamp>`).
Delete asks `Delete <name>?` (`Frees 2.0 GB. Download TWIC and import the PGN
files again to get the games back; the PGN files themselves are not touched.`)
and really deletes the file and its sidecars; there is no `.trash`. A delete
is refused while a download or import is writing. Failure: `Could not delete
<name>: <reason>`.

**One write at a time** — a download, an import and a delete never overlap.
Starting one while another runs says `Wait for the import to finish.`, `Wait
for the TWIC download to finish.` or `Wait for the deletion to finish.`
instead of failing on SQLite's lock.

## Data

- **`<support>/master_games.db`** — the one master database (owner,
  2026-09-28). SQLite, `user_version` 4, write-ahead-log mode so readers never
  wait on an import. Tables: `games` (headers plus the SAN main line without
  the result, zlib-compressed with a dictionary kept in `meta`), `book` (one
  row per position and move over the first 30 plies, `bookPlies`, with
  results, ratings, strongest and newest game, and the same counts for
  classical over-the-board games), `twic_issues`, `meta`, and `imports` (PGN
  fingerprints; the only table the app adds to an existing file). A file of any
  other version is refused, never migrated.
- **Import rules** — each TWIC issue and each PGN file commits in one
  transaction with its games and book counts, so a killed run leaves whole
  issues only and a retry imports nothing twice. Only finished games from the
  initial position that read cleanly are kept; the rest are counted as
  skipped.
- **Unreadable file** — a file SQLite reports damaged or not a database is
  renamed with its sidecars to `master_games.db.unreadable-<stamp>` (never
  reusing an earlier name) and a new one started; the download says so. A
  download that has to do this restarts its whole window into the new file,
  at most once per run; a second set-aside stops with a problem, keeping both
  copies.
- **Readers** — the explorer's TWIC source and Search's TWIC replies
  (`SqliteMasterBook`), this page (`SqliteMasterCorpus`), and the chess-prep
  MCP tools, which is why the schema stays fixed.
- **Kept game copies** — `Documents/pgn_collections/database games/`.
- **Storage list** — `nativeStoragePlaces` names every store: master games,
  engine evaluations (`eval_cache.db`), search finds, chapter audits, your
  games (`app_games.db`), kept versions, the bughouse engine, and the
  repertoire, study, PGN collection, games library, tactics and engine
  tournament folders. Databases count their `-wal`/`-shm`/`-journal`
  sidecars; folders are measured recursively without following links;
  measuring runs off the UI isolate and never throws.
- **Closing the app** — the download is a pending write: the window waits for
  the current issue to commit.
- **Outside the app** — `tools/lichess_broadcasts.py` and
  `tools/chesscom_events.py` collect broadcast PGNs, and
  `tools/master_import_pgn.dart` (run through `scripts/ci.sh test`) builds a
  database in this format from PGN files with the same importer.

## Owner decisions

- One master database file; no second book or migration (owner, 2026-09-28:
  "have one thing that makes sense, don't keep 2 files").
- Deferred, possibly not worth building (owner, 2026-09-28): Lichess
  evaluation and ChessDB dump stores, broadcast collections in the app, Scid
  export, automatic TWIC checks, a first-run download prompt, waiting on a
  download during a build, and rebuilding an old database's classical index.
