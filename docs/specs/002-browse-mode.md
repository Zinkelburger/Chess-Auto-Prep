# Engineering Spec: Interactive Browse Mode

**Status:** Draft  
**Feature:** Browse generated tree / database as a guide, one-click add to repertoire  
**Priority:** P1 — Core manual-prep workflow  
**Depends on:** 001-engine-toggle-lifecycle (for engine state awareness), 009-expectimax-lines-panel (hover preview system, expectimax line display)  
**Estimated effort:** 3-4 weeks  

---

## Problem Statement

Today, going from "I see a good candidate move in the Eval Tree" to "that move
is in my repertoire and trainable" requires:

1. Browse eval tree, find a candidate
2. Tap it (navigates board + session only)
3. Switch to PGN tab
4. Click "Add to Repertoire"
5. Go back to eval tree to continue browsing

This is 5 steps for what should be 1 click. En Croissant solved this: in Build
mode, clicking an unexplored move **immediately adds it to the repertoire AND
navigates there**. One click = add + advance.

### Additional gaps

- No way to build a repertoire WITHOUT running generation first (need tree.json)
- No way to browse Lichess DB moves as candidates (only eval tree from generation)
- No way to mark a line as "trainable" vs "main repertoire"
- No coverage delta shown when hovering candidates ("what does adding this buy me?")
- No "split variation into named line" operation
- The `RepertoireTreeExplorer` shows engine metrics but NOT DB frequency or W/D/B

---

## Design Goals

1. **One click to add**: Tap unexplored move → it's in your repertoire, board
   advances. No tab switching.
2. **Works without generation**: Use Lichess DB as the move source when no
   tree.json exists.
3. **Shows what matters per context**:
   - Opponent's turn: frequency (how often they play this), coverage status
   - Your turn: eval, ease, traps, coherence hint
4. **Coverage-aware**: Per-move coverage indicators + delta on hover
5. **Non-destructive**: All additions are incremental; undo is possible
6. **Trainable distinction**: User can choose "add to repertoire" vs "add as
   trainable drill" vs "just navigate"

---

## Reference: How En Croissant Does It

| Aspect | En Croissant | Our adaptation |
|--------|--------------|----------------|
| Data source | Reference DB only | Generated tree (eval + ease + traps) + Lichess DB fallback |
| Click semantics | Unexplored = makeMove (add+enter), Explored = navigate | Same pattern |
| Coverage | Per-move ring, computed from DB query per FEN | Pre-computed from CoverageService, cached |
| Gap nav | Next/Biggest gap buttons | Already exists in Lines tab — surface in browse |
| Move columns | Move, %, Games, W/D/B, Coverage ring | Merge: Move, %, Games, W/D/B, Eval, Ease, Traps, Coverage |
| Opponent vs our turn | Different headers, rare-move collapse | Same |
| Persistence | Zustand tree store + PGN sync | RepertoireController + disk write |
| Training | FSRS auto-sync from tree edits | appendNewLine + training flag |

Key improvements over En Croissant:
- We show **eval + ease + trap count** per candidate (they show only DB stats)
- We have **pre-computed expectimax** data (they have none)
- We can show **"cached eval" badge** for moves where we already know the answer
- We offer **trainable line** as a separate category

---

## Architecture

### Entry Points into Browse Mode

```
┌─────────────────────────────────────────────────────────────────┐
│ Entry Point                        │ Data Available             │
├────────────────────────────────────┼────────────────────────────┤
│ Eval Tree tab → "Browse" toggle    │ Full BuildTree             │
│ Generate → "Browse Result" button  │ Full BuildTree (just built)│
│ Coverage gap → "Explore gap"       │ BuildTree at gap position  │
│ Lines browser → "Extend..." button │ BuildTree at leaf node     │
│ New repertoire → "Build manually"  │ Lichess DB only (no tree)  │
└────────────────────────────────────┴────────────────────────────┘
```

### State Machine

