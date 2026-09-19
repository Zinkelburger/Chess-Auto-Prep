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
- **Proven pure code**, copied into `v2` and reviewed there, not rewritten
  (see [What to copy](#what-to-copy)).
- **Every mode.** Nothing is dropped: Tactics, Player analysis, Repertoire
  builder, Repertoire trainer, PGN Viewer, Study, Engine tournament, Bughouse
  lab, Databases, Repertoires, Players & prep.

What changes is the application layer (screens, controllers, services and the
wiring between them) and the product shape: five modes that are each "a PGN
with a board" become one workspace (see [Product shape](#product-shape)).

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
- `v2` never imports old `lib/` code. To reuse something, copy the file into
  `v2` and fix it there. The duplicate disappears at switch-over.
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
receives the workspace's owner and adds its own state; it never has its own
board or move tree.

Size target for the whole of `v2/`: under 80k lines of `lib/` including about
35k lines of copied pure code, against 227k today. The gate that matters is
per step ([below](#a-step-is-done-when)); the total is the sanity check.

## Layout

```text
lib/main_v2.dart          entry point: flutter run -t lib/main_v2.dart
lib/v2/
  app/                    composition, window, mode menu, cross-mode requests
  ui/                     theme tokens and shared controls
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
| `workspace/` | `chess/`, `storage/`, `engines/`, `net/`, `ui/` |
| `features/<mode>/` | `workspace/` and everything it may import; never another mode |
| `app/` | Everything in `v2` |

Nothing in `v2` imports the old `lib/` folders. Cross-mode jumps (open this
line in the builder, train this chapter) are typed requests handled by `app/`.
An import check for this table is added in the step that first has two folders
to check, not before.

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
8. **Async work has an owner and a stale check.** Each action declares whether
   a repeat is rejected, merged or queued. A result that arrives after its
   document, position or request changed is discarded. Disposing a widget never
   kills work that should continue, such as a running generation.
9. **Explain non-obvious algorithms next to the code:** representation, units,
   score perspective and a small example. Long explanations go in
   [ALGORITHM.md](ALGORITHM.md).
10. **Build only what the current step's screenshot needs.** No abstractions,
    options or scaffolding for a later step.
11. Follow [the Dart conventions](agents/dart.md) for paths, helpers and
    `SafeChangeNotifier`, and [the UI conventions](agents/ui.md) for controls,
    typography, shortcuts and copy density. Where those guides name old
    folders, the `v2` equivalents apply.

## Choices already made

None of these is re-opened during the rewrite.

| Area | Choice |
|---|---|
| Dependency passing | Constructors, with Provider for Flutter lookup and listening. No Riverpod, Bloc or GetIt. |
| State | Plain immutable values and sealed classes. No code generation. |
| Packages | No new pub dependencies. The existing set (`dartchess`, `provider`, `http`, `sqlite3`/`sqflite_common_ffi`, `shared_preferences`, `stockfish`, `onnxruntime`, `window_manager`, `file_picker`) covers `v2`. |
| Database | The existing SQLite files, schemas and migrations. |
| Files | The existing atomic writer and its SQLite-transaction lock, copied into `v2/storage/`, so the old and new apps lock each other out correctly. |
| Network | `http` behind one client per service, each with its own retry policy. |
| Navigation | A persistent shell with the mode menu and plain `Navigator`. No router package. |
| Strings | Plain English in widgets. |
| Credentials | Keep reading the existing SharedPreferences tokens. A vault migration is a separate, later step. |
| Panels | One `SplitPane` control with minimum sizes and a saved layout, built in the step that first needs two panes. |
| Theme | Dark by default with Light/System, tokens in `ui/`. Built in step 0 only as far as a board and a move list need; extended by later steps. |
| Catalog and visual tests | Widgetbook on production widgets, added at step 12. Widget tests before that; no golden framework. |

## What to copy

Copy into `v2` and review against the code rules; do not rewrite:

| Old location | Lines | Goes to |
|---|---|---|
| `lib/chess_core/` (PGN parser, move trees, projections, generation codecs) | 5.8k | `chess/` |
| `lib/services/generation/` (expectimax, line extraction, pruning, config) | 15.4k | `chess/generation/` |
| `lib/services/scid/` | ~2k | `chess/scid/` |
| `lib/services/master_games/`, `lib/services/eval/` | 7.8k | `storage/` and `net/` |
| `lib/services/engine/`, `lib/services/maia/` | ~3k | `engines/` |
| `lib/utils/atomic_file.dart`, `file_operation_lock.dart`, `pgn_utils.dart`, `fen_utils.dart`, `movetext_builder.dart`, `pgn_nags.dart`, `time_format.dart`, `chess_utils.dart` | ~3k | `storage/` and `chess/` |

Copy a file when a step needs it, not all at once. Drop the parts the step does
not use.

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
| Recovery | Atomic-write journals and backups, quarantine, PGN recovery snapshots, SQL `game_trash`, schema-upgrade backups | Each keeps its purpose; none is a version history |

### PGN document store

Every PGN write goes through one `PgnDocumentStore` in `v2/storage/`. Nothing
else in `v2` calls `File.writeAsString`.

| Intent | Contract |
|---|---|
| Open | Returns identity, revision and content. Absent, unreadable and malformed are distinct results; a failed read is never an empty document. |
| Create or save a copy | Exclusive create; a name collision returns a collision and replaces nothing. |
| Save | Requires the loaded revision. If the file changed on disk, return a conflict. There is no overwrite flag. |
| Append, import or edit | A locked transformation of current content. Returns the validated before-content and the committed revision together. |
| Undo | Validates that storage still holds the revision the undo entry expects; restores that entry's before-content. On mismatch it rejects and keeps history. |
| Rename, move, delete | The same store and lock, with collision checks, and training references updated in the same operation. Delete is recoverable. |

Results are typed: saved, conflict, collision, invalid document or I/O failure.
Only *saved* clears the dirty state. A conflict keeps the user's draft and
offers keep editing, save a copy or reload. Dismissing a dialog never grants
overwrite permission.

A revision is the SHA-256 of the exact bytes on disk plus the observed file
identity (the native probe in `packages/document_file_io`). A changed or
missing identity means a conflict, never permission to replace.

Undo history is built from store receipts (actual before-content and committed
revision), never from controller memory. Edits A → B → C leave rC on disk. Undo
C checks rC, restores B and gets rB2; B's entry then expects rB2. If an external
edit E happened before C, undo C restores E and the older B entry stays
disarmed. A failed or uncertain undo never pops history.

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

## Order of work

One row is one agent session. Each row ends with a headless screenshot the
product owner looks at, tests passing, and the work integrated into local
main. Rows deliver a feature, never a foundation; theme tokens, `SplitPane`,
settings, lint and Widgetbook appear inside the row that first needs them.

| Step | Scope | Ends with | Status |
|---|---|---|---|
| 0 | **Board on screen.** `main_v2.dart`, a window with the mode menu stub, board widget, move-tree widget; open a real chapter from Documents `repertoires/` read-only; click and arrow through moves. Only the theme values a board and a move list need. | Screenshot of a real chapter | Not started |
| 1 | **Engine.** Supervisor, one Stockfish, engine pane with MultiPV lines at 200 ms, kill-on-exit test on Linux. | Live evaluation on the board | Not started |
| 2 | **Document store.** `PgnDocumentStore` (open, save, create, rename, move, recoverable delete) with revisions; add moves and comments in the workspace; save; undo from receipts; the required failure tests; the old app sees the edit. | Edit a chapter, reopen it in the old app | Not started |
| 3 | **Library.** Repertoire list, search, create, rename, move, recoverable delete; training references follow chapter changes. | Screenshot | Not started |
| 4 | **Chapters and Study.** Chapter outline panel, chapter operations, per-chapter orientation, Lichess study import and export, quiz markers. | Screenshot | Not started |
| 5 | **Trainer.** Training session over the workspace, scheduling, history and bulk actions on the existing CSV/JSONL formats. | Screenshot and one completed session | Not started |
| 6 | **Games.** Collections from `app_games.db`, game list, filters, explorer pane (Lichess, Masters, TWIC). | Screenshot | Not started |
| 7 | **Generation.** Launch from a chapter, progress, cancel, publish against the source revision, results in the side panel; copies the expectimax code. | One real build | Not started |
| 8 | **Checks.** Holes/tricks, coverage, audit and planner as side-panel tools on the same document. | Screenshot | Not started |
| 9 | **Tactics.** Puzzle sets, game import, review, filters, puzzle session. | Screenshot | Not started |
| 10 | **Players.** Player analysis, opponent search and prep sheets, tournaments, people directory, US Chess lookup. | Screenshot | Not started |
| 11 | **Databases.** Master games, TWIC import and browser, broadcast collections, Scid export. | Screenshot | Not started |
| 12 | **Engine tournament and Bughouse lab** on the shared supervisor. | Screenshot | Not started |
| 13 | **Services.** Settings screen, Lichess and chess.com accounts, updates, diagnostics; theme polish; Widgetbook. | Screenshot | Not started |
| 14 | **Switch-over.** `main.dart` starts `v2`; delete the old code, tests, ledgers and checks; move `lib/v2/` to `lib/`; rewrite COMPONENT_MAP and the agent guides. | Old code gone | Not started |

A row that turns out too large for one session is split into two rows here,
each with its own screenshot; it is not stretched over two sessions.

### A step is done when

1. The product owner has seen the screenshot and accepted it.
2. Everything in the row's scope works in the running `v2` app, or the owner
   dropped it (remove it from the row so it is never ported).
3. It reads and writes the same data as the old app, and both run at once.
4. Tests cover its user actions, its failure paths and every write it makes.
5. Its `v2` code is smaller than the old code for the same features. If it is
   not, stop and review the design before continuing. Tests and copied pure
   code are counted separately.

Mark the status cell *Done* with the commit. Nothing else is written down.

### Known hard problems

Each belongs to the step that owns it:

- **Step 3:** chapter rename, move and delete must update training references,
  including late writes from an active session and a reused path.
- **Step 6:** opening another file, pasting, recovery and close must stop
  delayed collection, filter, index and analysis work.
- **Step 2/7:** autosave is bounded (no unbounded queue of snapshots);
  generation publishes only against its source and run identity, never over an
  edited companion PGN. Legacy artifacts stay readable; legacy runs are not
  resumed.
- **Step 13:** tokens are plaintext in SharedPreferences. Migrate one account
  at a time: write the vault, read it back, then remove the old key.
- **Platforms:** engine cleanup after a killed app is verified only on Linux.

## How agents work on this

### The brief

The product owner starts a session with one row and this brief, filled in:

```text
Goal: v2 step N — <the row's scope in one sentence>; screenshot; tests;
integrate; stop.

Rules:
- Work only in lib/v2/, lib/main_v2.dart and test/v2/. Never import old lib/
  code; copy the file in. Never edit the old app.
- No new pub packages. No package or framework evaluations.
- No documents except the one status cell in docs/ARCHITECTURE_RENEWAL.md.
  No evidence logs, checkpoints, reports, ledgers or diaries.
- No scaffolding for a later step. Build what this step's screenshot needs.
- From step 2 on, every write goes through PgnDocumentStore.
- Budget: stop after about three hours of work or when the goal is met. If not
  done, commit what runs, integrate it if checks pass, and report what is
  missing in three lines.
- Done = screenshot from the headless driver, tests passing,
  scripts/ci.sh analyze lint, integrated to local main, v2 line count reported.
```

### Session rules

- **One row per session.** Never "finish the plan", "the whole renewal" or an
  overnight goal. The next row starts after the owner has seen the screenshot.
- **Before integrating**, run `scripts/ci.sh analyze lint` and the `test/v2/`
  suite. The old app's full suite is not run for `v2` changes.
- **Status is the table cell.** Commit messages and tests are the record.
- **Review:** one independent review of the diff when a row is marked done.
- **After a context reset**, re-read this file and `git log -- lib/v2`.
- **Ask the product owner** about scope, dropping something and visible design.
  Decide implementation details without asking.

## References

- [DATA_INTEGRITY.md](DATA_INTEGRITY.md): stores, formats and recovery files.
- [COMPONENT_MAP.md](COMPONENT_MAP.md): what the old app does, for parity.
- [ALGORITHM.md](ALGORITHM.md): tree-generation pipeline.
- [Flutter architecture recommendations](https://docs.flutter.dev/app-architecture/recommendations).
- [SQLite: how to corrupt a database](https://www.sqlite.org/howtocorrupt.html)
  and [WAL](https://www.sqlite.org/wal.html).
- [Windows Job Objects](https://learn.microsoft.com/en-us/windows/win32/procthread/job-objects)
  and [ReplaceFileW](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-replacefilew).
