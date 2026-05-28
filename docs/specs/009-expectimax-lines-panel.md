# Engineering Spec: Expectimax Lines Panel, Hover Preview & On-the-Fly BFS

**Status:** Draft  
**Feature:** Engine-style expectimax line display, Lichess hover preview, incremental BFS  
**Priority:** P0 — The app's killer differentiator  
**Depends on:** 001-engine-toggle-lifecycle, 002-browse-mode, 003-layout-redesign  
**Estimated effort:** 3-4 weeks  

---

## Problem Statement

The app can build a precomputed expectimax tree with eval, ease, trap, and
probability data on every node — data that no other chess tool surfaces in a
user-friendly way. But today:

1. **No engine-like line display for expectimax.** The tree explorer shows a
   flat table of candidate rows at the current node. There is no "best line"
   continuation — the user sees metrics at one depth, not the most-likely
   N-ply future. Stockfish shows "1. e4 c5 2. Nf3 d6 3. d4 +0.32" — we should
   show "1. e4 c5 (41%) 2. Nf3 d6 (38%) 3. d4 V=62%" from precomputed data.

2. **No hover line preview.** Lichess lets you hover over any move in an engine
   PV and the board instantly shows that position. Hovering is the primary way
   users explore lines without committing. We have zero hover-to-board
   interaction anywhere — engine pane, eval tree, browse candidates, traps,
   coverage suggestions, or PGN moves.

3. **No on-the-fly computation.** Currently the user must precompute the full
   tree from the repertoire root (often to depth 20) before seeing any
   expectimax data. There is no way to say "I'm at move 12 — compute a quick
   subtree from HERE." A focused BFS from the current position using existing
   `TreeBuildService` infrastructure would let users explore positions that
   aren't in the precomputed tree, then optionally merge results back.

4. **Engine lines aren't clickable in the repertoire builder.** The
   `UnifiedEnginePane` continuation column is plain text — no per-move click,
   no hover. Only the first-move row is tappable. The PGN Viewer's
   `InlineEngineBar` + `ClickableMoveLineWidget` already solved this for that
   screen, but the repertoire builder doesn't use it.

---

## Design Goals

1. **Expectimax as a "second engine"**: show precomputed lines in the same
   visual language as Stockfish MultiPV — rank, eval, clickable/hoverable
   SAN continuation. Users toggle between Stockfish and Expectimax like
   switching engine backends.
2. **Lichess-style hover everywhere**: hovering ANY move in ANY line display
   (engine PV, expectimax line, browse candidate, PGN move, trap, suggestion)
   temporarily shows that position on the board. Mouse leave restores. Click
   commits.
3. **On-the-fly BFS**: "Compute from here" button runs a scoped tree build
   from the current FEN, with its own depth/thread settings, real-time progress,
   and automatic Phase 2 (ease + expectimax) on completion.
4. **Click to add**: clicking a move in an expectimax or engine line can add it
   to the repertoire PGN (via `RepertoireWriter` from spec 002).
5. **Unified interaction model**: engine lines, expectimax lines, and browse
   candidates all use the same `ClickableMoveLineWidget` and hover preview
   system — consistent UX everywhere.

---

## Reference Patterns

| App | Feature | Key insight |
|-----|---------|-------------|
| Lichess Analysis | Hover PV move → board updates | Debounced ~100ms, restores on leave |
| Lichess Analysis | Multiple engine lines (MultiPV) | Rank, eval, clickable continuation |
| En Croissant | Opening explorer + engine inline | Same panel shows both DB and engine data |
| ChessBase | Reference engine + own analysis engine | Two engines side-by-side |
| Stockfish web | PV lines with per-move click | Click anywhere in line to navigate |

**Our advantage**: Lichess shows raw engine output. We show **practical win
probability** weighted by human move frequencies, trap potential, and ease.
The expectimax line is a "human-aware engine" — it predicts what actually
happens in practice, not just the theoretical best play.

---

## Part 1: Hover Line Preview System

### Architecture

A shared preview layer sits between all move-displaying widgets and the board.
Any widget can request a board preview; at most one preview is active at a time.

```
┌─────────────────────────────────────────────────────────────────┐
│ BoardPreviewController (singleton or InheritedWidget)           │
│                                                                 │
│  previewFen: String?    ← set by any widget on hover            │
│  previewMoves: List<String>?  ← SAN path for highlight          │
│  isPreview: bool        ← true when previewFen != null          │
│                                                                 │
│  setPreview(fen, moves) ← called on hover (debounced 80ms)      │
│  clearPreview()         ← called on mouse leave                  │
│                                                                 │
│  Board reads: previewFen ?? controller.fen                       │
│  Board shows: dimmed + "preview" badge when isPreview            │
└─────────────────────────────────────────────────────────────────┘
```

### Implementation: `lib/services/board_preview_controller.dart` (NEW)

