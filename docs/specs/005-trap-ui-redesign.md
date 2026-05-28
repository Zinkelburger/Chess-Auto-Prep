# Engineering Spec: Trap UI Redesign

**Status:** Draft  
**Feature:** Intuitive trap presentation, fast-forward navigation, line badges  
**Priority:** P1 — Unique differentiator, data already exists  
**Depends on:** 002-browse-mode (trap integration into browse), 003-layout (zone placement), 009-expectimax-lines-panel (hover preview system)  
**Estimated effort:** 2-3 weeks  

---

## Problem Statement

The Traps tab currently shows a **dense numeric table** — trap score, surplus,
eval diff, reach probability — that requires expertise to interpret. The user
sees 42 traps but can't quickly answer:

- "What actually happens at this trap? What's the story?"
- "How many traps are in the line I'm studying?"
- "Take me to the next interesting position — skip the boring moves"
- "How trappy is my repertoire overall?"

All data is already computed (TrapLineInfo has 12 fields per trap). The problem
is purely presentation and navigation.

---

## Design Goals

1. **Narrative over numbers**: Lead with "Opponent plays X (Y% of the time) and
   loses Z centipawns" not "trapScore: 0.41"
2. **One-click navigation**: Fast-forward to traps in current line
3. **At-a-glance density**: See trap count per line without opening the trap tab
4. **Probability context**: Show HOW LIKELY the trap is to actually fire
5. **Full opponent response table**: Not just popular vs best — ALL replies
6. **Zero new computation**: Everything derives from existing TrapLineInfo +
   BuildTreeNode data

---

## Data Model Extension

### Extended TrapLineInfo

Add fields captured at extraction time (currently available on BuildTreeNode
but not persisted in TrapLineInfo):

```dart
class TrapLineInfo {
  // --- Existing fields (all kept) ---
  final List<String> movesSan;
  final double trapScore;
  final double popularProb;
  final String popularMove;
  final String bestMove;
  final int popularEvalCp;
  final int bestEvalCp;
  final int evalDiffCp;
  final double cumulativeProb;
  final double trickSurplus;
  final double expectimaxValue;
  final double wpEval;

  // --- NEW fields ---
  final String fen;                    // FEN at trap position
  final String? openingName;           // e.g. "Caro-Kann Advance"
  final int positionEvalCp;            // Eval at node before any reply
  final List<TrapReply> allReplies;    // All opponent responses
}

/// One possible opponent reply at a trap position.
class TrapReply {
  final String san;
  final double probability;     // moveProbability from Maia/Lichess
  final int evalAfterCp;        // Eval after this move (our perspective)
  final TrapReplyClass classification;
}

enum TrapReplyClass {
  blunder,    // evalDiff >= 200cp from best
  mistake,    // evalDiff >= 100cp
  inaccuracy, // evalDiff >= 50cp
  acceptable, // evalDiff >= 20cp
  good,       // evalDiff < 20cp (includes best move)
}
```

### Changes to TrapExtractor

In `_collectTraps()`, after identifying a trap candidate:

```dart
// Capture all children for rich display
final allReplies = node.children.map((child) {
  final evalAfter = child.engineEvalCp != null
      ? (playAsWhite ? child.engineEvalCp! : -child.engineEvalCp!)
      : 0;
  final diffFromBest = bestEvalForUs - evalAfter;
  return TrapReply(
    san: child.moveSan,
    probability: child.moveProbability,
    evalAfterCp: evalAfter,
    classification: _classify(diffFromBest),
  );
}).toList()
  ..sort((a, b) => b.probability.compareTo(a.probability));

candidates.add(_TrapCandidate(
  // ... existing fields ...
  fen: node.fen,
  openingName: node.openingName,
  positionEvalCp: evalUs,
  allReplies: allReplies,
));
```

### JSON serialization update

Add `fen`, `opening_name`, `position_eval_cp`, `all_replies` to
`*_traps.json`. Backward compatible: old files without these fields load with
null values; UI falls back to showing only popular + best.

---

## Feature 1: Trap Detail Card

### Purpose

Replace the current expandable panel with a rich, narrative presentation of
what happens at a trap position.

### Layout

