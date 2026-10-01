# Architecture renewal: the sole app

**Source retirement: 2026-09-30.** The owner explicitly requested finishing
the v2-only switch and deleting v1, without legacy/backward-compatibility
requirements. V2 now lives directly in `lib/`, starts at `lib/main.dart`, and
has its tests directly in `test/`. Release targets, the headless driver and
local checks use that entry point. Publication/version changes are separate.

## Decision

V1 source, old-only assets/tests, Widgetbook, localization generation and
old architecture/debt ledgers are retired. The switch helper was consumed and
removed. V2's own storage, recovery, restart and algorithm tests remain; tests
that executed v1 as a live oracle are retired or now assert independent values
and current-format round trips. Frozen fixture data can remain useful without
shipping old code.

No profile migration, folder move or user-data deletion is part of this change.
Current document/training persistence remains authoritative. The app no longer
inspects v1-only operation receipts or asks users to reopen a deleted app;
foreign metadata is left untouched. Current-app recovery and write guards remain.

This owner decision supersedes the older feature-parity and switch-over gates
below. Remaining v1-only conveniences are backlog, not prerequisites for source
retirement. The historical implementation rows preserve their evidence and
remaining product scope; they do not certify fresh native Windows/macOS or scale
acceptance. Current development guidance is in [the agent guides](agents/README.md)
and [component map](COMPONENT_MAP.md).

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

## Source ownership after retirement

There is one implementation under `lib/`. Do not recreate a parallel v1 app,
legacy adapters, localization generators or old debt ledgers. Retained wire
formats, IDs and fixtures do not imply a requirement to run old code. New work
uses the ownership and data-correctness contracts below.

## Product shape

One **workspace**: a board, a move tree, an engine pane, an explorer pane and
one side panel, over one **document** (a PGN file with a revision from the
store). This is the Lichess model, where analysis, study and practice share
one board, tree and engine. Modes are what fills the side panel and what drives
the workspace:

| Mode today | In `v2` |
|---|---|
| PGN Viewer | Workspace + a game list (collections, filters) |
| Repertoire builder | One mode with Repertoires, named for the building (owner, 2026-09-21 and 22): the library list, the chapter outline and the Replies tab (Maia shares, gaps, Next gap) over the workspace; generation writes draft chapters, no tool panels |
| Study | Workspace + the same chapter outline + Lichess import/export and quiz markers |
| Repertoire trainer | A training session driving the workspace in quiz mode |
| Tactics | A puzzle session driving the workspace, plus a puzzle list |
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
it uses. What lays panels out — the shell, `WorkspaceView`, the Actions
menu — takes the `Workspace` value (`workspace/workspace.dart`), which only
holds the owners below, so a new owner is one field there rather than one
more parameter on every layer.

