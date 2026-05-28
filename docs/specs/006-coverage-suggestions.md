# Engineering Spec: Coverage Suggestions

**Status:** Draft  
**Feature:** "Add these N lines to reach X% coverage" with ranked suggestions  
**Priority:** P1 — Makes repertoire completion trivially easy  
**Depends on:** 002-browse-mode (RepertoireWriter, CandidateService), 007-my-ease, 009-expectimax-lines-panel (hover preview system)  
**Estimated effort:** 2.5-3 weeks  

---

## Problem Statement

The Coverage service already identifies gaps (TooShallow, Unaccounted positions
with their game counts). The Lines tab has "Next Gap" / "Biggest Gap" buttons.
But there's no **"here are the best lines to fill your gaps — click Accept"**
workflow. The user has to:

1. Click "Next Gap" → taken to a position
2. Figure out what to play there (no suggestions)
3. Manually add moves in PGN editor
4. Repeat for every gap

This should be: "You're at 62% coverage. Here are 5 lines that get you to 75%.
Accept the ones you like."

---

## Design Goals

1. **Target-based**: User sets a coverage target (e.g., 75%), system finds
   minimum lines to reach it
2. **Ranked by quality**: Not just "biggest gap first" but weighted by eval,
   ease, coherence, and trap potential
3. **Preview before accept**: User can see the full line, board preview, and
   metrics before committing
4. **Incremental**: Each accepted line updates coverage in real-time; remaining
   suggestions re-rank
5. **Works with and without generated tree**: Tree provides deep candidates;
   without tree, use DB + shallow search

---

## Architecture

### Pipeline

```
CoverageResult (existing)
  │
  ├── .tooShallowLeaves: positions where repertoire ends too early
  ├── .unaccountedMoves: popular opponent moves not in repertoire
  └── .coveredLeaves: positions fully prepared
       │
       ▼
┌────────────────────────┐
│ GapCollector           │  ← Existing data, just needs to be sorted
│ Sort by game count     │
│ Produce GapCandidate[] │
└────────┬───────────────┘
         │
         ▼
┌────────────────────────┐
│ LineResolver           │  ← Find best continuation for each gap
│ - Check BuildTree      │
│ - Fallback: DB lookup  │
│ - Fallback: shallow SF │
└────────┬───────────────┘
         │
         ▼
┌────────────────────────┐
│ SuggestionScorer       │  ← Multi-objective scoring
│ score = f(impact,      │
│   eval, ease, traps)   │
└────────┬───────────────┘
         │
         ▼
┌────────────────────────┐
│ GreedySetCover         │  ← Pick N lines reaching target %
│ Maximize marginal gain │
│ Remove overlap         │
└────────┬───────────────┘
         │
         ▼
┌────────────────────────┐
│ SuggestionPanel UI     │  ← Present, preview, accept/reject
└────────────────────────┘
```

### Data Flow

```dart
/// A gap in the repertoire that needs filling.
class GapCandidate {
  final List<String> pathToGap;      // Moves from root to gap position
  final String fen;                  // FEN at gap
  final GapType type;                // tooShallow | unaccounted
  final int gameCount;               // How many master games reach here
  final double coverageImpact;       // Estimated % gain if filled
  final String? opponentMove;        // The specific unaccounted move (if type == unaccounted)
}

enum GapType { tooShallow, unaccounted }

/// A suggested line to fill a gap.
class SuggestedLine {
  final GapCandidate gap;            // Which gap this fills
  final List<String> fullMoves;      // Complete move sequence (root to leaf)
  final List<String> newMoves;       // Only the moves beyond current repertoire
  final double coverageGain;         // Actual % gain (may differ from estimate)
  final double score;                // Composite quality score
  final String source;               // 'tree' | 'db' | 'engine'

  // Quality metrics
  final int? leafEvalCp;             // Eval at end of suggested line
  final double? linePlayability;     // My ease metric (spec 007)
  final int trapCount;               // Traps in suggested line
  final double? coherenceBonus;      // How well this fits existing repertoire
}
```

---

## Implementation

### File: `lib/services/coverage_suggestion_service.dart` (NEW)