```
┌─ Trap #7 ─────────────────────────── Caro-Kann Advance ──────────┐
│                                                                    │
│ After 1.e4 c6 2.d4 d5 3.e5 Bf5 4.Nf3 e6 5.Be2                   │
│                                                                    │
│ ┌──────────────────────────────────────────────────────────────┐  │
│ │  Opponent is tempted to play ...Nd7                           │  │
│ │  41% of humans choose this move                              │  │
│ └──────────────────────────────────────────────────────────────┘  │
│                                                                    │
│  ┌─ HUMAN MOVE ──────────┐     ┌─ BEST MOVE ──────────────┐      │
│  │ ...Nd7                 │     │ ...b4                     │      │
│  │ Eval: +2.52 (for you) │     │ Eval: +0.10 (equal)       │      │
│  │ Probability: 41%       │     │ Probability: 12%          │      │
│  │ ❌ BLUNDER             │     │ ✓ BEST                    │      │
│  └────────────────────────┘     └───────────────────────────┘      │
│                                                                    │
│  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━  │
│  YOU GAIN: +242cp    REACH: 0.13%    SURPLUS: 8.3%                │
│  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━  │
│                                                                    │
│  ALL OPPONENT RESPONSES:                                           │
│  ┌─────────────────────────────────────────────────────────────┐  │
│  │ Move    │ Prob │ Eval (you) │ Class        │ Status         │  │
│  │─────────│──────│────────────│──────────────│────────────────│  │
│  │ ...Nd7  │ 41%  │ +2.52      │ BLUNDER      │ trap fires     │  │
│  │ ...Ne7  │ 23%  │ +0.45      │ INACCURACY   │ slight edge    │  │
│  │ ...b4   │ 12%  │ +0.10      │ BEST         │ equal          │  │
│  │ ...c5   │  9%  │ +0.30      │ ACCEPTABLE   │ small edge     │  │
│  │ ...h6   │  8%  │ +0.80      │ MISTAKE      │ clear edge     │  │
│  │ other   │  7%  │ ~+0.50     │ —            │ —              │  │
│  └─────────────────────────────────────────────────────────────┘  │
│                                                                    │
│  Practical win prob: 59.3%  vs  Raw eval: 51.0%                   │
│  "This position performs 8.3% better in practice than eval shows"  │
│                                                                    │
│  [Show Refutation ▸]  [How Do I Get Here?]  [Train This Line]     │
└────────────────────────────────────────────────────────────────────┘
```

### Widget: `lib/widgets/traps/trap_detail_card.dart`

```dart
class TrapDetailCard extends StatelessWidget {
  final TrapLineInfo trap;
  final VoidCallback? onShowRefutation;
  final VoidCallback? onShowPath;
  final VoidCallback? onTrainLine;
  final BoardPreviewController boardPreview;  // NEW (spec 009)

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildHeader(),        // Trap # + opening name
            _buildMovePath(),      // Move sequence — hoverable (spec 009)
            _buildNarrative(),     // "Opponent tempted to play..."
            _buildComparison(),    // Side-by-side human vs best — hoverable
            _buildStatRow(),       // Gain, reach, surplus
            _buildRepliesTable(),  // All opponent responses — hoverable
            _buildWinProbLine(),   // Practical vs raw
            _buildActions(),       // Refutation, path, train buttons
          ],
        ),
      ),
    );
  }

  /// Move path rendered as a hoverable ClickableMoveLineWidget (spec 009).
  /// Hovering any move in the path previews that position on the board.
  Widget _buildMovePath() {
    return ClickableMoveLineWidget(
      sanMoves: trap.movesSan,
      startPly: 0,
      maxMoves: trap.movesSan.length,
      onMoveTapped: (idx) => /* navigate to this position */,
      onMoveHovered: (idx) {
        final fen = fenAfterMoves(Chess.initial.fen, trap.movesSan, idx);
        boardPreview.setPreview(fen);
      },
      onHoverExit: () => boardPreview.clearPreview(),
    );
  }

  /// Reply rows in the ALL OPPONENT RESPONSES table are hover-enabled.
  /// Hovering a reply move (e.g. ...Nd7) previews the position AFTER
  /// that reply on the board.
  Widget _buildReplyRow(TrapReply reply) {
    return MouseRegion(
      onEnter: (_) {
        if (trap.fen != null) {
          final fen = playMove(trap.fen!, reply.san);
          if (fen != null) boardPreview.setPreview(fen);
        }
      },
      onExit: (_) => boardPreview.clearPreview(),
      child: /* existing reply row content */,
    );
  }
}
```