```
BROWSING
  ├─ position = current FEN (from board/eval tree)
  ├─ candidates = merged(tree children, DB moves)
  ├─ coverageAtPosition = CoverageService lookup
  │
  ├─ User taps UNEXPLORED candidate:
  │     → addMoveToRepertoire(san)
  │     → navigateForward(san)
  │     → recalculate candidates at new position
  │
  ├─ User taps EXPLORED candidate:
  │     → navigateForward(san) only
  │     → recalculate candidates at new position
  │
  ├─ User taps "Add as Trainable":
  │     → saveCurrentPathAsTrainable()
  │     → (does NOT navigate — path is complete)
  │
  ├─ User taps "Back":
  │     → navigateBack()
  │     → recalculate candidates at parent position
  │
  └─ User taps "Next Gap" / "Biggest Gap":
        → jump to gap position
        → recalculate candidates
```

### Data Flow

```
                     ┌──────────────────┐
                     │   Browse Mode    │
                     │  (BrowsePanel)   │
                     └────────┬─────────┘
                              │ requests candidates
                              ▼
                     ┌──────────────────┐
                     │ CandidateService │ ← NEW
                     └────────┬─────────┘
                              │ merges sources
               ┌──────────────┼──────────────┐
               ▼              ▼              ▼
     ┌─────────────┐  ┌────────────┐  ┌──────────────┐
     │  BuildTree  │  │ Lichess DB │  │ EvalCache /  │
     │  (if avail) │  │  Explorer  │  │ ChessDB      │
     └─────────────┘  └────────────┘  └──────────────┘

User clicks "Add" ──────────────────────────────────────┐
                                                         ▼
                                               ┌──────────────────┐
                                               │ RepertoireWriter │ ← NEW
                                               └────────┬─────────┘
                                                        │
                              ┌──────────────────────────┼──────────────┐
                              ▼                          ▼              ▼
                    ┌─────────────────┐      ┌──────────────┐  ┌──────────────┐
                    │ PGN file append │      │ OpeningTree  │  │ repertoire   │
                    │ (atomic write)  │      │  appendLine  │  │ Lines list   │
                    └─────────────────┘      └──────────────┘  └──────────────┘
```

---

## Implementation Plan

### File: `lib/services/candidate_service.dart` (NEW)

Merges tree + DB into a unified candidate list per position.

```dart
/// A single candidate move at the current position.
class CandidateMove {
  final String san;
  final String uci;

  // From BuildTree (null if no tree or move not in tree)
  final int? evalCp;           // Engine eval after this move (our perspective)
  final double? ease;          // Opponent ease (our turn) or our-move ease
  final double? myEase;        // How natural is this for us (Maia frequency)
  final double? expectimax;    // Practical win probability
  final int? subtreeTrapCount; // Traps below this move
  final bool? isRepertoireMove; // Was auto-selected during generation

  // From Lichess DB (null if DB unavailable or no games)
  final int? dbGames;          // Total games with this move
  final double? dbFrequency;   // Share of all games at this position
  final double? dbWhiteWin;    // White win rate
  final double? dbDraw;        // Draw rate
  final double? dbBlackWin;    // Black win rate

  // Derived
  final bool inRepertoire;     // Already in user's OpeningTree
  final double? coverageDelta; // Estimated coverage gain if added (null = unknown)
  final String? evalSource;    // 'tree' | 'cache' | 'db' | 'live' | null

  // Sorting helpers
  bool get hasTreeData => evalCp != null;
  bool get hasDbData => dbGames != null;
}

/// Produces candidate lists for browse mode.
class CandidateService {
  final BuildTree? _tree;
  final OpeningTree _openingTree;
  final LichessExplorerApi _lichessApi;
  final EvalCache _evalCache;
  final CoverageResult? _coverage;

  /// Returns sorted candidates for the given FEN.
  /// - ourTurn: different sort (eval/ease first) vs opponent turn (frequency first)
  /// - maxCandidates: limit (default 8)
  Future<List<CandidateMove>> getCandidates({
    required String fen,
    required bool isOurTurn,
    required bool playAsWhite,
    int maxCandidates = 8,
  }) async {
    final treeMoves = _getTreeMoves(fen);
    final dbMoves = await _getDbMoves(fen);
    return _merge(treeMoves, dbMoves, isOurTurn, fen);
  }

  List<CandidateMove> _merge(...) {
    // 1. Start with tree moves (have eval, ease, traps)
    // 2. For each tree move, enrich with DB data if available
    // 3. Add DB-only moves (not in tree) with null engine fields
    // 4. Mark inRepertoire from OpeningTree lookup
    // 5. Compute coverageDelta for unexplored moves
    // 6. Sort:
    //    - Our turn: isRepertoireMove desc → eval desc → ease desc
    //    - Opponent turn: frequency desc → isRepertoireMove desc
    // 7. Collapse rare moves (< 1% frequency) into separate list
  }
}
```

