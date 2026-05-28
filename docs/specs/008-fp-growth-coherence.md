# Engineering Spec: FP-Growth Repertoire Coherence

**Status:** Draft  
**Feature:** Measure and cluster repertoire lines by shared move patterns  
**Priority:** P2 — Novel metric; builds on P0/P1 foundations  
**Depends on:** 007-my-ease (linePlayability for tradeoff UI)  
**Estimated effort:** 2-3 weeks (v1 itemsets); +2 weeks for v2 sequences  

---

## Problem Statement

A repertoire of 150 lines may feel incoherent — some lines share structural
plans (Nf3 + g3 + Bg2 + d3) while others are one-off tactical sequences. Users
can't currently see:

- "Which of my lines share the same setup?"
- "Is this new line I'm adding coherent with my existing prep?"
- "Which lines are outliers I'll struggle to remember?"
- "How much of my game time is spent in familiar patterns?"

---

## Design Goals

1. **Per-line coherence score**: "This line shares moves with 70% of your repertoire"
2. **Clusters**: Group lines by shared structural patterns (auto-named)
3. **Global coherence**: One number for the whole repertoire
4. **Rare-line risk**: Flag incoherent rare lines (hardest to remember)
5. **Coverage-by-cluster**: "In X% of games, you'll reach one of these 3 setups"
6. **Tradeoff visibility**: Show what you give up for coherence (eval, ease)
7. **Client-side**: Runs in Dart on 50-500 lines in < 100ms

---

## Algorithm

### Phase 1: Extract Itemsets

For each repertoire line, extract the set of OUR moves only:

```dart
Set<String> extractItemset(RepertoireLine line, bool playAsWhite) {
  final items = <String>{};
  for (var i = 0; i < line.moves.length; i++) {
    // Our moves are at even indices (0, 2, 4...) if white
    // Or odd indices (1, 3, 5...) if black
    final isOurMove = playAsWhite ? (i % 2 == 0) : (i % 2 == 1);
    if (isOurMove) {
      items.add(line.moves[i]); // SAN string
    }
  }
  return items;
}
```

Example:
```
Line: 1.d4 Nf6 2.c4 g6 3.Nc3 Bg7 4.e4 d6 5.Nf3 O-O 6.Be2 e5
Our moves (White): {d4, c4, Nc3, e4, Nf3, Be2}
```

### Phase 2: Optional Item Weighting

Not all moves contribute equally to "shared setup":

```dart
enum MoveCategory {
  structural,   // Pawn moves: d4, e4, c4, c3, d3, e3, f3, g3, b3
  development,  // Minor piece: Nf3, Nc3, Bc4, Be2, Bf4, Bg2, Bb5
  castle,       // O-O, O-O-O
  queen,        // Qd2, Qe2, etc.
  tactical,     // Captures (xN), checks (+)
}

double itemWeight(String san) {
  if (_isCapture(san) || _isCheck(san)) return 0.3; // Tactical: low coherence value
  if (san == 'O-O' || san == 'O-O-O') return 1.0;  // Castle: very structural
  if (_isPawnMove(san)) return 1.0;                  // Pawn structure: very structural
  if (_isMinorPieceDev(san)) return 0.9;            // Development: structural
  return 0.7;                                        // Default (queen, rook moves)
}
```

### Phase 3: FP-Growth Mining

```dart
class FPGrowthMiner {
  final double minSupport; // e.g., 0.05 = item in ≥ 5% of lines
  final List<Set<String>> transactions;
  final List<double>? transactionWeights; // line probability (optional)

  /// Mine frequent itemsets.
  List<FrequentItemset> mine() {
    // 1. Count item frequencies (weighted or unweighted)
    final itemFreq = _countItems();

    // 2. Filter items below minSupport
    final frequentItems = itemFreq.entries
        .where((e) => e.value >= minSupport)
        .map((e) => e.key)
        .toList()
      ..sort((a, b) => itemFreq[b]!.compareTo(itemFreq[a]!));

    // 3. Build FP-tree (compressed trie)
    final tree = _buildFPTree(frequentItems);

    // 4. Mine patterns (recursive conditional pattern bases)
    return _minePatterns(tree, minSupport);
  }

  /// Filter to Maximal Frequent Itemsets (no strict superset with same support).
  List<FrequentItemset> maximalItemsets(List<FrequentItemset> all) {
    // Sort by size descending
    all.sort((a, b) => b.items.length.compareTo(a.items.length));
    final maximal = <FrequentItemset>[];
    for (final candidate in all) {
      final isSubset = maximal.any((m) =>
        candidate.items.every((item) => m.items.contains(item))
      );
      if (!isSubset) maximal.add(candidate);
    }
    return maximal;
  }
}

class FrequentItemset {
  final Set<String> items; // e.g., {Nf3, g3, Bg2, d3, O-O}
  final double support;    // fraction of lines containing this set
  final int count;         // absolute number of lines
}
```

