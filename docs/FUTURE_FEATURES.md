# Future Features

**Backlog only — not current-state documentation.** For what exists today, see [`COMPONENT_MAP.md`](COMPONENT_MAP.md).

Consolidated list of planned or incomplete capabilities (from `tree_builder/TODO_cloud_evals.md` and gap analysis vs `lib/`). Many foundation pieces from earlier design docs are already shipped; this file lists what is **still missing or incomplete**, de-duplicated and ordered by priority.

**Legend**

| Status | Meaning |
|--------|---------|
| **Not started** | No meaningful implementation in `lib/` |
| **Partial** | Core exists; UX or edge cases remain |
| **Deferred** | Explicitly postponed or open product question |

---

## Architecture renewal and eventual replacement

**Status: Partial.** Parallel ownership work retires the old training service and
Viewer core hierarchies, separates Builder document lifecycle from its board,
and guards generated PGN publication with retained per-run output. Training now
has one app-scoped configuration writer and an explicit next-sitting policy;
durable sitting resume, tactics and shared UI adoption remain. Builder still needs private
opening-graph ownership, scratch recovery and full native undo provenance.
Stopped-profile cross-store restore has a Linux rehearsal; the bounded
20,000-node Study profile passes its command, frame-build and RSS budgets.
Generation's remaining derived caches, broader performance/restore coverage and
native platform gates remain open. These are completions within the full renewal.

