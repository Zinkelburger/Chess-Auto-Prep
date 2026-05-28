# Engineering Spec: "My Ease" Metric

**Status:** Draft  
**Feature:** Measure how natural/easy each of OUR moves is to find  
**Priority:** P1 — Enables "playability" sorting and coherence tradeoffs  
**Depends on:** None (data already exists in BuildTreeNode.maiaFrequency)  
**Estimated effort:** 1 week  

---

## Problem Statement

The existing `ease` metric measures how hard it is for the **side to move** to
find a good move. At opponent nodes, this is useful (hard for them = good for
us). But at OUR nodes, high ease means the position is hard for US too.

Users want to know: "Are MY moves in this line natural and easy to remember, or
do they require precise calculation?" This determines whether a repertoire is
**practical** — not just theoretically good but actually playable under time
pressure.

The data already exists: `maiaFrequency` on our-move children tells us how
often a human would naturally find that move.

---

## Design Goals

1. **Per-position metric**: "How natural is my chosen move here?"
2. **Per-line metric**: "How playable is this entire line for me?"
3. **Combined metric**: "Position quality = easy for me + hard for opponent"
4. **Surfaced everywhere**: Browse candidates, lines browser, eval tree, sorting
5. **Zero new engine computation**: Derives entirely from existing Maia data
6. **Guides repertoire selection**: Prefer lines where MY moves are obvious

---

## Definitions

| Metric | Scope | Meaning | Range |
|--------|-------|---------|-------|
| `myEase(node)` | Single our-move node | How natural is our chosen move | [0, 1] |
| `positionQuality(node)` | Single node | Easy for us AND hard for opponent | [0, 1] |
| `linePlayability(line)` | Full line | Geometric mean of position quality | [0, 1] |
| `bottleneckPly(line)` | Full line | Ply with lowest position quality | int |

---

## Computing My Ease

### Primary signal: Maia frequency

Already stored on our-move children during tree build:

```
tree_build_service.dart line 448-451:
  child.moveProbability = 1.0;
  child.cumulativeProbability = node.cumulativeProbability;
  child.maiaFrequency = prob;  // ← THIS IS THE KEY DATA
```

`maiaFrequency` ∈ [0, 1] = probability that Maia (a human-like neural net)
would play this move. High value = humans naturally find it = easy for us.

### Formula

```dart
double computeMyEase(BuildTreeNode ourMoveNode) {
  // Primary: Maia probability of the repertoire move
  double ease = ourMoveNode.maiaFrequency;

  // Modifier 1: Only-move bonus
  // If the engine gap to the second-best move is huge, it's "forced" = easy
  if (_isOnlyMove(ourMoveNode)) {
    ease = 1.0; // Forced move — nothing to remember
  }

  // Modifier 2: Precision penalty
  // If Maia prob is very low but it's the engine best, it requires calculation
  if (ease < 0.15 && _isEngineBest(ourMoveNode)) {
    ease = ease.clamp(0.0, 0.5); // Cap: requires finding a non-obvious move
  }

  // Modifier 3: Recapture / obvious trade bonus
  // (Optional: detect if move is a recapture on same square as last move)

  return ease.clamp(0.0, 1.0);
}

bool _isOnlyMove(BuildTreeNode node) {
  // Check parent: if parent has MultiPV data and gap to #2 > 200cp
  final parent = node.parent;
  if (parent == null || parent.children.length < 2) return true;
  final sorted = parent.children.toList()
    ..sort((a, b) => (b.engineEvalCp ?? 0).compareTo(a.engineEvalCp ?? 0));
  if (sorted.length < 2) return true;
  final gap = (sorted[0].engineEvalCp ?? 0) - (sorted[1].engineEvalCp ?? 0);
  return gap.abs() > 200;
}
```

### Position Quality (combined)

```dart
double computePositionQuality(
  BuildTreeNode node,
  bool playAsWhite,
) {
  // At opponent-to-move nodes: existing ease tells us how hard it is for them
  // At our-move nodes: myEase tells us how easy it is for us
  //
  // Position quality combines BOTH perspectives at a node:
  // "My move was easy" (from parent's our-move child) ×
  // "Their response is hard" (from this node's ease)

  final isOurMove = (node.isWhiteToMove == playAsWhite);

  if (isOurMove) {
    // We are about to move. Quality = how natural is our best move here
    final bestChild = _findRepertoireChild(node) ?? _findBestChild(node);
    if (bestChild == null) return 0.5; // leaf
    return computeMyEase(bestChild);
  } else {
    // Opponent is about to move. Quality = how hard is it for THEM
    // Use existing ease (inverted: high ease = hard for mover = good for us)
    return 1.0 - (node.ease ?? 0.5);
  }
}
```