```dart
/// Controls temporary board position previews.
/// Any widget can request a preview; at most one is active.
/// The board reads previewFen when non-null instead of the
/// RepertoireController's committed fen.
class BoardPreviewController extends ChangeNotifier {
  String? _previewFen;
  List<String>? _previewMoves;
  Timer? _debounce;

  String? get previewFen => _previewFen;
  List<String>? get previewMoves => _previewMoves;
  bool get isPreview => _previewFen != null;

  /// Request a board preview. Debounced: first call within 80ms wins.
  void setPreview(String fen, {List<String>? moves}) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 80), () {
      _previewFen = fen;
      _previewMoves = moves;
      notifyListeners();
    });
  }

  /// Clear the preview (mouse leave). Immediate, no debounce.
  void clearPreview() {
    _debounce?.cancel();
    if (_previewFen == null) return;
    _previewFen = null;
    _previewMoves = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }
}
```

### Board Integration

```dart
// In RepertoireScreen or BoardZone (spec 003):
Widget _buildBoard() {
  return ListenableBuilder(
    listenable: _boardPreview,
    builder: (context, _) {
      final displayFen = _boardPreview.previewFen ?? _controller.fen;
      final isPreview = _boardPreview.isPreview;

      return Stack(
        children: [
          Opacity(
            opacity: isPreview ? 0.85 : 1.0,
            child: ChessBoardWidget(
              key: ValueKey(displayFen),
              position: _positionFromFen(displayFen),
              flipped: _boardFlipped,
              onMove: isPreview ? null : _handleMove,
            ),
          ),
          if (isPreview)
            Positioned(
              top: 4, right: 4,
              child: Container(
                padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text('Preview',
                  style: TextStyle(color: Colors.white70, fontSize: 11)),
              ),
            ),
        ],
      );
    },
  );
}
```

### Hover-Enabled Move Widget

Extend `ClickableMoveLineWidget` with hover callbacks:

```dart
class ClickableMoveLineWidget extends StatelessWidget {
  // ... existing props ...
  final void Function(int index)? onMoveHovered;
  final VoidCallback? onHoverExit;

  // In build(), each move WidgetSpan gets:
  MouseRegion(
    cursor: SystemMouseCursors.click,
    onEnter: (_) => onMoveHovered?.call(idx),
    onExit: (_) => onHoverExit?.call(),
    child: GestureDetector(
      onTap: () => onMoveTapped!(idx),
      child: /* existing styled Text */,
    ),
  ),
}
```

### FEN Computation for Hover

The parent widget computes FEN for each hovered move index by replaying the
PV from the starting FEN:

```dart
/// Compute the FEN after playing moves[0..hoverIndex] from startFen.
String fenAfterMoves(String startFen, List<String> sanMoves, int upToIndex) {
  var pos = Chess.fromSetup(Setup.parseFen(startFen));
  for (int i = 0; i <= upToIndex && i < sanMoves.length; i++) {
    final move = pos.parseSan(sanMoves[i]);
    if (move == null) break;
    pos = pos.play(move);
  }
  return pos.fen;
}

// On hover callback:
void _onMoveHovered(int index) {
  final fen = fenAfterMoves(widget.fen, _currentLine, index);
  _boardPreview.setPreview(fen, moves: _currentLine.sublist(0, index + 1));
}

void _onHoverExit() {
  _boardPreview.clearPreview();
}
```

### Where Hover Preview Applies

Every widget displaying a clickable move sequence gets hover for free:

| Widget | Current behavior | With hover |
|--------|-----------------|------------|
| `UnifiedEnginePane` continuation | Plain text, not clickable | `ClickableMoveLineWidget` + hover |
| `InlineEngineBar` PV lines | Clickable, no hover | Add hover callbacks |
| `BrowsePanel` candidate rows | Planned click only (spec 002) | Add hover on row |
| `RepertoireTreeExplorer` rows | Click navigates | Add hover on row |
| `TrapDetailCard` reply rows | Planned click (spec 005) | Add hover on reply move |
| `SuggestionPanel` rows | Planned Preview button (spec 006) | Hover replaces Preview button |
| `InteractivePgnEditor` moves | Click navigates | Add hover |
| `RepertoireLinesBrowser` move preview | Static text | Add hover |
| Expectimax lines panel (this spec) | NEW | Built-in hover |

---

## Part 2: Expectimax Lines Panel

### Concept

An engine-like panel showing the best N-ply expectimax continuation from the
current position. Looks and feels like Stockfish MultiPV output, but backed
by precomputed tree data (or on-the-fly computation).

```
┌─ Expectimax Lines ─── depth 14 ── from tree ──────────────────────┐
│                                                                    │
│  1  V:62%  +0.42  1...c5 (41%) 2.Nf3 d6 (38%) 3.d4 cxd4 4.Nxd4  │
│  2  V:58%  +0.38  1...e5 (28%) 2.Nf3 Nc6 (52%) 3.Bb5 a6 4.Ba4   │
│  3  V:54%  +0.25  1...e6 (12%) 2.d4 d5 (67%) 3.Nd2 Nf6 4.e5     │
│                                                                    │
│  Opponent moves show probability. Our moves show ★ if repertoire.  │
│  Hover any move → board previews that position.                    │
│  Click any move → navigate there.                                  │
│                                                                    │
│  [⚡ Compute deeper]  [MultiPV: 3 ▾]  [Depth: +8 ▾]              │
└────────────────────────────────────────────────────────────────────┘
```

