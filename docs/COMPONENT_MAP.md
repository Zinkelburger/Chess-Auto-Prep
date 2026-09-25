# Component Map

**Source of truth for what is currently implemented** in the Chess Auto Prep Flutter/Dart app. Use this document to audit behavior, trace data flows, and plan fixes.

| Document | Purpose |
|----------|---------|
| **This file** | Current implementation — screens, services, widgets, tests |
| [`FUTURE_FEATURES.md`](FUTURE_FEATURES.md) | Backlog only — not yet built or incomplete |
| [`ARCHITECTURE_RENEWAL.md`](ARCHITECTURE_RENEWAL.md) | Renewal app in `lib/v2/`: rules, data-safety contracts, implementation status and remaining work |
| [`ALGORITHM.md`](ALGORITHM.md) | Flutter expectimax / tree-generation pipeline |
| [`../tree_builder/ALGORITHM.md`](../tree_builder/ALGORITHM.md) | C `tree_builder` CLI pipeline (incl. db-explorer) |
| [`tree-display-architecture.md`](tree-display-architecture.md) | Eval-tree graph performance principles |
| [`OPPONENT_PREP.md`](OPPONENT_PREP.md) | MCP server: tournament identity/pairing **and** PGN opening-tree query |

Last reviewed against `lib/` and `tree_builder/` (June 2026, post 7-phase remediation). When you change code, update the matching section here.

---

## Table of contents

