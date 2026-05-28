# Engineering Spec: Layout Redesign

**Status:** Draft  
**Feature:** Consolidate 8 tabs into a focused, multi-pane layout  
**Priority:** P0 — Structural change that improves every interaction  
**Depends on:** 001-engine-toggle-lifecycle (eval bar on board), 009-expectimax-lines-panel (hover preview, expectimax chip)  
**Estimated effort:** 2-3 weeks  

---

## Problem Statement

The current repertoire builder has **8 scrollable tabs** in a single panel:
Tree, Engine, PGN, Lines, Generate, Eval Tree, Traps, Actions.

Problems:
1. **Cognitive overload**: 8 tabs with no hierarchy. User doesn't know where to look.
2. **PGN and engine can't be seen simultaneously**: The most common workflow
   (browse position, see engine eval, edit PGN) requires constant tab switching.
3. **Tab switching breaks flow**: Arrow-key navigation behaves differently per tab.
4. **Generation locks everything**: Tab bar is disabled during generation — user
   can't even read their PGN or browse lines.
5. **No visual hierarchy**: All tabs look equally important (they're not).
6. **Dead weight**: Actions tab is rarely used; Generate is a one-time action.

---

## Design Goals

1. **PGN and engine/candidates visible simultaneously** in the primary workflow
2. **Two operational modes** (Edit and Analyze), not 8 tabs
3. **Generation is a background action**, not a UI state that locks everything
4. **Progressive disclosure**: show what matters now, hide the rest
5. **Consistent keyboard navigation** regardless of active panel
6. **Responsive**: works well from 900px to ultrawide

---

## Reference Patterns

| App | Layout | Key insight |
|-----|--------|-------------|
| Lichess Analysis | Board + notation (always) + engine bar (toggle) + explorer (collapsible) | Engine and PGN always visible together |
| En Croissant | Board + right panel (tabs: Analysis/Database/Practice/Annotate) | Fewer tabs, practice is a mode not a tab |
| ChessBase | Board + notation (docked) + reference tab (side) | Notation permanently visible |
| PGN Viewer (our app) | Board + 2 tabs (Game with inline engine, Analysis) | Simpler, engine above PGN |

**Common pattern**: Board is permanent. Notation/PGN is permanent or nearly so.
Engine output is a toggle or collapsible, not a full-screen tab.

---

## New Layout Architecture

### Wide Layout (≥ 1100px) — Three Zones

```
┌────────────────────────────────────────────────────────────────────────┐
│ AppBar: [title] [gen status chip] [mode: Edit|Analyze] [Train] [⚙]  │
├────────────────────┬─────────────────────┬─────────────────────────────┤
│                    │                     │                             │
│   ZONE A: Board    │   ZONE B: PGN      │   ZONE C: Context Panel    │
│   (40% width)      │   (30% width)      │   (30% width)              │
│                    │                     │                             │
│  ┌──────────────┐ │  Interactive PGN    │  [Edit mode]:               │
│  │              │ │  Editor (always     │   - Engine candidates       │
│  │   Chess      │ │  visible in edit    │   - OR Expectimax lines     │
│  │   Board      │ │  mode)             │   - OR Browse candidates    │
│  │  (supports   │ │                     │   - Opening tree (compact)  │
│  │  hover       │ │  With:              │                             │
│  │  preview)    │ │  - Inline markers   │  [Analyze mode]:            │
│  └──────────────┘ │  - Trap dots        │   - Coverage + gaps         │
│                    │  - Move numbers    │   - Lines browser           │
│  [⚡Engine] [🎯EX] │  - Comments        │   - Eval tree graph         │
│  [Flip] [Nav ←→]  │  - Hover preview   │   - Traps browser           │
│                    │                     │                             │
├────────────────────┴─────────────────────┴─────────────────────────────┤
│ Status bar: Coverage 67% │ 42 traps │ 156 lines │ Engine: d22 │ EX: V=62% │
└────────────────────────────────────────────────────────────────────────┘
```

### Compact Layout (< 1100px) — Stacked with Tabs

```
┌────────────────────────────────────────┐
│ AppBar                                 │
├────────────────────────────────────────┤
│                                        │
│         Board (40% height)             │
│         [toolbar below]                │
│                                        │
├────────────────────────────────────────┤
│ [PGN] [Context] ← 2 tabs only         │
├────────────────────────────────────────┤
│                                        │
│   Tab content (60% height)             │
│                                        │
└────────────────────────────────────────┘
```

In compact mode, the two-tab split replaces the 8-tab overload.
PGN tab shows the editor. Context tab shows the same context panel content.

### Ultrawide (≥ 1600px) — Four Zones

For users with ultrawide monitors, add a fourth zone:

```
│ Board (30%) │ PGN (25%) │ Engine/Browse (22%) │ Tree/Coverage (23%) │
```

Engine candidates and analysis results shown side-by-side with tree overview.

---

## Mode System

Replace 8 tabs with **2 modes** + **Generate as modal action**:

### Edit Mode (default)

**Purpose:** Build and refine repertoire manually.

| Zone | Content |
|------|---------|
| A (Board) | Chess board + toolbar (flip, nav, engine toggle, expectimax toggle, trap nav). Board supports hover preview overlay (spec 009). |
| B (PGN) | InteractivePgnEditor (always visible). Moves are hover-enabled: hovering a PGN move previews that position on the board. |
| C (Context) | Switchable: Engine candidates / Expectimax lines / Browse candidates / Opening tree |

Context panel sub-modes (togglable chips, not tabs):

| Chip | Content | When active |
|------|---------|-------------|
| Engine | UnifiedEnginePane with **clickable + hoverable** PV continuations (spec 009). Hover any move in a Stockfish line → board previews that position. Click → navigate. | Engine toggle ON |
| Expectimax | ExpectimaxLinesPane (spec 009) — precomputed lines from BuildTree displayed like engine MultiPV. Shows rank, V%, eval, hoverable SAN continuation. "Compute deeper" button for on-the-fly BFS. | Expectimax toggle ON or tree loaded |
| Browse | BrowsePanel from spec 002. Hovering a candidate previews the resulting position on the board. | When tree/DB available |
| Tree | OpeningTreeWidget (compact) | Always available |

### Analyze Mode

**Purpose:** Review generated data, find gaps, study traps.

| Zone | Content |
|------|---------|
| A (Board) | Chess board + toolbar |
| B (main) | Tabbed: Lines / Coverage / Traps |
| C (detail) | Eval Tree graph OR trap detail card OR line metrics |

Sub-tabs in Zone B (analyze):

| Tab | Content |
|-----|---------|
| Lines | RepertoireLinesBrowser (with trap badges, playability sort) |
| Coverage | Coverage results + gap navigation + suggestions panel |
| Traps | TrapsBrowser + trap walkthrough |

Zone C in analyze mode shows the detail view for whatever is selected in Zone B
(e.g., selecting a line shows its eval tree path; selecting a trap shows the
trap detail card).

### Generate (Modal Action)

**NOT a tab.** Triggered from:
- App bar button ("Generate" / "Resume")  
- Browse panel ("Generate tree for this position")
- Coverage panel ("Generate to fill gaps")

Shows a **modal overlay** (like current generation lock, but better):
- Takes over Zone C (context panel) with generation controls + progress
- Board dimmed but viewable (shows current build position)
- **Zone B (PGN) stays readable** — user can scroll their existing lines
- Cancel/Pause buttons prominent
- On completion: modal dismisses, returns to Edit mode, browse panel refreshes

---

## Widget Architecture

### New file: `lib/widgets/layout/repertoire_layout.dart`

```dart
/// Top-level layout orchestrator for the repertoire builder.
/// Manages zones, mode switching, and responsive breakpoints.
class RepertoireLayout extends StatefulWidget {
  final RepertoireController controller;
  final EvalTreeController? evalTreeController;
  final EngineLifecycle engineLifecycle;
  // ... other dependencies

  @override
  State<RepertoireLayout> createState() => _RepertoireLayoutState();
}

class _RepertoireLayoutState extends State<RepertoireLayout> {
  RepertoireMode _mode = RepertoireMode.edit;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= 1600) {
          return _buildUltrawideLayout();
        } else if (constraints.maxWidth >= 1100) {
          return _buildWideLayout();
        } else {
          return _buildCompactLayout();
        }
      },
    );
  }

  Widget _buildWideLayout() {
    return Row(
      children: [
        // Zone A: Board (flex 4)
        Expanded(flex: 4, child: _buildBoardZone()),
        const VerticalDivider(width: 1),
        // Zone B: PGN / Main content (flex 3)
        Expanded(flex: 3, child: _buildMainZone()),
        const VerticalDivider(width: 1),
        // Zone C: Context panel (flex 3)
        Expanded(flex: 3, child: _buildContextZone()),
      ],
    );
  }

  Widget _buildBoardZone() {
    return BoardZone(
      controller: widget.controller,
      engineLifecycle: widget.engineLifecycle,
      // Eval bar, toolbar, flip, nav all contained here
    );
  }

  Widget _buildMainZone() {
    switch (_mode) {
      case RepertoireMode.edit:
        return EditMainZone(controller: widget.controller);
      case RepertoireMode.analyze:
        return AnalyzeMainZone(controller: widget.controller);
    }
  }

  Widget _buildContextZone() {
    if (_isGenerating) {
      return GenerationPanel(...); // modal-in-panel during generation
    }
    switch (_mode) {
      case RepertoireMode.edit:
        return EditContextZone(...); // engine/browse/tree
      case RepertoireMode.analyze:
        return AnalyzeContextZone(...); // eval tree graph / trap detail
    }
  }
}
```

### New file: `lib/widgets/layout/board_zone.dart`

```dart
/// Board + toolbar + optional eval bar.
/// Self-contained: handles its own sizing, flip state, and toolbar.
/// Supports hover preview overlay via BoardPreviewController (spec 009).
class BoardZone extends StatelessWidget {
  final RepertoireController controller;
  final EngineLifecycle engineLifecycle;
  final BoardPreviewController boardPreview; // NEW (spec 009)

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Board with hover preview overlay
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Center(
              child: AspectRatio(
                aspectRatio: 1.0,
                child: ListenableBuilder(
                  listenable: boardPreview,
                  builder: (context, _) {
                    final displayFen =
                        boardPreview.previewFen ?? controller.fen;
                    final isPreview = boardPreview.isPreview;
                    return Stack(
                      children: [
                        Opacity(
                          opacity: isPreview ? 0.85 : 1.0,
                          child: ChessBoardWidget(
                            key: ValueKey(displayFen),
                            position: positionFromFen(displayFen),
                            onMove: isPreview ? null : handleMove,
                          ),
                        ),
                        if (isPreview)
                          Positioned(
                            top: 4, right: 4,
                            child: _PreviewBadge(),
                          ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ),
        // Toolbar: engine toggle, EXPECTIMAX toggle, flip, nav, trap nav
        BoardToolbar(
          engineLifecycle: engineLifecycle,
          engineToggle: EngineToggleButton(),           // spec 001
          expectimaxToggle: ExpectimaxToggleButton(),    // spec 009
          onFlip: ...,
          onBack: ...,
          onForward: ...,
          onNextTrap: ...,
          onPrevTrap: ...,
        ),
      ],
    );
  }
}
```

### New file: `lib/widgets/layout/edit_context_zone.dart`

```dart
/// Context panel in Edit mode.
/// Shows engine output, expectimax lines, browse candidates, or opening tree.
/// All move-displaying sub-views support hover preview (spec 009).
class EditContextZone extends StatefulWidget { ... }

class _EditContextZoneState extends State<EditContextZone> {
  EditContextView _view = EditContextView.browse;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // View switcher chips
        Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              _buildChip('Browse', EditContextView.browse),
              _buildChip('Engine', EditContextView.engine),
              _buildChip('Expectimax', EditContextView.expectimax),
              _buildChip('Tree', EditContextView.tree),
            ],
          ),
        ),
        const Divider(height: 1),
        // Content — all views wire BoardPreviewController for hover
        Expanded(
          child: switch (_view) {
            EditContextView.browse => BrowsePanel(
              boardPreview: widget.boardPreview,
              ...
            ),
            EditContextView.engine => CompactEnginePaneView(
              boardPreview: widget.boardPreview,
              // PV continuations now use ClickableMoveLineWidget
              // with hover callbacks (spec 009)
              ...
            ),
            EditContextView.expectimax => ExpectimaxLinesPane(
              fen: widget.controller.fen,
              tree: widget.tree,
              config: widget.config,
              boardPreview: widget.boardPreview,
              onMoveSelected: (san) => widget.controller.userPlayedMove(san),
              // On-the-fly BFS "Compute deeper" built-in (spec 009)
            ),
            EditContextView.tree => OpeningTreeWidget(...),
          },
        ),
      ],
    );
  }
}
```

---

## Migration Strategy (Incremental, Not Big-Bang)

### Phase 1: Extract zones as widgets (no layout change yet)

Create `BoardZone`, `EditMainZone`, `EditContextZone`, `AnalyzeMainZone`,
`AnalyzeContextZone` as new widgets that wrap existing content. The current
`repertoire_screen.dart` still uses the old 8-tab layout but delegates to these.

**Testable:** Each zone widget can be rendered in isolation.

### Phase 2: Add mode switcher (Edit/Analyze)

Add mode chips to the app bar. In Edit mode, show tabs 0-2 content. In Analyze
mode, show tabs 3-6 content. Tab 7 (Actions) absorbed into Settings screen.
Tab 4 (Generate) becomes modal.

**Result:** User sees 3-4 tabs max instead of 8, organized by intent.

### Phase 3: Three-zone layout (wide)

Replace the 50/50 `Row` with the 40/30/30 three-zone `Row`. PGN moves to Zone B
(always visible in edit mode). Engine/browse moves to Zone C.

**Result:** PGN + engine simultaneously visible. Core UX improvement.

### Phase 4: Compact layout (2 tabs)

Replace the 8-tab compact layout with 2 tabs (PGN / Context). Much less
overwhelming on smaller screens.

### Phase 5: Generation modal

Move Generate tab content into a modal overlay on Zone C. Remove generation lock
from board (just dim it). User can still read PGN and browse lines during generation.

---

## Zone Sizing Rationale

| Zone | Wide % | Why |
|------|--------|-----|
| Board | 40% | Needs to be large enough for comfortable play. 40% of 1440px = 576px → ~72px per square. Adequate. |
| PGN | 30% | Move notation is narrow text. 30% of 1440px = 432px. More than enough for variations + comments. |
| Context | 30% | Engine table / browse candidates are moderately wide. 432px fits 4-5 columns. |

At 1100px breakpoint: Board = 440px, PGN = 330px, Context = 330px. Still usable.

Below 1100px: switch to stacked (board top, tabbed bottom with 2 tabs).

---

## Keyboard Shortcuts (Unified)

With the new layout, keyboard behavior is consistent regardless of active zone:

| Shortcut | Action | Context |
|----------|--------|---------|
| ← / → | Navigate moves (back/forward in current line) | Always (unless in text field) |
| Shift+← / Shift+→ | Jump to prev/next trap in line | Always |
| F | Flip board | Always |
| E | Toggle engine | Always |
| X | Toggle expectimax lines (spec 009) | Always |
| Ctrl+Z | Undo last add (browse mode) | Edit mode |
| Tab | Cycle focus between zones | Always |
| 1 / 2 | Switch mode (Edit / Analyze) | Always |
| Ctrl+Shift+V | Paste FEN | Always |
| G | Open generate modal | Edit mode, not generating |

---

## What Gets Removed / Relocated

| Current | New location |
|---------|-------------|
| Tab 0 (Tree) | Edit context zone → "Tree" chip |
| Tab 1 (Engine) | Edit context zone → "Engine" chip (with clickable+hoverable PV lines, spec 009) |
| Tab 2 (PGN) | Zone B (always visible in edit mode) |
| Tab 3 (Lines) | Analyze mode → Lines tab |
| Tab 4 (Generate) | Modal action (app bar button + overlay) |
| Tab 5 (Eval Tree) | Analyze mode → context zone (graph). Tree data also feeds Expectimax Lines panel in Edit mode (spec 009). |
| Tab 6 (Traps) | Analyze mode → Traps tab |
| Tab 7 (Actions) | Global Settings screen (spec 004) |

---

## Edge Cases

### 1. Window resized across breakpoints

**Problem:** User resizes from wide to compact. Zone C content disappears.

**Solution:** When crossing 1100px threshold:
- Wide→Compact: Zone C content moves into the "Context" tab (second tab)
- Compact→Wide: Tab content splits back into zones
- Active selection preserved (if user was on engine chip, it stays selected)

### 2. Mode switch with unsaved PGN edits

**Problem:** User is editing PGN, switches to Analyze mode. PGN zone disappears.

**Solution:** PGN auto-saves on mode switch (debounced save fires immediately).
When returning to Edit mode, PGN editor restores to last position.

### 3. Generation in progress + mode switch

**Problem:** User is in Analyze mode, starts generation. Generation panel needs
to show somewhere.

**Solution:** Generation always shows in Zone C regardless of mode. A small
progress chip in the status bar indicates generation is running. Zone C content
is replaced by generation panel until done.

### 4. Hover preview across zones (spec 009)

**Problem:** User hovers a move in Zone C (engine/expectimax line). Board in
Zone A needs to show a preview. Hover exits mid-transition while crossing the
zone divider.

**Solution:** `BoardPreviewController` (spec 009) is shared across all zones
via `InheritedWidget`. Hover sets `previewFen`; mouse leave clears it. The
board reads `previewFen ?? controller.fen`. Crossing dividers naturally
triggers `onExit` on the source widget, clearing the preview. Board shows a
"Preview" badge and dims slightly (opacity 0.85) during preview. Piece
dragging is disabled while preview is active.

### 5. Very narrow window (< 900px)

**Problem:** Three zones don't fit, two-tab layout is too cramped.

**Solution:** Below 900px, use single-pane layout:
- Board fills width (landscape) or top (portrait)
- Single tab below with swipe gestures between PGN/Context
- Engine output as a collapsible bar above PGN (like PGN Viewer)

---

## Status Bar

New persistent bar at the bottom (outside the zone layout):

```dart
class RepertoireStatusBar extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      height: 28,
      padding: EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          // Coverage percentage
          Text('Coverage: 67%'),
          VerticalDivider(),
          // Trap count
          Text('42 traps'),
          VerticalDivider(),
          // Line count
          Text('156 lines'),
          Spacer(),
          // Engine status
          Text('Engine: depth 22/30'),
          // Or: "Engine: OFF"
          VerticalDivider(),
          // Expectimax status (spec 009)
          Text('Expectimax: V=62% depth 14'),
          // Or: "Expectimax: computing..." (on-the-fly BFS)
          // Or: "Expectimax: OFF"
          // Or: "Expectimax: no tree"
        ],
      ),
    );
  }
}
```

Provides at-a-glance repertoire health without taking space from main content.

---

## Testing Strategy

### Widget tests

| Test | Verifies |
|------|----------|
| Wide layout renders 3 zones | Correct flex ratios at 1440px |
| Compact layout renders 2 tabs | Correct at 900px |
| Mode switch preserves state | PGN position maintained |
| Generation modal shows in Zone C | Overlay doesn't block Zone B |
| Resize wide↔compact | Content migrates correctly |

### Integration tests

| Test | Verifies |
|------|----------|
| Edit mode: PGN + engine visible simultaneously | Both render, both update on nav |
| Hover engine PV move → board previews position | BoardPreviewController sets previewFen |
| Hover expectimax line move → board previews | Same hover system across both panels |
| Mouse leave Zone C → board restores | previewFen cleared, committed FEN shown |
| Engine + Expectimax both ON → both panels render | No resource contention |
| Analyze mode: select line → eval tree highlights path | Cross-zone communication |
| Generate → complete → browse mode shows tree | Modal dismissal + data refresh |
| Keyboard nav works across zones | Consistent ←/→ behavior |

### Performance targets

| Metric | Target |
|--------|--------|
| Mode switch latency | < 100ms (no teardown, just visibility toggle) |
| Zone resize (drag divider) | 60fps (no layout thrash) |
| Initial render (all zones) | < 500ms after repertoire load |

---

## Open Questions

1. **Resizable dividers between zones?** Recommend: yes for wide layout
   (draggable `VerticalDivider` with min/max constraints). Not for compact.

2. **Should Eval Tree graph be in Analyze or always available?**
   Recommend: Analyze mode only. It's a large visualization that fights with
   browse/engine for space.

3. **Status bar: always visible or collapsible?**
   Recommend: always visible (28px is negligible). Provides constant awareness.

4. **Engine + Expectimax chip: merge or separate?**
   Recommend: separate chips. Engine shows live Stockfish analysis; Expectimax
   shows precomputed practical lines. They serve different purposes and can
   be ON simultaneously. On wide/ultrawide, both can be visible side-by-side.

5. **Should hover preview show a mini-board tooltip instead of updating the
   main board?** Recommend: update the main board (Lichess pattern). Mini-board
   tooltips are harder to see and add rendering complexity. The main board is
   always visible in Zone A — use it.