### File: `lib/services/repertoire_writer.dart` (NEW)

Handles all repertoire mutation operations with proper atomicity.

```dart
/// Atomic repertoire mutations with undo support.
class RepertoireWriter {
  final RepertoireController _controller;
  final String _pgnFilePath;

  /// Add a single move at the current position to the repertoire.
  /// Returns the updated line path (for navigation).
  ///
  /// This is the ONE-CLICK ADD operation.
  Future<List<String>> addMoveAtPosition({
    required String fen,
    required String san,
    required List<String> pathFromRoot,
  }) async {
    // 1. Check if move already in OpeningTree at this FEN → no-op
    if (_controller.openingTree.hasMove(fen, san)) {
      return [...pathFromRoot, san];
    }

    // 2. Append to OpeningTree in memory
    final newPath = [...pathFromRoot, san];
    _controller.openingTree.appendLine(newPath);

    // 3. Find the PGN game that contains pathFromRoot as a prefix
    //    and add san as continuation (or create new game if no match)
    await _appendMoveToPgnFile(pathFromRoot, san);

    // 4. Update repertoireLines
    _controller.appendMoveToExistingLine(pathFromRoot, san);

    // 5. Notify listeners
    _controller.notifyListeners();

    return newPath;
  }

  /// Save the current browsed path as a new trainable line.
  Future<void> savePathAsTrainable({
    required List<String> moves,
    required String title,
  }) async {
    final pgn = _buildPgnWithHeaders(moves, title, trainable: true);
    await _appendGameToPgnFile(pgn);
    _controller.appendNewLine(moves, title, pgn, trainable: true);
  }

  /// Save path as a named standalone line (split variation).
  Future<void> splitAsNamedLine({
    required List<String> moves,
    required String name,
    required int splitAtPly,
  }) async {
    final subpath = moves.sublist(splitAtPly);
    final pgn = _buildPgnWithHeaders(subpath, name, startFen: _fenAtPly(splitAtPly));
    await _appendGameToPgnFile(pgn);
    _controller.appendNewLine(subpath, name, pgn);
  }

  /// Undo last add operation (removes last appended move/game).
  Future<void> undo() async {
    if (_undoStack.isEmpty) return;
    final op = _undoStack.removeLast();
    await op.reverse(this);
  }

  // --- Private ---

  Future<void> _appendMoveToPgnFile(List<String> prefix, String move) async {
    // Strategy: find the game whose mainline matches prefix
    // If found: append move to that game's movetext
    // If not found: create new game with prefix + move
    //
    // Uses atomic write: read → modify → write to tmp → rename
  }

  Future<void> _appendGameToPgnFile(String pgn) async {
    // Append new game block to end of PGN file
    // Uses atomic write: read → append → write to tmp → rename
  }

  String _buildPgnWithHeaders(List<String> moves, String title, {
    bool trainable = false,
    String? startFen,
  }) {
    final headers = StringBuffer();
    headers.writeln('[Event "$title"]');
    if (trainable) headers.writeln('[Trainable "1"]');
    if (startFen != null) headers.writeln('[FEN "$startFen"]');
    headers.writeln('[SetUp "1"]');
    // ... format movetext
  }
}
```

### File: `lib/widgets/browse/browse_panel.dart` (NEW)

The main browse mode widget — replaces/augments the EvalTree explorer.

