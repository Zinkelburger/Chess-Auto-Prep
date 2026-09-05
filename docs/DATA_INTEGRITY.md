# Durable data and recovery

The app has several sources of truth. Back up both the application Documents
and Support directories; `app_games.db` contains tactics source games that may
have no remaining PGN-file copy. Stop the app before a plain filesystem backup
of SQLite, or use SQLite's backup API so committed WAL data is included.

## Shared file operations

`atomic_file.dart` owns text updates, expected-content checks, recovery and
replacement. Read/modify/write operations use `updateTextFileAtomically` (or
`StorageService.updateFile`). Reads recover interrupted replacements while
holding the same directory lock as writers. A missing file returns null; a
failed read throws and must never be interpreted as an empty document.

`file_operation_lock.dart` uses a SQLite transaction as a mutex. Separate
connections contend across Dart isolates and OS processes; the old POSIX
record lock did not exclude other isolates in the same process. Domain
transactions take a separate lock namespace before acquiring individual file
locks. Do not recursively acquire the same directory lock.

These locks coordinate app writers. They cannot make an arbitrary external
editor honor the lock. Expected-content checks reject already-observed external
changes; backups remain important for edits by other programs and hardware loss.

## Tactics

`Documents/tactics_sets/Default.pgn` stores puzzle positions, solutions,
provenance and review statistics. Its leading PGN semicolon comment,
`ChessAutoPrep-Analyzed-v1`, contains the completed-game IDs as base64url JSON.
Each completed game's puzzles and completion marker are committed together,
including completed games with no puzzles. Callbacks announce a committed game;
they do not buffer its only copy. `analyzed_games.txt` is a legacy import source
and is no longer written by this pipeline after the first checkpoint.

A decode error blocks replacement and source-game pruning. The original remains
on disk. Legacy CSV migration refuses records it cannot preserve and retains
original input. An unsuccessful save propagates to the importer, leaves the
completion marker unset and exposes a visible save error.

Source games live in the `tactics` collection of `Support/app_games.db`.
Pruning first reads references from every tactics set and study. A failed read
aborts pruning. Removed SQL records are retained in `game_trash`, with their
collection, key, verbatim PGN and deletion timestamp. No automatic purge is
applied to this recovery archive.

## Player Analysis

Each identity owns `Documents/analysis_games/player-<sha256>/`. The hash covers
platform and case-normalized username; filename punctuation cannot collapse two
names or collide with another player's cache suffix.

`current.json` is the single publication point. It selects a generation:

```
player-<id>/
  current.json
  versions/<timestamp>-<digest>/
    games.pgn
    metadata.json
    derived/<corpus-digest>/
      white_analysis.json
      black_analysis.json
      engine_evals.json
      holes_white.json
      ...
```

PGN and generation metadata are staged before replacing the manifest. Older
generations are retained. Legacy flat files are discovered by their stored
identity fields, copied into the new layout, and retained. Deletion publishes a
tombstone; legacy files cannot silently resurrect the player on the next launch.

SQLite's `analysis:<player-id>` collection is a derived position index. Opening
a player compares corpus fingerprints and rebuilds a mismatched index. The PGN
is held stable during rebuilding. A failed index update is reported as an
unavailable search index and is retried on opening; it does not undo the saved
PGN. Derived caches use the corpus fingerprint, and long analysis jobs must
verify that their input still matches before publishing current results.

To recover a deleted or replaced player manually, locate a retained generation's
`games.pgn` and import it under a new player name in the app. Its corresponding
`metadata.json` records the identity and download settings. Keep the old
manifest and generations until the recovered import has been checked.

## Studies, PGN editing and the games library

Study saves compare against the loaded content. A save failure keeps the open
document dirty and stops a requested file switch. When possible, a separate
`Documents/recovery/study-*.pgn` preserves the edited document as well. These
copies can be opened as PGNs or imported as a new study.

Viewer metadata and comments patch only the changed games into the latest
file. Unrelated games and document text remain intact. Ambiguous or changed
source games cause a conflict; edited snapshots are retained under
`Documents/recovery/pgn-*.pgn` when a recovery write is possible. Background
library annotations compare against the PGN captured before analysis began.

The games-library download limit applies to reproducible games. Games carrying
comments, variations, NAGs or custom metadata survive the limit, even if they
are older than the requested download window.

## Training progress

The three Documents CSVs (`repertoire_reviews.csv`,
`repertoire_move_progress.csv`, `repertoire_review_history.csv`) quote commas,
quotes and multiline fields. Before rewriting a legacy CSV, the service retains
its original bytes as `<name>.pre-csv-v2.bak`. Legacy unquoted path commas are
reconstructed using the schema's fixed columns; malformed records fail rather
than being replaced with default progress values.

History appends run under one read/modify/write lock. Progress writes merge
only changed rows against their loaded values and preserve other repertoires.
Conflicting edits to the same row are rejected. Training operations capture
the source repertoire before awaiting persistence, so navigation cannot redirect
an outgoing session's progress or history to another file.

## Verification

`test/services/storage/data_integrity_regression_test.dart` exercises real temp
files, independent isolate writers, injected disk failures, interrupted player
publication, index rebuilding, legacy migration, stale document edits and
training concurrency. Related storage, tactics, game-library and controller
tests cover the existing call-site contracts. Run all checks through
`scripts/ci.sh`; platform-specific filesystem behavior also requires the desktop
CI jobs on their respective operating systems.

## Audit repair checklist

The original audit IDs map to these implemented protections:

- **F01 — isolate locks:** the shared directory mutex excludes writers in
  separate isolates and processes, with crash release and bounded waiting.
- **F02 — stale PGN writes:** viewer edits patch their original game into the
  latest document; external tactics and background library annotation writes
  reject changed source content.
- **F03 — swallowed tactics failures:** puzzle and archive write errors reach
  the importer and user-visible error state; failed games remain incomplete.
- **F04 — partial decoding:** unreadable tactics records block overwriting and
  pruning; CSV migration rejects lossy conversion and retains its input.
- **F05 — player filename collisions:** hashed platform/name identities replace
  sanitized flat filenames; migration checks metadata identity fields.
- **F06 — game collisions:** only actual platform game URLs are treated as
  identities; other games use their headers and mainline moves. Existing SQL
  rows are rekeyed transactionally without discarding colliding records.
- **F07 — CSV paths:** proper quoting supports commas, quotes and newlines;
  legacy path commas are reconstructed with a retained pre-migration copy.
- **F08 — study navigation:** failed saves keep the current study dirty and
  prevent switching away; recovery snapshots retain edits when possible.
- **F09 — destructive pruning:** reference reads must all succeed; removed
  source games are archived in the same SQL transaction as their removal.
- **F10 — annotated library eviction:** retention limits preserve games with
  comments, variations, annotations or custom metadata.
- **F11 — racing recovery:** readers and replacement recovery take the same
  lock as writers and cannot recover another live transaction underneath it.
- **F12 — progress/history races:** history appends atomically; progress merges
  changed rows against loaded baselines and rejects same-row conflicts.
- **F13 — stale analysis caches:** caches are tied to corpus fingerprints, and
  long-running analyses verify their starting corpus before publishing.
- **F14 — buffered completion:** a game's puzzles and completion marker share
  one durable PGN commit before progress callbacks announce completion.
- **F15 — partial player publication:** one manifest publishes the staged PGN
  and metadata; SQL is a fingerprinted, repairable index with visible failures.
