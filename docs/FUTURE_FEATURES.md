# Future Features

**Backlog only — not current-state documentation.** For what exists today, see [`COMPONENT_MAP.md`](COMPONENT_MAP.md).

Consolidated list of planned or incomplete capabilities (from `known-issues.md`, `tree_builder/TODO_cloud_evals.md`, and gap analysis vs `lib/`). Many foundation pieces from earlier design docs are already shipped; this file lists what is **still missing or incomplete**, de-duplicated and ordered by priority.

**Legend**

| Status | Meaning |
|--------|---------|
| **Not started** | No meaningful implementation in `lib/` |
| **Partial** | Core exists; UX or edge cases remain |
| **Deferred** | Explicitly postponed or open product question |

---

## P0 — Foundation gaps (blocks polish / daily use)

### Engine lifecycle hardening

| Item | Status | Notes |
|------|--------|-------|
| Worker crash recovery | **Not started** | No `onCrash` handler on pool workers; crashed worker can stay busy forever |
| App backgrounding (`paused` / `inactive`) | **Partial** | Only `detached` calls `EngineLifecycle().toggleOff()` in `MainScreen` |
| Analysis output debouncing (~200 ms) | **Not started** | Spec throttling for UI updates not wired |
| Document / tab visibility awareness | **Not started** | Engine runs when user is not on engine-relevant panels |
| Default 1 worker for interactive analysis | **Deferred** | Still uses full `EngineSettings.workers` for interactive |
| Inline PGN viewer engine unified with lifecycle | **Deferred** | Spec recommends keeping separate; still a separate worker path |
| Integration perf tests (toggle ON/OFF timing, process count) | **Not started** | Unit tests exist; no automated process/RSS checks |

### Layout & navigation

| Item | Status | Notes |
|------|--------|-------|
| Ultrawide four-zone layout (≥ 1600 px) | **Not started** | `kWideBreakpoint` exists; no fourth column |
| Draggable zone dividers | **Not started** | Fixed flex ratios only (`RepertoireLayout`) |
| Eval bar docked on board (Lichess-style) | **Not started** | Engine output lives in context panel / analysis dock, not under board |
| Dedicated **Expectimax toggle** on board toolbar | **Partial** | `EngineToggleButton` only; expectimax visibility via dock settings (`showExpectimaxDock`) |
| Full unified keyboard shortcuts | **Partial** | `Ctrl+Z` undo exists; missing `E`, `X`, `G`, `1`/`2`, `Tab`, `Shift+←/→` trap nav as global shortcuts |
| Remove legacy tab hybrid in Edit wide mode | **Partial** | Wide Edit still uses `RepertoireTabBar` (Browse + PGN tabs) while context is a separate zone |
| Status bar expectimax / coherence metrics | **Partial** | `RepertoireStatusBar` shows coverage, traps, lines, engine, tree nodes — not V% or coherence |

### Global settings completeness

| Item | Status | Notes |
|------|--------|-------|
| Central `SettingsService` | **Not started** | Persistence lives on `EngineSettings`, `EvalDatabaseSettings`, `TrainingSettings` separately |
| **Accounts** section (Lichess OAuth UI, disconnect, Chess.com username) | **Not started** | `LichessAuthService` exists; settings screen has no account panel (login via `LichessDbInfoIcon` elsewhere) |
| **Training** settings in global settings | **Not started** | Training settings only in trainer UI |
| **Display** settings (board theme, piece set, coordinates, default Edit/Analyze mode) | **Not started** | |
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
| **Next Gap / Biggest Gap** in browse nav bar | **Not started** | Gap buttons live in `LineMetricsPanel` (Lines tab), not `BrowsePanel` |
| Inline **expectimax continuation** on candidate hover | **Not started** | Hover previews FEN only; no `ClickableMoveLineWidget` under row |
| **Coverage ring** per opponent candidate | **Partial** | `coverageDelta` chip exists; no visual ring |
| **W/D/B result bar** for opponent moves | **Partial** | DB frequency/games shown; full win/draw/loss bar not in `CandidateRow` |
| `RepertoireTreeExplorer` DB frequency columns | **Not started** | Explorer shows engine metrics, not Lichess W/D/B |
| Entry: **Build manually** (empty repertoire, DB-only) | **Partial** | DB fallback in `CandidateService` works; no dedicated entry CTA |
| Entry: **Browse Result** after generation | **Partial** | Tree loads; no explicit post-gen browse button |
| PGN editor writes exclusively through `RepertoireWriter` | **Partial** | Browse/suggestions use writer; editor may still write directly |

### Expectimax lines & hover