### Line Playability

```dart
class LinePlayability {
  final double playability;      // Geometric mean of position quality
  final double bottleneckQuality; // Minimum position quality in line
  final int bottleneckPly;       // Ply index of the hardest position
  final int easyMoveCount;       // Moves with myEase > 0.7
  final int hardMoveCount;       // Moves with myEase < 0.3
}

LinePlayability computeLinePlayability(
  List<BuildTreeNode> linePath,
  bool playAsWhite,
) {
  final qualities = <double>[];
  double minQuality = 1.0;
  int minPly = 0;
  int easy = 0, hard = 0;

  for (var i = 0; i < linePath.length; i++) {
    final node = linePath[i];
    final isOurMove = (node.isWhiteToMove == playAsWhite);

    if (isOurMove) {
      final quality = computePositionQuality(node, playAsWhite);
      qualities.add(quality);

      if (quality < minQuality) {
        minQuality = quality;
        minPly = i;
      }
      if (quality > 0.7) easy++;
      if (quality < 0.3) hard++;
    }
  }

  if (qualities.isEmpty) {
    return LinePlayability(playability: 0.5, bottleneckQuality: 0.5, ...);
  }

  // Geometric mean
  final logSum = qualities.map((q) => log(q.clamp(0.01, 1.0))).reduce((a, b) => a + b);
  final geoMean = exp(logSum / qualities.length);

  return LinePlayability(
    playability: geoMean.clamp(0.0, 1.0),
    bottleneckQuality: minQuality,
    bottleneckPly: minPly,
    easyMoveCount: easy,
    hardMoveCount: hard,
  );
}
```

---

## Implementation

### File: `lib/services/generation/tree_my_ease.dart` (NEW)

Post-processing pass that computes `myEase` on all our-move nodes in the tree.
Runs after `calculateTreeEase` in Phase 2.

```dart
/// Compute my-ease for all our-move nodes in the tree.
/// Runs as a post-processing pass on the built tree.
void calculateMyEase(BuildTree tree, {required bool playAsWhite}) {
  tree.walkBFS((node) {
    final isOurMove = (node.isWhiteToMove == playAsWhite);
    if (!isOurMove) return; // Only compute for our-move nodes' children

    for (final child in node.children) {
      child.myEase = computeMyEase(child);
    }
  });
}
```

### File: `lib/models/build_tree_node.dart` (MODIFY)

```dart
class BuildTreeNode {
  // ... existing fields ...
  double myEase = -1.0; // -1 = not computed

  // Add to serialization
  Map<String, dynamic> toJson() => {
    ...existing...,
    if (myEase >= 0) 'my_ease': myEase,
  };

  factory BuildTreeNode.fromJson(Map<String, dynamic> json) {
    return BuildTreeNode(...)
      ..myEase = (json['my_ease'] as num?)?.toDouble() ?? -1.0;
  }
}
```

### File: `lib/features/eval_tree/eval_tree_snapshot_adapter.dart` (MODIFY)

```dart
// Add myEase to EvalTreeNodeSnapshot
class EvalTreeNodeSnapshot {
  // ... existing fields ...
  final double? myEase;
}

// In adapter:
EvalTreeNodeSnapshot _adaptNode(BuildTreeNode node) {
  return EvalTreeNodeSnapshot(
    ...existing...,
    myEase: node.myEase >= 0 ? node.myEase : null,
  );
}
```

### File: `lib/features/eval_tree/services/eval_tree_line_metrics.dart` (MODIFY)

```dart
class EvalTreeLineMetrics {
  // ... existing: subtreeTrapCount, expectedEaseDeep ...
  final double? linePlayability;
  final double? bottleneckQuality;
  final int? bottleneckPly;
}

// In buildCandidateRows sorting (our turn):
// Add myEase as a sort factor for candidates
rows.sort((a, b) {
  if (a.node.isRepertoireMove != b.node.isRepertoireMove) {
    return a.node.isRepertoireMove ? -1 : 1;
  }
  // NEW: sort by myEase when available
  final aEase = a.node.myEase ?? 0.5;
  final bEase = b.node.myEase ?? 0.5;
  return bEase.compareTo(aEase); // Higher ease first
});
```

### Integration into generation pipeline

In `repertoire_generation_tab.dart`, Phase 2 pipeline:

```dart
// After existing ease + expectimax:
await calculateTreeEase(tree, playAsWhite: config.playAsWhite);
ecaCalc.calculate(tree);
ecaCalc.computeTrapScores(tree);

// NEW: compute my-ease
calculateMyEase(tree, playAsWhite: config.playAsWhite);

// Then repertoire selection, line extraction, etc.
```