### Data Source: `followExpectimaxLine()`

New utility that walks the tree from any node, producing a single "best line":

```dart
/// Follow the expectimax-optimal path from [start] for up to [maxPlies].
///
/// At our-move nodes: pick the child with the highest expectimax value
/// (via scoreOurMoveChildren, respecting eval-loss filter + novelty).
/// At opponent nodes: pick the child with the highest moveProbability
/// (most likely human response).
///
/// Returns the path as a list of BuildTreeNode (excluding [start]).
List<BuildTreeNode> followExpectimaxLine(
  BuildTreeNode start,
  TreeBuildConfig config,
  ExpectimaxCalculator eca, {
  required int maxPlies,
  FenMap? fenMap,
}) {
  final path = <BuildTreeNode>[];
  var node = start;

  for (var i = 0; i < maxPlies && node.children.isNotEmpty; i++) {
    // Resolve transposition leaves to their canonical node
    final resolved = _resolveTransposition(node, fenMap);
    if (resolved.children.isEmpty) break;

    final isOurMove = resolved.isWhiteToMove == config.playAsWhite;
    BuildTreeNode? next;

    if (isOurMove) {
      // Pick the best expectimax child (same logic as repertoire selection)
      final scored = eca.scoreOurMoveChildren(resolved);
      next = scored?.child;
    } else {
      // Pick the most likely opponent response
      double bestProb = -1;
      for (final child in resolved.children) {
        if (child.moveProbability > bestProb) {
          bestProb = child.moveProbability;
          next = child;
        }
      }
    }

    if (next == null) break;
    path.add(next);
    node = next;
  }

  return path;
}
```

### MultiPV: Top-K Lines

For MultiPV display, enumerate the top K children at the start node (our-move)
and follow each one independently:

```dart
/// Generate MultiPV-style lines from [start].
/// At the first our-move node, enumerate the top [multiPv] children by
/// expectimax value. For each, follow the best continuation for [maxPlies].
List<ExpectimaxLine> generateExpectimaxLines(
  BuildTreeNode start,
  TreeBuildConfig config,
  ExpectimaxCalculator eca, {
  required int multiPv,
  required int maxPlies,
  FenMap? fenMap,
}) {
  final isOurMove = start.isWhiteToMove == config.playAsWhite;
  if (!isOurMove || start.children.isEmpty) {
    // Opponent to move: single line (most probable + then follow)
    final line = followExpectimaxLine(start, config, eca,
        maxPlies: maxPlies, fenMap: fenMap);
    if (line.isEmpty) return [];
    return [ExpectimaxLine.fromPath(start, line, config)];
  }

  // Our move: rank children by expectimax, take top multiPv
  final scored = <ScoredChild>[];
  for (final child in start.children) {
    if (!child.hasExpectimax) continue;
    scored.add(ScoredChild(child: child, expectimaxValue: child.expectimaxValue));
  }
  scored.sort((a, b) => b.expectimaxValue.compareTo(a.expectimaxValue));

  final lines = <ExpectimaxLine>[];
  for (var i = 0; i < multiPv && i < scored.length; i++) {
    final firstChild = scored[i].child;
    final continuation = followExpectimaxLine(firstChild, config, eca,
        maxPlies: maxPlies - 1, fenMap: fenMap);
    lines.add(ExpectimaxLine.fromPath(
      start,
      [firstChild, ...continuation],
      config,
    ));
  }

  return lines;
}
```

### Data Model: `ExpectimaxLine`

```dart
/// One line of expectimax output, analogous to a Stockfish DiscoveryLine.
class ExpectimaxLine {
  final int rank;                   // 1-based MultiPV rank
  final double expectimaxValue;     // V at the first move
  final int? evalCp;                // Engine eval at the first move (our perspective)
  final int depth;                  // How many plies this line covers
  final List<String> movesSan;      // SAN move sequence
  final List<String> movesUci;      // UCI move sequence
  final List<ExpectimaxMoveInfo> moveInfo;  // Per-move metadata

  factory ExpectimaxLine.fromPath(
    BuildTreeNode start,
    List<BuildTreeNode> path,
    TreeBuildConfig config,
  ) {
    return ExpectimaxLine(
      rank: 0, // set by caller
      expectimaxValue: path.isNotEmpty ? path.first.expectimaxValue : 0.5,
      evalCp: path.isNotEmpty ? path.first.evalForUs(config.playAsWhite) : null,
      depth: path.length,
      movesSan: path.map((n) => n.moveSan).toList(),
      movesUci: path.map((n) => n.moveUci).toList(),
      moveInfo: path.map((n) => ExpectimaxMoveInfo(
        moveProbability: n.moveProbability,
        isOurMove: n.isWhiteToMove != config.playAsWhite,
        isRepertoireMove: n.isRepertoireMove,
        evalCp: n.evalForUs(config.playAsWhite),
        ease: n.ease,
        trapScore: n.trapScore >= 0 ? n.trapScore : null,
        expectimaxValue: n.hasExpectimax ? n.expectimaxValue : null,
      )).toList(),
    );
  }
}

/// Per-move metadata in an expectimax line.
class ExpectimaxMoveInfo {
  final double moveProbability;     // How likely this move is played
  final bool isOurMove;             // Our move or opponent's
  final bool isRepertoireMove;      // Selected in repertoire pass
  final int? evalCp;                // Eval after this move (our perspective)
  final double? ease;               // Ease at resulting position
  final double? trapScore;          // Trap score at resulting position
  final double? expectimaxValue;    // V at resulting position
}
```