| Owner | Holds | Never holds |
|---|---|---|
| `DocumentSession` | The parsed move tree as an immutable value, the cursor, how far the line is shown while a puzzle asks for the rest (`shownTo`), the store revision, dirty state, undo receipts | Engine output, explorer data, panel state |
| `EngineAnalysis` | The running engine job for the cursor position and its latest snapshot | Anything about the document |
| `Explorer` | The explorer query for the cursor position, its state and the session's answers (`ExplorerAnswers`, asked through `ExplorerDatabases`) | Anything about the document; a listed game being kept as a file (`GameFetcher`) |
| `Replies` / `GapHunt` | The Maia table for the cursor position / the walk over the open chapter and the gap `Next gap` marked; both ask one `ReplyModel` cache | A copy of the tree or cursor |
| `WorkspaceLayout` | Which panel is open and the split sizes | Data |
| `FileFilter` | The game filter's rules for the open file and which of its games pass them; cleared when another file is opened, pasted or closed | The games themselves |
| `FileTree` / `MyGamesTree` | The explorer's `This file` and `My games` trees. `This file` is indexed when a file opens, from the games already read, a turn at a time between frames (`IndexBuild.ofLines`), once the moves of a file just opened have arrived (`movesBeingRead`); an index stays with the list of games it numbers, so a tab gone back to answers at once, and any changed game list drops it. `My games` is read and indexed on its own isolate the first time it is asked | The document, the cursor |
| `ParsedFiles` (in `DocumentSession`) | The parse of each file read lately, by path, reused only when the text read from disk is the same again: a tab, Back or recent file gone back to is not parsed again, and its games are the same list. Bounded by characters of text; a file changed anywhere is parsed again. A large file shown one game at a time opens from its headers (`readChapterShowing`): the game on the board reads its own moves, and every other game's are read on another isolate and handed to the same `ChapterLine`s | Revisions, drafts, anything on disk |
| `WorkspaceRequests` (`app/workspace_requests.dart`) | The mode, the status line, and every cross-mode request that puts a document on the board or takes it off (a list's click, Open/Import/Paste, an explorer game, Close file), each answering a sealed `RequestResult`; the leave question goes through `ExitGuard`, the side question and the clipboard through `WindowInput` | The document, panel state, dialogs |
| A panel's owner (`GenerationRun`, `TrainingSession`, `HoleHunt`, …) | That tool's state, keyed to a document revision | A second copy of the tree or cursor |

An owner notifies only for what its listeners show. `DocumentSession`
notifies its own listeners when the document changes (another chapter or
game, an edit, a refusal, a flip) and `cursorListenable` when the cursor
moves; `anyChange` is both, for views of the position (board, engine,
explorer, replies, move note, comment field). A derived owner such as
`ChapterOutline` notifies when its output changes, not whenever its inputs
do. A list highlights its current row through `ui/selection.dart`, so a
cursor move redraws two rows, and builds its rows lazily
(`ListView.builder`). A `State` that reacts to an owner with more than a
rebuild uses `ui/listening_state.dart`, which follows the widget across
`didUpdateWidget`.

Split an owner when it has two jobs, which its fields and its listeners
show — never to get under a count. The old `PgnViewerController` (1,341
lines) is what this table prevents. A split whose second half only answers
the first's calls is a forwarding layer (rule 3): `Library` and the
`LibraryWrites` cut from it to pass a ten-field cap were merged back on
2026-09-22, because every `Library` command was `_writes.x()`.

Committed document changes have a separate owner from an active editor.
`storage/DocumentRepository` wraps the filesystem adapter and publishes typed
create/save/move/delete events only after success. `RepertoireCatalog` coalesces
those events into a committed listing; a change during a read invalidates that
read, and the next publication retains the whole change batch. Library search
and busy state do not invalidate the catalog. Books, training and repertoire
indexes consume it independently. A whole-file autosave already represented by the open
session does not restart a training sitting; a sibling mutation or a course
file save does reload the scope. Explicit refresh handles changes made outside this process.

`AppParts` is the composition root. `WorkspaceRequests` coordinates navigation,
including dirty-draft decisions and desktop file-open requests; request tickets
cancel superseded opens even when the latest request selects the current file.
`DocumentSession` owns the active editor, while `document_projection.dart` owns
file/section projection and `document_history.dart` owns held edits and board
undo. These helpers have no widget or persistence side effects.
`DocumentTabs` keeps file destinations, cursors, viewer drafts with their original
save revisions, and independent temporary analysis boards. Analyze copies the
whole current game (variations and comments included), at the current move;
changes in that tab never write the source. Tabs have left-aligned compact labels,
visible close buttons, drag ordering, and a plus button. Pane tabs use the same
strip without close buttons (right-click Close tab, or middle-click) and with neutral surface fills and stronger selected labels (source selectors also
use neutral selection fills); closed tools reopen
from its plus menu. A tab picked from the plus menu of a lone pane opens under it
in a pane of its own, and joins the pane it was picked in once there are several;
the plus menu also adds an empty pane. Action panes also grow through Split right
/ Split below in the tab context menu, up to four panes. Dragging a tool tab reveals docking
targets over the pane bodies; dropping in another pane moves it, and dropping on
an edge splits that pane. A split moves the tab when its source has other tabs;
a lone tab is shown in both views. Right-clicking a tool entry in Actions or the
plus menu offers named pane destinations. A secondary pane whose last tab leaves
collapses, and the main pane takes over the tabs of the pane its own last tab
moved to; Close pane and Join all panes return their tabs to the primary pane.
Explorer filters remain independent per pane. Collection Analysis stays in the
primary pane and pinned mode tabs stay put. Layouts remain window state. Flip board and Analyze are
Actions entries; the Viewer's menu omits Analyze because its moves are already
held unsaved, read-only files included. The Viewer offers reading and analysis,
without repertoire/training commands. TWIC SQLite reads run on worker isolates so a busy database cannot
hold up filter controls or menu dismissal.

`PendingWrites` belongs to the application, not to a mode. Accepted writes of
user data (documents, ratings, books, settings, usernames) stay tracked after
their screen is disposed. Closing disables input, pauses producers, flushes the
document and waits for those writes before stopping engines; only a write that
failed is asked about. A line move or study rename the store answers
`Unfinished` is not: it is recorded, and recovery finishes it after a restart
too. Derived writes (search trees, finds, download caches) are waited for but
never asked about.

## Data correctness contracts

Keep the shared workspace, pure chess code, concrete owners and the existing
storage formats. A command is correct when its reads, its dependent writes and
its recovery are correct together; directory boundaries alone do not give that.
The ideas are the usual ones from *Designing Data-Intensive Applications*
([chapter 12](https://www.oreilly.com/library/view/designing-data-intensive-applications/9781491903063/ch12.html)):
know which bytes are the system of record, rebuild derived views from them,
make retries idempotent, and give a document change and its reference changes
one recoverable boundary. No broker, event store or new database is needed:
SQLite transactions where data already shares one database, guarded file
replacement for the formats that must stay files.

### Rules

1. **Never lock the app.** A problem affects at most the one item involved —
   one document, one save, one job — never every open, every save or startup.
   Preferences and derived data never block anything.
2. **Never delete user data.** PGNs, training progress, puzzles and saved
   matches are kept. A record the app cannot read, finish or replay is moved
   whole into `Support/recovery-quarantine/<time>/`, logged, and the app carries
   on without it.
3. **Recover automatically.** Unfinished operations are finished on the first
   access after a crash; leftover staging files are cleaned or adopted. The user
   is never asked to repair a file by hand.
4. **Derived data may be discarded.** Generation trees, finds, download caches,
   indexes and staging files are rebuilt, refetched or recomputed. A failed
   write of derived data is a log line, not a blocked feature.
5. **Saves are Obsidian-style.** Debounced, one write per burst, byte-heavy work
   off the UI isolate, no read-back verification, no gzip.
6. **At most one short message** where the user must act; no status sentences,
   no extra Retry buttons. The log holds the detail, never secrets or PGN text.

### Authority

Rebuildable does not mean cheap; it means a failed write of it may be dropped.

| Area | Authoritative (kept, quarantined if unreadable) | Derived (may be discarded) |
|---|---|---|
| Workspace, viewer, library, study | PGN bytes, kept versions, required references | Parsed tree, filter, cursor, selection |
| Books | Book definitions and membership | Expanded chapter set, counts |
| Repertoire training | Schedule, streak, history and attempt files | Due queues, scope lists, lesson board |
| Tactics | Puzzle PGN, review fields, analyzed-game markers | Puzzle queue, mining computation |
| My games | Account usernames | Downloaded games cache, freshness dates, opening index, book comparison |
| Generation and checks | Draft chapters written | Search trees, finds, gaps, coverage, evaluations |
| Bughouse | Saved matches and saved analysis with provenance | Live search, archive queries |
| Settings and accounts | Nothing irreplaceable: defaults are always a valid start | Form state, connection status |

### Consistency the user can observe

| Operation or read | Guarantee |
|---|---|
| An edit on the active board | Reads the current draft; its save state is shown separately. |
| A successful durable command | Its required writes are complete; a dependent command reads the committed result. |
| Training after an accepted rating | Later reads see the rating; a failed rating write is retried in order, not lost, and follows a chapter rename, move or delete made while it waits. |
| Rename, move or committed undo | Document and references form one operation; a crash between them is finished on the next access. |
| Catalog, gaps, explorer, book check | Refresh asynchronously; a late answer never replaces a newer one. |
| Engine or network response | Published only into the request it answers. |
| Reopen after a crash | Unfinished operations are finished or quarantined before the affected file is read. |
| External edit or sync conflict | Revalidated; the user's draft is kept as a conflict, never overwritten. |

An in-process notification is a wake-up hint, not proof of a commit; a new
consumer rebuilds from source.

### How a save and its recovery work

1. **Edit.** The draft changes at once; a one-second clock starts. More edits
   restart it. Leaving the file, the window losing focus or closing ends the
   wait.
2. **Write.** One write per burst: check the revision on disk against the one
   loaded (a changed file is a conflict, never an overwrite), copy the version
   being replaced into Support, write a staged copy beside the file, flush it,
   rename it over the file, flush the directory. Nothing is read back.
3. **Several files.** A command that must change more than one file (a
   rename with its book and training references, a move, a delete) first
   writes a small record under Support naming each participant's before and
   after state, then applies the steps, then removes the record. Training
   answers are not journaled: each training file is replaced atomically.
4. **Crash.** Each access lists the record names (never their contents);
   the recovery gate finishes them on the first access, when a record
   nobody here has seen appears, and when one left unfinished (a failed
   command's, or one it could not finish yet: a file held open) is due
   again: at each of the next three accesses, then after 5 seconds doubling
   to 5 minutes. An access that reads or writes a file an unfinished record
   changes tries that record first, so the next read sees what the command
   meant. A pass that could not run (a lock another app keeps) is tried
   again after 30 seconds, waiting longer each time, and nothing is tried
   meanwhile. What is owed lives in memory per profile (`RecoveryLedger`)
   and the folders stay the truth. Until a record is finished, a create,
   save, move or delete of a file it renames or rewrites whole (an edit's
   PGNs, both ends of a move) fails as in step 5; training writes, Books
   edits and other moves go on, and so do reads. A record owed for five
   minutes stops guarding when a write meets it: one not yet applied whole
   is undone and set aside, each file holding what it wrote put back after
   its bytes are kept as a version, and one that has lets plain saves pass.
   A file that stays unreadable is never written: as the last one rewritten
   it is left as it is while the rest are undone, and before another it
   alone stays guarded until it reads again. A record set aside whose
   move into `recovery-quarantine/` fails is marked `<id>.aside`, guards
   nothing, and is only moved later, never finished again. A move the
   old app left pending in `repertoire-mutations/` is only the old app's to
   finish: it guards both its ends the same way, never tried or stopped
   here, and its receipt is read again when that folder's names change or a
   write meets it. Anything else the old app left is only logged and
   costs no pending move its guard.
   For each renamed or rewritten file: still at "before" → apply; already at
   "after" → accept; anything else (an edit by another program) → the files
   the record already rewrote are put back where they still hold its bytes
   (what it wrote is kept as a version), the record and its data go to
   `recovery-quarantine/`, the log says why, and access continues. The
   training rows and book selectors that follow them never stop a record:
   still at "before" → written as planned; changed since (an answer, another
   book) → planned again from what they hold now, by the change the record's
   own snapshots show; not their format at all → left as they are, and the
   record, finished, is kept in `recovery-quarantine/`.
   A participant that cannot be read right now (held open, or changing while
   read) leaves the record pending for the next access.
   A staged copy left beside a file is removed or overwritten by the next
   write.
5. **Fail.** A write that fails keeps the draft on screen with one short
   message; the next edit or save tries again. Closing asks only when a
   write the user made is still unsaved.

Required application states are *committed*, *rejected* (nothing changed) and
*unknown* (a lost acknowledgement: retry with the same operation, never a new
one that would append twice).

### Identity and undo

Paths, course sections and `[LineID]` stay the shared identity with the old
app. A content hash identifies a version, not a document. A rename or move
produces an explicit old-to-new mapping that books and training follow; copy
makes a new document; delete moves the file into the repertoire's quarantine
and restore brings it and its references back. Draft undo changes only the
draft; committed undo is a new guarded operation, refused when a participant
changed since, keeping the history.

### Background work

`PendingWrites` is app-lifetime: accepted authoritative writes outlive the
screen that made them, and closing waits for them. Derived writes are only
watched, so the way out waits for one in flight but never asks about a failed
one. Every job captures its input when it starts. Generation shows a run as
done at once; its tree and finds are saved behind it. Mining writes a game's
puzzles and its analyzed marker in one replacement. My games reviews the games
it downloaded even when the cache could not save them. The engine supervisor
owns each process from spawn to confirmed exit; finite searches have deadlines,
continuous analysis an explicit stop. Hivemind's hashes for saved-analysis
provenance are worked out once per file version and never fail a start.

### Derived views

An index or analysis result names its inputs (document revisions, membership,
corpus, settings) and publishes only while they still match; otherwise it is
recomputed. Invalidate by affected input: a sibling deletion recomputes gaps, a
membership change recomputes the book scope, a cursor move does neither. A
failed rebuild keeps the last view; an unavailable source never becomes an
empty success.

### Compatibility and acceptance

The old and new apps share one profile and take the same locks in the same
order. Public formats and paths stay compatible; private recovery records are
versioned, and an unknown one is quarantined, not obeyed. Tools and MCP writers
go through the same store or are treated as external writers. Logs name the
operation and file, never credentials or PGN text.

| Proof | Observable invariant |
|---|---|
| Rename section, then undo while its book is active | Name, membership and training scope agree at each completed boundary. |
| Hold a rating write; trigger two scope reloads | Neither reload shows progress older than the accepted write. |
| Delete/import a sibling that answers a gap | Gaps and Replies converge without reopening the chapter. |
| Kill a worker after each durable step; reopen twice | State is recovered or quarantined; the app opens; nothing is duplicated. |
| Corrupt `settings.json`, a recovery record or a staged file | The app starts, the bad file is kept aside, everything else works. |
| Fail a derived write (tree, finds, download cache) | The feature keeps working; the next run tries again. |
| Repeatedly open/close modes and jobs | Process, subscription and queue counts return to baseline. |

Use real temporary profiles for storage and restart tests, controlled
completions for concurrency, and production `AppParts` wiring for user
sequences. Process-kill tests prove crash recovery, not power loss on every
device; Windows and macOS durability is not yet verified.

## Layout

```text
lib/main.dart          entry point: flutter run -t lib/main.dart
lib/
  app/                    composition, window, mode menu, cross-mode requests
  ui/                     theme tokens and shared controls
  diagnostics/            the log facade every other folder reports through
  chess/                  pure Dart: PGN, positions, moves, evaluation, generation
  storage/                PgnDocumentStore, SQLite stores, settings, credentials
  engines/                UCI supervision, pools, analysis streams
  net/                    Lichess, chess.com, US Chess and other clients
  workspace/              board, move tree, engine pane, explorer, side-panel host
  features/<mode>/        one folder per mode: panels, sessions, lists
test/                  mirrors lib/
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
`diagnostics/`. `dart:io` is for `storage/`, `engines/`, `net/` (sockets:
the Lichess login listens on a loopback port) and `app/`; files are written
only in `storage/`. Nothing in `v2` imports the old `lib/` folders;
`scripts/check_v2.py` enforces this table. The one exception is `lib/main.dart` importing
`lib/debug/agent_driver.dart`, the headless-test hook shared with the old app.
Cross-mode jumps (open this line in the builder, train this chapter) are typed
requests handled by `app/`: `WorkspaceRequests` owns them and `Shell` only
draws its mode and status and maps the lists, the explorer and the keys to
its commands. Questions it puts to the user come in through an interface
(`ExitGuard`'s `DraftQuestion`, `WindowInput`), so the flows are tested
without widgets. The way out of the window (`AppExit` in `app/app.dart`) waits for
the draft, then stops the engines, then closes the log, once however often
it is asked.

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
| Theme | Dark only; no Light or System theme is planned (owner, 2026-09-22). Tokens in `ui/`. Built in step 0 only as far as a board and a move list need; extended by later steps. |
| Catalog and visual tests | Widgetbook on production widgets, added at step 12. Widget tests before that; no golden framework. |

## What clean code means here

Clean code is code a maintainer reads once and can predict. Three questions
decide it, and the reviewer answers each with a file and line, not an opinion.

**Can I read it?**

- Names say what; comments say why. A comment that explains *how* a block
  works means the block should be rewritten (kernel `coding-style`). A
  non-obvious algorithm gets a short paragraph with its representation, units
  and one worked example beside the code (Knuth).
- A function does one thing and usually fits on a screen. The checker fails
  past 80 lines or 3 levels of nesting; aim for 5 parameters or fewer. Extract a piece when it has a name and a
  contract, not to hit a length; one long linear function that runs top to
  bottom once is better than six that share state through fields (Carmack).
- A file holds one type or one group of closely related functions. Never
  `part`. The checker fails past 1,000 lines, a backstop against a god file
  rather than a target: splitting one job across files to get under a
  number costs more reading than it saves. The caps were 400/50 until
  2026-09-21 and 600/50 until 2026-09-22; both times commits went in only
  to get under them (a shortened comment, a session split, a `Writes` half).
- Composition has three layers (ports and adapters; lila's per-module
  `Env`). `app/environment.dart` is every way out of the app — files,
  dialogs, sites, engines, Maia, the clock, timings — as one
  `AppEnvironment`; `.native()` builds the real ones. `app/app_parts.dart`
  (`AppParts`) puts the app together over any environment in order and
  disposes it in reverse, calling `app/mode_wiring.dart` and
  `app/workspace_wiring.dart`, each of which builds its owners and
  connects them. `app/app.dart` hosts the window over `AppParts`. The
  window tests build a scripted environment and the same `AppParts`
  (`test/support/window_fixture.dart`), so they test the real wiring.
  A new owner goes in the wiring it belongs to; a new way out of the app
  is a field of `AppEnvironment`.
- A mode is a `ModeView` (`app/mode_view.dart`): it owns its reading-card
  tabs and answers for its list, Actions menu, own tab bodies and flags.
  The shell asks the mode on screen instead of switching on which mode it
  is; a new mode is a subclass and one arm of `modeViews`.
  `WorkspaceView` takes one `WorkspaceHooks` value for what the window
  adds to the workspace.
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
- After an `await`, transient reads and computations check their input/request
  identity before publishing. Accepted durable operations instead follow their
  commit/recovery protocol even if the initiating view has gone. Every
  subscription, timer and process has a named owner and an explicit end;
  disposing a view does not dispose durable obligations it initiated.
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
| `lib/chess/pgn/game_tree.dart` | Immutable values (`MoveNode`, `NodePath`, `GameTree`), doc comments that say why |
| `lib/chess/pgn/pgn_reader.dart` | A pure function over a package, typed issues instead of exceptions |
| `lib/chess/pgn/tree_merge.dart` | One algorithm, one paragraph explaining it |
| `lib/workspace/document_session.dart` | An owner: two fields, commands, derived getters, the document and the cursor notified apart |
| `lib/features/library/library.dart` | Sealed states and results, a stale check after `await` |
| `lib/workspace/move_tree_view.dart` | A widget built from an owner, private sub-widgets, no I/O; lines built once per tree, a cursor move redraws two moves |
| `lib/app/workspace_requests.dart` | Cross-mode requests as an owner: sealed results, questions behind an interface, a disposed check after every `await` |
| `lib/storage/chapter_files.dart` | An interface at a real boundary (the filesystem) with sealed results, and its one adapter |
| `lib/engines/uci_engine.dart` | A protocol over a pipe: serialised searches, each with its own stream, so stale output cannot land |
| `lib/workspace/engine_analysis.dart` | An owner over a background job: enable/disable, stale checks, a 200 ms snapshot buffer, `dispose` |
| `test/workspace/engine_analysis_test.dart` | Fake time, a scripted double, assertions on the owner and never on private state |

`scripts/check_v2.py` enforces the numbers below and the import table; run
it before saying a step is done. `scripts/ci.sh lint` runs it and its tests
(`scripts/test_check_v2.py`).

### Reviewer checklist

The independent review of a finished step answers these, each with a location:

1. Any file over 1,000 lines, function over 80, nesting over 3?
   (`scripts/check_v2.py` finds all three. A `group(...)` or `test(...)`
   body in a test file is a function; `main()` and `group(...)` bodies are lists of cases and are not.) Any split made
   only to get under one of them, or a file too small to be read on its
   own?
2. Any owner holding data that belongs to another owner in the
   [workspace table](#workspace-owners)? Any mode importing another mode's
   folder? (`scripts/check_v2.py` finds the second: shared code moves to
   `workspace/` or `ui/`.)
3. Any `await` not followed by a stale check? Any subscription without a
   `dispose`? (`scripts/check_v2.py` finds one kind: a `State` whose
   `initState` calls `widget.<owner>.addListener` must use `ListeningState`
   (`ui/listening_state.dart`) or implement `didUpdateWidget`, so a widget
   rebuilt with another owner stops hearing the old one.)
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

User data is the one thing the rewrite must never damage. The target guarantees
across multiple stores are defined in [Data correctness contracts](#data-correctness-contracts);
the sections below specify document formats and individual storage operations.
[DATA_INTEGRITY.md](DATA_INTEGRITY.md) lists every store, its format and its
recovery files.

### Stores and formats

| Data | Where | Must preserve |
|---|---|---|
| Repertoires and chapters | Documents `repertoires/` folders: chapter PGNs, or one course PGN whose games name their chapter (see [Course files](#course-files)) | Comments, variations, NAGs, unknown headers, machine tokens such as `[%eval]`, `[%pv]` and `[%clk]` |
| Studies | Multi-chapter PGNs in Documents `studies/` | Lichess export tags, root comments, per-chapter orientation |
| Games | Support `app_games.db`, collection-scoped with position indexes | Tactics source games that have no other copy |
| Training | Review, progress and history CSVs and attempt JSONL, keyed by file path and line id | Scheduling and history across chapter rename, move, split and delete, and across edits that would change a derived line id |
| Generation output | Versioned bundles via the artifact repository, plus legacy chapter-side files | Readability of old artifacts; user edits to companion PGNs |
| Settings and accounts | V2 Support `settings.json`; existing SharedPreferences account/credential keys | Existing keys and values; no implicit account migration |
| Recovery | Atomic-write journals, quarantine, `Support/recovery-quarantine/` for records and settings the app could not read, PGN recovery snapshots, SQL `game_trash`, schema-upgrade backups, the training records a relocation replaced in Documents `.cap-reference-history/<operation>/`, and the Support note naming a move whose training rows are not rewritten yet | Each keeps its purpose; none of them is the version history — see [Backups](#backups) |

### Course files

A repertoire is a folder; a chapter is a `.pgn` in it, or — for a course —
the games of one file that carry the same `[ChapterName]` (the Lichess study
export's tag). One rule, `chapterSections` in `chess/pgn/chapter_sections.dart`:
each named chapter retains `(path, section)` identity even when it is the last
chapter left. Untagged games form the unnamed section. A stale explicit section
never opens a different surviving chapter; older whole-file references still
read a singleton file. Book membership therefore survives sibling deletion.

Listings traverse nested repertoire folders without following symlinks or
entering hidden recovery or staging folders. Like v1, a chapter is any `.pgn`
whatever the extension's case, except `_raw_games` sidecars. Root-level PGNs move to
`<name>/Main.pgn` through the store, carrying training references and backups;
a collision leaves the original visible. Rename, move, delete and restore of a
file or folder go through `FileRelocations`, which writes a record under
`Support/relocation-writes/` naming the PGN or folder inventory, the four
training files, book selectors and backup ownership before and after, then
applies them and removes the record. The record is carried by
`OperationJournal` (`storage/operation_journal.dart`): the file or folder is
the move's pivot, renamed first and guarded until it lands; the training
rows, book selectors and kept versions are references that follow it,
exactly as planned or planned again from what they hold now. Nothing is
applied while any of them cannot be read: a participant unreadable for now
(a permission, a sharing violation, a folder entry that cannot be read)
keeps the record for a later try, and a kept-versions folder the disk
refuses for now keeps it too. Only a pivot holding something else sets the
record aside. After a crash the recovery gate finishes each record on the
next access, each under the folder locks its command took, or quarantines it
(see [How a save and its recovery work](#how-a-save-and-its-recovery-work)).
A retry that lost its operation id takes the pending move over. A move owed
for five minutes stops guarding when a write meets it: one not yet landed is
set aside, even while a file in its folder stays unreadable, and one that has
landed writes its kept versions down as owed (`Support/backup-moves/`), then
`<id>.following` beside its record, so plain saves over its file may pass,
versions they keep are merged with the moved history, and a later finish
follows its training rows and book selectors without looking at the file
again, leaving the kept versions to what was written down (a build without the marker
sets the marker aside and finishes the record by its own rules). Imports
are written into a `.import-` staging folder and renamed into place; the first
listing of a run removes staging folders older than the run. They belong to
imports a crash interrupted, which never completed or showed, so they are
treated as disposable even when, as for pasted text, no other copy exists.

- **One file, one write path.** A chapter of a course file opens as a
  `SectionView`: its games in file order as an ordinary `Chapter`, so every
  edit works unchanged. `spliced` puts the edit back into the file, and the
  store checks the whole file against the file-level arrangement, as it does
  for a chapter file. Games the edit kept stay in their own places; a new
  game goes at the end of the file carrying the chapter's name.
- **Chapters are tags.** Moving lines to another chapter of the same file
  (`linesNamed`), renaming a chapter (`sectionRenamed`) and deleting one
  (`sectionRemoved`) each change one file. Deleting is an edit that undo takes
  back, not a quarantine. A course chapter does not move to another
  repertoire without its file.
- **Line ids are written down.** A game without an id header is trained under
  an id worked out from its main line and its place in the file, counted as
  the old app's parser counts games (`oldAppGameIndexes`: text above the first
  game that is not a comment line counts as one, and claims its id first).
  Ids follow the old app's rule exactly (`trainedIdsOf`): the last tag under
  an id key wins, castling with zeros counts as `O-O`, and a game whose header
  block the old app ends early (a bare backslash in a value, a line that is
  not a tag) is identified as the old app reads it; one it reads no move in
  is no line in either app. Any edit that would change that id — moves
  edited, a game above it moved or removed — first writes `[LineID]` with the
  current id (`withIdsPinned`) where both apps read it; a game whose `[Event`
  line the old app cannot read as a tag has no such place, and is edited or
  moved as it is, its id changing in both apps. Progress therefore stays
  keyed by file path and id, the format the old app shares, and chapter
  changes inside a file never touch the training files.
- **Import writes one file.** A course or study with several chapters is
  written as `<repertoire>.pgn` with `[ChapterName]` and a distinct `[LineID]`
  on every line (`courseText`); a source id another line already claimed is
  replaced by the id the line is trained under. A one-chapter import is a
  chapter file as before.
- **The old app** lists a course file as one chapter until step 14, and trains
  it under the same keys.

### Backups

The user never asks for a backup and never names one. Losing work is a bug in
this section, not a mistake the user made.

- **Every replaced byte is kept.** A save, append, import, rename or delete goes
  through the store, and the store already returns the validated before-content
  of the file it replaced. That content is what gets recorded. A write whose
  backup could not be recorded does not proceed; it returns an I/O failure like
  any other. Games appended to the downloaded games cache (`games_library/`)
  replace no bytes and can be downloaded again, so they keep no version.
- **Backups live in Support**, under `backups/<document id>/`, one plain copy
  per version named by commit time and content hash, with a small index per
  document. Copies are not compressed: PGN is small, disk is cheap, and a
  compressed copy is one more thing that has to work before a save may go
  ahead (versions an earlier build gzipped are still read, by their magic
  bytes). They are never written into Documents: a synced folder must not
  gain files the user did not make, and a restore must work when Documents is
  the thing that went wrong.
- **Identity, not path.** Versions follow the document's identity, so a rename
  or a move keeps one history instead of starting a second one. A history that
  cannot move at once never holds the document back: it is noted under
  `Support/backup-moves/` and the next recovery pass (at start or after a
  failed access) moves it, merging it with any versions the document kept
  meanwhile. Until then a new file at the old path would add to it.
- **Unchanged content costs nothing.** A save whose bytes hash to the newest
  stored version records nothing.
- **Retention is explicit.** Version history offers cleanup under the Documents lock,
  keeping the newest 100 versions and everything from the last 90 days. Saves do not prune.
- **Restore as a copy.** The builder's `Version history` shows each whole-file PGN version
  with time, size and a checksum-verified preview. Restore imports it as a separate repertoire,
  leaving the live document and training records intact for comparison.
- **SQLite** (`app_games.db`) is snapshotted with SQLite's backup API, not by
  copying db/WAL/SHM, when the newest snapshot is older than a day.
- **What it is not:** not the undo history (store receipts, in-session), not the
  generation artifact history (versioned bundles, per run), not the recovery
  files above (interrupted writes and deletes). Those keep their own purposes.

Step 2 owns recording; the builder exposes version preview, restoration as a copy and
explicit retention cleanup.

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

A course-section rename commits its PGN and the matching `books.json`
references as one compound operation (`Support/compound-writes/`), and
`savePair` does the same for exactly two PGNs and the training rows of the
lines it moves; undo is the guarded inverse, refused when any of them
changed since. `CompoundWrites` hands the record to `OperationJournal`: the
PGNs are its pivots, rewritten from their exact recorded bytes and guarded
until they land, source before target; the book selectors or training rows
follow them, renamed or moved again as they are now when they changed
meanwhile (`sectionRenamesBetween`, `lineMovesBetween`). A pair whose
target another writer changed puts its source back before it is set aside,
so moved lines are never in neither file. Training paths and line IDs do not
change on a section rename.

For an ordinary save, the store does not read the file back after the
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

A revision is the SHA-256 of the exact bytes on disk. The same bytes have the
same revision, but two copies remain different documents with their own
references and histories. Different bytes from those expected are a conflict,
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

A comment lives where it lived. Reading shows the note of the first game that
holds one on a move several games play. An edit rewrites the games holding that note, or the first
game that plays the move when none holds one; a game holding a different note
keeps it, because the user never saw it. Arrows and circles follow the same
rule.

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
  retried with a capped backoff and a fresh revision check. A plain document
  save or create whose rename landed is reported as done, with a warning, when
  only the directory flush fails. A directory flush the filesystem does not
  support (EINVAL, ENOTSUP or ENOSYS, as on VirtualBox shared folders and some
  CIFS mounts) is skipped with one warning per folder, as on Windows; compound
  and relocation writes still fail on any other flush error. A landed move
  whose old folder was removed since is flushed from its nearest remaining
  parent, and an operation that already lets saves pass follows its
  references without flushing its pivots.

V2 desktop compatibility (2026-09-25): the native file adapter normalizes
Windows long/UNC paths, preserves ACLs and alternate streams on replacement,
retains a recovery copy for partial replacement failures, and rechecks content
and identity between bounded sharing retries. macOS stages use `F_FULLFSYNC`.
Names have both a character cap and a UTF-8 byte budget, leaving room for
staging and recovery names. macOS retains App Sandbox with outgoing network,
OAuth loopback-server and user-selected file permissions; Finder PGNs enter
the same guarded import route as Windows and Linux. External files are copied
into the app's Documents folder, so recent imported files do not require
persisting grants to their external originals.

`.github/workflows/desktop-contracts.yml` runs native v2 document, locking,
login, exit and desktop integration checks on Windows 2022/2025, macOS and
Linux as a release gate. The non-publishing `windows-check` branch runs its
Windows cases too. `--self-test-desktop` in the release executable uses a
disposable temporary profile to check long Unicode document paths, save on
exit, reopen, rename/recoverable delete, bundled Stockfish, Maia and actual
login callback sockets. `tools/test_desktop_bundle.py EXE --report REPORT`
runs that check, preserves its JSON result, and fails on a missing report,
timeout or failed step. Windows checks exercise both portable and installed
builds, including the portable build with the machine's VC++ runtime removed.
These are host/file-operation gates, not sudden-power-loss or cloud-provider
certification; Windows directory-entry durability remains unpromised.

## Settings

- One writer, `SettingsStore`, for `settings.json` in Support; saved whole on
  every change, the last write winning. Top-level keys this build does not
  know are written back unchanged, so an older build never erases a newer
  one's choices.
- Preferences never block startup. A file that cannot be read (bad UTF-8 or
  JSON, not an object, a directory) is moved into `recovery-quarantine/`,
  logged, and the app starts on the defaults. A symlinked `settings.json` is
  followed for reading and writing.
- A failed save keeps the choice on screen with one line saying so; the next
  change writes again.
- Jobs capture their configuration when they start. Secrets never appear in
  settings, logs or exports.
- Lichess credentials keep the old app's SharedPreferences keys. Keys that
  cannot be read, or hold the wrong type, read as signed out and are removed.

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
  owner or double from `test/support/` and never a real file or engine.
- **Keep presentation in the theme and panel files.** Inter and Source Code Pro,
  sizes 18/14/13/12, surface `1B1B1D`, board `F0D9B5`/`B58863`. The owner's
  2026-09-24 polish uses brighter blue `80B4FF` with filled buttons `2459C4`.
  Read the old mode or `lib/design_system/theme/` for reference values and
  behavior, never copied code. Layout and palette changes stay out of owners.
- The reviewer's test for a step: could the new widget file be rewritten from
  scratch by someone who read only the owner's public API and the theme?
  If not, state or layout leaked into the wrong place.

## Correctness hardening order

These batches precede broad feature expansion. Each delivers a named user
sequence and the smallest reusable mechanism needed for it. They are dependency
groups, not a request to implement the whole design in one session. Split a
batch into bounded tasks when needed; keep one status line per batch and use
tests and commits as the implementation record.

| Batch | Depends on | Scope and first places to change | Exit condition | Status |
|---|---|---|---|---|
| H1 | None | Direct fixes: recursive book selection, gap invalidation, analysis-save errors, partial engine retry, puzzle timer; `books`, workspace wiring, bughouse stores/search, puzzle trainer | Their acceptance sequences above pass through real wiring; failures are visible | Done 2026-09-24: book removal, gap refresh, analysis-save failures, engine retry, puzzle timer. |
| H2 | H1 | Accepted ratings and writes outlive reload/dispose; `PendingWrites`, training progress/owner, exit guard | Two overlapping reloads cannot bypass the same pending rating; failed outcomes remain retryable; shutdown is honest | Done 2026-09-24: accepted writes outlive reload and dispose; honest shutdown. |
| H3a | H2 | Existing relocation recovery before affected reads; document guards, training reads, startup; reconcile v1 domain locks/order | Kill during a move, reopen/train from either supported app; no missing or duplicate progress; anything unrecoverable is quarantined and the app opens | Done 2026-09-24 (Linux): unfinished moves recover before affected reads. |
| H3b | H3a | One compound operation for course rename/book references and its inverse; Library, storage, session history | Rename and undo agree across PGN/book state, including crash and external-conflict cases | Done 2026-09-24 (Linux): section rename and its book references commit and undo together. |
| H3c | H3b | Apply the proven operation boundary to supported file/folder moves, delete/restore and multi-file edits | Every existing command has an explicit required read/write set, recovery path and compatible undo behavior | Done 2026-09-27 (Linux): file/folder moves, delete/restore and imports retain recovery; `36fe1c22` completes cross-file line transfers with both PGNs, training snapshots, stable retry and guarded undo (`pair_store_test.dart`). Folding a trained line into another file remains refused; a separate-line move preserves its schedule. Platform proof remains H8. |
| H4 | H2, H3c | Versioned input snapshots for catalog, shelf, gaps, book comparison and training; targeted invalidation | A late computation cannot replace a newer result; a fresh rebuild equals the displayed committed projection | Done 2026-09-25 (Linux): catalog, gaps, training scope, book tree and game comparison read again when an input changes and leave an unreadable file out; none of them blocks opening, saving or training. |
| H5 | H2, H3c | Generation, mining, downloads, bughouse and engine lifetimes; job-specific checkpoints and truthful completion | Stop/retry/restart neither duplicates saved units nor loses promised results; resources return to baseline | Done 2026-09-25 (Linux): generation, mining, downloads, bughouse and engines report truthfully; derived writes never block. |
| H6 | H4, H5 | All existing modes: focus/shortcuts/navigation/close, settings, credentials, diagnostics | The complete cross-mode sequence below passes with real disposable storage, offline/error cases and headless UI checks | Done 2026-09-25 (Linux): modes, settings, credentials and close pass the cross-mode sequence; nothing blocks startup. |
| H7 | H6 | Remaining approved player/prep, database and tournament features, following their product rows | Each adds its own source/derived classification, durable unit and failure/restart tests while meeting the shared contracts | Partial 2026-09-27: Players & prep built in `43d59228`; TWIC cache downloading built in `307990e1`. Database browsing/import and the Engine tournament setup/run/results/history are now built under the owner’s September 27 implementation instruction; remaining workflow and presentation gaps are listed in rows 11–12. |
| H8 | H7 | Platform/scale/compatibility gates and switch-over readiness (no data migration) | No untested supported-platform durability claim; recovery and parity gates pass before old code is retired | Partial 2026-09-28: the native desktop contracts (document store, relocation, locks, file-open, exit, login sockets, built-app engines, sandboxed macOS release) and the Windows setup/portable/clean-runtime checks pass on Windows Server 2022/2025, macOS and Linux for `59eaf470` (run 36446559787); Databases storage, killed-import and cache tests joined that list. Remaining: killed-parent engine cleanup off Linux, scale budgets/parity and the maintainability review. |

Compatibility and scale checks start in the batch that changes their boundary,
not only at H8. Do not put a failing test on main to reserve a later batch;
commit a regression with the fix that makes it pass. H1's smaller fixes do not
substitute for the operation and lifetime work in H2-H5.

The integration sequence is: edit and train a course chapter; start a rating;
rename its section while a book is active; change training scope twice; remove
an answering sibling; verify membership, progress and gaps; undo the rename;
interrupt a durable move; restart; verify those same facts from disk and then
from the UI. Check expected intermediate states, not just the final screen.
The answering sibling need not be selected in the active book: its deletion
then leaves the rename receipt's book participant unchanged and undo succeeds.
Also exercise a selected sibling. Its deletion changes that participant, so
undo must refuse, retain its receipt and preserve the post-delete PGN, book and
training bytes; a fresh open must show those same facts. This is the guarded
inverse contract above, not permission to overwrite intervening book changes.

Implementation tasks run relevant tests, analysis and lint. Visible changes
also need a headless app check. Documentation-only planning runs lint and link
checks; it does not require a screenshot or mark an implementation batch Done.
Update the existing contract when the implementation changes it, without adding
a parallel report or debt ledger. New public formats, dropped product behavior
or weakened compatibility remain product decisions; internal implementation
choices follow the contracts here.

## Order of work

The table is the current checklist, reconciled against local main at
`613cab04` on 2026-09-27. Earlier delivery details live in Git history;
[the evidence record](ARCHITECTURE_RENEWAL_EVIDENCE.md) describes the abandoned
in-place migration, not unfinished v2 work.

**Status meanings:** Built means the implementation is present, not that this
documentation pass ran its tests or secured product acceptance. Partial means
the working feature has the gaps named in its row. Not started means the named
workflow is absent. Deferred means a product decision or explicit later scope,
not permission to implement it. Done requires [all exit conditions](#a-step-is-done-when);
old cells saying “Done, owner has not seen the screenshot” are now Built or
Partial. Existing hardening results above retain their recorded Linux scope.

Read a row's linked spec and its latest owner decisions before picking a task.
Old “Keep” lists and draft-screen descriptions do not override later Change/Drop
decisions. Missing legacy behavior is listed for disposition; it is not
automatically required parity. Do not revive dropped work.

| Step | Scope / spec | Status and what exists | Remaining work / next action |
|---|---|---|---|
| 0 | **Board and workspace** ([workspace](v2/features/workspace.md)) | Built: shared board, move tree, navigation and independent v2 entry point; arrows and circles stored as `[%cal]`/`[%csl]` and the shared board editor (2026-09-28). | Preserve the single workspace; final owner/platform/scale acceptance belongs to H8. |
| 1 | **Engine** ([workspace](v2/features/workspace.md)) | Built: shared supervisor, Stockfish/MultiPV, coalesced output, log, persistent engine switch and retry, Show threat (2026-09-28). Killed-parent cleanup is tested on Linux. | Prove native cleanup on Windows/macOS in H8; do not rebuild the supervisor. |
| 2 | **Document store and editing** ([workspace](v2/features/workspace.md), [backups](#backups)) | Built: revisions, conflicts, debounced autosave, compound edits and undo, recovery, version history/restore-as-new and explicit retention (`36fe1c22`). Windows replacement/sharing retries are implemented. | PGN semantic round trips remain H8; native Windows/macOS contracts pass (H8). Extend the existing compound-operation contract to linked Study/Players lifecycle gaps in 4b/10; existing repertoire recovery does not certify those links. Shared move-edit controls must follow the workspace spec; a store implementation alone is not UI parity. |
| 3 | **Library** ([repertoires](v2/features/repertoires.md)) | Partial: list/search/create/rename/move/delete, chapter recovery, course sections, Open/Paste/native-drop import, training-reference recovery and protection from late ratings are built. | Legacy receipt adoption/recovery dropped by the owner on 2026-09-30; the old-app recovery gate was removed and foreign metadata is untouched. Folder-to-course conversion and per-section Root/Draft representation before changing shared formats. Folder Organize UI is dropped. Studies and cross-mode navigation already have their own owners. |
| 4a | **Chapter outline** ([repertoires](v2/features/repertoires.md)) | Partial: roots/drafts, course sections, global chapter/line search, multi-select, drag/drop and Move to chapter (including a new chapter named there), the At this position filter (transpositions included), resize/collapse, move editing and transactional line transfers with training and guarded undo (`36fe1c22`). | Resolve remaining legacy split/check-disk/publish and unopened-chapter count expectations against the current spec; do not restore folder creation/moving or the old Organize screen. Cross-file training preservation is built, not an open design decision. |
| 4b | **Study** ([study](v2/features/study.md)) | Partial: shared workspace; create/delete/rename study; add/rename/reorder/delete/orient chapters; Lichess URL and PGN-file import; snapshot file/clipboard export; chapter tags, starting FEN, undoable annotation/variation cleanup and quiz markers. Study save/rename failures retain exact retry commands (`f361db78`). Players also create linked prep/group studies. Analyze/lint, 70 focused tests and headless tags/cleanup/FEN/rename checks pass. | First close linked-study lifecycle gaps: reproduce delete with player/group links, then preserve or explicitly resolve references through create/link, rename, delete/restore and chapter changes, with exact retry and restart tests. Linked studies currently refuse rename and delete; that guard alone is insufficient. Remaining: drag reorder, chapter manager, collection/user imports, compact layout and Train/Browse handoffs; apply the latest owner decisions before reproducing old layouts. |
| 5 | **Trainer** ([trainer](v2/features/trainer.md)) | Partial: Repertoire trainer mode **and** shared Train tab; Chapter/Repertoire/Book scope, course import, Learn/Review, typed moves, automatic mistake-based grading or optional manual ratings, scheduling/history, bulk actions and persistent settings. Accepted writes survive reload/disposal. Lesson Open in Builder now ends the sitting without grading, opens its course section at the shown move, and preserves Back; failed or superseded opens retain the current mode/document. Linux analyze/lint, full v2 suite and headless handoff/Back/restart checks pass (2026-09-27). Study quiz markers ([%tstart]/[%tend]) narrow the drilled window; the lesson's Line actions menu has View moves and notes and Exclude from training (2026-09-28). | Decide legacy partial-depth, automatic walkthrough, per-move streak and custom grouping options. Separate Drill, PGN-header schedule mirroring and studies-as-repertoire-training are outside the current design. |
| 6a | **PGN Viewer** ([viewer](v2/features/pgn-viewer.md)) | Partial: open/recent/paste, game/chapter search and navigation, notes/glyphs, explicit Save/Discard with bounded undo, autoplay, fullscreen clipboard PGN copy, exclusive visible-game file export, stable sorting shared by list/counter/keys, per-file game/cursor/sort restoration, and opening names (bundled lichess book by position) in the game heading and over the Explorer table (2026-09-28); filtering and explorer sources are in 6c. `5aaf611d` fixes save/filter/search behavior. `1f55c3b9` delivery: analyze/lint, 250 app/focused tests plus 55 final focused checks; headless sorting, export dialog and restart restoration inspected. | Whole-game review/graph now has a visible Game review tab, held annotations and suggested variations; solitaire (setup, hint, show move, summary) and Edit/Analyze/Solitaire heading buttons are built (2026-09-28); My books tab and left-book line, add to study from everywhere (one picker), follow-a-player orientation and crash checkpoints of held edits built 2026-09-28; review fixes the same day: closing writes the pending checkpoint, a tab closed on held edits offers them on reopen, a draft of a changed file is saved as a copy, and the follow box acts only on a pick or Enter. Verify right-click Comment against the spec. |
| 6b | **Explorer tab** ([workspace](v2/features/workspace.md)) | Built: Masters/Lichess/TWIC, source controls, games opened on the shared board, authentication retry and resumable weekly TWIC cache download (`307990e1`); This file/My games are also built in 6c. | Verify the remaining games-list hover-board expectation against the spec. Full database management is step 11, not a reason to rebuild the explorer. |
| 6c | **Collections and filters** ([viewer](v2/features/pgn-viewer.md)) | Partial: read-only legacy `app_games.db` access, header filters with bounded cancellable workers, This file and My games opening indexes, deduplication, selected-game opening, stable sorting and saved header-filter slices. Empty restored slices clear, and named game handoffs override remembered reading positions. | Position and move-sequence filters are built (2026-09-23, 2026-09-28); Include variations, Check filters, several positions and richer collection-as-list browsing remain. MCP PGN search/export is separate tooling, not completion of these app controls. |
| 7 | **Generation** ([generation](v2/features/generation.md)) | Built: Search tab, live values, explicit Make lines, Positions/finds, saved-tree resume, optional ChessDB/Lichess evaluation and retryable tree/draft publication (`36fe1c22`). 2026-09-28: Maia practical \| ChessDB mainline book source (master replies, stop/resume) and six-ply engine continuations on drafted lines. | Final parity/scale/platform proof in H8. The earlier Fill gaps dialog, pins, pruning and Prefer traps are superseded by the Search-tab decisions; do not recreate them. Legacy runs remain readable but are not resumed. |
| 8 | **Checks** ([checks](v2/features/checks.md), [repertoires](v2/features/repertoires.md)) | Built: Maia Replies, sibling-aware gaps, Next gap and corrected coverage. Player-specific Stockfish findings and bounded Maia practical estimates are built in step 10; generation also has finds/trap computation. Chapter audit (2026-09-28): Audit tab with weak moves (40/100 cp, mates said as mates), strong replies the Replies walk leaves out (engine, optional ChessDB through the one environment-owned client; an outage, or an engine that dies, reads as incomplete), go-to, dismissals kept apart by finding key, Stop and cached reruns; one engine job at a time. | Coherence, line metrics and the trap tour are not ported (owner scope, 2026-09-28). Do not port player findings twice. |
| 9a | **Tactics: puzzles** ([tactics](v2/features/tactics.md)) | Partial: filtered queue, shared-board puzzle session, hidden answers, feedback, stars, review fields, recap/retry and analysis handoff. Optional alternative-answer checking (`b494cc29`) compares both child positions at depth 14 on a bounded private engine, preserves the stored answer, cancels stale results and leaves unavailable checks ungraded. Analyze/lint, 317 app/tactics/settings checks plus 36 final focused checks and a real-Stockfish headless acceptance pass. Row menu (Analyze in the game, Add game to study, Copy FEN, Copy game PGN, confirmed Delete) and a Game tab with the whole source game from the games cache or `SourceMovetext`, mistake marked, opening on an analysis board (2026-09-28). | Tactic editor/multi-select and study-as-set review remain product backlog. Legacy CSV/named-set adoption is dropped as a switch requirement (owner, 2026-09-30). Current production wiring uses `tactics_sets/Default.pgn`; existing current-format puzzle data and review fields must survive. |
| 9b | **Tactics: my games** ([tactics](v2/features/tactics.md)) | Partial: Lichess/Chess.com usernames, download/pause/resume/offline cache, Stockfish mining and atomic puzzle-plus-analyzed-marker writes; persisted Bullet/Blitz/Rapid/Classical filter for mining and the book check; per-game mistake counts written with the analyzed marker (2026-09-28). | Game-card moments, flaw tags, Maia-shaped answer line and startup check. Player-download filters in step 10 do not complete the tactics UI. |
| 9c | **My games and Books** ([my games](v2/features/my-games.md), [books](v2/features/books.md)) | Partial: separate My games mode, Games/Openings views, active-book comparison, Book tab and Open in builder; Books mode and shared repertoire membership/index are built. Rows show the review's mistake counts; time-control filter shared with Tactics (2026-09-28). | Moments and commentary-line recommendation semantics. Reconcile the old per-colour book-choice gap with the current Books spec before adding another selector. |
| 10 | **Players & prep / Player analysis** ([players](v2/features/players.md)) | Built 2026-09-27 (`155b6d31`, `43d59228`): identities/groups/rosters, downloads/filters, deduplicated corpus, openings/findings/practical estimates, active-book checks, prep/linked studies, prepared flags, event metadata, US Chess updates and Markdown exports. Recorded delivery checks: analyze/lint, 223 focused/app tests and headless real-Stockfish walkthrough. 2026-09-28: saved-game counts/freshness on cards and the analysis header, recoverable Delete saved games (also offered on Remove), persisted finding dismissals and Train group study in the Repertoire trainer (study chapters trained from their own sides). | Linked prep/group study lifecycle correctness with 4b after chapter changes (missing, unreadable and half-linked studies are repaired or unlinked since 2026-09-29); then final acceptance/H8. Do not restart step 10 from its old Not started status. The players spec defines the bounded practical-search scope. |
| 11 | **Databases** ([databases](v2/features/databases.md)) | Partial 2026-09-28: one `master_games.db` holds TWIC downloads and PGN imports, and the explorer, this mode and the MCP tools read it; v2 writes its version-4 schema as the older app did and refuses other versions. The mode filters/sorts/pages games, imports PGN idempotently, downloads or tops up TWIC and opens games in the viewer; TWIC download is shared with the explorer. A folded Storage list measures every store the app keeps (databases with sidecars, document folders) and deletes only derived data: the master games and leftover copies of derived databases (`.bak`, set-aside). Writes survive a killed import (issue rolled back), a full disk (reported as such, earlier issues kept, resumable) and an unreadable file (set aside, new one started); these run natively on Windows/macOS/Linux, disk-full on Linux tmpfs. | Offline evaluation stores, ChessDB dump, broadcast UI, Scid export, auto-sync, first-run prompt and legacy classical-index rebuild are deferred: the owner is not sure they are worth building (2026-09-28). |
| 12 | **Engine tournament / Bughouse** ([tournament](v2/features/engine-tournament.md), [bughouse](v2/features/bughouse-lab.md)) | Partial (`e22b4e62`, `b819ec31`): Engine tournament now has verified custom-engine registration, setup/FEN, four time controls, round-robin/gauntlet/concurrency, adjudication, live board, scores, searchable history, retryable PGN/metadata checkpoints, trash and viewer handoff on the shared supervisor. Outside-run history watching, atomic open-request claims, ranked opponent crosstables/rating statistics, persisted final-position previews, date groups and opening search are built; 228 focused/app tests plus four native inbox tests and a headless outside-request/watch/preview walkthrough pass. Focused checks and a real-Stockfish headless setup/run/results/viewer/registration walkthrough pass. Bughouse table, book/archive, Hivemind analysis, saved matches and provenance remain built. 2026-09-28: engine file picker with `id name` naming, specific verification failures with the engine's first 40 output lines, time presets and the run header's time control/format; the lab copies and pastes both boards' moves as BPGN. | Remaining tournament parity: disposition of the duplicate Engine controls tab. Keep durable checkpoint/illegal-move/shutdown tests; do not rebuild the runner. Bughouse editable clocks, palette and Compare clock scenarios were dropped, not deferred work. |
| 13 | **Services** ([settings](v2/features/settings.md)) | Partial: searchable settings, training/repertoire/engine controls, Lichess PKCE/token login, usernames for Lichess/Chess.com downloads, Open log folder, bounded Copy diagnostics (`85023871`: version/platform/log tail with recognizable credential lines omitted; 49 focused checks and headless clipboard success), failure-tolerant settings, and (2026-09-28) version + complete licence page (packages and bundled engines, model, fonts, pieces, opening names), a Shortcuts reference built from the one `AppKey` table the handlers use, and figurine notation through one `displaySan`. Updates (2026-09-28): daily GitHub checks, the once-per-version prompt with Skip, size/SHA-256-verified cancellable downloads, install-on-close through the existing `assets/updater/` helpers (Windows setup, deb/rpm, marked portable zip; others get the release page), next-start failure report and Settings ▸ App rows; unit/widget tests plus a real Linux helper swap, headless prompt/Settings screenshots against a local release fixture. | Native Windows/macOS installation acceptance of the v2 updater in H8 (the Windows release gate runs its tests); approved display/account settings (the old Widgetbook was retired with v1). Keep diagnostics bounded and credentials out of logs. Chess.com downloading is already built; any additional account UI needs a defined purpose. Vault migration is explicitly a separate later step, not an H6 blocker. |
| 14 | **Switch-over** | Source retirement implemented 2026-09-30 under the owner's explicit instruction to drop legacy/backward-compatibility requirements: `main.dart` is the sole entry, production/tests moved to their standard roots; old app, assets, tests, ledgers and one-shot switch tooling removed. Current recovery no longer depends on reopening v1. | Validated on Linux: analyze (informational hints only), lint, offline tools and both native desktop integration checks pass. Full Dart run: 5,141 passed, 4 skipped and one stale child-harness path failure; that path and three other constructed paths were corrected, then all 1,085 focused recovery/engine/storage checks passed. The 142 merged training checks and 24 merged file-change/save checks pass; analysis was rerun after both integrations. Headless `main.dart` smoke: create repertoire, add `e4`, restart and reopen the saved chapter; screenshot inspected. Tooling fixture failures were corrected and the offline suite passes (10 optional live-Hivemind checks skipped). Native Windows/macOS release and scale gates remain publication work; unported legacy features are not prerequisites. No user-data migration or deletion. |

### Next-agent queue

Work on requested improvements in the sole app. The feature rows retain the
known scope gaps; do not turn old-only functionality or compatibility into a
new migration project. Validate current behavior and persistence through the
existing production owners and tests. Publication still requires its own
explicit request and release gates.

### Completion gates

Historical pre-retirement acceptance scope follows. The September 30 owner
decision supersedes v1 parity, legacy recovery and pre-deletion acceptance
requirements; current-app correctness and release validation still apply.

**Correctness across features.** Existing stores and Linux hardening are the
foundation, not proof that every new cross-mode command is safe. For linked
studies, [rename and delete refuse while player/group links name the
file](../lib/features/study/studies.dart); [Players reuses stored prep
paths](../lib/app/player_wiring.dart). Acceptance must cover a linked
study's creation, failed link write, rename, deletion, restore and referenced
chapter rename/removal. No successful command may silently leave a dangling
required reference. Either complete the reference change recoverably or refuse
before mutation; retained links need an explicit, usable recovery path.
Exercise uncertain acknowledgements with the same operation identity, external
changes, close during a write and two subsequent reopens. Keep unrelated files
usable throughout. Include semantic PGN round trips for custom starts, comments,
variations, shapes, quiz markers and unknown tags; untouched content must follow
the document-store preservation contract.

**Usable end-to-end workflows.** A control being present is not completion.
Each retained row must pass its journey with production wiring and disposable
data, including keyboard/focus behavior, narrow-window layout, empty/loading
states, offline or failed operations and reopening the result:

- Study: create/import → annotate/reorder → save/reopen → export → Browse or
  train as puzzles. Settle the Study-to-puzzle handoff; do not silently turn
  studies into repertoire training or discard existing puzzle review fields.
- Viewer: open a collection → filter/search/sort → navigate/analyze → save or
  discard → export the visible selection → reopen. List, counter, navigation,
  explorer and export must agree on game identity and selection; stale workers
  must not publish into another file.
- Library/trainer: import a course → organize chapters/lines → learn/review →
  inspect the lesson in Builder → move/delete/restore → retain the schedule and
  history. Include legacy whole-repertoire recovery receipts.
- Tactics/My games: download → mine a moment → solve → inspect its source game
  → edit/manage the puzzle → review again. Failed or cancelled checks do not
  invent grades; puzzle changes and review history stay consistent.
- Databases: inspect usage → configure/download/import → pause/restart/resume →
  use the source in explorer/generation → recover or remove derived data.
  Distinguish removing an archive, quarantining files and actually freeing
  space; preserve user PGNs and account/progress data. A working setup screen
  without a working evaluation consumer is incomplete.
- Repertoire audit: run the agreed check → inspect a finding at its position →
  edit the chapter → rerun and see current results. Define scope, score
  perspective, cancellation and stale-result handling before building reports.
- Tournament/services: configure/run → inspect/reopen/export results, and check
  for/download/verify/install an update on each supported platform. Failures
  retain saved matches and the existing installation; no silent partial success.

**Scope and spec reconciliation.** Complete the retained scope or record an
explicit owner Drop/Defer in the existing spec and row. In particular resolve
viewer engine review/solitaire/handoffs, Study collection/user imports and
chapter manager, trainer legacy options, folder/course representation, tactics
CSV/study-as-set compatibility, My games commentary recommendations, chapter
audit/report scope, database broadcasts/offline dumps and tournament duplicate
controls. Existing data must remain readable or have a verified preservation
path even when its former UI is dropped. Reconcile historical Study autosave,
recovery and training text with the central contracts and latest decisions;
remove obsolete viewer claims that saved header slices are absent. No Light or
System theme, old Organize screen, superseded generation controls, dropped
bughouse clock tools or credential-vault migration is added by this update.

**Maintainability.** At `613cab04`, `scripts/check_v2.py` passes and reports
85,760 production lines in 361 files, about 43% above the 60k sanity target.
That is a design-review trigger, not evidence that the architecture is broken
or permission to raise the target. Review equivalent feature scope against the
old implementation, keeping tests separate. Start with the shared document
session/save lifecycle, composition/navigation and generation ownership; the
999-line `document_session.dart` and 956-line `document_saver.dart` are useful
review starting points, not automatic split instructions. Trace each mutable
fact, required write and invalidation to its owner; remove duplicated rules,
unused paths and forwarding-only layers, and test behavior across boundaries.
Split only when responsibilities differ. Do not hide growth by moving files
outside `v2`, fragmenting one job or loosening checker limits. Keep the
production-widget catalog tied to real controls. Resolve the size review and
any must-fix findings before declaring renewal complete.

**Platform, compatibility and scale (H8).** Run the existing [desktop
contracts](../.github/workflows/desktop-contracts.yml) and required release
gates on the candidate commit; a workflow definition or previous green commit
is not acceptance. Native Windows/macOS evidence must cover file replacement
and sharing contention, permissions and long/Unicode paths, recovery after
interruption, file-open integration, packaged engines/login sockets and engine
cleanup after parent termination. Verify installed/release behavior, including macOS
sandbox/signing, rather than relying only on debug tests. Record platform
skips honestly; Linux process-kill tests do not prove power-loss durability.
Use disposable profile copies to alternate old-app, v2 and supported external
writer operations, then verify locks, formats, progress, references and undo.
Compare deterministic rewritten algorithms with the old oracle on fixed
inputs. Before scale acceptance, define representative corpus/course sizes and
measurable latency, frame, memory and shutdown budgets; exercise large annotated
PGNs, collections, filters, save/undo and repeated mode/job transitions. Verify
processes, subscriptions and queues return to baseline. Keep results with their
tests/commits and existing status cells, not a new evidence log.

**Source retirement (14).** Implemented September 30 under the decision above.
The existing Documents and Support locations are unchanged. Do not recreate
the deleted one-shot migration script or v1 compatibility work. Build/test paths
and agent guidance now describe the sole app.

### A step is done when

1. The product owner has seen the screenshot and accepted it.
2. Everything in the row's scope works in the running `v2` app, or the owner
   dropped it (remove it from the row so it is never ported).
3. Current app data survives save/reopen and interrupted operations.
4. Tests cover its user actions, its failure paths and every write it makes.
5. Every failure it can hit names the action in the log, and the screen says
   the same thing in plain English.
6. Ownership stays clear and the architecture checks pass. Tests are counted
   separately from production size.

Mark the status cell *Done* with the commit. Nothing else is written down.

### Known hard problems

These remain regression contracts, not an independent list of missing features:

- **Steps 2–4 / H3:** the shared directory-domain lock and recoverable
  document/reference operations are built (`storage/recovery_gate.dart`,
  `storage/file_relocation.dart` and `features/library/line_transfers.dart`).
  Keep late-rating, reused-path, crash/retry and guarded-undo tests green.
  A trained line folded into another file is refused; moving it as its own
  line preserves progress. Transfers use the source training id and the
  destination id after arranging the whole file, including when a malformed
  header prevents pinning an id; raw `LineID` tags do not identify progress.
- **Steps 6–7 / H4–H5:** replacement opens, paste, close and cancellation must
  reject stale filter/index/engine/generation results. Autosave and publication
  stay bounded and tied to their captured input. Legacy generation formats
  stay readable; old runs are not resumed.
- **Step 2:** backup failure cannot leave a half-applied authoritative change;
  explicit retention shares the save/move lock. History and retention are
  already built; their implementation is not proof of power-loss behavior.
- **Step 13:** existing SharedPreferences credentials remain supported.
  A vault migration is deferred by [Choices already made](#choices-already-made);
  if later authorized, migrate and verify one account before removing its key.
- **H8:** Linux process-kill tests do not prove Windows/macOS engine cleanup
  or power-loss durability on every supported filesystem. Prove those native
  behaviors before claiming them or retiring the old app.

## Current development workflow

Follow [AGENTS.md](../AGENTS.md) and its conditional [agent guides](agents/README.md).
The app and tests now live at their standard roots; use the feature specs for
current product decisions and the reviewer checklist above for ownership.
Do not apply the retired dual-app session protocol or restore v1 parity gates.

Use an isolated task worktree, bounded checks and disposable headless profiles.
Changes belong on local main through the integration helper; publication remains
separate. The `run-chess-auto-prep` skill owns runtime checks and screenshots.
The table's remaining feature work is backlog, not a request to implement every
old control. Explicit current user instructions set scope.

## References

- [DATA_INTEGRITY.md](DATA_INTEGRITY.md): stores, formats and recovery files.
- [COMPONENT_MAP.md](COMPONENT_MAP.md): what the old app does, for parity.
- [ALGORITHM.md](ALGORITHM.md): tree-generation pipeline.
- [Flutter architecture recommendations](https://docs.flutter.dev/app-architecture/recommendations).
- [SQLite: how to corrupt a database](https://www.sqlite.org/howtocorrupt.html)
  and [WAL](https://www.sqlite.org/wal.html).
- [Windows Job Objects](https://learn.microsoft.com/en-us/windows/win32/procthread/job-objects)
  and [ReplaceFileW](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-replacefilew).
- macOS runs Stockfish from `Contents/Helpers`, signed at build time with
  sandbox inheritance after verifying the pinned archive. Extracting the
  upstream signed binary at runtime was rejected by the macOS sandbox. The
  packaged release check exercises the helper under the release entitlements.
  [Apple's helper sandbox requirements](https://developer.apple.com/library/archive/qa/qa1773/_index.html).