### When shown

- **Traps tab**: Replaces current expanded detail panel on tap
- **Browse mode**: Shown in context zone when current position is a trap
- **Eval bar**: Shown when tapping the trap indicator label
- **Fast-forward landing**: Auto-shown when jumping to a trap position

---

## Feature 2: Trap Fast-Forward Navigation

### Board Toolbar Buttons

```dart
class TrapNavigationButtons extends StatelessWidget {
  final TrapIndexService trapIndex;
  final RepertoireController controller;

  @override
  Widget build(BuildContext context) {
    final trapsInLine = trapIndex.trapsInCurrentLine(
      controller.currentMoveSequence,
    );
    final currentPly = controller.currentMoveIndex;
    final currentTrapIdx = _findCurrentTrapIndex(trapsInLine, currentPly);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Previous trap button
        IconButton(
          icon: const Icon(Icons.skip_previous),
          color: Colors.orange,
          tooltip: 'Previous trap (Shift+←)',
          onPressed: currentTrapIdx > 0
              ? () => _jumpToTrap(trapsInLine[currentTrapIdx - 1])
              : null,
        ),
        // Trap position counter
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: Colors.orange.withOpacity(0.1),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            '${currentTrapIdx + 1}/${trapsInLine.length}',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
        // Next trap button
        IconButton(
          icon: const Icon(Icons.skip_next),
          color: Colors.orange,
          tooltip: 'Next trap (Shift+→)',
          onPressed: currentTrapIdx < trapsInLine.length - 1
              ? () => _jumpToTrap(trapsInLine[currentTrapIdx + 1])
              : null,
        ),
      ],
    );
  }

  void _jumpToTrap(TrapLineInfo trap) {
    controller.loadMoveSequence(trap.movesSan);
    // Emit event → TrapDetailCard shows for this trap
  }
}
```

### Keyboard shortcuts

| Shortcut | Action |
|----------|--------|
| Shift+→ | Jump to next trap in current line |
| Shift+← | Jump to previous trap |
| T | Toggle trap detail card visibility |

### Walkthrough mode

"Start Tour" button at top of Traps tab.

**Hover preview in walkthrough (spec 009):** When the walkthrough shows a list
of upcoming traps (sidebar or bottom strip), hovering a trap in the list
previews that trap's position on the board without committing navigation.
Clicking the trap commits (loads the move sequence). This lets users skim
through traps visually before deciding which to study.

```dart
class TrapWalkthrough extends StatefulWidget { ... }

class _TrapWalkthroughState extends State<TrapWalkthrough> {
  int _currentIndex = 0;
  TrapSortMode _sortMode = TrapSortMode.surplus;
  final BoardPreviewController boardPreview;  // NEW (spec 009)

  void _next() {
    if (_currentIndex < _sortedTraps.length - 1) {
      _currentIndex++;
      _loadCurrentTrap();
    }
  }

  void _prev() {
    if (_currentIndex > 0) {
      _currentIndex--;
      _loadCurrentTrap();
    }
  }

  void _loadCurrentTrap() {
    final trap = _sortedTraps[_currentIndex];
    widget.controller.loadMoveSequence(trap.movesSan);
    // Board animates to position, detail card shows
  }

  /// Hover a trap in the upcoming-traps list → preview its position (spec 009)
  void _onTrapHovered(int index) {
    final trap = _sortedTraps[index];
    if (trap.fen != null) {
      boardPreview.setPreview(trap.fen!);
    }
  }

  void _onTrapHoverExit() {
    boardPreview.clearPreview();
  }
}
```

---

## Feature 3: Trap Index Service

### File: `lib/services/trap_index_service.dart` (NEW)