The current-code save/undo safety prerequisite is
implemented and tested on Linux. The first replacement slice is partial:
repertoire catalog actions now use injected repository/controller boundaries
and the new hierarchy. Linux catalog creation now uses the typed native-identity
PGN store. Book selections have one typed settings owner and explicit failed
write/retry states. Linux folder rename has journaled training/book-reference
recovery. Linux journaled deletion and its Recovery/Restore UI now preserve
files and training/book references, including interrupted restore. New Linux
repertoires now publish complete staged chapter sets with verified manifests.
The migrated catalog now has English ARB localization, typed message presentation,
plural/date formatting and enlarged-label/text layout checks. Its theme and five
shared controls now live in `design_system/`, with light/dark Widgetbook cases
using production widgets and a guarded ledger of remaining legacy theme users.
The shared save session/status interaction now preserves drafts across conflicts,
reload and exclusive copies, with scripted catalog cases; repertoire creation
uses the shared status control and preserves input on a naming collision.
Persisted Dark/Light/System appearance now drives the app theme, with explicit
failure/retry feedback and retained navigation/drafts. Shared menu/breadcrumb and
chapter-picker colors adapt; fixed dark legacy interiors remain bounded until
migration. Study now adopts the shared typed save protocol, injected storage,
native Linux revisions, exclusive copies/exports and retained reload/restore drafts;
its controller/model and pure PGN text helpers have canonical feature/chess-core
paths. App-owned close coordination now covers Study, PGN Viewer and pending
repertoire line edits, preserving drafts if another owner cancels or changes.
Study now checkpoints current/retained drafts, their original file revision and
chapter/cursor/orientation, with startup review/restore and conflict-safe explicit
saving. Recovery excludes live instances and preserves unreadable records.
PGN Viewer collection edits now use an injected document-feature owner and native
Linux scoped game patches, with blocked failed autosaves and preserved recovery
copies. Its shared typed recovery UI now supports inspection, reload with draft
retention, restoration, exclusive pasted-collection Save As and PGN exports.
Failed recovery writes block replacement; exports leave the current source intact.
Viewer now has app-lifetime ownership and shared durable checkpoints/startup
discovery for current/retained drafts, original game text, uncertain writes and
game/mainline cursor/orientation. Close protection works before the reader opens.
Study now keeps its editable document private and publishes immutable cached
chapter/tree projections, with incremental local-edit updates, stable annotation
focus and detached prior revisions. The shared interactive editor now lazily
mounts variable-height move/comment rows, preserves inline drafts across eviction
and reveals distant selections without laying out every preceding row.
Production single-game PGN parsing now shares a guarded chess-core entry point;
long annotated lines avoid quadratic upstream copying, and move replay/fresh-ID
adoption handle deep lines iteratively. The native 20,000-node debug journey opens
in 1.3 seconds, with profile-mode memory/frame gates still pending.
Builder now has a pure feature-owned board/cursor controller that publishes
immutable cached move-tree views and detaches caller-owned trees at adoption.
The feature document controller coordinates notifications and injected storage;
its controller/writer and tests have moved out of `core/`. Draft undo receipts
are bound to the original board adoption, including equal-looking replacements.
Study and Builder share the projection cache; Builder autosaves
capture the current owner revision before UI rebuilds and retain their destination
across chapter changes. Viewer now detaches parsed input and exposes immutable
headers/mainline annotations with stable move identities; stale mainline editor
callbacks are rejected after game replacement. Serialization works on copies and
preserves variation introductions separately from trailing notes. Its variation forest
and cursor are now private in the document-feature game controller, with immutable
projections sharing untouched branches and refreshed focused-reader scopes. Pure
analysis/replay helpers have canonical chess-core paths, and the controller runs
without Flutter. Async loading now has an injected archive contract and a
request owner that rejects superseded reads/failures/callbacks. Nested annotation
adoption validates full stored topology, retains node identities and scratch
continuations, and updates prose/introductions/glyphs through shared projections.
Viewer now indexes and lazily renders mainline/variation rows through the shared
viewport, retaining reading anchors, branch bookmarks and evicted inline drafts.
20,000-ply mainline and sideline native journeys are covered; individual long
comments remain whole passages and full performance budgets remain pending.
Viewer reading checkpoints now have a pure ordered session owner and injected
preferences repository, with acknowledged-write deduplication, explicit failure/retry
and stale recent-file read protection. Existing preference keys and game identities
are preserved. This does not complete variation cursor, panel or whole-workspace
restoration. Collection read/decode requests now have a pure feature owner with
stale-result rejection and an injected isolate decoder; read-only library lookups
are also injected. Adoption rechecks manual edits made during file reads or paste
parsing. Accepted Viewer filters now have a pure owner with immutable snapshots,
latest-request acceptance, failed-query recovery and recomputation after in-place
source edits. The slice mixin is retired; matching predicates and worker scheduling
have separate chess-core/infrastructure homes. The full filter workspace injects
its matcher. Board orientation/fullscreen now have a pure presentation owner,
with injected native operations, serialized intent, failure/retry and app-lifetime
listener disposal. The last Viewer part/mixin is retired; perspective edits share
the collection save/recovery path and preserve drill-only annotations on screen.
Collection membership/order/selection now have one pure owner with fixed published
lists, atomic filter/navigation validation and deterministic sorting. External
list/index writes are retired; game entry contents still need private ownership.
Navigation now retains private collection edit ledgers, including screen-only
substitutions, original bytes and pending save outcomes; returning cannot silently
rebase a draft. Save Copy forks its destination baseline from the source context.
Durable navigation history and private game-entry values remain unfinished.
Legacy collection presentation/widget ownership, generation inline
filter wiring, remaining Builder session ownership and draft recovery, incremental editor indexing, undo receipts, variation-cursor/panel
restoration and complete large-document performance evidence remain pending.
Builder document reads/writes and decoding now use required injected contracts.
Linux writes use the shared native PGN store; pure chapter text, headers, IDs and
append receipts, course-header interpretation and variation expansion live in chess core.
Line authoring is now pure and no longer constructs a storage service.
Line saves retain acknowledged originals;
external target edits and reordered bulk deletions conflict. Remaining legacy
outline/generation editors, durable Builder recovery and native undo receipt
ownership still need migration.
Study now has independent cursor/metadata projections and scoped subscriptions;
metadata reads avoid tree materialization and ordinary annotation edits leave the
board/engine/sidebar unchanged. Its existing Provider bridge still needs retirement
with the broader presentation migration.
Other editors' persisted drafts, clean workspace/session restoration, archive
purging, builder-draft checks and job shutdown coordination are still pending.
Legacy unjournaled trash adoption, remaining settings/writers, transactional
splitting of existing chapters, remaining localization, legacy appearance migration/accessibility and full slice
gates remain unfinished in the old app. The rewrite now happens as a fresh app
in `lib/v2/`; its rules, PGN mutation contract, data-safety tests and order of
work live in [ARCHITECTURE_RENEWAL.md](ARCHITECTURE_RENEWAL.md). The old app is
frozen apart from data-loss, crash and release fixes. This file retains the
feature backlog; update step status there and feature status here.

