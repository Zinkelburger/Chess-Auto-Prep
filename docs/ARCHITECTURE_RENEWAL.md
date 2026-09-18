# Architecture renewal: a fresh app in `lib/v2/`

**Status: Not started (planned 2026-09-18).** This replaces the first renewal
plan, which migrated the app in place. That plan is preserved at commit
`449d5428` (`git show 449d5428:docs/ARCHITECTURE_RENEWAL.md`), and its work log
is in [the evidence record](ARCHITECTURE_RENEWAL_EVIDENCE.md). Read this file,
not those, before working on the rewrite.

## Decision

Write the application again from an empty directory, `lib/v2/`, with its own
entry point, `lib/main_v2.dart`. The existing app keeps working and shipping
until the new one replaces it. When every mode the product owner keeps is done
in `v2`, delete the old code and move `lib/v2/` up to `lib/`.

The rewrite keeps the things that are not the problem:

- **The same Flutter project:** `pubspec.yaml`, the platform runners, bundled
  engines and assets, `packages/`, packaging and release tooling.
- **The same user data:** every file and database the old app reads or writes
  keeps its format and location. Both apps can run on one profile at the same
  time.
- **Proven algorithms:** PGN parsing, move generation, expectimax and tree
  generation, evaluation formatting, Scid export and similar pure code are
  copied into `v2` after review against the rules below, not reinvented.

The problem is the application layer: screens, controllers, services and the
wiring between them. That is what gets written fresh.

## Why the first plan was replaced

The in-place migration (Sept 16–18, 2026) produced useful safety fixes and
deleted more than 12k lines of unused code. It did not produce a simpler app:

- Old and new code had to coexist inside one app, so every step added
  adapters, bridges and forwarding layers to keep both halves working. Library
  code grew from 219k to 237k lines before consolidation brought it to 227k,
  while 112k lines of legacy code remained. None of the 20 feature folders
  was finished.
- The plan had 27 acceptance IDs and a 4,600-line evidence record. Agents
  spent most of their effort proving compliance and recording evidence, and
  one unbounded overnight goal ("finish the plan") exhausted a week of usage.
- "Done" was defined by review ceremony rather than by working modes and
  deleted code, so progress was hard to see and easy to overstate.

This plan measures one thing: **modes that work in `v2`.** The old app is
reference material, not something to keep compatible with at the code level.

## Rules for the old app during the rewrite

- The old app is **frozen**. Fix data loss, crashes and release blockers only.
  No new features, refactors or migrations in the old code; each one makes the
  rewrite chase a moving target.
- `v2` never imports code from the old app. To reuse something, copy the file
  into `v2`, review it against the rules below and fix it there. The duplicate
  is temporary and disappears at switch-over.
- A data-safety bug found while rewriting is fixed in `v2`. Port it to the old
  app only when the old app can lose user data because of it.
- The old architecture ledgers (`scripts/architecture_feature_debt.json`,
  `scripts/architecture_retirements.json`) stay as they are until switch-over
  deletes them with the code they describe.

## Layout

```text
lib/main_v2.dart          entry point: flutter run -t lib/main_v2.dart
lib/v2/
  app/                    composition, shell, mode menu, navigation, startup
  ui/                     theme, tokens and shared controls
  chess/                  pure Dart: PGN, positions, moves, evaluation, generation
  storage/                files, PGN document store, SQLite, settings, credentials
  engines/                UCI process supervision, pools, analysis streams
  net/                    Lichess, chess.com, US Chess and other clients
  features/<mode>/        one folder per mode: state owners and widgets
test/v2/                  mirrors lib/v2/
```

Allowed imports:

| From | May import |
|---|---|
| `chess/` | Pub packages without Flutter or `dart:io` |
| `storage/`, `engines/`, `net/` | `chess/`, pub packages, `packages/` |
| `ui/` | Flutter and generated localizations; no feature, storage or engine code |
| `features/<mode>/` | `chess/`, `storage/`, `engines/`, `net/`, `ui/`; never another mode |
| `app/` | Everything in `v2` |

Everything in `v2` may use pub packages, the local `packages/` and the
generated `AppLocalizations`. Nothing in `v2` imports the old `lib/` folders. A
lint check (added in step 0) enforces the table.

Cross-mode jumps, such as opening a line from the Trainer in the Builder, are
typed requests handled by `app/`. One mode never reaches into another's state.

## Code rules

These are the lessons from both the old app and the first renewal attempt.