### Phase 4: Line Coherence Scoring

```dart
double lineCoherence(
  Set<String> lineItemset,
  List<FrequentItemset> maximalItemsets,
) {
  double score = 0;
  for (final mfi in maximalItemsets) {
    if (mfi.items.every((item) => lineItemset.contains(item))) {
      score += mfi.support;
    }
  }
  // Normalize to [0, 1]: divide by max possible score
  // (sum of all MFI supports that could apply to any line)
  return (score / _maxPossibleScore).clamp(0.0, 1.0);
}
```

### Phase 5: Clustering

```dart
class CoherenceCluster {
  final String id;
  final FrequentItemset signature; // The MFI that defines this cluster
  final String autoName;           // Generated: "Fianchetto King's Indian"
  final List<String> lineIds;      // Lines in this cluster
  final double probabilityMass;    // Sum of line probabilities
}

List<CoherenceCluster> buildClusters(
  List<RepertoireLine> lines,
  List<FrequentItemset> maximalItemsets,
  bool playAsWhite,
) {
  final clusters = <CoherenceCluster>[];

  // Sort MFIs by support × size (prefer large, common patterns)
  final ranked = maximalItemsets.toList()
    ..sort((a, b) => (b.support * b.items.length)
        .compareTo(a.support * a.items.length));

  final assigned = <String>{};

  for (final mfi in ranked) {
    final members = lines.where((line) {
      if (assigned.contains(line.id)) return false;
      final itemset = extractItemset(line, playAsWhite);
      return mfi.items.every((item) => itemset.contains(item));
    }).toList();

    if (members.isEmpty) continue;

    for (final m in members) assigned.add(m.id);

    clusters.add(CoherenceCluster(
      id: _generateId(),
      signature: mfi,
      autoName: _generateClusterName(mfi), // e.g., "d4 + Bf4 + e3 setup"
      lineIds: members.map((l) => l.id).toList(),
      probabilityMass: members.map((l) => l.probability).fold(0, (a, b) => a + b),
    ));
  }

  // Unclustered lines
  final unclustered = lines.where((l) => !assigned.contains(l.id)).toList();
  if (unclustered.isNotEmpty) {
    clusters.add(CoherenceCluster(
      id: 'unclustered',
      signature: FrequentItemset(items: {}, support: 0, count: 0),
      autoName: 'Unclustered',
      lineIds: unclustered.map((l) => l.id).toList(),
      probabilityMass: unclustered.map((l) => l.probability).fold(0, (a, b) => a + b),
    ));
  }

  return clusters;
}
```

### Phase 6: Global Metrics

```dart
class CoherenceResult {
  final double globalCoherence;       // Weighted average of line coherences
  final double riskWeightedCoherence; // Penalizes incoherent rare lines more
  final List<CoherenceCluster> clusters;
  final Map<String, double> lineCoherenceById;
  final double topNCoverage;          // Probability mass in top 3 clusters

  // Rare-line risk: lines with low coherence AND low probability
  List<String> get riskLines => lineCoherenceById.entries
      .where((e) => e.value < 0.3 && _lineProbability(e.key) < 0.02)
      .map((e) => e.key)
      .toList();
}
```

### Risk-Weighted Formula