---

## P0 — Foundation gaps (blocks polish / daily use)

### Engine lifecycle hardening

| Item | Status | Notes |
|------|--------|-------|
| Worker crash recovery | **Done** | Dead workers fail in-flight evals, leave the pool, and respawn up to the last `ensureWorkers` target. `EngineConnection.done` signals unexpected process exit. |
| App backgrounding (`paused` / `hidden`) | **Done** | `MainScreen` suspends on `paused`/`hidden`/`detached` (skips transient `inactive`); resumes on `resumed` when the current mode uses an interactive engine |
| Analysis presentation update coalescing (~200 ms trial) | **Not started** | Periodically publish latest snapshots before UI state; preserve terminal events and avoid continuous-stream debounce starvation. See [runtime-state contract](ARCHITECTURE_RENEWAL.md#engines-and-background-work). |
| Document / tab visibility awareness | **Not started** | Engine runs when user is not on engine-relevant panels |
| Default 1 worker for interactive analysis | **Deferred** | Still uses full `EngineSettings.workers` for interactive |
| Inline PGN viewer engine unified with lifecycle | **Deferred** | Spec recommends keeping separate; still a separate worker path |
| Integration perf tests (toggle ON/OFF timing, process count) | **Not started** | Unit tests exist; no automated process/RSS checks |
| `enterGeneration` / `exitGeneration` race safety | **Done** | Wrapped in `EngineLifecycle._serialExec` (June 2026 remediation) |

### Layout & navigation

| Item | Status | Notes |
|------|--------|-------|
| Preserve mode toolbar in material pickers | **Partial** | Player Analysis now embeds its picker. Repertoire library, Builder and Trainer now retain nested pickers/configuration beneath Actions / View / Settings. Route/input retention and deferred handoffs are implemented; full session restoration, deep links, branch memory/engine visibility and frame profiling remain under the [persistent-shell contract](ARCHITECTURE_RENEWAL.md#interface). |
| Bound simple lists and forms | **Partial** | Player Analysis caps its picker at 1040px; Settings and Databases already cap forms. Repertoire/chapter lists are capped at 920px and the library organizer at 1040px. `TournamentsScreen` group cards still fill the window; bound these, while retaining room for multi-column player tables and board workspaces. |
| Preserve navigation in planning workflows | **Partial** | Players & prep now keeps people and groups under a persistent mode bar. `BuildConfigScreen` and `PlanBuildScreen` still replace it with route-specific controls; planner boards/tables benefit from width, but question/review forms should have a readable cap. |
| My games UI within Tactics | **Not started** | Keep the workflow in Tactics; improve download status, catalog/filtering and opening-review navigation, reusing helpers with Viewer and Player analysis. |
| Contextual repertoire builds | **Partial** | Keep builds attached to a repertoire; make the output chapter explicit and improve planning/jobs/history in that context. |
| Audit follow-ups in Builder | **Partial** | Guarded run lifecycle, reliable partial resume, Priority/search and source warnings implemented. Still needed: saved-report staleness detection after line edits and explicit whole-repertoire chapter aggregation. Keep review beside the source lines and board. |
| Repertoire organization follow-ups | **Partial** | Standalone Repertoires and shared creation are implemented. Existing outline moves chapters into folders and reorders lines. Arbitrary sibling chapter ordering, cross-repertoire dragging and importing directly into an existing folder remain follow-ups. |
| Ultrawide four-zone layout (≥ 1600 px) | **Not started** | `kWideBreakpoint` exists; no fourth column |
| Draggable zone dividers | **Not started** | Fixed flex ratios only (`RepertoireLayout`). Trial a shared package-backed splitter with keyboard, minimum-size and restoration checks; see [panel contract](ARCHITECTURE_RENEWAL.md#interface). |
| Eval bar docked on board (Lichess-style) | **Not started** | Engine output lives in context panel / analysis dock, not under board |
| Dedicated **Expectimax toggle** on board toolbar | **Not started** | Existing position generation commands remain; the unused engine bolt widget did not implement this capability. |
| Repertoire keyboard shortcuts (`RepertoireShortcuts`) | **Done** | Letter shortcuts E/X/G/A/I/F/L/T/N/P/D with text-field guards; no digit bindings — see COMPONENT_MAP |
| Typed `RepertoireMetadata` (replace repertoire maps) | **Done** | `Map<String, dynamic>` replaced across selection, controller, storage, generation, training |
| Full unified keyboard shortcuts (all modes) | **Partial** | Letter shortcuts restored across repertoire, PGN viewer, tactics, training, audit findings; digit shortcuts remain removed; still missing global Tab |
| Remove legacy tab hybrid in Edit wide mode | **Partial** | Wide Edit still uses `RepertoireTabBar` (Browse + PGN tabs) while context is a separate zone |
| Status bar expectimax / coherence metrics | **Partial** | `RepertoireStatusBar` shows coverage, traps, lines, engine, tree nodes — not V% or coherence |

### Storage and update follow-ups

| Item | Status | Notes |
|------|--------|-------|
| Broader historical file fixtures | **Partial** | Frozen saved-games schema fixture, data-integrity and eval migrations are gated. Add fixtures whenever custom PGN/CSV/JSON formats change; no blanket compatibility promise. |
| One namespaced Documents root / relocatable data home | **Deferred** | Existing named folders and root-level legacy files remain addressable. A future move needs copy/verify/switch migration and external-path handling. |
| Windows bulk data outside roaming profiles | **Deferred** | Existing support databases use AppData/Roaming. New update payloads use local cache; moving old databases requires a separate migration. |
| OS credential vault | **Not started** | OAuth/PAT tokens currently use SharedPreferences. Use the [credential migration gate](ARCHITECTURE_RENEWAL.md#known-hard-problems) before migrating Accounts UI; verify native storage and preserve accounts across failures. |
| Additional auto-update formats and cleanup | **Partial** | Windows Setup, deb/rpm and marked Linux portable bundles supported. Flatpak/Windows ZIP/macOS use manual updates; install logs, downloaded releases and previous portable bundles need a retention UI. |
| Native update smoke matrix | **Partial** | Linux portable helper tests and Windows helper tests with disposable fake programs are gated. Test actual Windows Setup and Linux authorization/cancellation before publishing. |

### Diagnostics and error reporting

Warnings and errors already reach the console and `<support>/logs/app.log`, and
every red snackbar is logged with its message — see
[Diagnostics log](COMPONENT_MAP.md#diagnostics-log).

| Item | Status | Notes |
|------|--------|-------|
| Remaining `debugPrint` call sites | **Partial** | ~130 direct `debugPrint` calls in `lib/` bypass the log file; convert the ones that report a failure to `log.w` / `log.e` as their owning workflow is touched. |
| Caught failures shown only inline | **Partial** | Panels that set an `_error` string (player table, tournaments, study links) show the failure but do not log it. Log at the catch site so the file says what the screen said. |
| Copy or attach the log from the app | **Not started** | Settings opens the folder; a "copy diagnostics" action (log tail + version + OS, like the bughouse engine report) would make a bug report one click. |
| Retention beyond one rotation | **Deferred** | `app.log` + `app.log.1` at 512 KiB each is deliberate; per-session files or a longer history need a cleanup policy first. |

### Global settings completeness

| Item | Status | Notes |
|------|--------|-------|
| Shared settings repository | **Not started** | Persistence lives on `EngineSettings`, `EvalDatabaseSettings`, `TrainingSettings` separately. Migrate through one owner per key with typed sections, per-job effective settings and failure/restart tests; see [settings contract](ARCHITECTURE_RENEWAL.md#settings). |
| **Accounts** section (Lichess OAuth UI, disconnect, Chess.com username) | **Not started** | `LichessAuthService` exists; settings screen has no account panel (login via `LichessDbInfoIcon` elsewhere) |
| **Training** settings in global settings | **Not started** | Training settings only in trainer UI |
| **Display** settings (board theme, piece set, coordinates, default Edit/Analyze mode) | **Not started** | |
| Shared `AppTextStyles` + gradual UI token migration | **Partial** | `AppTextStyles` / `PgnTextStyles` + `ThemeData.textTheme` landed; many legacy `Colors.grey` / hard-coded `fontSize` call sites remain. Migrated components use [typed theme roles and retirement gates](ARCHITECTURE_RENEWAL.md#interface). |
| Stockfish binary path picker + validation | **Not started** | Auto-detect only |
| ChessDB.cn API quota display / toggle | **Not started** | |
| Queue engine setting changes during generation + toast | **Not started** | |
| CdbDirect path validation on settings open | **Partial** | Panel exists; spec-level startup warning flow not fully implemented |

---

## P1 — Core repertoire workflow

### Browse mode polish

| Item | Status | Notes |
|------|--------|-------|
| **Add as trainable line** | **Not started** | No `savePathAsTrainable`; no `[Trainable "1"]` PGN header |
| **Split as named line** | **Not started** | No `splitAsNamedLine` / `parentLineId` on `RepertoireLine` |
| **Next Gap / Biggest Gap** in browse nav bar | **Not started** | Gap buttons live in `LineMetricsPanel` (Lines tab); no dedicated browse navigation action |
| Inline **expectimax continuation** on candidate hover | **Not started** | Hover previews FEN only; no `ClickableMoveLineWidget` under row |
| **Coverage ring** per opponent candidate | **Not started** | The unused candidate chip implementation is retired; active explorer rows have no coverage ring |
| **W/D/B result bar** for opponent moves | **Done** | Active `ExplorerMoveRow` uses `WinDrawLossBar` with the local explorer's white/draw/black counts |
| Combined generated-evaluation and DB-frequency columns | **Deferred** | The old tree explorer is retired. Any combined view belongs to the current Builder database pane; no replacement graph is planned. |
| Entry: **Build manually** (empty repertoire, DB-only) | **Partial** | Empty repertoire creation and the active Database explorer are available; no dedicated entry CTA |
| Entry: **Browse Result** after generation | **Partial** | Tree loads; no explicit post-gen browse button |
| PGN editor persistence ownership | **Partial** | Builder controller/writer now use injected document contracts and the shared native PGN store on Linux; durable draft recovery, native undo receipts and remaining outline/generation editor callers are pending |
| Tree-path navigation (single source of truth) | **Done** | `MoveTree` + `TreePath` cursor privately owned by pure `RepertoireBoardController`; PGN editor is a pure view; no `addPostFrameCallback` sync; arrow keys always go through controller |

### Generation & bottom pane UX

| Item | Status | Notes |
|------|--------|-------|
| **Simplified generation config** | **Done** | Only Max Depth + Engine Depth visible by default; selection mode, thresholds, opponent model, PGN export under "Advanced settings" |
| **Friendlier mode names** | **Done** | "Expectimax (recommended)", "Quick Build (no engine)", "From Your Games (PGN database)" |
| **Trap detection info banner** | **Done** | Amber banner below build mode: "Traps are automatically detected after building" |
| **Inline config in Jobs tab** | **Done** | Generation and audit config show inline in Jobs tab (bottom pane), replacing floating dialogs |
| **Rich progress display** | **Done** | C-like stats: depth, nodes, rate (n/min), elapsed, ETA — monospace row in Jobs panel |
| **Finish Now button** | **Done** | Stops Phase 1 BFS, proceeds to Phase 2 on partial tree; controller `finishNow()`/`clearFinishNow()` |
| **Enriched job tiles** | **Done** | Status labels, type labels, subtree indicator, differentiated icons for completed/failed/cancelled |
| **Findings empty state** | **Done** | Descriptive text + "Start Audit" button |
| **Auto-switch to Lines tab** | **Done** | Tools column switches to Lines tab after generation completes |
| **Line probability display** | **Done** | Reach probability badge on each `LineItemRow` when `importance > 0` |
| Extract `GenerationConfigForm` from generation tab | **Done** | `lib/widgets/generation/generation_config_form.dart`; tab owns build orchestration only |
| Lines browser performance (debounce, lazy list) | **Done** | 300 ms search debounce, single `setState` filter reset, grouped `ListView.builder` in `LinesListPanel` |
| PGN editor move-widget memoization | **Done** | Bounded recent-row cache reused across cursor changes; only visible/prefetched rows mount. Tree edits rebuild the pure row index. |

### Expectimax lines & hover

| Item | Status | Notes |
|------|--------|-------|
| `ExpectimaxToggleButton` on board toolbar | **Not started** | Toggle via settings / analysis dock |
| **Shift+click** add full line to repertoire | **Not started** | Click navigates; no bulk add |
| **Ctrl+click** add-with-confirm for out-of-repertoire moves | **Not started** | |
| Inline move **annotations** on lines (prob %, ★ repertoire, ⚠ trap) | **Not started** | `MoveAnnotation` model not on `ClickableMoveLineWidget` |
| Side-by-side Engine + Expectimax panels | **Not started** | Builder exposes live Engine and generated evaluation reference tabs separately; the unreachable old dock is retired. |
| Hover preview on **all** move surfaces | **Partial** | Active engine/generated positions, traps, PGN trap dots and lines browser have previews; coverage of all PGN moves remains incomplete. Retired browse/suggestion/eval-tree widgets are not future targets. |
| Independent persist of expectimax panel toggle | **Partial** | `showExpectimaxDock` persisted; not spec’s toolbar toggle semantics |

### Trap UI

| Item | Status | Notes |
|------|--------|-------|
| **TrapsBrowser in tools column** | **Done** | Lines tab → Traps segmented view; rich rows with mini board, per-reply stats, classification badges, sort by Eval Drop/Most Common/Trap%/Surplus; filter: All Explored vs In Repertoire |
| **Opponent-mistake weight** | **Removed** | Shipped as `TreeBuildConfig.mistakeWeight`, then deleted: expectimax already values a line by how opponents play it, so the weight double-counted the effect — and it read a value computed in a later pass, so it tilted selection without tilting the values selection compared against. See `docs/ALGORITHM.md` §5b. |
| **Enriched trap tooltips in PGN** | **Done** | Multi-line tooltip: mistake description, popularity, reach probability, score |
| **Traps empty state** | **Done** | Prompts "Generate Repertoire" with button when no traps detected |
| Trap detail when **current position is a trap** (browse context) | **Partial** | Expanded trap list under candidates; not full card in context zone |
| Eval bar → tap trap indicator → detail | **Not started** | |
| Detail card actions: **Show Refutation**, **Train This Line** | **Partial** | Refutation move extracted and displayed in detail card + browse panel; interactive "Show Refutation" navigation and "Train This Line" not wired |
| Sort lines by **ETV** (expected trap value) | **Partial** | Trap count sort exists; ETV sort not exposed |

### Coverage suggestions

| Item | Status | Notes |
|------|--------|-------|
| **Accept all** suggestions | **Not started** | Per-row accept only |
| **Needs generation** row with focused mini-build | **Not started** | Unresolvable gaps omitted or empty |
| Target-unreachable messaging | **Partial** | Service logic exists; UI messaging may be minimal |

### My Ease / playability

| Item | Status | Notes |
|------|--------|-------|
| **Dream sort** (playability × opponent difficulty × expectimax × traps) | **Not started** | Individual sorts exist (`playability`, `hardestFirst`) |
| **Bottleneck ply** warning on hard lines | **Done** | Shown in trainer `_LineRow` + builder `_HardMoveWarning` when quality < 0.3 |
| Training review weighted by **inverse playability** | **Done** | `ReviewOrder.hardestFirst` sorts by ascending playability; trainer loads `tree.json` and computes per-line playability |
| On-demand `myEase` for manually added moves (Maia lookup) | **Not started** | Defaults to neutral when absent from tree |
| **"Needs scoring" banner** in trainer | **Done** | Shown when no `tree.json` exists; links to Builder for generation |

---

## P2 — Coherence & analytics

### FP-Growth coherence

| Item | Status | Notes |
|------|--------|-------|
| Lines browser **grouped by coherence cluster** | **Not started** | Groups by PGN event / first moves (`getLineGroupName`), not clusters |
| **Coherence** in status bar | **Not started** | |
| **Tradeoff sliders** (eval / ease / coherence) in generation | **Not started** | |
| Coherence-aware **generation selection** modifier | **Not started** | |
| Prominent **risk-line** warnings in lines list | **Partial** | Lines already display coherence scores with low-score coloring; explicit risk-line explanations remain open |
| FP-Growth off UI thread | **Done** | `CoherenceService.compute` runs mining in `Isolate.run` |
| **v2**: PrefixSpan sequence mining, FEN collapse, pawn-structure tags | **Deferred** | Explicitly future in spec |

---

## P3 — Platform, infra & other modes

### Tactics trainer

| Item | Status | Notes |
|------|--------|-------|
| Mate-in-1 positions shown / scored incorrectly | **Open bug** | "Position to next position" eval measurement suspected broken for last-move-of-game SF evaluations |
| Positions with many equivalent winning moves | **Open design** | No filtering strategy for "any move maintains eval" (e.g. opponent blunders in equal position -- almost any reply is good) |

### Tree builder / eval database (`tree_builder/TODO_cloud_evals.md`)

| Item | Status | Notes |
|------|--------|-------|
| Download & import Lichess **cloud eval JSONL** (~369M positions) | **Not started** | Separate from Flutter app; CdbDirect + SQLite chain exists |
| FEN normalization for Lichess EP convention | **Not started** | Lookup misses possible |
| MultiPV depth vs breadth tradeoff for cloud evals | **Not started** | Design open |
| PGN game filters for db-explorer (`--min-year`, avg Elo) | **Partial** | `--min-elo` implemented in both C and Flutter; year/avg-elo filters not yet added |
| Leaf **Best game** PGN annotation from source database | **Deferred** | Was db-seed export metadata; not in db-explorer pipeline |

### README / docs drift

| Item | Status | Notes |
|------|--------|-------|
| README reflects repertoire builder scope | **Partial** | Updated to point at `docs/COMPONENT_MAP.md`; expand feature list over time |
| `docs/ALGORITHM.md` file paths | **Partial** | Flutter-side paths; top-level doc links to `tree_builder/ALGORITHM.md` for C CLI |
| `docs/COMPONENT_MAP.md` reflects June 2026 remediation | **Done** | Typed metadata, API removals, new widgets, performance fixes documented |

---

## Cross-cutting open questions

These remain **undecided**; pick one before implementing dependent UI:

1. **Generated evaluations and database browsing** — Current Builder database sources share the board. The disconnected Browse and Eval Tree implementations are retired; any further consolidation applies to the current pane.
2. **Expectimax + Engine both ON** — Side-by-side vs tabbed on narrow screens. Current: tabbed dock.
3. **On-the-fly auto-compute** — Off by default (recommended). Not implemented.
4. **Engine toggle persist on restart** — Implemented (`engine_lifecycle.toggle_on`); verify product preference for first-install default.
5. **Hover preview on main board vs mini-board tooltip** — Main board chosen; mini-board not planned.

---

## Implementation priority

For the rewrite, follow the steps in
[Architecture renewal](ARCHITECTURE_RENEWAL.md#order-of-work).
For smaller maintenance tasks, choose from the incomplete entries above after
checking current code. The previous standalone priority list was removed
because it presented completed engine recovery work as unbuilt scope.

---

## Related reference docs (not backlog)

- `docs/COMPONENT_MAP.md` — current implementation
- `docs/ALGORITHM.md` — Flutter pipeline description
- `tree_builder/ALGORITHM.md` — C `tree_builder` CLI (db-explorer, expectimax)
- `docs/tree-display-architecture.md` — historical eval-tree graph performance lessons
- `tree_builder/TODO_cloud_evals.md` — infra backlog