```dart
/// Interactive browse panel. Shows candidates, handles add/navigate.
class BrowsePanel extends StatefulWidget {
  final RepertoireController controller;
  final BuildTree? tree;
  final CandidateService candidateService;
  final RepertoireWriter writer;
  final CoverageResult? coverage;
  final bool isWhiteRepertoire;

  @override
  State<BrowsePanel> createState() => _BrowsePanelState();
}

class _BrowsePanelState extends State<BrowsePanel> {
  List<CandidateMove> _candidates = [];
  List<CandidateMove> _rareCandidates = [];
  bool _isLoading = false;
  int _hoveredIndex = -1;
  List<String> _currentPath = [];

  @override
  void didUpdateWidget(covariant BrowsePanel old) {
    // Recalculate candidates when position changes
    if (widget.controller.fen != _lastFen) {
      _loadCandidates();
    }
  }

  Future<void> _loadCandidates() async {
    setState(() => _isLoading = true);
    final fen = widget.controller.fen;
    final isOurTurn = _isOurTurn(fen);

    final all = await widget.candidateService.getCandidates(
      fen: fen,
      isOurTurn: isOurTurn,
      playAsWhite: widget.isWhiteRepertoire,
    );

    // Split main vs rare (< 1% frequency on opponent turn)
    if (!isOurTurn) {
      _candidates = all.where((m) => (m.dbFrequency ?? 0) >= 0.01).toList();
      _rareCandidates = all.where((m) => (m.dbFrequency ?? 0) < 0.01).toList();
    } else {
      _candidates = all;
      _rareCandidates = [];
    }
    _isLoading = false;
    if (mounted) setState(() {});
  }

  void _onCandidateTap(CandidateMove move) async {
    if (move.inRepertoire) {
      // Navigate only
      widget.controller.userPlayedMove(move.san);
    } else {
      // Add + navigate (one click!)
      _currentPath = await widget.writer.addMoveAtPosition(
        fen: widget.controller.fen,
        san: move.san,
        pathFromRoot: widget.controller.currentMoveSequence,
      );
      widget.controller.userPlayedMove(move.san);
    }
  }

  void _onAddAsTrainable() async {
    final title = _generateTitle(_currentPath);
    await widget.writer.savePathAsTrainable(
      moves: _currentPath,
      title: title,
    );
    // Show snackbar confirmation
  }
}
```

### File: `lib/widgets/browse/candidate_row.dart` (NEW)

Single candidate move row with hover board preview, optional expectimax line
preview, and context-dependent columns.

**Hover behavior (spec 009):** Hovering a candidate row previews the resulting
position on the main board via `BoardPreviewController`. If the candidate has
tree data, the best expectimax continuation (up to N plies) is shown inline
below the row as a hoverable `ClickableMoveLineWidget`. The user can then
hover individual moves in that continuation to scrub the board further.

```dart
class CandidateRow extends StatelessWidget {
  final CandidateMove candidate;
  final bool isOurTurn;
  final bool isHovered;
  final VoidCallback onTap;
  final VoidCallback onHover;
  final VoidCallback onHoverEnd;
  final BoardPreviewController boardPreview;  // NEW (spec 009)
  final String parentFen;                     // FEN before this move

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) {
        onHover();
        // Preview the position after this candidate move (spec 009)
        final resultFen = playMove(parentFen, candidate.uci);
        if (resultFen != null) {
          boardPreview.setPreview(resultFen);
        }
      },
      onExit: (_) {
        onHoverEnd();
        boardPreview.clearPreview();
      },
      child: GestureDetector(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              // Green left border if inRepertoire
              // Orange left border if trappy
              // Hover highlight
              child: Row(
                children: [
                  _buildRepertoireIndicator(),
                  _buildMoveSan(),
                  Spacer(),
                  if (isOurTurn) ..._buildOurTurnColumns(),
                  if (!isOurTurn) ..._buildOpponentTurnColumns(),
                ],
              ),
            ),
            // Expectimax continuation preview (spec 009)
            // Shown inline below the row when hovered and tree data available
            if (isHovered && candidate.hasTreeData)
              _buildExpectimaxContinuation(),
          ],
        ),
      ),
    );
  }

  /// Show the best expectimax line from this candidate's position.
  /// Uses followExpectimaxLine() from spec 009 to walk the tree.
  /// Rendered as a hoverable ClickableMoveLineWidget — hovering individual
  /// moves in the continuation scrubs the board to that position.
  Widget _buildExpectimaxContinuation() {
    final line = followExpectimaxLine(
      candidate.treeNode!, config, eca, maxPlies: 6);
    if (line.isEmpty) return const SizedBox.shrink();
    final sanMoves = line.map((n) => n.moveSan).toList();
    final vStr = line.first.hasExpectimax
        ? 'V:${(line.first.expectimaxValue * 100).round()}%'
        : '';

    return Padding(
      padding: const EdgeInsets.only(left: 28, top: 2, bottom: 4),
      child: Row(
        children: [
          if (vStr.isNotEmpty)
            Text(vStr, style: TextStyle(fontSize: 10, color: Colors.green)),
          const SizedBox(width: 4),
          Expanded(
            child: ClickableMoveLineWidget(
              sanMoves: sanMoves,
              startPly: candidate.ply + 1,
              maxMoves: 6,
              fontSize: 10,
              onMoveTapped: (idx) => onLineMoveClicked(sanMoves, idx),
              onMoveHovered: (idx) {
                final fen = fenAfterMoves(
                    playMove(parentFen, candidate.uci)!, sanMoves, idx);
                boardPreview.setPreview(fen);
              },
              onHoverExit: () => boardPreview.clearPreview(),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildOurTurnColumns() => [
    if (candidate.evalCp != null) _EvalChip(candidate.evalCp!),
    if (candidate.myEase != null) _EaseBar(candidate.myEase!, label: 'natural'),
    if ((candidate.subtreeTrapCount ?? 0) > 0)
      _TrapBadge(candidate.subtreeTrapCount!),
    if (candidate.coverageDelta != null && candidate.coverageDelta! > 0)
      _CoverageDelta(candidate.coverageDelta!),
  ];

  List<Widget> _buildOpponentTurnColumns() => [
    if (candidate.dbFrequency != null) _FrequencyChip(candidate.dbFrequency!),
    if (candidate.dbGames != null) _GamesChip(candidate.dbGames!),
    if (candidate.dbWhiteWin != null) _ResultBar(
      white: candidate.dbWhiteWin!,
      draw: candidate.dbDraw!,
      black: candidate.dbBlackWin!,
    ),
    _CoverageRing(candidate.inRepertoire ? 1.0 : 0.0),
  ];
}
```