---

## UI Surfaces

### 1. Browse mode candidates (spec 002)

On our-turn rows, show "My ease" as a visual bar:

```
│ ★ d4     +0.42   ▓▓▓▓░  3 traps   (natural: 82%)    │
│   Bb5+   +0.38   ▓▓▓░░  1 trap    (natural: 45%)    │
│   d3     +0.25   ▓▓▓▓▓  0 traps   (natural: 91%)    │
```

"Natural: 91%" means Maia gives 91% probability to this move — almost everyone
would find it without thinking.

### 2. Lines browser

New sort option: "Playability" — sorts by `linePlayability`.
Badge on lines with low playability: "Hard line — 2 precise moves required"

### 3. Eval Tree explorer

Column "My ease" on our-turn candidate rows (replaces or supplements existing
sort).

### 4. Coverage suggestions (spec 006)

`linePlayability` feeds into the suggestion scoring formula. Preset "Playable"
weights ease at 0.5.

### 5. Training priority

Lines with low playability should be drilled MORE (they need memorization).
`RepertoireReviewService` can weight review frequency by inverse playability.

### 6. Repertoire selection (generation)

When auto-selecting repertoire lines, add `myEase` as an optional factor:

```dart
// In RepertoireSelector, when choosing between siblings at our-move nodes:
double childScore(BuildTreeNode child, SelectionMode mode) {
  switch (mode) {
    case SelectionMode.expectimax:
      return child.expectimaxValue;
    case SelectionMode.engineOnly:
      return winProbability(child.engineEvalCp);
    case SelectionMode.playable: // NEW
      return child.expectimaxValue * 0.6 + (child.myEase) * 0.4;
  }
}
```

---

## The "Dream Sort"

The killer feature: sort lines by a combined score:

```
dreamScore(line) = linePlayability × (1 - avgOpponentEase) × expectimax × trapBonus

Where:
  linePlayability = my moves are natural (high = good)
  (1 - avgOpponentEase) = opponent moves are hard (high = good)
  expectimax = position is objectively good (high = good)
  trapBonus = 1 + 0.1 * trapCount (traps are a bonus)
```

Lines that score high on ALL dimensions are "perfect" — easy for you, hard for
them, objectively good, and trappy. These are the lines to play.

---

## Edge Cases

### 1. No Maia data available (maiaFrequency = 0)

**Solution:** If maiaFrequency is 0 or not computed (generation without Maia),
`myEase` defaults to 0.5 (neutral). Display "Maia data unavailable" in UI.

### 2. Repertoire move was not in the tree (manually added)

**Solution:** For moves added via browse mode that aren't in the BuildTree,
`myEase` can be computed on-demand: look up the FEN in Maia (if available) or
default to 0.5. Store result in EvalCache for next time.

### 3. Line with only one our-move (very short)

**Solution:** `linePlayability` degrades gracefully — geometric mean of one
value is just that value. Display normally.

### 4. All moves have similar ease (flat line)

**Solution:** This is valid information — "This line is uniformly natural" or
"uniformly hard." No special handling needed.

---

## Testing Strategy

| Test | Verifies |
|------|----------|
| `computeMyEase` with maiaFrequency 0.8 | Returns ~0.8 |
| `computeMyEase` forced move (only move) | Returns 1.0 |
| `computeMyEase` low Maia, engine best | Capped at 0.5 |
| `computePositionQuality` our turn | Uses myEase |
| `computePositionQuality` opponent turn | Uses (1 - ease) |
| `computeLinePlayability` with 5 positions | Correct geometric mean |
| `bottleneckPly` correct | Finds minimum quality position |
| Serialization round-trip | myEase preserved in tree.json |
| Sort by playability | Most playable lines first |

### Performance targets

| Metric | Target |
|--------|--------|
| `calculateMyEase` on 10k node tree | < 50ms (simple field access per node) |
| `computeLinePlayability` for one line | < 1ms |
| Sort 500 lines by playability | < 10ms |

---

## Migration Path

1. **Add `myEase` field to BuildTreeNode** (1 day): Field + serialization.
   Backward compatible (defaults to -1.0).
2. **`tree_my_ease.dart` post-pass** (1 day): Compute on all our-move children.
   Wire into Phase 2 pipeline.
3. **EvalTreeSnapshot adapter** (0.5 day): Expose myEase in snapshot.
4. **Explorer column + sort** (1 day): Show in RepertoireTreeExplorer.
5. **Line playability** (1 day): Compute per-line, expose in lines browser.
6. **Dream sort** (0.5 day): Combined score, sort option in lines browser.
7. **Selection mode** (0.5 day): Add `SelectionMode.playable`.