```dart
double computeRiskWeightedCoherence(
  Map<String, double> lineCoherence,
  Map<String, double> lineProbability,
  {double alpha = 0.5, double beta = 1.5}
) {
  // alpha < 1 boosts rare lines in the score
  // beta > 1 penalizes incoherence extra hard
  double numerator = 0, denominator = 0;
  for (final id in lineCoherence.keys) {
    final p = lineProbability[id] ?? 0.01;
    final c = lineCoherence[id] ?? 0;
    final weight = pow(p, alpha);
    numerator += weight * c;
    denominator += weight;
  }
  return denominator > 0 ? numerator / denominator : 0;
}
```

---

## Implementation

### File: `lib/services/coherence_service.dart` (NEW)

```dart
/// Computes repertoire coherence using FP-Growth on our-move itemsets.
/// Singleton service, recomputes on repertoire change.
class CoherenceService extends ChangeNotifier {
  CoherenceResult? _result;
  CoherenceResult? get result => _result;
  bool _computing = false;

  /// Recompute coherence for the given repertoire.
  /// Fast enough for main isolate (< 100ms for 500 lines).
  Future<void> compute({
    required List<RepertoireLine> lines,
    required bool playAsWhite,
    double minSupport = 0.05,
  }) async {
    if (_computing) return;
    _computing = true;

    // Extract itemsets
    final transactions = lines.map((l) =>
      extractItemset(l, playAsWhite)
    ).toList();

    // Mine patterns
    final miner = FPGrowthMiner(
      minSupport: minSupport,
      transactions: transactions,
    );
    final allItemsets = miner.mine();
    final maximal = miner.maximalItemsets(allItemsets);

    // Score lines
    final lineScores = <String, double>{};
    for (var i = 0; i < lines.length; i++) {
      lineScores[lines[i].id] = lineCoherence(transactions[i], maximal);
    }

    // Build clusters
    final clusters = buildClusters(lines, maximal, playAsWhite);

    // Global metrics
    final lineProbabilities = {
      for (final l in lines) l.id: l.probability,
    };
    final global = _weightedAverage(lineScores, lineProbabilities);
    final riskWeighted = computeRiskWeightedCoherence(lineScores, lineProbabilities);
    final topN = clusters.take(3).map((c) => c.probabilityMass).fold(0.0, (a, b) => a + b);

    _result = CoherenceResult(
      globalCoherence: global,
      riskWeightedCoherence: riskWeighted,
      clusters: clusters,
      lineCoherenceById: lineScores,
      topNCoverage: topN,
    );

    _computing = false;
    notifyListeners();
  }

  /// Invalidate on repertoire change.
  void invalidate() {
    _result = null;
    notifyListeners();
  }
}
```

### File: `lib/services/fp_growth.dart` (NEW)

Pure Dart implementation of FP-Growth algorithm:

```dart
/// FP-Tree node.
class _FPNode {
  final String? item; // null for root
  int count = 0;
  final Map<String, _FPNode> children = {};
  _FPNode? parent;
  _FPNode? headerLink; // For same-item traversal
}

/// FP-Growth implementation optimized for small transaction sets.
/// Designed for chess repertoire itemsets (50-500 transactions, 5-15 items each).
class FPGrowthMiner {
  final double minSupport;
  final List<Set<String>> transactions;

  List<FrequentItemset> mine() {
    final n = transactions.length;
    final minCount = (minSupport * n).ceil();

    // 1. Count single-item frequencies
    final freq = <String, int>{};
    for (final t in transactions) {
      for (final item in t) {
        freq[item] = (freq[item] ?? 0) + 1;
      }
    }

    // 2. Remove infrequent items, sort by frequency desc
    final frequentItems = freq.entries
        .where((e) => e.value >= minCount)
        .toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final itemOrder = {
      for (var i = 0; i < frequentItems.length; i++)
        frequentItems[i].key: i,
    };

    // 3. Build FP-tree
    final root = _FPNode();
    final headerTable = <String, _FPNode>{};

    for (final transaction in transactions) {
      final sorted = transaction
          .where((item) => itemOrder.containsKey(item))
          .toList()
        ..sort((a, b) => itemOrder[a]!.compareTo(itemOrder[b]!));

      var current = root;
      for (final item in sorted) {
        if (!current.children.containsKey(item)) {
          final newNode = _FPNode()
            ..item = item
            ..parent = current;
          current.children[item] = newNode;
          // Update header table
          if (headerTable.containsKey(item)) {
            var last = headerTable[item]!;
            while (last.headerLink != null) last = last.headerLink!;
            last.headerLink = newNode;
          } else {
            headerTable[item] = newNode;
          }
        }
        current = current.children[item]!;
        current.count++;
      }
    }

    // 4. Mine patterns recursively
    return _mineTree(root, headerTable, minCount, {});
  }

  List<FrequentItemset> _mineTree(
    _FPNode root,
    Map<String, _FPNode> headerTable,
    int minCount,
    Set<String> prefix,
  ) {
    final results = <FrequentItemset>[];

    // Process items in reverse frequency order (least frequent first)
    final items = headerTable.keys.toList().reversed;

    for (final item in items) {
      final newPrefix = {...prefix, item};
      final support = _countItem(headerTable[item]);

      if (support >= minCount) {
        results.add(FrequentItemset(
          items: newPrefix,
          support: support / transactions.length,
          count: support,
        ));

        // Build conditional pattern base
        final conditionalPatterns = _conditionalPatternBase(headerTable[item]!);
        if (conditionalPatterns.isNotEmpty) {
          // Recursively mine conditional tree
          final subMiner = FPGrowthMiner(
            minSupport: minSupport,
            transactions: conditionalPatterns,
          );
          final subResults = subMiner.mine();
          for (final sub in subResults) {
            results.add(FrequentItemset(
              items: {...sub.items, ...newPrefix},
              support: sub.support,
              count: sub.count,
            ));
          }
        }
      }
    }

    return results;
  }
}
```

---

## UI Surfaces

### 1. Lines browser — cluster grouping

```
┌─ Repertoire Lines (grouped by cluster) ──────────────────────────┐
│                                                                    │
│ ▸ KID Fianchetto Setup (23 lines, 45% of games) ── Coherence: 0.81 │
│   │ 1.Nf3 d5 2.g3 Nf6 3.Bg2 e6 4.O-O Be7 5.d3     playability 0.85 │
│   │ 1.Nf3 d5 2.g3 c6 3.Bg2 Nf6 4.O-O Bg4 5.d3     playability 0.78 │
│   │ ...                                                            │
│                                                                    │
│ ▸ Classical d4+c4 (19 lines, 38% of games) ── Coherence: 0.74    │
│   │ ...                                                            │
│                                                                    │
│ ▸ Unclustered (4 lines, 3% of games) ── Coherence: 0.21          │
│   │ ⚠ 1.e4 c5 2.b4 ... (low coherence, rare — hard to remember) │
│   │ ...                                                            │
└────────────────────────────────────────────────────────────────────┘
```

### 2. Status bar / summary

```
Coherence: 0.74 │ Clusters: 4 │ Top-3 coverage: 89%
```

### 3. Browse mode — coherence hint on candidates

When adding a move in browse mode, show whether it increases or decreases
coherence with existing lines:

```
│   Bg2    +0.28   ease▓▓▓   coherence: +0.03 (fits fianchetto cluster) │
│   Bc4    +0.30   ease▓▓    coherence: -0.05 (doesn't fit any cluster) │
```

### 4. Generation selection — coherence-aware

New selection mode or modifier: prefer lines whose our-moves overlap with
existing high-support itemsets.

### 5. Tradeoff sliders

Three-way slider in settings or generation config:
- **Eval** ← expectimax value
- **Ease** ← linePlayability (spec 007)
- **Coherence** ← line coherence score

Presets: "Engine-First" (eval heavy), "Playable" (ease heavy),
"Coherent" (coherence heavy), "Balanced" (equal).

---

## Cluster Auto-Naming

```dart
String generateClusterName(FrequentItemset mfi) {
  // Strategy: identify the most distinctive structural moves
  final structural = mfi.items.where(_isStructural).toList();
  final development = mfi.items.where(_isDevelopment).toList();

  if (structural.contains('g3') && development.contains('Bg2'))
    return 'Fianchetto setup';
  if (structural.contains('d4') && structural.contains('c4'))
    return 'd4 + c4 complex';
  if (structural.contains('d4') && development.contains('Bf4'))
    return 'London-style';
  if (structural.contains('e4') && structural.contains('d4'))
    return 'Open center';

  // Fallback: list top 3 most distinctive moves
  final topMoves = mfi.items.toList()
    ..sort((a, b) => itemWeight(b).compareTo(itemWeight(a)));
  return topMoves.take(3).join(' + ') + ' setup';
}
```