### Modifications to existing files

#### `lib/core/repertoire_controller.dart`

```dart
// ADD: method to append a single move to an existing line
void appendMoveToExistingLine(List<String> prefix, String newMove) {
  // Find the RepertoireLine whose moves match prefix
  // Extend its moves list by newMove
  // Update openingTree at that path
  // This is the in-memory counterpart to disk write
}

// ADD: method to check if a move exists at FEN
// (delegate to OpeningTree)
```

#### `lib/models/opening_tree.dart`

```dart
// ADD: check if specific move exists at a position
bool hasMove(String fen, String san) {
  final node = _fenIndex[fen];
  if (node == null) return false;
  return node.children.any((c) => c.san == san);
}

// ADD: appendLine that works with custom startingFen
void appendLineFromFen(String startFen, List<String> moves) {
  // Handle non-standard starting positions
}
```

#### `lib/models/repertoire_line.dart`

```dart
// ADD: trainable flag
class RepertoireLine {
  // ... existing fields ...
  final bool trainableOnly; // If true, drilled but not "main repertoire"
  final String? parentLineId; // For split variations
}
```

#### `lib/services/repertoire_service.dart`

```dart
// ADD: parse [Trainable "1"] header
// ADD: handle parentLineId from [ParentLine "..."] header
```

#### `lib/screens/repertoire_screen.dart`

```dart
// ADD: Browse mode tab/toggle alongside existing tabs
// OR: Replace EvalTree tab with unified Browse + Graph view
// Entry: when user enables browse mode, instantiate CandidateService + BrowsePanel
```

---

## Edge Cases & Solutions

### 1. No BuildTree and no Lichess DB available

**Problem:** User creates empty repertoire, tries browse mode. No tree.json, no
internet for Lichess API.

**Solution:** Show empty state: "No candidate data available. Generate a tree or
connect to Lichess to see move suggestions." Offer "Generate" button.

### 2. Move exists in tree but not in DB

**Problem:** Generated tree has a move that Lichess DB doesn't know about (rare
line or engine-only suggestion).

**Solution:** Show it with DB columns blank, eval/ease/traps filled. Sort after
DB moves. Badge: "Engine suggestion" instead of frequency.

### 3. Transpositions

**Problem:** Two paths reach the same FEN. User adds a move at FEN X via path A.
Later reaches FEN X via path B. Is the move "in repertoire"?

**Solution:** `OpeningTree` is FEN-indexed. `hasMove(fen, san)` checks by FEN,
not by path. So yes, it shows as "in repertoire" regardless of how you got there.
PGN file may have the move under a different game — that's fine for training.