1. [Architecture overview](#architecture-overview)
2. [Entry points & navigation](#entry-points--navigation)
3. [Major data flows](#major-data-flows)
4. [Directory reference](#directory-reference)
5. [Test coverage map](#test-coverage-map)
6. [External & non-Flutter components](#external--non-flutter-components)
7. [Audit gaps](#audit-gaps)

---

## Architecture overview

| Layer | Role | Key packages |
|-------|------|--------------|
| **Screens** | Top-level routes / modes | `screens/` |
| **Widgets** | UI composition | `widgets/`, `features/*/widgets/` |
| **Features** | Domain-vertical modules (audit, traps, coverage, generation) | `features/` |
| **Core** | Session controllers shared across repertoire UI | `core/` |
| **Services** | Business logic, engines, I/O | `services/` |
| **Models** | Immutable / serializable data | `models/` |
| **Constants / utils / theme** | Shared helpers | `constants/`, `utils/`, `theme/` |

**State management:** Provider (`ChangeNotifier`) supplies `AppState`, feature/session controllers and application-owned engine/settings components. `AppDependencies` shares the committed settings owners and `EngineRuntime` components across views. Evaluation preferences and the CDB/Lichess download controllers are also app-owned; legacy settings outside those migrated sections remain separate debt.

**June 2026 remediation (7-phase refactor):** Repertoire metadata is typed (`RepertoireMetadata` replaces `Map<String, dynamic>`). `AppState` no longer tracks a global saved-games list. `RepertoireController` navigation funnels through `playMove` / `playMoveAtTreePath` (removed `userPlayedMove`, `_isInternalUpdate`). `GenerationSessionController.dispose()` stops an in-flight build. Lines browser uses typed `LineSortBy` / `LineMetricsFilter`, 300 ms search debounce, and lazy grouped `ListView.builder` rows. PGN editor memoizes move widgets and delegates clipboard/persist I/O to parent callbacks. Coherence FP-Growth runs in `Isolate.run`. `EngineLifecycle.enterGeneration` / `exitGeneration` are serialized via `_serialExec`. Startup failures surface via `runZonedGuarded` → `StartupErrorApp`; repertoire load failures via `RepertoireController.loadError`. Deleted unused `ease_calculator.dart`. New extractions: `GenerationConfigForm`, `RepertoireShortcuts`.

**Repertoire navigation model:** `RepertoireBoardController` privately owns the
mutable move tree, cursor and cached immutable projections. Builder widgets use
its commands directly; Trainer owns only a board. `BuilderWorkspaceController`
owns editable drafts, retained copies and recovery attachment, while
`RepertoireDocumentSession` owns chapter loading and ordered writes. The old
`RepertoireController` facade is deleted. `InteractivePgnEditor` emits edits and
title changes; it no longer owns an autosave timer or snapshot supplier. The
workspace captures edits immediately, and the document owner retains one active
write and one latest pending edit per line between explicit command barriers.

`BuilderLifetime` owns the workspace and recovery for the application lifetime.
Recovery retains annotations, headers, cursor and native source evidence;
restored drafts attach autosave only when that evidence and the original line
still match, including when selected through the outline. Explicit copies persist
intent before appending, retain uncertain outcomes across restart, and require
inspection before retry. Close joins copy/reconciliation actions and their final
checkpoints. A source autosave cannot retire a draft referenced by an unresolved
copy.

**Viewer game ownership:** `features/documents/controllers/viewer_game_controller.dart`
privately owns the parsed game, mainline, variation forest and board cursor. Its
public metadata, moves, variation nodes and cursor paths are detached immutable
values. Annotation commands resolve stable node IDs against the live forest;
deleted/replaced targets cannot emit an edit. `chess_core/pgn/sideline_projection_cache.dart`
shares unchanged plies and branches using the same `MoveNodeSnapshot` capture
algorithm as Study/Builder; navigation reuses the exact forest. Focused reading
scopes/bookmarks refresh their nodes from each new projection. Deleting the
selected branch or clearing scratch analysis also retreats the board.

`chess_core/analysis/{move_eval,game_eval_annotations}.dart` now owns stored engine
verdicts and PGN annotation transforms; `chess_core/pgn/pgn_position_replay.dart`
owns pure replay/index codecs. Numeric quality-NAG editing rules live in
`chess_core/pgn/quality_nags.dart`, separate from glyph styling. The old service
and Viewer model paths are removed, with imports/tests migrated. The standalone
`tools/bench/viewer_document_bench.dart` runs the game owner with plain Dart;
widget lifetime, collection orchestration and full presentation migration remain
separate work.

`ViewerOpeningTree` reads games, visible games and the selected setup directly
from its `ViewerCollectionController`; autoplay steps its `PgnViewerHandle`
directly. Reading-mode position callbacks remain explicit because the opening
tree can have a different cursor from the game reader.
`ViewerReadingController` also dispatches external board/step commands. The
screen supplies the current Book comparison reader explicitly when appropriate;
fullscreen supplies the primary reader. Without that argument, commands use the
existing game/tree/Solitaire rules. `PgnPaneRouter` and its callback dispatch are
retired; there is no retained active-reader state. Home/End on the Book reader
remain direct ply jumps, preserving its ephemeral variations. Fullscreen keeps
that existing reader subtree mounted but hidden and unfocusable; both keyboard
and button movement target the primary game, and leaving restores the Book
pane's cursor.

`PgnWorkspace` owns only fixed panel identities and immutable titles: Game,
Books, Evaluation graph, Tree, Collection and Filter. Database explorer selects
the existing Tree tab's database source. Closing, reopening, reordering and
navigation-history restoration use those identities; Filter has an explicit
pane branch. Main document PGN/TXT opening, SCID export and collection/database operations
remain separate from these tabs.

The custom database-picker/reference-tab component, its five screen maps,
custom-title allocation and reference-only action branches are retired. Live
Book cursor ownership, Filters, fixed database Tree and collection operations
remain with their existing owners.

The shared annotation panel flushes pending prose before a glyph action emits a
save. A same-target rebuild does not replace a pending draft just because focus
has moved to a toolbar control.

**PGN context menu (right-click):** Uses Flutter's built-in `showMenu` API (Overlay-based, avoids Stack/Positioned layout issues). Menu items: Add Comment (focuses comment TextField), Promote Variation (non-mainline only), Make Main Line (recursive promote to root, non-mainline only), Duplicate Line (copies full line to clipboard), Copy PGN from Here, View in Lines (existing-line only; switches to Lines tab), Delete from Here. When the context menu is open, all moves from root to the right-clicked position are highlighted (blueGrey background). Delete from Here records a draft-only undo via `RepertoireWriter.recordDraftUndo()`, making it reversible with Ctrl+Z without replacing the chapter on disk. Its opaque board receipt validates both the adoption lifetime and expected movetext; adopting an equal-looking board cannot authorize restoring an old draft. Successive deletions remain undoable within their original lifetime.

**Builder document boundary:** The workspace and writer receive the same
`RepertoireDocumentRepository`; the document session also receives a
`RepertoireDecoder`. App startup constructs these owners and their lifetime.
The retired loader's result is `features/repertoires/models/loaded_repertoire.dart`,
with its decoder contract in `features/repertoires/repositories/` and isolate
implementation in `infrastructure/repertoires/`. Builder destination selection
uses the injected catalog's `listChapters` capability. The same catalog owns
`createChapter` for Builder, Outline and the chapter picker; only an acknowledged
`PgnSaved.after.path` may become the selection. Exclusive document creation
preserves competing files, and uncertain outcomes retain inspection paths without
automatic retry. `ChapterStore` is retired; the pure `chapterHeader` formatter lives
in `chess_core/pgn/repertoire_pgn_text.dart`.

Builder loads sibling chapters when its breadcrumb picker opens, without a
background sibling cache. The existing document generation rejects stale list,
dialog and load continuations, including A→B→A switches. The chapter manager
renders file listings before enriching them with catalog `chapterSections`
(header-only course grouping), rejecting results from replaced folder requests.
Picker creation inherits an available sibling color; unreadable color sources
fail before creation. Builder and Outline capture their explicit color. Chapter
rename/move and Outline line transfers remain legacy migration work; manual
deletion uses captured native quarantine as described in the catalog section.

`DocumentRepertoireRepository` adapts the shared `PgnDocumentStore` for chapter
reads, line edits/deletion, imports, metadata replacement, append and undo.
Linux uses the native store chosen at startup, including observed byte/file
identity validation and retained history. Other hosts retain the legacy
content-only adapter pending their platform gates. Repertoire text transforms,
metadata headers, line IDs, document splitting and immutable append receipts
and course-header/variation-expansion helpers have canonical libraries under `chess_core/pgn/`; the old service utility paths
are removed, with no re-export shims. Unmigrated callers of
`RepertoireFileEditor` share those pure transforms but retain their existing I/O.

**Repertoire mutation safety:** `setRepertoireColor`, `setRootPosition` and
`importPgnContent` require their observed decoded-content baseline. A line saver
retains its original game's bytes across debounce and chapter switches; queued
saves advance only from acknowledged stored game text. An external edit of that
game conflicts, while unrelated games and missing custom headers survive. A
structural edit that changes a derived line ID can resolve its exact acknowledged
game only when unique. Replacements contain exactly one game. Bulk deletion
validates every captured index/game pair before changing anything; late single
and bulk deletion results cannot clear the newly selected chapter.

`RepertoireWriter` serializes append/undo, captures its document session before
queueing and rejects stale queued work. Append preparation returns immutable
`AppendMovesResult` receipts containing the observed before-content and actual
added-move steps; a batch commits once. File-backed undo validates its expected
content and advances only its proven predecessor after commit. Conflicts/failures
retain history. Scratch-tree deletion undo remains independent of file mutation.
The import dialog keeps its draft on conflict/read/write failure. Missing
destinations fail rather than reporting success. Native append/undo uses validated before/after snapshot receipts; successive
undo advances only a proven predecessor and retains unresolved history on
conflict or uncertain acknowledgement. Builder workspace recovery is implemented;
remaining catalog mutations and line transfers still need their own cutovers. See `test/features/repertoires/repertoire_mutation_safety_test.dart`,
`test/features/repertoires/repertoire_line_save_switch_test.dart` and
`test/infrastructure/repertoires/document_repertoire_repository_test.dart`.

**Outline storage injection:** `RepertoireService(storage: ...)` routes file
parsing and course discovery through its supplied storage. `RepertoireOutlineService`
passes its storage owner into its default parser, so a fixture or alternate
profile is not silently read through `StorageFactory`. The injected
`ChapterSplitter` instead opens one document snapshot and parses that captured
content off the UI isolate.
Pure text parsing does not resolve storage; the legacy default remains for
unmigrated callers. Remaining outline/generation file-editor callers still need migration.

**Line deletion:** `RepertoireDocumentSession.deleteLine(line)` validates the loaded game through its injected document repository and reloads only the same active chapter. `LineItemRow` shows a trash icon with a confirmation dialog; callbacks thread through `LinesListPanel` → `RepertoireLinesBrowser` → `repertoire_screen`.

**Chess logic:** `dartchess` for rules/FEN; `flutter_chess_board` for display.

### Recoverable repertoire folder moves, deletion and restore (Linux)

`RepertoireDirectoryMutations` owns a durable intent/completion journal in
Support `repertoire-mutations/`. Linux `renameat2(RENAME_NOREPLACE)` refuses
racing destination creation. Native directory identity gates replay; ambiguous
paths retain the journal and surface **Recover library** in the catalog.
`RepertoireReferenceMigration` atomically rewrites the latest review schedules,
review history, move progress and mistake log, retaining prior text under
Documents `.cap-reference-history/`, then updates the shared book selections.
Reference failures resume from the journal without repeating the namespace move.
Before any affected access or its own recovery, this owner also checks v2's
private compound and file-relocation journals. `foreign_relocation_history.dart`
validates `Support/relocation-writes/` without importing v2 or reading current
participants: only complete/cancelled records are accepted. Pending, malformed,
linked or unknown metadata instructs the user to reopen v2, preserving all files.
`foreign_training_history.dart` applies the same refusal boundary to
`Support/training-writes/`: it validates compact completed receipts, their
predecessor chain and proven native previous copies without replaying commands
or consulting historical source paths. Pending or unknown training evidence
blocks document/training access before legacy recovery can run.
The compound decoder also recognizes strict version-2 two-PGN receipts. It
accepts terminal history without consulting former participant paths and
refuses pending or invalid records before legacy recovery. V2's `savePair`
validates and preserves both PGNs, publishes under one recovery boundary, and
returns one authenticated inverse. Workspace external-edit preparation holds
source adoption through publication; historical retry requires fresh native
proof before updating the editor. Library cross-file command wiring remains
pending; the two-PGN protocol does not include training or book changes.
The v2 protocol and remaining migration work are described in
[architecture renewal](ARCHITECTURE_RENEWAL.md#course-files).

`IOStorageService` routes Linux repertoire/nested-folder moves through this
owner and supplies the same domain lock to managed file operations and the
native PGN store. Linux folder deletion moves the complete tree to Documents
`.chess_auto_prep_trash/repertoires/<receipt-id>` using the same identity and
journal protocol. Training/book references move to that recovery location;
`MyRepertoireSettings` excludes parked recovery paths from active opening books.
The catalog's **Recovery** view lists retained deletion receipts. Restore accepts
the original name or a replacement name in the original parent, refuses existing
destinations, verifies the recorded directory identity and replays reference
updates. A restore receipt links back to its deletion; completion removes it
from the recovery list without deleting the audit records. Interrupted delete
and restore use the same persistent **Recover library** action as rename.
Missing/replaced recovery folders remain listed with restore disabled. No
receipts or recovery contents are automatically pruned. Older quarantine folders
without a journal remain on disk; their UI adoption is still pending.
Single-file/chapter rename remains legacy. Windows/macOS retain their prior
folder-move adapter pending native verification. A revisionless legacy write
can still recreate a stale path after a move; full writer migration is pending.

### Typed settings ownership (first section)

`features/settings/{models,repositories,controllers}` provides the injected
`AppSettingsRepository` and immutable committed/draft section state.
Appearance uses a Provider stream subscription, seeded from current state before
loading; subscription disposal leaves the borrowed repository alive. `infrastructure/settings/` owns the two existing
`my_repertoire_*_paths` keys. It serializes field changes, reads the latest
platform values, verifies writes by rereading, and keeps failed drafts for
explicit retry. Games' `MyRepertoireSettings` is a temporary ChangeNotifier
adapter to this same owner; it no longer reads/writes preferences or publishes
optimistic saved values. Its listeners fire only when confirmed selections
change, so saving/error transitions do not rerun game analysis.

The My books panel shows pending/failure state, keeps confirmed choices visible,
and retries designation without recreating an already imported repertoire.
The relocation operation maps path components and can retry a partial two-key
update. Linux folder rename, deletion and restore invoke it through the directory
journal above. Credentials retain legacy ownership. There is no cross-process preference transaction claim.

`RuntimeSettings` composes the typed engine, bulk-analysis, board-display and
evaluation-database owners; their immutable configurations normalize both setter and explicit field
edits. A failed initial read stays failed and retryable until a committed value
exists. `EngineLifecycle` serializes preference initialization with toggles and
generation transitions: unknown preferences do not enable analysis, late startup
cannot undo a successful user toggle, and navigation resume does not rewrite
preferences.

`EvalDatabaseSettings` now uses the same committed/draft owner and verified
preference storage for its seven existing keys. Callers read immutable
`EvalDatabaseConfiguration` snapshots; there is no process singleton or
forwarding getter surface. Generation captures confirmed probe settings before
loading artifacts. Builder refuses Planner admission without confirmed settings
and passes its captured configuration through an explicit `PlanDataSource`.

`AppDependencies` provides one CDB and one Lichess download controller. Each
reserves its operations and drains them on close before settings disposal.
Artifact completion and saving its activation are distinct: retrying settings
never transfers or imports data. Destructive deletion first clears only the
matching selection; failed preference writes retain files. Retry and toggles
resolve selection inside the existing settings queue, preserving newer choices.
Manual CDB selection validates under the same resource reservation. Metadata
reload is read-only; Resume/Continue setup require an explicit user action.
Preferences do not provide cross-process compare-and-swap semantics.

The inline engine bar, PV moves, settings shortcut and busy notices resolve the
active application theme; an open floating preview follows appearance without
restarting analysis. Explicit evaluation and move-annotation colors remain owned
by their callers. Shared notices use the paired `SnackBarTheme` surface, text,
action and close colors in either appearance. Errors remain persistent and
attention notices timed; severity is expressed by the message rather than a
fixed red surface.

Startup wraps legacy Linux/Windows preference backends in
`FreshDesktopPreferencesStore`: serialized requests use fresh backend instances,
so the plugin's second cache cannot confirm an unsaved value or flush a failed
draft during an unrelated write. Keys/file format remain unchanged. Linux has
real disk-failure coverage; Windows native verification remains outstanding.

### Bughouse analysis and editing

`features/bughouse/widgets/bughouse_screen.dart` keeps Board 1 and Board 2
beside one analysis/reference panel. Underlined Engine / Board / Engine settings
tabs provide navigation, distinct from the segmented database selectors.
Engine moves use the PGN notation face at 16px, with consistently semibold white
continuations, white move numbers and separators between candidates. The layout follows lila's separation of
boards, engine lines and opening explorer. Smaller windows stack the panel.

| User action | Control / behavior |
|---|---|
| Play or drop a piece | Drag on either board; reserve pieces also support click then square |
| Read reserves | Pieces match their board's piece size and scale with it, including during a drag. Compact, centered gray trays fit the five slots with tight padding, keeping both piece colors visible. Owned pieces stay fully opaque on either turn and always show a count; empty slots remain faint silhouettes |
| Identify seats | You / Partner / Opponent / Partner’s opponent in 16px text beside 20px clocks and larger seat badges. Board headings use 18px text; the turn marker keeps a fixed slot so labels do not shift |
| Pause or resume | Analysis toolbar |
| Read candidate continuations | Board 1 and Board 2 ranked lines appear together, automatically using the side to move on each board. Searches still consider both boards jointly; all scores are from your team’s perspective |
| Preview a continuation | Hover a move or candidate to show the resulting boards and reserves; exit restores the current position without changing history |
| Play a continuation | Click a move to play the joint sequence through that point, including its other-board moves |
| Browse FICS | Book icon opens the archive immediately in the right panel; Board 1 / Board 2 filters the recorded next moves |
| Interpret archive results | Result bars always describe your team. Move frequencies use the selected board’s recorded continuations; the archive remains keyed by both boards |
| Change team, sitting or clocks | Board tab; editable clocks remain beside the players |
| Compare clock assumptions | Board → Compare clock scenarios opens Engine immediately with a distinct Clock scenarios section, spinner and completed-result count. Each scenario’s evaluation and board-labeled moves appear as it finishes; current-clock lines remain separately labeled below. Hover explains the three cases (ahead and may sit, level or behind, forced to move on Board 1) |
| Change cores, lines, memory or time | Engine settings tab, with number steppers and typed entry |
| Edit either board | Pencil icon; shared drag editor supports palette placement, arbitrary piece movement and right-click removal; illegal kingless bughouse positions are rejected |
| Change turn, castling, reserves, clear/reset | Edit position controls and reserve slots |
| Load/copy a position | Dual FEN controls in the editor; copy menu below the boards |
| Navigate or undo | Larger controls below the boards; arrows and Home/End navigate history. Each board's 16px move list has a charcoal background and outline separating it from the page, with room for two lines before scrolling |
| Flip a board | Its header control; F for Board 1, G for Board 2 |
| Run or review engine matches | More bughouse tools → Engine tournament; Done returns to analysis |

`BughouseCpuLimit` limits all threads of the Linux analysis process with
`taskset`, restricted to the parent process’s allowed CPU set. The persisted
default is two cores. This controls CPU affinity, not Hivemind's compiled
worker count; Windows/macOS still use the engine's own CPU allocation.
Tournament resources remain owned by the tournament runner. Engine settings
explains batch size directly below its control: keep 8 for everyday analysis;
16 or 32 are optional throughput experiments, with a search-feedback trade-off
that means faster processing does not guarantee stronger moves.

Behind the widgets, `BughouseController` owns the two-board line and the
analysis pump; `services/bughouse_engine_session.dart` holds the one live
engine (shared launch, liveness check, once-per-change `Hash`/`BatchSize`,
injected engines released but never disposed); `models/bughouse_notation.dart`
reads joint actions against a position (SAN, seat rows, principal variations,
board shapes) and owns `parseEngineUci`, which the match runner and replay
share; `BughouseHistory.play` is the one path a move takes onto a line.
`services/bughouse_engine_protocol.dart` parses Hivemind's lines and
`services/bughouse_engine_report.dart` assembles the diagnostic block.

Seats are lettered so that a team's letters run together: **A** and **C** face
each other on board 1, **D** and **B** on board 2, making the teams **A + B**
and **C + D** (partners hold opposite colours). *Priority* — the right to
choose whether to move at all, which the team up on the diagonal clock has —
replaces the older "clock advantage" wording throughout the Lab, the book and
BughouseDB: `AB may sit`, `Equal` (the default) or `CD may sit`.

The website's `/bughouse` is a separate static Lab. Its shared Chessground
view is in `frontend/src/bughouse/boards.ts`; `lines.ts` owns independent
history snapshots and `session.ts` owns validated saved sessions and BPGN
exports. Copy moves/download preserve cross-board chronology; Copy link also
preserves forward history and settings. One worker retains WASM and ONNX
between moves/searches/Stop, with a bounded result cache and persistent model
chunks. The [static Lab guide](../tools/bughouse_web/README.md) documents
promotion, keyboard entry, cache boundaries and the required browser checks.

`tools/bughouse_db/hivemind_book.py` builds a precomputed Hivemind book beside
the FICS book (`~/.local/share/chess-prep/bughouse-db/hivemind_book.db`, same
position key): every legal move on both boards, scored for the priority cases
Hivemind can tell apart. A run searches `even` alone unless given
`--priority all`, which halves the work — one search per move instead of two,
and two of the position instead of four. (`both`, where each team has the bit
on, is a curiosity no clock produces and lands within about a tenth of a pawn
of `even`.) One engine, one search at a time, resumable; by default
it follows the four most-played FICS moves of each position to ply 10.
`push` uploads it to BughouseDB (`/bughousedb` on the site); the desktop Lab
reads it, and its engine switch adds each position it scores that the book lacks. BughouseDB's **Analyze locally** fills a missing position
in the visitor's browser more cheaply: 200-node searches of the position, then
200-node searches after only each board's four most-visited moves; every other
legal move is stored unscored and shows "—".

The v2 lab puts FICS continuations under the actual boards, keeps FEN/reserve editing collapsed,
and opens Matches through Actions. Compact engine tables use board/seat headers, aligned scores,
alternating row backgrounds and a highlighted best move. Its `Saved scores` details show engine
identity and node budgets. Both the Python builder and v2 writer retain local per-clock score history
with binary/network hashes, budgets, reported search nodes/depth and calibration; legacy versions
remain unknown. Git snapshots of both local books and restore instructions are in
[`data/bughouse-books/`](../data/bughouse-books/README.md). See the
[v2 lab](v2/features/bughouse-lab.md) for its current screen and data contracts.

Engine failures show the exit code and Windows NTSTATUS name without guessing
which file caused it. **Copy full report** copies the diagnostic block through
`END BUGHOUSE DIAGNOSTICS`, including OS/app/runtime, executable and arguments,
DLL candidates, SHA-256 comparisons, repair results and captured output.
Before each new bundled engine process, the app rechecks engine/network/ONNX
SHA-256 hashes and repairs mismatches from bundled assets. On Windows, CMake
packages the build's x64 VC++ DLLs under `data/bughouse-runtime/` as compressed
files with a size/hash manifest, included in both Setup and the portable ZIP.
Bughouse verifies its private copies against that manifest and restores missing
or altered files, independently of system-wide VC++. Invalid archives, failed
replacement/removal and missing or wrong-architecture DLL candidates stop the
launch and appear in the full report. Only engine-local files are repaired;
Windows system files are never deleted. Hash checks establish file identity;
the actual engine handshake still determines whether Windows can load them.
File/DLL inspection after a startup failure precedes repair; collection errors stay in their section
without discarding the rest of the report. DLL candidates are a filesystem
inspection, not an observed Windows loader trace.

The Windows Hivemind build loads `hivemind_ort.dll` by absolute path beside
its executable, resolves the API from that module handle, and checks API
compatibility before constructing any ONNX objects. Its Unicode Windows entry
point and explicit UTF-8 filesystem conversions preserve non-ASCII profile and
model paths. It reports the actual DLL
path/version on stderr and exits cleanly for missing or incompatible runtimes.
It never falls back to the generic `onnxruntime.dll` in System32 or an older
installation. The engine, complete corresponding source and build hashes live
under [`tools/bughouse_windows/`](../tools/bughouse_windows/README.md); normal
asset fetching verifies that build and includes its source archive. The
runtime bytes remain the pinned Microsoft 1.29.0 build. Windows release gates
exercise an incompatible runtime, corrupt/missing private DLL, and a successful
search with an old basename DLL present in a Unicode installation path.

Windows first-use checks run in the built desktop app via
`integration_test/bughouse_first_run_test.dart`: an empty disposable profile
with spaces and non-ASCII characters, real bundled extraction, app-local VC++
DLL checks, repeated engine searches, and repair of a same-size damaged network.
The Bughouse engine workflow also runs the app boot/navigation tests on Windows;
release builds require that workflow to pass before packaging Windows. Hosted
runners have VC++ installed, so these checks supplement the binary dependency
audit; they do not replace an installer/portable test on a clean Windows PC.

`widgets/board_editor/editable_board.dart` supplies the shared editing surface
to both ordinary board editors and bughouse, after the lichess editor: the
`EditorTool` in `core/board_editor_controller.dart` is a pointer (drag pieces,
drop off the board to remove), a piece brush or the eraser. A brush or the
eraser acts on press and keeps painting while the button is held; pressing a
square that already holds the brush piece removes it; right-click swaps a
brush's colour and otherwise clears the square. Flutter cannot show a piece
as the cursor, so the board hides the cursor and draws a ghost of the tool.
`widgets/board_editor/piece_palette.dart` is the spare-piece strip (pointer,
king to pawn, bin): a drag places once and leaves the pointer in hand, a click
takes the piece as the brush. `BoardWithSpares` in `widgets/board_editor/board_editor_panel.dart` stacks
the far side's strip, the board and the near side's strip, following the
flip. `BoardEditorWidget` binds the surface to `BoardEditorController`; the
bughouse cards bind it to their dual-board state and share the same tool
model and palette. Bughouse king moves update the board atomically before
validating the position. `BoardEditorPanel` composes board, palette and
`PositionSetupPanel` for embedding in both the editor dialog and collection
search. Castling and en passant sit under Advanced. FEN text is a controller
owned draft (`fenInput`, `hasUnappliedFen`); apply or discard it before using
the position, so a malformed paste can never silently select the previous board.

The app driver sets `BUGHOUSE_DB_HOME` to its disposable profile. An explicit
archive override is authoritative and cannot fall through to the user's book.

### Architecture invariants (do not regress)

These rules were added after the generation/traps remediation
(`docs/REFACTOR_PLAN.md`). Violating them reintroduces the "lines don't show"
and "infinite traps" class of bugs.

The v2 Search tab has separate owners: `workspace/fill_gaps.dart` retains the
accepted result publication in `PendingWrites`; `workspace/finds.dart` owns
ordered, frozen SQLite finding batches; `storage/generation_trees.dart` owns
create-only native v4 artifacts with a fixed run id. `workspace/generated_draft.dart`
retains exact new-draft placement through uncertain create acknowledgement.
`FillDone` follows all required saves; explicit retry never recomputes a run or
silently allocates another draft after an uncertain write. See the
[v2 generation contract](v2/features/generation.md#search-publication-and-retry-h5).

1. **One owner of the generated tree.** `GenerationSessionController` holds a
   single `GeneratedRepertoire` bundle (`lib/core/generated_repertoire.dart`)
   containing the tree, `FenMap`, and trap index. All of
   these are derived **once**, in `GeneratedRepertoire.fromTree`, the moment a
   tree is built — never inside a widget `initState`/`didUpdateWidget`.
2. **One definition of position identity.** Transposition keys and trap lookup
   both use `canonicalizeFen4` (4-field FEN). `TrapExtractor` dedups on it and
   `TrapIndexService` keys on it; they must stay in agreement.
3. **Every transposition-following traversal is cycle-guarded.** Any DFS that
   calls `resolveTransposition` / `getCanonical` and recurses into the resolved
   subtree must carry a path-scoped `visited` set keyed on `canonicalizeFen4`
   (see `LineExtractor`, `RepertoireSelector`). Iterative walks must be bounded
   by `maxPlies`/`maxPly`.

---

## Entry points & navigation

### Application bootstrap

```
main.dart
  ├─ AppLogFile.install()    // <support>/logs/app.log receives every warning and error
  ├─ RuntimeSettings.load()  // engine, bulk, display and evaluation preferences
  ├─ EvalCache.instance.init()  // SQLite eval + Maia cache ready for interactive writes
  ├─ EngineLifecycle.loadPersistedState()  // marks engine idle (no process spawn); workers created lazily on first eval
  ├─ DefaultPgnService.ensureExtracted()
  └─ ChessAutoPrepApp → MainScreen  (startup wrapped in `runZonedGuarded`; failures show [StartupErrorApp])
```

| File | Purpose |
|------|---------|
| `lib/main.dart` | `WidgetsFlutterBinding`, `AppLogFile.install()`, `FlutterError.onError` and the `runZonedGuarded` handler (both routed through `log.e`), `runZonedGuarded` startup, window manager, settings init, `EvalCache.instance.init()`, `MaterialApp` dark theme, `AppState` provider (`loadUsernames` on create) |
| `lib/core/app_state.dart` | Global mode enum, usernames, board position, builder↔trainer pending path/line handoff, `pendingGenerationPgnPaths` for PGN-viewer→builder seeding |
| `lib/screens/main_screen.dart` | `IndexedStack` of mode views; engine suspend/resume on leaving/entering interactive-engine modes and on `paused`/`hidden`/`detached` |

### Diagnostics log

A failure the user hit on their own machine has to leave a trace they can
send. `lib/utils/log.dart` is the facade: `log.d/i/w/e`. Debug and info reach
an attached debugger only and are dropped in release; **a warning or an error
is also written as one plain line** — `2026-09-19 14:42:10 ERROR Downloads:
message`, the error, and up to 12 stack frames.

| Destination | Reaches |
|---|---|
| `dart:developer.log` | an attached debugger / DevTools |
| Console (`debugPrint`, every build mode) | the systemd journal for a desktop-entry launch on Linux, the terminal otherwise |
| `<support>/logs/app.log` | the user — Settings ▸ App ▸ **Open log folder** |

`lib/infrastructure/diagnostics/app_log_file.dart` is the file sink: serialized
appends, a session banner naming the version and OS, and rotation to
`app.log.1` at 512 KiB, so two files is all the log ever occupies. `main`
installs it, so unit tests and isolates write nothing; every write failure is
swallowed, because a broken log must not break the app reporting through it.

`showAppSnackBar(..., isError: true)` logs the message it shows, so a report of
"some red error message" can be answered from the log. Remaining `debugPrint`
call sites are listed as a cleanup in [FUTURE_FEATURES](FUTURE_FEATURES.md).

### App modes (`AppMode`)

| Mode | Screen | Primary use |
|------|--------|-------------|
| `tactics` | Embedded `_TacticsModeView` | Tactics from user's own games (Stockfish analysis + Maia line extension) |
| `positionAnalysis` | `AnalysisScreen` | Weak positions from user games |
| `repertoireLibrary` | `RepertoireLibraryScreen` | Import, create and organize repertoire material; explicit Read / Train / Build handoffs |
| `repertoire` | `RepertoireScreen` | Opening repertoire builder |
| `repertoireTrainer` | `RepertoireTrainingScreen` | Spaced repetition training |
| `pgnViewer` | `PgnViewerScreen` | Standalone game PGN + inline engine |
| `study` | `StudyScreen` | Multi-chapter studies |
| `engineTournament` | `EngineTournamentScreen` | Engine-vs-engine matches, crosstable, per-game PGN |
| `bughouse` | `BughouseScreen` | Two-board analysis and matches |
| `databases` | `DatabasesScreen` | Local data inventory, downloads and storage |

Mode switcher: `widgets/app_mode_switcher.dart` — the labelled **View** selector (`Tactics ▾`) on the right of the app bar opens on hover or click with a grouped, text-only menu (Train / Library / Build / Analyse / Lab / Data, order in `kAppModeGroups`); switching views uses this menu, with no Ctrl/Cmd+number bindings.

#### View composition audit (September 2026)

Count independently implemented workflows that duplicate an existing reader,
selector or analysis surface; do not count every extracted widget as a new view.
Smaller widgets with one owner reduce maintenance cost. This audit records the
specific duplicates reviewed in this pass, not a claim that every screen is
finished. Update these rows when adding or retiring a route or parallel renderer.

| View | Duplicate surfaces retired in this pass | Canonical organization / retained feature surfaces |
|---|---:|---|
| Repertoire trainer | 4 (five bespoke reader/phase surfaces → one phase surface) | Library → browser → session/results. `TrainingPhasePanel` uses shared PGN movetext; Read opens PGN Viewer. Mistakes is a searchable panel, not another board/reader. Chapter selection is optional scope. |
| Repertoire builder | 1 | Outline + board/editor + Engine/Database tabs. Repertoire tree and opening explorer are Database sources; background jobs remain in the bottom panel. Whole-repertoire opening bypasses the forced chapter gate. |
| Tactics | 1 | Queue/browser → puzzle. Opening-review cards hand off to PGN Viewer; the nested book/game review dialog is removed. |
| PGN Viewer | 0 | Owns reading, game navigation, analysis graph, collection filtering and book comparison. Book contents and matching lines use the same Book panel. |
| Player analysis | 0 | Compact player selection → `PositionAnalysisWidget`; findings reuse `HolesReportPanel`. |
| Study | 0 | Chapter sidebar + authoring board/movetext + engine. Study/chapter selection uses `showSearchablePicker`; reading and training hand off to their canonical views. |
| Engine tournament | 0 | Results and Engine controls; setup reuses `TournamentSetupPanel`, games open PGN Viewer. |
| Bughouse lab | 0 | Two boards and one contextual side panel. Variant positions, reserves and joint engine actions justify feature-owned presentation. |
| Databases | 0 | One scrolling inventory of data sources; downloads and storage operations stay in their owning cards/dialogs. |

List selection has three reusable forms: visible `ListSearchField` for a catalog,
inline `ChoiceField` for a named choice, and `showSearchablePicker` where the
anchor cannot contain an input. Add-existing repertoires and the tactics flaw-tag
menu now search. Numeric values use `NumberStepper`; short fixed choices use
segments. Action menus (copy, import, delete) are commands, not catalogs. New
reading features should enter PGN Viewer rather than introduce another chess
board + navigation + movetext implementation.

The user's **ChessBook Discord Updates** note informed the line-scoped correction
flow, preserving answers when leaving practice, searchable scope navigation and
stable controls. Listudy was consulted for the guided/repetition flow. We reuse
these interaction principles rather than importing an unrelated training model,
predictive learnability score or mandatory daily quota.

#### Standalone workflow audit (September 13, 2026)

The inventory includes all mode roots and their substantial nested routes,
selection states, tabs and dialogs. A workflow merits a destination when users
can finish a useful job there and several consumers use its output. A board,
settings form or confirmation alone does not merit another mode.

| Current root and implicit views | Ownership decision |
|---|---|
| Repertoire trainer: material picker, chapter/line browser, learn/review/drill, mistakes, results, settings | Material creation and organization belong to **Repertoires**. Keep lesson phases and session results in Trainer; Read uses PGN Viewer. |
| Repertoire builder: outline, editor, Engine/Database sources, build configuration, planner, jobs, audit/traps/coverage/coherence | The outline is shared with Repertoires. Editing and position-dependent tools stay in Builder. Build configuration, queues and audit reports remain attached to the selected repertoire/chapter. |
| Tactics: recent games/downloads, opening review, puzzle catalog/import, puzzle/game tabs, session recap | **My games stays in Tactics**: improve the embedded download, filtering and opening-review UI and keep direct links to Viewer and Player analysis. Puzzle import/catalog can remain Trainer-local until another workflow needs to manage it. |
| Players & prep: All players, searchable Groups, group sheets, imports and linked studies; Player analysis: picker/import, board and engine hunts | **Players & prep is standalone** under Library. People and groups share saved records, with explicit analysis handoffs. The board and engine tools remain in Player analysis. |
| PGN Viewer: collection/import, filters, Game/Book/Explorer/Analysis/Tree panels, annotation and solitaire | Keep it the canonical reader for games, studies and repertoire lines. Explorer/Tree are reusable position panels; adding another top-level reader would duplicate its job. Share game selection helpers with the My games area in Tactics. |
| Study: study/chapter pickers, chapter ordering, annotations, board/engine, reading/training handoffs | Keep Study as the authoring destination. A future material catalog may include studies, but do not merge their puzzle/annotation storage semantics with repertoires. |
| Engine tournament: results, setup, games, engine registry | Already an independent workflow. Registry is shared Settings; tournament game reading uses PGN Viewer. |
| Bughouse: positions, reserves, analysis, game/match setup and archives | Keep the distinct two-board workspace. Its analysis and match controls depend on both boards. |
| Databases: inventories, downloads, local engine-eval stores, own-game storage, recovery trash | Already standalone. Keep storage maintenance here; the My games area in Tactics owns chess browsing/review rather than disk maintenance. |
| Shared Settings: accounts, board/moves, analysis, training, tactics, viewer, repertoires, engines, data, app and shortcuts | Already independent. Keep configuration centralized with contextual links; creation/import belongs beside material. |

**Players & prep** is now implemented as a standalone destination. My games stays in
Tactics. Builds start from a repertoire, with the output chapter explicit in
setup; planning and run history should improve there. Audits remain in Builder:
reviewing a finding requires its line, board and editing context. Improve those
contextual workflows before considering a separate reports catalog. Generation
setup, engine settings, chapter naming and import confirmations remain forms,
not modes. These are ownership decisions; the remaining work is tracked in
[Layout & navigation](FUTURE_FEATURES.md#layout--navigation).

#### Persistent repertoire workspaces

`design_system/layout/workspace_shell.dart` and its
`WorkspaceNavigationController` retain a nested Navigator beneath the toolbar.
Repertoire library, Builder and Trainer own separate instances; mode switches
retain their nested destinations in `MainScreen`'s lazy stack. Popup routes do
not count as workspace pages. Back and Escape target the nested navigator and
respect `PopScope`; root dialogs remain separate modal tasks.

`app/navigation/workspace_destination_toolbar.dart` keeps Actions / View /
Settings and the owning mode label visible. While a picker or configuration
page is open, Actions offers navigation back; board/editor commands remain in
the retained root toolbar and cannot receive focus or pointer input. Keeping
that root toolbar mounted also preserves its live settings registration. The
secondary Settings entry opens that existing owner rather than registering a
replacement. `design_system/layout/workspace_branch.dart` excludes inactive
mode branches from keyboard focus/traversal and restores their last attached
focus destination on return. A root modal keeps keyboard ownership.

The catalog and chapter destinations now have canonical paths under
`features/repertoires/widgets/`; the old `screens/` files are removed. Builder
planning/build/audit routes also use its nested navigator. New Builder/Trainer
source handoffs wait while a nested destination is open; Builder also waits for
active generation. Closing a destination applies a pending request, while an
explicit selection made later supersedes an older request. Builder focus is
reclaimed only while its root is visible in the active mode.

Library refresh now refreshes the injected controller without replacing the
catalog widget. Opening an outline keeps the catalog mounted, preserving its
filter and scroll state for return. `widgetbook/workspace_cases.dart` pairs the
production shell and memory catalog with a small illustrative editor to
exercise retained navigation and creation forms.

This is in-memory navigation retention. Full document-session restart restore,
deep-link routing, retained-branch memory budgets, nested interactive-engine
visibility and frame profiling are still open renewal gates.

Builder's `RepertoireDocumentSession` owns destination, decoded lines, metadata,
load epochs and queued edits independently of the Flutter host. Builder line/move
handoffs await their own load command and validate its generation, destination
and readable content before navigating. Superseded, failed, missing-source or
inactive-mode requests cannot apply to a later chapter; ready same-source
requests remain immediate. There is no shared load waiter or separate line/move
continuation. Failed source
switches retain the current board, selected line and undo; the mounted editor
shows a dismissible error banner. Failed queued edits block later switches and
close attempts until resolved. Tests inject document/decoder contracts instead
of production debug hooks. Opening-graph privacy and durable scratch-session
recovery remain unfinished.

#### Shared document save interaction

App composition selects one `PgnDocumentStore` for the document, Study and
Generation factories. Those factories require that exact store; only
`createPlatformDocumentStore` chooses the native Linux or remaining legacy host
adapter. `StoragePgnCollectionRepository` adds collection patch/recovery duties:
patch observes a snapshot, computes the text replacement, then saves through the
same injected store. Its separate `storage.updateFile` patch writer is deleted.
Collection paths are absolute for either selected adapter.

`features/documents/controllers/document_save_session.dart` owns a loaded
snapshot, current draft and explicit save/reload transitions over injected
`PgnDocumentStore`. It has no Flutter, provider, filesystem or global-service
dependency. `DocumentSaveState` reports saving, saved, dirty, conflict, collision,
failure and uncertain outcomes. Concurrent button submissions are rejected;
text typed during a save remains dirty against the returned committed revision.
Only an accepted receipt or explicit reload changes the baseline. An unexpected
adapter exception is uncertain, never permission to replay a possibly committed
operation.

`saveCopy` exclusively creates and adopts the successful destination. Collision
or failure keeps the original path/baseline; uncertain copy inspection targets
the attempted destination. Inspection never adopts a revision. Reload reads
again and retains the latest displaced draft, including edits made during the
read; missing/unreadable files preserve both text and baseline. Restoring a
retained draft changes editor text only, against the currently loaded revision.

`features/documents/widgets/document_save_panel.dart` composes production
`SaveStatus` with localized save/copy, read-only inspection, reload, keep-editing
and retained-draft actions. It receives a session, destination picker callback
and editor-focus callback. It displays the current destination, never performs
direct disk operations and never retries on dismissal. The repertoire creation
form uses the same status component; a name collision offers focus/selection
of the name while preserving PGN and side.

`widgetbook/document_cases.dart` supplies seven memory-backed cases using this
session and panel. The editor and destination field are fixture hosts, not a
replacement production editor or OS picker. Legacy editor/generator/undo and
chapter writers have not yet adopted this session. Retained drafts live only
for the session lifetime unless its workspace installs a recovery owner. Study
now checkpoints both current and retained drafts (below); other document hosts,
complete workspace restoration, PGN validation and large-document inspection
remain in the document workspace migration.

#### Application close coordination

`app/desktop_application.dart` owns the native window close policy through the
injected `DesktopClosePort`; `infrastructure/desktop/window_close_adapter.dart`
implements it with `window_manager`. Screens never enable/disable prevention or
close the app. The viewer retains its independent fullscreen listener.

`features/documents/controllers/document_close_coordinator.dart` serializes one
close attempt across registered document owners. Every approval carries an exact
revision; changed membership or a later edit invalidates the attempt. Cancelled
or failed checks leave the app open. `DocumentCloseScope` surrounds the navigator;
`DocumentCloseRegistration` tracks each mounted owner, including hidden branches.
Unmounting a feature removes its registration without changing native prevention.
Failed native close restores prevention before surfacing the error.

`StudyCloseGuard` is mounted at app scope because other modes can edit Study
before its screen exists. It awaits queued saves and shows the shared localized
save/recovery panel for dirty, uncertain or retained drafts. Cancel preserves
work; explicit Close without saving approves a revision without mutating it, so
another owner's veto cannot erase the draft. Known failed/uncertain autosaves are
not implicitly replayed. `PgnCloseGuard` now registers at app scope too, including
before the Viewer screen exists, and retains an approved-for-discard draft until
actual application exit. Both Viewer screen navigation and native close use
`showDocumentLeaveDialog` in `document_save_dialog.dart`, subscribed to the
existing save-state stream. Its choice captures the revision at the click;
callers validate that approval before leaving. Screen navigation explicitly
discards approved edits, while native approval retains them until all owners
agree. Pending reader comments are flushed again after awaited autosave before
checking whether the document is clean. `PgnViewerLifetime` constructs and disposes the legacy
viewer/reader/analysis owners; the screen borrows them and only owns its view
listeners and focus. Repertoire
registers pending line-comment saves; repeated failures continue to block closing.
Builder drafts and long-running job shutdown are not yet covered by these guards.
Study and PGN Viewer restart recovery are implemented below; other document hosts
remain pending.

The bounded runner seeds fresh disposable profiles with a declined native desktop
integration offer. This prevents GTK's modal first-run prompt (outside Flutter's
layer-tree screenshots) from swallowing native input/close events. Explicit
fixture choices remain intact; the user's desktop preferences are never touched.

#### Study import and publication

App composition provides `StudyImportRepository` and `StudyImportController`
directly through Provider. The controller owns one admitted collection download
or completed-PGN publication, its native receipt, and any unresolved
`DocumentSaveSession`; it never selects the active editor. The URL dialog owns
its scoped network source and keeps a resolved download until its apply callback
accepts it. Retrying uses current destination options without fetching again.

Collection downloads, Lichess imports and Builder study exports all publish
through the same controller. `StorageStudyImportRepository` creates destinations
exclusively, bounds name collisions, and returns exact submitted content/path
with native outcomes. Uncertain publication exposes the existing document review
and copy actions and participates in app-close confirmation. Ordinary shutdown
settles admitted work. `StudyController` owns chapter append and boolean document
adoption; failed append keeps dirty chapters, and superseded adoption cannot
announce a different active study as the imported result. Its duplicate
`createStudyFromPgn` path and the old `services/study_import/` directory are gone.

Network sources close their injected transport. The owned Lichess API client
cancels backoff/retry timers on closure and rejects pending/future requests.
The import dialog is scrollable at enlarged text sizes; the rest of the legacy
Study presentation remains outside this completed import-safety responsibility.

Study appearance follows the application's committed Dark/Light/System setting,
including its engine controls, PGN editor, dialogs and board-coordinate chrome.
The Study branch no longer installs `LegacyThemeBoundary`. Theme changes evict
rendered PGN rows while retaining document identity, cursor, scroll and drafts.
Board pigments and annotation hues retain their chess meaning; annotation ink
is adjusted for ordinary, hovered and selected surfaces. Shared choice rows use
the active text scale for layout and keyboard scrolling, and board setup stacks
its side-to-move choices instead of shrinking enlarged labels. This appearance
closure does not certify Study's remaining persistence or typed-diagnostic debt.

#### Study document projections

`StudyController` privately owns the mutable `StudyDocument` and `MoveTree`.
Its public `doc`, `chapter` and `tree` getters return detached immutable values
from `features/studies/models/study_projection.dart` and
`chess_core/moves/move_tree_snapshot.dart`. Document/chapter equality includes
session identity, projection kind, chapter key where applicable and revision;
it is separate from the native save baseline. Old values retain their headers,
annotations, glyphs and descendants after later edits. Submitted chapters and
isolate-decoded nodes are copied on adoption, including mutable NAG lists.

`StudyProjectionCache` belongs to the controller. `chapterAt` materializes only
its requested chapter; title and `StudyChapterListProjection` reads never traverse
move nodes. `StudyCursorProjection` carries the current position, path, comment,
glyphs and orientation under its own view revision. Edits elsewhere and save-status
changes preserve that cursor projection. Unchanged chapters retain their projections,
including across reorder. Editing invalidates any cached whole-document projection
so it cannot pin superseded trees while the UI consumes only smaller views. Ordinary edits reconcile
changed node IDs and their ancestors, sharing immutable unaffected branches;
chapter-wide clears rebuild that chapter. Initial/bulk construction is iterative.
The immutable tree's stable editing identity is separate from its content revision,
so annotation fields keep focus as typing produces new views. Root-list reconciliation
still scales with the number of root variations; first materialization remains
proportional to document size. Synthetic 20,000-node measurements are regression
evidence, not a completed native frame/allocation budget.

`chess_core/moves/tree_path.dart` is the canonical cursor value;
`move_tree_view.dart` supplies shared read-only navigation, and
`chess_core/pgn/move_text_writer.dart` serializes both immutable and mutable
views. Mutable position replay stays in `models/move_tree_pgn.dart` for its
unmigrated owners; replay and fresh-ID adoption use explicit stacks to handle
deep lines without recursive decoding. `InteractivePgnEditor` takes the read-only contract; glyph
changes require a host callback. Study dialogs retain chapter projections and
reject edits/deletes when that chapter revision is no longer current. Promoting
or removing siblings and deleting another chapter preserve the viewed position.

`StudySelector` adapts the existing injected Study controller through read-only
Provider subscriptions, with explicit projection equality. It owns no commands
or second document state. `StudyScreen` no longer installs a screen-wide rebuild
listener: title, save indicator, menu availability, chapter list/selection, engine
position/orientation and editor tree/cursor subscribe separately. The board compares
position/orientation and parsed shapes, so prose and glyph edits do not rebuild it.
A board repaint boundary also preserves its painted layer during those edits;
shape changes repaint it. The chapter manager uses the same metadata subscription,
and the chapter picker resolves a stable chapter key after its async dialog.
Chapter rows use stable chapter keys; current-chapter menu identity follows the
selected chapter. Inline rename rejects a switched document/destination.

`features/documents/models/move_text_layout.dart` indexes editor movetext into
bounded move runs and variable-height prose/editor rows. Its iterative traversal
preserves variation order and numbering without recursion or chess replay. Linked
addresses share ancestors; move selection uses node IDs, materializing a path only
for an action. `design_system/layout/anchored_document_viewport.dart` owns bounded row mounting
around a movable anchor, with 240 pixels of prefetch. It receives a feature-free
`DocumentRows` identity/index contract. `features/documents/widgets/move_text_viewport.dart`
adapts editor layout and node selection to that contract without copying the
index on navigation. Distant selections mount their row in the first build,
without laying out preceding rows; selection reveals the exact chip even in a
tall wrapped run. Stable row keys preserve widget state through insertion.
The PGN Viewer's rich reader has not yet adopted this shared viewport.
`InteractivePgnEditor` retains at most 96 recently built rows, reuses them across
cursor changes, and retains the single inline comment draft across eviction.
The layout index itself remains O(nodes + prose), rebuilt on content revisions;
this does not complete incremental indexing, parsing/allocation or frame budgets.

`chess_core/moves/move_tree_projection_cache.dart` shares lazy immutable tree
projection between Study and Builder. Owners record changed ancestor paths before
mutation; untouched branches are shared, bulk changes recapture, and replacing
the private source rotates an opaque editing identity. Cursor notifications reuse
the exact snapshot. Builder's close revision also exposes an opaque identity,
never the mutable core. Line-entry operations that insert moves notify structural
subscribers even when the visible cursor does not move.

`features/documents/controllers/viewer_game_controller.dart` owns the Viewer's
private parsed game, mainline and variation forest. Its public move views are
immutable; mutations resolve live identities inside the owner. The separate
`viewer_game_load_controller.dart` owns asynchronous replacement, immutable load
states and request revisions. Superseded reads, failures and deferred callbacks
cannot publish into a newer selection; closing the reader revokes its requests.
Missing/unavailable source games can use an explicitly supplied solution PGN.

`features/documents/repositories/stored_game_repository.dart` is the injected
source-game contract. `AppDependencies` provides `Provider<StoredGameRepository>` for readers
and tactics copy/add-to-study actions, using the indexed
`infrastructure/documents/archive_stored_game_repository.dart` adapter. Its
connection opener is injected at app startup; the adapter borrows the shared
archive connection and does not close it. This GameStore bridge retires with
training/ingestion milestones 4/5. The old `services/stored_game_lookup.dart`
global helper is removed. Standalone readers can inject `storedGames` directly;
text-only readers need no archive. Header-only updates refresh the Viewer title,
a changed initial FEN replaces its position, and replacing a widget control
handle detaches the old handle.

`viewer_sideline_adoption.dart` validates every stored branch before applying
incoming annotations. Nested prose, introductions and glyphs follow the incoming
source; matching nodes keep their IDs, cursor and scratch continuations. Sibling
reordering preserves matching node views, and unchanged projections are shared.
Only nodes on the exact referenced engine path may extend a stored branch during
annotation adoption. Other structural edits trigger replacement, preventing old
nested moves from surviving a changed document. Duplicate equal-SAN siblings are
matched by occurrence, never merged into one identity. Validation and application
are iterative, including deep variations.

Legacy bridge retirement, undo receipts, bulk/decode allocation and
native frame measurements remain unfinished. Viewer uses the shared bounded
viewport; collection/widget orchestration migration remains unfinished.
Builder still owns legacy storage/session collaborators and needs the remaining
feature ownership, draft recovery and presentation migrations.

#### Workspace restart recovery

`features/studies/models/study_workspace_snapshot.dart` captures name, source path,
original save baseline, serialized PGN, retained drafts, uncertainty (including a
pending copy destination), chapter, cursor and board orientation.
`StudyController.captureWorkspace` serializes only at checkpoint boundaries;
`restoreWorkspace` preserves displaced work and refuses to adopt after intervening
edits during decoding. Restoration never reads a newer file baseline, writes the
source, or resumes implicit autosave. An explicit save still uses the captured
revision; an externally changed source conflicts. Retained drafts also survive
opening another Study document.

`features/documents/controllers/workspace_recovery_controller.dart` owns checkpoint
scheduling, available recovery entries and failure/retry state. A one-second
coalescing timer makes progress during continuous edits, with one in-flight write
and one pending latest snapshot. Errors stop automatic retries and remain visible.
App close awaits the pending checkpoint; shutdown releases its native lease.
Edits made after the last acknowledged checkpoint can still be lost on abrupt
termination before the next write completes; this is not per-keystroke durability.

`WorkspaceRecoveryStore<T>` is the pure feature contract; startup injects
`infrastructure/documents/file_workspace_recovery_store.dart` with a workspace
codec. Each app instance owns a random checkpoint under Support/`study-recovery-v1/`
or `pgn-viewer-recovery-v1/`, written with the existing
journaled atomic writer. Versioned JSON includes a payload checksum and the full
original document revision. Linux flushes the checkpoint directory. A SQLite
transaction held for the session lifetime excludes live sessions across stores,
isolates and processes, and the OS releases it on process death. Directory
recovery precedes discovery; unsupported/corrupt records remain untouched and
are reported. These files contain user work and are not a disposable cache.

`features/documents/widgets/workspace_recovery_host.dart` offers a localized, themed
recovery banner in every mode. Review shows the source and local checkpoint time.
Restore checkpoints the newly adopted draft before resolving the old entry and
opens the owning workspace. Study's existing payload and directory are unchanged;
its former controller/store/host paths are retired rather than re-exported.
Dismiss asks for confirmation and resolves only the selected
revision. Resolution is idempotent and leaves archived bytes on disk; it does not
purge work or affect another session. An archive retention/purge UI and full clean
workspace restoration remain future work. Recovery-store errors expose Retry;
known failed source-file writes are never replayed by the checkpoint service.

PGN Viewer checkpoints serialize `PgnWorkspaceSnapshot`: current text, per-game
persisted originals, source revision, whole-replacement intent, current/retained
drafts, uncertain destination, selected game, mainline ply and board orientation.
Original game text preserves scoped patch matching across restart. An in-flight
write is recovered as uncertain, and restoration blocks implicit autosaves even
if the saved user preference enables them. Decode validates collection length;
intervening edits veto adoption, and displaced dirty text is acknowledged as a
recovery PGN first. Restoring does not resume cached engine-enrichment jobs.
The app owns discovery and close protection before any Viewer screen is mounted.
Only acknowledged checkpoints survive process death; variation cursors, filters,
tabs, panel sizes and complete clean-workspace restoration remain future work.

#### Design system and component catalog

`lib/design_system/theme/` owns `AppTheme`, `AppTypography`, `AppSpacing`,
`AppMotion` and the interpolated `WorkspaceTheme` extension. Both light and dark
factories register the same roles; widgets resolve the current theme.
`app/themed_application.dart` observes only the committed appearance section and
wires both themes and `ThemeMode` into the production `MaterialApp`. Dark remains
the default; Light and System are persisted through Settings → Appearance.
System follows desktop brightness while explicit choices override it.

`features/settings/models/app_appearance.dart` is the stable enum contract;
`AppSettingsRepository.appearance` and `appearanceSettingsProvider` expose its
loading/saving/failed/committed state. `infrastructure/settings/persisted_appearance.dart`
serializes writes to the `app_appearance` preference, reads back before confirming,
and reconciles write errors. Unknown values stay untouched until an explicit
choice; failed loads/saves require explicit Retry or Reload saved choice.
Changing themes preserves the app navigator, active routes, drafts and focus.
The existing analysis/board/data reset does not reset appearance.

Shared Actions/mode menus, breadcrumbs, contextual hints and chapter-picker rows now resolve theme
colors. `app/legacy_theme_boundary.dart` explicitly contains fixed dark panels:
legacy modes; Builder/Trainer root content; Builder planning/audit pages; library
outline; and legacy settings forms. The library catalog, pickers, creation/recovery,
settings navigation and Appearance page use the selected app theme. Remove each
boundary with its owning feature migration; these dark interiors are not certified
light-mode implementations.

`lib/design_system/components/` is the canonical home for `ListSearchField`,
`showNameEntryDialog`, `confirmAction`, `ItemTitle`, `EmptyStatePlaceholder` and
the presentation-only `SaveStatus`.
All existing callers import these implementations; the old files were removed.
Catalog/create/paste UI now uses resolved foreground, error, surface and type
roles. Shared neutral values and font names have one owner; remaining dark
`AppColors`/`AppTextStyles` consumers are listed with migration owners in
`scripts/legacy_theme_consumers.json` (252 after the appearance checkpoint). Architecture
lint rejects new consumers and requires removing retired ledger entries. It
also excludes feature/storage dependencies from the design system and literal
colors/type sizes from migrated widgets.

`widgetbook/main.dart` is a local developer entrypoint with production library,
creation, search and empty-state widgets. Cases cover populated/empty/unavailable
libraries, recovery, and successful/slow/failed creation with memory-only
repositories, picker results and chapter navigation. The theme/text-scale addons
use production light/dark themes at 100/150/200%; the case host preserves that
configuration through pushed routes and dialogs. No real library, account or
engine is initialized, and lint rejects direct storage/singleton access there.
`RepertoireListBody.browseChapters` is the host-owned navigation seam used by the
fixtures; production retains the existing chapter-screen handoff by default.

Run `python3 scripts/app_driver.py start --target widgetbook/main.dart` from the
task checkout, then use the normal dump/tap/screenshot/stop commands. This uses
the same private display/profile and bounded runner as the app; stop it before
checking that tree. `scripts/ci.sh analyze lint` includes the catalog source;
`test/design_system/` and `integration_test/design_system_catalog_test.dart`
exercise actual production controls. Reduced-motion page transitions skip the
fade, and theme-switch tests retain the creation field's draft/focus/selection.

#### Repertoire library and shared creation

The catalog now lives in `lib/features/repertoires/`: `models/`, `controllers/`,
`repositories/` and `widgets/`. `AppDependencies` in `lib/app/` injects the
`RepertoireCatalogRepository` contract, using the explicit
`LegacyRepertoireCatalogRepository` adapter in `lib/infrastructure/repertoires/`.
The catalog contract also lists a folder's chapters for Builder open/copy
selection through that same Provider-injected repository. Listing failures
retain the draft and surface localized feedback.

Manual chapter deletion in the picker and Outline captures a `PgnSnapshot`
through `RepertoireCatalogRepository.prepareChapterDeletion` before confirming.
The catalog validates the actual configured Documents/support roots, trusts an
explicitly configured root alias, and rejects untrusted aliases beneath it.
`deleteChapter(snapshot)` uses the selected document store's quarantine operation
with that root constraint; it never delegates to the old path-only storage delete.
The native store repeats managed-path validation under its existing mutation lock
and shares the repertoire directory domain guard for lexical and canonical paths.
External PGN open/save and the splitter's general quarantine remain supported;
an absent managed root is not created merely to inspect an external document.
Unsupported hosts refuse manual chapter deletion before mutation.

Only acknowledged quarantine closes Outline folds or follows active selection.
A changed view cannot inherit those effects. Uncertainty refreshes observed rows
without treating absence as confirmed removal; its dialog exposes selectable
original, retained-candidate and raw-backup paths, with no automatic retry.
Results identify the original chapter even if a still-mounted caller navigated
elsewhere. Recovery files live beside the source under `.cap-pgn-history`, not
in OS trash or the catalog's repertoire-folder recovery list. No chapter restore
UI is implied. Undo for **Move lines to a new chapter** returns the moved lines
but retains the created chapter; its initial and completion messages say so.
This avoids deleting later additions or header-only edits based on cached line
counts. Line transfer/Undo still addresses games by index; it is not certified
against arbitrary external line replacement or reordering. Folder deletion and
chapter rename/move retain their existing separate behavior.
The adapter is the catalog's only storage/creation caller. One constructor-injected
`RepertoireCatalogController`, owned by the app Provider, keeps independent library
and trainer read snapshots. It rejects overlapping mutations across both kinds,
coalesces refresh, invalidates both kinds' stale reads on mutation, and retains a
submitted commit when its last route/listener leaves. Re-entry explicitly refreshes
the retained snapshot; studies are read only after the trainer requests them. Failed reloads retain the last good snapshot;
a reload failure after a confirmed write is not reported as a failed write.
The list and create/import/paste forms submit domain requests. Form controllers
and search text remain widget-local. Catalog tests override the domain contract;
real-file adapter tests preserve the existing PGN and recovery semantics.

Catalog list/create/paste/recovery copy, tooltips and validation resolve through
`lib/l10n/app_en.arb`, generated by Flutter's `gen_l10n` into
`lib/l10n/generated/`. The production `MaterialApp` registers those delegates
and supported locales; standalone UI hosts must do the same. English is the
source and fallback locale. `repertoire_messages.dart` maps typed failures at
the widget boundary; native exceptions are diagnostic data, not displayed copy.
`FileNameProblem` keeps validation independent of Flutter while the old English
formatter remains for unmigrated callers. Counts use ICU plural rules and
locale-aware number formatting. `localized_time.dart` shares the existing
relative-time thresholds and formats older dates with locale month names and
years. Persisted PGN side values, chapter defaults and existing filenames do
not depend on locale.

Shared search/name/confirmation controls accept resolved labels. Creation
actions use `OverflowBar` so enlarged labels stack instead of leaving the
window. Paste failures are uncapped text in the scrollable dialog and creation/
paste errors are live regions. English expansion fixtures at 100% and 200%
text exercise validation, failed creation/paste draft retention, search, rename
validation and recovery navigation. They are layout checks, not an RTL or
translated-language certification.

Edit the ARB source, then run
`scripts/ci.sh with -- flutter gen-l10n`; commit its generated Dart files.
The bounded check runner regenerates messages before analysis, Flutter tests
and native integration checks, preventing stale generated copy during checks.
Localization dependencies are forbidden in migrated models, repositories,
controllers and infrastructure by the architecture boundary check.

The older singular `features/repertoire/` still owns the chapter organizer,
document editing and generation. Existing picker and codec helpers are retained until their owning renewal
slice migrates; the catalog uses the shared design system above. Boundary checks in local
lint prevent migrated catalog code from importing storage/infrastructure or
accessing global singletons. This is a partial first slice; remaining renewal
gates are tracked in [the execution record](ARCHITECTURE_RENEWAL_EVIDENCE.md#catalog-boundary-checkpoint--first-slice-in-progress).

`RepertoireLibraryScreen` is available under **Library → Repertoires**. It
reuses `RepertoireListBody` for search, direct file/paste imports and repertoire
rename/delete. Opening a repertoire shows `RepertoireOutlinePanel` with its
existing controller/service, independent of a board or engine: folders,
chapters, line moves/reordering, drag/drop and Undo use the same disk operations
as Builder. Chapter selection stays in the organizer. Explicit actions send the
selected chapter to Read, Train or Build; Train repertoire sends the folder.
Opening a line hands its game index to PGN Viewer. Returning to the library
refreshes material changed in another mode.

`RepertoireCreationScreen` is the shared creation route from the library,
Builder and Trainer material selectors. It accepts a name, White/Black side,
file or pasted PGN, or an explicitly empty repertoire. It returns a
`RepertoireCreationResult` without switching modes or loading Builder's last
file. Valid imported material returns to the caller's selection flow; a
multi-chapter course keeps chapter selection. Empty creation returns to the
list without attempting a lesson. Cancel writes nothing, duplicate names are
refused, and write failures retain the form. Direct **Open PGN file…** continues
to import immediately; users need not fill a creation form for that shortcut.
The outline supports moving chapters **into folders** and reordering **lines**;
arbitrary sibling chapter ordering and cross-repertoire drag/drop are not added
by this extraction.

#### Typed PGN document persistence

`features/documents/` defines `PgnDocumentStore`, snapshots/revisions and typed
saved/conflict/collision/failure/uncertain results. Its native implementation in
`infrastructure/documents/` shares `AtomicFileWriter.transaction` and the existing
cross-process mutex with legacy writers. Revisions combine canonical document
path, native identity and SHA-256 of exact stored bytes; decoding does not erase
BOM/line-ending changes from conflict checks. The native package
`packages/document_file_io/` is bundled through Dart code-asset hooks. Reads,
hashes and codecs run off the UI isolate. Prior bytes are retained under each
parent's `.cap-pgn-history/`; post-install failures require reconciliation.

The general `FileMutationService.moveFileNoReplace` boundary also uses the
existing native exclusive move, so a destination created after preflight survives.
It preserves the `FileSystemException` collision contract used by reference-index
publication, generic storage renames and verified update downloads. Linux uses
`renameat2(RENAME_NOREPLACE)`, macOS `renamex_np(RENAME_EXCL)`, and Windows
`MoveFileExW` without replacement; unsupported filesystems fail without fallback.
Linux races and callers are tested; macOS/Windows source paths remain unverified
on their native hosts. This narrow guarantee does not certify captured-source
identity, chapter relocation journals or training-reference closure.

The same boundary exposes `supportsQuarantine` and `quarantine(snapshot)`.
Linux validates the captured native revision inside `FileMutationService`'s
existing parent lock, preserves raw baseline bytes, and moves the source into
that recovery directory without replacing another destination. Success requires
source absence, the retained identity/digest, and directory flushes; ambiguous
post-move state retains both recovery paths and reports uncertainty. An external
editor can race final validation and rename, so this is not identity-based
filesystem compare-and-swap. Legacy adapters report unsupported before mutation.

Linux new-repertoire creation uses the staged publication path below; the remaining
chapter/editor/generation APIs and other operating systems retain their documented
legacy adapters. This is partial adoption, not a repository-wide migration.
See [native-store evidence and limits](ARCHITECTURE_RENEWAL_EVIDENCE.md#native-document-store-checkpoint--linux-adoption-started).

#### Staged repertoire publication (Linux)

`RepertoirePublication` is an immutable map of the complete new chapter contents.
`repertoire_import_planner.dart` builds it off the UI isolate. Shared
`CourseChapterPartition` now owns course partitioning, line/model-game pinning
and safe unique filenames; the existing splitter and planner use the same
implementation. It retains annotations, unknown headers, source chapter order
and line IDs, and handles reserved operating-system filenames.

`NativeRepertoirePublicationStore` prepares every chapter with the typed PGN
store beneath `repertoires/.cap-repertoire-publications/<id>/payload`. Original
import text is retained separately as `source.pgn`. This reserved staging tree
is excluded from the catalog and cannot be renamed/deleted as a repertoire.
A manifest records directory identity and each chapter's native identity/SHA-256.
After preparation, the shared repertoire domain lock protects one Linux
exclusive directory rename into the library. Existing empty folders and
case-folded name collisions are refused; imports never merge into them.

The manifest advances through staged, pending and completed (or cancelled).
Startup/managed-operation recovery does not publish staged drafts. A pending
operation that never moved is cancelled; an installed directory must match the
complete manifest before acknowledgement. Changed/ambiguous contents block
managed mutations with **Recover library**. Incomplete private preparation is
retained, produces an explicit failure and leaves editable input in the form.
This path serves both the catalog and legacy My books creation on Linux.
Existing-chapter splitting/editing and non-Linux creation remain legacy; private
staging retention/inspection UI and process-kill durability gates remain open.

#### Board square feedback (unified September 2026)

Every board marks squares by tinting them; nothing is painted over the pieces.
`BoardSquarePainter` composites one tint per square in a fixed precedence:
the selected square, then `highlightedSquares` (an explicit hint or the move
under the pointer), then `legalMoveSquares` (where the piece in hand may land,
enabled by **Board & moves → Show legal moves**), then `recentMoveSquares`
(the from/to trail of the last half-move, or two in training). Destinations
are whole-square tints rather than dots and capture rings, so a marker never
hides the piece standing on the square it marks.

Hovering a move in a list — an opening-explorer row, the repertoire tree, a
local PGN reference, a generated candidate, a planner row — tints that move's
from/to squares through `BoardPreviewController.setHoverMove(uci)` /
`hoverSquares`, giving a hovered move the same mark a played one leaves. The
repertoire builder and planner boards show the trail of the move that reached
the position on them. A preview that swaps the board's position
(`setPreview(fen, lastMoveUci: …)`) tints the move that produced it instead
of the cursor's own trail.

`ChessBoardWidget.annotations` stays reserved for marks that mean something
other than "this move": red engine threats, the yellow solitaire hint ring,
bughouse drop rings with their piece letter, and the arrows and circles the
user draws with a right-drag or a PGN `[%cal]` / `[%csl]` comment.

#### App bar conventions (unified June 2026)

Every mode screen uses `Scaffold` + `AppBar` with consistent conventions:

- **`titleSpacing: 16`** on every `AppBar`.
- **Top bar**: the left title holds the current material, breadcrumb and contextual status. The right controls are **Actions ▾ → separator → View selector → settings gear**. The shared mode switcher owns the separator and spacing, with the current mode name as its anchor; labelled actions have at least 44px click targets. This separates screen operations from app navigation consistently across views. Actions open on hover or click and use named groups with leading Material icons across modes, with no settings-only ellipsis. Shared operations reuse the PGN viewer’s symbols for copy, import, edit and study actions. Shared Actions and view menus use 32px minimum rows, 13px labels, a 240px minimum width and 16px horizontal insets; faint inset 1px dividers separate groups, adding only 1px before section headings. Both Actions and the view selector support keyboard navigation, Escape and outside-click dismissal. Player Analysis keeps its player picker inside the mode body, below the same Actions / View / Settings bar; selecting or changing a player never replaces that bar. The picker is centered at a maximum width of 1040px, with one Add player button and direct Update games / Change range / Remove buttons per card (file imports only offer Remove). Cards wrap their actions below the metadata on narrower windows. Player analysis retains download refresh beside its subtitle; PGN Viewer retains collection filters on the left.
- **Back navigation**: `AppHistory` records cross-view links. Manually selecting a view starts a fresh trail, including when selecting the current view. The shared toolbar keeps Back visible even when the breadcrumb is too narrow, returning to the previous destination. Mounted screens retain their context. PGN Viewer also captures its live collection, filters, game, reading position and tabs before leaving, so revisiting it with another game does not overwrite the earlier history entry.
- **Settings**: One persistent route with a flat section list, a visible “Find a setting” field that matches section/control keywords, and one scrollable form per section. Wide windows show all section links in a sidebar; narrow windows show a horizontally scrolling section strip with the same search. No Views/Global navigation split or chapter submenus. Existing deep links resolve to the relevant flat section. View gears land on their own form; Study and Player analysis land on shared Analysis, and Databases lands on Data & storage. All compact engine gears use this same Analysis destination.

  | Section | Complete control map and scope |
  |---|---|
  | Accounts | Lichess and Chess.com username fields with explicit Save usernames; optional Lichess connection/logout and inline personal-token fallback. Username drafts survive section navigation and do not trigger downloads while typing. Authentication may open the browser. |
  | Board & moves | Shared coordinates, legal-move hints, piece notation and live preview. Applies to boards throughout the app. |
  | Analysis | Shared CPU cores, memory, board-analysis depth, game-analysis depth, suggested lines and Maia prediction rating. Shared panel/table switches: engine continuations, practical scores (Expectimax), Maia move frequency, engine move-table scores and number of moves shown. Study uses the board controls; panel/table choices apply only to views that render those panels. `BulkAnalysisSettings` owns review/audit/hole-hunt/new-build depth; saved builds retain their captured depth. `EngineSettings.depth` is live board depth. |
  | Training | One form for training mode, review schedule, new/review line limits (explicit Unlimited), correct-answer streak, drill depth, replay mistakes, manual rating, review order, quiz advancement/delay, automatic next line, opponent/intro delays, skipping to comments, current material’s playing side (from file/White/Black), chapter grouping, separator and inline grouping preview. Conditional controls follow the selected training/review mode. Changes persist through the existing training controller. |
  | Tactics | Puzzle order, grouping by game, accepting alternative winning moves, age window/all dates, mistake types, unreviewed-only and one-star filtering. Game downloads directly below: last N games/days, time controls, games per site for repertoire comparison, startup checks and Save download settings. Session preferences save immediately; download drafts apply together so editing does not repeatedly reset the review run. |
  | Game viewer | Playback visibility, seconds per move, continue to next game, PGN autosave, filling missing opening/ECO tags, orientation and current reader’s move-list anchor/expand/fold controls. Reader controls require loaded material. Flip and fullscreen remain workspace actions. Reset game viewer preferences affects the viewer preferences, not engine or global board settings. |
  | Repertoires | White/Black books used for opening review, direct import/add-existing/new/remove designation controls; current builder repertoire’s playing side and board size below. Playing-side changes still use an explicit Apply because they reinterpret the loaded repertoire and remain locked during generation. |
  | Tournament engines | Engine registry directly embedded. Add selects an executable; verification result appears inline; Edit reveals name, memory, cores, pondering and extra UCI fields inside the engine row. Save applies the engine draft; Cancel discards it. These settings affect tournament participants only. Match rules/time controls belong to New tournament. Removing an engine still confirms. |
  | Bughouse (when available) | Hivemind cores, lines, memory, time per pass and batch size. These are separate from Stockfish preferences. |
  | Data & storage | The database management body is embedded directly without navigating away. Master-game years/automatic updates/build usage sit alongside download status. Lichess and ChessDB installation/use/location controls, download progress and maintenance remain attached to their stores; preferences no longer hide under a Settings disclosure. Includes online ChessDB build lookup preference, own-game storage, bughouse archive status, leftovers/trash and refresh usage. Downloads remain explicit actions and permanent deletion confirms. The bughouse archive still requires its existing external build workflow; this settings redesign does not add a new downloader. |
  | App | Installed version, automatic update checks/downloads, check/download/install-on-close/cancel actions, release/project/license links, and explicitly scoped reset of engine/analysis/display/database preferences. Accounts and material are kept; this is not a reset of every view preference. |
  | Shortcuts | Read-only Action / Key / Where reference, backed by `app_shortcuts.dart`. |

  `ViewSettingsRegistry` requests lazy view owners from `MainScreen` without calling `AppState.setMode`: browsing Settings does not change the active workspace, history or handoff. Mounted views retain their controllers; forms are kept mounted after first visit so drafts survive navigation. Closing the route restores focus through the active view’s callback; inactive settings owners never claim keyboard focus. Normal switches and numeric controls save through existing models; account/download/engine drafts and repertoire-side changes use labelled commit buttons. File selection, authentication and destructive confirmations remain separate interactions; ordinary preferences do not open another settings dialog.
- **Layout body splits** at `kCompactBreakpoint` (960 px) from side-by-side to stacked.
- **Action padding** is `right: 8` for all toolbar action widgets.
- **Shared constants** live in `constants/ui_breakpoints.dart`.

### Study document ownership

`features/studies/controllers/study_controller.dart` owns the chapter trees,
cursor, edits and save coordination; `features/studies/models/study_document.dart`
owns the annotated multi-game PGN round trip. `app/study_dependencies.dart` injects
`PgnDocumentStore` and `StudyLibraryRepository`. The controller has no storage
singleton or filesystem import. Linux uses the native identity/byte revision
store; other hosts retain the explicitly content-only compatibility adapter.
`chess_core/pgn/pgn_text.dart` is the canonical pure-Dart split/count/header/text
module. `chess_core/pgn/pgn_parser.dart` owns production single-game syntax
parsing, enforced by architecture lint even in legacy directories. `lib/v2/`
is outside that rule: the rewrite may not import the old app's code and reads
one game at a time through its own `v2/chess/pgn/pgn_reader.dart`. It bounds
long annotated parser-input lines to avoid upstream quadratic suffix copying,
preserves comment/header/escape-line semantics and removes explicit move-number
labels (including `10000.`, otherwise misread upstream as a null move). Stored
bytes and standalone null moves remain intact. Multi-game parsers and specialized
lexical readers retain their existing boundaries. Study tests mirror the feature
under `test/features/studies/`; the shared synthetic course also drives
`tools/bench/study_document_bench.dart` and the native large-document journey.

The Study toolbar's **Save and recovery…** opens the production shared
`DocumentSavePanel` through `DocumentSaveActions`. Move edits mark a revision;
PGN serialization occurs when a save/recovery command captures the draft,
not on every move. A slow write advances only its submitted baseline, retaining
later edits as dirty. Failed saves suspend autosave, including queued debounce
requests; dismissing their presentation, changing modes or disposing the editor
cannot replay them. A confirmed explicit retry/copy or reload reconciles state.
Reload decodes before adoption and retains the latest intervening draft. Restoring
that draft exchanges it with any newer dirty draft without writing either.
The app-scoped Study close guard protects normal window closure. The recovery
owner checkpoints current and retained drafts for restart restoration (below).

Successful **Save a copy…** creates an exclusive new study and opens it. **Save
study PGN as…** exports a captured snapshot through its own typed save session,
leaving the source open and dirty as appropriate. Export asks for a folder and
filename; an existing destination is a collision, never an implicit overwrite.
Failed saves also attempt an exclusive `Recovered …` PGN in the study library.
The retained in-memory draft remains authoritative if recovery-copy creation fails.

`LegacyStudyLibraryRepository` bridges existing library listing, path naming,
rename and quarantine deletion. Relocation retains the pre-move content/identity;
it cannot silently adopt an external edit as the next write baseline. Those
namespace operations still require the document-workspace journal/reference
migration; this bridge does not certify their full renewal exit gates.

### Repertoire builder workspace

The wide workspace keeps chapters on the left, the board in the center, and
moves/comments above Engine / Database tabs on the right. Database sources are
Engine evals (generated locally), ChessDB, Repertoire, Opening explorer, and
Local PGN. No permanent bottom reference dock or duplicate Expectimax panel is
shown. The eval source shows a legal-move table first; depth, cores, engine-move
count and Maia coverage live in a persisted settings overlay accessible from its
gear and the Actions menu. Import PGN and disk refresh also live in Actions.
TWIC download status belongs inside the database surface. The comment editor is
labelled Comment and expands on click or annotation focus.

The [interactive JS design reference](../design/repertoire-builder/index.html)
is a standalone mockup using sample data, adapted from the supplied
[Chess.ceo reference](https://chess.ceo/). Serve that directory with a local HTTP
server or open the HTML directly. It is a layout reference, not a chess engine.
Flutter retains the app's typography, theme and real data sources.

Chapter switches keep the workspace mounted with a thin loading indicator and
temporary input lock. Initial opening still shows a loading state while files
are read and parsed. Debounced line saves capture their destination and content;
reloads flush and await queued writes before reading, and late writes cannot
change the newly opened chapter's in-memory state. Board
navigation sits immediately beneath the board. Go to start preserves the loaded
line and annotations so Forward can continue through it.

```
RepertoireScreen (composition root — wires controllers to widgets)
  ├─ RepertoireController (document coordination, opening tree, lines)
  │    └─ RepertoireBoardController (private MoveTree + cursor; pure Dart)
  ├─ RepertoireOutlineController (features/repertoire/controllers) — the repertoire folder as
  │     OutlineFolder/OutlineChapter/OutlineLine; every edit hits disk then rebuilds;
  │     fold state (expanded folders, unfolded chapters) lives in OutlineFoldState
  ├─ GenerationSessionController (TreeBuildService, CoherenceService, tree/config/fenMap, job)
  ├─ AuditSessionController (RepertoireAuditService, result/liveFindings/progress, persistence, job)
  ├─ CoverageController (CoverageResult, progress)
  ├─ BoardPreviewController (hover preview FEN)
  ├─ JobManager (background generation/audit tracking)
  ├─ TrapIndexService
  │
  ├─ Wide (≥ kCompactBreakpoint):
  │     Outline column (resizable, collapsible → "Chapters" strip)
  │       beside a workspace containing:
  │         Board + NavControls | Moves + Comment (InteractivePgnEditor)
  │                             | Engine / Database tabs
  │         Database source menu: Engine evals | Repertoire | Opening explorer | Local PGN
  │     Outline content = RepertoireOutlinePanel, or the optional line-metrics view
  │     BottomPane (collapsed by default, full width): Findings | Jobs
  │
  ├─ Compact (<960px):
  │     Column: Board (flex 4) | ToolsColumn (flex 5): PGN | Chapters | Database | Engine
  │
  ├─ Actions ▾ → Generate from here… opens Database → Engine evals; its build action and the outline chapter menu open BuildConfigScreen → RepertoireGenerationTab;
  │     Audit button / chapter menu → AuditConfigPanel
  ├─ RepertoireStatusBar (clickable badges → toggle bottom pane tabs)
  └─ optional TrapWalkthrough overlay
```

**Outline panel** (`features/repertoire/widgets/repertoire_outline_panel.dart`): header (Chapters, options menu with counts/metrics, collapse, `+` = New chapter…), visible search field, position filter in a menu; tree rows for folders (nestable, expand/collapse), chapters (active one highlighted; unfold to show lines; course-composer `[White]` sections shown as uppercase section headers), lines (name + move preview + ply count; model games italic). **Selection**: Ctrl/Cmd-click toggles a line, Shift-click extends; a selection lives in one chapter and a drag or menu on any picked line acts on all of them. **Right-click / long-press menus**: empty space → New chapter…, New folder…; folder → New chapter here…, New folder here…, Rename…, Move to…, Delete folder…; chapter → Open, Generate lines into this chapter…, Audit this chapter, Train this chapter, Rename…, Move to folder…, New chapter next to this…, Split into chapters… (course exports only), Delete chapter…; line → Load on the board, Train this line, Rename…, Move [N lines] to chapter…, Move [N lines] to a new chapter…, Delete [N lines] (no confirmation — the toast has Undo). **Drag & drop** (a mouse drags at once; touch after a press): a line onto a chapter row appends it, between two lines (top/bottom half of the row, drawn as an insertion line) lands it there — in another chapter or its own (reorder); lines onto a folder or the foot drop zone (shown only during a drag, = the top level) start a new chapter there, named after the first line; chapters and folders onto folders or the foot zone (a folder cannot be dropped into itself). A closed folder/chapter opens after the pointer rests on it 600 ms; the list auto-scrolls near its edges. Edits that carry `OutlineEditOutcome.undo` show their existing completion message and Undo action. Manual chapter deletion separately confirms recovery retention and reports its typed result; uncertainty opens a recovery-evidence dialog. A line that crosses files keeps its training progress: `ReviewProgressRepointer` pins `[LineID]` into the game and re-points the review CSVs (shared with the chapter splitter). Names go through the shared `showNameEntryDialog` with `RepertoireOutlineService.validateName` plus a same-folder duplicate check. Line edits address games by file index (`RepertoireLine.gameIndex`) because the move-based line id truncates and collides for lines sharing a long prefix.

**Chapter split safety:** The app provides one outline service using its selected
`PgnDocumentStore`. The existing outline controller rejects concurrent structural
edits until the admitted edit and refresh finish. A split creates destinations
through that store, then saves the remaining source against its captured
snapshot or quarantines an exhausted source; unsupported quarantine is refused
before any destination exists. Only confirmed source mutation permits progress
repointing. Partial failures refresh the outline and show selectable acknowledged
chapter paths separately from candidate/recovery paths, with no automatic retry.
A progress failure says the files committed and were not rolled back. New
repertoire imports reuse the existing pure chapter planner on every host;
legacy import no longer writes a temporary Main chapter and then splits/deletes it.

**Planner (`lib/features/planner/`, “Plan starting lines…”)**: full-width planning mode (`PlanBuildScreen`) accepts several named move sequences from the initial position, one per row (`Name | 1.d4 Nf6 …`). Users can add/remove positions, select a root to preview or extend on the board, and return from review to edit the starts. **Choose ECO openings…** opens the shared catalog picker: search by code/prefix or opening name, tick multiple named lines, preview their boards and edit their moves before adding them as named starting lines. Existing nonempty starts are preserved; duplicate/overlapping roots use the same validation as typed lines. `models/plan_starting_line.dart` canonicalizes legal SAN and rejects invalid moves, duplicate positions and overlapping ancestor/descendant paths instead of silently truncating input. `controllers/plan_controller.dart` owns the walk; its chapters and build points live in `controllers/plan_chapter_ledger.dart` and what a question shows (knowledge overlay, ordering, pre-ticks) in `controllers/plan_candidate_assembler.dart`; `services/san_paths.dart` plays and compares SAN paths. `controllers/plan_runner.dart` names chapter files with `CourseChapterPartition.fileNameFor` and retries on `OutlineNameTakenException`. **Guided choices** runs the opening-book or own-games quiz across every supplied root; Back and Finish now preserve the remaining roots. Own-games thresholds are relative to each root’s sample. **Use these positions** skips the questions, starts with the ChessDB compact profile and sends one named chapter per root to review. The review validates build settings before generation, permits renaming/removing chapters, and preserves settings when returning to setup. Generation limits apply per build point.

The quiz uses `services/eco_trie.dart` to identify opening forks and `services/plan_data_source.dart` for ECO names, Maia probabilities and ChessDB evaluations. `services/plan_knowledge.dart` overlays existing chapter choices and the user’s games. `PlanController.startMany` keeps distinct root chapters and walks their branches in order; no build runs during planning. Review returns `PlanBuildResult`; `PlanRunner` creates chapter files through `RepertoireOutlineService`, then queues each `PlanBuildPoint` through `GenerationSessionController`. Every request carries its complete starting move prefix and the standard PGN root, so KID, Fianchetto and London continuations all export from move one.

**Toolbar**: title/breadcrumb (repertoire ▸ chapter switcher) · `Actions ▾` — one sectioned menu (`AppMenuEntry.heading`): GENERATE (Plan the lines…, Generate from here…) · IMPORT (From a PGN…) · TRAIN (Train this chapter) · CHECK (Audit for gaps…) · mode switcher · settings gear (Repertoires form in the shared flat Settings screen). "Play the moves myself" and "From my games" were removed in Sept 2026: both are the planner's job (moves played on the board at a question; the "My games" walk).

**Key files:**
- `lib/core/generation_session_controller.dart` — owns the run and the generated-tree bundle; pause/resume/cancel survive dialog disposal; `dispose()` stops build. The controller creates its registered job from the captured request before notifying UI; `currentJob` is read-only. `GenerationProgress` owns the single elapsed clock and shared notification throttle. Ordinary stats and phase changes publish at most every 250 ms (formerly 100 ms job stats plus a second 250 ms screen timer); admission, pause/resume/cancel and completion flush immediately. Late disposed callbacks cannot restart its timers. Mid-run line export lives on `SnapshotExporter`, which directly borrows the stable progress and tree-builder objects. The screen retains only coherence/one-shot presentation rules, and the Jobs panel calls controller commands directly.
- `lib/features/audit/controllers/audit_session_controller.dart` — owns `RepertoireAuditService` + audit state + persistence; pause/resume/cancel from any widget
- `lib/features/coverage/controllers/coverage_controller.dart` — owns coverage result + progress state
- `lib/widgets/layout/bottom_pane.dart` — resizable, collapsible, tabbed bottom pane (Findings/Jobs — the Lines list lives only in the side panel)
- `lib/features/audit/widgets/audit_findings_panel.dart` — findings list with category filter chips, auto-scaled to ~20 findings, bulk dismiss, keyboard navigation, and interrupted-audit resume banner; dismiss context menus use `showAnchorMenu` (shared with the holes report)
- `lib/features/audit/services/audit_persistence.dart` — centralized save/load for audit snapshots (result + config + resume state)
- `lib/widgets/layout/jobs_panel.dart` — jobs panel: one compact card per active generation/audit job (phase, live stats, threads/hash, progress bar, controls); completed jobs as simple tiles; no duplicate status banners
- `lib/widgets/repertoire_lines_browser.dart` — line search/filter/group browser; now the outline column's *metrics view*, not the default
- `lib/features/repertoire/widgets/repertoire_board_pane.dart` — board, annotations and retained hover-preview owner composed directly by Builder
- `lib/widgets/chess_board_widget.dart` — board + annotation overlay (arrows, circles, labels)
- `lib/services/jobs/repertoire_job.dart` — background job manager; `RepertoireJob` includes `configSnapshot` (serialized `AuditConfig.toMap()`) for audit jobs

**Bottom pane (VS Code-style):** Collapsed by default (zero height). Auto-opens to Findings tab when audit starts, Jobs tab when generation starts. Tabs show badge counts. Resizable by dragging the top edge (min 120px, max 60% of screen height). Collapse via close button, `Escape` key, or double-click the drag handle. The `onClose` callback clears inline config flags so that reopening the pane does not show stale config forms. `Escape` both collapses the pane and resets inline gen/audit config state.

**Findings tab UX:** Category filter chips (Blunders/Inaccuracies/Missing/Weak/Dead Ends) with counts — multi-select toggles. Findings are sorted by reach probability (cumulative likelihood of the line occurring). The visible count is capped (default 20) and user-configurable via an inline text field in the status row; as findings are dismissed, lower-probability ones surface automatically. Each finding tile shows its reach probability right-aligned (e.g. "12.3%"). When capped, the status row reads "Top [N] of M · X% – Y% reach". Bulk dismiss via right-click context menu: dismiss similar, dismiss at depth, dismiss all of type. Keyboard: ↓/↑ to cycle findings (board navigates within full repertoire tree), dismiss through the row menu — navigation is routed through `RepertoireShortcuts` at the screen level (active when the Findings tab is open in the bottom pane), delegating to `AuditFindingsPanelState.selectNext()` / `selectPrevious()` / `dismissSelected()` via `GlobalKey`; ↑/↓ also work when the findings panel has focus. Selected finding is highlighted. Timestamp shows when saved results were generated.

**Line metrics view (outline column):** The old `RepertoireLinesBrowser` (search/filter/sort, coverage/ease/coherence columns, gap buttons) plus the Lines/Traps segmented toggle, reached from the outline header's metrics button; "Back to chapters" returns to the outline. The screen composes `TrapsBrowser` directly when the existing trap session has traps (default sort: Eval Drop, also Most Common/Trap%/Surplus) with mini board preview, per-reply stats with classification badges, and expandable detail cards. `BoardPreviewController` is threaded through; a `FloatingBoardPreview` overlay is mounted in the view's `Stack`.

**Database tab:** The Repertoire source shows `OpeningTreeWidget`, an interactive opening tree explorer built from the repertoire's PGN lines via the same `OpeningTreeBuilder` as the PGN viewer (Actions → Tree). Course-style `*` games fold RAVs in; frequency shows as **paths** (including variations) when there is no W/D/L. The cursor is FEN-keyed: a different move order that reaches a known position still shows that position's continuations, and a position the PGN never reached still lists legal moves that transpose into book (marked `≈`). Navigates with back/forward and syncs with the board via `RepertoireController.userSelectedTreeMove` (plays from the board cursor so the user's move order is kept). When no opening tree is available (empty repertoire), shows an empty-state message.

The separate Tree tab has been removed. Database offers the repertoire tree and
live opening explorer and local PGN databases through a compact source switcher.
The selected source is remembered. Explorer games open in a separate reference
viewer at the board position, preserving the repertoire cursor. `ExplorerGameOpener.fetchPgn`
fetches the game without adding a copy to a collection.

**Local PGN** (`features/repertoire/services/local_reference_database.dart`,
`widgets/local_reference_pane.dart`): choose any standard-chess PGN, switch among
eight recent paths, or refresh after changing the file. A cancellable isolate
streams one game at a time into a SQLite cache under
`<application cache>/repertoire-reference/`. The original PGN is read-only.
Completed indexes are keyed by source path, size, modification time and schema
version; incomplete builds use private staging directories and are not reused.
The index stores original single-game PGNs, a canonical-FEN game index and
pre-aggregated move counts. All mainline positions, including terminal positions,
are indexed; each game contributes only its first continuation at a repeated
position. Transpositions merge, FEN starts are supported, and illegal/unsupported
mainlines are skipped with a visible count. Variations and annotations are
preserved for reading but do not inflate played-game statistics. Unknown results
count as games, not draws.

Move statistics and matching games appear side by side at wider dock sizes;
narrow docks use Moves / Games tabs. Search filters the matching games by player,
event, site or ECO; it does not change the position's move statistics. Queries
run off the UI isolate, return at most 50 PGNs per page, and discard superseded
results. A move row plays the move; its explicit `+` adds it to the repertoire.
Game rows reuse `PgnTreeGamesList` with host-owned search and paging, and open a
separate board/notation dialog. This source supplies browsing evidence; automatic
generation continues to use its existing configured sources. Copying moves stays in
the PGN editor context menu. Repertoire selection uses compact searchable rows:
clicking a repertoire opens it directly (Builder opens its first file with the
full outline available), while Browse chapters is an optional action.

Generate starts bounded exploration: the union of Stockfish candidates and Maia
moves covering the requested probability at every position. Compact controls
start at four engine moves and 60% Maia coverage. Scores update during expansion;
completed-position and depth counters stay visible. A move row's play-circle
evaluates that move once and saves its engine PV without tree generation or an
invented expected score. See [bounded database exploration](ALGORITHM.md#bounded-local-database-exploration).

**"Generate from here" button:** In the nav controls bar, a `+` icon button opens the generation dialog pre-seeded with the current position FEN.

**Board annotations:** `BoardAnnotation` model with `AnnotationBrush` (green/red/blue/yellow/purple). `_AnnotationPainter` renders arrows (shaft + arrowhead) and circles on a `CustomPaint` overlay above pieces.

**Keyboard shortcuts:** `lib/utils/app_shortcuts.dart` owns every app-command binding and its Settings reference. `RepertoireShortcuts` dispatches the shared entries, with text-field guards in `keyboard_shortcut_utils.dart`.
- `↑` / `↓` — previous/next finding or trap-tour stop
- `←` / `→`, Home / End — navigate moves
- `Ctrl/Cmd+Z` — undo last repertoire add
- `Ctrl/Cmd+Shift+V` — paste FEN from clipboard
- `Escape` — close the current panel
- `F` — flip the board (outside text input)
- `E` — toggle engine analysis (outside text input, including comment and move fields)

View-switching Ctrl/Cmd+number shortcuts, bare letter commands other than `F` (flip board) and `E` (toggle engine), slash, panel-Tab, numbered fork/planner choices and Shift+arrow trap jumps have been removed. Their mouse controls remain available. Unassigned actions have no chords, dispatch no keys and show no shortcut suffix in shared tooltips.

Digit shortcuts (bottom-pane tab toggles `1`/`2`/`3`, edit-mode NAG `1`–`6`, star ratings, etc.) are **not** bound.

Breakpoints: `constants/ui_breakpoints.dart` (`kCompactBreakpoint=960`, `kWideBreakpoint=1100`).

Actions menu groups view operations; the trailing gear opens `screens/settings_screen.dart` with contextual settings.

---

## Major data flows

### V2 downloaded games

The renewal app's download path lives under `lib/v2/`; the legacy tactics
import path remains separate.

| Component | Implemented boundary / API |
|---|---|
| `features/tactics/my_games.dart` — `MyGames` | Captures account names for a run, fetches each site independently and queues only persisted corpus rows for review. `load()` consumes `AccountsSnapshot` / `AccountsUnavailable`, retaining prior names and blocking new downloads on read failure or any owner's unresolved account-write obligation. `downloadProblems`, `corpusProblems`, `accountsUnavailable`, `retryDownloads()` and `retryUsernames()` drive explicit save/read retries. |
| `features/tactics/download_saves.dart` — `DownloadSaves` | Freezes returned games, site, username and time into per-corpus `PendingWrites` obligations. `accept()` and `retry()` retain failed outcomes across owner disposal and retry without HTTP; successors wait behind unresolved writes to the same corpus. |
| `storage/my_games_files.dart` — `GamesCache` | `keep()` returns `GamesKept` / `GamesNotKept`, publishing deduplicated PGN bytes before the `.fetched` note. Dedup uses site ID or trimmed PGN text when metadata has no ID. Typed `snapshotNewest()` separates absent input from an unreadable corpus. Unverified stamp staging files are refused and preserved. |
| `storage/my_accounts.dart` — `AccountStore` / `PreferencesAccounts` | Immutable `AccountsSnapshot` plus owner `revision`, or `AccountsUnavailable`. `setDownloaded(..., expectedUsername:)` serializes with username writes and refuses a changed account; failed optimistic preference timestamps stay masked until acknowledged. The legacy `read()` compatibility wrapper still maps unavailable to empty, but `MyGames` uses `snapshot()`. |
| `features/tactics/my_games_block.dart` — `MyGamesBlock` | Shows separate account, download-save and saved-corpus-read errors. Retry uses the retained operation or rereads saved inputs; unresolved errors cannot display an overall completed result or authorize a new download. |

The accepted HTTP response is retained in memory, not in a persistent queue.
It survives screen disposal; a crash before corpus publication can lose it.
Published corpus bytes are the restart checkpoint and remain readable offline
when a later freshness write fails. A restart may refetch using the old
freshness; deduplication preserves an already published batch. No persistent
HTTP spool is implied. Native publication/lost-ack retry tests
cover both create and append without duplicate games. Freshness is a subsequent
write, not part of an atomic corpus transaction. Mining checkpoints and the
remaining H5 jobs are tracked in the
[renewal contract](ARCHITECTURE_RENEWAL.md#durable-work-and-job-lifetimes).

Behavioral coverage: `test/v2/features/tactics/download_saves_test.dart`,
`my_games_test.dart`, `account_persistence_test.dart`, and
`test/v2/storage/my_games_files_test.dart` / `my_accounts_test.dart`. Native checks
run on Linux; no Windows/macOS durability claim follows from them.


### Repertoire load & edit

```
RepertoireListBody (embedded inline or in RepertoireSelectionScreen)
  → RepertoireCatalogController → RepertoireCatalogRepository.listRepertoires()
  → injected legacy storage adapter → List<RepertoireMetadata>
  → user picks RepertoireMetadata → onSelected callback → setRepertoire / loadRepertoire
  → BuilderWorkspaceController (draft/recovery owner) + RepertoireDocumentSession (chapter/serialized writes) + RepertoireBoardController (editable tree/cursor)
  → InteractivePgnEditor (pure view: tree + path props, action callbacks; memoized move widgets; context-menu path highlighting)
  → Screen binds title/edit commands directly; workspace observes board edits for autosave
  → Screen supplies clipboard copy and View in Lines; no intermediate editor wrappers
  → OpeningTreeWidget (unchanged — read-only statistics tree)
  → injected RepertoireDocumentRepository → DocumentRepertoireRepository → shared PgnDocumentStore (native on Linux)
  → injected RepertoireDecoder → IsolateRepertoireDecoder → atomic application of chapter load results
```

### Native engines (Stockfish + Maia)

```
Stockfish:
  tools/fetch_assets.py (also fetches the bughouse bundle) | CMake/Xcode (if .gz missing or stale) | in-app download
  → assets/executables/*.gz  (gitignored; pubspec bundles the directory)
  → StockfishBundle.ensureExecutable
      → verify checksums, gunzip (or unpack upstream tar.gz/zip) into AppPaths.supportDirectory()
      → refresh cached engines when the platform + release checksum stamp changes

Maia:
  assets/maia3_simplified.onnx + vocab JSON  (tracked in git)
  onnxruntime plugin  (.so / .dll / universal .dylib, auto-copied into the bundle)
  → MaiaService.initialize → OrtSession
```

macOS GitHub Releases are two zips (`macos-arm64` / `macos-x86_64`). Each has the
same universal Stockfish 19 engine; `ditto --arch` also thins the universal ONNX Runtime dylib.
Release packaging uses `zip -ry` so framework `Versions/Current` symlinks are
stored as links (plain `zip -r` packed Stockfish/Maia/Flutter three times).

The Builder Jobs view binds directly to its existing generation, audit and job
registry owners. `JobsPanel` listens to all three, invokes their controls, and
hosts the existing snapshot-export dialog; only navigation to configuration
stays with the screen. `JobsTabContent` and its command-forwarding callbacks
are retired. Audit cancellation persists progress using the audit session's
captured source, including resumed/queued runs; an idle cancel remains a no-op.
Snapshot-export input stays alive through the closing transition. A cancelled
dialog cannot act on a late lookup, and pending keyboard submissions do not
start another lookup.

### Tree generation (expectimax pipeline)

```
GenerationSessionController (owns TreeBuildService + CoherenceService)
  ← RepertoireGenerationTab submits a captured GenerationRequest and publication receiver
  ← Screen/JobsPanel call pauseBuild/resumeBuild/cancelBuild/finishNow directly
  ← BuildConfigScreen hosts manual configuration; it closes when a run starts.

GenerationSessionController (run ordering, cancellation and publication)
  → controller.cancelBuild() → drain owned partial staging before cleanup
      (selected partial generation survives cancel)
  → EngineLifecycle.enterGeneration(threads)
  → controller.buildService.build(TreeBuildConfig)    [Phase 1 BFS — Stockfish/Maia modes]
    OR
  → controller.buildService.buildFromPgnFreqMap(…)    [Phase 1 DB Explorer mode]
      → parsePgnFiles (isolate) → PgnFreqMap
      → BFS expand from freq map
      → _enrichEvals (cache → external chain → Stockfish batch)
  → calculateTreeEase + EcaCalculator                 [Phase 2]
  → calculateMyEase                                     [myEase on our moves]
  → RepertoireSelector + LineExtractor
  → TrapExtractor → in-memory trap index
  → GenerationArtifacts.prepareBundle → immutable tree/probes/traps/partial proposal
  → CourseBuilder → sequential probes + composition → course and immutable counts
  → GenerationPublicationController → source PGN commit + Builder receipt
  → GenerationArtifactRepository.select → matching current artifact generation
  → EngineLifecycle.exitGeneration()
```

`CourseBuilder` owns the four enrichment passes in order: refutations,
alternatives, engine tails and master improvements. Disabled, engine-free and
cancelled work skips preparation; preparation errors fail export, while engine
startup and probe errors leave that pass empty and allow later passes. Database
suppliers remain live at each pass. Counts derive from the local results and
return with the composed course; the session uses a local export result for its
summary. There is no separate enrichment runner, count reset or session mirror.

**Build modes** (enum `BuildMode` in `generation_config.dart`, UI labels in parentheses):
- `stockfishExpectimax` ("Stockfish Expectimax (recommended)") — default; Stockfish MultiPV + Maia opponent, traps auto-detected
- `maiaDbExplore` ("DB Win Rate Only (no Stockfish)") — Maia moves, DB evals only, no engine at build time
- `dbExplorer` ("From Added PGN Files") — requires PGN files added via `PgnSourcesPanel` (file picker or paste); does **not** use lines already in the repertoire PGN; parsing → frequency map → BFS tree → eval enrichment
- `chessDbBook` ("ChessDB mainline book") — one move per position, whichever ChessDB ranks best (exact ties to the more-played master move); opponent replies from master practice only, unsmoothed; off practice (or past `maxPly`) the line continues as a single ChessDB mainline to `bookTailMaxPly`; a line ends where ChessDB's knowledge ends unless `bookEngineFallback` puts the engine underneath as a floor (off by default — it is what makes the mode need Stockfish at all, and it is slow); Phase 2.5 never runs. Needs the local TerarkDB dump or the ChessDB API. See the mode's section in `lib/services/generation/README.md`

**Generation config, two layers.** The always-visible form starts with What to build (source, traps-only, PGN sources), then Opponent and Search. Engine builds expose the Maia rating and Pure/Fast search. ChessDB books instead show master replies and Book size: branching depth, total line limit, reply count, reply coverage and time budget. Their summary describes database mainlines, not Maia or expectimax. The source expander labels ChessDB as required. The Generate pane’s **Build ChessDB repertoire…** action opens a configuration route at the current board position, prefilled with the ChessDB profile. The explicit **ChessDB compact repertoire** preset (also offered beside the ChessDB mode) follows the King’s Indian harness: 20 branching plies, 34 total plies, up to 5 replies after the root, 90% local reply coverage, 12,000 nodes / 120 minutes, one API request at a time, ECO chapters, no engine fallback. It is a starting profile, not a promise of a fixed line count. Master games must be present for opponent branching; the form offers their download when missing. Saved presets and a live summary remain below the controls.

Everything else is in the **Advanced** dialog (`AdvancedSettingsDialog`), ten focused sections in build order: Opponent model · Move choice · Search tuning · Master games · ChessDB book · Verification · Coverage & line order · Chapters · Explanatory variations · PGN source filters. Both layers edit the same controllers, so they cannot disagree.

A section whose knobs cannot apply to the current build source renders one sentence saying why instead of a card of greyed-out controls (`AdvancedSection.unavailable`); it keeps its table-of-contents entry so it stays findable. ChessDB book, Verification and PGN source filters use this. The main form's `PgnSourcesPanel` is simply absent unless the source is My PGN files — the attached files live in `PgnSourcesController`, so they survive a round trip through another build source.

The Builder opens configuration explicitly. The form keeps its existing initial-config/last-config precedence, validation and presets; opening it does not start a run. There is no external PGN-seeding handoff or frame-polling seed API. The obsolete Viewer-generation handoff had no producer, and the former empty-traps discovery branch could not render inside the nonempty-traps view. Build and Cut configuration captures its chapter inputs when the route opens. New commands require that route and the same successfully loaded document generation to remain current; source replacement, including A→B→A, or closing the route rejects admission with visible feedback. Build captures its publication receiver before changing run settings; that admitted receiver survives the normal route close. Cut receives an acknowledged removal count and an immutable remaining-line projection from its exact successful refresh. Only that receipt advances the route generation; unavailable refresh requires reload and does not authorize another cut. The open Cut route retains its original tree/configuration/ranking if a successful edit invalidates the global artifact, and computes subsequent removal counts from the acknowledged remaining lines. This source-generation guard does not provide filesystem identity validation against external writers.

**Where the form's sub-editor state lives.** The three sub-editors are views over controllers `GenerationConfigFormState` owns — `EvalSourcesController`, `SkeletonPlanController`, `PgnSourcesController` — not `GlobalKey`-addressed widget state. Each of their widgets sits behind an expander or a build-source switch, so none is guaranteed to be mounted when the form seeds it (`_applyInitialConfig`) or reads it back (`toConfig`); owning the state lets the widgets be built conditionally and removes the post-frame seeding hop. `EvalSourcesController` pairs `applyConfig` with `applyTo`, the two halves of the config round trip, in one file.

The form retains uneditable settings in its immutable seed configuration rather than mirroring them in hidden text controllers or booleans. Presets replace that seed; visible controls supply explicit overrides. Existing defaults, range limits, clamps, text trimming and mode-specific normalization remain in force. Start validates editable fields first, then inherited values with the same range validator, so a visible error takes priority when both are invalid. The inherited error still blocks Start after the visible field is corrected.

"Finish Now" stops Phase 1 BFS and proceeds to Phase 2 on the partial tree; discarding an unfinished build asks for confirmation first.

See `docs/ALGORITHM.md` for algorithm detail.

### Database exploration and one-click add

Builder composes `RepertoireDatabasePane` directly. Its local explorer sends
selected moves to the existing board owner; Add to repertoire calls
`RepertoireWriter.addMoveAtPosition` with the current path, then advances the
board. Receipt-backed `undo` remains the same writer responsibility. Generated
evaluations use the database pane's existing source selection and generation
view. The unused browse/suggestion panels and their candidate pipeline are
retired; they are not a second production route.

### Coverage

`CoverageCalculatorWidget` starts the existing coverage controller/service.
Results feed the live repertoire lines browser, line metrics and tree coverage
annotations. The retired suggestion panel/service had no live screen caller;
coverage calculation and its regression tests remain.

### Audit

Configuration opens as a route; results stay in Builder's bottom pane.
See [the audit feature](#libfeaturesaudit) for lifecycle and persisted report details.

```
AuditConfigPanel → AuditSessionController.launch
  → engine setup → RepertoireAuditService.audit → engine cleanup
  → guarded progress and findings → AuditFindingsPanel
  → chapter-specific partial / complete snapshot

AuditFindingsPanel
  → chapter, checked positions, settings tooltip, source warnings and errors
  → Priority / Frequency sort, move/line search, type and clash filters
  → configurable cap, stable selected finding, board navigation
  → dismiss / restore / bulk dismiss, keyboard navigation
  → interrupted report: Resume original scope / Start fresh

Controller state:
  → AuditResult + liveFindings + interruptedSnapshot + progress + _activeRepertoireId
  → Repertoire scoping: onRepertoireSwitching(oldPath) cancels in-flight audit, saves progress to old path, clears all state; tryRestore(newPath) has stale-async guard (discards late loads if user switched again)
  → Board annotations: screen reads controller.result for arrows (mistakes=red, inaccuracies=yellow, missing=blue)
  → JSON persistence: *_audit.json beside repertoire PGN; partial progress saved on cancel/dispose via controller.saveProgress()
  → Interrupted audits: controller.tryRestore() sets interruptedSnapshot; controller.launchResume() passes skipFens + priorFindings
  → Shared eval via EvalCache (SQLite-backed, FEN → white-normalized CP + depth)
  → Coverage %: only missingResponse FENs in denominator (dead-ends excluded)
```

### Traps

```
TrapExtractor (during generation)
  → TrapLineInfo list → GenerationArtifacts bundle staging
  → GenerationArtifactRepository selects/loads the verified generation
  → TrapIndexService (FEN index, line prefix index, metrics)
  → TrapsBrowser, TrapDetailCard, TrapNavigationButtons, PGN trap dots
```

### Coherence

```
CoherenceService.compute(lines)
  → extractItemset per line → Isolate.run(runFpGrowthMining)  // FP-Growth off UI thread
  → clusters + lineCoherence scores on main isolate
  → repertoire lines browser metrics, coherence sorting and low-score highlighting
```

### Engine analysis

Engine rows in `InlineEngineBar` show the evaluation
in a fixed left gutter, followed by one continuous numbered PV in regular weight.
Rows use `EnginePvRow`: compact rows, hairline separators and a cool slate surface
distinguish analysis from the neutral PGN canvas. All engine-provided moves are
available, without a fixed move-count cap; each row can expand to show its full
line. The shared PV-row preference limits collapsed wrapping in every instance (one row
by default); each slot reserves that many rows even for short or pending lines.
Move taps and hover previews work throughout the line, including the first move.
The inline toolbar is 24px tall and reserves compact PV slots during streaming
to keep the PGN stable, including when wrapping is enabled. Expanding a line opens
a fixed six-row viewport; subsequent PV updates scroll within it without moving
the following rows.

```
Settings → Enable engine analysis → EngineLifecycle.toggleOn/Off
InlineEngineBar (Builder, Viewer and tactics)
  → its existing BoardEngineSession → shared BoardEngine / EvalWorker
  → discover at the selected FEN; coalesce live PV updates
  → persist normal Stockfish discovery to EvalCache on completion
  → hypothetical threat search uses threatPositionFen and skips cache writes
  → move/PV hover uses the existing floating board preview
Generated evaluation views use the saved tree; the live trick probe retains
ExpectimaxLineService for practical continuations.
```

Active board panes prepare one shared Stockfish process before the first toggle.
`EngineLifecycle` owns the persisted toggle for these panes. Toggle-off sends
UCI `stop` and keeps the idle process, network, hash and configured threads warm.
Turning it on starts a new search with the retained hash; it does not continue
the stopped search's stack or depth. Leaving the last board, backgrounding the
app, or starting generation releases the process. Returning prepares one again.

The engine responsibilities are separated as follows:

| Component | Owns | Contract |
|---|---|---|
| `BoardEngineSession` | One pane's attachment and search ownership | `prepare`, `discover`/`evaluate`, `pause`, reversible `detach`, terminal `dispose`. Detached panes cannot search. An old pane cannot cancel its successor; same-position views share discovery and live PVs. |
| `BoardEngine` / `EngineWorkerSlot` | Latest interactive request and one lazily initialized worker | Coalesce startup, reject late connections after teardown, update settings while idle, retry a retired worker once. Pausing keeps the process. |
| `EvalWorker` | UCI transaction and result parsing | Serialize readiness, options and searches. Cancellation completes the caller promptly while the worker drains through `bestmove`; old output never belongs to a new FEN. Ten-second readiness/stop timeouts retire the transport. Disposed workers are unavailable. |
| `EngineSearchBudget` | Search-thread admission shared by board and bulk workers | FIFO, cancellable admission; grant up to the requested threads from free cores. Release only after `bestmove` or retirement. Idle processes consume no search allocation. |
| `StockfishPool` | Bulk worker provisioning and exclusive worker checkout | Generation and background jobs create workers on demand. All searches use the same `EvalWorker` contract. Finished generation releases unleased workers. |
| `EngineSerialQueue` | Ordered asynchronous transactions | A failed transaction still reaches its caller, while subsequent work can run. Install the queue tail before invoking potentially reentrant callbacks. |

The core setting caps admitted board-plus-pool search threads. A search keeps
its allocation until it ends; lowering cores takes effect at subsequent search
boundaries. With competition a board can receive fewer threads; those options
are changed only while idle. FIFO admission does not preempt an existing long
search: a queued job waits for completion or cancellation. This budget covers
`EvalWorker` consumers, not external MCP processes, engine tournaments, Maia or
Bughouse. It is not a total RAM cap: idle workers still retain their hash and
network allocations. Generation still suspends interactive analysis explicitly. Its transition is
serialized; repeated entry preserves its original toggle preference, and
failed provisioning restores the prior state without blocking later toggles. App resume cannot reopen board analysis
during generation. The board API still accepts a FEN, so it does not supply
the move history Stockfish needs to identify repetitions before that position.
Retaining the hash does not reconstruct that history.

The ordering follows the [Stockfish UCI documentation](https://official-stockfish.github.io/docs/stockfish-wiki/UCI-Protocol-and-Stockfish-Commands.html):
`readyok` may arrive during a search and cannot acknowledge `stop`; `bestmove`
ends that search, and options belong between searches. This is also the pattern
in [Lichess's ceval protocol](https://github.com/lichess-org/lila/blob/master/ui/lib/src/ceval/protocol.ts)
(current work survives until `bestmove`, with pending replacement work) and
[Scid's engine communication](https://github.com/benini/scid/blob/github/tcl/enginecomm.tcl)
(command/reply sequencing around stop and restart).

On the mobile FFI fallback, `StockfishPackageConnection` accounts for
`package:stockfish` 1.8.1's [dispose implementation](https://github.com/ArjanAswal/stockfish/blob/master/lib/src/stockfish.dart):
quit is a stdin write that requires the ready state. An adapter disposed during
startup cancels its waiters immediately and quits a late successful start;
error/disposed states require no quit write. Adapter lifecycle tests inject the
package engine, so desktop unit tests do not need its native library.

Regression checks live in `test/services/engine/{board_engine,eval_worker_protocol,engine_search_budget,stockfish_pool}_test.dart`,
and the actual pane widget tests in
`test/widgets/inline_engine_bar_lifecycle_test.dart`.
They cover delayed/stale output, stop timeout and replacement, queued cancellation,
CPU sharing, settings changes, hidden panes, warm toggles and teardown. For a
native Linux check, set `STOCKFISH_EXECUTABLE` to the extracted bundled binary
and run `scripts/ci.sh test test/services/engine/native_board_engine_test.dart`;
it measures paused process CPU ticks, checks process/config reuse and verifies
exit on the last detach. Without that environment variable the native test skips.

Inline engine hover boards follow the main board perspective in Repertoire,
PGN Viewer, Player Analysis, Planner, Studies and Tactics. Stepping through a
line preserves that perspective regardless of whose turn it is; flipping the
main board also refreshes an already open hover board.

### Training

```
RepertoireTrainingScreen
  → app/training_dependencies.dart (production composition)
  → features/training/controllers/TrainingSessionController
  → injected source/review/header/answers/settings contracts
  → infrastructure/training adapters and existing format owners
```

Training session, phases, chapter scope and review progress have canonical
owners under `features/training/`; the old `services/training/` libraries and
`models/training_settings.dart` are removed. Models no longer persist themselves.
Epoch guards reject stale source, layout, settings and rating completions.
Line-completion persistence resumes failed stages without tallying twice.
`TrainingHistoryOperation` retains exact before/after CSV contents in the adapter:
a retry recognizes a previously installed append, writes only the expected
before-state, and refuses intervening history changes. Identical newly accepted
ratings have distinct operation identities. The existing error panel retries the pending action;
failed header mirrors remain queued. This retry state is in memory; crash-resume
remains a separate requirement.

`TrainingSessionController` owns finish → persist → tally → advance for both
linear and spaced runs, including automatic ratings while no result widget is
mounted. `TrainingResultsPanel` is a stateless direct consumer: it neither
schedules work nor mirrors session fields. Manual Next, skip, restart, exclusion
and repeat completion cannot bypass a pending/failed completion. Existing Retry
resumes the captured result; a different run receives a distinct attempt identity.
`ReviewProgressStore` captures source/reviews/moves before queuing disk stages,
serializes distinct attempts and joins retries of the same attempt. Source reload
waits for admitted writes and deferred header mirrors before capturing a new
source. Cancelling a line retains in-flight, partly published and uncertain
outcomes; these keep their original source context and block a new load until
settled. Generation checks suppress old tally/error/advancement. A definitive
source rejection before any participant writes can require a fresh load. The redundant
rating-button wrapper and all-caught-up panel are retired.

`TrainerBrowser` receives the existing session directly for chapter scope,
Learn/Review, per-line practice and bulk-known commands. The screen retains
only navigation callbacks; browser-local search, sort and checkbox selection
stay in the widget. Its chapter inventory includes read-only model games even
when those chapters contain no trainable lines. Bulk-known and exclusion edits
share the existing progress write queue and publish only after acknowledgement.
Bulk proposals capture every selected source before waiting; their previous PGN
mirrors must drain before newer schedules are written. Unrelated failed mirrors
do not block another source. A partial edit failure offers **Reload saved progress**,
never a blind retry: committed schedules may survive while history/PGN mirrors
remain incomplete. A successful durable review read clears the block (optional
presentation work may still fail); a failed read does not. Reload does not replay
the edit. Abandoned failed completion/rating outcomes also require reconciliation.
Source changes reject stale commands before publication; unresolved partial
outcomes retain their retry material and visible errors stay with their captured
source generation. Checkbox drafts also retain their original
line-list identity and cannot save after source replacement or reload. Read opens
explicit unsaved Viewer content; it cannot overwrite the training source.

Each loaded source carries a `TrainingSourceContext` captured from the PGN
read. Reviews, move progress, history and attempts validate it under the shared
recovery domain before publication, including their first row. A source turn
serializes these writes with publication and acknowledgement of its own header
mirror. The canonical platform selection lives in
`app/document_dependencies.dart`: Linux validates native identity and bytes;
the explicitly selected legacy adapter on Windows/macOS checks content only
and cannot distinguish replacement with identical bytes. Arbitrary external
writers do not share the app's locks.

`AppDependencies` provides and initially loads one `TrainingSettingsController`,
using the existing `SectionSettingsOwner`; an injected override remains owned by
its caller. The separate Training queue, stream, repository/storage contracts
and patch type are retired. Panels and the session listen to the same concrete
owner. `TrainingConfiguration.changesFrom` captures only changed persisted keys;
the shared patch/storage contracts distinguish absent fields from explicit null
(removal of optional training depth). Committed values, pending drafts, failures
and Retry use the same machinery as engine/display/evaluation settings. Fresh
reads and serialized writes preserve concurrent edits. `PreferencesTrainingSettings`
retains the existing flag-last default-cap migration and uses the shared scalar
storage adapter, including checked removal acknowledgements. A sitting captures its committed configuration, including auto-next
lines, and later changes apply while browsing or at the next sitting. Initial
settings load failure blocks training startup and uses the same retry path.
Drafts are in memory, and partially completed multi-key writes are reconciled
from storage before retry; cross-process transactions are not implied.

Train opens a repertoire directly; chapters remain an optional filter. Whole-folder
sessions include each chapter and retain its original per-file review identity.
Learn and Review have no default session cap (a chosen cap remains available in
settings). Read sends the selected chapter or whole repertoire to the canonical
PGN Viewer. During learning, the shared `PgnMovetextView` reveals only played
moves and keeps introductory prose with the first move; a compact Next control
stays in a fixed footer. Drilling advances quietly and shows prose only after a
wrong answer. Corrections replay only missed moves from the current line; an
Again rating schedules later review without reintroducing earlier lines into
the current run. Every answer is durably recorded before progression in
`repertoire_move_attempts.jsonl`, including source, line, position, played and
expected moves and phase. The trainer's searchable Mistakes panel opens the
matching line for reading. `MoveAttemptStore` keeps this history attached when
lines move or split into chapters, and when an owned chapter or repertoire
folder is renamed or moved.

Trainer loading shows the current stage (preparing lines or restoring progress),
reuses the last parsed source when its contents and training side are unchanged,
skips unchanged review-file writes, and computes builder-tree difficulty in a
worker that returns only per-line scores. Difficulty preparation runs in the
background unless the selected queue order requires it. Reading and training use
the builder's saved PGN and stable line identities; edits require reloading the
trainer's source. Keyboard ratings **1 / 2 / 3 / 4** select **Again / Hard / Good /
Easy** on the manual review result screen, with interval previews and shortcut
tooltips. These keys remain text while an input has focus.

Trainer view organization: source browser, lesson and results share the same
board/panel frame. One phase panel replaces separate intro/learn/drill/replay
views and move-pair cards. The independent chapter reader was removed; PGN
reading belongs to the canonical viewer. Mistakes is a list in the existing
side pane, not a separate screen.
Training uses Actions → view picker → gear. The gear opens the single Training form in shared Settings. **Skip** is visible during a
lesson and leaves a line out for the current sitting without rating it.
**Line → Exclude from training** saves an exclusion alongside review progress;
excluded lines remain readable and can be restored from their line options.
They do not contribute to Learn/Review counts or either scheduling queue.

### PGN viewer (Open PGN)

Opening a collection reads its text and indexes game headers off the UI thread;
the selected game becomes readable before collection-wide opening classification
and position indexing. A thin progress bar identifies this background work while
game navigation remains available. Saved filters are restored before reading
(and may require opening classification); the previous game and ply are retained.
A manual board flip becomes the fixed perspective for subsequent games; selecting
a player perspective restores automatic orientation for that player.
Shared horizontal reader controls, breadcrumbs, filter strips and evaluation
graphs accept vertical mouse-wheel scrolling, including in Tactics. Horizontal
trackpad scrolling is retained, and vertical scrolling passes to a surrounding
scroll view when the strip reaches its edge.


**Actions ▾** offers icon-labelled **Edit**, **Show opening / Hide opening**, **Show Engine / Hide Engine**,
**Evaluation graph / Tree**, **Copy Game PGN**, **Copy mainline PGN (no comments)**,
and **Copy FEN** (the overlapping-squares copy icon). The mainline copy keeps the
active game's headers, starting position and result, stripping all comments,
variations and annotation glyphs from the clipboard copy. The full-game copy
retains annotations; neither option changes the source game. Copy FEN copies the currently displayed board position, including
when viewing a variation or reference game. **Export** contains **Export as PGN…**, **Export as SCID…**, and
**Add to Study** (or **Edit study** for an open study). File exports use the
current filtered collection, whose count appears in the submenu; pasted
collections can also be exported. There is no collection clipboard action.
Actions and the mode picker open on hover or click and dismiss 250ms after
the pointer leaves the anchor and menu rows, including nested submenus;
keyboard navigation, Escape and outside-click dismissal remain available.
**Tree** opens one tab with a **Collection / Database** selector. The collection
toolbar puts **Filter** and the detected player’s **White / Black** toggles on
the same row, with horizontal scrolling in narrow panes. Collection tree explores
the filtered games with single-line move rows and result bars capped at 180 pixels.
To export games reaching a position, use **Filter → Current position → Apply filter**,
then **Actions → Export → Export as PGN…**. Position filtering matches mainlines
and variations and combines with the other active filters; there is no separate
tree-position export action. Database explorer offers
Lichess, Masters and local TWIC sources.

Opening details are hidden by default; **Actions → Show opening** saves the
choice and displays the opening name with its ECO code in normal body text.
Code-only PGNs resolve a name from the bundled opening book. ECO detection and
filtering remain independent of this display choice. Normal reading has no PGN
edit banner or mainline heading; **Back to game** appears only in variations or
comment previews. **Edit** opens the annotation panel with a white **Comment:**
label and field outline; **Done** leaves edit mode.

The engine is hidden by default. **E** reveals and enables it on the Game tab;
further presses toggle analysis without hiding the panel. This shortcut is
suppressed while typing or in solitaire. **Show Engine** opens the Game tab with an
inline switch, a **Show threat** target button and compact settings for **Cores,
Lines, Depth and Memory**. These controls use `EngineSettings.instance`, shared
and persisted with global engine preferences. Threat mode evaluates a hypothetical
pass (opponent to move, en passant cleared), displays threat lines and a red
board arrow, and resets when the position changes. It is unavailable in check
or at game end. Threat lines offer board previews but cannot be inserted into
the real game's move list, and their evals are not cached as game evaluations.
Turning the engine off, hiding it, or leaving the active Game tab releases its
worker. Game viewer settings contain playback and board/move controls in one form; view settings
content is capped at 728px including padding so controls remain beside labels.
Move-quality glyphs on mainlines and variations, inline analysis verdicts and their borders, and
the analysis move list use the shared NAG palette: blue inaccuracies, amber
mistakes, red blunders and pink interesting moves. Selecting a move preserves
its glyph color.
The evaluation graph uses opaque near-white and near-black advantage fills
on a charcoal plot background so both sides remain distinct. Its full-game horizontal
extent and fixed ±8-pawn vertical scale remain stable while scores stream in;
new offscreen evaluations neither animate old points nor reset scrolling.
Navigation scrolls only when the selected move leaves the visible area. Sparse
saved evaluations use their actual ply for tooltips and selection. Tactics review
also scores the final position when the opponent moves last, and records terminal
draws directly, so its saved graph covers the whole game. The graph opens without
a saved-position-count banner or a separate “Analyze full game” prompt.

**Filter games** opens a normal **Filter** tab beside the board. It starts with
one blank Field / Rule / Value row and a 40px **+ Add filter** control. Field and
Rule use searchable `ChoiceField`s; values search the loaded collection's cached
header values, preserving separate White/Black lists and showing compact game
counts. Result also suggests `1-0`, `0-1`, `1/2-1/2` and `*`. Selecting a suggestion
resolves Contains/Regex to Exact while preserving bounds and exclusions; typed
text keeps its selected operator. Bright column labels and text, outlined inset controls and consistent input
heights distinguish Field, Rule and Value, including the initial blank row.
Selecting ECO exposes catalog browsing inside that row’s Value control; selected
codes can be reopened and edited without replacing other ECO conditions. Each player field accepts one name (PGN commas remain
part of the name).

A **Combine AND / OR** selector applies to all active header, position and move
sequence conditions. **Positions** and **Move sequence** are collapsed unless
restored with active filters. Positions accepts multiple FEN/move inputs, with
**Add position** and a single source selector per row (current board, setup, or
remove an additional row). The choice and all positions survive saved-filter
round trips, chip removal and Tree player presets. AND requires every position;
OR accepts any condition. Indexed and replay searches use the same semantics,
including positions in variations; a saved legacy filter defaults to AND.

Matching games use the shared `PgnTreeGamesList`, with compact titles and optional
move previews initially hidden. The list fills the remaining pane below the
scrollable conditions, with **Apply filter** always available in the footer. Preview titles, arrows and
result badges use secondary text colors so the editor remains prominent. Applied
conditions appear as uniform 112×44 gray tiles beside the collection title. Each
tile stacks the value above the field/rule, truncates both lines, shows the full
condition on hover and opens the editor on click. Its separate × removes that
condition. AND/OR separators retain the combination rule; the muted **Add filter**
action extends the same set. Additional tiles scroll horizontally.
Tree retains **[Player] as White / as Black** when one player occurs in at least
80% of the collection; Filter uses its editable rows instead of shortcut buttons.
The mode selector shows only the current mode name, without a “View” prefix.

In the reader, **Enter** focuses a variation. **←** steps back through its root
to its parent, restoring any parent focus and reading position. **Esc** first
returns to a manually scrolled reading position, then returns to the parent
variation, then follows the existing mode-exit behavior. Parent and focus
controls use quiet text buttons with registry-backed shortcut tooltips.
The Viewer indexes its reading document with the pure
`features/documents/models/viewer_document_layout.dart`. The iterative index
preserves mainline/variation order, folded branch heads, solitaire visibility,
engine suggestions and repeated prose references. Move runs contain at most 24
plies; comments stay with their move. `PgnMovetextView` builds only viewport rows
through the shared `design_system/layout/anchored_document_viewport.dart`, also
used by Study and Builder. Navigation reuses the index; document, disclosure or
visible-branch changes rebuild it. Prose parsing and widgets are created only for
mounted rows, and inline comment drafts survive row eviction. Very large single
comments remain whole passages; this is not a paragraph-size or memory-budget
certification.

`PgnReadingPane` supplies its scroll controller and layout-time anchor policy.
Parent bookmarks retain a stable row key plus an offset relative to that row's
viewport origin, so distant re-anchoring does not invalidate focus/return history.
The renderer preserves the 900px reading column, prose widths, diagrams, inline
move previews and selected passage headings. `MainlinePositions.positions` now
shares one immutable list per replay revision instead of copying the entire
mainline for each rendered comment.

Move navigation anchors during viewport layout, before the new selection paints,
without a scroll animation or a frame at the previous scroll offset,
so vertical jumps across long notes stay in step with the board cursor.
Move anchoring is bounded by the document with bottom clearance for the floating
controls (32px when none are shown): games whose title, moves and notes fit stay
at the top for every anchor setting.
Long chapters retain the selected anchor while content remains below it;
near the end, scrolling stops at the document boundary instead of revealing
a screen of blank space.
**Settings → Shortcuts** shows a compact, bordered Action / Key / Where table with keycaps. Bindings and reference rows live together in `app_shortcuts.dart`; there is no separate list of handwritten mappings. Shared settings cards use 10px vertical row/header padding and 12px group gaps, with a 680px content cap to keep labels and values close together.

PGN collection edits now belong to
`features/documents/controllers/pgn_collection_editor.dart`. Viewer consumers
call and observe this one edit owner; the metadata mixin is retired.
`PgnCollectionRepository` is injected at construction, with production setup in
`app/app_dependencies.dart` and its storage/native adapter under
`infrastructure/documents/`. `ViewerDocumentController` owns read/decode, request invalidation and
adoption through the injected collection repository and `PgnCollectionDecoder`; the production isolate adapter calls the pure
`chess_core/pgn/pgn_collection.dart` codec. Leading banners survive indented/CRLF
headers and headerless movetext in copies and recovery. File, paste, close, navigation and
recovery replacement share request invalidation. Late read/decode/metadata
successes and failures cannot publish to a newer collection. The host rechecks
manual-draft protection immediately before adopting a completed load.
`PgnLibraryRepository` supplies recent-file existence, browse parents and the
collection directory; direct Viewer `StorageFactory` access is retired. Startup
selects its storage adapter and the directory supplier. The unused slice-export
write bypass is removed; production export retains the shared exclusive-copy
interaction.

`features/documents/controllers/viewer_collection_controller.dart` owns file
membership, visible indices/order, sort preference and selected game. The host's
`allGames`, `filteredGames`, `currentGameIndex` and `sortMode` are read-only.
Adoption captures caller-owned membership, filters validate indices atomically,
and navigation restoration validates both order and selection before adoption.
Sorting publishes fixed lists and uses file position to break ties; previously
published order cannot change through an in-place sort. Applying and clearing
filters respect the chosen sort before notifying. Selection shares the
existing lists, including large collections; identical views retain their revision
and list identities. The pure sort helpers now live in
`chess_core/pgn/pgn_game_sorting.dart`, with the old core path retired.

Decoded in-memory documents enter through `adoptDecodedCollection`, which applies
draft protection and invalidates outgoing work before publication; paste uses this
same handoff. The screen awaits `selectGame` before deciding whether cached
analysis is ready, and a superseded selection reports false. Identity membership
rejects delayed annotation callbacks for departed games before they can mutate
the old game or dirty the new collection; hidden games in the current filter remain
valid edit targets. These lists protect
membership/order only: `PgnGameEntry` contents still use the legacy mutable editor
model, so complete private game-value ownership remains pending.

`features/documents/controllers/viewer_filter_controller.dart` now owns accepted
filter selection, immutable config/index snapshots, request lifetime, failure
state and saved-filter restoration notices. The slice mixin is retired.
Overlapping requests obey the latest intent; reset, close, navigation and
same-selection reapply revoke older work. In-place document changes rerun the
pending intent against fresh records before publication. Failed matching keeps
the previous selection and releases loading. Restore with no matches keeps the
whole collection; a deliberate zero-match search remains a valid active filter.
The host still orchestrates reader/tree/sort presentation and preference writes.

`PgnCollectionFilter` is injected into both the Viewer owner and full filter
workspace. Its infrastructure isolate adapter shares the pure predicates in
`chess_core/pgn/pgn_slice_filter.dart`; the old services library is removed.
Indexed queries still narrow candidates before replay, and only queried position
lists are captured from the FEN index. The full workspace retains its separate
editable draft, error/retry and debounce UI; callbacks reject replaced or edited
source revisions. The generation inline editor still calls the infrastructure
compute helper until its own workflow migrates. Full collection presentation,
filter-widget theme/localization and broader session ownership remain unfinished.

`features/documents/controllers/viewer_presentation_controller.dart` owns
board orientation and fullscreen intent without Flutter or native imports.
`viewer_perspective.dart` holds immutable perspective values, header conversion
and exact-name/surname orientation; absent or ambiguous players retain the current
orientation. Collection player detection lives in
`chess_core/pgn/pgn_collection_players.dart`. Manual flips become the reading
preference for later games without changing an active solitaire side.

The final Viewer part/mixin is retired. Startup injects `DesktopFullscreenPort`;
`infrastructure/desktop/window_fullscreen_adapter.dart` owns the native listener
for the Viewer app lifetime, independently of screen mounts. Initial reads cannot
overwrite newer native events. Rapid toggles/exit requests serialize behind the
in-flight operation and retain the latest intent; errors remain retryable, and
disposal detaches events and ignores late completions. The host reports window
errors without erasing newer document errors. The remaining collection and reader
presentation still use the legacy host and widgets.

The editor owns rating/comment/perspective changes, screen-only solitaire substitutions,
per-game persisted baselines, the autosave timer and serialized writes. Perspective
changes update the stored-text header separately from any drill-only annotations,
so changing the view neither loses the header edit nor saves temporary guesses. It captures
an outgoing collection before awaiting and only updates the active collection's
mtime/index if that collection still owns the receipt. Later edits stay dirty.
Failures block queued/automatic source writes; already queued snapshots still
get distinct recovery copies, including the collection banner. An explicit Save
can retry a definite failure. An uncertain acknowledgement cannot be replayed;
the retained recovery copy and original require review. Viewer now uses the shared
typed Save and recovery panel for inspection, reload with draft retention, restoring
a retained draft and exclusive Save As. Reload/restore acknowledge a recovery PGN
before displacing dirty work; a failed recovery write or a newer edit vetoes adoption.
Restoring a draft keeps the captured reload revision as its explicit replacement
baseline. It never silently adopts a newer disk revision. Scoped dirty state uses
per-game baselines, without serializing the collection on UI notifications.

Each adopted collection now has a private edit ledger inside
`features/documents/controllers/pgn_collection_editor.dart`. Navigation retains an
opaque `PgnCollectionEditContext` bound to its creating editor, path and ordered
game identities. Returning restores persisted game originals, dirty tracking,
screen-only substitutions, baseline, outcome and automatic-save block together.
An outgoing receipt updates its own ledger whether it arrives before or after
return; it cannot report an error, mark busy or stamp another collection. The
serialized write queue remains editor-owned, while pending-write counts belong
to individual ledgers. Separate partial-clear commands and outcome/block
`Expando` maps are retired; save outcome, error and autosave settings expose
read-only getters and explicit commands.

Save Copy creates a separate destination ledger with the acknowledged baseline;
older navigation handles retain the source baseline and any source conflict.
The existing retained-draft chooser remains editor-session-wide, so recovery
choices survive opening a pasted collection. These in-memory contexts are not
a durable navigation-history format or private immutable game values; app
restart still uses the workspace recovery and reading-session contracts.

On Linux, the repository observes the current source, patches only uniquely
matching original games, and commits through `NativePgnDocumentStore`. Unrelated
bytes and the pre-save native history are preserved. A change between observation
and validation conflicts without retry; this does not eliminate the documented
external-editor race after final validation. This is a scoped game-text merge,
not a claim to detect every replacement since the collection was first opened.
Native writes require an absolute path. Other hosts retain the serialized legacy
storage adapter until their native gates pass. Pasted-collection Save As and PGN
exports use the same exclusive-create repository contract. The destination form
only returns a filename and absolute folder; optional native browsing selects a
folder and does not write. A collision leaves the destination untouched and keeps
the draft available. Save As adopts the acknowledged copy and reading session;
exports use a separate save session and leave the viewer's source unchanged.
Retained-draft selection now survives through the shared workspace checkpoint
protocol described above. Recovery PGN bytes are also written before displacement.

Canonical game identity now lives in `chess_core/pgn/game_identity.dart`; stored games and Viewer bookmarks share its unchanged URL/hash rules.

Pure mainline lexing and Study-header rewriting now live in
`chess_core/pgn/mainline_lexer.dart` and `chess_core/pgn/study_metadata.dart`.

```
PgnViewerScreen._pickFile → `FilePicker.pickFile` (Linux: **XDG Desktop Portal only** in `file_picker` ≥10.3 — D-Bus `org.freedesktop.portal.FileChooser`; no zenity/kdialog fallback) → ViewerDocumentController.loadFile(path)
  → ViewerDocumentController → PgnCollectionRepository.open (native Linux snapshot captures content and file revision; other hosts use the legacy adapter)
  → injected PgnCollectionDecoder → IsolatePgnCollectionDecoder → chess-core parseMultiGamePgn; lightweight headers/raw text in allGames / filteredGames; only the selected game is parsed into the reader
  → on failure: controller.errorMessage + debugPrint; screen shows SnackBar + inline error in empty state
  → on success: recent-files prefs, missing ECO/Opening tags, optional saved slice and reading-session restore, loadCurrentGame
  → viewer startup reopens the last file, filters, sort order, game and mainline move; explicit file/game handoffs take precedence. Closing the collection clears auto-reopen, keeping its per-file bookmark. `features/documents/models/viewer_session.dart` validates game identity before restoring a cursor, including when a file was reordered. The pure `ViewerSessionController` serializes checkpoints and only deduplicates acknowledged saves; failed writes remain retryable. `ViewerPreferencesRepository` is injected at app startup, with `SharedPreferencesViewerRepository` retaining the existing bookmark, recent-file, filter and opening-preference keys. Failed platform acknowledgements are surfaced, and reads refresh the plugin cache. App shutdown awaits its final reading checkpoint.
  → ordinary opens make the selected game available before background opening classification and position indexing finish (saved filters needing opening tags wait for classification). Opening-tag autosaves match source game ranges in one pass and assemble the document in an isolate under the atomic file lock; they preserve untouched text and reject changed/duplicate source games.
  → default-on **Board and moves → Auto-detect ECO and opening** classifies every game's mainline using the bundled opening book (including transpositions). Missing/placeholder ECO and Opening tags are patched into the source PGN without replacing existing values or reserializing movetext. Detected tags appear above the game and in exported/copied PGNs. Turning this off stops detection and hides that label; previously saved tags remain in the PGN.
  → game change (↓/↑, dropdown, slice, sort): `loadCurrentGame` resets `currentPosition` to start; `PgnViewerWidget._loadGame` defers `onPositionChanged` to a post-frame callback (avoids setState-during-build when called from `didUpdateWidget`)
Game nav bar (when games loaded): Copy PGN → `filteredGames[currentGameIndex].pgnText` → `Clipboard.setData` + `AppMessages.pgnCopied` snackbar
Move selection follows the position on the board: only the latest half-move supplies its from/to square tints. The collection Tree uses its own walked move path, including transpositions, and clears the tint at its root; an absent game variation falls back to the tree root on both the tree and board, and that saved root survives tab switches; switching panes never borrows a hidden reader’s trail for a different position. Inline comment previews suppress the parked mainline move selection; variations and previews suppress the analysis graph’s mainline cursor and selected mainline card. Returning to the mainline restores its selection. Active repertoire training retains its intentional two-half-move trail (your move and the opponent reply).
Analysis tab / inline engine: tap best line or Maia move → `PgnViewerWidgetController.goToMainLineIndex(branchPly)` + `addEphemeralMove` (new RAV per distinct line; prior RAVs kept; editable readers save these lines, read-only readers retain them temporarily)
Clear annotations → nav bar `onClearAnnotations` or PGN variation context menu / Escape / Home → `clearEphemeralMoves` (removes ephemeral nodes only)
Keyboard: `↑`/`↓` previous/next game, `←`/`→` moves, Home/End jump, Enter focus variation, Esc return to parent or leave mode, F11 fullscreen, Space playback, and Ctrl/Cmd+V paste PGN. Enter starts solitaire during setup. Text fields retain their normal editing behavior.
Workspace tabs: the main **Game** stays open. **Actions** opens Compare against my books, Evaluation graph,
Filter or Tree; the Tree tab contains the collection/database source selector. The strip appears only with
two or more tabs; extra tabs can be closed and dragged into order, and Tab cycles
only opened tabs. Readers stay mounted and preserve their cursors. The settings
gear opens view preferences. Opening a filter result exposes **Back to filters**,
which returns to the same draft. Autosave can be toggled in Actions or settings;
the reader has no persistent saved-status label. Tree/filter results use subtle
row striping. Tree uses blue White-win, amber Black-win and neutral draw badges;
filter previews use neutral badges.

**Book comparison:** Actions → Compare against my books opens the canonical
`RepertoireLinePanel` beside the Game tab on the main board. The opening-review
queue opens games here directly; its former nested board/detail dialog is
removed. The master-practice comparison button is removed from Tactics.
The review queue and the selected book comparison show a thumbnail of the position
before departure: green arrows/text identify book moves, red identifies your
deviation, and neutral identifies an opponent move or the end of prep. Opening a
book replaces the summary cards with one compact book/chapter selector and one
readable comparison sentence; the line title appears once and the embedded
reader has no floating reading-settings menu.
Matching lines offers searchable line choices and previous/next controls. Chapter
contents displays every line in a scrollable, searchable list, with a course
chapter filter when present. Clicking a line opens it at the beginning for reading
on the main board. The builder's chapter/line outline and Study's searchable
sidebar provide the corresponding direct navigation; Study lists every imported
PGN game as an entry. An in-book game can still browse its book.
On Tactics, Play tactics is the larger, high-contrast primary action. Pasted-game
imports display “Analyzing games…” with numeric progress below and a working
Pause control, including when no online account is configured.
Choosing another opening on move one is neutral for either side: the game must
match the first full opening pair (or enter through a later transposition) before a
departure counts. Different-opening games are excluded from review mistakes,
gaps and game moments, and never labeled fully in book.
Comparison uses positions across move orders; the book reader uses the book's
own ply when a transposition changes path length. Async comparison and line
loads discard obsolete results after selection changes. Add existing in My books
uses the shared `ChoiceField` searchable picker.

Date rules use **After ≥** / **Before ≤**; rating bounds use **At least ≥** /
**At most ≤**. These bounds remain inclusive. Even a filter matching all games
is restored.

**Browse ECO openings…** uses `widgets/opening_picker_dialog.dart` and
`services/opening_catalog.dart` to browse the bundled opening TSVs, preserving
multiple named lines per ECO code. Its search uses the common `ListSearchField`
with a magnifier, inset input and clear action. The browse control lives in the Value input after selecting ECO. Selection survives searches and reopening the picker. Exact code sets
appear as removable chips in the ECO value cell, with representative board
thumbnails enabled by default and a Show thumbnails checkbox. The preview
supports legal board moves, editable SAN, undo, reset and board flip.
**Filter by selected ECO codes** updates the current ECO row with one exact/OR
condition and preserves other filters. **Use preview position** instead supplies
the edited move sequence to the position filter; **Choose position… → Set up a board** can then
arrange pieces freely. These actions change the filter draft, not game moves.
Existing game editing and autosave remain separate; opening detection still
fills missing headers without overwriting existing ECO labels.

The game counter and Search both open the larger **Browse Games** dialog.
Chapter detection uses the same header rules as repertoire browsing. Chapters
appear as compact single-line rows with counts and full-title tooltips in a left sidebar; selecting one lists its games without jumping
to the first game. Without chapters, Event (or Site when Event is missing) plus
year creates a group only for more than four games. **All games** always remains
available, including ungrouped games. Search matches game labels, chapters,
players, event, place, dates, openings and study text within the selected group;
empty results offer Search all games. A number still offers Go to game N.
Narrow windows move the compact group rows into a horizontal strip. Repertoire
and training chapter pickers use compact rows with at most two title lines and
full-name tooltips. Full-screen repertoire and chapter libraries cap their reading
width at 920px. Embedded course contents show three chapters initially, with a
Show all / Show fewer toggle; searching reveals matching chapters even when
collapsed. Line counts use bright 13px text; trainer chapter cards keep progress counts without repeating a full progress bar per row. Chapter setup scrolls within short
windows, and study chapter names expose full titles on hover.
Shared tooltips wrap at 480px. Database destination rows wrap drive metadata beneath a bounded path instead of reserving fixed columns. Review zero counts, one-star tactics and selectable
game-window alternatives retain readable ink. Below 760px, optional tactics filters and sorting collapse behind a disclosure; actions and sort choices wrap. Tactics browse rows stack game and move details with a per-row actions menu instead of squeezing the full table. Move entry hints and borders remain
visible before typing; annotation and finding colors use brighter green, red and
purple for dark surfaces.

PGN moves use a consistent 16px regular weight across annotated moves,
unannotated moves and variations. The current move is marked by its background
highlight without changing text size or weight.

PGN comment diagrams (`pgn/comment_diagram.dart`) render embedded FENs as small
boards labelled **Comment position**, including FENs nested inside Chessable
editorial brackets. Parenthetical prose stays inline; move runs continue across
notes and replay from their embedded FEN. Dotted-underlined comment moves offer
**Preview comment move** tooltips and show **Comment preview** while navigating.
Their active highlight uses the mainline’s borderless pill around the move alone;
move numbers and separating spaces stay outside, and selection preserves text weight.
Classified engine suggestions (**Interesting**, **Inaccuracy**, **Mistake**,
**Blunder**) are saved as standard PGN variations when analysis writes the game.
Their real variation nodes render once inside the verdict’s inset **Best** block,
with ordinary move selection, Back/Forward, branching, focus and context menus.
The `[%bestline ...]` comment identifies the styled path; the RAV owns its moves.
Existing branches and annotations are reused; the engine’s continuation becomes
the principal path within that analysis branch, retaining other continuations.
Legacy `[%pv ...]` suggestions on classified moves convert on load and go through
the editable reader’s normal save policy, without rerunning the engine. Repeated
loads do not duplicate them; deleting a branch or suffix also removes/shortens
its reference so it stays deleted after save/reload. Unclassified cached PVs
remain compact engine metadata.
Prose-embedded move runs still preview without saving. Playing a move from one
first gives it ordinary variation ancestry. Independent embedded FEN diagrams
remain temporary previews when their starting position does not occur on the
game’s mainline.
The variation toolbar and continuation picker float at the foot of the reader,
so entering a sideline or reaching a fork never resizes the reading viewport.
Overflow scrolls horizontally. Positions without a choice have no picker or
reserved empty row; trailing document padding keeps the final moves reachable
above any visible controls. The mainline control remains available when reading
options live in the host menu.
The note stays in view during preview. They never become saved mainline moves
or variations. Explicit move numbers and sides must match the preview position;
bare square references in prose are not inferred as pawn moves. Move numbers, check signs
and annotations are preserved in prose; invalid diagram text remains readable.
Single-spaced comment lines also replay legally, with numbered restarts and
parenthesized alternatives anchored to their own positions. Trainer Read captures
ordered PGN text, title, selected game and ply in `OpenPgnViewer.content` and
opens it through the Viewer's existing leave approval and collection loader.
It writes no temporary cache file. The Viewer owns this separate editable
collection; Save a copy/export and unsaved-close approval preserve edits without
modifying course or training data. Breadcrumb history retains its captured
content, collection title and cursor. Newer navigation supersedes delayed loads. `[--]` paragraph separators, bullet sections and `**bold**`
labels are formatted for reading. Known exporter null counters and impossible
Black-prefixed duplicates of legal White moves are cleaned only for display;
other invalid notation stays readable. A move and its explanation precede its
alternatives. In reading mode, a commented leaf repeating the principal move
reads as an inline reference; annotated or continuing branches and edit mode
retain full variation controls. The source PGN and every branch remain intact.

Opening tree (**Actions → Tree**): `PgnOpeningTreePanel` splits the move tree and a resizable **games at this position** list (`PgnTreeGamesList`). Viewer and repertoire both build through `OpeningTreeBuilder` → `walkMainlineIntoTree` (`pgn_tree_core.dart`); player analysis uses the same walk from `UnifiedAnalysisBuilder` (mainline only). The viewer defaults to one mainline per game. **Include variations**, in the tree header, rebuilds both tree frequencies and the matching-game index with all RAVs. Other builder callers retain their existing automatic policy (RAVs for course `Result *`, mainlines for scored games). `*` results count toward frequency without a fake 50% draw bar — the UI says **paths** (including variations) instead of **games** and hides the W/D/L bar. Chessable intro dummies (`1. Z0 (1. d4 …)`) are promoted onto the mainline before the walk. The list keeps the nav-bar `GameNumberField` + `GameSearchButton` (`/` searches this list, `G` focuses the number). Game headers show the players, date and completed result (`1-0`, `0-1`, or `1/2-1/2`); the result stays visible when a long title is truncated. Rows start expanded with the comment-free continuation from this FEN (including a hit that only exists in a sideline), truncated to one line. **Show moves** (next to Search) is on by default — the blue triangle is a bullet and tapping a row opens the game. Unchecked, the triangle previews one line and the title still opens the game. Drag the split handle to grow the list.

**Cursor ownership (same rule as Game vs Line tabs, Analysis `_navigateTo`, Repertoire `jump`):** each exploration surface keeps its own place. The merged opening tree is not the current game's move list, and its tab retains the game reader offstage. Re-entering the tree — its tab, or the app-bar back after a games-at-position click — restores the tree cursor onto the board; it does not resync from that remounted game. Clicking a game in the list parks that game at the tree FEN (`pgnInitialFen` → `PgnViewerWidget.initialFen`). Leaving the tree for the Game tab restores the game cursor snapshotted when the tree was opened. First open (no saved tree cursor) still syncs the tree to the current game FEN. Next/prev/sort/slice clear the landing FEN so those games start at move 1. Repertoire's Tree tab and Analysis's opening-tree tab already share one board cursor and stay mounted, so they do not need this snapshot.

Collection trees retain null moves as navigable plies so Back preserves the side to move. They retain disconnected FEN chapters as separate setup roots; Back, Start, saved cursors, move numbers and highlights replay from that chapter's root. Chapters whose start is already reached still join at that position. A FEN header is honored even without SetUp by both the reader and position indexes; older FENIDX caches rebuild. Tree rebuilds apply a board position only while the tree is visible, game loads cannot overwrite a visible tree, and games-at-position matches follow game identity after sorting.
```

#### Edit Mode (Annotation)

Toggled through **Actions → Edit PGN**. When active:

- **NAG display**: Move-quality NAGs ($1–$6) render inline after the SAN with Lichess-style colors (brilliant=green, good=green, interesting=pink, dubious=blue, mistake=orange, blunder=red). Annotations remain visible outside edit mode.
- **Save status and annotation panel**: PGN Viewer keeps autosave controls in Actions/settings without a persistent status label; failed autosaves expose Save to retry. Study shows a quiet, fixed-width status beside the file title: **Autosave on · Saved**, **Saving…**, or **Not saved** on failure. There are no success popups or animated indicators, and saving does not insert a toolbar or shift the board. Hover reveals the file path or failure details. Manual saving reports **Autosave off · Saved** / **Unsaved changes** and keeps **Save** available; pasted games say **Not saved to a file** and offer **Save as…**. Failed viewer autosaves expose **Save** for explicit retry; uncertain acknowledgements require reviewing the recovery copy and reopening the source. The shared Notes panel labels its target move; NAG buttons retain move-quality colors. Emptying an existing comment field keeps the stored comment until the explicit Delete comment action is confirmed, allowing replacement text without a popup while typing. Submitting an empty inline comment asks before removal. Branch deletion always confirms the count of moves and prose comments across all nested variations; chapter deletion and bulk clearing also show affected counts, including chapter introductions and variation starting comments. Confirmed removals follow the host's normal save setting.
- **Context menu**: Right-click in edit mode shows Comment, Annotate, Promote (variation), Delete — with promote/delete gated by `protectOriginal`.
- **Keyboard**: `Escape` exits edit mode.
- **Persistence**: User-added moves and variations persist in both reading and edit mode; Edit PGN exposes annotation controls. **Settings → Game viewer → Autosave PGN edits** defaults on. Turning it off keeps edits in memory across game navigation until **Save**; closing the file, replacing the collection, or closing the window offers Save / Discard / Cancel. Solitaire guesses and read-only Book comparisons remain temporary. Saves patch changed games into the source file, preserve unrelated games and file preambles, and retain unsaved status on failure. Pending comments flush on Save and when finishing editing, before the annotation panel is removed; repainting waits until the widget tree unlocks. NAGs saved via `buildGameMovetext()` (the whole tree, so sidelines and the game comment survive) → `persistMoveComments()` → file write. NAGs serialize as `$N` tokens after the SAN in standard PGN format.

Key files: `pgn_comment_utils.dart` (`buildGameMovetext`, the one serializer for a parsed game), `pgn_viewer_widget.dart` (`editMode`), `pgn/pgn_annotation_panel.dart`, `pgn/pgn_viewer_widget_annotations.dart`, `pgn_viewer_screen.dart` (`_editMode`, `_buildEditModeBar`).

#### Solitaire Mode (Guess-the-Move)

Guess one side's moves of the loaded game; the game unfolds as you get them right. The underlying PGN-viewer session UI remains, but the simplified Actions menu no longer offers solitaire and the Ctrl+S / Shift+S entry shortcuts were removed.

- **Setup strip** (`SolitaireSetupStrip`): the toolbar button opens a one-line strip above the movetext instead of starting at once. Choices: **Guess for** White/Black (defaults to the side at the bottom of the board), **Start** from the game start or **from here** (only offered when the cursor is on the mainline mid-game; the moves before it stay visible), **Include variations** (only when the game has saved sidelines), and **Hint and reveal after** 0–120 s (persisted as `solitaire_reveal_delay_sec`). Enter starts, Esc cancels. The side is fixed for the session: flipping the board or changing perspective no longer restarts it. A new game under a running session restarts with the side read from the board again and the same sidelines choice (`solitaire_include_variations`).
- **Script** (`lib/features/documents/models/solitaire_script.dart`): `buildSolitaireScript` lays the session out up front as a list of `SolitaireStep`s — mainline moves from the start ply, and with variations every saved sideline in movetext order: a move, then the alternatives to it, then the line resumes. A sideline's first move is a **premise** (`isPremise`): shown after a 700 ms pause, never asked. Null-move plies are walked through but never asked; ephemeral scratch lines are never drilled.
- **Reveal state** (`lib/features/documents/models/solitaire_reveal.dart`): `SolitaireReveal` = mainline frontier ply + revealed sideline node ids + whether unreached sidelines are hidden. Pushed into the PGN widget through `PgnViewerHandle.setSolitaireReveal` synchronously on every controller change, *before* the controller's navigation callbacks fire, so a jump to the new frontier is never clamped against the old one (the old prop-based `revealedPly` lagged a frame). `ViewerGameController.reveal` clamps mainline navigation, refuses hidden sideline nodes, and `PgnMovetextView.reveal` prunes them from rendering; the fork bar and ←/→ inside a sideline respect it too.
- **Guessing**: a board move counts as a guess only when the board sits on the position the current step is asked from (`mainLineIndex == step.mainlinePly`, or inside a sideline `currentVariationNodeId == step.parentNodeId`); anywhere else it is exploratory analysis. Wrong tries appear live as ephemeral alternatives (sideline roots on the mainline, children of the current node inside a sideline). The opponent's reply auto-plays after 400 ms.
- **Hint** (`H`, lightbulb chip): after the delay, highlights the square of the piece that moves (`ChessBoardWidget.highlightedSquares`). One per move; a hinted move is logged `wasHinted` — not first-try, not revealed. **Reveal** (`R`) gives the move up. Both chips stay visible and grey until available; the countdown sits in its own fixed-width slot so nothing jitters.
- **Status bar** (`SolitaireStatusBar`): "Solitaire · White", a turn cue ("Your move · 2 wrong", "Black replies…", "Sideline: 1… c5", "Sideline 1… c5 · White replies…"), progress over script steps, first-try tally.
- **Leaving**: Esc, the toolbar icon, the Exit chip, and Prev/Next game all ask first (`confirmAction`, non-destructive styling) when guesses have been made and the game is not complete. Closing the file, opening the opening tree, or loading another file stops silently.
- **Guess log & PGN injection**: every asked move is a `SolitaireGuess` (its `SolitaireStep`, wrong attempts, `wasRevealed`, `wasHinted`). On completion the notes (`1st try`, `Hinted`, `Tried: e5, d5 (3 tries)`, `Revealed`) are appended to the move's comment and wrong tries become saved alternatives — for mainline moves by ply (`addGuessAnnotations` / `addGuessVariations`) and for sideline moves by node id (`addGuessNodeAnnotations` / `addGuessNodeVariations`). `persistMoveCommentsFor` updates the in-memory game even without a file, so a pasted PGN's Copy PGN carries the notes; only the disk write needs a path.
- **Completion banner** (`SolitaireCompleteBanner`): score line (first-try, hinted, revealed), Copy PGN, Add to study…, **Analyse for trophies** (leaves solitaire, runs or reuses full-game analysis, then `detectSolitaireTrophies`) and Next game. The trophy sentence and button appear only when there were wrong tries to check.
- **Trophies**: `detectSolitaireTrophies` evaluates each wrong attempt at a mainline position and compares it with the game move's eval (sideline guesses have no eval and are skipped). Trophies persist to `solitaire_trophies.json`, show as markers in the analysis tab, and the cabinet dialog is always listed in the viewer's overflow menu ("Solitaire trophies", with a hint while empty) so the loop is discoverable before the first one is earned.
- **Toolbar adaptation**: in solitaire the `GameNavBar` shows game counter, Hint, Reveal, Fullscreen, Exit and Prev/Next; the app bar hides slice chips, opening tree, amend and perspective; the side-panel tabs, engine bar and Analysis tab are hidden. The engine bar is also hidden while the setup strip is open.

Key files: `lib/features/documents/models/solitaire_script.dart` (`SolitaireStep`, `SolitaireScript`, `buildSolitaireScript`), `lib/features/documents/models/solitaire_reveal.dart`, `lib/features/documents/controllers/solitaire_controller.dart` (cursor over the script, hints, countdown, score, `SolitaireGuess`), `lib/features/documents/controllers/viewer_solitaire_session.dart` (`SolitaireSetup`, board glue, guess routing, note injection), `lib/features/documents/repositories/pgn_viewer_handle.dart` (the widget surface core may touch), `lib/features/documents/controllers/viewer_reading_controller.dart` (selected-game lifecycle, `onViewerGameLoaded`), `lib/widgets/pgn/solitaire_status_widgets.dart` (setup strip, status bar, completion banner), `lib/widgets/game_nav_bar.dart` (Hint/Reveal chips), `lib/screens/pgn_viewer_screen.dart` (confirm-on-leave, `H`/`R`/Enter/Esc bindings, analyse action), `lib/widgets/pgn/pgn_movetext_view.dart` + `pgn_movetext_variations.dart` (reveal-aware rendering), `lib/models/solitaire_trophy.dart`, `lib/services/solitaire_trophy_service.dart`, `lib/services/solitaire_trophy_detector.dart`, `lib/widgets/solitaire_trophy_cabinet.dart`.

### PGN import UX (multi-source panel)

The `PgnSourcesPanel` extends beyond the single-import `pgn_import_dialog.dart`
for contexts that manage multiple PGN sources (generation, batch import). Architecture:

```
PgnSourcesPanel (lib/widgets/pgn_sources_panel.dart)
  ├─ PgnSourcesController (lib/widgets/pgn_sources_controller.dart)
  │    └─ List<PgnSource> — each with name, filePath/paste, color, sliceConfig;
  │       owned by the host so the list outlives the panel's mount
  ├─ "+ Add PGN" popover → file picker (multi) or compact paste dialog
  └─ Per-source row:
       ├─ Color badge, name, filename, game count
       ├─ Slice chip → expands InlineSliceEditor
       │    ├─ Radio: "All Lines" / "Slice"
       │    ├─ PositionFilter (lib/widgets/slice/position_filter.dart)
       │    ├─ SequenceFilter (lib/widgets/slice/sequence_filter.dart)
       │    ├─ HeaderFilters (lib/widgets/slice/header_filters.dart)
       │    ├─ Isolate-based slice compute → matchedIndices
       │    └─ "Preview lines" → LinesPreviewPanel
       │         ├─ Literal substring search bar
       │         ├─ Virtualized game line list
       │         └─ HoverableMoveChips per row → BoardPreviewController → FloatingBoardPreview
       └─ Remove button
```

Used by:
- `RepertoireGenerationTab` (DB Explorer mode) — replaces `_buildPgnFilePickerSection()`
- `PgnGameFilterWorkspace` — live matching-games results embed `LinesPreviewPanel` with hover board and direct game opening
- `LineItemRow._MovesPreview` — upgraded to `HoverableMoveChips` for hover board on lines browser

---

## Directory reference

### `lib/constants/`

| File | Purpose | Dependencies |
|------|---------|--------------|
| `chess_constants.dart` | Shared chess literals (starting FEN helpers, ply limits) | — |
| `engine_defaults.dart` | Defaults: interactive analysis depth (`kDefaultDepth` 15), **tree generation eval depth** (`kDefaultGenerationEvalDepth` 14), MultiPV | — |
| `ui_breakpoints.dart` | Responsive layout width constants | — |

### `lib/features/repertoires/` board/document owners

| File | Responsibility |
|------|----------------|
| `controllers/repertoire_board_controller.dart` | Pure board, cursor, immutable projections, editing commands and adoption-bound draft undo receipts; no Flutter or I/O |
| `controllers/builder_workspace_controller.dart` | Draft/copy intent, source reattachment, active board edits and recovery capture; no forwarding facade |
| `controllers/repertoire_document_session.dart` | Destination, load epochs, selected line, private opening graph and bounded serialized pending edits; failed handoffs retain the current document |
| `controllers/repertoire_writer.dart` | Serialized append/undo with document preconditions and session guards |
| `models/repertoire_authoring.dart` | Pure line construction/rebuilding, PGN numbering and prefix matching |

Shared cursor navigation lives in `chess_core/moves/move_navigation.dart`.
Course header interpretation and variation expansion live in `chess_core/pgn/`.
The original libraries are retired, and tests mirror the new ownership paths.
Durable scratch recovery belongs to the app-owned `BuilderLifetime`; opening
graphs expose immutable projections. Remaining legacy screen coordination and
chapter creation are still pending.

### `lib/features/documents/` Viewer workspace

`PgnViewerController` and its forwarding/error-mirroring API are deleted.
`ViewerDocumentController` owns collection replacement, loading, filter publication
and recovery transactions. `ViewerReadingController` owns the selected-game
lifecycle and reading position; its tree, playback and Solitaire owners expose
their own commands. `ViewerLibraryController` owns library discovery and ordered
recent-file preferences. Collection membership, metadata and sorting belong to
`ViewerCollectionController`; save state and writes belong to `PgnCollectionEditor`.
The screen and controls consume these owners directly. Display errors are selected
in the UI without copying child errors into document state. The leave dialog and
recovery lifetime subscribe to the combined owner notifications, so editor save
acknowledgments update their actual consumers.

All document replacement paths use one abandonment contract: revoke collection,
opening, filter and selection work before stopping index/tree work, playback,
analysis and Solitaire. Pending editor writes retain their existing ledger and
receipt semantics. A successful open reports adoption explicitly; a failed recent
preference write cannot prevent selecting the requested game and move.

`ViewerPositionIndexRepository`, `ViewerOpeningRepository`,
`ViewerSolitaireRepository` and `ViewerAnalysisPort` are injected. Cancellable
worker adapters terminate owned work on reset/disposal; epoch checks reject late
results from asynchronous ports. The v2 `.fenidx` wrapper fingerprints exact
source game records, so metadata saves cannot revalidate a stale cache by
refreshing file timestamps. Legacy v1 sidecars are disposable and rebuilt.
Solitaire preference writes check platform acknowledgements.

Viewer filter and Solitaire controls consume state/callbacks or the actual
`SolitaireController`. Opening search captures a game identity; the screen ignores
an entry removed while its dialog was open. These controls use the active theme;
the unused perspective button and five legacy-theme ledger entries are deleted.

Pure replay/serialization/opening-header helpers live in `chess_core/pgn/`;
`sideline_tree.dart` lives in `chess_core/moves/`. Solitaire models are feature
models. All `core/pgn/` files are retired without shims; the unused collection-merge
helper was removed. `PgnViewerLifetime` composes and disposes the document owners
and adapts the concrete reader/analysis ports. The remaining legacy screen,
reader widgets and shared controls still require their broader workflow/UI gates;
this owner cutover does not certify the whole Viewer renewal.

### `lib/features/generation/` publication owner

`GenerationPublicationController` captures the native source revision and an
immutable configuration before work starts. App composition creates one owner
per generation session and injects document and draft repositories. The
infrastructure adapter stages the proposed course and optional model games under
`.cap-generation/<chapter.pgn>/<runId>/`, with a manifest; a successful source
commit adds a separate publication receipt. Older companions remain intact.
Conflicts and uncertain results retain the proposal and report its exact path;
an uncertain publication is never automatically appended again. The former
`PgnBatchWriter` and blind model-game overwrite/delete path are retired.
Generation awaits `onPublished(PgnSnapshot)` before job success. Builder binds
the receiver to its loaded chapter/session, drains pending edits and atomically
adopts the current complete document. Stale or replayed callbacks cannot add
lines twice. Ordinary line saves also refresh the complete baseline, opening
tree and metadata, preserving newer actions and unrelated external game edits.
`GenerationArtifactRepository` is the single saved tree/probe/trap/partial
publication authority. Its injected `StorageGenerationArtifactRepository` stages
immutable payloads and a source/run/config manifest under
`.cap-generation/<chapter.pgn>/artifacts-<id>/`. One revision-checked
`artifacts.current.json` selects the complete generation. Readers validate the
manifest, payload hashes, source revision and current pointer before adoption;
stale runs, edited payloads and interrupted selection cannot replace a newer
selected generation. Old generations and failed proposals remain on disk.

`GenerationArtifacts` owns snapshot capture, isolate scheduling and complete-bundle
staging. The synchronous v3/v4 tree and versioned probe codecs and canonical
`BuildTree`/`BuildTreeNode`, `TrapLineInfo` and `TrapReply` values live in
`chess_core/generation/`. The shared persistent four-field FEN reducer lives in
`chess_core/position/eval_canonicalize.dart`. This dependency closure contains no
legacy services, Flutter, native I/O or isolate scheduling. Saved configuration
stays historical JSON; the decoder does not consult operational `TreeBuildConfig`
or current CPU limits. `tree_serialization.dart` preserves the existing wire
format and metadata/index reconstruction; `expectimax_probe_codec.dart` composes
that format without importing build/engine helpers. Probe graft/rescore and trap extraction remain generation
algorithms outside the artifact codec boundary.
Generation, saved-tree reopening, probe updates, resumable partials, the active
Builder tree panes, traps and training source loading use this repository.
Resume/discard carries the observed generation ID. Chapter changes invalidate
cached reads, and late trap loads cannot repopulate an outgoing chapter.
`ExpectimaxDatabase` retains in-memory tree/probe operations and an injected
reader; it no longer writes files. `GenerationArtifactStore`, its path/writer
APIs, `ExpectimaxDatabase.persist`, trap filesystem helpers and obsolete eval-tree
loader/tab implementations are deleted. `ExpectimaxProbeCodec` only encodes and
decodes probes.

Builder → Actions → **Recover generated outputs…** opens the single production
`GenerationRecoveryDialog`, owned by `GenerationRecoveryController`.
`GenerationArtifactRepository.listRecovery` catalogs retained run directories
under `.cap-generation/<chapter>/` and the older JSON/model-games sidecar set. Empty/error Builder
Actions opens the same dialog with an initial source chooser. `listRecoverySources`
discovers namespaces under the configured repertoire root without following
links or entering hidden trash/staging folders; a deleted chapter remains
reachable. Entire deleted repertoires must first use library restore. Selecting an output
lazily loads it through `readRecovery`; `GenerationArtifacts.inspectRecovery`
uses the pure codecs off the UI isolate. There is no second browser or writer.

Recovery values are separate from authoritative artifact snapshots. The view
shows recorded run/source/configuration, source-revision comparison, per-file
checksum evidence and publication/selection records. A missing publication
receipt does **not** mean the PGN write failed; an old artifact directory does
**not** prove it was never selected. Even a matching recorded revision/checksum
is not certification of current analysis. PGN proposals and model games are
readable as text; tree/probe/trap/partial payloads use the existing semantic
inspection. Run manifests and receipts remain inspectable/exportable.

The native repository reads only fixed filenames, never paths from a manifest.
Directory identity checks reject replaced runs; unsafe and missing files have
isolated typed failures. Enumeration failure leaves older sidecars accessible
and offers Refresh. Native observations capture exact bytes before decoding.
**Export original file…** exclusively creates a new PGN/JSON file from those
immutable bytes, preserving BOM, compression, edits and undecodable content.
It never replaces a destination, changes originals or selects analysis. Uncertain
export displays the destination for inspection. Stale loads, closed pickers and
chapter navigation cannot redirect the captured export.

The former legacy-only dialog/controller, `readLegacy`, `exportLegacy` and
`inspectLegacy` APIs are retired with all consumers on the final recovery flow.
Legacy files still lack historical source evidence. Recovery does not adopt
analysis, transfer it into training, or resume any output. The normal generation
flow alone can resume a validated current partial. PGN commit and artifact
selection remain separate transactions: a cache-selection failure after PGN
commit reports the saved PGN and retained output, without replay. Automatic
legacy resume, retention/garbage collection and cross-file atomicity remain
outside this responsibility.

### `lib/core/`

| File | Purpose | Public API / state |
|------|---------|-------------------|
| `app_state.dart` | Global app mode, usernames, board position, builder↔trainer↔study pending handoffs (`pendingTrainStudyPath` = "Train" in Study mode, `pendingStudyPath` = "Edit study" in the Trainer); **tactics auto-fetch preferences** (`tacticsAutoFetch`, `lichessLastFetch`, `chesscomLastFetch`) persisted via SharedPreferences; `AppMode.usesInteractiveEngine` names which IndexedStack children keep an engine pane | `setMode`, `switchToBuilder`/`switchToTrainer`/`switchToStudyTraining`/`switchToStudyEdit`, `setRepertoireGenerating`, `setTacticsAutoFetch`, `setLichessLastFetch`/`setChesscomLastFetch`, `notifyListeners` |
| `generation_session_controller.dart` | **Generation session** — owns `TreeBuildService` + `CoherenceService`; pipeline, pause/resume/cancel/finishNow and probes; injected publication owner stages and commits source output, then selects the matching artifact generation. Captures artifact runs before builds/probes, drains partial staging and closes run capabilities. Disposal releases waits and drains owned commands. | `startBuild`, `pauseBuild`, `resumeBuild`, `cancelBuild`, `discardBuild`, `finishNow`, `onTreeBuilt`, `clearTree`, `loadSavedTreeFor`, `skipMasterGamesDownload`, `progress`, `snapshots`, `current` |
| `expectimax_database.dart` | In-memory `GeneratedRepertoire` and probe trees; loads through injected `readSaved`, lands probes and records engine PVs. Loads replace prior analysis; full builds retain probes and supersede pending loads. Main-tree mutations refresh derived artifacts; probe-only changes reuse them. The session owns notifications and repository publication. | `publish`, `clear`, `dropTree`, `load` → `ExpectimaxLoadOutcome`, `addBoundedProbe`, `landProbe`, `recordEnginePv`; `enginePvProbe` |
| `master_games_wait.dart` | `MasterGamesWait` — parks a run on the master-games download (start or join a sync, mirror its status, release on finish / "start now without them" / cancel); `MasterGamesSync` is the service slice it needs | `park`, `stopWaiting`, `decline`, `isWaiting`, `declined` |
| `generation_run_summary.dart` | Pure wording of a finished run's outcome sentence | `composeRunSummary`, `courseNote`, `bookSourceNote` |
| `generation_progress.dart` | Throttled BFS / phase stats for the Jobs panel; owned by the session controller | `update`, `setStatus`, `handleBuildProgress`, `flushNotify` |
| `snapshot_exporter.dart` | Mid-run export of lines found so far to a new repertoire file | `export`, `nameSuggestion` |
| `generation_session_types.dart` | `GenerationRequest` (+ `expectimaxProbe`, `resolveLinePrefix`), `TreeAnalysis`, `ExtractedLines`, `ExpectimaxProbeTarget` (+ `moves`, `probeConfig`, `movePvConfig`) | — |
| `game_sorting.dart` | Comparators behind the PGN viewer's `GameSortMode`s | `sortGamesInPlace`, `compareGamesBy*` |
| `features/audit/controllers/audit_session_controller.dart` | **Audit session state** — owns `RepertoireAuditService` + result, live findings, progress, config, interrupted snapshot; handles persistence via `AuditPersistence`; `onLiveFinding` creates a new list on each addition (avoids stale-reference bugs in widget comparisons) | `pause`, `resume`, `cancel`, `saveProgress`, `tryRestore`, `launch`, `launchResume`, `startFresh`, `onAuditingChanged`, `onResultReady`, `onLiveFinding`, `onProgress` |
| `features/coverage/controllers/coverage_controller.dart` | **Coverage session state** — result, progress, running flag | `calculate`, `clear` |
| `board_preview_controller.dart` | Debounced hover FEN overlay for board | `setPreview`, `clearPreview`, `previewFen`, `isPreview` |
| `navigation_stack.dart` | Breadcrumb stack for repertoire navigation | push/pop/jump |

### Application-owned engine and display settings

`app/runtime_settings.dart` constructs one application-scoped owner per section.
Immutable configurations live in `features/settings/models/`;
the existing `controllers/section_settings_owner.dart` directly serializes field
edits against fresh storage, confirms writes by rereading, and retains failed
drafts for retry. The private forwarding controller and stream relay are retired.
The same owner handles admission, state, notifications and disposal: admitted
writes settle after disposal without notifying, while new edits are rejected.
`infrastructure/settings/preferences_section_storage.dart` preserves existing
keys and migrations, including worker/thread settings and `tactics_import.depth`.
Normal and inline controls share loading, saving, failure and retry state.

Committed engine changes apply to the next search or job. Board requests capture
configuration before queuing; pool provisioning and crash recovery retain their
captured configuration. A running review keeps its depth/core settings across
accounts. Board-display changes apply after successful persistence.
Boards and SAN presenters observe the Provider-owned `BoardDisplaySettings`
directly and render its committed configuration; bare previews receive immutable
defaults, never a fallback settings writer.
The three owners are `features/settings/controllers/engine_settings.dart`,
`bulk_analysis_settings.dart` and `board_display_settings.dart`; their old
`models/` singleton files are deleted.

`app/engine_runtime.dart` constructs and disposes `BoardEngine`, `StockfishPool`,
`EngineSearchBudget`, `EngineLifecycle` and an instance `GenerationLease`. It
exposes components without duplicating their operational APIs. Consumers receive
components through constructors or application providers. Singleton accessors,
static generation lease access and temporary settings-binding methods are
deleted. Lifecycle toggle persistence delegates to the engine-settings owner.
Runtime disposal retires active and starting workers, cancels queued budget
admissions and prevents disposed owners from starting new work.

Settings tests cover concurrent panels, invalid legacy values, late loading versus
edits, partial writes, retained failures, retry and restart. Engine tests cover
queued configuration and recovery; `test/app/engine_runtime_test.dart` covers
shutdown, late startup retirement and lease exclusion. Native Linux checks cover
complete runtime PID cleanup and a fresh runtime after disposal. Credentials,
external evaluation-database settings and unrelated services remain separate
renewal work; Windows/macOS native verification remains open.

### `lib/models/`

| File | Purpose |
|------|---------|
| `analysis/discovery_result.dart` | Engine discovery lines (MultiPV) |
| `analysis/move_analysis_result.dart` | Per-move analysis in game review |
| `analysis_player_info.dart` | Player metadata for analysis; `accounts` (the chess.com/lichess handles an opponent's merged game-set came from — what makes it re-downloadable) and `group` (event name); `displayName` is the first `;`-segment of the username |
| `chess_core/generation/build_tree_node.dart` | **Generated tree node**: eval, ease, myEase, expectimax, traps, `pvContinuationMove`, `engineInjected`, children, serialization |
| `engine_evaluation.dart` | Single eval result |
| `engine_weakness_result.dart` | Weak square / position analysis output |
| `eval_database_settings.dart` | CdbDirect path, enable flags (persisted) |
| `explorer_response.dart` | Opening explorer answer shape: `LichessDatabase` (which database is being asked), moves with counts, plus the games a source lists for the position (`ExplorerGame`, tagged with the `ExplorerGameSource` it can be fetched from — Lichess, masters or the local TWIC database) |
| `move_tree.dart` | Editable PGN move tree (`MoveNode`, `MoveTree`). FEN cached per node; Iterative fresh-ID adoption copies NAG lists and preserves cached positions. Cursor and read contracts live in `chess_core/moves/`. PGN parsing delegates to `move_tree_pgn.dart`; writing uses `chess_core/pgn/move_text_writer.dart`. Privately owned by `RepertoireBoardController` for Builder navigation and edits. |
| `move_tree_pgn.dart` | `MoveTreePgnCodec` — iterative dartchess game-tree replay → editable `MoveNode`s, preserving variations, starting comments and NAGs |
| `legal_destination_cache.dart` | `LegalDestinationCache` — bounded LRU of legal moves and their destination FENs per position, behind the opening tree's one-ply transposition scan |
| `opening_tree_transfer.dart` | `OpeningTreeTransfer` — flat id-keyed encoding of an `OpeningTree` for isolate transfer (`toTransferJson` / `fromTransferJson` delegate here) |
| `opening_tree.dart` | In-memory statistics tree indexed by FEN. Cursor walks by FEN (so 1.d4 Nf6 2.e3 c5 and 1.d4 c5 2.e3 Nf6 land on the same node). Off-book positions still list **one-ply transpositions** (`continuations` / `viaTransposition`). `hasMove`, `appendLine` / `appendLineFromFen` (null-move passes skip a node). `updateStats(null)` counts frequency without a fake draw; `hasWdl` hides the W/D/L bar on course trees |
| `pgn_filter_models.dart` | PGN import filter types |
| `pgn_source.dart` | **PGN source model** — represents one attached PGN file or paste blob with optional slice config; used by `PgnSourcesPanel` for multi-source import |
| `pgn_game_entry.dart` | One game in a loaded PGN file. `label` is `"White vs Black"` for player games; course exports (`Result *`, no ratings, no `"Last, First"` comma) use `"Chapter — Line"` (or just the title when White==Black) |
| `position_analysis.dart` | Position analysis aggregate; `getSortedPositions` orders by `PositionSort` |
| `repertoire_line.dart` | Trainable line extracted from PGN (moves, title, probability) |
| `repertoire_metadata.dart` | **Typed repertoire file descriptor** (`filePath`, `name`, `gameCount`, `lastModified`) used across selection screen, controller, storage, generation tab, and training |
| `repertoire_move_progress.dart` | Training progress per move |
| `repertoire_review_entry.dart` | FSRS-style review scheduling |
| `repertoire_review_history_entry.dart` | Review history log |
| `settings_enums.dart` | `CandidateSource`, `SelectionMode` (`expectimax`, `engineOnly`, `dbWinRateOnly`), `OpponentProbabilityMode`, etc. |
| `features/tactics/models/tactics_position.dart` | Tactics puzzle position; includes `int rating` (0=unrated, 1–5 stars; 1-star excluded from training by default) |
| `features/tactics/models/tactics_session_settings.dart` | `TacticsSessionSettings` — order (`newestFirst`/`leastReviewed`/`worstSuccessRate`/`random`), `mistakeTypes` filter, `includeOneStar` toggle, `acceptAlternatives` (ask Stockfish about a non-matching move before calling it wrong; off by default); `accepts(pos)` for session filtering |
| `training_settings.dart` | Trainer behavior (persisted); `ReviewOrder` enum includes `hardestFirst` (sorts by ascending playability from tree) |

### `lib/features/browse/`

| File | Purpose |
|------|---------|
| **services/candidate_service.dart** | Merges `BuildTree` + coverage delta into `CandidateMove` list (Lichess Explorer mothballed) |
| **widgets/browse_panel.dart** | Candidate list, rare-move collapse, back/root/undo nav |
| **widgets/candidate_row.dart** | Per-move row: eval, ease, traps, DB stats, coherence hint |
| **widgets/expanded_trap_list.dart** | Trap sub-list when expanding trappy candidate |

### `lib/features/coverage/`

| File | Purpose |
|------|---------|
| **services/coverage_service.dart** | Gap detection, `CoverageResult` (`findNextGap`, `findBiggestGap`), `UnaccountedMove.source` as `UnaccountedSource` (masters/maia), typed `MasterMoveCount` from `getMovesWithCounts`; `getPositionData()` mothballed (returns null, no Lichess API) |
| **widgets/suggestion_panel.dart** | Target coverage UI, accept/skip suggestions with hover preview |

### `lib/features/traps/`

| File | Purpose |
|------|---------|
| **chess_core/generation/trap_line_info.dart** | Trap metadata + optional `allReplies`, `fen`, `refutationMove`, `refutationEvalCp` |
| **chess_core/generation/trap_reply.dart** | Opponent reply classification at trap position |
| **services/trap_index_service.dart** | FEN/prefix indexes, repertoire & line metrics, ETV |
| **widgets/trap_detail_card.dart** | Narrative trap UI, reply table, hoverable move path |
| **widgets/trap_navigation_buttons.dart** | Prev/next trap in line (board toolbar) |
| **widgets/trap_summary_header.dart** | Aggregate trap stats + ETV |
| **widgets/trap_tour_bar.dart** | Sequential trap tour bar with list hover preview |
| **widgets/traps_browser.dart** | Rich trap list with mini board, per-reply stats, classification badges, sort by Eval Drop/Most Common/Trap%/Surplus; filter toggle: All Explored vs In Repertoire (wired into repertoire screen Lines tab) |

### Generated tree presentation

The disconnected eval-tree graph, explorer and compact outline are retired.
`GeneratedRepertoire` retains the generated tree, FEN index, trap index,
configuration and probes; it no longer builds unused graph snapshots or subtree
metric caches. Builder's `GeneratePositionPane` uses `positionMoves` over the
shared FEN index and live generation nodes; its rows show the engine evaluation
and, in the next column, the stored expectimax value (`PositionMove.expectedCp`,
White's perspective), ordered by `storedCp` so the move that scores best against
likely replies is first. The engine continuation is the row's tooltip. While a
probe runs, the strip above the table shows the phase and the live stat line the
Jobs panel uses. `RepertoireLinesBrowser` derives its
line metrics through `services/line_metrics_helpers.dart`, `tree_my_ease.dart`
and `TrapIndexService`. The chapter/line outline and BuildTree serialization
remain active. Graph-layout guidance is historical; no graph widget remains.

### `lib/features/audit/`

Repertoire quality audit — BFS over the existing `OpeningTree` to detect mistakes, inaccuracies, missing opponent responses, weak positions, and dead ends.

**Shares the same caching infrastructure as generation:** Stockfish evals are read from and written to `EvalCache` (SQLite), so running an audit populates the cache for future generation runs and vice-versa. Maia policy/win-prob cached in `EvalCache.maia_cache`. Lichess Explorer mothballed (`ProbabilityService._fetchInternal()` returns null; `useLichessDb` defaults false). The audit is effectively "generation-shaped" — same engines, same persistent cache.

| File | Purpose |
|------|---------|
| **models/audit_finding.dart** | `AuditFinding` — JSON-serializable, with cumulative probability, dismissal state, `transposesIntoRepertoire` flag for missing moves |
| **models/audit_result.dart** | `AuditResult` — JSON-serializable aggregate: findings, stats, soundness/coverage %, cache hit rate |
| **services/audit_config.dart** | `AuditConfig` thresholds (mistake/inaccuracy cp, min games, Maia prob, depth); `useLichessDb` defaults `false`; `clashPgnPaths` for repertoire-clash checking against book/course PGNs; `toMap()`/`fromMap()` serialization; `summaryLabel` compact display |
| **services/repertoire_audit_service.dart** | Drives a `RepertoireWalk`: Stockfish MultiPV for our moves (via `EnginePositionProbe`), `MissingReplyFinder` for opponent gaps and dead ends, clash tree built from book/course PGNs; computes cumulative reach probability per finding; `pause()`/`resume()`/`cancel()`; exposes `checkedFens` for resume support; accepts `skipFens`/`priorFindings` to resume interrupted audits |
| **services/repertoire_walk.dart** | `RepertoireWalk` / `RepertoireWalkEntry` — the BFS the audit and the hole hunt share: ply limit, `RunControl` checkpoint per position, progress every 5 positions, reach attenuation charged to one side's branching (`attenuatingSideIsWhite`) |
| **services/engine_position_probe.dart** | `EnginePositionProbe` — the shared engine questions with the `EvalCache` in the loop: SAN-resolved MultiPV `discover`, `evalAfterMove` (line → cache → engine, with `EvalCacheStats`), deep single-PV `verify`; owns `DiscoveredCandidate` |
| **services/missing_reply_finder.dart** | `MissingReplyFinder` — per-run opponent-side sources in fixed order (Lichess, Maia, ChessDB, engine MultiPV, clash tree), first source to name a move owns it; transposition detection against the tree's `fenToNodes`; dead-end continuation counting |
| **services/audit_persistence.dart** | `AuditPersistence` singleton: centralized save/load for audit snapshots (`AuditSnapshot` = result + config + checked FENs + completion state). Auto-loads on repertoire open, auto-saves on dismiss changes. Handles v1 (legacy) and v2 (envelope) JSON formats |
| **widgets/audit_config_panel.dart** | Configuration-only route: Current chapter / current-position subtree, Stockfish + Maia, optional ChessDB strong replies, depth/ply/rating and validated detailed thresholds, optional clash PGNs. Calls `onStart(config, startFen)`; the session controller owns execution after the route closes. |
| **widgets/audit_findings_panel.dart** | Builder Findings tab: severity-first Priority or estimated Frequency sort, move/line search, category and clash filters, configurable visible cap, dismiss/restore, keyboard navigation and stable live selection. Chapter/count/settings context, source warnings, visible run errors, and interrupted-run Resume / Start fresh. |

**Entry points:** Builder's context-aware Audit action opens Findings for a run
or saved report, otherwise the **Check this chapter** configuration route.
The findings refresh action opens configuration again. Creation and organization
remain in Repertoires; audits stay beside the lines being reviewed.

**Persistence and lifecycle:** `<chapter>_audit.json` stores the result, config,
completion state, checked FENs for interrupted runs and optional subtree start
FEN. Old v1/v2 reports still load. Dismissal edits preserve partial status and
resume scope. Writes are serialized per report path. `AuditSessionController.launch`
owns engine preparation, service execution and cleanup; run versions guard
callbacks, and replacement runs wait for cancelled work to finish. Cancellation
and chapter switches save progress before invalidating the run. Engine startup
and run failures keep an interrupted report and expose an error. Resume traverses
already-checked positions for complete statistics without rechecking leaves.

**Data flow:** configuration → controller.launch → engine preparation → service
BFS → guarded findings/progress callbacks → report save → engine cleanup.
The service checks our moves with Stockfish MultiPV and per-move evals, checks
opponent replies with Maia / ChessDB / Stockfish / clash PGNs, and probes line
endings. Stockfish and Maia reuse the generation caches. Jobs controls pause,
resume and cancel through the controller.

**Practical limits:** This is a targeted chapter check, not proof of a sound or
complete repertoire. Depth, MultiPV, reply windows and source availability limit
coverage. Unavailable sources and unscored ChessDB positions produce persisted
warnings. Frequency estimates combine repertoire branch counts and source
probabilities; they are not measured frequencies from the user's games. Whole-
repertoire aggregation and automatic detection of edits since the saved audit
remain follow-ups. Rerun after changing lines. Soundness counts affected positions
once even when one move produces both a move-quality and weak-position finding.

**Finding UX:**
- Clicking a finding navigates within the existing repertoire tree (via `navigateToLineMove`) — the full tree with all variations is preserved.
- **Missing-move ephemeral preview:** Clicking a missing-move finding navigates to the parent position AND shows the missing move played ephemerally on the board (position after the missing move). A blue "Go to position" bar appears below the board with the missing move name; clicking it navigates to that position in the tree. Close button dismisses the ephemeral preview. Ephemeral state auto-clears when the user navigates normally.
- **Transposition detection:** Missing-move findings check if the resulting FEN (after playing the missing move) already exists in the repertoire tree. If so, the finding is tagged "transposes" in the summary — indicating the gap is less critical because the position is already covered elsewhere.
- Category filter chips: Blunders, Inaccuracies, Missing, Weak, Dead Ends — click to toggle (multi-select). Counts shown per chip.
- **Auto-scaling:** At most ~20 findings shown at a time (severity first by default). As findings are dismissed, the next priority items surface. Frequency ordering remains available. Status bar shows "20 of 150 findings" when capped.
- **Probability display:** Missing moves show Maia probability (e.g. "p=0.003 Maia" for small values). Uses adaptive formatting: ≥10% → integer, ≥1% → 1 decimal, ≥0.001 → 3 decimals, smaller → scientific notation.
- Move numbers in summaries: "Missing: 3...Nd2" instead of "Missing: Nd2". Also for mistakes/inaccuracies.
- Dismiss button: 16px icon with 32px hit target and hover feedback.
- Bulk dismiss via right-click context menu: dismiss similar (same type + FEN), dismiss at depth (all of same type at ply N or earlier), dismiss all of type.
- Keyboard navigation: ↓/↑ cycle through findings (board auto-navigates); dismiss with the row menu; suppressed while a text field has focus.
- Selected finding gets a highlighted background in the list, with "X of N" counter in status bar.
- Timestamp display: "2h ago", "3d ago", etc. when viewing saved results.
- Dismissed findings shown in a collapsed section at the bottom with "Restore all".

Implements principles from `docs/tree-display-architecture.md` (focused window, flat index, pre-sorted children).

### `lib/features/engine_tournament/`

Engine-vs-engine play. **The only place the app runs a binary that is not the
bundled Stockfish** — a user-supplied UCI engine has to pass
`verifyUciEngine` (start → `uciok` → `readyok` → a *legal* move from the
standard position) before it can be added, so a wrong pick is reported as a
sentence rather than as a match of silent forfeits.

The whole core is Flutter-free `dart:io`, which is what lets
`tools/run_engine_tournament.dart` drive the identical code path headlessly
into the same `Documents/engine_tournaments/` tree the app reads. That tool is
also how the MCP server runs matches, verifies binaries (`--verify`) and reads
standings (`--show`) — there is exactly one implementation of the arbiter and
of the Elo/SB/LOS maths, and everything else reaches it through that script.

The screen keeps a directory watch, so a match an agent starts fills in live
rather than waiting for someone to press Refresh.

Output is deliberately plain: one directory per tournament holding
`tournament.json` (config + per-game results) and `games.pgn` (the games, in
schedule order). Clicking a row in the games table hands that PGN to the PGN
Viewer with a game index, so the viewer's own Prev/Next then walks the match.

| File | Purpose |
|------|---------|
| **models/time_control.dart** | `TimeControl` — per-move, clock (base+inc, optional moves/session), fixed depth, fixed nodes; labels, PGN `TimeControl` tag, hang-guard ceilings, and the preset list |
| **models/engine_spec.dart** | `EngineSpec` — one competitor: binary path (null = bundled), name, Hash/Threads/Ponder, extra `setoption` pairs |
| **models/adjudication_rules.dart** | cutechess-shaped `-draw` / `-resign` knobs plus the move ceiling and the fifty-move/threefold toggles |
| **models/tournament_config.dart** | Snapshot of a tournament's setup; owns pairing generation (round robin / gauntlet) and `totalGames` |
| **models/tournament_game.dart** | `GameResult`, `TerminationReason` (with PGN `Termination` vocabulary), and the per-game record |
| **models/crosstable.dart** | Standings row + head-to-head grid data |
| **models/stored_tournament.dart** | What lives on disk: config, status, games, paths |
| **services/uci_engine.dart** | UCI process driver for *play* — handshake, options, clock-aware `go`, `bestmove` with score/depth/time, hang guard. Exposes the narrow `PlayingEngine` interface the arbiter uses |
| **services/engine_verification.dart** | The gate on user-supplied binaries; never throws, always reports |
| **services/engine_registry.dart** | `engines.json`; the bundled engine's *settings* persist but its path never does (it is resolved at launch) |
| **services/engine_game_runner.dart** | The arbiter: clocks, repetition/fifty-move, draw & resign adjudication, illegal-move and crash handling, and the PGN writer. Per-move cutechess-style `{+0.31/24 2.0s}` comments are opt-in (`TournamentConfig.annotateMoves`) — on by default they put every move on its own row in the viewer |
| **services/engine_tournament_runner.dart** | Schedule building, concurrent lanes with per-lane engine processes, persist-after-every-game |
| **services/tournament_store.dart** | `Documents/engine_tournaments/<slug>/` — atomic writes, listing, deletion |
| **services/tournament_open_request.dart** | The cross-process "open the app on this tournament" file (`open_request.json`), written by the MCP tools and consumed — read-and-cleared in one step — by the app. Requests older than a day are dropped so a forgotten one cannot hijack a launch |
| **services/tournament_open_watcher.dart** | Checks for a waiting request on start (which is what makes a request written while the app was closed work), then watches the directory. Timer-free on purpose: a poll in the always-mounted host screen would leak into every widget test that pumps it |
| **services/crosstable_builder.dart** | Points, W/D/L, Sonneborn-Berger, Elo ± 95% interval, likelihood of superiority |
| **services/tournament_summary.dart** | One-line readings for the history rail: match score (`Alpha 5½–4½ Beta`), leader of a field, duplicate-name disambiguation, day grouping and run duration. Pure — the arithmetic is `buildCrosstable`'s |
| **controllers/engine_tournament_controller.dart** | Screen state: list, selection, engine registry, live run (board + last move + progress) |
| **widgets/engine_tournament_screen.dart** | The mode screen; hands games to the PGN Viewer, and honours an `OpenEngineTournament` handoff (breadcrumb, or an agent's open request) |
| **widgets/new_tournament_dialog.dart** | Reusable setup in the Engine controls tab and new/rerun dialog; snapshots the selected tournament, edits the board, time control, schedule, adjudication and independent participant resource settings |
| **widgets/engine_manager_dialog.dart** | Add / verify / configure / remove engines |
| **widgets/tournament_list_pane.dart** | The history rail: every saved run, newest first, grouped by day, each row carrying its score; filter box appears past six runs |
| **lib/widgets/crosstable_view.dart**, **lib/widgets/match_games_table.dart**, **widgets/tournament_detail_pane.dart** | Head-to-head score and W/D/L counts, optional rating statistics, game lengths in moves, and a persisted final-position thumbnail toggle. `services/tournament_game_positions.dart` replays PGN mainlines off the UI thread, including older saved matches |

### Retired master-practice review

The disconnected master-practice comparison dialog, controller and review
algorithm/models are retired, along with their four exclusive tests/fixtures.
No application, tool, driver, plugin or Widgetbook entrypoint reached this
three-file subtree; the earlier claim that Home Openings launched it was stale.
This removes 1,163 production lines without a replacement. It retires an unused
feature rather than marking a migrated feature complete.

The live master-games database/service, opening explorer, Games opening review,
and generation's master-book coverage, selection and improvement algorithms remain.

### `lib/features/holes/`

Adversarial "Find Holes" hunt — hosted in Player Analysis (`analysis_screen.dart`), which keys results per player + colour. **Different from Analyze with Engine** (raw Stockfish eval coloring of most-played positions): this walks the loaded tree from the ATTACKER's side (opposite the tree's colour) and emits exploitable findings — `uncoveredStrongMove` (engine-strong attacker moves with no reply on file), `refutation` (owner moves that concretely lose, with verified Stockfish PV), `trickyMove` (near-best attacker moves and novelties whose Maia expectimax value beats the engine-best move's raw eval — the owner is expected to misplay by more than the trick concedes). One MultiPV discovery per attacker position feeds both the uncovered check and the trick candidates; attacker-to-move leaves get discovery after the walk under the probe budget (most reachable first), which is how the hunt reaches past the recorded games; the top candidates by reach (discounted by objective cost) each get a short expectimax probe. Ranked by `exploitScore` (reach × gain) into a short killer list, not a breadth checklist. Reuses the audit's `AuditFinding` model and shared `EvalCache`/`StockfishPool`. Without Maia the walk still runs and the report notes that the trick search was skipped; the config dialog hides the trick knobs.

| File | Purpose |
|------|---------|
| **services/hole_hunt_config.dart** | `HoleHuntConfig` — walk thresholds plus the trick-probe knobs (window, budget, ply, eval depth, net-gain floor, Maia rating) |
| **services/hole_hunt_service.dart** | Adversarial walker on the audit's `RepertoireWalk` and `EnginePositionProbe`: attacker-side BFS, Stockfish refutation verification, post-walk leaf discovery, then the probe pass via `TrickProbe`; `HoleHuntProgress` with walking/leaves/probing phases |
| **services/trick_probe.dart** | The probe pass: `TrickProbe` builds a short Maia expectimax tree per candidate and reports a `trickyMove` when the root's practical value beats the engine-best move's raw eval by the net-gain floor. Its builds come from an injectable `ProbeTreeBuilder`, and it owns the Maia readiness gate |
| **services/hole_scoring.dart** | Pure helpers: `TrickTarget` and top-by-reach selection, `TrickCandidateMetrics` (the White-to-attacker sign flip), candidate windowing, probe prescreen; engine/widget-free for unit tests (reach propagation lives in the audit's `repertoire_walk.dart`) |
| **services/hole_hunt_persistence.dart** | `HoleHuntSnapshot` JSON save/load at a caller-supplied path via the audit's `HuntReportStore`; no resume state — cancels save partial reports |
| **widgets/hole_hunt_config_dialog.dart** | Config dialog; pops with a `HoleHuntConfig`, the host screen owns the hunt lifecycle |
| **widgets/holes_report_panel.dart** | Ranked report for the Holes list: flat list sorted by exploit score, Uncovered / Refutations / Tricks filter chips, visible cap, dismissal, prev/next stepping |

### `lib/screens/`

| File | Purpose |
|------|---------|
| `main_screen.dart` | Mode `IndexedStack`; engine suspend/resume on leaving/entering interactive-engine modes and on `paused`/`hidden`/`detached` (not `inactive`) |
| `repertoire_screen.dart` | **Composition root** — wires `GenerationSessionController`, `AuditSessionController`, `CoverageController` to widgets; owns board, PGN, ephemeral finding preview, layout; when no repertoire is selected shows `RepertoireListBody` inline instead of a placeholder button; keyboard shortcuts via `RepertoireShortcuts`; status bar shows "Audit paused" when audit is paused; Jobs panel listens to both `_jobManager` and `_generationController` via `Listenable.merge` |
| `features/repertoires/widgets/repertoire_selection_screen.dart` | Workspace destination around `RepertoireListBody`; returns a typed `ChapterPick` |
| `repertoire_training_screen.dart` | Repertoire and study trainer: a stable board beside the source picker, chapter/line browser or current lesson; Learn and Review respect the selected chapter and session size. Read opens the canonical PGN Viewer. The settings gear follows the global mode switcher; Skip is visible, and Line actions include persistent exclusion. The browser restores excluded lines without discarding review history. Keyboard: Space acknowledges the next learning step, arrows skip lines, `/` focuses move input, Escape returns to the browser. |
| `analysis_screen.dart` | Game weakness / position analysis |
| `study_screen.dart` | **Composition root** for Study mode — wires `StudyController` to `StudyBoardPane`, `StudySidePane`, `StudyPickerBar`, `StudyChapterSidebar`; keyboard, import/export, train/browse handoffs stay on the screen |
| `pgn_viewer_screen.dart` | Standalone PGN + `InlineEngineBar`; surfaces `loadFile` errors via SnackBar and empty-state text; solitaire mode toggle + feedback overlay + progress bar; keyboard: arrows, Home/End, Enter, Space, Escape, Ctrl/Cmd+V paste, F11 fullscreen; caches `AppState` so dispose does not `context.read` |
| `player_selection_screen.dart` | Embedded player pick for analysis, with a bounded list and direct per-player actions: cached game-sets from chess.com / lichess downloads, PGN-file imports, and **opponent lists** (`OpponentListImportDialog` → one merged player per opponent, sourced from every account listed, tagged with the event as `group`; batch download with per-person progress, skip-existing, failures reported not swallowed); search matches name, platform and group |
| `settings_screen.dart` | Flat settings sections with keyword search, direct preferences, embedded databases and contextual forms. See the complete Settings control map above. |

### `lib/services/` (grouped)

#### Engine & analysis

| File | Purpose |
|------|---------|
| `engine/engine_lifecycle.dart` | OFF/IDLE/ANALYZING/GENERATING state machine; `toggleOn`/`toggleOff`/`enterGeneration`/`exitGeneration` serialized via `_serialExec`; `suspend`/`resume` preserve `_userWantsEngine`; `onPositionChanged` skips notify when already ANALYZING; `@visibleForTesting resetForTest()` resets singleton; `testMode` skips pool I/O in unit tests |
| `engine/engine_connection.dart` | Abstract engine connection |
| `engine/eval_worker.dart` | UCI worker loop |
| `engine/stockfish_pool.dart` | Worker pool acquire/release, `prepareForTreeBuild` |
| `engine/stockfish_*_connection.dart` | Platform Stockfish backends |
| `engine/process_connection*.dart` | Process spawn (native/stub). Delegates path setup to `stockfish_bundle.dart`. |
| `engine/stockfish_bundle.dart` | Installs desktop Stockfish: support-dir cache, then bundled `.gz`, then download of the lockfile URL (checksummed). macOS lock key is arch-specific; the extracted file is always `stockfish-macos`. |
| `analysis_games_service.dart` | Fetch/store analysis game-sets; `downloadGamesFor(player)` is the single (re-)download entry point — one live account, or every `account` of an opponent concatenated into one PGN |
| `game_analysis_controller.dart` | Game review session; cached and live replay pass ChessBase `--`/`Z0` without dropping later plies (1-based PGN ply still includes the pass) |
| `engine_weakness_service.dart` | Weakness detection |
| `unified_analysis_builder.dart` | Builds unified analysis structures |

#### Eval providers & chain

| File | Purpose |
|------|---------|
| `eval/eval_chain.dart` | Ordered provider chain |
| `eval/cdbdirect_eval_provider.dart` | Local TerarkDB/CdbDirect |
| `eval/chessdb_api_provider.dart` | ChessDB.cn API |
| `eval/sqlite_eval_provider.dart` | Local SQLite cache |
| `eval/in_memory_eval_provider.dart` | Session hash |
| `eval/external_eval_provider.dart` | Remote eval abstraction |
| `eval/db_move_list.dart` | `ExternalMoveProvider` — a database's whole ranked move list (`DbMove`/`DbMoveList`), not just a score; what `BuildMode.chessDbBook` builds from |
| `eval/chessdb_score.dart` | ChessDB's raw score encoding (plain cp, mate as ±(30000−ply)), decoded once for both ChessDB faces |
| `eval/cdb_snapshot_catalog.dart` | Which full dumps exist and what they cost — reads the published `chess-YYYYMMDD` snapshots off the Hugging Face mirror of chessdb.cn (per-file sizes and SHA-256, so the download knows the exact total before it starts). Parsers are pure and tested; the network half is one injectable `http.Client` |
| `eval/cdb_snapshot_download.dart` | The ~1.2 TB transfer itself: four parallel HTTP range requests, per-file resume (a partial file continues from its own length, a finished one is never re-fetched), pause/resume across app restarts, a free-space guard that parks the job rather than filling the disk, and `check()` to compare local lengths against the manifest. Registers a resumable `JobType.evalDatabase` job and points `EvalDatabaseSettings` at the `data/` folder when it finishes |
| `eval/storage_volumes.dart` | `df -PB1 -T` → mounted volumes with free space, deduped per device, each tagged SSD / hard disk / network from `/sys/block/*/queue/rotational` (LUKS and LVM resolved through `slaves`). Also `formatBytes` / `formatDuration`, used wherever the download reports size or ETA |
| `eval/lichess_eval_source.dart` | What `database.lichess.org` is publishing today: a `HEAD` for the size and `Last-Modified` (which is the file's only version identity — Lichess refreshes it in place) plus the page scrape for the position count and publication date. Falls back to the September 2026 figures, flagged, when the site is unreachable |
| `eval/lichess_eval_line.dart` | One JSONL line → one row. Scans the text directly instead of `jsonDecode` because the import reads 394M lines averaging 716 bytes; keeps the deepest eval's first PV. Documents the sign convention (`cp` and `mate` are **White-relative**, established from the data, not from the download page) and packs the best move into 15 bits |
| `eval/zstd_stream.dart` | Streaming zstd, so the 21.7 GB download is never expanded to disk: libzstd through FFI where the library exists (Linux, macOS), the `zstd` command as the fallback. Detects a frame that ends early, so a truncated download fails instead of quietly building a partial database |
| `eval/lichess_eval_store.dart` | The sorted flat store the evals live in — 15-byte records keyed by the same FNV position key the master-games book uses, with a sparse index every 1024 keys. ~5.9 GB and one disk read per lookup, where the equivalent SQLite table would be ~10 GB of random-insert B-tree |
| `eval/lichess_eval_import.dart` | Scan then merge: decompress, parse, append each record to one of 256 bucket files chosen by the key's top byte; then sort each bucket in memory and concatenate. Checkpoints line count and bucket lengths so an interrupted scan resumes without re-parsing or double-counting, and discards the buckets when a newer file is published |
| `eval/lichess_eval_provider.dart` | `ExternalEvalProvider` over the store, converting the published White-relative scores into the white-normalized cp / side-to-move mate the rest of the app uses |
| `eval/lichess_eval_controller.dart` | Owns the two stages behind one progress bar — resumable range download, then the import isolate — with a free-space guard, Jobs-pane integration, and delete-the-archive / delete-everything. Points `EvalDatabaseSettings` at the store and switches it on when the build finishes |
| `eval_cache.dart` | Eval cache facade (SQLite v2): Stockfish evals + `maia_cache` table keyed by `(fen, elo)` (policy JSON, win prob); `MaiaCache` get/put with L1 in-memory mirror; get/put await idempotent `init()` so background warm-up in `main` cannot leave early writes memory-only; fire-and-forget writes use `putEvalCpWhiteSoon`; shared by generation, audit, and interactive engine panes |

#### Generation pipeline

| File | Purpose |
|------|---------|
| `tree_build_service.dart` | BFS tree build; canonical-FEN transposition table with `propagate_higher_cumP` on higher-probability transposition hits; root MultiPV floor `max(ourMultipv, 10)` at ply 0; MultiPV line-0 PV reply stash + opponent-node injection when Maia omits it; `buildFromPgnFreqMap()` for DB Explorer mode |
| `generation/pgn_freq_map.dart` | PGN frequency map (Dart port of C `pgn_freq.c`): isolate-based PGN parsing via `file_text_reader` (UTF-8 with Latin-1 fallback), FEN-based prefix matching (games reaching target via transposed move orders), per-position move frequencies keyed by 4-field canonical FEN, min-elo filtering, move probability filtering; detailed parse warnings (first 10 failures); tracks `fileReadErrors` in stats. `pgn_freq_parser.dart` treats `--`/`Z0` as a turn pass (no `recordMove`) so later same-side SAN stays legal |
| `generation/pgn_freq_cache.dart` | Disk cache for parsed frequency maps (`<pgn>.freq.cache`); manifest keyed on file path/size/mtime + `startFen`/`startMoves`/`maxPly`/`minElo`; binary format compatible with C `PFREQ` layout |
| `generation/line_extractor.dart` | Extract lines from tree; PGN `{engine-injected}` on injected opponent moves |
| `generation/pgn_export.dart` | Shared generated PGN export through `export/pgn_game_writer.dart`. New exports have no generated comments. Advanced output checkboxes independently enable evaluations, expectimax values, source-labelled Maia probabilities/database frequencies, and explanations/extra statistics. Saved explicit annotation choices still load. Ranking metadata stays in headers. |
| `generation/repertoire_slice.dart` | Cut lines ranks a loaded selected build by weighted decision coverage, preserves required transposition owners, and matches PGN entries using the saved starting-move prefix. It deletes matching entries only; it neither restores earlier cuts nor folds new sidelines. Coverage is relative to the saved build. |
| `generation/generation_config.dart` | `TreeBuildConfig` (default `evalDepth` 14, `relativeEval` true), build modes; `summaryLabel` / `buildModeLabel` / `engineResourceLabel` for Jobs panel; DB Explorer fields: `pgnFilePaths`, `dbMinGames`, `dbMinProb`, `minElo` |
| `generation/tree_eval_resolver.dart` | Eval resolution during build |
| `generation/tree_ease.dart` | Opponent ease calculation |
| `generation/tree_my_ease.dart` | Our-move naturalness + line playability |
| `generation/eca_calculator.dart` | Expectimax + trap scores + per-node opponent CPL (diagnostic) |
| `generation/repertoire_selector.dart` | Mark repertoire moves on tree (3 objectives; novelty weight and tie-breaks on top) |
| `generation/trap_extractor.dart` | Trap candidate collection |
| `generation/fen_map.dart` | Transposition map keyed by 4-field canonical FEN (`canonicalizeFen`); `freeze()` after `GeneratedRepertoire.fromTree`; shared cycle helpers `isTranspositionCycle` / `enterFenPath` / `enterPositionOnce`; `resolveTransposition(node, fenMap)` follows canonical FEN when a leaf has children elsewhere |
| `generation/tree_build_progress.dart` | Progress callbacks |

#### Repertoire & PGN

| File | Purpose |
|------|---------|
| `repertoire_service.dart` | Load/save repertoire, parse lines, append moves; in-place line edits and deletion locate games via `_findGameIndexByLineId` and rewrite via `_reassembleDocument` (atomic `_writeAtomically`); `deleteLine(filePath, lineId)` removes a game from disk |
| `repertoire_review_service.dart` | Review scheduling |
| `chess_core/pgn/pgn_text.dart`, `chess_core/pgn/pgn_position_replay.dart`, `chess_core/pgn/pgn_slice_filter.dart`, `infrastructure/documents/isolate_pgn_collection_filter.dart` | Multi-game split/count (`splitPgnIntoGames`, `countPgnGames`); `[Event]`-delimited chunks, including back-to-back games without blank lines (tree_builder exports); `buildFenIndex` builds an inverted FEN→game-indices map in an isolate for O(1) position lookups (mainline **and RAVs**); `computeSliceMatches` is the shared entry point for position+header+sequence filtering (fast path with FEN index, slow path without); `serializeFenIndex`/`deserializeFenIndex` persist the index as a FENIDX3-format companion `.fenidx` file (header stores game count, PGN file size, and mtime for staleness detection; older blobs rebuild); `parseTargetFen` / `gamePassesThroughFen` / `buildFenIndex` / `mainlineSansAfterFen` replay ChessBase/Chessable **null moves** (`--` / `Z0`) as a turn pass so later same-side SAN stays on the index; `promoteNullMoveDummyMainline` runs before replay so Chessable intro chapters index the lesson moves; `gameMatchesSequence` ignores those tokens; `mainlineSansAfterFen` returns remaining SAN after a FEN along the line that found it (used by the opening-tree games list PV) |
| `opening_tree_builder.dart` | Build opening tree from PGN via `walkMainlineIntoTree`; `*` / empty Result → `userResult: null` and `includeVariations: true` (course sidelines become tree siblings); scored games stay mainline-only; `--`/`Z0` pass without a tree node |
| `pgn_tree_core.dart` | Shared PGN attribution + walk used by `OpeningTreeBuilder` and `UnifiedAnalysisBuilder`; `includeVariations` counts each RAV as a line so sibling frequencies still sum to 100% |
| `default_pgn_service.dart` | Bundled default PGN extraction (`rootBundle.load` + `decodeTextBytes` for Latin-1/Windows-1252 names in legacy PGNs) |

#### Expectimax & lines

| File | Purpose |
|------|---------|
| `expectimax_line_service.dart` | `followExpectimaxLine`, `generateExpectimaxLines` (capped, used by the hole hunt's trick probes), `expectimaxLinesForAllMoves` (the pane's position table), `findNodeByFen`, `ExpectimaxLine` model. Pure reads of the cooked tree |
| `line_metrics_helpers.dart` | Line-level quality/trap/coherence metrics for UI |
| `coherence_service.dart` | FP-Growth coherence + browse hints; `compute()` runs mining in `Isolate.run` |
| `fp_growth.dart` | FP-Growth algorithm |
| `probability_service.dart` | Move probability helpers; `_fetchInternal()` mothballed (returns null immediately, no Lichess Explorer API) |

#### Maia & Lichess

| File | Purpose |
|------|---------|
| `maia/maia_service.dart`, `maia/maia_native.dart`, `maia/maia_stub.dart`, `maia/maia_factory.dart`, `maia/maia_tensor.dart` | Human move prediction; ONNX model + vocab JSON are git-tracked Flutter assets; native ORT comes from the `onnxruntime` plugin (Linux/Windows/macOS). `evaluate()` checks `MaiaCache` before inference. |
| `lichess_api_client.dart` | Authenticated API; explorer lookups ask for the games lists, and `fetchGamePgn` fetches one listed game from the masters PGN endpoint or the site's export |
| `explorer_game_opener.dart` | Opening a game the explorer listed: fetch its PGN (local database, masters endpoint or game export), file it in the `explorer-games.pgn` collection without duplicates, and report the index and the ply at which it reaches the position |
| `live_explorer_service.dart` | Debounced, cached, coalesced explorer lookups for the panel; the TWIC source is answered synchronously from the local book (classical-only rows when asked) with the citation and latest game per move as its games list |
| `master_games/book_replay.dart` | The one replay of stored movetext into `book` rows (`movetextSans`, `replayBookMoves`, `resultTally`, `strongerElo`) shared by the importer, the classical rebuild and the model-game picker |
| `master_games/master_book_rebuild.dart` | Replays the classical games into the book's classical columns — citations (v3) and classical-only counts (v4) — for a database imported before they existed; chunkable by `afterId`/`maxGames`, which is how `MasterGamesService.rebuildClassicalIndex` runs it from an isolate |
| `lichess_auth_service.dart` | OAuth/PAT token storage |
#### Tactics & training

| File | Purpose |
|------|---------|
| `features/tactics/services/alternative_move_judge.dart` | "Accept other winning moves": `isAcceptableAlternative` is the rule (the played move must score within 50cp of the stored answer, both from the mover's side — a slower mate passes, trading a mate for a won endgame does not); `EngineAlternativeJudge` scores the position after each move at depth 14 on one pool worker and answers `false` whenever it cannot ask (no engine, a build holds it, an unparseable move). The session controller shows "Checking…", locks input, drops a verdict that arrives after a reset, and finishes the tactic on the played move when the answer is yes |
| `features/tactics/services/tactics_engine.dart` | Puzzle validation; `buildTrainableLine` extends lines using **Maia opponent-probability** (≥ 85% threshold) when available — agreement with PV continues from PV, disagreement triggers a fresh Stockfish depth-14 eval for the user's best reply then stops, low confidence stops at single move; falls back to captures/checks/mates heuristic when Maia is unavailable; max 6 ply (3 user moves); `solutionPv` + `solutionLineToSan` for Show Solution |
| `features/tactics/services/tactics_database.dart` | Local puzzle store; `startSession(settings)` builds filtered/ordered queue; `setRating(fen, rating)` persists star rating + removes 1-star from live queue |
| `features/tactics/services/tactics_import_service.dart` | Import from Lichess/Chess.com; supports `since` parameter for date-based fetch (Lichess `since` query param, Chess.com archive month filtering + PGN date header filtering); 200-game safety cap on date-based imports; initializes Maia at import start; extracts user Elo from first game PGN headers (`WhiteElo`/`BlackElo`) — Lichess uses PGN Elo as-is; Chess.com maps blitz Elo via `chesscom_lichess_elo.dart` then clamps 600–2400 (default 2200); passes `MaiaEvaluator` + `EvalWorker` to `buildTrainableLine` for line extension; **atomic per-game completion**: positions are awaited/persisted before `markGameAnalyzed`, so an app close mid-batch never permanently skips a game's blunders; `countPendingGames()` reports stored-but-unanalyzed count; `resumeStoredPgns()` re-analyzes from storage (splits by source prefix, uses appropriate username per platform); all public import/resume methods return `ImportResult` (`positions`, `gamesAnalyzed`, `gamesSkipped`) so callers can distinguish "all skipped" from "analyzed with no blunders" |
| `features/tactics/services/tactics_parallel_analyzer.dart` / `features/tactics/services/tactics_parallel_analyzer_stub.dart` | Parallel puzzle analysis |
| `features/tactics/controllers/tactics_session_controller.dart` | Puzzle session; `startSession(settings)` delegates to DB queue; `setRating(star)` on current position |
| `features/tactics/services/tactics_import_coordinator.dart` | Import UI coordination; `TacticsImportMode.recent` / `TacticsImportMode.sinceDate` for count-based vs date-based fetch; passes `since` param through to service; **resume analysis**: `refreshPendingCount()` diffs stored PGN game IDs against `analyzedGameIds` to detect interrupted imports; `resumeAnalysis()` re-processes only un-analyzed games from storage (no re-download); `pendingGameCount`/`totalStoredGames` drive the resume button; `_statusMessage(ImportResult)` picks "Games were already analyzed" / "No new blunders found" / "Added N …" based on `gamesAnalyzed` count |
| `features/training/controllers/training_session_controller.dart` | Injected repertoire training flow; `TrainingMode` × `RepetitionMode`; owns queue, drill, and session stats. Learn walkthrough and missed-move replay are collaborators (`LearnPhase`, `ReplayPhase`); chapter grouping is `ChapterScope`; disk review state is `ReviewProgressStore` |
| `training/learn_phase.dart` | New-line acknowledge / quiz walkthrough |
| `training/replay_phase.dart` | Missed-move replay after a drill with mistakes |
| `training/chapter_scope.dart` | Chapter grouping and training scope |
| `training/review_progress_store.dart` | Persisted SRS entries, per-move streaks, history writes |
| `training/training_phase.dart` | Phase enum/state |
| `opponent_list.dart` | Parse opponent-list JSON (`chess-auto-prep/opponents@1`) into `AnalysisPlayerInfo` entries for Player Analysis |

#### Storage & platform

| File | Purpose |
|------|---------|
| `storage/storage_service.dart` | Abstract file I/O; `listRepertoireFiles()` → `List<RepertoireMetadata>` |
| `storage/io_storage_service.dart` | Desktop/mobile IO; `_resolveFile` maps relative paths to app documents; `readFile` / PGN reads use UTF-8 with Latin-1 fallback via `utils/file_text_reader.dart`; `listRepertoireFiles` filters out `*_raw_games.pgn` companion files; `fileStat` returns file size + modification time for index staleness checks |
| `storage/storage_factory.dart` | Platform factory |
| `storage/app_paths.dart` | Version-independent document, support and local cache roots |
| `storage/schema_guard.dart` | Reject newer SQLite schemas; flushed SQLite snapshot before saved-game schema upgrades |
| `features/updates/services/app_update_service.dart` | Daily stable GitHub release checks, persisted check/download preferences, streamed size/SHA-256 verification, reusable verified download, install scheduling/cancellation |
| `features/updates/services/update_installer.dart` | Detect Windows Setup, Linux deb/rpm or marked portable bundles; launch an acknowledged detached helper that waits for normal app close |
| `features/updates/widgets/app_updates.dart` | Startup update popup and Settings → App controls; installation is explicitly scheduled, never a forced exit |

**Storage and upgrade policy.** Installation directories contain replaceable
application code/assets. App version numbers never enter the user-data paths.
`AppPaths` remains the canonical app-side directory boundary:

| Data | Existing location / policy |
|---|---|
| Repertoires, studies, tactics sets, opponents, collections and tournament work | Named directories directly under OS Documents; legacy training/review CSV and analyzed-game files also live at its root. These are intentionally unchanged for existing users. PGN/CSV remain exportable independently of the app. |
| User games | `app_games.db` in application support; current schema 2. Before changing an older schema, `VACUUM INTO` makes a consistent `.before-schema-2.sqlite` backup including committed WAL contents. DDL, rekeying and schema version update share one transaction. |
| Master games | `master_games.db` in support; current schema 4. Transactional migration; old schema 1 is a deliberately rebuildable download cache. |
| Evaluation cache | `eval_cache.db` in support; current schema 4. Existing sqflite migrations preserve/rekey Stockfish evals and can invalidate Maia policies. A newer schema is refused by sqflite and the cache falls back to memory. |
| Settings and accounts | SharedPreferences under the platform application-support identity; defaults supply missing preference keys. Tokens currently use this store too, rather than an OS credential vault. |
| Extracted engines / downloaded database locations | Engines are reproducible support data. Large optional evaluation stores retain their user-selected paths; upgrades must not silently relocate these. |
| Update downloads / logs | `AppPaths.cacheDirectory()/updates/`, using LocalAppData on Windows. Kept outside installation and durable documents; a cached payload is verified again before reuse/install. Install logs and retained Linux bundles are currently retained for explicit troubleshooting/cleanup. |

Linux support is normally `$XDG_DATA_HOME/com.example.chess_auto_prep`
(default `~/.local/share/com.example.chess_auto_prep`); path_provider preserves
an existing legacy executable-name directory. Windows support is normally
`%APPDATA%/com.example/Chess Auto Prep`. Windows CompanyName/ProductName,
the Linux application/executable IDs, and the Windows Setup AppId therefore
form a **storage identity**; changing branding in those fields needs an explicit
migration. Flatpak's sandbox creates a separate profile from native packages;
switching package families does not automatically import the other profile.

This is a best-effort forward-upgrade policy, not a public compatibility or
rollback guarantee. User-game and master-game readers reject future schemas
before changing journal mode or schema, close failed connections, and do not
classify newer schemas as corruption. A failed user-game migration rolls back
and retains the pre-migration snapshot. Existing atomic file writers and PGN/CSV
migration backups remain the document protection boundary. Unknown custom PGN
annotations/JSON formats still need feature-specific fixtures when changed;
there is no universal version envelope for every file format.

`test/fixtures/storage/app_games_v1.sql` is frozen independently of current
writers. `upgrade_contract_test.dart` tests preservation, reopening, migration
failure rollback and future-schema refusal. Existing data-integrity and eval
migration tests run in the release quality gate. A separate Windows quality job
runs updater/upgrade contracts before release builds. Offline `test_storage_contract.py` pins
storage identities and legacy folder names; change those assertions only with
a reviewed data migration. `test_app_updates.py` exercises the shipped helper
against disposable bundles (wait/cancel, verified replacement, checksum and
traversal rejection, rollback). Windows cases compile disposable .NET executables
to exercise the shipped `.exe` launch contract, including paths with spaces,
apostrophes and non-ASCII characters, checksum rejection, installer failure,
waiting and cancellation. The Windows helper reads the app's request as UTF-8.
It uses its host's bundled PowerShell modules so a parent PowerShell 7 process
cannot hide Windows PowerShell 5.1's checksum command with incompatible modules;
the native tests also cover an inherited module path without the host modules.
Helper failures return a nonzero exit code and retain the installation error;
the Windows quality job uploads diagnostic logs on failure.
Real Windows Setup and Linux package-manager authorization still need native
release smoke testing. No release or update is triggered by these tests.

### `lib/widgets/` (grouped)

#### Shared UI patterns

| File | Purpose |
|------|---------|
| `shortcut_tooltip.dart` | **Shortcut hover tooltips** — `actionTooltip()`, `ShortcutIconButton`, `ShortcutTooltip`, `shortcutTooltip()` (500ms hover delay); unassigned actions omit the suffix. Tests: `test/widgets/shortcut_tooltip_test.dart`. |
| `common/list_search_field.dart` | Compact one-line filter box (`fontSize` 13, 6px radius outline) used by list toolbars and `GameSearchDialog`; `matchesSearch` is the shared contains-filter |

#### Layout (repertoire builder zones)

Builder uses the screen's wide/compact workspace layouts. The unused configurable
Edit context layout, arrangement sheet, model, descriptors and preference writer
are retired; no production route constructed that subtree. The existing Viewer
opening-tree divider remains shared. This removes 1,124 dormant production lines
and does not change active editor, document or save ownership. The screen now
composes `RepertoireBoardPane` directly and the toolbar places its existing trap
navigation directly. `RepertoireLayoutPrefs` retains only live board, outline
and analysis-dock preferences; `analysisCollapsed` preserves the existing
`repertoire.lines_panel_collapsed` storage key. The unused right-side Lines
width/state, generic expanded side panel and optional notation header are
removed. The notation surface retains its clipping, border and child geometry.

| File | Purpose |
|------|---------|
| `features/repertoire/widgets/repertoire_outline_controls.dart` | Collapsed chapter strip and outline resize handle; only the live left-hand outline can be resized |
| `layout/edit_context_split_handle.dart` | Draggable divider retained by the PGN Viewer opening-tree panel |
| `layout/bottom_pane.dart` | VS Code-style resizable, collapsible bottom pane with tabs (Findings/Jobs); collapsed by default, opens at max height (60%) to minimise board area, auto-opens on audit/generation start, drag-resizable, badge counts |
| `layout/repertoire_status_bar.dart` | Bottom metrics bar (badges open bottom pane tabs) |
| `layout/empty_state_placeholder.dart` | Shared empty states |
| `repertoire_list_body.dart` | Embeddable repertoire list with import/rename/delete; the standard dark Open PGN file… action (matching the PGN viewer label) opens the native file picker immediately, saves under a safe unique filename-derived name, and opens the imported chapter. Create new repertoire opens the shared creation form and returns to its caller. A quieter Paste PGN action accepts text without setup; naming stays on the library cards and training side/settings remain available in Train. `features/repertoires/widgets/repertoire_import_dialog.dart` owns both flows; used inline by Builder and Trainer screens when no repertoire is selected, and by `RepertoireSelectionScreen` as a full-screen push; optional `onStudySelected` adds a "Studies — custom tactics" section (trainer only; study management stays in Study mode) |
| `layout/responsive_split_layout.dart` | Generic split helper |

#### Repertoire-specific

| File | Purpose |
|------|---------|
| `features/repertoire/widgets/repertoire_board_pane.dart` | Board + preview overlay + generation dim |
| `features/repertoire/widgets/repertoire_shortcuts.dart` | `RepertoireShortcuts` — `CallbackShortcuts` (Ctrl/Cmd+Z undo, Ctrl/Cmd+Shift+V paste FEN) + `Focus.onKeyEvent` for arrow/Escape bindings; suppresses shortcuts while a text field is focused (`isTextInputFocused()` in `lib/utils/keyboard_shortcut_utils.dart`) |
| `features/repertoire/widgets/repertoire_toolbar.dart` | App bar: repertoire/chapter breadcrumb title; Actions → view picker → gear. |
| `generation/generation_config_form.dart` | `GenerationConfigForm` — settings form (controllers, build mode, advanced thresholds, eval sources); prominent **Engine resources** section (threads, hash MB, logical core count) when Stockfish is used; `toConfig({startFen, playAsWhite})`, `validateBeforeStart()`, optional `initialConfig`; DB Explorer mode shows `PgnSourcesPanel` + tuning fields; owns `EvalSourcesController` / `SkeletonPlanController` / `PgnSourcesController`, which hold the three sub-editors' state |
| `generation/eval_sources_controller.dart` | `EvalSourcesController` — the eval lookup chain's settings (local ChessDB file, ChessDB API quota/concurrency, subtree skip, depth floor) plus today's API spend; `applyConfig` ↔ `applyTo` are the two halves of the config round trip |
| `generation/skeleton_plan_controller.dart` | `SkeletonPlanController` + `kStructureVetoes` — the typed lines and active vetoes behind `SkeletonPlanCard`; `loadPlan` / `currentPlan(playAsWhite:)` |
| `repertoire_generation_tab.dart` | Configuration UI; embeds `GenerationConfigForm` via `GlobalKey`; submits a `GenerationRequest` with captured job label, source/root and config plus the publication/adoption callback the controller awaits. `GenerationSessionController` owns run ordering and the pause/cancel partial-save context |
| `repertoire_lines_browser.dart` | Filter/sort/group lines; 300 ms search debounce; typed `LineSortBy`/`LineMetricsFilter`; filter reset uses single `setState` |
| `interactive_pgn_editor.dart` | Tree-structured PGN editor sharing the viewer's borderless move selection, hover, and NAG styling; prose and indented variations break into reading rows. Context menu supports comments, promotion, copy and delete; memoizes movetext by tree identity/version while selection repaints only affected chips. I/O via `onAutoSave`/`onDirty`/`onCopyToClipboard`/`onViewInLines` callbacks; shared Notes editor below the moves |
| `opening_tree_widget.dart` | Compact tree navigator. Continuations come from `OpeningTree.continuations` (played moves plus one-ply transpositions, marked `≈` / "transp.") |
| `opening_tree/opening_tree_move_row.dart` | Tree row |
| `opening_tree/coverage_annotation.dart` | Coverage badges on tree |
| `features/coverage/widgets/coverage_calculator_widget.dart` | Run coverage analysis UI |

#### Engine widgets

| File | Purpose |
|------|---------|
| `engine/inline_engine_bar.dart` | Compact engine for PGN viewer and tactics; reserves a fixed height for the configured MultiPV count while enabled, including loading and positions with fewer legal moves; settings button opens `AnalysisSettingsContext.tacticsEngine` (depth + multiPv only); writes Stockfish eval to `EvalCache` after discovery completes |
| `engine/floating_board_preview.dart` | Cursor-following mini board overlay on engine/expectimax line hover |

#### Lines sub-widgets

| File | Purpose |
|------|---------|
| `lines/line_filter_controls.dart` | Compact search + sort/coverage filter chips (same 6px-radius outline as `ListSearchField`) |
| `lines/line_item_row.dart` | Single line row + trap/coherence badges; unaccounted-move preview sorts a copied list (does not mutate source); trash icon with confirm dialog (`onLineDeleted` callback) |
| `lines/line_metrics_panel.dart` | Metrics + Next/Biggest gap buttons |
| `repertoire_lines_browser.dart` | Owns filters, sorting, indexes and scrolling; renders its table header and lazy line list directly, with reusable row/header cells and coverage prompt. No intermediate list-panel forwarding contract. |

#### Shared / other modes

| File | Purpose |
|------|---------|
| `app_mode_switcher.dart` | Top-level View selector: bordered current-mode button and separator, with the grouped mode menu behind it |
| `chess_board_widget.dart` | Board rendering, move input; coordinates follow the Display preference unless the caller passes `coordinates:` (thumbnails under 24px squares are always bare; *outside* takes a margin out of the squares — see `board/board_coordinates.dart`, whose `coordinateLabels` is the pure placement rule); `board/board_square_painter.dart` owns the shared surface for interactive boards, the position editor and static thumbnails. Selection, explicit hint/preview highlights, and recent moves use borderless tints (in that precedence); legal destinations use dots on empty squares and inset rings on occupied squares. Bughouse drops use the same `legalMoveSquares` API. Tile colours are composited before painting without tile-edge antialiasing, avoiding seams at fractional sizes; square feedback never changes board layout or its permanent outer frame. The painter snapshots input sets and compares their contents for repainting. Pieces are `Positioned` on their squares with no implicit animation, so a layout resize (expanding a chapter list, dragging a panel) cannot slide them. Annotation types live in `lib/models/board_annotation.dart`. |
| `clickable_move_line.dart` | SAN line with tap + hover callbacks |
| `layout/jobs_panel.dart` | Jobs tab: single rich card per active generation or audit job (name, build mode config summary, phase icon/label, C-style live stats, thread/hash chips, linear progress, elapsed, pause/resume/cancel/finish-now); completed jobs as compact list tiles |
| `services/jobs/generation_job_display.dart` | Phase labels, stats-line formatting, and progress fraction helpers for generation job cards |
| `analysis/stockfish_settings_dialog.dart` | Shared Analysis controls reached by every `InlineEngineSettings` shortcut; board and bulk depths persist independently. |
| `analysis_download_dialog.dart` | Download games for analysis: site, username, range (months or last N games) and time controls. Given a saved `player`, site and username are fixed and it pops that player with the new range — the refresh button beside "downloaded … ago" in Player Analysis and "Change range…" on the picker both use it |
| `game_analysis_chart.dart` | Eval chart for game review |
| `game_nav_item.dart` | `GameNavItem` — label, study rating/summary, PGN `headers` for nav bar and search dialog; `fromEntry(PgnGameEntry)` |
| `game_number_field.dart` | **Game N of Total** jump box: the counter *is* the input (digits only, Enter jumps, Escape restores, `G` focuses). Search-by-name stays on the Search button so the current position stays visible while you type |
| `game_nav_bar.dart` | Previous/next game, editable game number (`G`), and Search (`/`). Search opens the chapter/event/game browser; the counter only supports direct number entry. Optional playback uses a labelled Play/Pause button; solitaire hides browsing. |
| `game_search_dialog.dart` | Responsive Browse Games dialog with chapter/event cards, scoped text search, All games, numeric jump, Enter selection and Escape dismissal; shared by game navigation and the opening-tree games list. Grouping lives in `game_chapter_dialog.dart`. |
| `games_list_widget.dart` | Selectable games list |
| `fullscreen_game_view.dart` | Fullscreen game + board view |
| `fen_list_widget.dart` | Ranked positions list of Player Analysis. The Bad/Good Eval sorts are always offered; picked before any engine pass, the empty state explains and carries the **Analyze with engine…** button (`onAnalyzeWithEngine`) |
| `pgn_with_engine.dart` | PGN pane with inline engine bar |
| `pgn_viewer_widget.dart` | Game list + board for viewer; `_variationsByPly` holds mainline + **multiple ephemeral RAVs** per branch point (`addEphemeralMove` / `clearEphemeralMoves`); movetext via `PgnMovetextView` (theme-resolved `PgnTextStyles`, comments/variations on own rows; reading column capped at 900 logical pixels with 24–32 pixel side insets, prose capped at 640 pixels for readability); larger branch chips + Return-to-mainline + nav icons; **Edit mode** (`editMode` prop): NAG inline display, annotation panel, right-click context menu with promote/delete gated by `protectOriginal`; `_toggleNag` modifies `PgnNodeData.nags` and persists via `buildGameMovetext` |
| `chess_core/pgn/pgn_analysis_variations.dart` | Converts classified legacy/new engine PVs to standard RAVs, reuses existing branches, and synchronizes the `[%bestline]` display reference after edits; shared by full review, tactics annotation and viewer loading. |
| `pgn/pgn_movetext_view.dart` | Mainline + sideline + comment rendering; analyzed games annotate every classified move for both sides (Interesting, Inaccuracy, Mistake, Blunder), including short games and scores mixed with prose, using the graph’s shared classifier; move suffixes show `!?`, `?!`, `?`, or `??` even for older cached games. Full review and tactics analysis also save these as standard PGN NAGs, preserving existing author glyphs and positional annotations; verdicts and their saved RAVs share an inset block with a left rule and extra space before play resumes; those same nodes handle navigation and edits, with no duplicated preview line. Uses `PgnTextStyles` (comments upright, not italic). ChessBase/Chessable **null moves** (`--` / `Z0`) are hidden in the SAN but still pass the turn. Chessable intro dummies are promoted to the mainline before render, so `1. Z0 (1. d4 Z0 2. Nf3 …)` shows the lesson text on the spine |
| `pgn/pgn_opening_tree_panel.dart` | Opening-tree side panel (replaces Game/Analysis + nav bar). Resizable split between `OpeningTreeWidget` and `PgnTreeGamesList`. While the tree is open, `/` searches the games-at-position list (not the full file) and picking a row/`G` number calls `loadGameFromTree` |
| `pgn/pgn_tree_games_list.dart` | Games at the tree cursor: `GameNumberField` + `GameSearchButton` + **Show moves** checkbox. Default expanded rows show title + truncated comment-free mainline PV from this FEN (`mainlineSansAfterFen`). With Show moves off, the blue play arrow previews one line and the title opens the game |
| `pgn_import_dialog.dart` | Compact PGN import `AlertDialog` — file picker pill + paste textarea with live line count via `countPgnGames`; used for repertoire append and create-with-PGN flows. Multi-source contexts use `PgnSourcesPanel` instead |
| `pgn_sources_panel.dart` | **Compact multi-source PGN attachment panel** — replaces the oversized import dialog; supports multiple PGN files/pastes, per-source slicing via `InlineSliceEditor`, embedded `LinesPreviewPanel` |
| `pgn_inline_slice_editor.dart` | **Inline slice editor** — "All Lines" / "Slice" radio + position/header/sequence filters + match count via `computeSliceMatches` + preview panel; accepts optional `fenIndex` for instant position lookups; used inside `PgnSourcesPanel` per source |
| `lines_preview_panel.dart` | **Browseable line list** — literal substring search, virtualized scrolling, `HoverableMoveChips` per row with `FloatingBoardPreview` on hover; shows full-panel loading spinner while `computing` (replaces stale count + list); used in collection search and inline slice editor |
| `hoverable_move_chips.dart` | **Inline move chips with hover board preview** — renders SAN moves as compact chips, computes FEN on hover, triggers `BoardPreviewController.setPreview`; shared by `LinesPreviewPanel`, `LineItemRow`, PGN Viewer |
| `slice/position_filter.dart` | Shared position filter widget (FEN/SAN input, clear and optional current-board shortcut); hovering the input shows a board through `PositionHoverPreview`, without an eye icon or success checkmark |
| `slice/header_filters.dart` | Reusable Field / Rule / Value table, stacked at narrow widths. Distinct collection headers suggest names/events with game counts; typing uses literal case-insensitive matching and selecting a suggestion sets the visible rule to exact. Presets are ordinary editable rows; shared by collection search and inline import filters |
| `slice/sequence_filter.dart` | Shared move sequence filter widget ([gap]-separated groups) |
| `pgn/pgn_game_filter_workspace.dart` | **Filter** workspace tab opened from **Actions → Filter games**, beside the board with the shared app theme. Compact named filter buttons focus newly added values; player fields reject multiple semicolon-separated names. Board position stays expanded and accepts FEN/moves, current-board capture and an embedded board editor. Move sequence is collapsible. Draft conditions and results survive tab switches; a changed collection starts a fresh draft from saved filters. Exact position search includes side to move, castling and en passant (mainline and variations). Live results use `LinesPreviewPanel`; Show games or a result click applies the draft and returns to Game. Debounces by 300ms and hides stale results; invalid input and unfinished board setup block applying. Optional `fenIndex` accelerates matching. |
| `position_preview_icon.dart` | **Shared hover-preview widget** — eye icon that shows a floating 200×200 board overlay on hover via `bestEffortPositionFromInput`; supports FEN, SAN, and `[gap]`-separated sequences; used by `PositionFilter` |
| `position_analysis_widget.dart` | Player analysis: Positions/Holes list, board, and Move Tree/Games/Try moves tabs. Games opens its reader inline with Back to games. |
| `engine_weakness_dialog.dart` | Engine-analysis setup (depth, min games, thresholds, workers); reached from the positions list's eval-sort empty state or the kebab. Re-downloading games is no longer part of it — that is the subtitle refresh button |
| `lichess_db_info_icon.dart` | Lichess DB info + OAuth entry point |
| `features/tactics/widgets/tactics_control_panel.dart` | Tactics mode shell; warms Maia on page load but leaves Stockfish lazy so an idle home screen holds no engine processes; PGN tab builds a synthetic PGN from the tactic FEN + **trainable line** (`correctLine`) as the **mainline** (`_buildSolutionPgn`) — correct user moves and opponent replies advance through the mainline via `goForward()`; FEN comparison in `onPositionChanged` prevents double-updates; Show Solution midway through a multi-move tactic navigates to current position via `_navigateToSolutionIndex` instead of jumping to end; keyboard commands come from `AppShortcut` through `BoardKeyboardScope`; Space reveals the solution, arrows navigate, Escape leaves the editor/tab/session in order; move letters take precedence while move entry is enabled |
| `features/tactics/widgets/tactics_training_panel.dart` | Puzzle UI; the three buttons keep fixed homes (Show Solution's slot empties but holds its width once solved, Analyze never turns into anything else, Reset is an icon button disabled at the puzzle position); Skip reads Next once an attempt has been scored, not only once solved; the "You played h5 (blunder)" line is a caption with no full stop; **played-moves trail** shows numbered SAN for moves completed so far in multi-move tactics; **Show Solution** = numbered SAN line + highlight; midway Show Solution navigates to current position (not end); star rating after solve/reveal |
| `features/tactics/widgets/tactics_browse_panel.dart` | Puzzle browser with full filter/sort toolbar: **Mistake-type chips** (toggle `??` blunders, `?` mistakes, `?!` inaccuracies independently), **Status filter** (All / New / Struggling < 50% success), **Min-rating popup** (Any / 2★+ / 3★+ …), **Sort chips** (Newest / Oldest / Worst success / Least reviewed); **Multi-select mode** (checklist icon → checkboxes on rows, Select All, batch Delete with confirmation); per-row: tappable 5-star rating, 1-star rows dimmed; count shows "visible / total tactics" |
| `features/tactics/widgets/tactics_import_panel.dart` | Import tactics from Lichess/Chess.com; **fetch mode toggle** (Recent N games / Since date) with segmented button; date picker for since-date mode; **auto-fetch on startup** checkbox with last-synced label; **Session Settings** dialog (order, mistake-type filter, 1-star toggle) opened from toolbar button beside Browse Tactics; live matching count on Start Session |
| `features/tactics/widgets/puzzle_stats_display.dart` | Puzzle statistics display |
| `training/training_*.dart` | Training panels (progress, results, settings, board controls, repertoire selector); **PGN-style lessons** reveal played moves and introductory prose through `PgnMovetextView`, with a compact fixed **Next button** (Space shortcut); recall mode hides explanations except on mistakes; `MoveInputWidget` below board accepts SAN/UCI text input and auto-submits on a unique legal-move match; `BoardKeyboardScope` shares typing and navigation behavior across trainers |
| `board_keyboard_scope.dart` | Shared `FocusScope` around Study, Repertoire Trainer and both Tactics panes. Uses the screen's `KeyBinding` list from the `AppShortcut` registry. With an enabled move field, SAN/UCI characters focus it and insert the first character once; normal Flutter text input handles the rest. Other editors retain typing, dialogs retain focus, hidden modes cannot capture keys, and field blur returns to this scope. Empty move fields forward navigation/repeats; partial moves retain left/right caret editing; Tab/Shift+Tab traverse and Escape clears/blurs. `MoveInputWidget` inherits navigation bindings, disables desktop select-all-on-focus, and never steals focus when enabled after an opponent reply. |
| `study/study_board_pane.dart` | Study board + SAN input; board-shape helpers (`applyStudyBoardShape`) |
| `study/study_side_pane.dart` | Engine bar + compact chapter bar + PGN editor; compact and sidebar chapter menus retain their chapter key across selection/reordering and ignore removed targets. One plain `onChapterAction` callback dispatches to the screen’s existing dialogs; shared `studyChapterMenuItems` builds the entries without a callback-holder object. Shared borderless move selection/hover and neutral Notes field with no move-specific placeholder. |
| `pgn/add_to_study_dialog.dart` | Shared destination picker for adding lines and games: an always-visible Add new study button opens a dedicated name prompt with a suggested unused name and duplicate validation; search and Enter select existing studies only. |
| `study/study_picker_bar.dart` | App-bar study switcher with an explicit Rename study pencil and inline name editing constrained to available title width. At the shared compact breakpoint, `StudySaveButton` uses a tooltip-labelled save/recovery icon (including its warning state) to leave room for the title controls; wide layouts retain the text label. |
| `study/study_chapter_sidebar.dart` | One searchable, reorderable chapter list for the persistent sidebar and modal manager. The sidebar adds New chapter and the full row menu; the manager keeps inline Edit/Delete, active-chapter status and Done. Row selection/actions resolve captured chapter keys; actions dispatch to the screen’s existing confirmation commands. Reorder rejects a changed list projection or disposed list. Filtered lists disable reorder; selecting stays in the manager. The former separate chapter-manager list and delete handler are retired. Shared list controls resolve the supplied theme and text scale; the overall Study mode retains its legacy dark boundary until its other controls migrate. |
| `study/study_name_dialog.dart` | Shared name prompt for studies and chapters |
| `features/opponents/` | `PlayersPrepScreen` is Library → Players & prep: persistent All players / Groups tabs, searchable groups and inline group sheets under the mode bar. Reuses `PeopleScreen`, `TournamentsScreen`, `TournamentScreen` and `PlayerTable` over `OpponentStore`; a `PersonRecord` carries `aliases` (searched and matched like the name), `fide_id`, and every key it does not model in `extra`, so the MCP tooling's `lookup` report survives an app save; no file migration or interactive engine. Selection, filters and group context survive mode changes, and game-set links refresh on return. `OpenPlayerAnalysis` delivers the selected corpus once to the canonical Analysis screen, including when it is already mounted. Study/train actions retain their existing handoffs. See [Players and groups](OPPONENT_PREP.md#in-the-app). |
| `opponent_list_import_dialog.dart` | Import an opponent-list JSON into Player Analysis |
| `settings/settings_widgets.dart` | Reusable settings tiles; Study exposes Engine (cores, memory, board depth, lines) and Display preferences. Maia/Expectimax move-table toggles remain with the analysis views that consume them |
| `eval_database_settings_panel.dart` | CdbDirect configuration and the download card: start / pause / resume / check / delete, live progress with rate and ETA, the data-directory picker with a **Show in file manager** button, and a collapsed "Download it yourself instead" section carrying the rsync command for the current snapshot. On non-Linux, shows that the dump reader is unavailable instead of hiding the section. |
| `lichess_eval_settings_panel.dart` | The Lichess evaluations card: download, progress through both stages, pause/resume, open folder, free the archive once the store is built, rebuild from a newer file. Separate from the ChessDB panel because that one is gated on the Linux-only native reader while this store is plain Dart |
| `lichess_eval_download_dialog.dart` | States the three numbers the download page does not: 21.7 GB to fetch, ~28 GB needed while building, ~5.9 GB kept. Measures drives against the peak rather than the download size |
| `storage_destination_picker.dart` | The shared "where should this go?" drive list: free space per volume, SSD / hard disk / network label, per-drive "X to spare" or "short by X", and the advisories. Used by both database downloads |
| `eval_database_download_dialog.dart` | Where the dump should go: the exact snapshot size and file count, every drive with free space and an SSD / hard disk / network label, "fits with X to spare" or "short by X" per drive, and blocking / advisory banners (no room, tight fit, spinning disk, network share). Defaults to the fastest drive that actually fits, and never pre-selects one that does not |
| `lichess_db_selector.dart` | Explorer source picker (Lichess / Masters, and TWIC when the caller has a local database) with speed/rating chips for Lichess and a classical-OTB-only chip for TWIC |
| `opening_explorer/opening_explorer_panel.dart` | The live explorer: filter header, source picker, move rows, Σ totals and — for a host that can open one — the games the source lists. Answers Lichess through `LiveExplorerService` and TWIC from the local book; says when TWIC's classical-only counts still need their index |
| `opening_explorer/explorer_games_list.dart` | The games under the table, lila's "top games": players, ratings, result, the move played, one row per game, click to open |
| `generation/eval_sources_section.dart` | Eval source picker in generation |

### `lib/utils/`

| File | Purpose |
|------|---------|
| `chess_utils.dart` | UCI/SAN helpers; `isNullMoveSan` / `playSanOrNullMove` treat ChessBase `--`, SCID `Z0`, UCI `0000`, and `@@@@` as a turn pass so same-side continuations stay legal |
| `san_display.dart` | `figurineSan` (`Nf3` → `♘f3`, promotion letter too, castling untouched) and `displaySan(context, san)`, the one place the piece-notation preference is applied; only at the pixel — storage, comparison, the move box and copied PGN keep the letter. Used by `ClickableMoveLineWidget`, `MoveChip`, `HoverableMoveChips`, `EngineMoveRow` and the tactics panel |
| `movetext_builder.dart` | Numbered PGN movetext; omits `--`/`Z0` from the text but still flips the turn so `1. d4 Z0 2. Nf3` serializes as `1. d4 2. Nf3` |
| `fen_utils.dart` | FEN manipulation; `isWhiteToMove(fen)` shared across eval providers, generation, and Maia |
| `best_effort_position.dart` | Best-effort board builder from FEN, SAN, or `[gap]`-separated move sequences; handles castling (O-O/O-O-O) by manually repositioning king+rook; produces a renderable `Position` even for illegal placements (used by `PositionPreviewIcon`) |
| `pgn_utils.dart` | PGN formatting, event title extraction |
| `pgn_comment_utils.dart` | The `[%tag …]` machine tokens (`parseEvalComment`, `setEvalInComment`, `commentProse` / `mergeCommentProse`), display filtering (`filterDisplayComment`, `stripEngineTokens`) and `buildGameMovetext`, the one serializer for a parsed game. |
| `move_metrics.dart` | `MoveMetrics`: reads a generated repertoire's per-move tokens back into plain-English labels. |
| `chessable_comment_format.dart` | Chessable rich-comment parser (`parseRichComment`, `hasChessableFormatting`). Handles `@@HeaderStart@@`, `@@StartBlockQuote@@`, `@@StartBracket@@`, `@@StartSquare@@`, `@@StartFEN@@`, `@@LinkStart@@` markers and double-space paragraph breaks. |
| `comment_move_tokens.dart` | `CommentToken` / `CommentMove` / `CommentDiagram` and `parseCommentTokens`, which recovers the double-spaced analysis lines and bare FENs book PGNs embed in comments; `prose_comment_parser.dart` does the same for single-spaced prose. |
| `piecewise_linear.dart` | `interpolatePiecewiseLinear` behind every anchor-table lookup (findability bars, Chess.com → Lichess Elo). |
| `coverage_helpers.dart` | Coverage UI helpers |
| `lines_filter_helpers.dart` | Line filter/sort/group (`filterSortAndGroupLines`, `getLineGroupName`); typed `LineSortBy` and `LineMetricsFilter` enums (replaces string sort/filter params) |
| `ease_utils.dart` | Ease display formatting |
| `eval_constants.dart` | Eval display thresholds |
| `chesscom_lichess_elo.dart` | Chess.com blitz → Lichess blitz Elo table + `chessComBlitzToLichessBlitz()` for Maia (tactics Chess.com import) |
| `log.dart` | `log.d/i/w/e` facade and `formatLogLine`; warnings and errors also go to the console and to `Log.sink` (the log file). See [Diagnostics log](#diagnostics-log) |
| `app_messages.dart` | Routine success notifications are silent. Snackbars are reserved for errors and explicitly flagged notices requiring attention. Adding to a study finishes quietly; explicit Edit in study opens the editor directly. |
| `keyboard_shortcut_utils.dart` | Shared `KeyBinding` dispatch, `isTextInputFocused()` and modifier guards, plus the SAN/UCI key classification used for move capture and move-safe navigation; shortcut chords and tooltip labels remain in `app_shortcuts.dart` |
| `file_text_reader.dart` | UTF-8 file read with Latin-1 fallback (`decodeTextBytes`, `decodeTextBytesDetailed`, sync/async helpers) for PGN / text imports |
| `system_info.dart` | CPU core count (native/stub) |

### `lib/theme/`

| File | Purpose |
|------|---------|
| `app_theme.dart` | Production dark theme, including Material 3 surface tiers. Menus, engine popovers and tooltips use raised charcoal surfaces with outlines; light text/icons remain readable through hover and focus. Shared by the app and contrast regression tests. |
| `app_colors.dart` | Dark theme palette, semantic colors; canonical `success`/`danger`/`warning` with eval/analysis aliases (`evalPositive`, `evalNegative`, `difficulty`). PGN movetext tokens (`pgnMove`, `pgnMoveNumber`, `pgnComment`, `pgnVariation`) are a near-white hierarchy — sidelines are distinguished by structure, not mint/teal hue. |
| `app_text_styles.dart` | Shared text roles (`body`, `muted`, `caption`, `mono`, `title`, …) built from `AppColors` / near-white ink. `forTheme(context, style)` adapts these roles to dark ink on light feature surfaces while retaining the dark palette. Wired into `ThemeData.textTheme` in `app_theme.dart`. Prefer these over ad-hoc `Colors.grey` / hard-coded sizes. |
| `widgets/pgn/pgn_text_styles.dart` | Shared PGN domain typography resolves the active theme through required context. Move-state decorations use the same surface roles; NAG ink preserves hue and adjusts lightness for readable annotation and selection backgrounds. Ephemeral moves remain italic. The editor clears rendered row styles when inherited appearance changes, preserving its document index, cursor and comment draft. |

**Style convention:** migrated UI uses `design_system/` typography and resolved theme roles. `AppColors`, `AppTextStyles` and domain packs remain only for the named legacy owners in `scripts/legacy_theme_consumers.json`; do not introduce new consumers. The [UI guide](agents/ui.md) owns current conventions.

---

## Test coverage map

| Test file | Verifies |
|-----------|----------|
| `test/core/board_preview_controller_test.dart` | Preview debounce, clear |
| `test/core/generation_session_controller_test.dart` | Engine-free surface of `GenerationSessionController`: initial state, `onTreeBuilt`/`clearTree` bundle lifecycle, resume-mismatch refusal, `GenerationProgress` throttling, idle guards, dispose safety |
| `test/features/repertoires/repertoire_controller_test.dart` | Controller navigation (tree-path model), line sync, invariants |
| `test/core/viewer_opening_tree_test.dart` | PGN-viewer opening tree: re-enter restores the tree line after a game remount; first open syncs to current FEN; app-bar back only after a games-at-position click |
| `test/features/documents/controllers/viewer_game_controller_test.dart` | Viewer load/nav; Chessable dummy intro promoted onto the mainline |
| `test/core/pgn/pgn_dummy_mainline_test.dart` | `promoteNullMoveDummyMainline` splice + idempotence |
| `test/core/pgn/pgn_variation_extractor_test.dart` | Sideline extraction including Z0 passes (without dummy promotion) |
| `test/core/pgn_viewer_controller_test.dart` | Game index nav, close-file reset, tree-landing FEN cleared on nextGame |
| `test/models/move_tree_test.dart` | MoveTree: parse PGN, round-trip, addMove, navigation, variations, TreePath equality |
| `test/features/repertoires/repertoire_writer_test.dart` | Add move, PGN append |
| `test/features/repertoires/repertoire_writer_undo_test.dart` | Undo stack |
| `test/features/browse/candidate_service_test.dart` | Candidate merge/sort |
| `test/features/coverage/coverage_result_test.dart` | `CoverageResult.findNextGap` / `findBiggestGap` gap ordering |
| `test/features/traps/trap_index_service_test.dart` | FEN index, line traps |
| `test/features/traps/trap_navigation_buttons_test.dart` | Trap jump UI |
| `test/services/master_games/master_games_query_test.dart` | Browse filters, as clauses and against a real database |
| `test/services/master_games/classical_counts_test.dart` | The book's classical-only split: import, the classical-only view, the rebuild in one go and in chunks, cancellation, completeness |
| `test/services/explorer_game_opener_test.dart` | Explorer games into the collection: local and Lichess sources, the ply at the position, no duplicates |
| `test/widgets/opening_explorer/opening_explorer_panel_sources_test.dart` | The panel's games list and the TWIC source: opening a game, the classical filter, the index note, falling back without a database |
| `test/widgets/lichess_db_selector_test.dart` | The TWIC segment appears only when offered; its classical chip |
| `test/services/eval/lichess_eval_line_test.dart` | Lichess JSONL parsing: deepest eval, White-relative signs, move packing |
| `test/services/eval/lichess_eval_store_test.dart` | Import, sort, dedupe, resume, and lookup of the Lichess store |
| `test/services/eval/lichess_eval_controller_test.dart` | Download → import → enable, resume from a partial file, delete paths |
| `test/services/eval/lichess_eval_source_test.dart` | Size/date probe and its offline fallback |
| `test/services/eval/zstd_stream_test.dart` | Both zstd backends, and truncation detection |
| `test/features/holes/hole_hunt_config_test.dart` | `HoleHuntConfig` defaults/serialization, old two-pass keys ignored, snapshot round-trip |
| `test/features/holes/hole_finding_json_test.dart` | Hole and trick finding JSON round-trip; a retired finding type drops without losing the report |
| `test/features/holes/hole_hunt_service_test.dart` | The hunt against a scripted engine: walk shape, uncovered moves, refutations, ranking, the Maia gate, leaf discovery order and budget, one discovery feeding both the uncovered check and the candidate pool |
| `test/features/holes/hole_scoring_test.dart` | Sign conventions, candidate windowing, prescreen and probe selection |
| `test/features/holes/trick_probe_test.dart` | The probe pass against a stubbed tree builder: the net-gain gate and severity, the build config a probe asks for, budget and reach order, cancellation and a failing build |
| `test/features/holes/exploit_ranking_test.dart` | Exploit-score ranking, top-by-reach target selection |
| `test/features/holes/hole_walk_probability_test.dart` | Reach-probability propagation in the attacker walk |
| `test/features/audit/repertoire_walk_test.dart` | The shared BFS: visit order and paths, ply limit, progress cadence, attenuation for either side, cancel and pause |
| `test/features/audit/engine_position_probe_test.dart` | SAN-resolved discovery, line → cache → engine eval fallback with hit/miss counts, White-normalised verification |
| `test/features/audit/missing_reply_finder_test.dart` | Engine, ChessDB and clash sources on their own, source precedence, transposition flag, dead-end continuation counting |
| `test/features/holes/holes_report_panel_test.dart` | The report panel: empty state, filter chips surviving a rebuild, status row, nav-controller stepping |
| `test/features/engine_tournament/engine_game_runner_test.dart` | The arbiter, against scripted engines: mate, threefold, fifty-move, draw/resign adjudication, move ceiling, illegal move, engine death, per-move and clock forfeits, PGN numbering from a FEN start |
| `test/features/engine_tournament/crosstable_builder_test.dart` | Points from both sides, head-to-head order, SB tiebreak, Elo/LOS edge cases |
| `test/features/engine_tournament/tournament_summary_test.dart` | History-rail wording: match score and leader, level match, field leader while running, self-match name numbering, day grouping and run duration |
| `test/features/engine_tournament/tournament_schedule_test.dart` | Colour alternation, round-major order, round robin vs gauntlet |
| `test/features/engine_tournament/tournament_store_test.dart` | Slug allocation, JSON round trip, corrupt-file tolerance, and that `games.pgn` reparses as the viewer's collection |
| `test/features/engine_tournament/engine_verification_test.dart` | Real-process gate: missing/dir/non-executable, silent binary, UCI-but-illegal-move, and a passing toy engine |
| `test/features/engine_tournament/time_control_test.dart` | Labels, PGN `TimeControl` tags, hang-guard ceilings, JSON round trip |
| `test/features/engine_tournament/uci_score_test.dart` | Mate-to-centipawn collapsing (including `mate 0`), no-move answers, `go` command spelling |
| `test/features/engine_tournament/crosstable_view_test.dart` | Crosstable and games-table rendering, empty states, row click carries the game index |
| `test/features/engine_tournament/engine_tournament_screen_test.dart` | Screen boots empty and populated, a games-row click hands the viewer the match PGN parked on that game, and an `OpenEngineTournament` handoff selects the named tournament (or leaves the screen intact and says so when it is gone); the history rail's score line and its filter |
| `test/features/engine_tournament/tournament_open_request_test.dart` | The request file the MCP side writes and the app consumes: round trip, read-and-clear, malformed and stale requests, and the watcher's already-waiting / written-live / stopped paths |
| `test/features/engine_tournament/engine_registry_test.dart` | Bundled-first ordering, bundled settings persisted without its path, update/remove, corrupt-file tolerance |
| `test/features/eval_tree/tree_serialization_eval_tree_test.dart` | Tree JSON round-trip |
| `test/models/opening_tree_test.dart` | Opening tree mutations; `updateStats(null)` frequency without WDL; one-ply transposition (1.d4 c5 2.e3 shows Nf6 when the book is 1.d4 Nf6 2.e3 c5) |
| `test/models/pgn_game_entry_test.dart` | Course `"Chapter — Line"` labels vs player `"White vs Black"` |
| `test/models/repertoire_metadata_test.dart` | `RepertoireMetadata` parsing, equality, `fromMap`/`toMap` |
| `test/models/engine_settings_test.dart` | Settings persistence |
| `test/services/coherence_service_test.dart` | Coherence compute |
| `test/services/engine_lifecycle_test.dart` | State transitions, notify-count guards, full lifecycle cycle |
| `test/services/engine/stockfish_bundle_test.dart` | Host lock key + largest-member extract from zip/tar |
| `test/services/expectimax_line_service_test.dart` | Line following / MultiPV |
| `test/services/fp_growth_test.dart` | FP-Growth mining |
| `test/services/generation/tree_my_ease_test.dart` | myEase computation |
| `test/services/generation/repertoire_selector_test.dart` | Expectimax/engine selection, idempotent marking |
| `test/services/pgn_parsing_service_test.dart` | PGN parsing; `mainlineSansAfterFen` remaining SAN |
| `test/services/repertoire_service_test.dart` | Repertoire I/O |
| `test/services/trap_extractor_test.dart` | Trap extraction |
| `test/features/tactics/controllers/tactics_session_controller_test.dart` | Tactics session |
| `test/services/training/training_session_controller_test.dart` | Repertoire trainer: `loadRepertoire` happy/error paths, due-queue ordering, `setIdle`, `isCorrectUserMove` SAN/UCI edge cases, drill/learn/replay phase transitions, session statistics, move-progress streaks, dispose safety (in-memory service fakes) |
| `test/features/tactics/services/tactics_engine_test.dart` | `checkMoveAtIndex`, SAN normalization, mate-in-1 from mid-game FEN; `buildTrainableLine` fallback + Maia agree/disagree/low-confidence paths with mock evaluator |
| `test/services/eval/test_*.dart` | Eval provider chain (helpers) |
| `test/widgets/position_analysis_widget_test.dart` | Analysis widget |
| `test/widgets/pgn_tree_games_list_test.dart` | Opening-tree games list: expanded PV, expand-all off preview vs open |
| `test/screens/main_screen_test.dart` | Main screen smoke |
| `test/widget_test.dart` | App smoke |
| `test/utils/lines_filter_helpers_test.dart` | `filterSortAndGroupLines`, `LineSortBy`/`LineMetricsFilter`, grouping, sort invariants |
| `test/utils/chesscom_lichess_elo_test.dart` | Chess.com→Lichess blitz anchor, interpolation, clamp |

**Gaps:** Few widget/integration tests for full `RepertoireScreen` layout, generate mode, or settings screen.

---

## External & non-Flutter components

| Path | Role |
|------|------|
| `tree_builder/` | C expectimax tree builder (`--eval-depth` default 14), CdbDirect reader; MultiPV line-0 PV reply stash + opponent injection (`engine_injected`, PGN `{engine-injected}`). **Build modes** (`--build-mode` in `tree.h`): `stockfish-expectimax` (default interleaved BFS), `maia-db-explore`, `db-explorer`, `trap-finder` (unimplemented). **SQLite cache** (`database.c`): explorer/eval/Maia/repertoire tables plus `build_metadata`. **`cli_args` persistence:** each run calls `save_config_to_db()` → `rdb_save_cli_config()` with the effective CLI as JSON (color, depth, build mode, PGN paths, eval sources, presets, etc.). **`--resume`:** `load_config_from_db()` in `main.c` restores from `cli_args`; `CliExplicit` records flags passed on the command line — saved values apply only for options *not* explicitly set (e.g. `--resume --threads 8` overrides stored thread count). Restores `-c` when omitted; DBs without `cli_args` fail with a clear error. **`build_now` is sticky:** `save_config_to_db()` persists it and `load_config_from_db()` re-applies it whenever the CLI passes neither `--build-now` nor `--skip-build` (`main.c` ~L564), so once a DB has seen one `--build-now`, every later `--resume` silently skips building. Pass the original flags explicitly instead of `--resume` if you need to alternate between scoring and building. **`--resume` skips** the legacy `check_build_metadata` color/ratings/speeds gate; without `--resume`, reopening an existing `.db` still **refuses** on mismatch (prints stored vs current settings and example `--resume` / fresh / `--input-db` commands). Legacy DBs with data but no metadata get a one-time note and recorded settings. **`--input-db` / `-I`:** copy eval/explorer cache tables (`evaluations`, `explorer_positions`/`explorer_moves`, `multipv_cache`, `maia_cache`) from another DB into a new/empty target via `rdb_import_cache_from` (ATTACH + INSERT OR IGNORE); not `repertoire_moves`. **Threads:** `-t` / `--threads` default is `default_thread_count()` — half of `_SC_NPROCESSORS_ONLN`, minimum 1 (not a fixed 4). **Build progress (TTY):** live line via `progress_line.c` — `[Depth N] X new + Y transpositions | total | rate/min | ~ETA`; depth-complete line uses unique node count at that ply (`g_nodes_created_at_depth`). **Tree resume** (stockfish-expectimax / maia-db-explore): if `<name>.tree.json` exists and `build_complete` is false, stage 1 continues BFS from unexplored frontier leaves (`resume_prepare_frontier` in `tree.c`); only `build_complete: true` skips building. SIGINT saves partial trees; nodes interrupted mid-expansion stay `explored: false` and are retried. **Engine pool:** Stockfish children call `setsid()` (Ctrl+C does not kill engines); `engine_pool_request_stop` from the signal handler sets `shutting_down` and wakes waiters so batch/single eval exits without spamming "all Stockfish engines are dead". `--build-now` / `--skip-build` still export without expanding. **DB explorer:** `--build-mode db-explorer --pgn <file>` (repeatable) → `pgn_freq.c` replays each game from the standard start position; when `--fen` or `--moves` defines a target, counting starts only after the canonical 4-field FEN matches (not SAN-prefix string matching). `--min-elo` (default 2100) skips games where both `[WhiteElo]` and `[BlackElo]` are present and below threshold; missing or partial Elo tags are kept. Games that never reach the target are skipped (aggregate log). Parallel per-file parse when multiple PGNs; binary cache `<name>.freq.bin` with manifest incl. `min_elo`, `--no-freq-cache` to force reparse; OOM aborts parse → `tree_build_from_freqmap` → deferred Stockfish pool start → `tree_enrich_evals` (project DB → external chain → Stockfish; abort if >50% nodes still unevaluated, else warn) → expectimax + PGN export. `fen_map_put` / PGN hash tables propagate resize OOM. Opponent `move_probability` = count/reach; our-move children = 1.0; `tree_recalculate_probabilities` chains cumulative probability. See `tree_builder/ALGORITHM.md`. |
| `python/twic-position-finder/` | TWIC Position Finder — the live site/API at `api.chessautoprep.com` (FastAPI + Astro frontend, weekly ingest cron, lesson booking). Dashboard lists matched games per TWIC issue with a Lichess link on each game. Independent of the Flutter app. |
| `tools/bughouse_web/` and `python/twic-position-finder/frontend/src/bughouse/` | Fully static `/bughouse` lab for Cloudflare Pages. Hivemind’s existing C++ rules and MCTS are compiled to WebAssembly; one browser worker runs that module and ONNX Runtime Web locally. Moves, cross-board reserves, promotion, dual FEN, Stop and calibrated joint suggestions require no API. Pinned model chunks stay below Pages’ 25 MiB per-file limit. [Build, hosting and verification](../tools/bughouse_web/README.md). |
| `tools/fetch_assets.py` | Stdlib fetch of the pinned engines: Stockfish (`sf_19`, universal CPU-dispatch binaries) into `assets/executables/*.gz` and the Hivemind bughouse bundle (`engine-v0.1.0`: engine, ONNX Runtime, FP32 network plus `manifest.json`) into `assets/bughouse/` (both gitignored). Default is **both engines, host OS/arch only**; `--only stockfish`, `--only bughouse` or a platform target narrows it, `--hivemind <checkout>` packs a local engine build. Linux/Windows CMake and macOS Assemble invoke it on configure; Release CI always `--only`s the job’s target. In-app fallback is `StockfishBundle` for Stockfish; a missing bughouse bundle hides Bughouse Lab. Checksums in `tools/assets.lock.json`. |
| `tools/mcp/chess_prep/` | Local MCP server (`python3 tools/mcp/chess_prep/__main__.py`). **Opponent prep** (zero extra deps): directory, USCF, roster, Swiss sim, `opponents_export`. **Players directory** (`names.py`, `people.py`, `player_lookup.py`: `player_lookup`, `people_populate`, `people_list` / `_get` / `_upsert` / `_confirm`; `master_player_search` in `master_games.py`): looks a person up in a fixed order (people.json, bundled directory, US Chess, OTB games by every spelling grouped by FIDE ID in TWIC and each broadcast collection under `Documents/lichess_broadcasts/`, a scored username probe on chess.com/Lichess) and writes the app's own `Documents/opponents/people.json` and group files; only trusted matches become downloadable accounts, the rest wait in the row's `lookup` block. **PGN opening tree** (`pgn_open` / `pgn_position` / `pgn_walk` / `pgn_eval` / `pgn_audit`): FEN-keyed graph so transpositions merge; needs `python-chess` (`pip install -r tools/mcp/requirements.txt`) and Stockfish for eval. **ChessDB** (`chessdb.py`: `chessdb_query`, and the reply-gap half of `pgn_audit`): chessdb.cn `queryall` over `urllib`, cached per position, fetch injectable; the one source that rates a move nobody plays. **Engine tournaments** (`tournament_run` / `_status` / `_list` / `_crosstable` / `_games` / `_game_pgn` / `_stop` / `_open` / `_engines` / `_add_engine`): starts a match from any FEN and opens the app on it. Needs the Flutter SDK's `dart` (`CHESS_PREP_DART` overrides) because it shells out to `tools/run_engine_tournament.dart` rather than re-implementing the chess or the standings maths. `tournament_run` returns as soon as the runner prints its `TOURNAMENT {…}` handshake line and leaves the games playing detached, recording the pid in `run.json` so `tournament_stop` can SIGINT it. **Expectimax runs** (`expectimax_run` / `_result` / `_status` / `_list` / `_stop` / `_resume`): builds a Maia+Stockfish expectimax tree via `tree_builder/` and returns the root ranking — every candidate with its practical win probability, its eval, and how much of the tree it got. Takes a move list or FEN; refuses a `color` that is not the side to move (a line ending on Black's move is White to move) rather than scoring the wrong side. `expectimax_result` can also include a cached root `engine_shortlist` for candidates not expanded in the tree. `prepare_toolchain()` rebuilds stale binaries lacking ONNX linkage and refuses a resulting binary without ONNX support; it compiles `tree_builder` on first use, unpacks `assets/executables/stockfish-*.gz`, and symlinks `libonnxruntime`/`libcurl` out of the pub cache and `/usr/lib64` into `CHESS_PREP_EXPECTIMAX_TOOLCHAIN` — Fedora ships neither `-devel` symlink. Runs are directories under `CHESS_PREP_EXPECTIMAX_DIR` (default `Documents/expectimax_runs`). Never passes `--resume` (see the `tree_builder/` row); it re-runs the `build_argv` stored in `run.json` instead, adding `--build-now` to score a partial tree. `_pid_alive` treats zombies as dead — the server is the builder's parent, so an unreaped child otherwise reads as running for ever. **chess.com account search** (`chesscom.py`: `chesscom_search` / `_search_status` / `_search_stop`, `chesscom_rating_on`, `chesscom_profile`, `chesscom_who_plays`): rebuilds rating history from cached monthly game archives (both sides' post-game ratings, so opponents count), indexes ratings and opening plies in SQLite under `CHESS_PREP_CHESSCOM_DIR`, and runs the search as a detached `python3 -m chess_prep.chesscom --job DIR` process with a request budget; fetch injectable. **chessgames.com collections** (`chessgames.py`: `chessgames_download` / `_status` / `_stop`): reads the collection page for game ids (or a browser-saved page when the WAF challenges), then a detached `python3 -m chess_prep.chessgames --job DIR` fetches `viewPGN/<gid>` one game per 22 s with back-off on soft bans, caching each game so reruns resume and rewriting `Documents/chessgames/<title>.pgn` in collection order. The server is registered for Claude Code in `.mcp.json` at the repo root. See [`OPPONENT_PREP.md`](OPPONENT_PREP.md). Tests: `python3 tools/mcp/test_chess_prep.py`, `python3 tools/mcp/test_people.py`, `python3 tools/mcp/test_chesscom.py`, `python3 tools/mcp/test_chessgames.py`, `python3 tools/mcp/test_opening_tree.py`, `python3 tools/mcp/test_chessdb.py`, `python3 tools/mcp/test_engine_tournament.py`, `python3 tools/mcp/test_expectimax.py`. |
| `packages/cdbdirect_flutter_libs/` | Native ChessDB bindings |
| `scripts/` | One-off data/analysis scripts (chess.com titled-player stats, USCF mapping, epub/pdf game extraction) |

---

## Audit gaps

Areas where behavior could not be fully determined without runtime testing:

1. **Maia native availability** — platform matrix for real vs stub inference.
2. **Cross-platform Stockfish** — first-launch extract from the bundled `.gz` is implemented (`process_connection.dart`); Release CI fetches the platform engine before `flutter build`. End-to-end extract on a clean Windows/macOS install is still a runtime check.
3. **Lichess OAuth** — full flow on all desktop platforms (callback server binding).
4. **Compact vs wide layout** — all breakpoint transitions and state preservation paths in `RepertoireScreen` (complex conditional tree).
5. **Training FSRS parameters** — exact scheduling algorithm vs documented FSRS.

**Recently closed:** generation cancel now UCI-stops in-flight evals (`StockfishPool.stopAll` + `forEachParallel` abort); dead workers are dropped and respawned up to the last `ensureWorkers` target. `loadRepertoire` is epoch-guarded like `StudyController.openStudy`. Board annotation types live in `lib/models/board_annotation.dart` so utils/services no longer import widgets. `FenMap` is frozen when published on `GeneratedRepertoire`. Transposition cycle checks share `isTranspositionCycle` / `enterFenPath` in `fen_map.dart`. Legacy engine settings persist through `EngineSettings._persist`; training uses the app-scoped serialized settings owner described above; eval cache writes from search pipelines use `EvalCache.putEvalCpWhiteSoon`. Training review headers are awaited after FSRS updates. `copyToClipboard` in `app_messages.dart` is the shared clipboard helper. `MainScreen` suspends the engine on `paused`/`hidden`/`detached` and on leaving interactive-engine modes (`AppMode.usesInteractiveEngine`); `resume` restores it on `resumed` and when re-entering those modes. Findings/report dismiss menus share `showAnchorMenu`. Single-file picks use `FilePicker.pickFile`; multi-file picks use `pickFiles` without deprecated `withData`/`withReadStream`/`allowMultiple`.

For planned work not yet in code, see **[`docs/FUTURE_FEATURES.md`](FUTURE_FEATURES.md)** (backlog only — do not treat as current behavior).