```dart
/// Pre-indexed trap lookups for O(1) position and line queries.
/// Built once on trap file load, invalidated on regeneration.
class TrapIndexService {
  final List<TrapLineInfo> _traps;

  // Position lookup: is this FEN a trap?
  late final Map<String, TrapLineInfo> _fenIndex;

  // Line lookup: which traps are in a given line?
  late final Map<String, List<TrapLineInfo>> _prefixIndex;

  // Aggregate metrics
  late final TrapRepertoireMetrics metrics;

  TrapIndexService(this._traps) {
    _buildFenIndex();
    _buildPrefixIndex();
    _computeMetrics();
  }

  /// Is the current position a trap? Returns trap info or null.
  TrapLineInfo? trapAtFen(String fen) => _fenIndex[fen];

  /// All traps whose movesSan is a prefix of the given line.
  List<TrapLineInfo> trapsInLine(List<String> lineMoves) {
    // Walk through traps, check if movesSan is prefix of lineMoves
    return _traps.where((t) =>
      t.movesSan.length <= lineMoves.length &&
      _isPrefix(t.movesSan, lineMoves)
    ).toList()
      ..sort((a, b) => a.movesSan.length.compareTo(b.movesSan.length));
  }

  /// Traps reachable from current position in current line.
  List<TrapLineInfo> trapsInCurrentLine(List<String> currentPath) {
    return trapsInLine(currentPath);
  }

  /// Per-line metrics for the lines browser.
  TrapLineMetrics metricsForLine(List<String> lineMoves) {
    final traps = trapsInLine(lineMoves);
    if (traps.isEmpty) return TrapLineMetrics.empty;
    return TrapLineMetrics(
      count: traps.length,
      bestEvalDiff: traps.map((t) => t.evalDiffCp).reduce(max),
      totalReach: traps.map((t) => t.cumulativeProb).reduce((a, b) => a + b),
      expectedTrapValue: traps.map((t) =>
        t.cumulativeProb * t.popularProb * t.evalDiffCp
      ).reduce((a, b) => a + b),
    );
  }

  void _buildFenIndex() {
    _fenIndex = {};
    for (final trap in _traps) {
      if (trap.fen != null) _fenIndex[trap.fen!] = trap;
    }
  }

  void _computeMetrics() {
    metrics = TrapRepertoireMetrics(
      totalTraps: _traps.length,
      highQualityCount: _traps.where((t) => t.trickSurplus > 0.10).length,
      avgReach: _traps.isEmpty ? 0 :
        _traps.map((t) => t.cumulativeProb).reduce((a, b) => a + b) / _traps.length,
      avgEvalGain: _traps.isEmpty ? 0 :
        _traps.map((t) => t.evalDiffCp).reduce((a, b) => a + b) / _traps.length,
      expectedTrapValue: _traps.map((t) =>
        t.cumulativeProb * t.popularProb * t.evalDiffCp
      ).reduce((a, b) => a + b),
    );
  }
}

class TrapLineMetrics {
  final int count;
  final int bestEvalDiff;
  final double totalReach;
  final double expectedTrapValue;
  static const empty = TrapLineMetrics(count: 0, bestEvalDiff: 0, totalReach: 0, expectedTrapValue: 0);
}

class TrapRepertoireMetrics {
  final int totalTraps;
  final int highQualityCount;
  final double avgReach;
  final double avgEvalGain;
  final double expectedTrapValue; // ETV: expected cp gain from traps per game
}
```

---

## Feature 4: Line Trap Badges

### Lines browser integration

In `RepertoireLinesBrowser`, each line row gets:

```dart
// In line row builder:
final trapMetrics = trapIndex.metricsForLine(line.moves);

Row(
  children: [
    // ... existing content ...
    if (trapMetrics.count > 0) ...[
      Container(
        padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: Colors.orange.withOpacity(0.15),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          '${trapMetrics.count} trap${trapMetrics.count > 1 ? 's' : ''}',
          style: TextStyle(fontSize: 11, color: Colors.orange),
        ),
      ),
      Text(
        '+${trapMetrics.bestEvalDiff}cp',
        style: TextStyle(fontSize: 11, color: Colors.green),
      ),
    ],
  ],
)
```

New sort options: trap count, best trap quality, ETV.

### PGN editor integration

In `InteractivePgnEditor`, moves preceding trap positions get an orange dot:

```dart
Widget _buildMoveWidget(PgnMove move, int plyIndex) {
  final isPreTrap = trapIndex.trapAtFen(_fenAfterMove(plyIndex)) != null;

  return Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      if (isPreTrap)
        Container(
          width: 6, height: 6,
          margin: EdgeInsets.only(right: 2),
          decoration: BoxDecoration(
            color: Colors.orange,
            shape: BoxShape.circle,
          ),
        ),
      // ... existing move text widget ...
    ],
  );
}
```