---

## Edge Cases

### 1. Very small repertoire (< 5 lines)

**Solution:** FP-Growth produces trivial results. Show: "Too few lines for
meaningful coherence analysis. Add more lines to see patterns." Don't display
a misleading score.

### 2. All lines are the same opening (100% coherent)

**Solution:** Valid — global coherence = 1.0. One cluster containing all lines.
Useful feedback: "Your repertoire is highly focused."

### 3. Tactical repertoire with many unique moves

**Solution:** Low coherence is expected and correct. UI shows neutral language:
"Diverse repertoire — many different setups." Not a warning, just information.

### 4. Move appears in different contexts (e.g., Nf3 in KID vs London)

**Solution:** This is what FP-Growth handles well — Nf3 alone has high support,
but the cluster separates based on WHICH OTHER moves accompany it. {Nf3, g3, Bg2}
is a different cluster from {Nf3, d4, Bf4, e3}.

### 5. Transpositions: same position, different move orders

**Solution:** Itemsets are inherently transposition-agnostic (sets, not
sequences). Two lines reaching the same position via d4+Nf3 vs Nf3+d4 produce
the same itemset. This is a feature for v1.

### 6. Coherence computation during PGN editing

**Solution:** Debounce: recompute coherence 500ms after last PGN change.
Cache result until next invalidation. < 100ms computation means no jank.

---

## Limitations (v1)

1. **Can't distinguish KID subtypes** (Mar del Plata vs Classical) without
   pawn-structure or eval-band tags
2. **Tactical sequences ignored** (captures and checks are low-weight)
3. **No move ordering** — can't detect "Qd2 must come before Bh6"
4. **Same moves, different plans** — rare false friends possible
5. **Coherence ≠ quality** — a coherent repertoire of bad lines is still bad

### v2 Improvements (future)

- Sequence mining (PrefixSpan) for order-sensitive patterns
- FEN-based collapse for true transposition grouping
- Cluster splitting when eval spread > 80cp at canonical FEN
- Pawn-structure tags as additional items (e.g., "IQP", "closed center")

---

## Testing Strategy

| Test | Verifies |
|------|----------|
| `extractItemset` white/black | Correct move extraction |
| FP-Growth on known transactions | Matches expected frequent patterns |
| Maximal filtering | Removes proper subsets correctly |
| `lineCoherence` for line in cluster | Score > 0 |
| `lineCoherence` for outlier line | Score ≈ 0 |
| Cluster assignment | Lines assigned to correct cluster |
| Risk-weighted coherence | Rare incoherent lines penalized |
| Auto-naming | Produces readable names |
| 500-line repertoire timing | < 100ms total |
| Empty repertoire | No crash, helpful message |

---

## Performance Analysis

| Repertoire size | Transactions | Avg items | FP-Growth time (est.) |
|-----------------|-------------|-----------|----------------------|
| 50 lines | 50 | ~8 | < 5ms |
| 200 lines | 200 | ~10 | < 30ms |
| 500 lines | 500 | ~12 | < 80ms |

FP-Growth complexity: O(n × avg_item_count) per database scan, two scans for
tree build + mining. With 500 × 12 = 6000 total items, this is trivially fast.

---

## Migration Path

1. **FP-Growth pure Dart** (3 days): Algorithm + unit tests on synthetic data
2. **CoherenceService** (2 days): Wire to repertoire lines, compute on load
3. **Cluster UI in Lines browser** (2 days): Grouped view, coherence badges
4. **Global coherence in status bar** (0.5 day): Summary metric
5. **Browse mode coherence hint** (1 day): Per-candidate coherence delta
6. **Risk-line warnings** (1 day): Flag incoherent rare lines
7. **Tradeoff slider** (1 day): Preset chips for eval/ease/coherence balance
8. **v2 sequences** (2 weeks): PrefixSpan + FEN collapse (separate future spec)
