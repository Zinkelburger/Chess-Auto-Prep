# Architecture renewal: a fresh app in `lib/v2/`

**Status: Not started (plan revised 2026-09-19).** This is the third version of
the plan. The first (Sept 16, commit `6d980630`) migrated the app in place; its
work log is [the evidence record](ARCHITECTURE_RENEWAL_EVIDENCE.md) and its
final text is at `449d5428`. The second (Sept 18, `58a8dfd8`) moved to a fresh
app. This version keeps that decision and fixes how the work is cut. Read this
file, not the earlier ones.

## Decision

Write the application again from an empty directory, `lib/v2/`, with its own
entry point, `lib/main_v2.dart`. The old app keeps working and shipping until
the new one replaces it; then the old code is deleted and `lib/v2/` moves up
to `lib/`.

The rewrite keeps what is not the problem:

- **The same Flutter project:** `pubspec.yaml`, platform runners, bundled
  engines and assets, `packages/`, packaging and release tooling.
- **The same user data:** every file and database keeps its format and
  location. Both apps can run on one profile at the same time.
- **Every mode.** Nothing is dropped: Tactics, Player analysis, Repertoire
  builder, Repertoire trainer, PGN Viewer, Study, Engine tournament, Bughouse
  lab, Databases, Repertoires, Players & prep.