### Widget: `lib/widgets/engine/expectimax_lines_pane.dart` (NEW)

```dart
/// Engine-like panel displaying expectimax lines from the precomputed tree.
/// Visual parity with UnifiedEnginePane: rank, eval, clickable continuation.
class ExpectimaxLinesPane extends StatefulWidget {
  final String fen;
  final BuildTree? tree;
  final TreeBuildConfig? config;
  final FenMap? fenMap;
  final bool isWhiteRepertoire;
  final BoardPreviewController boardPreview;
  final void Function(String san)? onMoveSelected;
  final void Function(List<String> sanMoves, int index)? onLineMoveClicked;

  @override
  State<ExpectimaxLinesPane> createState() => _ExpectimaxLinesPaneState();
}

class _ExpectimaxLinesPaneState extends State<ExpectimaxLinesPane> {
  List<ExpectimaxLine> _lines = [];
  int _multiPv = 3;
  int _maxPlies = 12;

  @override
  void didUpdateWidget(covariant ExpectimaxLinesPane old) {
    if (old.fen != widget.fen) _recompute();
  }

  void _recompute() {
    if (widget.tree == null || widget.config == null) {
      setState(() => _lines = []);
      return;
    }

    // Find the node matching current FEN in the tree
    final node = _findNodeByFen(widget.tree!, widget.fen);
    if (node == null) {
      setState(() => _lines = []);
      return;
    }

    final eca = ExpectimaxCalculator(
        config: widget.config!, fenMap: widget.fenMap);

    final lines = generateExpectimaxLines(
      node, widget.config!, eca,
      multiPv: _multiPv,
      maxPlies: _maxPlies,
      fenMap: widget.fenMap,
    );

    setState(() => _lines = lines);
  }

  @override
  Widget build(BuildContext context) {
    if (_lines.isEmpty && widget.tree != null) {
      return _buildNoDataState();
    }
    if (widget.tree == null) {
      return _buildNoTreeState();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildHeader(),
        const Divider(height: 1),
        Expanded(
          child: ListView.builder(
            itemCount: _lines.length,
            itemBuilder: (ctx, i) => _buildLineRow(_lines[i]),
          ),
        ),
        _buildControls(),
      ],
    );
  }

  Widget _buildHeader() {
    final node = _findNodeByFen(widget.tree!, widget.fen);
    final depth = node?.subtreePly ?? 0;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          Text('Expectimax Lines',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
          const Spacer(),
          Text('depth $depth',
              style: TextStyle(fontSize: 11, color: Colors.grey)),
          const SizedBox(width: 8),
          Container(
            padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.teal.withOpacity(0.15),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text('from tree',
                style: TextStyle(fontSize: 10, color: Colors.teal)),
          ),
        ],
      ),
    );
  }

  Widget _buildLineRow(ExpectimaxLine line) {
    final vStr = '${(line.expectimaxValue * 100).round()}%';
    final evalStr = line.evalCp != null
        ? _formatEval(line.evalCp!)
        : '?';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      child: Row(
        children: [
          // Rank
          SizedBox(width: 20, child: Text('${line.rank}',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13))),
          // V value
          SizedBox(width: 42, child: Text('V:$vStr',
              style: TextStyle(
                fontWeight: FontWeight.bold, fontSize: 12,
                color: _vColor(line.expectimaxValue),
              ))),
          // Eval
          SizedBox(width: 48, child: Text(evalStr,
              style: TextStyle(
                fontWeight: FontWeight.bold, fontSize: 12,
                fontFamily: 'monospace',
                color: _evalColor(line.evalCp),
              ))),
          const SizedBox(width: 6),
          // Clickable + hoverable continuation
          Expanded(
            child: ClickableMoveLineWidget(
              sanMoves: line.movesSan,
              startPly: _startPly,
              maxMoves: 10,
              onMoveTapped: (idx) => _onLineMoveTapped(line, idx),
              onMoveHovered: (idx) => _onMoveHovered(line, idx),
              onHoverExit: () => widget.boardPreview.clearPreview(),
            ),
          ),
        ],
      ),
    );
  }

  /// Move annotations inline: opponent moves show probability, our moves
  /// show ★ if repertoire move.
  /// Handled inside ClickableMoveLineWidget via optional annotations list.

  Widget _buildControls() {
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Row(
        children: [
          // Compute deeper button (on-the-fly BFS, see Part 3)
          OutlinedButton.icon(
            icon: Icon(Icons.bolt, size: 14),
            label: Text('Compute deeper'),
            onPressed: _onComputeDeeper,
          ),
          const Spacer(),
          // MultiPV selector
          DropdownButton<int>(
            value: _multiPv,
            items: [1, 2, 3, 5].map((v) =>
                DropdownMenuItem(value: v, child: Text('PV $v'))).toList(),
            onChanged: (v) {
              if (v != null) setState(() { _multiPv = v; _recompute(); });
            },
            isDense: true,
          ),
          const SizedBox(width: 8),
          // Max depth selector
          DropdownButton<int>(
            value: _maxPlies,
            items: [4, 8, 12, 16, 20].map((v) =>
                DropdownMenuItem(value: v, child: Text('+$v'))).toList(),
            onChanged: (v) {
              if (v != null) setState(() { _maxPlies = v; _recompute(); });
            },
            isDense: true,
          ),
        ],
      ),
    );
  }

  void _onLineMoveTapped(ExpectimaxLine line, int index) {
    // Navigate to the clicked position
    final san = line.movesSan[index];
    widget.onMoveSelected?.call(san);
    // Or: commit the full line up to index as navigation
    widget.onLineMoveClicked?.call(line.movesSan, index);
  }

  void _onMoveHovered(ExpectimaxLine line, int index) {
    final fen = fenAfterMoves(widget.fen, line.movesSan, index);
    widget.boardPreview.setPreview(fen,
        moves: line.movesSan.sublist(0, index + 1));
  }
}
```