1. **One owner per piece of mutable state.** Each owner is a `ChangeNotifier`
   (or `ValueNotifier`) constructed in `app/` and passed down by constructor or
   Provider. No global singletons, service locators or second dependency
   container.
2. **Pass owners, not bags of callbacks.** A widget receives the owner it uses,
   or an immutable value plus the commands it needs. Never wire a collaborator
   through one supplier callback per field.
3. **No forwarding layers.** A class that only passes calls to another class
   should not exist. Do not build a facade over owners that the widgets could
   use directly.
4. **Widgets do no I/O.** They call their owner. Owners call `storage/`,
   `engines/` or `net/`.
5. **Interfaces only at real boundaries:** filesystem, SQLite, engine
   processes, network, clock and native windows, where tests need a fake or a
   failure. Internal algorithms are concrete classes and functions.
6. **Split a class by job, not by size.** Never use `part` to spread one
   class over several files.
7. **Typed results and failures.** Owners expose typed status (idle, running,
   failed, done); widgets turn them into ARB copy. No English strings in owners.
8. **Async work has an owner and a stale check.** Each action declares
   whether a repeat is rejected, merged or queued. A result that returns after
   its document, position or request changed is discarded. Disposing a widget
   never kills work that should continue, such as a running generation.
9. **Explain non-obvious algorithms next to the code:** representation,
   units, score perspective and a small example. Long explanations go in
   [ALGORITHM.md](ALGORITHM.md).
10. Follow [the Dart conventions](agents/dart.md) for paths, helpers and
    `SafeChangeNotifier`, and [the UI conventions](agents/ui.md) for controls,
    typography, colors, shortcuts and localization. Where those guides name old
    folders, the `v2` equivalents apply.

## Choices already made

| Area | Choice |
|---|---|
| Dependency passing | Constructors, with Provider for Flutter lookup and listening. No Riverpod, Bloc or GetIt. |
| State | Plain immutable values and sealed classes. No blanket code generation. |
| Database | The existing SQLite files, schemas and migrations. Drift only if a store needs a new schema and a migration fixture proves it helps. |
| Files | The existing atomic writer and its SQLite-transaction lock, copied into `v2/storage/`, so the old and new apps lock each other out correctly. |
| Network | `http` behind one client per service, each with its own retry policy. |
| Navigation | A persistent shell with the mode menu, using Navigator. Consider `go_router` only if Back, file-open or restore handling needs substantial custom routing. |
| Localization | ARB and `gen_l10n` from the first screen. English only for now. |
| Credentials | Keep reading the existing SharedPreferences tokens. Moving them to an OS vault (`flutter_secure_storage`) is a separate step with its own migration test. |
| Catalog and visual tests | Widgetbook with production widgets. Native widget tests and a few screenshots; no golden framework unless it saves work. |
| Panels | One `SplitPane` control with minimum sizes, keyboard resizing and saved layout. Build it when the first mode needs it. |

## Data safety

User data is the one thing the rewrite must never damage. These contracts come
from the first plan and from [DATA_INTEGRITY.md](DATA_INTEGRITY.md), which
lists every store, its format and its recovery files.

### Stores and formats

Keep every format and location. The main ones are listed below;
[DATA_INTEGRITY.md](DATA_INTEGRITY.md) has the full list.

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
| Append, import or edit | A locked transformation of current content, or a prepared snapshot validated at commit. Returns the validated before-content and the committed revision together. |
| Undo | Validates that storage still holds the revision the undo entry expects; restores that entry's before-content. On mismatch it rejects and keeps history. |
| Rename, move, delete | The same store and lock, with collision checks, and training references updated in the same operation. Delete is recoverable. |

Results are typed: saved, conflict, collision, invalid document or I/O failure.
Only *saved* clears the dirty state or says "saved". A conflict keeps the
user's draft and offers keep editing, save a copy or reload. Dismissing a
dialog never grants overwrite permission.

A revision is the SHA-256 of the exact bytes on disk (including BOM and line
endings) plus the observed file identity. The native identity probe lives in
`packages/document_file_io`. A changed or missing identity means a conflict,
never permission to replace.

### Undo

Each undoable mutation returns a receipt from the store: the actual
before-content, the committed revision and, for a multi-move batch, each
intermediate state. Undo history is built from receipts, never from
controller memory.

Example: edits A → B → C leave revision rC on disk. Undo C checks rC, restores
B and gets a new revision rB2. B's undo entry then expects rB2, because
the store proved B follows C. If an external edit E happened before C, undo C
restores E, and the older B entry stays disarmed. A failed or uncertain undo
never pops history.