```dart
class CoverageSuggestionService {
  final CoverageResult _coverage;
  final BuildTree? _tree;
  final OpeningTree _openingTree;
  final LichessExplorerApi _lichessApi;
  final EvalCache _evalCache;

  /// Generate suggestions to reach target coverage.
  /// Returns sorted suggestions (best first).
  Future<List<SuggestedLine>> generateSuggestions({
    required double targetCoverage,
    required bool playAsWhite,
    SuggestionWeights weights = const SuggestionWeights(),
    int maxSuggestions = 10,
  }) async {
    // 1. Collect and sort gaps
    final gaps = _collectGaps();

    // 2. Resolve line for each gap
    final candidates = await _resolveLines(gaps, playAsWhite);

    // 3. Score each candidate
    final scored = _scoreAll(candidates, weights);

    // 4. Greedy set cover to target
    final selected = _greedySelect(scored, targetCoverage, maxSuggestions);

    return selected;
  }

  List<GapCandidate> _collectGaps() {
    final gaps = <GapCandidate>[];

    // From unaccounted moves (most impactful)
    for (final um in _coverage.unaccountedMoves) {
      gaps.add(GapCandidate(
        pathToGap: um.parentPath,
        fen: um.fen,
        type: GapType.unaccounted,
        gameCount: um.gameCount,
        coverageImpact: um.gameCount / _coverage.rootGameCount,
        opponentMove: um.moveSan,
      ));
    }

    // From too-shallow leaves
    for (final leaf in _coverage.tooShallowLeaves) {
      gaps.add(GapCandidate(
        pathToGap: leaf.path,
        fen: leaf.fen,
        type: GapType.tooShallow,
        gameCount: leaf.gameCount,
        coverageImpact: leaf.estimatedGain,
      ));
    }

    // Sort by game count descending (most common gaps first)
    gaps.sort((a, b) => b.gameCount.compareTo(a.gameCount));
    return gaps;
  }

  /// Find the best continuation for a gap.
  Future<SuggestedLine?> _resolveOneGap(
    GapCandidate gap,
    bool playAsWhite,
  ) async {
    // Strategy 1: Look in BuildTree
    if (_tree != null) {
      final treeLine = _findTreePath(gap);
      if (treeLine != null) return treeLine;
    }

    // Strategy 2: Follow DB popularity (most common continuations)
    final dbLine = await _followDbPath(gap, playAsWhite, maxDepth: 6);
    if (dbLine != null) return dbLine;

    // Strategy 3: Mark as "needs generation" (optional on-demand)
    return null; // Caller can filter these out or show "Generate to fill"
  }

  /// Follow the generated tree from gap position, selecting best path.
  SuggestedLine? _findTreePath(GapCandidate gap) {
    // Find node in tree at gap FEN
    // Follow isRepertoireMove (or best expectimax child) to a leaf
    // Return the full path as a SuggestedLine
  }

  /// Follow DB popularity to a reasonable depth.
  Future<SuggestedLine?> _followDbPath(
    GapCandidate gap,
    bool playAsWhite,
    {int maxDepth = 6}
  ) async {
    // At each ply:
    //   Our turn: pick most popular move with decent eval (if available)
    //   Opponent turn: pick most popular response
    // Stop when games < threshold or maxDepth reached
  }

  double _scoreLine(SuggestedLine line, SuggestionWeights w) {
    final impact = line.coverageGain;
    final eval = line.leafEvalCp != null
        ? _winProbability(line.leafEvalCp!) : 0.5;
    final ease = line.linePlayability ?? 0.5;
    final traps = line.trapCount > 0 ? 0.7 + 0.3 * (line.trapCount / 5).clamp(0, 1) : 0.5;

    return pow(impact, w.impactExp) *
           pow(eval, w.evalExp) *
           pow(ease, w.easeExp) *
           pow(traps, w.trapExp);
  }

  /// Greedy set cover: pick lines maximizing marginal coverage gain.
  List<SuggestedLine> _greedySelect(
    List<SuggestedLine> candidates,
    double targetCoverage,
    int maxCount,
  ) {
    final selected = <SuggestedLine>[];
    var currentCoverage = _coverage.coveredPercentage;
    final coveredFens = <String>{..._coverage.coveredFens};

    while (currentCoverage < targetCoverage && selected.length < maxCount) {
      SuggestedLine? best;
      double bestMarginal = 0;

      for (final candidate in candidates) {
        if (selected.contains(candidate)) continue;
        // Marginal gain: how much NEW coverage does this add?
        final marginal = _marginalGain(candidate, coveredFens);
        if (marginal > bestMarginal) {
          bestMarginal = marginal;
          best = candidate;
        }
      }

      if (best == null || bestMarginal <= 0) break;

      selected.add(best);
      currentCoverage += bestMarginal;
      coveredFens.addAll(_fensInLine(best));
    }

    return selected;
  }
}

class SuggestionWeights {
  final double impactExp;
  final double evalExp;
  final double easeExp;
  final double trapExp;

  const SuggestionWeights({
    this.impactExp = 0.5,
    this.evalExp = 0.3,
    this.easeExp = 0.2,
    this.trapExp = 0.0,
  });

  // Presets
  static const maxCoverage = SuggestionWeights(impactExp: 1.0, evalExp: 0, easeExp: 0);
  static const balanced = SuggestionWeights(impactExp: 0.5, evalExp: 0.3, easeExp: 0.2);
  static const playable = SuggestionWeights(impactExp: 0.3, evalExp: 0.2, easeExp: 0.5);
  static const trappy = SuggestionWeights(impactExp: 0.4, evalExp: 0.2, easeExp: 0.1, trapExp: 0.3);
}
```