### 4. User adds move, then wants to undo

**Problem:** Accidental click adds a bad move.

**Solution:** `RepertoireWriter` maintains an undo stack (last 20 operations).
Ctrl+Z or explicit Undo button. Undo removes the move from OpeningTree + PGN.

### 5. Concurrent PGN writes (browse + auto-save from PGN editor)

**Problem:** BrowsePanel and InteractivePgnEditor both write to the same PGN file.

**Solution:** All writes go through `RepertoireWriter` which uses a serial async
queue (same pattern as EngineLifecycle). PGN editor's auto-save also routes
through the writer. No concurrent file access.

### 6. Coverage delta computation is slow

**Problem:** `CoverageService` queries Lichess API. Computing delta for 8
candidates × API call = 8 network requests per position change.

**Solution:** 
- Level 1: Use cached CoverageResult (already computed for Lines tab)
- Level 2: Heuristic delta — if this FEN is in `unaccountedMoves`, delta = that
  move's game count / root game count
- Level 3: Full recompute only on "Accept" (not on candidate display)

### 7. OpeningTree.appendLine assumes initial position

**Problem:** Current implementation always starts from `Chess.initial`. Custom
FEN repertoires (e.g., starting from a specific position) break.

**Solution:** Add `appendLineFromFen(startFen, moves)` that initializes the walk
from the given FEN. Wire browse mode to always pass `controller.startingFen`.

### 8. Large tree.json load time

**Problem:** A 10-ply deep tree with MultiPV=3 can produce ~50k nodes. Loading
and building CandidateService index takes time.

**Solution:**
- Load tree.json in a `compute()` isolate (already done for PGN parsing)
- Build FEN→node index lazily (on first lookup per FEN)
- Keep only the snapshot adapter in memory (not the full BuildTree)
- Show "Loading tree..." indicator during first load

---

## Testing Strategy

### Unit tests

| Test | Verifies |
|------|----------|
| `CandidateService.getCandidates` with tree only | Correct merge, sorting |
| `CandidateService.getCandidates` with DB only | Fallback mode works |
| `CandidateService.getCandidates` merged | Tree + DB enrichment correct |
| `RepertoireWriter.addMoveAtPosition` | OpeningTree + PGN + lines updated |
| `RepertoireWriter.addMoveAtPosition` duplicate | No-op on existing move |
| `RepertoireWriter.undo` | Reverts last add correctly |
| `RepertoireWriter.savePathAsTrainable` | [Trainable] header present |
| Transposition: same FEN via different path | `hasMove` returns true |
| `appendLineFromFen` with custom start | Nodes indexed correctly |

### Integration tests

| Test | Verifies |
|------|----------|
| Browse → tap unexplored → PGN file has new move | Full pipeline |
| Browse → tap explored → no file change | Navigate-only works |
| Browse → add → undo → PGN restored | Undo works end-to-end |
| Browse → add trainable → training screen shows it | Trainable flag respected |
| Coverage delta shown → add → delta realized | Coverage update accurate |
| No tree, Lichess available → candidates shown | DB-only fallback |
| Hover candidate row → board shows preview | BoardPreviewController.previewFen set (spec 009) |
| Mouse leave candidate → board restores | previewFen cleared |
| Hover candidate with tree data → expectimax continuation shown | Inline ClickableMoveLineWidget appears |
| Hover move in expectimax continuation → board scrubs | FEN computed and previewed |
| Hover candidate without tree data → no continuation | Graceful fallback |

### Performance targets

| Metric | Target |
|--------|--------|
| Candidates displayed after position change | < 150ms (tree), < 500ms (DB fallback) |
| One-click add → file written + UI updated | < 200ms |
| Undo → file restored + UI updated | < 200ms |
| Tree.json load (50k nodes) | < 2s (in isolate, non-blocking) |
| Coverage delta heuristic | < 50ms (no network) |

---

## UI Wireframe