### Expectimax vs Engine: Side-by-Side or Toggle

Two display approaches (user-configurable):

| Mode | Layout | When to use |
|------|--------|-------------|
| **Toggle** (default) | One panel, switch between Stockfish / Expectimax via toggle | Compact screens, focused work |
| **Side-by-side** | Both panels visible (split vertically) | Wide screens, compare engine vs practical lines |

Toggle implementation: reuse the existing engine toggle chip pattern from
spec 001. Add a second toggle icon in the board toolbar:

```
[⚡ Engine]  [🎯 Expectimax]   ← two toggle buttons
```

- Both can be ON simultaneously (engine uses live Stockfish; expectimax reads
  precomputed tree — no resource contention).
- If on-the-fly BFS is running, the expectimax toggle shows a spinner.
- If no tree is loaded, expectimax toggle shows "No tree — Compute?" tooltip.

---

## Part 3: On-the-Fly BFS Computation

### Concept

"Compute from here" runs a scoped `TreeBuildService.build()` starting at the
current FEN, with lighter defaults (lower depth, fewer nodes), then
automatically runs Phase 2 (ease + expectimax) and displays lines.

This is the same pipeline as full generation but:
- **Root = current position** (not repertoire root)
- **Smaller scope**: default depth 8-10, max 2000 nodes
- **Auto Phase 2**: runs ease + expectimax immediately on completion
- **Results cached**: stored per-FEN in a `Map<String, BuildTree>` session cache
- **Optional merge**: user can merge the subtree into the main tree

### Settings

Same controls as the generation tab but with lighter defaults:

| Setting | Default (on-the-fly) | Default (full gen) |
|---------|---------------------|--------------------|
| Depth | 8 | 20 |
| Max nodes | 2000 | unlimited |
| Engine threads | 1-2 | cores-1 |
| Eval depth | 16 | 20 |
| Our MultiPV | 3 | 3 |
| Opponent source | Maia | Maia |

Displayed as a compact settings row below the expectimax lines panel:

```
┌─ On-the-fly settings ──────────────────────────────────────────┐
│ Depth: [8 ▾]  Threads: [2 ▾]  Mode: [Expectimax ▾]  [Compute] │
└────────────────────────────────────────────────────────────────┘
```

### State Machine

```
                                              ┌──────────────────┐
                                              │                  │
                                              ▼                  │
┌─────────────┐  "Compute"   ┌────────────┐  done   ┌────────────┐
│ NO_DATA     │─────────────►│ COMPUTING  │────────►│ HAS_DATA   │
│ (no tree    │              │ (BFS +     │         │ (lines     │
│  at this    │              │  Phase 2)  │         │  displayed) │
│  FEN)       │              └────────────┘         └────────────┘
└─────────────┘                    │                      │
      ▲                            │ cancel               │ FEN changes
      │                            ▼                      │ (tree at new
      │                      ┌────────────┐               │  FEN? → HAS_DATA
      └──────────────────────│ CANCELLED  │               │  else → NO_DATA)
                             └────────────┘               ▼
                                                    check cache
```

### Implementation