### File: `lib/widgets/coverage/suggestion_panel.dart` (NEW)

```dart
class SuggestionPanel extends StatefulWidget {
  final CoverageSuggestionService service;
  final RepertoireWriter writer;
  final RepertoireController controller;
  final bool playAsWhite;
  final BoardPreviewController boardPreview;  // NEW (spec 009)
}

class _SuggestionPanelState extends State<SuggestionPanel> {
  double _targetCoverage = 0.75;
  SuggestionWeights _weights = SuggestionWeights.balanced;
  List<SuggestedLine> _suggestions = [];
  bool _isLoading = false;
  double _currentCoverage = 0;

  Future<void> _generateSuggestions() async {
    setState(() => _isLoading = true);
    _suggestions = await widget.service.generateSuggestions(
      targetCoverage: _targetCoverage,
      playAsWhite: widget.playAsWhite,
      weights: _weights,
    );
    setState(() => _isLoading = false);
  }

  Future<void> _acceptSuggestion(SuggestedLine suggestion) async {
    await widget.writer.addMoveAtPosition(
      fen: suggestion.gap.fen,
      san: suggestion.newMoves.first,
      pathFromRoot: suggestion.gap.pathToGap,
    );
    // For multi-move suggestions, add remaining moves sequentially
    for (var i = 1; i < suggestion.newMoves.length; i++) {
      final path = [...suggestion.gap.pathToGap, ...suggestion.newMoves.sublist(0, i)];
      await widget.writer.addMoveAtPosition(
        fen: _fenAfterMoves(path),
        san: suggestion.newMoves[i],
        pathFromRoot: path,
      );
    }
    // Refresh suggestions (marginal gains change)
    _generateSuggestions();
  }

  Future<void> _acceptAll() async {
    for (final s in _suggestions) {
      await _acceptSuggestion(s);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Header: current coverage + target slider
        _buildHeader(),
        // Preset chips
        _buildPresets(),
        const Divider(),
        // Suggestions list
        if (_isLoading)
          const Center(child: CircularProgressIndicator())
        else
          Expanded(
            child: ListView.builder(
              itemCount: _suggestions.length,
              itemBuilder: (ctx, i) => _SuggestionRow(
                suggestion: _suggestions[i],
                index: i,
                onAccept: () => _acceptSuggestion(_suggestions[i]),
                onReject: () => _rejectSuggestion(i),
                boardPreview: widget.boardPreview,  // spec 009
              ),
            ),
          ),
        // Footer: Accept all button
        if (_suggestions.isNotEmpty) _buildFooter(),
      ],
    );
  }
}
```

### Suggestion Row: Hover Preview (spec 009)

The separate "Preview" button is replaced by **hover-to-preview** using
`BoardPreviewController`. Hovering a suggestion row shows the gap position on
the board. The suggestion's full move sequence is rendered as a hoverable
`ClickableMoveLineWidget` — hovering individual moves scrubs the board through
the suggested line.