```
┌─ Browse Mode ─────────────────────── Coverage: 67% ─── Gaps: 12 ─┐
│                                                                    │
│ Position: 1.e4 c5 2.Nf3 d6 (Black to move)                       │
│ ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ │
│                                                                    │
│ ▸ OPPONENT MOVES                           %    Games    W/D/B     │
│ ┌──────────────────────────────────────────────────────────────┐  │
│ │ ✓ Nf6       42%   18.2k  ████░░░░░░  ←── in repertoire      │  │
│ │   Nc6       31%   13.4k  ███░░░░░░░  +3.2% coverage         │  │
│ │   g6        12%    5.1k  ██░░░░░░░░  +1.8% coverage         │  │
│ │   e5         8%    3.4k  █░░░░░░░░░  +0.9% coverage         │  │
│ │   a6         4%    1.7k  █░░░░░░░░░  +0.4% coverage         │  │
│ └──────────────────────────────────────────────────────────────┘  │
│                                                                    │
│ ▾ Rare moves (3 more with < 1%)                                   │
│                                                                    │
│ ─────────────────────────────────────────────────────────────────  │
│ [← Back]  [↑ Root]  [Next Gap ▸ 5...a6]  [Biggest Gap ▸ 4...e5]  │
│                                                                    │
│ ┌────────────────────────────────────────────────────────────┐    │
│ │ [+ Add as Trainable Line]  [Split as Named Line...]        │    │
│ │ [Undo Last Add]                                            │    │
│ └────────────────────────────────────────────────────────────┘    │
└────────────────────────────────────────────────────────────────────┘

After navigating to OUR TURN (e.g., after 2...d6).
Hovering a candidate shows the resulting position on the board AND an inline
expectimax continuation preview below the row (spec 009):

┌─ Browse Mode ───────────────────────────────────────────────────────┐
│                                                                      │
│ Position: 1.e4 c5 2.Nf3 d6 3.? (White to move — YOUR MOVE)         │
│ ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ │
│                                                                      │
│ ▸ YOUR RESPONSE                    Eval   Ease   Traps   Source     │
│ ┌────────────────────────────────────────────────────────────────┐  │
│ │ ★ d4        +0.42   ▓▓▓▓░  3 traps   tree (repertoire move)  │  │
│ │   └ V:62% 3...cxd4 (62%) 4.Nxd4 Nf6 (87%) 5.Nc3  ← hover   │  │
│ │   Bb5+      +0.38   ▓▓▓░░  1 trap    tree                    │  │
│ │   d3        +0.25   ▓▓▓▓▓  0 traps   tree (very natural)     │  │
│ │   Bc4       +0.30   ▓▓▓░░  0 traps   DB only                 │  │
│ └────────────────────────────────────────────────────────────────┘  │
│                                                                      │
│ Clicking a move adds it as your response and advances.              │
└──────────────────────────────────────────────────────────────────────┘
```

---

## Migration Path

1. **Week 1:** `CandidateService` + `CandidateMove` model + unit tests.
   Can be tested in isolation with mock tree/DB.

2. **Week 2:** `RepertoireWriter` + undo stack + `appendMoveToExistingLine` on
   controller + `OpeningTree.hasMove` + `appendLineFromFen`. Integration tests.

3. **Week 3:** `BrowsePanel` + `CandidateRow` UI. Wire into `RepertoireScreen`
   as a new mode accessible from EvalTree tab toolbar toggle. Hover preview.

4. **Week 4:** Coverage delta heuristic. Gap navigation surfaced in browse panel.
   Trainable line support (header parsing + training screen respect). Polish,
   keyboard shortcuts, undo button.

---

## What This Enables

- **Coverage Suggestions (spec 003)** can reuse `CandidateService` and
  `RepertoireWriter` — suggestions just pre-select the "best" candidate per gap
- **Trap UI** can link "explore this trap" → browse mode at that position
- **Coherence** can be shown as an additional column in `CandidateRow`
- **Training** automatically picks up new lines (mainline from added moves)

---

## Open Questions

1. **Should browse mode replace the EvalTree tab or coexist?**  
   Recommend: coexist. EvalTree graph is still useful for visualization. Browse
   panel is the interactive "do things" view. Toggle between them.

2. **One game per line in PGN, or extend existing games?**  
   Recommend: extend existing games when possible (append to longest matching
   prefix). Create new game only when no matching prefix exists or user splits.

3. **How to handle "opponent plays rare move not in tree or DB"?**  
   Show "No data for this position. Enable engine for live analysis." with toggle.

4. **Should auto-add on opponent turn vs ask on our turn?**  
   En Croissant: always one-click add regardless of turn. Recommend same.
   The distinction is which columns are SHOWN, not which action is taken.