| Item | Status | Notes |
|------|--------|-------|
| `ExpectimaxToggleButton` on board toolbar | **Not started** | Toggle via settings / analysis dock |
| **Shift+click** add full line to repertoire | **Not started** | Click navigates; no bulk add |
| **Ctrl+click** add-with-confirm for out-of-repertoire moves | **Not started** | |
| **Merge on-the-fly subtree** into main `BuildTree` | **Not started** | `OnTheFlyExpectimaxService` caches per-FEN only |
| Inline move **annotations** on lines (prob %, ★ repertoire, ⚠ trap) | **Not started** | `MoveAnnotation` model not on `ClickableMoveLineWidget` |
| Side-by-side Engine + Expectimax panels | **Partial** | `RepertoireAnalysisDock` tabs; not simultaneous split |
| Hover preview on **all** move surfaces | **Partial** | Engine, expectimax, browse, traps, suggestions, PGN trap dots — **not** eval-tree explorer rows, lines browser move text, all PGN moves |
| Auto on-the-fly when entering unexplored FEN | **Not started** | Manual compute only |
| Persist on-the-fly results to disk | **Not started** | Session cache only |
| Independent persist of expectimax panel toggle | **Partial** | `showExpectimaxDock` persisted; not spec’s toolbar toggle semantics |

### Trap UI

| Item | Status | Notes |
|------|--------|-------|
| Trap detail when **current position is a trap** (browse context) | **Partial** | Expanded trap list under candidates; not full card in context zone |
| Eval bar → tap trap indicator → detail | **Not started** | |
| **`T`** keyboard shortcut for trap detail | **Not started** | |
| Detail card actions: **Show Refutation**, **Train This Line** | **Not started** | Buttons stubbed or absent |
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
| **Dream sort** (playability × opponent difficulty × expectimax × traps) | **Not started** | Individual sorts exist (`playability`, `trappy`) |
| **Bottleneck ply** warning on hard lines | **Not started** | Computed in `LinePlayability` but not surfaced in UI |
| Training review weighted by **inverse playability** | **Not started** | |
| On-demand `myEase` for manually added moves (Maia lookup) | **Not started** | Defaults to neutral when absent from tree |

---

## P2 — Coherence & analytics

### FP-Growth coherence

| Item | Status | Notes |
|------|--------|-------|
| Lines browser **grouped by coherence cluster** | **Not started** | Groups by PGN event / first moves (`getLineGroupName`), not clusters |
| **Coherence** in status bar | **Not started** | |
| **Tradeoff sliders** (eval / ease / coherence) in generation | **Not started** | |
| Coherence-aware **generation selection** modifier | **Not started** | |
| Prominent **risk-line** warnings in lines list | **Partial** | `CoherencePanel` shows risk; not inline on every line row |
| **v2**: PrefixSpan sequence mining, FEN collapse, pawn-structure tags | **Deferred** | Explicitly future in spec |

---

## P3 — Platform, infra & other modes

### Tactics trainer (`known-issues.md`)

| Item | Status | Notes |
|------|--------|-------|
| Mate-in-1 positions shown / scored incorrectly | **Open bug** | Eval measurement for last-move positions suspected broken |
| Positions with many equivalent winning moves | **Open design** | No filtering strategy for “any move maintains eval” |

### Tree builder / eval database (`tree_builder/TODO_cloud_evals.md`)

| Item | Status | Notes |
|------|--------|-------|
| Download & import Lichess **cloud eval JSONL** (~369M positions) | **Not started** | Separate from Flutter app; CdbDirect + SQLite chain exists |
| FEN normalization for Lichess EP convention | **Not started** | Lookup misses possible |
| MultiPV depth vs breadth tradeoff for cloud evals | **Not started** | Design open |

### README / docs drift

| Item | Status | Notes |
|------|--------|-------|
| README reflects repertoire builder scope | **Partial** | Updated to point at `docs/COMPONENT_MAP.md`; expand feature list over time |
| `docs/ALGORITHM.md` file paths | **Partial** | References moved paths (`candidate_service` → `features/browse/`, etc.) |

---

## Cross-cutting open questions

These remain **undecided**; pick one before implementing dependent UI:

1. **Browse vs Eval Tree tab** — Coexist vs merge. Current: coexist via chips + eval tree in Analyze mode.
2. **Expectimax + Engine both ON** — Side-by-side vs tabbed on narrow screens. Current: tabbed dock.
3. **On-the-fly auto-compute** — Off by default (recommended). Not implemented.
4. **Engine toggle persist on restart** — Implemented (`engine_lifecycle.toggle_on`); verify product preference for first-install default.
5. **Hover preview on main board vs mini-board tooltip** — Main board chosen; mini-board not planned.

---

## Implementation priority (suggested)

1. **Engine crash recovery + background CPU** — stability
2. **Accounts + training in Settings** — discoverability
3. **Browse gap navigation + trainable lines** — completes manual prep loop
4. **Expectimax toolbar toggle + merge on-the-fly** — differentiator polish
5. **Cluster-grouped lines + dream sort** — repertoire quality insight
6. **Cloud eval import** — build-time speed (tree_builder scope)

---

## Related reference docs (not backlog)

- `docs/COMPONENT_MAP.md` — current implementation
- `docs/ALGORITHM.md` — pipeline description (update paths as needed)
- `docs/tree-display-architecture.md` — eval-tree graph performance principles
- `known-issues.md` — active bugs
- `tree_builder/TODO_cloud_evals.md` — infra backlog