```dart
/// On-the-fly expectimax computation from arbitrary positions.
/// Manages a session cache of subtrees and coordinates build + Phase 2.
class OnTheFlyExpectimaxService extends ChangeNotifier {
  final TreeBuildService _buildService = TreeBuildService();
  final Map<String, BuildTree> _cache = {};
  final Map<String, FenMap> _fenMaps = {};

  OnTheFlyComputeState _state = OnTheFlyComputeState.noData;
  OnTheFlyComputeState get state => _state;

  BuildTree? _currentTree;
  BuildTree? get currentTree => _currentTree;
  String? _computingFen;

  BuildProgress? _progress;
  BuildProgress? get progress => _progress;

  /// Check if we have precomputed data for this FEN (from main tree or cache).
  bool hasDataForFen(String fen, BuildTree? mainTree) {
    if (_cache.containsKey(fen)) return true;
    if (mainTree != null) return _findNodeInTree(mainTree, fen) != null;
    return false;
  }

  /// Get the tree data for a FEN (main tree node or cached subtree).
  BuildTree? getTreeForFen(String fen, BuildTree? mainTree) {
    if (_cache.containsKey(fen)) return _cache[fen];
    // Wrap the subtree node from main tree as a BuildTree
    if (mainTree != null) {
      final node = _findNodeInTree(mainTree, fen);
      if (node != null) return _wrapAsTree(node);
    }
    return null;
  }

  /// Compute a subtree from this FEN.
  Future<void> compute({
    required String fen,
    required bool playAsWhite,
    int maxPly = 8,
    int maxNodes = 2000,
    int evalDepth = 16,
    int ourMultiPv = 3,
    int engineThreads = 2,
    BuildMode buildMode = BuildMode.stockfishExpectimax,
    void Function(BuildProgress)? onProgress,
  }) async {
    _computingFen = fen;
    _state = OnTheFlyComputeState.computing;
    notifyListeners();

    final config = TreeBuildConfig(
      startFen: fen,
      playAsWhite: playAsWhite,
      maxPly: maxPly,
      maxNodes: maxNodes,
      evalDepth: evalDepth,
      ourMultipv: ourMultiPv,
      engineThreads: engineThreads,
      buildMode: buildMode,
      // Use lighter defaults for on-the-fly
      minProbability: 0.02,
      maxEvalLossCp: 80,
    );

    // Phase 1: BFS build
    final tree = await _buildService.build(
      config: config,
      onProgress: (p) {
        _progress = p;
        onProgress?.call(p);
        notifyListeners();
      },
      isCancelled: () => _state != OnTheFlyComputeState.computing,
    );

    if (_state != OnTheFlyComputeState.computing) return;

    // Phase 2: ease + expectimax
    final fenMap = FenMap();
    fenMap.buildFromTree(tree);
    calculateTreeEase(tree, playAsWhite: playAsWhite);
    final eca = ExpectimaxCalculator(config: config, fenMap: fenMap);
    eca.calculate(tree);
    eca.computeTrapScores(tree.root);

    // Cache result
    _cache[fen] = tree;
    _fenMaps[fen] = fenMap;
    _currentTree = tree;
    _state = OnTheFlyComputeState.hasData;
    notifyListeners();
  }

  void cancel() {
    _state = OnTheFlyComputeState.cancelled;
    notifyListeners();
  }

  /// Merge cached subtree into the main tree at the matching FEN.
  /// Enables on-the-fly results to persist with the repertoire.
  Future<void> mergeIntoMainTree(BuildTree mainTree, String fen) async {
    final subtree = _cache[fen];
    if (subtree == null) return;
    // Find the node in mainTree at this FEN and graft subtree children
    final target = _findNodeInTree(mainTree, fen);
    if (target == null) return;
    // Merge children that don't already exist
    for (final child in subtree.root.children) {
      final existing = target.children
          .where((c) => c.moveUci == child.moveUci)
          .firstOrNull;
      if (existing == null) {
        child.parent = target;
        target.children.add(child);
      }
    }
    mainTree.computeMetadata();
  }
}

enum OnTheFlyComputeState { noData, computing, hasData, cancelled }
```

### Progress Display

While computing, the expectimax lines panel shows:

```
┌─ Computing from e4 c5 Nf3 d6 ─────────────────────────────────┐
│                                                                  │
│  ████████████░░░░░░░░░░  347/2000 nodes  depth 6/8              │
│  ETA: ~12s   (34 nodes/sec)                                     │
│                                                                  │
│  [Cancel]  [Pause]                                               │
│                                                                  │
│  Partial results (depth 4):                                      │
│  1  V:61%  +0.35  3...cxd4 (62%) 4.Nxd4 Nf6 (87%) 5.Nc3       │
│  2  V:55%  +0.28  3...Nf6 (23%) 4.Nc3 cxd4 (71%) 5.Nxd4       │
└──────────────────────────────────────────────────────────────────┘
```

Partial results update every 2 seconds: run Phase 2 on the in-progress tree
and show current best lines. This gives immediate value while building deeper.

---

## Part 4: Click-to-Add from Lines

### Engine Lines → Repertoire

When the user clicks a move in an expectimax or engine line, the action depends
on context:

| Click target | Action |
|-------------|--------|
| Move already in repertoire tree | Navigate to that position (existing behavior) |
| Move NOT in repertoire | Show "Add to repertoire?" tooltip, click again to confirm. Or: hold Ctrl+click to add immediately. |
| Shift+click | Add entire line up to this point to repertoire |

Implementation reuses `RepertoireWriter.addMoveAtPosition()` from spec 002:

```dart
void _onLineMoveClicked(ExpectimaxLine line, int index) {
  final movesToPlay = line.movesSan.sublist(0, index + 1);

  if (_isShiftHeld) {
    // Add all moves in sequence
    _addLineToRepertoire(movesToPlay);
  } else {
    // Navigate to the position (play moves on board)
    for (final san in movesToPlay) {
      _controller.userPlayedMove(san);
    }
  }
}

Future<void> _addLineToRepertoire(List<String> moves) async {
  var path = _controller.currentMoveSequence;
  for (final san in moves) {
    path = await _writer.addMoveAtPosition(
      fen: _controller.fen,
      san: san,
      pathFromRoot: path,
    );
    _controller.userPlayedMove(san);
  }
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text('Added ${moves.length} moves to repertoire')),
  );
}
```

### Engine Lines (Stockfish) — Same Treatment

Extend `UnifiedEnginePane` continuation to use `ClickableMoveLineWidget`
instead of plain `Text` + `formatContinuation`:

```dart
// Replace in _buildMoveRow:
Expanded(
  child: ClickableMoveLineWidget(
    sanMoves: _pvToSanList(widget.fen, move.fullPv),
    startPly: _currentPly,
    startIndex: 1,  // skip first move (shown in MOVE column)
    maxMoves: 8,
    onMoveTapped: (idx) => _onPvMoveTapped(move, idx),
    onMoveHovered: (idx) => _onPvMoveHovered(move, idx),
    onHoverExit: () => _boardPreview.clearPreview(),
  ),
),
```

This gives engine lines the same click + hover behavior as expectimax lines.

---

## Part 5: Inline Annotations on Lines

Expectimax lines carry richer data than engine PVs. Show this inline:

### Opponent moves: probability annotation

```
1...c5 (41%) 2.Nf3 d6 (38%)
     ^^^^          ^^^^
     grey text showing how likely this opponent response is
```

### Our moves: repertoire badge

```
2.Nf3 ★ d6 3.d4 ★
      ^        ^
      teal star if this move is the repertoire-selected move
```

### Trap indicators

```
4.Nxd4 Nf6 5.Nc3 ⚠ a6
                  ^
                  orange dot at positions with high trap score
```

These annotations are rendered by extending `ClickableMoveLineWidget` with
an optional `annotations` list that maps index → annotation widget:

```dart
class ClickableMoveLineWidget extends StatelessWidget {
  // ... existing props ...
  final List<MoveAnnotation>? annotations;  // NEW
}

class MoveAnnotation {
  final String? suffix;           // "(41%)" after the move
  final Color? suffixColor;       // grey for prob
  final IconData? prefixIcon;     // ★ or ⚠
  final Color? prefixIconColor;   // teal or orange
}
```

---

## Widget Architecture

### New files

| File | Purpose |
|------|---------|
| `lib/services/board_preview_controller.dart` | Hover preview state management |
| `lib/services/expectimax_line_service.dart` | `followExpectimaxLine`, `generateExpectimaxLines`, `ExpectimaxLine` model |
| `lib/services/on_the_fly_expectimax_service.dart` | On-the-fly BFS + cache |
| `lib/widgets/engine/expectimax_lines_pane.dart` | Main expectimax lines panel widget |
| `lib/widgets/engine/expectimax_toggle_button.dart` | Board toolbar toggle for expectimax |

### Modified files

| File | Change |
|------|--------|
| `lib/widgets/clickable_move_line.dart` | Add `onMoveHovered`, `onHoverExit`, `annotations` |
| `lib/widgets/engine/unified_engine_pane.dart` | Replace plain continuation with `ClickableMoveLineWidget` + hover |
| `lib/widgets/engine/inline_engine_bar.dart` | Add hover callbacks to existing clickable moves |
| `lib/widgets/chess_board_widget.dart` | Accept `previewFen` for overlay display |
| `lib/screens/repertoire_screen.dart` | Wire `BoardPreviewController`, add expectimax pane |

---

## Edge Cases

### 1. No tree loaded (new repertoire, no generation run)

**Solution:** Expectimax panel shows empty state with "Compute" button. User
can run on-the-fly BFS immediately. Or: show Stockfish engine lines only.

### 2. Current position not in the precomputed tree

**Solution:** Check `_findNodeByFen`. If not found, show "Position not in tree"
with "Compute from here" button. On-the-fly BFS fills the gap.

### 3. Tree exists but no expectimax values (Phase 2 not run)

**Solution:** `hasExpectimax` field on `BuildTreeNode` is false. Show fallback:
engine eval from tree nodes (they have `engineEvalCp`), skip V display. Or:
run Phase 2 on-demand (fast — < 50ms for most trees).

### 4. Hover while on-the-fly BFS is computing

**Solution:** Hover still works on partial results. `_recompute()` is called
when progress updates arrive. Hover targets the latest partial line list.

### 5. Rapid position changes during hover

**Solution:** `BoardPreviewController.setPreview()` is debounced at 80ms. Rapid
mouse movement across multiple moves produces at most ~12 board updates/second.
`clearPreview()` is immediate to avoid stale previews.

### 6. Hover preview + keyboard navigation conflict

**Solution:** Keyboard arrows commit navigation (via `RepertoireController`),
which updates the committed FEN. If a hover is active, it's cleared on any
keyboard event. Board always shows committed FEN when no hover is active.

### 7. On-the-fly BFS + full generation running simultaneously