### Required failure tests

Run each against real files in a disposable directory:

- concurrent create of the same name;
- a stale editor save after an external edit;
- two app writers, including the old and new apps at once;
- an external edit before an append, then undo (restores the external edit);
- successive and per-move undo, and an external edit between undos;
- an interrupted replacement, then recovery;
- a queued save after switching chapters;
- a generation that finishes after its source changed;
- a failed read, unreadable file and disk-full error;
- chapter rename, move and delete while a training session is writing.

Tests never read or modify the user's real profile. Use the disposable profile
from `scripts/app_driver.py` or a temporary directory.

### Filesystem notes

- Locks coordinate app writers only. An external editor can still race;
  commit-time revision checks catch what they can, and backups cover the rest.
- Treat Documents as possibly synced or remote. A delayed or failed read is
  an error, not empty content. Never merge or delete conflict copies
  automatically.
- Live SQLite files and lock databases stay in local Support storage. Back up
  SQLite with its backup API, never by copying db/WAL/SHM files.
- Durability goal: survive app or worker termination. On POSIX, write temp,
  fsync, rename, fsync the directory. On Windows, use `ReplaceFileW` and treat
  sharing violations as retryable with a capped backoff and a fresh revision
  check. Power-loss guarantees are not promised.

## Settings

- One writer per key. Two open panels cannot overwrite each other's changes.
- A failed settings read is different from an absent key. A failed read never
  starts analysis or any other work using defaults, and stays retryable.
- A failed save is shown as failed, never as saved.
- Jobs capture their configuration when they start. A preference change during
  a job applies to the next run unless the control says otherwise.
- Secrets never appear in settings snapshots, logs, Widgetbook or exports.

## Engines and background work

- One supervisor owns every engine process. It drains stdout and stderr
  continuously into bounded buffers, so a chatty engine cannot block.
- Cancellation, graceful stop, timeout and kill are defined for each engine
  type. Report cancelled only after the process has actually released its
  resources.
- Engine processes must die when the app dies, including when it is killed.
  Test this on each platform before claiming it. If the Dart process path is
  not enough: on Windows, launch engines in a kill-on-close Job Object; on
  Linux and macOS, use a small supervisor with a parent-liveness pipe and
  process-group kill. Never kill processes by name.
- Continuous analysis updates the UI at most about every 200 ms, with the
  latest snapshot of all MultiPV lines. Completion, errors and `bestmove`
  arrive immediately and are never overwritten by a delayed update. Don't use a
  trailing debounce; it starves updates during a continuous search.
- Workers, ports, timers and subscriptions each have a named owner and an
  idempotent shutdown. Opening and closing a mode repeatedly returns process
  and port counts to baseline.
- Large documents are shown from immutable projections tied to a revision.
  Never deep-copy or compare a whole move tree on each cursor move. Move
  parsing to a worker only when profiling shows it is needed.

## Interface

The rewrite is also the chance to make the app calm and consistent.

- A quiet dark workspace by default (Light and System available), with
  surfaces, text and accent colors from theme tokens. Color only for real
  meaning: errors, evaluation, selection.
- The board, the moves and the current task get visual priority. Keep context
  visible: current file or repertoire, side, orientation, selected line,
  filters and save state.
- Each mode keeps its toolbar and context while opening pickers or settings.
  Back, cancel and mode switches return to the same position and draft.
- Every control has hover, pressed, focus, disabled and busy states. Important
  actions are labelled, and keyboard shortcuts appear in tooltips.
- Distinguish unsaved, saving, saved, failed and conflicted. Show real progress
  and never a fake ETA.
- 12px type floor, 4.5:1 text contrast and usable layouts at 150% and 200% text
  scale. The board exposes squares and pieces to screen readers.
- Follow [the UI conventions](agents/ui.md): typeable choice fields instead of
  dropdowns, visible search inputs and the shared confirmation and name dialogs.

## Order of work

Each step is one bounded piece of work, sized for one agent session. It ends
with checks passing and the work integrated into local main. The product owner
may drop or reorder modes. Remove a dropped mode from this table so it is
never ported.