Tooltip on hover shows: "After this move: 41% play Nd7 (blunder, +242cp)"

**Board preview on hover (spec 009):** In addition to the tooltip, hovering a
trap-dotted move previews the **trap position** on the board via
`BoardPreviewController`. The user sees the critical position without clicking,
matching the Lichess hover-to-preview pattern across all move displays.

---

## Feature 5: Repertoire Trap Summary

Top of Traps tab (above the list/walkthrough):

```dart
class TrapSummaryHeader extends StatelessWidget {
  final TrapRepertoireMetrics metrics;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _Stat(value: '${metrics.totalTraps}', label: 'Total traps'),
                _Stat(value: '${metrics.highQualityCount}', label: 'High quality'),
                _Stat(value: '${(metrics.avgReach * 100).toStringAsFixed(2)}%', label: 'Avg reach'),
                _Stat(value: '+${metrics.avgEvalGain.round()}cp', label: 'Avg gain'),
              ],
            ),
            const Divider(),
            Row(
              children: [
                Text('Expected Trap Value: '),
                Text(
                  '+${metrics.expectedTrapValue.toStringAsFixed(1)} cp/game',
                  style: TextStyle(fontWeight: FontWeight.bold, color: Colors.green),
                ),
                Tooltip(
                  message: 'Average centipawns gained per game from opponent blunders at trap positions',
                  child: Icon(Icons.info_outline, size: 14),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
```

---

## Edge Cases

### 1. No tree.json → no FEN on legacy trap files

**Solution:** If `trap.fen` is null (old format), FEN index skips it. Fast-
forward still works via movesSan path matching. Detail card shows "FEN
unavailable" for all-replies table.

### 2. Trap position reached via different move order (transposition)

**Solution:** FEN index handles this — same FEN regardless of path. Multiple
TrapLineInfo entries may share a FEN if the tree finds the position via
different paths. Show the one with higher trick surplus.

### 3. Very long trap list (200 traps)

**Solution:** Walkthrough mode handles sequential access. List view uses
`ListView.builder` (already virtualized). Summary + top-5 table provides
overview without scrolling all 200.

### 4. Line has no traps

**Solution:** Badge simply not shown. Fast-forward buttons disabled. Toolbar
shows "0 traps in this line" greyed out.

---

## Testing Strategy

| Test | Verifies |
|------|----------|
| TrapIndexService with 50 traps | FEN index, prefix matching correct |
| trapsInLine with transpositions | Same FEN found regardless of path |
| TrapDetailCard with full allReplies | All rows rendered, sorted by prob |
| TrapDetailCard with null allReplies (legacy) | Falls back to popular + best only |
| Fast-forward next/prev | Correct ply indices, wraps at boundaries |
| Line badge computation | Count, bestEvalDiff, ETV correct |
| PGN dot markers | Dots appear only on pre-trap moves |
| ETV calculation | Matches manual formula |
| Walkthrough sort change | Re-sorts and navigates to new first trap |
| Hover trap detail move path → board previews | BoardPreviewController.previewFen set (spec 009) |
| Hover reply row (e.g. ...Nd7) → board shows reply position | Preview after opponent move |
| Mouse leave trap card → board restores | previewFen cleared |
| Hover trap in walkthrough list → board previews trap FEN | Preview without commit |
| Click trap in walkthrough → board navigates (commit) | loadMoveSequence called |
| Hover PGN trap dot → board previews trap position | Spec 009 hover system |

---

## Migration Path

1. **Extend TrapLineInfo + extractor** (2 days): Add new fields, update JSON.
   Backward compatible loading.
2. **TrapIndexService** (1 day): Build index, expose metrics.
3. **TrapDetailCard widget** (2 days): Rich narrative UI.
4. **Fast-forward navigation** (2 days): Toolbar buttons, keyboard shortcuts.
5. **Line badges** (1 day): Lines browser + PGN editor dots.
6. **Summary header + ETV** (1 day): Top of traps tab.
7. **Walkthrough mode** (2 days): Tour UI with prev/next/sort.