**Solution:** On-the-fly uses its own `TreeBuildService` instance with its own
pool workers (1-2 threads). Full generation uses the main pool. If both need
Stockfish, on-the-fly is lower priority — it pauses if the main pool is in
generation state (check `EngineLifecycle.state == generating`). Alternatively,
on-the-fly can use `maiaDbExplore` mode (no engine needed) as a fast fallback.

### 8. Merging on-the-fly subtree into main tree with conflicts

**Solution:** Only merge children that don't already exist (by UCI). Existing
nodes in the main tree keep their evals (they were computed with full depth).
New nodes from on-the-fly are marked with a "shallow" flag so they can be
re-evaluated during the next full generation.

---

## Testing Strategy

### Unit tests

| Test | Verifies |
|------|----------|
| `followExpectimaxLine` with known tree | Correct path: best expectimax at our nodes, most probable at opponent nodes |
| `followExpectimaxLine` with transpositions | Resolved correctly via FenMap |
| `generateExpectimaxLines` MultiPV=3 | Returns 3 lines sorted by V |
| `generateExpectimaxLines` at opponent node | Single line (most probable) |
| `BoardPreviewController` debounce | Rapid setPreview → only last fires |
| `BoardPreviewController` clearPreview | Immediate, cancels pending debounce |
| `ExpectimaxLine.fromPath` | Correct SAN, eval, V extraction |
| `OnTheFlyExpectimaxService.compute` | Builds tree, runs Phase 2, caches |
| `OnTheFlyExpectimaxService` cancel | Stops build, state = cancelled |
| `mergeIntoMainTree` | New children added, existing untouched |

### Widget tests

| Test | Verifies |
|------|----------|
| `ExpectimaxLinesPane` with tree | Shows N lines with V, eval, SAN |
| `ExpectimaxLinesPane` without tree | Shows empty state with "Compute" |
| Hover move → `BoardPreviewController.previewFen` set | Board shows preview |
| Mouse leave → preview cleared | Board restores committed FEN |
| Click PV move → navigation | Board navigates to that position |
| MultiPV selector → line count changes | Correct re-render |
| Annotations on opponent moves | Probability shown inline |

### Integration tests

| Test | Verifies |
|------|----------|
| On-the-fly compute → lines appear | Full pipeline from button to display |
| On-the-fly → merge into main tree | Subtree grafted correctly |
| Engine toggle ON + Expectimax ON | Both panels render simultaneously |
| Hover engine PV + hover expectimax PV | Preview switches correctly |
| Click expectimax line + Shift → add to repertoire | PGN file updated |

### Performance targets

| Metric | Target |
|--------|--------|
| `followExpectimaxLine` (10k node tree) | < 1ms |
| `generateExpectimaxLines` MultiPV=5 | < 5ms |
| Hover → board preview displayed | < 100ms (80ms debounce + render) |
| On-the-fly BFS (depth 8, 2000 nodes) | < 30s |
| On-the-fly Phase 2 (2000 nodes) | < 100ms |
| Partial results update during BFS | Every 2s |

---

## Migration Path

1. **Week 1: Hover preview system** (3 days)
   - `BoardPreviewController`
   - Extend `ClickableMoveLineWidget` with hover callbacks
   - Wire into `RepertoireScreen` board
   - Apply to `InlineEngineBar` (PGN viewer first — already has click infra)
   - Apply to `UnifiedEnginePane` (replace plain text continuation)

2. **Week 2: Expectimax line service + panel** (4 days)
   - `followExpectimaxLine`, `generateExpectimaxLines`, `ExpectimaxLine` model
   - `ExpectimaxLinesPane` widget with hover + click
   - Toggle button in board toolbar
   - Wire into repertoire screen as new context zone chip

3. **Week 3: On-the-fly BFS** (4 days)
   - `OnTheFlyExpectimaxService` with compute/cancel/cache
   - Progress display in expectimax panel
   - Partial results (Phase 2 on incomplete tree)
   - "Compute deeper" button
   - Merge into main tree

4. **Week 4: Polish + add-to-repertoire** (3 days)
   - Click-to-add from lines (Shift+click for bulk)
   - Inline annotations (probability, ★, ⚠)
   - Side-by-side Engine + Expectimax layout option
   - Settings persistence
   - Edge case testing

---

## Open Questions

1. **Should on-the-fly auto-trigger when navigating to an unexplored position?**
   Recommend: no by default (CPU cost). Show "Compute" button. User can enable
   auto-compute in settings.

2. **Should on-the-fly results persist across sessions (write to disk)?**
   Recommend: session cache only by default. User can explicitly "Save subtree"
   or merge into main tree. Full persistence adds file management complexity.

3. **Should expectimax lines show a different visual style than engine lines?**
   Recommend: same layout, different accent color. Engine = blue/teal (existing).
   Expectimax = green or purple. Header badge distinguishes source ("from tree"
   vs "live engine").

4. **MultiPV at opponent nodes?**
   Current design shows one line per opponent response (most probable). Could
   show multiple opponent responses like engine MultiPV. Recommend: defer to
   browse mode (spec 002) which already handles opponent branching.