| Step | Scope | Status |
|---|---|---|
| 0. Skeleton | `main_v2.dart`, `app/` composition, theme and tokens, ARB wiring, shell with mode menu, settings store, file store with locks, engine supervisor with one working engine, `test/v2/` harness, import-rule lint for `lib/v2/` | Not started |
| 1. Repertoires | Library list, search, create, rename, move, recoverable delete; training references follow chapter changes | Not started |
| 2. PGN Viewer | Open collections, filters, navigate, edit and save through the store, undo, engine pane, explorer tab | Not started |
| 3. Repertoire builder | Chapter editing, outline, lines table, workspace recovery, generation launch and results, holes, traps, coverage and audit checks, planner | Not started |
| 4. Repertoire trainer | Sessions, scheduling, history, bulk actions | Not started |
| 5. Study | Chapters, Lichess import and publication, quiz markers | Not started |
| 6. Tactics | Game import, puzzle sets, review, filters | Not started |
| 7. Player analysis, Players & prep | Opponent search and prep sheets, tournaments, people directory | Not started |
| 8. Databases | Master games, TWIC, broadcast collections, Scid export | Not started |
| 9. Engine tournament, Bughouse lab | As today | Not started |
| 10. Accounts and app services | Lichess/chess.com accounts, credential vault migration, updates, diagnostics | Not started |
| 11. Switch-over | `main.dart` starts `v2`; delete the old code and its tests, ledgers and checks; move `lib/v2/` to `lib/`; update COMPONENT_MAP, the agent guides and this file | Not started |

Large modes split into several steps; each step still delivers something that
works in the running `v2` app. Before starting a mode, list what it does today
from the old code and [the component map](COMPONENT_MAP.md), and put that
list in the mode's first commit message or here. That list is the parity
check.

### A mode is done when

1. Everything on its parity list works in `v2`, or the product owner dropped it.
2. It reads and writes the same data as the old app, and both can run at once.
3. Tests cover its user actions, failure paths and every write it makes.
4. The product owner has seen it running (a headless screenshot is enough to
   start) and accepts it.
5. Its `v2` code is smaller than the old code for the same features. If it is
   not, stop and review the design before continuing. Tests and generated code
   are counted separately.

Mark the status column *Done*, with the commit. Only one line changes here;
there is no separate evidence log.

### Known hard problems

The first attempt found these unsolved problems. Each belongs to the step that
owns it:

- **Repertoires:** chapter rename, move and delete must update training
  references, including late writes from an active training session and a
  reused path. Chapter relocation has no stable source identity yet.
- **PGN Viewer:** opening another file, pasting, recovery and close must stop
  delayed collection, filter, index and analysis work so stale results never
  appear.
- **Builder:** autosave must be bounded. Replacing a debounce with an
  unbounded queue of PGN snapshots is not acceptable.
- **Builder:** generation publishes only against its source and run identity,
  never over an edited companion PGN. Legacy artifacts stay readable; legacy
  runs cannot be resumed.
- **Accounts:** tokens are plaintext in SharedPreferences today. Migrate one
  account at a time: write the vault, read it back, then remove the old key.
  Restart at any point loses nothing.
- **Platforms:** engine cleanup after a killed app is verified only on Linux.

## How agents work on this

- **One step per session, with a named end.** Give a goal like "Repertoires:
  list, search and create; tests; integrate; stop". Never "finish the plan".
- **Before integrating into main,** run `scripts/ci.sh analyze lint` and the
  full `scripts/ci.sh test` (about 8 minutes). A known failing test blocks
  integration.
- **Status lives in this file's table.** Commit messages and tests are the
  record. Don't write evidence diaries, checkpoint narratives or per-step
  reports.
- **Review:** one independent review of the diff when a mode is marked done.
  No standing panels of review agents.
- **After a context reset,** re-read this file and `git log`. Earlier
  questions in the conversation have already been answered.
- **Ask the product owner** about scope, dropping modes and visible design.
  Decide implementation details without asking.

## References

- [DATA_INTEGRITY.md](DATA_INTEGRITY.md): stores, formats and recovery files.
- [COMPONENT_MAP.md](COMPONENT_MAP.md): what the old app does, for parity lists.
- [ALGORITHM.md](ALGORITHM.md): tree-generation pipeline.
- [Flutter architecture recommendations](https://docs.flutter.dev/app-architecture/recommendations).
- [Refactoring UI](https://refactoringui.com/) and
  [Nielsen's usability heuristics](https://www.nngroup.com/articles/ten-usability-heuristics/).
- [SQLite: how to corrupt a database](https://www.sqlite.org/howtocorrupt.html)
  and [WAL](https://www.sqlite.org/wal.html).
- [Windows Job Objects](https://learn.microsoft.com/en-us/windows/win32/procthread/job-objects)
  and [ReplaceFileW](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-replacefilew).
