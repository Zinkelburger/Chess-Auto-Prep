# Architecture

The contracts every change to the app follows. `lib/main.dart` boots the one
app; production code lives under `lib/`, tests under `test/`.
`scripts/check_architecture.py` enforces the mechanical parts (import table, size caps,
write ownership, theme literals); `scripts/ci.sh lint` runs it. What each mode
does is in [the mode specs](features/README.md); where the code is, in
[the component map](COMPONENT_MAP.md); stores and recovery files, in
[DATA_INTEGRITY.md](DATA_INTEGRITY.md).

## Product shape

One **workspace** — a board, a move tree, an engine pane, an explorer and
tool panes — over one **document** (a PGN with a store revision). As on
Lichess, analysis, study and practice share one board, tree and engine. A
mode decides what fills the side column and what drives the workspace; it
never has its own board or move tree.

| Mode (`app/mode.dart`) | Shape |
|---|---|
| Repertoire builder | Library list, chapter outline and the Replies/Expectimax/Audit tabs over the workspace |
| Opening books | Named sets of repertoires and chapters; one book is in use |
| PGN Viewer | Workspace plus a game list (collections, filters) |
| Repertoire trainer | A training session driving the workspace as a quiz |
| Study | Workspace plus chapters, Lichess import/export and quiz markers |
| Tactics, My games | A puzzle session or your games against your book, on the shared board |
| Player analysis, Players & prep | Opponents, prep studies, tournaments; games open in the workspace |
| Databases | Master games (TWIC, imports) and storage use |
| Engine tournament, Bughouse | Their own screens on the same engine supervisor |

## Layout and imports

```text
lib/main.dart       entry point; installs logging, optional agent driver, self-tests
lib/
  app/              composition, window, mode menu, cross-mode requests, exit, updates
  ui/               theme tokens and shared controls
  diagnostics/      the log facade
  chess/            pure Dart: PGN, positions, generation, training, tournaments
  storage/          files, SQLite, settings, credentials, revisions, recovery, backups
  engines/          supervised UCI/Hivemind/Maia processes and finite jobs
  net/              Lichess, chess.com, ChessDB, GitHub and other clients; login sockets
  workspace/        board, move tree, document session, engine/explorer and tool panes
  features/<mode>/  one folder per mode: owners and panels
  debug/            opt-in agent driver and packaged-app self-tests (unchecked)
test/               mirrors lib/; test/support/ holds fixtures and scripted ports
```

| From | May import (besides itself) |
|---|---|
| `chess/` | Pub packages only; no Flutter, no `dart:io`, no `diagnostics/` |
| `diagnostics/` | Nothing in `lib/`; no Flutter |
| `storage/` | `chess/`, `diagnostics/` |
| `engines/` | `chess/`, `diagnostics/`; no Flutter, so engines run in plain Dart tests |
| `net/` | `chess/`, `diagnostics/` |
| `ui/` | `diagnostics/`; Flutter, no feature, storage or engine code |
| `workspace/` | `chess/`, `storage/`, `engines/`, `net/`, `ui/`, `diagnostics/` |
| `features/<mode>/` | Everything `workspace/` may, plus `workspace/`; never another mode |
| `app/` | Everything |

`dart:io` is allowed only in `storage/`, `engines/`, `net/` (the Lichess login
listens on a loopback port) and `app/`. Files are written only in `storage/`;
the Stockfish and Hivemind installers in `engines/` are the named exceptions.
A widget file outside `app/` never imports `dart:io` or `net/`. From
`storage/` and `engines/` a widget takes value types (`ChapterRef`, `Score`,
`EngineLine`), never an adapter or a process.

## Composition

- `app/environment.dart` (`AppEnvironment`) is every way out of the app —
  files, dialogs, sites, engines, Maia, the clock, timings; `.native()` builds
  the real ones, from `native_engines.dart` (engine and Maia launches) and
  `native_desktop.dart` (browser, file manager, window, updates). A new way
  out of the app is a field here.
- `app/app_parts.dart` (`AppParts`) builds the app over any environment in
  order and disposes it in reverse, calling `app/mode_wiring.dart` and
  `app/workspace_wiring.dart`. Window tests build a scripted environment and
  the same `AppParts` (`test/support/window_fixture.dart`), so they test the
  real wiring. A new owner goes in the wiring it belongs to.