Everything else is written again, including the algorithms. **No file is
copied from the old app.** The old code is reference material: read it to
learn what a feature does, then write it to [the definition of clean
code](#what-clean-code-means-here). For algorithms the spec is
[ALGORITHM.md](ALGORITHM.md), [DATA_INTEGRITY.md](DATA_INTEGRITY.md) and, for
Scid, `tools/scid_reference`; the old app stays installed as an oracle, so a
rewritten algorithm is checked by running both on the same input and comparing
where the result is deterministic. Copying would carry the debt in (a 71-field
config synced by hand, a third algorithm bolted on as an `extension`, five
copies of pool warm-up); the comparison test is the better safety net.

The product shape also changes: five modes that are each "a PGN with a board"
become one workspace (see [Product shape](#product-shape)).

## What the old app gets wrong

Measured on 2026-09-19; details in
[the Aug 21 audit](maintenance/2026-08-21-architecture-audit.md).

| Problem | Evidence |
|---|---|
| Too big for what it is | 227k lines in `lib/`, 165k lines of tests, 11 modes, 20 feature folders plus 108k lines of legacy `core/`, `services/`, `screens/`, `widgets/` |
| Five modes are one thing | Repertoires, Builder, Trainer, Study and PGN Viewer each have their own screen (1,875 / 1,478 / 973 / 1,101 lines), controller, move tree and save path for the same board-plus-moves task |
| God classes hidden by `part` | `_PgnViewerScreenState` 2,296 effective lines, `_RepertoireScreenState` 2,440, `GenerationSessionController` 1,414, `TreeBuildConfig` 71 fields synced by hand at 8 sites |
| Global singletons | `StorageFactory.instance`, `EvalCache.instance`, `ProbabilityService.instance`, `MaiaFactory.instance`, `EngineSettings.instance`, `AuditPersistence.instance` |
| Duplicated core code | Movetext builders, FEN parsers, PGN tokenizers and header parsers each existed 3–14 times; five hand-rolled staleness tokens |
| Two of everything mid-migration | `features/repertoire` and `features/repertoires`; `generate` and `generation`; `AppColors` and `design_system`; `core/` and `chess_core/` |
| Ad-hoc write safety | Whole-file writes without an expected revision and undo without one caused the lost-edit incidents |
| Ceremony agents must feed | A 3,060-line component map, three JSON debt ledgers, boundary scripts, an 8-minute suite |

## What the two earlier attempts taught

1. **Old and new code in one tree never converge.** Every step added adapters,
   bridges and ledgers; `lib/` grew from 219k to 237k lines before shrinking to
   227k with 112k legacy lines left and none of 20 feature folders finished.
2. **A plan that asks for evidence gets evidence.** 27 acceptance IDs and a
   4,620-line record consumed most of the effort. Now the only record is one
   status cell per step and the commit history.
3. **"Evaluate X" is a day lost.** Riverpod, Drift, Freezed, go_router, Dio,
   Sentry, Alchemist and Patrol were each proposed for trial; Riverpod was
   adopted, then retired. Every choice is made below; none is re-opened.
4. **Unbounded goals burn budgets.** "Finish the plan" ran for a week. A
   session gets one row of the step table and a hard stop.
5. **Scaffolding before features is where agents disappear.** A step that
   builds theme tokens, settings stores, lint rules and test harnesses has no
   screenshot to fail. Each step ends with something the product owner can see.

## Rules for the old app during the rewrite

- The old app is **frozen**. Fix data loss, crashes and release blockers only.
  No refactors or migrations; each one makes the rewrite chase a moving target.
- `v2` never imports or copies old `lib/` code. Read it, then write the `v2`
  version. What must stay compatible is data and protocols, not code: file
  formats, the SQLite lock the two apps share, and settings keys.
- A data-safety bug found while rewriting is fixed in `v2` and ported to the
  old app only when the old app can lose user data because of it.
- The old ledgers (`scripts/architecture_feature_debt.json`,
  `scripts/architecture_retirements.json`, `scripts/legacy_theme_consumers.json`)
  stay untouched until switch-over deletes them with the code they describe.

## Product shape

One **workspace**: a board, a move tree, an engine pane, an explorer pane and
one side panel, over one **document** (a PGN file with a revision from the
store). This is the Lichess model, where analysis, study and practice share
one board, tree and engine. Modes are what fills the side panel and what drives
the workspace:

| Mode today | In `v2` |
|---|---|
| PGN Viewer | Workspace + a game list (collections, filters) |
| Repertoire builder | Workspace + chapter outline + tool panels: generation, holes/tricks, coverage, audit, planner |
| Study | Workspace + the same chapter outline + Lichess import/export and quiz markers |
| Repertoire trainer | A training session driving the workspace in quiz mode |
| Tactics | A puzzle session driving the workspace, plus a puzzle list |
| Repertoires | The library list that opens a document in the workspace |
| Player analysis, Players & prep | Opponent search, prep sheets, tournaments, people directory; games open in the workspace |
| Databases | Master games, TWIC, broadcasts, Scid export; games open in the workspace |
| Engine tournament, Bughouse lab | Their own screens, as today, on the same engine supervisor |

The workspace, move tree, engine pane and explorer are written once. A panel
receives the one or two owners it uses (below) and adds its own state; it never
has its own board or move tree.

Size target for the whole of `v2/`: under 60k lines of `lib/`, against 227k
today. The gate that matters is per step ([below](#a-step-is-done-when)); the
total is the sanity check.

### Workspace owners

The workspace is several small owners, not one. A panel takes the one or two
it uses; nothing takes "the workspace".

| Owner | Holds | Never holds |
|---|---|---|
| `DocumentSession` | The parsed move tree as an immutable value, the cursor, the store revision, dirty state, undo receipts | Engine output, explorer data, panel state |
| `EngineAnalysis` | The running engine job for the cursor position and its latest snapshot | Anything about the document |
| `Explorer` | The cached explorer query for the cursor position | Anything about the document |
| `WorkspaceLayout` | Which panel is open and the split sizes | Data |
| A panel's owner (`GenerationRun`, `TrainingSession`, `HoleHunt`, …) | That tool's state, keyed to a document revision | A second copy of the tree or cursor |

If an owner grows past about 300 lines or ten fields, it has two jobs; split
it by job. The old `PgnViewerController` (1,341 lines) is what this table
prevents.

## Layout

```text
lib/main_v2.dart          entry point: flutter run -t lib/main_v2.dart
lib/v2/
  app/                    composition, window, mode menu, cross-mode requests
  ui/                     theme tokens and shared controls
  diagnostics/            the log facade every other folder reports through
  chess/                  pure Dart: PGN, positions, moves, evaluation, generation
  storage/                PgnDocumentStore, SQLite stores, settings, credentials
  engines/                UCI supervision, pools, analysis streams
  net/                    Lichess, chess.com, US Chess and other clients
  workspace/              board, move tree, engine pane, explorer, side-panel host
  features/<mode>/        one folder per mode: panels, sessions, lists
test/v2/                  mirrors lib/v2/
```

Allowed imports:

| From | May import |
|---|---|
| `chess/` | Pub packages without Flutter or `dart:io` |
| `storage/`, `engines/`, `net/` | `chess/`, pub packages, `packages/` |
| `ui/` | Flutter only; no feature, storage or engine code |
| `diagnostics/` | Pure Dart, so `engines/` can report from outside Flutter; nothing else in `v2` |
| `workspace/` | `chess/`, `storage/`, `engines/`, `net/`, `ui/` |
| `features/<mode>/` | `workspace/` and everything it may import; never another mode |
| `app/` | Everything in `v2` |

Every folder except `chess/`, which stays pure, may also import
`diagnostics/`. Nothing in `v2` imports the old `lib/` folders;
`scripts/check_v2.py` enforces this table. The one exception is `lib/main_v2.dart` importing
`lib/debug/agent_driver.dart`, the headless-test hook shared with the old app.
Cross-mode jumps (open this line in the builder, train this chapter) are typed
requests handled by `app/`.

## Code rules

1. **One owner per piece of mutable state.** A `ChangeNotifier` or
   `ValueNotifier` constructed in `app/` and passed down by constructor or
   Provider. No singletons, service locators or second dependency container.
2. **Pass owners, not bags of callbacks.** A widget receives the owner it
   uses, or an immutable value plus the commands it needs.
3. **No forwarding layers.** A class that only passes calls to another class
   does not exist. No facades over owners the widgets could use directly.
4. **Widgets do no I/O.** They call their owner. Owners call `storage/`,
   `engines/` or `net/`.
5. **Interfaces only at real boundaries:** filesystem, SQLite, engine
   processes, network, clock. Internal algorithms are concrete functions.
6. **Split a class by job, not by size.** Never use `part` to spread one class
   over files.
7. **Typed results and failures.** Owners expose typed status (idle, running,
   failed, done) and typed errors; widgets turn them into text. Widget copy is
   plain English strings. There is no ARB or `gen_l10n` in `v2`; the
   localization section of [the UI guide](agents/ui.md) does not apply here.
8. **A failure is reported twice: to the user and to the log.** At the catch
   site, `log.w`/`log.e` with the action that failed and the error; at the
   widget, the typed failure as plain English. Warnings and errors go to the
   console in every build mode and to `<support>/logs/app.log`, so a user's
   report of "an error appeared" can be answered without reproducing it. Never
   log secrets, tokens or file contents — the path and the error are enough.
   The facade lives in `diagnostics/` and its file sink in `storage/`
   (`v2` may not reuse the old app's); `main_v2` installs the sink before
   anything that can fail, then `app/error_log.dart`: Flutter's own errors
   (a layout assertion, a build that threw, an uncaught async error) become
   an `E performLayout(): …` entry with the blamed widget and the app's
   frames, so a console that scrolled away is still in the file. Build it in the first step that can report a
   failure, not before, and never swallow an error into a bare `catch (_) {}`.
9. **Async work has an owner and a stale check.** Each action declares whether
   a repeat is rejected, merged or queued. A result that arrives after its
   document, position or request changed is discarded. Disposing a widget never
   kills work that should continue, such as a running generation.
10. **Explain non-obvious algorithms next to the code:** representation, units,
   score perspective and a small example. Long explanations go in
   [ALGORITHM.md](ALGORITHM.md).
11. **Build only what the current step's screenshot needs.** No abstractions,
    options or scaffolding for a later step.
12. Follow [the Dart conventions](agents/dart.md) for paths, helpers and
    `SafeChangeNotifier`, and [the UI conventions](agents/ui.md) for controls,
    typography, shortcuts and copy density. Where those guides name old
    folders, the `v2` equivalents apply.

## Choices already made

None of these is re-opened during the rewrite.

| Area | Choice |
|---|---|
| Dependency passing | Constructors, with Provider for Flutter lookup and listening. No Riverpod, Bloc or GetIt. |
| State | Plain immutable values and sealed classes. No code generation. |
| Packages | No new pub dependencies beyond two the owner allowed on 2026-09-21: `chessground` (Lichess's board, by the `dartchess` authors) and `multi_split_view` (draggable panes). The existing set (`dartchess`, `provider`, `http`, `sqlite3`/`sqflite_common_ffi`, `shared_preferences`, `stockfish`, `onnxruntime`, `window_manager`, `file_picker`) covers the rest of `v2`. A hand-rolled piece is replaced by a package only when the package does the whole job; the PGN reader stays, because no package keeps untouched games byte for byte or reports where a bad token is. |
| Database | The existing SQLite files, schemas and migrations. |
| Files | A new atomic writer in `v2/storage/` that takes the same SQLite-transaction lock the old app takes (`file_operation_lock.dart` documents the protocol), so the two apps lock each other out. |
| Network | `http` behind one client per service, each with its own retry policy. |
| Navigation | A persistent shell with the mode menu and plain `Navigator`. No router package. |
| Strings | Plain English in widgets. |
| Credentials | Keep reading the existing SharedPreferences tokens. A vault migration is a separate, later step. |
| Panels | `multi_split_view` with minimum sizes; the divider look and the pane widths are tokens in `ui/theme.dart`. A saved layout is not built yet. |
| Theme | Dark by default with Light/System, tokens in `ui/`. Built in step 0 only as far as a board and a move list need; extended by later steps. |
| Catalog and visual tests | Widgetbook on production widgets, added at step 12. Widget tests before that; no golden framework. |

## What clean code means here

Clean code is code a maintainer reads once and can predict. Three questions
decide it, and the reviewer answers each with a file and line, not an opinion.

**Can I read it?**

- Names say what; comments say why. A comment that explains *how* a block
  works means the block should be rewritten (kernel `coding-style`). A
  non-obvious algorithm gets a short paragraph with its representation, units
  and one worked example beside the code (Knuth).
- A function does one thing and fits on a screen: at most 50 lines, 3
  levels of nesting and 5 parameters. Extract a piece when it has a name and a
  contract, not to hit a length; one long linear function that runs top to
  bottom once is better than six that share state through fields (Carmack).
- A file holds one type or one group of closely related functions, at most
  600 lines. Never `part`. The cap was 400 until 2026-09-21, when two core
  owners sat on it and a commit went in only to shorten a comment.
- Clear beats clever (Pike). No tricks that need a second reading.

**Can I reason about it?**

- Data is values. Domain types are immutable; a change returns a new value.
  Mutable state lives in exactly one owner that notifies (Hickey: do not braid
  state, identity and time).
- Effects happen at the edge. Parsing, tree operations, scheduling and scoring
  are pure functions of their arguments; `storage/`, `engines/` and `net/` do
  the I/O; owners connect the two. A pure function is tested with values only.
- Expected outcomes are typed results, not exceptions: a sealed `SaveResult`
  with `Saved`, `Conflict`, `Collision`, `Invalid`, `IoFailure` and an
  exhaustive `switch`. Design so the error cannot happen where possible
  (Ousterhout: define errors out of existence).
- Ids and units are types when confusion would be a bug: `Fen`, `Revision`,
  `ChapterId`, `Centipawns` (lila's opaque ids). Not every string.
- Every `await` in an owner is followed by a check that the request is still
  current. Every subscription, timer and process has a named owner and is
  closed in `dispose`.
- No `dynamic`, no `late` for things that could be constructor arguments, no
  boolean parameters that switch behaviour, no nullable fields that mean
  "not loaded yet" when a sealed state would say it.

**Can I change it?**

- One place per fact. FEN normalisation, movetext formatting, chapter naming
  each exist once. A little copying at the edges is better than a dependency
  on an unrelated module (Pike); a second implementation of a rule that must
  agree is a bug.
- Deep modules: a small interface hiding real work (`store.save(doc,
  expected: rev)`), never a wide one (`writeFile(path, bytes, {overwrite,
  lock, backup, …})`). A class or method that only forwards to another does
  not exist (Ousterhout).
- Nothing is there for later. No options nobody sets, no abstract classes
  with one implementation, no hooks for a step that has not started. Dead
  code is deleted, not commented out.
- Modules do not reach across: a feature imports `workspace/` and below,
  never another feature (lila's `modules/`, each with its own wiring).
- Tests describe behaviour a user could see or a contract another module
  relies on. A test never reads private state or asserts a call sequence. If
  a refactor that keeps behaviour breaks a test, the test was wrong.
- Dart idiom: [Effective Dart](https://dart.dev/effective-dart), `final` by
  default, sealed classes and exhaustive switches, records for small tuples,
  extension types for ids, `package:path` for paths.

### Style reference

Copy the shape of these files; they are what the rules above look like:

| File | Shows |
|---|---|
| `lib/v2/chess/pgn/game_tree.dart` | Immutable values (`MoveNode`, `NodePath`, `GameTree`), doc comments that say why |
| `lib/v2/chess/pgn/pgn_reader.dart` | A pure function over a package, typed issues instead of exceptions |
| `lib/v2/chess/pgn/tree_merge.dart` | One algorithm, one paragraph explaining it |
| `lib/v2/workspace/document_session.dart` | An owner: two fields, commands, derived getters, nothing else |
| `lib/v2/features/library/library.dart` | Sealed states and results, a stale check after `await` |
| `lib/v2/workspace/move_tree_view.dart` | A widget built from an owner, private sub-widgets, no I/O |
| `lib/v2/app/shell.dart` | Composition and the one cross-feature request |
| `lib/v2/storage/chapter_files.dart` | An interface at a real boundary (the filesystem) with sealed results, and its one adapter |
| `lib/v2/engines/uci_engine.dart` | A protocol over a pipe: serialised searches, each with its own stream, so stale output cannot land |
| `lib/v2/workspace/engine_analysis.dart` | An owner over a background job: enable/disable, stale checks, a 200 ms snapshot buffer, `dispose` |
| `test/v2/workspace/engine_analysis_test.dart` | Fake time, a scripted double, assertions on the owner and never on private state |

`scripts/check_v2.py` enforces the numbers below and the import table; run
it before saying a step is done.

### Reviewer checklist

The independent review of a finished step answers these, each with a location:

1. Any file over 600 lines, function over 50, nesting over 3, class over 10
   fields? (`scripts/check_v2.py` finds the first three.)
2. Any owner holding data that belongs to another owner in the
   [workspace table](#workspace-owners)?
3. Any `await` not followed by a stale check? Any subscription without a
   `dispose`?
4. Any exception used for an expected outcome? Any `catch` that swallows?
5. Any pass-through class, unused option, abstract type with one
   implementation, or code for a later step?
6. Any rule implemented twice? Any old-app code pasted in?
7. Any test that reads private state or asserts implementation order?
8. Any comment that explains *how*? Any algorithm without a *why*?
9. Is the `v2` line count for this step below the old app's for the same
   features?

A finding is fixed before the status cell says Done. **Step 0 is reviewed by a
second agent before step 1 starts**, because every later step copies its
style.

## Data safety

User data is the one thing the rewrite must never damage.
[DATA_INTEGRITY.md](DATA_INTEGRITY.md) lists every store, its format and its
recovery files.

### Stores and formats

| Data | Where | Must preserve |
|---|---|---|
| Repertoires and chapters | Documents `repertoires/` folders with chapter PGNs | Comments, variations, NAGs, unknown headers, machine tokens such as `[%eval]`, `[%pv]` and `[%clk]` |
| Studies | Multi-chapter PGNs in Documents `studies/` | Lichess export tags, root comments, per-chapter orientation |
| Games | Support `app_games.db`, collection-scoped with position indexes | Tactics source games that have no other copy |
| Training | Review, progress and history CSVs and attempt JSONL, keyed by chapter path | Scheduling and history across chapter rename, move, split and delete |
| Generation output | Versioned bundles via the artifact repository, plus legacy chapter-side files | Readability of old artifacts; user edits to companion PGNs |
| Settings and accounts | SharedPreferences keys | Existing keys and values |
| Recovery | Atomic-write journals, quarantine, PGN recovery snapshots, SQL `game_trash`, schema-upgrade backups, the training records a relocation replaced in Documents `.cap-reference-history/<operation>/`, and the Support note naming a move whose training rows are not rewritten yet | Each keeps its purpose; none of them is the version history — see [Backups](#backups) |

### Backups

The user never asks for a backup and never names one. Losing work is a bug in
this section, not a mistake the user made.

- **Every replaced byte is kept.** A save, append, import, rename or delete goes
  through the store, and the store already returns the validated before-content
  of the file it replaced. That content is what gets recorded. A write whose
  backup could not be recorded does not proceed; it returns an I/O failure like
  any other.
- **Backups live in Support**, under `backups/<document id>/`, one plain copy
  per version named by commit time and content hash, with a small index per
  document. Copies are not compressed: PGN is small, disk is cheap, and a
  compressed copy is one more thing that has to work before a save may go
  ahead (versions an earlier build gzipped are still read, by their magic
  bytes). They are never written into Documents: a synced folder must not
  gain files the user did not make, and a restore must work when Documents is
  the thing that went wrong.
- **Identity, not path.** Versions follow the document's identity, so a rename
  or a move keeps one history instead of starting a second one.
- **Unchanged content costs nothing.** A save whose bytes hash to the newest
  stored version records nothing.
- **Retention** is by age, then by size: everything from the last day, hourly
  for a week, daily for a month, weekly for a year. A byte cap prunes oldest
  first. The newest version of a document is never pruned, and pruning runs on
  its own schedule, never inside a save.
- **Restore is a normal save.** Settings ▸ Data lists each document's versions
  with time, size and move count, previews one, and restores by writing it
  through the store — so the restore is itself backed up and undoable. Nothing
  is ever replaced without the user choosing it.
- **SQLite** (`app_games.db`) is snapshotted with SQLite's backup API, not by
  copying db/WAL/SHM, when the newest snapshot is older than a day.
- **What it is not:** not the undo history (store receipts, in-session), not the
  generation artifact history (versioned bundles, per run), not the recovery
  files above (interrupted writes and deletes). Those keep their own purposes.

Step 2 owns the write path and the recording; the restore screen ships with
step 13's Settings, and until then a version is recoverable from Support by
hand.

### PGN document store

Every PGN write goes through one `PgnDocumentStore` in `v2/storage/`. Nothing
else in `v2` calls `File.writeAsString`.

| Intent | Contract |
|---|---|
| Open | Returns revision and content. Absent, unreadable and malformed are distinct results; a failed read is never an empty document. |
| Create or save a copy | Exclusive create; a name collision returns a collision and replaces nothing. |
| Save | Requires the loaded revision and the scope of the edit. If the file changed on disk, return a conflict. There is no overwrite flag. |
| Append, import or edit | A locked transformation of current content. Returns the validated before-content and the committed revision together. |
| Undo | Validates that storage still holds the revision the undo entry expects; restores that entry's before-content. On mismatch it rejects and keeps history. |
| Rename, move, delete | The same store and lock, with collision checks, and training references updated in the same operation. Delete is recoverable. |

Results are typed: saved, conflict, collision, invalid document, refused or
I/O failure. Only *saved* clears the dirty state. A conflict keeps the user's
draft and offers keep editing, save a copy or reload. Dismissing a dialog never
grants overwrite permission.

A save also declares what it is changing. `save` takes an `EditScope`: the
games of the version on disk it writes again and how many it adds at the end,
or `WholeDocument` for a restore, an import or a caller that cannot say, which
is logged as a warning so it is visible. The scope comes from the edit that
produced the text — `addMove` and `setComment` report the games they wrote —
never from comparing the new text with the old, which would agree with
whatever the writer did and leave nothing to refuse. Before anything is written, the new
text and the version on disk are cut into games with the chapter reader's own
splitter and compared: a game the scope does not name that would change, a game
that would disappear, or a changed `//` heading refuses the save, names the
first game that would have changed and writes nothing. Then the version being
replaced is copied into Support, and only then is the file replaced. A create
has no previous version, so there is nothing to declare and nothing to compare.

That is the whole of a save. The store does not read the file back after the
rename, and does not read its own backup back before it: a temp-and-rename on
a local disk does not fail silently, and a check that reads every byte again
buys nothing the revision check and the kept copy do not already give. What
the store keeps is the protection against the two things that really happen —
another writer, and a bug in this app's own writer.

**Nothing waits for the disk.** Reading bytes and hashing them happen on
another isolate (the native probe in `packages/document_file_io`), and so do
decoding a large file, encoding and hashing the text to write, and the
game-by-game comparison. Parsing a chapter into its tree happens on another
isolate once the text is larger than a few tens of kilobytes. A large
generated book opens and saves without the window pausing.

A revision is the SHA-256 of the exact bytes on disk. The same bytes are the
same document, whichever file they arrived in; different bytes are a conflict,
never permission to replace. (The native file identity the probe also returns
is used by moves, which write it down so that a move interrupted half way can
be finished by the file rather than by its name.)

Undo history is built from store receipts (actual before-content and committed
revision), never from controller memory. Edits A → B → C leave rC on disk. Undo
C checks rC and restores B, and because a revision is the bytes, B's entry
expects exactly what is on disk again. If an external edit E happened before
C, undo C restores E and the older B entry stays disarmed. A failed or
uncertain undo never pops history.

**Reading and writing a game.** `v2/chess/pgn/` owns the PGN grammar; dartchess
is used for legality and positions, never for text. Reading a game yields its
header lines with the endings they had, its moves, the termination marker it
wrote (never the `[Result]` tag), the whitespace before the moves, and a list
of named, located issues. **Any issue at all makes the game not whole:** it
keeps its own bytes, is left out of `Chapter.writableTree`, and every edit
that would have to rewrite it is refused with a typed reason the screen shows.

**The round-trip gate.** `rewritten` in `chess/pgn/rewrite_gate.dart` is the
only way a game already in a file becomes new text. It refuses a game reading
did not take whole; otherwise it writes the game, reads that text back and
compares headers, separator, moves, comments, annotations and marker, and
answers `LineRewritten(line)` or `LineRefused(reason)`. An edit commits
nothing until every game it must write comes back, so a note never lands in
some games and not others, and a refusal reaches the user as a typed reason.
The store needs no hook: a chapter that cannot be written never produces text
for the store to save.

A comment lives where it lived. A move several games play is commented in the
games that already carry a comment on it, or in the first game that plays it
when none does; reading merges the comments of every game, so the workspace
still shows one note.

The writer's canonical form is stated on `writeMoveText`. It keeps the SAN the
file spelled, every comment's text, the order of moves and variations, the NAG
numbers and the marker; it normalises redundant move numbers, several comments
on one move into one, `;` comments into `{}`, symbolic annotations into their
numbers, and `e.p.`. Each normalisation reads back as the same game, which the
gate proves, and writing twice gives the same bytes.

**When the file is written.** The workspace does not write on every move.
An edit starts a one-second clock, every edit inside it restarts the clock,
and the file is written once when it runs out, with the newest text: a burst
of moves is one write. Anything that needs the file now ends the wait at
once — opening another document, a rename, the window losing focus or
closing, and undo, which writes the waiting draft before it steps back.
Only one write is in flight at a time and edits made during it collapse into
a single pending save, so there is never a queue of stale snapshots. This is
what Obsidian and VS Code do, and for the same reason: the file is never
more than a moment behind the screen, and a keystroke never costs a write.

### Required failure tests (step 2)

Against real files in a disposable directory: concurrent create of the same
name; a stale save after an external edit; two app writers, including the old
and new apps at once; an external edit before an append, then undo; successive
and per-move undo with an external edit between; an interrupted replacement,
then recovery; a queued save after switching chapters; a generation that
finishes after its source changed; a failed read, unreadable file and
disk-full error; chapter rename, move and delete while a training session is
writing. Tests never touch the user's real profile.

### Filesystem notes

- Locks coordinate app writers only. Commit-time revision checks catch what
  they can of external editors; backups cover the rest.
- Treat Documents as possibly synced. A delayed or failed read is an error, not
  empty content. Never merge or delete conflict copies automatically.
- Live SQLite files and lock databases stay in local Support storage. Back up
  SQLite with its backup API, never by copying db/WAL/SHM files.
- Durability goal: survive app or worker termination. POSIX: write temp, fsync,
  rename, fsync the directory. Windows: `ReplaceFileW`, sharing violations
  retried with a capped backoff and a fresh revision check.

## Settings

- One writer per key. A failed read is different from an absent key and never
  starts work with defaults. A failed save is shown as failed.
- Jobs capture their configuration when they start.
- Secrets never appear in snapshots, logs, Widgetbook or exports.

## Network and offline

The app is usable with no connection. What the user has already downloaded is
on this computer, and a fetch that does not happen leaves it on the screen.
The old app broke this by reading its games cache only when a fetch returned
*empty*: a fetch that threw went past it, and a startup "check for new games"
that skipped the cache on purpose turned a missing connection into a page with
no games on it.

- **One client per service** in `net/`, injected at its owner, each with its
  own retry and backoff policy. Both paths are driven in tests by a fake
  client; no test reaches the real network, and `flutter test` blocks it
  anyway by answering every socket with an empty 400.
- **A failed fetch never takes data away.** The owner keeps what it had, marks
  it stale with when it came down, and names the service it could not reach.
  An empty list is a far stronger claim than "could not check".
- **Refreshing harder still cannot empty the screen.** A forced refresh — the
  user pressing check-for-new, or a startup check — prefers the network and
  ignores any freshness window, but never discards the local copy on the way
  back. Only a request with nothing stored behind it shows an error instead of
  content.
- **Two services fail independently.** One site being unreachable never
  removes the other's rows.
- **What a panel displays is persisted**, not held for one session, so a
  second launch offline shows what the first launch fetched. In-memory caches
  are scratch for a single session. The one decided exception is the Lichess
  explorer, whose database is the service: it stays online-only and says so
  with a retry (see [the workspace spec](v2/features/workspace.md)). A panel
  that cannot answer offline says which service it needs and offers the retry;
  it never shows an empty result or an unresolvable spinner.
- **A stale answer is labelled, not hidden:** one muted line naming the
  service and the age, beside the content, never instead of it.

**Required failure tests**, in each step that adds a client: a fetch that
throws, one that returns nothing, and one that returns a 429 and a 500 — each
against a store that holds content and against one that does not; a forced
refresh that fails; and two services where one fails and the other does not.

**Confirming it in the running app** belongs to the step's screenshot. The
accepted screenshot is the online proof; the offline proof is the same screen
from `python3 scripts/app_driver.py start --offline`, which runs the app in a
network namespace with loopback only — display, VM service and session bus
intact, nothing else reachable. Warm the build with a normal `start` first.
(`unshare` around the driver does not work: the app runs in a user-manager
unit, not as a child of the caller.)

## Engines and background work

- One supervisor owns every engine process, drains stdout and stderr into
  bounded buffers, and defines cancel, graceful stop, timeout and kill per
  engine type. Cancelled is reported only after resources are released.
- Engine processes die when the app dies, including when it is killed. Tested
  on Linux in step 1; Windows (Job Object) and macOS when those hosts are
  available. Never kill processes by name.
- Continuous analysis updates the UI at most about every 200 ms with the latest
  snapshot of all MultiPV lines; `bestmove`, completion and errors arrive
  immediately. No trailing debounce.
- Workers, ports, timers and subscriptions have a named owner and an idempotent
  shutdown. Opening and closing a mode repeatedly returns process and port
  counts to baseline.
- Large documents are shown from immutable projections tied to a revision.
  Never deep-copy or compare a whole move tree on each cursor move.

## Interface

- A quiet dark workspace by default; colour only for meaning (errors,
  evaluation, selection). Board, moves and the current task get priority.
- Context stays visible: current file, side, orientation, selected line,
  filters and save state. Back, cancel and mode switches return to the same
  position and draft.
- Distinguish unsaved, saving, saved, failed and conflicted. Real progress,
  never a fake ETA.
- 12px type floor, 4.5:1 contrast, usable at 150% and 200% text scale.
- Typeable choice fields instead of dropdowns, visible search inputs, shared
  confirmation and name dialogs, shortcuts in tooltips.

## Keeping the UI replaceable

The owner will change the look of `v2` often, so the rule that makes that
cheap comes first: **a widget file can be deleted and rewritten from its
owner's public API and the theme alone.**

- Owners (the `ChangeNotifier`s in `workspace/` and `features/`) import
  `package:flutter/foundation.dart` at most, never widgets. They expose
  values, typed states and commands; they know nothing of layout, text or
  colour.
- A widget is a function of one or two owners: it reads their values, calls
  their commands, and keeps only view state (hover, scroll position, an open
  menu). State that two widgets need lives in an owner.
- Only `Shell` and `WorkspaceView` know which panel sits where. Every other
  widget lays out its own contents and nothing else.
- Colours, font sizes, font families and spacing come from `ui/theme.dart`
  (`darkTheme()`, `BoardTheme`, `Space`, `monoText`, `scoreText`). Literal
  `Color(0x…)`, `fontSize:` and `fontFamily:` appear only under `ui/`;
  `scripts/check_v2.py` rejects them elsewhere. A widget that needs a new
  value adds a named token to the theme.
- A widget file (one importing `package:flutter/material.dart` or
  `widgets.dart`) never imports `dart:io` or `net/`; the checker rejects
  that. From `storage/` and `engines/` it takes value types only
  (`ChapterRef`, `Score`, `EngineLine`), never an adapter or a process.
- Every owner has a test without widgets. Every widget test uses a scripted
  owner or double from `test/v2/support/` and never a real file or engine.
- **Keep the current look.** The values in `ui/theme.dart` are the old
  app's: Inter and Source Code Pro, sizes 18/14/13/12, surface `1B1B1D`,
  accent `5F93CC`, board `F0D9B5`/`B58863`. When a step needs a colour, size,
  layout or control the old app has, screenshot the old mode with the
  driver or read `lib/design_system/theme/` and copy the *value*, never the
  code. Do not redesign; the redesign comes later, through the theme and the
  panel files, and a design that is built into owners would block it.
- The reviewer's test for a step: could the new widget file be rewritten from
  scratch by someone who read only the owner's public API and the theme?
  If not, state or layout leaked into the wrong place.

## Order of work

One row is one agent session. Each row ends with a headless screenshot the
product owner looks at, tests passing, and the work integrated into local
main. Rows deliver a feature, never a foundation; theme tokens, `SplitPane`,
settings, lint and Widgetbook appear inside the row that first needs them.

| Step | Scope | Ends with | Status |
|---|---|---|---|
| 0 | **Board on screen.** `main_v2.dart`, a window with the mode menu stub, board widget, move-tree widget; open a real chapter from Documents `repertoires/` read-only; click and arrow through moves. Only the theme values a board and a move list need. | Screenshot of a real chapter | Done 2026-09-19: 1.5k lines, 23 tests; second-agent review the same day, its findings fixed (typed file results, open race, move-list rewrite, 18 more tests) |
| 1 | **Engine.** Supervisor, one Stockfish, engine pane with MultiPV lines at 200 ms, kill-on-exit test on Linux. First step that can fail, so it also installs the log: facade in `diagnostics/`, file sink in `storage/`, installed by `main_v2` before the engine starts. | Live evaluation on the board, and an engine that will not start named in `app.log` | Done 2026-09-19: 1.6k lines, 41 tests; a real Stockfish dies with a SIGKILLed parent on Linux (`test/v2/engines/stockfish_exit_test.dart`); a start failure is an `E start …` line in `app.log` |
| 2 | **Document store.** `PgnDocumentStore` (open, save, create, rename, move, recoverable delete) with revisions; add moves and comments in the workspace; save; undo from receipts; every replaced version recorded per [Backups](#backups); the required failure tests; the old app sees the edit. | Edit a chapter, reopen it in the old app | Done 2026-09-19 (owner has not yet seen the screenshot): 6.4k lib lines total, 217 tests; store with revisions, backups and the cross-process lock proof; moves, comments, autosave, undo and conflict handling in the workspace; the old app reads the edit. 2026-09-20: saves settle a second after the last edit instead of going out per move, backups are plain copies, the post-write read-back and backup read-back are gone, and every byte-wide step runs off the UI isolate. Not built: retention/pruning, Windows `ReplaceFileW`, delete/promote/NAG edits |
| 3 | **Library.** Repertoire list, search, create, rename, move, recoverable delete; training references follow chapter changes. | Screenshot | Done 2026-09-19 (owner has not yet seen the screenshot): 7.7k lib lines total, 264 tests; repertoire folders with chapter counts and search, create, rename, move a chapter, recoverable delete of a chapter or a whole repertoire with the training rows following each file, shared name and confirm dialogs. Not built: Open PGN file and Paste PGN import, the Recovery view, the folder Organize view and outline drag and drop, course chapters, studies, the picker other modes push, late writes from an active trainer session re-adding an old path (no v2 trainer yet) |
| 4a | **Chapter outline.** The open repertoire's chapters and the open chapter's lines in a column beside the board, with search, the line operations, the move edits that rewrite whole games, and a playing side that can be changed. | Screenshot | Done 2026-09-20: 18.4k lib lines total with step 4b, 802 tests; the column lists chapters and lines (name, branch-point moves), clicking opens a chapter or moves the cursor, 200 ms search over names and movetext, rename/delete a line with an eight-second Undo, New chapter, Delete from here / Promote variation / Make main line on the move's right button, and a two-button side that rewrites `// Color:` in place. Not built: move a line to another chapter, drag and drop, multi-select, folders, course sections, split, import, check disk, publish, a line count for chapters that are not open, and a resizable or collapsible column. Reviewed the same day; its findings fixed (a moved game no longer takes the whitespace after it, a line that loses its moves keeps its name and id, the next edit closes the Undo offer, Ctrl+Z reaches the document from every column, the current line is worked out once per cursor move) |
| 4b | **Study.** Study mode over the same workspace: the studies in Documents `studies/`, one game per chapter, the chapter list and its operations, per-chapter orientation, Lichess import from a URL, export, quiz markers. | Screenshot | Done 2026-09-20: 18.6k lib lines total, 816 tests; one session reads one game of a file as the chapter, so the study list, the chapter list, New/Rename/Orientation/Reorder/Delete chapter, New and Delete study, Copy study and chapter PGN, Lichess import from a URL and `[%tstart]`/`[%tend]` quiz markers all run on the same board, saver and store. Left out: drag-and-drop reorder (menu only), the chapter manager dialog, chessgames.com collections and `study/by/<user>`, PGN-file import, Save study PGN as…, per-chapter free-form tag editing, Set starting position on an existing chapter, clear comments/variations, study rename, the compact layout and the Train and Browse handoffs |
| 5 | **Trainer.** Training session over the workspace, scheduling, history and bulk actions on the existing CSV/JSONL formats. | Screenshot and one completed session | Not started |
| 6a | **PGN Viewer.** Open a PGN file (recent list or the desktop's dialog), list its games, one game at a time on the shared board, annotate through the same saver. | Screenshot | Done 2026-09-21, second pass the same day after the owner saw it: 21.0k lib lines, 937 tests. Reading column in the old app's shape (heading, engine as one row when off, moves with comments laid out as paragraphs with inline moves, diagrams and Chessable headings, a navigation row); editing is a strip behind Actions ▸ Edit / Ctrl+E (Done, Undo, save state, six glyphs, comment field); the eval bar is gone from the app; a typeable game counter under the board, ↑/↓ for games, Home/End/PgUp/PgDn for the line, F, E, Ctrl+B hides the list, Ctrl+O opens a file, Ctrl+K types into the Actions menu; a file outside Documents is copied into `pgn_collections` on open. Not built: right-click ▸ Comment, paste from the clipboard, filters, sort, the remembered reading position, My books, engine review, Tree and Collection, export, solitaire (an action of the viewer, per the owner), autoplay, fullscreen, handoffs |
| 6b | **Games.** Collections from `app_games.db`, filters, explorer pane (Lichess, Masters, TWIC). | Screenshot | Not started |
| 7 | **Generation.** Launch from a chapter, progress, cancel, publish against the source revision, results in the side panel; expectimax rewritten from ALGORITHM.md and compared with the old app on the same input. | One real build | Not started |
| 8 | **Checks.** Holes/tricks, coverage, audit and planner as side-panel tools on the same document. | Screenshot | Not started |
| 9 | **Tactics.** Puzzle sets, game import, review, filters, puzzle session. | Screenshot | Not started |
| 10 | **Players.** Player analysis, opponent search and prep sheets, tournaments, people directory, US Chess lookup. | Screenshot | Not started |
| 11 | **Databases.** Master games, TWIC import and browser, broadcast collections, Scid export. | Screenshot | Not started |
| 12 | **Engine tournament and Bughouse lab** on the shared supervisor. | Screenshot | Not started |
| 13 | **Services.** Settings screen, Lichess and chess.com accounts, updates, diagnostics (**Open log folder**, copy diagnostics); theme polish; Widgetbook. | Screenshot | Partial 2026-09-21: the settings store and dialog. One `Settings` value in `storage/settings.dart`, one writer (`SettingsStore`, `settings.json` in the support folder, a failed read named on the page and kept as defaults); a 640×300 dialog (mode menu ▸ Settings…, Ctrl+,) with a list of five places — Look, Engine, Files, Accounts, App — and the chosen place's rows, one line each, searchable across places. Rows today: board coordinates; engine cores, memory and lines (the engine restarts for cores or memory, re-searches for lines); copy files from outside Documents on open; the Lichess token (the old app's key); Open log folder. Owner's rule for the page: a row only when two people want different values and the app cannot tell; a mode's own knobs stay in the mode. Not built: theme, figurines, chess.com, updates, diagnostics copy, Widgetbook |
| 14 | **Switch-over.** `main.dart` starts `v2`; delete the old code, tests, ledgers and checks; move `lib/v2/` to `lib/`; gather the folders the app writes in Documents (`repertoires/`, `studies/`, `pgn_collections/`, `games_library/`, `analysis_games/`, `tactics_sets/`, `opponents/`, `engine_tournaments/`, `exports/`, `repertoire_debug_runs/`, and the tools' `expectimax_runs/` and `lichess_broadcasts/`) under one `Documents/Chess Auto Prep/`, moving existing data once with a backup of every moved file and rewriting the settings keys and training references that name old paths (owner decision 2026-09-21; not earlier, because both apps must share the same folders until then); rewrite COMPONENT_MAP and the agent guides. | Old code gone | Not started |

A row that turns out too large for one session is split into two rows here,
each with its own screenshot; it is not stretched over two sessions.

### A step is done when

1. The product owner has seen the screenshot and accepted it.
2. Everything in the row's scope works in the running `v2` app, or the owner
   dropped it (remove it from the row so it is never ported).
3. It reads and writes the same data as the old app, and both run at once.
4. Tests cover its user actions, its failure paths and every write it makes.
5. Every failure it can hit names the action in the log, and the screen says
   the same thing in plain English.
6. Its `v2` code is smaller than the old code for the same features. If it is
   not, stop and review the design before continuing. Tests are counted
   separately.

Mark the status cell *Done* with the commit. Nothing else is written down.

### Known hard problems

Each belongs to the step that owns it:

- **Step 3:** chapter rename, move and delete must update training references,
  including late writes from an active session and a reused path.
- **Step 3:** the old app serialises every repertoire operation behind a lock
  on `<repertoires>/.cap-directory-domain` as well as the folder locks both
  apps take; `v2` does not take it yet, so against the old app the folder
  locks stop two writers in one folder but not two repertoire-wide
  operations.
- **Step 6:** opening another file, pasting, recovery and close must stop
  delayed collection, filter, index and analysis work.
- **Step 2/7:** autosave is bounded (no unbounded queue of snapshots);
  generation publishes only against its source and run identity, never over an
  edited companion PGN. Legacy artifacts stay readable; legacy runs are not
  resumed.
- **Step 2:** a backup that cannot be recorded must fail the write without
  leaving a half-applied change, and retention must never race a save.
- **Step 13:** tokens are plaintext in SharedPreferences. Migrate one account
  at a time: write the vault, read it back, then remove the old key.
- **Platforms:** engine cleanup after a killed app is verified only on Linux.

## How agents work on this

### The brief

Each mode has a behaviour spec in [`docs/v2/features/`](v2/features/README.md):
what is on the screen, what the user can do, what data it touches, what can
fail, and the owner's Keep / Change / Drop verdict on each item. The spec is
the scope of a row; the row text in the table is its summary; the old code
is consulted only for file formats and algorithms. A row starts when its
spec says `corrected by the owner`.

The product owner starts a session with one row and this brief, filled in:

```text
Goal: v2 step N — <the row's scope in one sentence>; screenshot; tests;
integrate; stop.

Rules:
- Work only in lib/v2/, lib/main_v2.dart and test/v2/. Never import or copy
  old lib/ code; read it, then write the v2 version. Never edit the old app.
- No new pub packages. No package or framework evaluations.
- No documents except the one status cell in docs/ARCHITECTURE_RENEWAL.md.
  No evidence logs, checkpoints, reports, ledgers or diaries.
- No scaffolding for a later step. Build what this step's screenshot needs.
- From step 2 on, every write goes through PgnDocumentStore.
- Budget: stop after about three hours of work or when the goal is met. If not
  done, commit what runs, integrate it if checks pass, and report what is
  missing in three lines.
- Done = screenshot from the headless driver, tests passing,
  python3 scripts/check_v2.py clean, scripts/ci.sh analyze lint, integrated to
  local main, v2 line count reported. Before saying done, answer the nine
  reviewer questions in docs/ARCHITECTURE_RENEWAL.md with a file and line.
```

To see the app: `python3 scripts/app_driver.py start --target lib/main_v2.dart`
from the worktree, then copy a chapter into the profile's
`Documents/repertoires/<name>/` folder that `status` reports.

### Session rules

- **One row per session.** Never "finish the plan", "the whole renewal" or an
  overnight goal. The next row starts after the owner has seen the screenshot.
- **Before integrating**, run `scripts/ci.sh analyze lint` and the `test/v2/`
  suite. The old app's full suite is not run for `v2` changes.
- **Status is the table cell.** Commit messages and tests are the record.
- **Review:** one independent review of the diff against the
  [reviewer checklist](#reviewer-checklist) when a row is marked done.
- **After a context reset**, re-read this file and `git log -- lib/v2`.
- **Ask the product owner** about scope, dropping something and visible design.
  Decide implementation details without asking. In an
  [unattended run](#unattended-runs) a visible-design question defaults to
  what the old app shows for that mode, and the question goes in the report.
- **When unsure, do the smaller thing.** Unsure whether to add a class: do
  not. Unsure whether something is an owner: only if it holds mutable state
  that outlives a widget; otherwise it is a value or a function. Unsure where
  a file goes: the import table decides, and a file that needs two folders is
  two jobs. Unsure about a screen: match the old app's screen for it.

### Unattended runs

When the owner is away, one session works through several rows with this
prompt. It is the brief above plus the review, the stop rules and the
report; nothing in it lets the agent choose scope.

```text
Work through docs/ARCHITECTURE_RENEWAL.md, "Order of work", one row at a
time, starting at the first row whose status is Not started. First read the
whole file, then `git log --oneline -- lib/v2`, then every file in its
style-reference table. For each row, in this order:

1. Review the previous row: spawn one subagent with the reviewer checklist
   and the "Keeping the UI replaceable" section over
   `git diff <first commit of that row>^..HEAD -- lib/v2 test/v2`. Fix every
   must-fix finding in a commit of its own before starting the new row.
2. Make a worktree: `python3 scripts/agent_worktree.py v2-stepN`.
3. Read the row's spec in docs/v2/features/ (stop if it is not marked
   corrected by the owner). Build the row from the spec; nothing for later
   rows; Drop lines are never built. When it needs a value the old app has (a colour, a size, a file format, a layout), read
   the old code or screenshot the old mode and copy the value, never the
   code. Owners first, with their tests; widgets last, from the owners.
4. See it: `python3 scripts/app_driver.py start --target lib/main_v2.dart`,
   seed the profile the driver reports (copy a chapter from the old app's
   Documents/repertoires; never point v2 at the real folder from a test),
   drive the feature, take a screenshot and open the PNG yourself. Check:
   the row's feature works on a real chapter, nothing overflows, only Inter
   and Source Code Pro, no colour without meaning, nothing below 12px.
5. Checks: `python3 scripts/check_v2.py`, `scripts/ci.sh analyze lint`,
   `scripts/ci.sh test test/v2`. All clean, no skips you added.
6. Stop the preview. Commit, push, `python3 scripts/agent_worktree.py
   --verify .`, `python3 scripts/agent_integrate.py`, then `--verify`. Set
   the row's status cell to `Done <date>: <lib lines>, <tests>` and change
   nothing else in docs.
7. End the row with a five-line note: what works, the screenshot path, what
   was left out, what you were unsure about, the commit on main.

Then start the next row.

Stop and wait for the owner when:
- a row needs a design or scope decision the plan does not make: say what
  the choice is, do not pick;
- a row has taken more than three hours: integrate what runs, report;
- a row would write to user data (step 2 onwards) and its required failure
  tests are not green;
- the reviewer reports the same kind of problem in two rows running;
- a tool (driver, runner, engine) has failed twice in a row.

Never: work on the old app, add a pub package, write documents beyond the
status cell, run the old app's full suite, copy old code, or start a row
because the previous one "mostly" works.
```

## References

- [DATA_INTEGRITY.md](DATA_INTEGRITY.md): stores, formats and recovery files.
- [COMPONENT_MAP.md](COMPONENT_MAP.md): what the old app does, for parity.
- [ALGORITHM.md](ALGORITHM.md): tree-generation pipeline.
- [Flutter architecture recommendations](https://docs.flutter.dev/app-architecture/recommendations).
- [SQLite: how to corrupt a database](https://www.sqlite.org/howtocorrupt.html)
  and [WAL](https://www.sqlite.org/wal.html).
- [Windows Job Objects](https://learn.microsoft.com/en-us/windows/win32/procthread/job-objects)
  and [ReplaceFileW](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-replacefilew).
