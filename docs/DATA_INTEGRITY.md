# Stored data and recovery files

What is stored where, in which format, and which recovery files exist. The
contracts — authority, save and recovery, kept versions, the PGN document
store — are in [Data correctness](ARCHITECTURE.md#data-correctness) and
[Data safety](ARCHITECTURE.md#data-safety). Every write target ends as either
the verified old version or the verified new version: never missing, partial,
silently overwritten, or outside the storage root it belongs to.

## The two roots

| OS | Documents | Support |
|---|---|---|
| Linux | `xdg-user-dir DOCUMENTS` | `$XDG_DATA_HOME/com.example.chess_auto_prep` (default `~/.local/share/…`) |
| Windows | the Documents known folder | `%APPDATA%\com.example\Chess Auto Prep` |
| macOS | the sandbox container's `Documents` | the container's `Library/Application Support/com.example.chessAutoPrep` |

`lib/main.dart` gets both from `path_provider`; `AppEnvironment.native`
(`lib/app/environment.dart`) places every store under them. On Linux, if
`xdg-user-dir DOCUMENTS` prints nothing or your home folder, run
`xdg-user-dirs-update`; without `xdg-user-dir` the app does not start. An
existing `~/.local/share/chess_auto_prep` is used when the app-id folder does
not exist. Stores sit directly in Documents, which may be synced. Updates
download to `updates/` in the OS cache folder; lock files sit in the system
temporary folder ([Writes and locks](#writes-and-locks)).

## Stores

Per [the authority table](ARCHITECTURE.md#authority), *kept* is never deleted
and is quarantined if unreadable; *derived* may be discarded and rebuilt.

| Store | Path | Format | Authority |
|---|---|---|---|
| Repertoires | Documents `repertoires/<repertoire>/` | Chapter PGNs, or one course PGN with `[ChapterName]` games ([course files](ARCHITECTURE.md#course-files)) | Kept |
| Studies | Documents `studies/` | Multi-chapter PGNs | Kept |
| PGN collections | Documents `pgn_collections/` | Imported PGN copies | Kept |
| Tactics | Documents `tactics_sets/Default.pgn` | Puzzle PGN with an analysed-games line | Kept |
| Training | Documents root | Three CSVs and one JSONL ([below](#training-files)) | Kept |
| Player directory | Documents `opponents/` | JSON ([below](#player-directory)) | Kept |
| Engine tournaments | Documents `engine_tournaments/` | Per run `tournament.json` + `games.pgn`; root `engines.json` | Kept |
| Downloaded games | Documents `games_library/<site>_<user>.pgn` | PGN + `.fetched` note (ms since epoch) | Derived |
| Player archive copies | Documents `games_library/player_archives/player-archive-<hash>.pgn` | PGN, append-only | Kept |
| Search trees | `.cap-generation/<chapter file>/v2-<run id>/tree.json` beside the chapter | JSON; newest 16 runs kept | Derived |
| Books | Support `books.json` | JSON, written whole | Kept |
| Settings | Support `settings.json` | JSON; unknown keys kept ([settings](ARCHITECTURE.md#settings-and-credentials)) | Defaults always valid |
| Unsaved viewer edits | Support `viewer-drafts/<sha256 of path>.json` | JSON | Kept |
| Master games | Support `master_games.db` | SQLite, written by `master_games_import.dart`, also read by the Python MCP tools | Derived (re-importable) |
| Engine evaluations | Support `eval_cache.db` | SQLite `evals` + `maia_cache` | Derived |
| Search finds | Support `finds.db` | SQLite | Derived |
| Chapter audits | Support `audit.db` | SQLite | Derived |
| Dismissed findings | Support `audit_dismissed.db` | SQLite, keyed by kind, position and move | Kept |
| Player reports | Support `player-reports/<key>.json` | Fingerprint-keyed JSON | Derived |
| Your games | Support `app_games.db` | SQLite; read only ([below](#read-only-stores)) | Kept |
| Kept versions | Support `backups/` | [Recovery files](#recovery-files) | Kept |
| Engines | Support: Stockfish binary, `bughouse/` (Hivemind) | Installed from the bundle | Derived |
| Logs | Support `logs/app.log` | Text, one line per entry | Derived |

The databases the app writes use WAL. A `master_games.db` SQLite reports as
damaged is renamed with its sidecars to `.unreadable-<stamp>` and restarted.
`app.log` is appended across runs; over 2 MiB at start it becomes `app.log.1`
(one generation), and a session stops logging after 2 MiB.

SharedPreferences keys: `lichess_username`, `chesscom_username`,
`lichess_last_fetch_ms`, `chesscom_last_fetch_ms` (`storage/my_accounts.dart`);
`lichess_access_token`, `lichess_refresh_token`, `lichess_auth_username`,
`lichess_token_expiry`, `lichess_is_pat` (`storage/lichess_token.dart`);
`pgn_viewer_recent_files`; `pgn_viewer.session:<path>` (viewer places).

## Formats

### Training files

In the Documents root (`storage/training_rows.dart`): `repertoire_reviews.csv`
(schedule; 11 columns written, 8 and 10 read), `repertoire_move_progress.csv`
(streaks), `repertoire_review_history.csv` (ratings) and
`repertoire_move_attempts.jsonl` (one answer per line). Every row is keyed by
`repertoire_id` (the chapter's path) and `line_id`. CSVs need their header
row and quote commas, quotes and newlines. Each file is replaced atomically,
touching only the rows a write names; a row changed since it was read refuses
the write. The first write to a CSV keeps its prior bytes as
`<name>.pre-csv-v2.bak`, a name kept for compatibility with existing profiles.

### Tactics set

The first line of `tactics_sets/Default.pgn` is
`; ChessAutoPrep-Analyzed-v1: ` followed by the analysed game ids as a sorted
JSON list, UTF-8, base64url. A game's puzzles and its id are written in one
replacement. A line that cannot be decoded stops mining into the set rather
than mining every game again.

### Player directory

`opponents/people.json` (format `chess-auto-prep/people@1`; a bare JSON list
is read as its people) and `opponents/tournaments/<id>.json`
(`chess-auto-prep/tournament@1`), written by `storage/player_files.dart` under
the folder lock. A row changed since it was read is refused; unknown fields
survive. A row that cannot be read (not an object, no ID, a name that is not
text, or a second row under one ID) is left out with one warning and a log line,
and every save writes it back where it was. A `people.json` that cannot be read
at all shows no players and refuses saves, so nothing writes over it; the
groups still read.

### Read-only stores

The app opens `app_games.db` read-only and reads only `games` (schema
version 2); its `tactics` collection holds source games that may have no other
copy. Saved players are discovered from Documents
`analysis_games/player-<id>/current.json` (version 1) and the
`versions/<revision>/games.pgn` it names. Ids in Documents
`analyzed_games.txt` count as analysed beside the tactics line.

## Recovery files

How they are written and finished is [Save and recovery](ARCHITECTURE.md#save-and-recovery)
and [Backups](ARCHITECTURE.md#backups).

| Name | Where | Holds |
|---|---|---|
| `backups/<document id>/` | Support | Kept versions (`<time>-<hash8>.pgn`, older `.pgn.gz`) and `index.json` |
| `compound-writes/<id>.json` | Support | Multi-file edits in flight (`CompoundWrites`) |
| `relocation-writes/<id>.json` | Support | Renames, moves and deletes in flight (`FileRelocations`) |
| `<id>.following`, `<id>.aside` | Beside a record | It landed and lets plain saves pass; it is set aside, to be moved |
| `backup-moves/` | Support | Kept-version histories still to follow a rename |
| `recovery-quarantine/<time>/` | Support | Records, settings and drafts the app could not read or finish; never deleted |
| `.cap-pgn-history/` | Inside the repertoire | Deleted chapters (`<operation>-<name>`), restored from Deleted chapters |
| `.cap-reference-history/<operation>/` | Documents | Training files as they were before a relocation rewrote them |
| `.<name>.v2-tmp` | Beside the target | A staged write; replaced or removed by the next write there |
| `.import-*` | `repertoires/` | Import staging; removed by the next listing |
| `.trash/` | `engine_tournaments/` | Deleted tournaments |
| `.v2-pending.json` | A tournament's folder | A results save in flight |

Recovery drains, but never adds to, Support `unfinished-moves/` (each note
finished or set aside) and `training-writes/` (finished receipts removed,
unfinished ones set aside). Support `repertoire-mutations/` and
`repertoires/.cap-repertoire-publications` are left untouched; a folder move
may not relocate them.

## Writes and locks

`storage/atomic_write.dart` stages a complete copy beside the target, flushes
it, renames it into place (`ReplaceFileW` on Windows, keeping metadata) and
flushes the directory; `createFileExclusively` lets the kernel decide a race
for a new name. Callers decide whether bytes may be published; document bytes
come only through `PgnFileStore`. Platform durability:
[Filesystem notes](ARCHITECTURE.md#filesystem-notes).

`withDirectoryLock` (`storage/file_lock.dart`) serialises writers to one
directory across isolates and processes. The mutex is a SQLite write
transaction on an empty database,
`<system temp>/chess-auto-prep-file-locks/<FNV-1a of the resolved directory path>.sqlite3`:
busy timeout 0, `BEGIN IMMEDIATE` retried every 10 ms for two minutes, rolled
back however the action ends; the OS drops it when a process dies. Never nest
one directory's lock: the inner call fails after the deadline. Every
document access takes the profile-wide lock keyed on
`repertoires/.cap-directory-domain` (`storage/recovery_gate.dart`). Locks
coordinate the app's own writers; external editors are caught by revision
checks.

## Backing up

Back up both Documents and Support: Support holds `books.json`, kept
versions, recovery records and `app_games.db`, whose tactics source games may
have no other copy. Stop the app before copying `.db` files, or use SQLite's
backup API (`sqlite3 <file> ".backup <copy>"`) so committed WAL data is
included; never copy a database without its `-wal` file while the app runs.