- A mode is a `ModeView` (`app/mode_view.dart`): it owns its card tabs and
  answers for its list, Actions menu, tab bodies and flags. `Shell` asks the
  mode on screen instead of switching on which mode it is; a new mode is a
  subclass in its own file (`document_views.dart` holds the builder,
  trainer, viewer and Study, which share a base) and one arm of
  `modeViews`. `WorkspaceView` takes one
  `WorkspaceHooks` value (`workspace/workspace_hooks.dart`) for what the
  window adds.
- `WorkspaceRequests` (`app/workspace_requests.dart`) owns the mode, the
  status line and every cross-mode request that puts a document on the board
  or takes it off (a list click, Open/Import/Paste, an explorer game, Close
  file), each answering a sealed `RequestResult`. Questions to the user come
  through interfaces (`ExitGuard`'s `DraftQuestion`, `WindowInput`), so flows
  are tested without widgets. Request tickets cancel superseded opens.
- `AppExit` (`app/app.dart`) closes once however often it is asked: it
  disables input, pauses producers, flushes the document and waits for
  `PendingWrites`, then stops the engines, then closes the log.

## Workspace owners

The workspace is several small owners. `Workspace` (`workspace/workspace.dart`)
only holds them for what lays panels out — the shell, `WorkspaceView`, the
Actions menu; a panel takes the one or two owners it reads.

| Owner | Holds | Never holds |
|---|---|---|
| `DocumentSession` | The parsed move tree as an immutable value, `shownTo` while a puzzle hides the rest, the store revision, dirty state, undo receipts | Engine output, explorer data, panel state |
| `DocumentCursor` (`session.cursor`) | The move the cursor is on, the position there, and a comment's line on the board in its place | The document; it reads the session's tree and `shownTo` |
| `DocumentSaver` | The debounced save of the session's draft and its outcome | The tree or cursor |
| `EngineAnalysis` | The engine job for the cursor position and its latest snapshot | Anything about the document |
| `Explorer` | The explorer query for the cursor position and the session's answers (`ExplorerAnswers` via `ExplorerDatabases`) | The document; a listed game kept as a file (`GameFetcher`) |
| `Replies` / `GapHunt` | The Maia table for the cursor / the walk over the open chapter and the gap `Next gap` marked; both ask one `ReplyModel` cache | A copy of the tree or cursor |
| `ActionLayout` | Which tool tabs sit in which pane and the split shares; `LayoutMemory` persists deliberate choices | Data |
| `FileFilter` | The game filter's rules for the open file and which games pass; cleared when another file opens | The games |
| `FileTree` / `MyGamesTree` | The explorer's `This file` and `My games` indexes (`IndexBuild`), kept with the game list they number | The document, the cursor |
| `ParsedFiles` (in `DocumentSession`) | Parses of recently read files keyed by path and identical text, bounded by characters; large files open from headers (`readChapterShowing`) and read other games' moves on an isolate | Revisions, drafts |
| A panel's owner (`FillGaps`, `Lesson`, `PuzzleTrainer`, `ChapterAudit`, …) | That tool's state, keyed to a document revision | A second copy of the tree or cursor |

An owner notifies only for what its listeners show. `DocumentSession`
notifies its own listeners when the document changes and `session.cursor`
(a `ValueListenable<NodePath>`) when the cursor moves; `anyChange` is both, for views of the position. A
derived owner such as `ChapterOutline` notifies when its output changes, not
whenever its inputs do. Lists highlight the current row through
`ui/selection.dart` (a cursor move redraws two rows) and build rows lazily.

Split an owner when it has two jobs, which its fields and listeners show —
never to get under a line count. A split whose second half only answers the
first's calls is a forwarding layer and is merged back.

Committed changes have their own owner, separate from the editor:
`DocumentRepository` (storage) publishes typed create/save/move/delete events
only after success; `RepertoireCatalog` coalesces them into a committed
listing that books, training and repertoire indexes consume. A change during
a read invalidates that read. Explicit refresh handles changes made outside
this process. `DocumentTabs` (`app/document_tabs.dart`) keeps file tabs,
cursors, viewer drafts with their save revisions, and temporary analysis
boards; an analysis board never writes its source. Each tab belongs to one
mode: `WorkspaceRequests.switchTo` brings up that mode's own latest tab, while
a handoff that opens a document for a mode changes mode without that restore.

`PendingWrites` (`storage/pending_writes.dart`) belongs to the application.
Accepted writes of user data (documents, ratings, books, settings, usernames)
stay tracked after their screen is disposed; closing waits for them and asks
only about one that failed. Derived writes (search trees, finds, caches) are
waited for but never asked about.

## Code rules

1. **One owner per mutable fact.** A `ChangeNotifier`/`ValueNotifier` built in
   `app/` wiring and passed down by constructor. No singletons, service
   locators, Provider, Riverpod, Bloc or GetIt.
2. **Pass owners, not bags of callbacks.** A widget receives the owner it uses,
   or an immutable value plus the commands it needs.
3. **No forwarding layers** and no facades over owners widgets could use
   directly. No abstract type with one implementation, no options nobody sets,
   nothing built for later.
4. **Widgets do no I/O.** Owners call `storage/`, `engines/` or `net/`; owners
   import `package:flutter/foundation.dart` at most.
5. **Interfaces only at real boundaries:** filesystem, SQLite, engine
   processes, network, clock. Algorithms are concrete pure functions.
6. **Split by job, not size.** Caps (enforced): 1,000 lines per file, 80 per
   function, nesting depth 3. A test's `main()` and `group(...)` bodies are
   lists of cases and exempt; each `test(...)` body counts. `part` is allowed
   only for a file of complete collaborator classes, never to spread one class.
   No `dynamic`; `late` only as `late final`.
7. **Typed results and failures.** Expected outcomes are sealed results with
   exhaustive switches (`SaveResult`: `Saved`, `Conflict`, …), not exceptions.
   Widgets turn them into plain English; there is no ARB or localization step.
8. **Report a failure twice:** `log.w`/`log.e` at the catch site with the
   action and error, and the typed failure on screen. Never a bare
   `catch (_) {}`. Logs go to the console and `<support>/logs/app.log`
   (`storage/log_file.dart`); `app/error_log.dart` turns Flutter's own errors
   into entries naming the blamed widget. Never log secrets, tokens or PGN text.
9. **Async work has an owner and a stale check.** Capture inputs before an
   `await`; a result whose document, position or request changed is discarded.
   Each action says whether a repeat is rejected, merged or queued. Accepted
   durable operations follow their commit/recovery protocol even if the view
   that started them is gone. Every subscription, timer and process has a named
   owner and an explicit end. A `State` that listens to `widget.<owner>` uses
   `ListeningState` (`ui/listening_state.dart`) or implements
   `didUpdateWidget` (enforced).
10. **Values, not mutation.** Domain types are immutable; ids and units are
    types where confusion would be a bug (`Fen`, `Revision`, `Eval`,
    `OperationId`). `package:path` as `p` for paths.
11. **One place per fact.** FEN normalisation, movetext writing, chapter naming
    exist once; reuse `chess/pgn/`, `chess/fen.dart`, `ui/move_notation.dart`.
12. **Explain non-obvious algorithms beside the code** — representation,
    units, score perspective, one example. Long explanations go in
    [ALGORITHM.md](ALGORITHM.md).
13. **Tests describe behaviour** a user could see or a contract another module
    relies on; never private state or call order. Owners have tests without
    widgets; widget tests use scripted owners/ports from `test/support/`, never
    a real file outside a disposable profile or a real engine.

Settled choices, not reopened without the owner: constructors for dependency
passing; plain immutable values and sealed classes without code generation;
the existing SQLite files and schemas; `http` with one client per service;
a persistent shell with plain `Navigator`; dark theme only (owner,
2026-09-22). New pub dependencies need the owner; `chessground` and
`multi_split_view` were allowed on 2026-09-21. The PGN reader/writer stays
hand-written because no package keeps untouched games byte for byte.

### Style reference

| File | Shows |
|---|---|
| `lib/chess/pgn/game_tree.dart` | Immutable values with doc comments that say why |
| `lib/chess/pgn/pgn_reader.dart` | A pure function over a package; typed issues instead of exceptions |
| `lib/chess/pgn/tree_merge.dart` | One algorithm, one paragraph explaining it |
| `lib/workspace/document_session.dart`, `document_cursor.dart` | An owner; document and cursor notified apart, each by its own type |
| `lib/features/library/library.dart` | Sealed states and results; a stale check after `await` |
| `lib/workspace/move_tree_view.dart` | A widget built from an owner; a cursor move redraws two moves |
| `lib/app/workspace_requests.dart` | Cross-mode requests: sealed results, questions behind an interface |
| `lib/storage/chapter_files.dart`, `chapter_directory.dart` | An interface at a real boundary with sealed results, and its one adapter in its own file |
| `lib/engines/uci_engine.dart` | A protocol over a pipe: serialised searches, so stale output cannot land |
| `lib/workspace/engine_analysis.dart` | An owner over a background job with a 200 ms snapshot buffer |
| `test/workspace/engine_analysis_test.dart` | Fake time, a scripted double, assertions on the owner only |

### Reviewer checklist

1. Any file, function or nesting over the caps — or a split made only to get
   under them?
2. Any owner holding another owner's data? Any mode importing another mode?
3. Any `await` without a stale check? Any subscription, timer or process
   without an end?
4. Any exception for an expected outcome? Any swallowed `catch`?
5. Any pass-through class, unused option, single-implementation interface or
   code for later?
6. Any rule implemented twice?
7. Any test reading private state or asserting call order?
8. Any comment explaining *how*? Any algorithm without a *why*?
9. Could a widget file be rewritten from its owner's public API and the theme
   alone? If not, state or layout leaked.

## Data correctness

Know which bytes are the system of record, rebuild derived views from them,
make retries idempotent, and give a document change and its reference changes
one recoverable boundary — SQLite transactions where data shares a database,
guarded file replacement for formats that must stay files.

### Rules

1. **Never lock the app.** A problem affects at most the one item involved —
   one document, save or job — never every open, every save or startup.
   Preferences and derived data never block anything.
2. **Never delete user data.** PGNs, training progress, puzzles and saved
   matches are kept. A record the app cannot read, finish or replay is moved
   whole into `<support>/recovery-quarantine/<time>/`, logged, and the app
   carries on without it.
3. **Recover automatically.** Unfinished operations are finished on the first
   access after a crash; leftover staging files are cleaned or adopted. The
   user never repairs a file by hand.
4. **Derived data may be discarded.** Generation trees, finds, download
   caches, indexes and staging files are rebuilt, refetched or recomputed; a
   failed write of them is a log line.
5. **Saves are Obsidian-style.** Debounced, one write per burst, byte-heavy
   work off the UI isolate, no read-back verification, no gzip.
6. **At most one short message** where the user must act; the log holds the
   detail.

### Authority

| Area | Authoritative (kept; quarantined if unreadable) | Derived (may be discarded) |
|---|---|---|
| Workspace, viewer, library, study | PGN bytes, kept versions, required references | Parsed tree, filter, cursor, selection |
| Books | Book definitions and membership (`books.json`) | Expanded chapter set, counts |
| Repertoire training | Schedule, streak, history and attempt files | Due queues, scope lists, lesson board |
| Tactics | Puzzle PGN, review fields, analyzed-game markers | Puzzle queue, mining |
| My games | Account usernames | Downloaded games cache, opening index, book comparison |
| Generation and checks | Draft chapters written | Search trees, finds, gaps, coverage, evaluations |
| Bughouse | Nothing: the table is a session scratchpad | The table, live search |
| Settings and accounts | Nothing irreplaceable: defaults are always a valid start | Form state, connection status |

### What the user can rely on

| Operation | Guarantee |
|---|---|
| An edit on the active board | Reads the current draft; save state is shown separately |
| A successful durable command | Its required writes are complete; a dependent command reads the committed result |
| Training after an accepted rating | Later reads see the rating; a failed rating write is retried in order and follows a rename, move or delete made while it waits |
| Rename, move or committed undo | Document and references are one operation; a crash between them is finished on the next access |
| Catalog, gaps, explorer, book check | Refresh asynchronously; a late answer never replaces a newer one |
| Engine or network response | Published only into the request it answers |
| Reopen after a crash | Unfinished operations are finished or quarantined before the affected file is read |
| External edit or sync conflict | Revalidated; the draft is kept as a conflict, never overwritten |

An in-process notification is a wake-up hint, not proof of a commit; a new
consumer rebuilds from source. Results of a command are *committed*,
*rejected* (nothing changed) or *unknown* (retry with the same `OperationId`,
never a new one that would append twice).

### Save and recovery

1. **Edit.** The draft changes at once and a one-second clock starts
   (`DocumentSaver`); more edits restart it. Opening another document, a
   rename, undo, the window losing focus or closing ends the wait. One write is
   in flight at a time; edits during it collapse into one pending save.
2. **Write.** Check the revision on disk against the one loaded (a changed
   file is a conflict), copy the version being replaced into Support, write a
   staged copy beside the file, flush, rename over it, flush the directory.
   Nothing is read back.
3. **Several files.** A command that changes more than one file (a rename with
   its book and training references, a move, a delete, a two-file line
   transfer) first writes a record under Support naming each participant's
   before and after state, applies the steps, then removes the record.
   `OperationJournal` (`storage/operation_journal.dart`) carries the records
   for `FileRelocations` (`relocation-writes/`) and `CompoundWrites`
   (`compound-writes/`). Training answers are not journaled: each training
   file is replaced atomically.
4. **Crash.** `storage/recovery_gate.dart` finishes records on the first
   access, when an unseen record appears, and when an unfinished one is due
   again (each of the next three accesses, then 5 s doubling to 5 min). An
   access touching a file a record changes tries that record first. What is
   owed lives in memory per profile (`RecoveryLedger`); the folders stay the
   truth. Per participant: still at *before* → apply; already at *after* →
   accept; anything else (another program's edit) → put back what the record
   already rewrote, keep its bytes as a version, quarantine the record, log
   why, continue. A participant unreadable for now leaves the record pending.
   A record owed for five minutes stops guarding when a write meets it: one not
   applied whole is undone and set aside; one that landed lets plain saves
   pass (`<id>.following`). A record whose quarantine move fails is marked
   `<id>.aside` and only moved later. Training rows and book selectors that
   follow a record never stop it: changed since → replanned from what they hold
   now; unreadable → left as they are.
5. **Fail.** A failed write keeps the draft on screen with one short message;
   the next edit or save tries again. Closing asks only when a write the user
   made is still unsaved.

### Identity and undo

Paths, course sections and `[LineID]` are document identity. A content hash
identifies a version, not a document. Rename or move produces an explicit
old-to-new mapping that books and training follow; copy makes a new document;
delete moves the file into the repertoire's quarantine and restore brings it
and its references back. Draft undo changes only the draft; committed undo is
a new guarded operation, refused when a participant changed since. Undo
history is built from store receipts (before-content and committed revision),
never from controller memory; a failed or uncertain undo never pops history.

### Derived views and background work

An index or analysis result names its inputs (document revisions, membership,
corpus, settings) and publishes only while they still match. Invalidate by
affected input: a sibling deletion recomputes gaps, a membership change
recomputes the book scope, a cursor move does neither. A failed rebuild keeps
the last view; an unavailable source never becomes an empty success.

Every job captures its input when it starts. Generation shows a run done at
once and saves its tree and finds behind it. Mining writes a game's puzzles and
its analyzed marker in one replacement. My games reviews the games it
downloaded even when the cache could not save them.

## Data safety

[DATA_INTEGRITY.md](DATA_INTEGRITY.md) lists every store, its format and its
recovery files.

### Stores and formats

| Data | Where | Must preserve |
|---|---|---|
| Repertoires and chapters | Documents `repertoires/`: chapter PGNs, or one course PGN whose games name their chapter | Comments, variations, NAGs, unknown headers, `[%eval]`, `[%pv]`, `[%clk]`, `[%cal]`/`[%csl]` |
| Studies | Multi-chapter PGNs in Documents `studies/` | Lichess export tags, root comments, per-chapter orientation, quiz markers |
| Training | Review, progress and history CSVs and attempt JSONL, keyed by file path and line id | Schedules across chapter rename, move, split and delete, and edits that would change a derived line id |
| Settings and accounts | Support `settings.json`; SharedPreferences account and token keys | Unknown keys and values |
| Recovery | Journals, `recovery-quarantine/`, backups, `.cap-reference-history/` in Documents | Each keeps its own purpose; none is the version history |

### Course files

A repertoire is a folder; a chapter is a `.pgn` in it (any extension case,
except `_raw_games` sidecars), or the games of one course file that carry the
same `[ChapterName]` (the Lichess study export's tag). `chapterSections`
(`chess/pgn/chapter_sections.dart`) gives each named chapter `(path, section)`
identity, even as the last chapter left; untagged games form the unnamed
section. Listings walk nested folders without following symlinks or entering
hidden recovery or staging folders.

- **One write path.** A course chapter opens as a `SectionView`; `spliced`
  puts the edit back and the store checks the whole file. Untouched games keep
  their places; a new game goes at the end carrying the chapter name.
- **Chapters are tags.** Moving lines between chapters of one file
  (`linesNamed`), renaming (`sectionRenamed`) and deleting (`sectionRemoved`)
  each change one file; deleting is an undoable edit.
- **Line ids are written down.** A game without a `[LineID]` trains under an
  id derived from its main line and its index among the file's games
  (`trainedIdsOf`). Any edit that would change that id first writes
  `[LineID]` with the current id (`withIdsPinned`). Progress therefore stays
  keyed by path and id, and chapter changes inside a file never touch the
  training files.
- **Import writes one file.** A multi-chapter course or study becomes
  `<repertoire>.pgn` with `[ChapterName]` and a distinct `[LineID]` on every
  line (`courseText`). Imports are staged in a `.import-` folder and renamed
  into place; stale staging folders are removed by the first listing after
  recovery has finished every recorded operation.
- A PGN directly in `repertoires/` lists as a repertoire of its own.

### Backups

The user never asks for a backup and never names one.

- **Every replaced byte is kept.** The store records the validated
  before-content of every save, append, import, rename or delete; a write whose
  backup could not be recorded does not proceed. Appends to the downloaded
  games cache replace nothing and keep no version.
- **In Support**, under `backups/<document id>/`: plain copies named by commit
  time and content hash, with an index. Never written into Documents (it may be
  synced).
- **Identity, not path.** Versions follow the document through rename and
  move; a history that cannot move at once is noted under `backup-moves/` and
  moved by the next recovery pass.
- Unchanged content records nothing. Saves do not prune: the builder's
  `Version history` previews each version (checksum-verified), restores one as
  a separate repertoire, and offers explicit cleanup keeping the newest 100
  versions and everything from the last 90 days.
- SQLite databases are never backed up by copying db/WAL/SHM files; use
  SQLite's backup API.

### PGN document store

Every PGN write goes through `PgnDocumentStore` (`storage/pgn_document_store.dart`).

| Intent | Contract |
|---|---|
| Open | Revision and content. Absent, unreadable and malformed are distinct; a failed read is never an empty document |
| Create or copy | Exclusive create; a name collision replaces nothing |
| Save | Requires the loaded revision and an `EditScope`; a changed file is a conflict. No overwrite flag |
| Append, import, edit | A locked transformation of current content, returning before-content and the new revision |
| Undo | Restores the receipt's before-content only while storage still holds the revision it expects |
| Rename, move, delete | Same store and lock, collision checks, training references updated in the same operation; delete is recoverable |

Only `Saved` clears the dirty state. A conflict keeps the draft and offers
keep editing, save a copy or reload; dismissing a dialog never grants
overwrite.

A save declares its `EditScope`: the games of the on-disk version it rewrites
and how many it appends, or `WholeDocument` (restore, import, or a caller that
cannot say — logged as a warning). The scope comes from the edit, never from
diffing old and new text. Before writing, both texts are split into games with
the chapter reader's splitter: a game outside the scope that would change or
disappear, or a changed `//` heading, refuses the save and names the game.

A revision is the SHA-256 of the exact bytes on disk. Reading, hashing,
encoding, decoding large files and the game-by-game comparison run off the UI
isolate (`packages/document_file_io`); parsing large chapters does too.

**Reading and writing a game.** `chess/pgn/` owns the PGN grammar; dartchess
is used for legality and positions, never text. Reading a game yields its
header lines with their endings, moves, termination marker, leading whitespace
and located issues. **Any issue makes the game not whole:** it keeps its own
bytes, is left out of `Chapter.writableTree`, and an edit that would rewrite
it is refused with a typed reason. `rewritten` (`chess/pgn/rewrite_gate.dart`)
is the only way an existing game becomes new text: it writes the game, reads
it back and compares everything, answering `LineRewritten` or `LineRefused`;
an edit commits nothing until every game it touches comes back.
`writeMoveText` states the canonical form: SAN as spelled, every comment,
move and variation order, NAG numbers and marker kept; redundant move numbers,
several comments on one move, `;` comments, symbolic annotations and `e.p.`
normalised. Writing twice gives the same bytes.

A comment lives where it lived: an edit rewrites the games holding that note,
or the first game playing the move when none does; a game holding a different
note keeps it. Arrows and circles follow the same rule.

### Filesystem notes

- Locks (`storage/file_lock.dart`) coordinate app writers only; revision
  checks catch what they can of external editors and backups cover the rest.
- Treat Documents as possibly synced: a delayed or failed read is an error,
  not empty content; never merge or delete conflict copies automatically.
- Live SQLite files stay in local Support storage.
- Durability goal: survive app or worker termination. POSIX: temp, fsync,
  rename, fsync the directory (`F_FULLFSYNC` on macOS). Windows:
  `ReplaceFileW`, sharing violations retried with capped backoff and a fresh
  revision check; long/UNC paths normalised, ACLs and streams preserved. A
  directory flush the filesystem does not support (EINVAL, ENOTSUP, ENOSYS) is
  skipped with one warning per folder; compound and relocation writes still
  fail on other flush errors.
- Names have a character cap and a UTF-8 byte budget that leaves room for
  staging and recovery names. External files are copied into Documents.
- `.github/workflows/desktop-contracts.yml` runs native document, locking,
  login, exit and desktop integration checks on Windows, macOS and Linux as a
  release gate. `--self-test-desktop` in a release executable checks a
  disposable profile (long Unicode paths, save on exit, reopen, rename,
  recoverable delete, bundled Stockfish, Maia, login sockets);
  `tools/test_desktop_bundle.py` runs it. These are not power-loss
  certification.

## Settings and credentials

- One writer, `SettingsStore` (`storage/settings_store.dart`), for
  `settings.json` in Support, saved whole on every change. Top-level keys this
  build does not know are written back unchanged.
- Preferences never block startup: an unreadable file is moved into
  `recovery-quarantine/`, logged, and the app starts on defaults. A symlinked
  `settings.json` is followed.
- A failed save keeps the choice on screen with one line saying so; the next
  change writes again. Jobs capture their configuration when they start.
- Lichess and account credentials live in SharedPreferences
  (`storage/lichess_token.dart`, `storage/my_accounts.dart`); unreadable or
  mistyped keys read as signed out and are removed. Secrets never appear in
  settings, logs or exports.

## Network and offline

The app is usable with no connection; what was downloaded stays on screen.

- **One client per service** in `net/`, injected at its owner, with its own
  retry/backoff. Tests use fake clients; `flutter test` blocks real sockets.
- **A failed fetch never takes data away.** The owner keeps what it had,
  marks it stale with its age, and names the service it could not reach. Only
  a request with nothing stored behind it shows an error instead of content.
- **A forced refresh** prefers the network but never discards the local copy.
- **Two services fail independently.**
- **What a panel displays is persisted**, so a second launch offline shows
  what the first fetched. The exception is the Lichess explorer (the database
  is the service): it is online-only and says so with a retry.
- **A stale answer is labelled**: one muted line naming the service and age.

Each new client is tested with a fetch that throws, one that returns nothing,
a 429 and a 500 — against a store with content and one without — plus a failed
forced refresh and one of two services failing.
`python3 scripts/app_driver.py start --offline` runs the app with loopback
only for an offline screenshot.

## Engines and background work

- `EngineSupervisor` (`engines/engine_supervisor.dart`) owns every engine
  process from spawn to confirmed exit, drains output into bounded buffers and
  defines cancel, stop, timeout and kill. Cancelled is reported only after
  resources are released. Never kill processes by name.
- Engines die with the app: they are joined by pipes, so when the app dies the
  engine reads end of input and quits (`stockfish_exit_test.dart`). Tested on
  Linux.
- Continuous analysis publishes the latest snapshot of all MultiPV lines at
  most every 200 ms; `bestmove`, completion and errors arrive immediately. No
  trailing debounce. Finite searches have deadlines.
- Engine jobs publish a named kind through `EngineJobs`; the top bar's running
  task returns to the owning tool without starting a second job.
- Opening and closing a mode repeatedly returns process, port, subscription
  and queue counts to baseline.
- Large documents are shown from immutable projections tied to a revision;
  never deep-copy or compare a whole move tree on each cursor move.
- Never compute expectimax or similar search values while the player browses:
  show stored values and offer a run on request.

## Interface

[DESIGN.md](../DESIGN.md) is the visual and copy specification;
`lib/ui/theme.dart` owns every visual value. A widget file can be deleted and
rewritten from its owner's public API and the theme alone:

- Owners expose values, typed states and commands; they know nothing of
  layout, text or colour.
- A widget reads one or two owners and keeps only view state (hover, scroll,
  an open menu). State two widgets need lives in an owner.
- Only `Shell` and `WorkspaceView` know which panel sits where.
- Literal `Color(0x…)`, `fontSize:`, `fontFamily:` and one-line icon sizes
  appear only under `ui/` (enforced); a new value is a named token in
  `ui/theme.dart`.
- Context stays visible: file, side, orientation, selected line, filters and
  save state (unsaved, saving, saved, failed, conflicted). Real progress,
  never a fake ETA. Usable at 150% and 200% text scale.

## Known hard problems

Regression contracts and open risks, not a feature list:

- **Recoverable references.** Relocation, compound writes and line transfers
  (`storage/file_relocation.dart`, `storage/compound_write.dart`,
  `features/library/line_transfers.dart`) must keep late-rating, reused-path,
  crash/retry and guarded-undo tests green. A trained line folded into another
  file is refused; moved as its own line it keeps its progress. Raw `LineID`
  tags do not identify progress; transfers use the source training id.
- **Linked studies.** Players & prep links studies by path; a linked study's
  rename and delete are refused (`features/study/study_file_changes.dart`). Any new
  command over linked studies must complete the reference change recoverably or
  refuse before mutating.
- **Stale results.** Replacement opens, paste, close and cancellation must
  reject stale filter, index, engine and generation results; autosave and
  publication stay tied to their captured input.
- **Platforms.** Linux process-kill tests do not prove Windows/macOS engine
  cleanup after the app is killed, or power-loss durability anywhere.
- **Size pressure.** No file sits at the 1,000-line cap.
  `workspace/document_session.dart` has room since navigation moved to
  `DocumentCursor`; what is left (opening, edits, held edits, the analysis
  board, undo) writes the same shown document and file, so a further split
  would scatter one owner's state. Extract a collaborator only when it owns
  a complete responsibility; do not loosen caps or fragment files to pass
  them. Retained memory across repeated large-file navigation and searches
  is unmeasured.

## References

- [Designing Data-Intensive Applications, ch. 12](https://www.oreilly.com/library/view/designing-data-intensive-applications/9781491903063/ch12.html)
  for the system-of-record / derived-view split.
- [SQLite: how to corrupt a database](https://www.sqlite.org/howtocorrupt.html)
  and [WAL](https://www.sqlite.org/wal.html).
- [ReplaceFileW](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-replacefilew).
- macOS runs Stockfish from `Contents/Helpers`, signed at build time with
  sandbox inheritance; extracting the signed upstream binary at runtime is
  rejected by the sandbox
  ([Apple's helper requirements](https://developer.apple.com/library/archive/qa/qa1773/_index.html)).