```dart
class _SuggestionRow extends StatelessWidget {
  final SuggestedLine suggestion;
  final int index;
  final VoidCallback onAccept;
  final VoidCallback onReject;
  final BoardPreviewController boardPreview;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) {
        // Preview the gap position on hover
        boardPreview.setPreview(suggestion.gap.fen);
      },
      onExit: (_) => boardPreview.clearPreview(),
      child: Card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Gap description + coverage gain
            _buildHeader(),
            // Full suggested line — hoverable (spec 009)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: ClickableMoveLineWidget(
                sanMoves: suggestion.fullMoves,
                startPly: 0,
                maxMoves: 12,
                onMoveTapped: (idx) => _navigateToMove(idx),
                onMoveHovered: (idx) {
                  final fen = fenAfterMoves(
                      Chess.initial.fen, suggestion.fullMoves, idx);
                  boardPreview.setPreview(fen);
                },
                onHoverExit: () => boardPreview.clearPreview(),
              ),
            ),
            // Metrics: eval, playability, traps, source
            _buildMetrics(),
            // Actions
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(onPressed: onReject, child: Text('Skip')),
                FilledButton(onPressed: onAccept,
                    child: Text('Accept (+${suggestion.coverageGain}%)')),
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

### 1. No BuildTree available

**Solution:** Fall back to DB-only path resolution. Show "Source: DB" badge.
Lines will be shorter (DB data runs out quickly for rare positions). Offer
"Generate to get deeper suggestions" button.

### 2. Gap cannot be resolved (no tree, no DB games)

**Solution:** Mark suggestion as "Needs generation." Show in list with a
different style: "No data available — [Generate]" button that triggers a
focused mini-generation for that position.

### 3. Accepting a suggestion creates new gaps

**Solution:** After accept, re-run greedy selection. New gaps may appear
(the added line may have branches). These surface as new suggestions in the
refreshed list.

### 4. Target coverage unreachable

**Solution:** If all resolvable gaps are filled and coverage is still below
target, show: "Maximum reachable coverage: 71%. Remaining gaps require
generation (positions not in database)."

### 5. Overlapping suggestions

**Solution:** Greedy set cover naturally handles this — once a suggestion is
accepted, overlapping suggestions lose their marginal gain and fall in rank.

### 6. Very large gap list (500+ gaps)

**Solution:** Only resolve the top 50 gaps (by game count). The greedy selector
typically picks from the top 10-20 anyway. Show "Showing top suggestions. Run
coverage analysis for complete view."

---

## Testing Strategy

| Test | Verifies |
|------|----------|
| `_collectGaps` with known CoverageResult | Correct sorting, counts |
| `_findTreePath` with BuildTree | Follows repertoire/expectimax path |
| `_followDbPath` mocked API | Respects depth limit, picks popular |
| `_scoreLine` with various weights | Correct weight application |
| `_greedySelect` with overlapping candidates | No double-counting |
| Accept → re-rank | Marginal gains update correctly |
| No tree, no DB → graceful empty state | No crash, helpful message |
| Target unreachable | Correct message and partial results |
| Hover suggestion row → board shows gap position | BoardPreviewController.previewFen set (spec 009) |
| Hover move in suggested line → board scrubs through line | FEN computed per move index |
| Mouse leave suggestion → board restores | previewFen cleared |
| Hover replaces old "Preview" button | No separate preview action needed |

### Performance targets

| Metric | Target |
|--------|--------|
| Generate suggestions (with tree) | < 500ms for 50 gaps |
| Generate suggestions (DB-only) | < 3s (network limited) |
| Accept single suggestion | < 200ms (uses RepertoireWriter) |
| Re-rank after accept | < 200ms |

---

## Integration Points

- **Coverage tab** in Analyze mode (spec 003): Suggestions panel lives here
- **Browse mode** (spec 002): "Explore this gap" opens browse at gap position
- **RepertoireWriter** (spec 002): Handles atomic PGN writes for accepted lines
- **My Ease** (spec 007): Provides `linePlayability` for scoring
- **Trap Index** (spec 005): Provides `trapCount` for scoring
- **Coherence** (spec 008): Optional `coherenceBonus` for scoring

---

## UI Presets

| Preset | Description | Weights |
|--------|-------------|---------|
| Max Coverage | Fill gaps fastest, ignore quality | impact=1.0, rest=0 |
| Balanced | Good lines that fill gaps | impact=0.5, eval=0.3, ease=0.2 |
| Playable | Easy-to-remember gap fillers | impact=0.3, eval=0.2, ease=0.5 |
| Trappy | Gap fills with trap potential | impact=0.4, eval=0.2, ease=0.1, trap=0.3 |
