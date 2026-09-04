/// Repertoire coverage: what share of the master games reaching your root
/// your file still has an answer for.
///
/// Counts come from the local master-games (TWIC) book, not the Lichess
/// Explorer — see [CoverageService.masterBook] for why.
library;

import 'dart:async';
import 'package:dartchess/dartchess.dart';
import '../../../models/opening_tree.dart';
import '../../../services/master_games/master_games_db.dart'
    show BookLookup, BookMove;
import '../../../utils/fen_utils.dart';
import '../../../utils/chess_utils.dart';
import '../../../services/maia/maia_factory.dart';

/// Database types for Lichess Explorer
enum LichessDatabase { lichess, masters, player }

/// Leaf classification for coverage analysis
enum LeafCategory { covered, tooShallow, tooDeep }

/// Represents a leaf node in the repertoire analysis
class LeafNode {
  final String fen;
  final List<String> moves;
  final int gameCount;
  final LeafCategory category;
  final String reason;

  /// For tooDeep leaves: how many ply past the threshold point
  final int excessPly;

  LeafNode({
    required this.fen,
    required this.moves,
    required this.gameCount,
    required this.category,
    required this.reason,
    this.excessPly = 0,
  });

  bool get isCovered => category == LeafCategory.covered;

  String get moveString => moves.isEmpty ? '(root)' : moves.join(' ');
}

/// An opponent move not covered by the repertoire
class UnaccountedMove {
  final List<String> parentMoves;
  final String move;
  final int gameCount;
  final double probability;

  /// Which database named this move: `masters` (the local TWIC book) or
  /// `maia` (the policy net, when the book has never seen the position).
  final String source;

  UnaccountedMove({
    required this.parentMoves,
    required this.move,
    required this.gameCount,
    required this.probability,
    required this.source,
  });
}

/// Results from coverage analysis
class CoverageResult {
  final String rootFen;
  final List<String> rootMoves;
  final int rootGameCount;
  final double targetPercent;
  final int targetGameCount;
  final List<LeafNode> coveredLeaves;
  final List<LeafNode> tooShallowLeaves;
  final List<LeafNode> tooDeepLeaves;
  final List<UnaccountedMove> unaccountedMoves;
  final int totalCoveredGames;
  final int totalShallowGames;
  final int totalDeepGames;
  final int totalUnaccountedGames;

  CoverageResult({
    required this.rootFen,
    required this.rootMoves,
    required this.rootGameCount,
    required this.targetPercent,
    required this.targetGameCount,
    required this.coveredLeaves,
    required this.tooShallowLeaves,
    required this.tooDeepLeaves,
    required this.unaccountedMoves,
    required this.totalCoveredGames,
    required this.totalShallowGames,
    required this.totalDeepGames,
    required this.totalUnaccountedGames,
  });

  String get rootDescription {
    if (rootMoves.isEmpty) return 'Starting position';
    return rootMoves.join(' ');
  }

  double get coveragePercent {
    if (rootGameCount == 0) return 0.0;
    return (totalCoveredGames / rootGameCount) * 100;
  }

  double get shallowPercent {
    if (rootGameCount == 0) return 0.0;
    return (totalShallowGames / rootGameCount) * 100;
  }

  double get deepPercent {
    if (rootGameCount == 0) return 0.0;
    return (totalDeepGames / rootGameCount) * 100;
  }

  double get unaccountedPercent {
    if (rootGameCount == 0) return 0.0;
    return (totalUnaccountedGames / rootGameCount) * 100;
  }

  /// All leaves regardless of category
  List<LeafNode> get allLeaves => [
    ...coveredLeaves,
    ...tooShallowLeaves,
    ...tooDeepLeaves,
  ];

  /// All "gap" items: too-shallow leaves and unaccounted moves, sorted by
  /// move-path length (tree order). Returns move sequences.
  List<List<String>> get _allGaps {
    final gaps = <List<String>>[];
    for (final leaf in tooShallowLeaves) {
      gaps.add(leaf.moves);
    }
    for (final um in unaccountedMoves) {
      gaps.add([...um.parentMoves, um.move]);
    }
    gaps.sort((a, b) => a.length.compareTo(b.length));
    return gaps;
  }

  /// First gap in tree order (shortest move path).
  List<String>? findNextGap() {
    final gaps = _allGaps;
    return gaps.isNotEmpty ? gaps.first : null;
  }

  /// Gap with the highest game count (most impactful to address).
  List<String>? findBiggestGap() {
    List<String>? best;
    int bestCount = -1;

    for (final leaf in tooShallowLeaves) {
      if (leaf.gameCount > bestCount) {
        bestCount = leaf.gameCount;
        best = leaf.moves;
      }
    }
    for (final um in unaccountedMoves) {
      if (um.gameCount > bestCount) {
        bestCount = um.gameCount;
        best = [...um.parentMoves, um.move];
      }
    }
    return best;
  }
}

/// Progress callback for coverage analysis
typedef CoverageProgressCallback =
    void Function(String message, double progress);

/// Coverage Calculator Service
class CoverageService {
  /// Leaves extending this many ply past the first sub-threshold node
  /// are classified as "too deep".
  static const tooDeepThresholdPly = 4;

  /// Fall back to the Maia policy net for opponent replies at positions the
  /// book has never seen — the only source left once the book runs out.
  final bool useMaia;
  final int maiaElo;

  /// Where the game counts come from.
  ///
  /// The local master-games (TWIC) book — `MasterGamesDb.bookMoves` — not the
  /// Lichess Explorer. Coverage asks a question about every node of a tree, so
  /// the Explorer version was thousands of API calls per run, which is why
  /// that fetch path was mothballed; the local book answers the same question
  /// from disk with no network, no rate limit and no politeness gap.
  ///
  /// The number therefore means "share of *master* games reaching your root
  /// that your file still answers", not "share of Lichess games in a rating
  /// band". That is the honest reading of the only complete position database
  /// this app has offline, and it is the right one for opening prep.
  ///
  /// Null when no book is wired (no TWIC import yet) — then there is no
  /// source at all, [hasPositionData] is false, and the run refuses rather
  /// than reporting zeros.
  final BookLookup? masterBook;

  CoverageService({this.useMaia = false, this.maiaElo = 2200, this.masterBook});

  /// Whether this service has a position-statistics source at all.
  ///
  /// Coverage is defined entirely by game counts — what fraction of the games
  /// reaching the root your file still answers — so with no source every
  /// number it produces is zero: a full tree traversal that ends in
  /// "0.0% covered, 0 shallow, 0 unaccounted" no matter how complete the
  /// repertoire is. That reads as a verdict on the repertoire rather than on
  /// the missing source, which is why the entry points are hidden and
  /// [analyzeOpeningTree] refuses instead of returning zeros.
  bool get hasPositionData => masterBook != null;

  /// Master moves at [fen], most-played first; empty when no book is wired
  /// or the position is not in it.
  List<BookMove> bookMovesAt(String fen) => masterBook?.call(fen) ?? const [];

  /// MOTHBALLED: Lichess Explorer API calls are disabled. Returns null
  /// immediately.
  ///
  /// Still here because [CandidateService] calls it for *Explorer-shaped*
  /// stats in the browse panels, where a master-book answer would be
  /// mislabelled. Coverage no longer goes through it — it reads
  /// [masterBook] directly.
  Future<Map<String, dynamic>?> getPositionData(String fen) async {
    // Mothballed: no Lichess Explorer API calls.
    return null;
  }

  /// Master games that reached [fen], as the sum over the moves played from
  /// it. A position no master ever left — the last position of every game
  /// that ended there — contributes nothing, which is the same convention the
  /// book itself is built on and is immaterial at opening depth.
  Future<int> getGameCount(String fen) async {
    final moves = bookMovesAt(fen);
    if (moves.isNotEmpty) {
      return moves.fold<int>(0, (sum, m) => sum + m.games);
    }
    // Legacy Explorer shape, for a future in which that path comes back.
    final data = await getPositionData(fen);
    if (data == null) return 0;
    return (data['white'] as int? ?? 0) +
        (data['black'] as int? ?? 0) +
        (data['draws'] as int? ?? 0);
  }

  /// Moves played from [fen] with their W/D/L counts, in the Explorer's shape
  /// so the callers below stay source-agnostic.
  ///
  /// The book stores UCI; a move whose SAN cannot be derived (an unparsable
  /// FEN, a move illegal in it — a corrupt row) is dropped rather than
  /// reported under a raw `e2e4`, which would never match a repertoire SAN
  /// and so would show up as a permanent phantom gap.
  Future<List<Map<String, dynamic>>> getMovesWithCounts(String fen) async {
    final book = bookMovesAt(fen);
    if (book.isNotEmpty) {
      final out = <Map<String, dynamic>>[];
      for (final m in book) {
        final san = uciToSanOrNull(fen, m.uci);
        if (san == null) continue;
        out.add({
          'san': san,
          'uci': m.uci,
          'white': m.whiteWins,
          'draws': m.draws,
          'black': m.blackWins,
        });
      }
      return out;
    }
    final data = await getPositionData(fen);
    if (data == null) return [];
    final moves = data['moves'] as List<dynamic>? ?? [];
    return moves.cast<Map<String, dynamic>>();
  }

  /// Where the measurement starts: the forced opening sequence the file
  /// commits to, and the node it lands on.
  ///
  /// The root sets the denominator — "games that reach here" — so it may only
  /// swallow moves that were *ours to choose*. A 1.e4 repertoire is measured
  /// over games with 1.e4, which is what its author means by coverage.
  ///
  /// It must NOT swallow a lone opponent reply. Descending through one
  /// because the file happens to answer only 1...e5 would redefine the
  /// denominator as "games with 1.e4 e5" and delete the entire Sicilian from
  /// the measurement — scoring the file 100% precisely for the gap it was run
  /// to find. Our own single child is a choice; theirs is a hole.
  ///
  /// Returns the moves played, the node they land on, and its FEN.
  ({List<String> moves, OpeningTreeNode node, String fen}) findRepertoireRoot(
    OpeningTree tree, {
    required bool isWhiteRepertoire,
  }) {
    final moves = <String>[];
    Chess position = Chess.initial;
    OpeningTreeNode current = tree.root;

    while (current.children.length == 1) {
      final ourTurn = (position.turn == Side.white) == isWhiteRepertoire;
      if (!ourTurn) break;

      final childMove = current.children.keys.first;
      final move = position.parseSan(childMove);
      if (move == null) break;

      moves.add(childMove);
      position = position.play(move) as Chess;
      current = current.children.values.first;
    }

    return (moves: moves, node: current, fen: position.fen);
  }

  Future<CoverageResult> analyzeOpeningTree(
    OpeningTree tree, {
    required double targetPercent,
    required bool isWhiteRepertoire,
    CoverageProgressCallback? onProgress,
  }) async {
    if (!hasPositionData) {
      throw StateError(
        'Coverage needs the master-games database, and none is loaded — '
        'every figure it produced would be zero. Import TWIC issues in '
        'Settings, then run it again.',
      );
    }
    onProgress?.call('Detecting root position...', 0.0);

    final root = findRepertoireRoot(tree, isWhiteRepertoire: isWhiteRepertoire);
    final rootMoves = root.moves;
    final effectiveRootFen = root.fen;

    onProgress?.call(
      'Root: ${rootMoves.isEmpty ? "Starting position" : rootMoves.join(" ")}',
      0.02,
    );

    final rootGameCount = await getGameCount(effectiveRootFen);
    final targetGameCount = (rootGameCount * targetPercent / 100).round();

    onProgress?.call(
      'Root: ${_formatNumber(rootGameCount)} games → Target: ${_formatNumber(targetGameCount)} (${targetPercent.toStringAsFixed(1)}%)',
      0.05,
    );

    final startingMoves = rootMoves;
    final leaves = <LeafNode>[];
    final allPositions = <String, List<String>>{};

    // The walk starts at the ROOT NODE, not at `tree.root`: every position
    // below is derived as `startingMoves + currentMoves`, so a walk that
    // began at the true root would re-apply the prefix on top of a path that
    // already contains it and compute a nonsense (usually illegal, therefore
    // silently unchanged) FEN for every node in the tree.
    await _traverseTree(
      root.node,
      [],
      leaves,
      allPositions,
      targetGameCount,
      isWhiteRepertoire,
      startingMoves,
      onProgress,
      null, // firstBelowThresholdPly — not yet below threshold at root
    );

    onProgress?.call('Found ${leaves.length} leaf positions', 0.6);

    final coveredLeaves = leaves
        .where((l) => l.category == LeafCategory.covered)
        .toList();
    final tooShallowLeaves = leaves
        .where((l) => l.category == LeafCategory.tooShallow)
        .toList();
    final tooDeepLeaves = leaves
        .where((l) => l.category == LeafCategory.tooDeep)
        .toList();

    final totalCoveredGames = coveredLeaves.fold(
      0,
      (sum, l) => sum + l.gameCount,
    );
    final totalShallowGames = tooShallowLeaves.fold(
      0,
      (sum, l) => sum + l.gameCount,
    );
    final totalDeepGames = tooDeepLeaves.fold(0, (sum, l) => sum + l.gameCount);

    onProgress?.call('Calculating unaccounted moves...', 0.7);
    final unaccountedMoves = await _calculateUnaccounted(
      tree,
      allPositions,
      isWhiteRepertoire,
      startingMoves,
      rootGameCount,
      onProgress,
    );

    final totalUnaccountedGames = unaccountedMoves.fold(
      0,
      (sum, m) => sum + m.gameCount,
    );

    onProgress?.call('Analysis complete!', 1.0);

    return CoverageResult(
      rootFen: effectiveRootFen,
      rootMoves: startingMoves,
      rootGameCount: rootGameCount,
      targetPercent: targetPercent,
      targetGameCount: targetGameCount,
      coveredLeaves: coveredLeaves,
      tooShallowLeaves: tooShallowLeaves,
      tooDeepLeaves: tooDeepLeaves,
      unaccountedMoves: unaccountedMoves,
      totalCoveredGames: totalCoveredGames,
      totalShallowGames: totalShallowGames,
      totalDeepGames: totalDeepGames,
      totalUnaccountedGames: totalUnaccountedGames,
    );
  }

  /// The position after [prefix] then [rest], or null when the path does not
  /// apply from the standard start.
  ///
  /// Total, but never *silently* total: skipping a move that will not play —
  /// as both replays here used to — leaves a position that has drifted from
  /// the path it claims to be, and every count taken at it is then a count
  /// for some other position. Returning null lets the caller drop the node
  /// instead of reporting a confident wrong number.
  Chess? _positionAfter(List<String> prefix, List<String> rest) {
    try {
      Chess position = Chess.initial;
      for (final move in [...prefix, ...rest]) {
        final m = position.parseSan(move);
        if (m == null) return null;
        position = position.play(m) as Chess;
      }
      return position;
    } catch (_) {
      return null;
    }
  }

  /// Traverse the opening tree and collect leaf nodes.
  ///
  /// [firstBelowThresholdPly] tracks the ply at which game count first
  /// dropped below the target.  If a leaf is 4+ ply deeper, it's "too deep".
  Future<void> _traverseTree(
    OpeningTreeNode node,
    List<String> currentMoves,
    List<LeafNode> leaves,
    Map<String, List<String>> allPositions,
    int targetGameCount,
    bool isWhiteRepertoire,
    List<String> startingMoves,
    CoverageProgressCallback? onProgress,
    int? firstBelowThresholdPly,
  ) async {
    final position = _positionAfter(startingMoves, currentMoves);
    if (position == null) return;

    final fen = position.fen;
    allPositions[normalizeFen(fen)] = List.from(currentMoves);

    final currentPly = currentMoves.length;

    if (node.children.isEmpty) {
      final gameCount = await getGameCount(fen);
      final isGameOver = position.isGameOver;
      final belowThreshold = gameCount <= targetGameCount || isGameOver;

      final effectiveFirstBelow =
          firstBelowThresholdPly ?? (belowThreshold ? currentPly : null);

      LeafCategory category;
      String reason;

      if (isGameOver) {
        category = LeafCategory.covered;
        if (position.isCheckmate) {
          reason = 'Checkmate';
        } else if (position.isStalemate) {
          reason = 'Stalemate';
        } else {
          reason = 'Game over';
        }
      } else if (!belowThreshold) {
        category = LeafCategory.tooShallow;
        reason =
            'Too shallow (${_formatNumber(gameCount)} > ${_formatNumber(targetGameCount)} target)';
      } else if (effectiveFirstBelow != null &&
          currentPly - effectiveFirstBelow >= tooDeepThresholdPly) {
        category = LeafCategory.tooDeep;
        reason = '${currentPly - effectiveFirstBelow} ply past threshold';
      } else {
        category = LeafCategory.covered;
        reason =
            'Covered (${_formatNumber(gameCount)} ≤ ${_formatNumber(targetGameCount)} target)';
      }

      leaves.add(
        LeafNode(
          fen: fen,
          moves: currentMoves,
          gameCount: gameCount,
          category: category,
          reason: reason,
          excessPly: effectiveFirstBelow != null
              ? currentPly - effectiveFirstBelow
              : 0,
        ),
      );
    } else {
      // Check game count at this intermediate node to track threshold crossing
      int? updatedFirstBelow = firstBelowThresholdPly;
      if (updatedFirstBelow == null) {
        final gameCount = await getGameCount(fen);
        if (gameCount <= targetGameCount) {
          updatedFirstBelow = currentPly;
        }
      }

      for (final child in node.children.values) {
        await _traverseTree(
          child,
          [...currentMoves, child.move],
          leaves,
          allPositions,
          targetGameCount,
          isWhiteRepertoire,
          startingMoves,
          onProgress,
          updatedFirstBelow,
        );
      }
    }
  }

  /// Calculate unaccounted moves (opponent moves not in repertoire).
  /// Returns structured list with move details and source.
  Future<List<UnaccountedMove>> _calculateUnaccounted(
    OpeningTree tree,
    Map<String, List<String>> allPositions,
    bool isWhiteRepertoire,
    List<String> startingMoves,
    int rootGameCount,
    CoverageProgressCallback? onProgress,
  ) async {
    final result = <UnaccountedMove>[];
    int checked = 0;
    final total = allPositions.length;

    for (final entry in allPositions.entries) {
      checked++;
      if (checked % 10 == 0) {
        onProgress?.call(
          'Checking unaccounted ($checked/$total)...',
          0.7 + (0.25 * checked / total),
        );
      }

      final position = _positionAfter(startingMoves, entry.value);
      if (position == null) continue;

      final isWhiteTurn = position.turn == Side.white;
      final isMyTurn =
          (isWhiteRepertoire && isWhiteTurn) ||
          (!isWhiteRepertoire && !isWhiteTurn);
      if (isMyTurn) continue;

      final node = _findNodeByFen(tree, entry.key);
      if (node == null || node.children.isEmpty) continue;

      final repertoireMoves = node.children.keys.toSet();
      final fen = position.fen;

      // Try Lichess DB first
      final apiMoves = await getMovesWithCounts(fen);

      if (apiMoves.isNotEmpty) {
        final totalGames = apiMoves.fold<int>(
          0,
          (s, m) =>
              s +
              (m['white'] as int? ?? 0) +
              (m['black'] as int? ?? 0) +
              (m['draws'] as int? ?? 0),
        );

        for (final moveData in apiMoves) {
          final moveSan = moveData['san'] as String?;
          if (moveSan != null && !repertoireMoves.contains(moveSan)) {
            final moveGames =
                (moveData['white'] as int? ?? 0) +
                (moveData['black'] as int? ?? 0) +
                (moveData['draws'] as int? ?? 0);
            final prob = totalGames > 0 ? moveGames / totalGames : 0.0;
            result.add(
              UnaccountedMove(
                parentMoves: List<String>.from(entry.value),
                move: moveSan,
                gameCount: moveGames,
                probability: prob,
                source: 'masters',
              ),
            );
          }
        }
      } else if (useMaia &&
          MaiaFactory.isAvailable &&
          MaiaFactory.instance != null) {
        // Maia fallback when Lichess DB has no data
        try {
          final maiaResult = await MaiaFactory.instance!.evaluate(fen, maiaElo);
          for (final moveEntry in maiaResult.policy.entries) {
            final uci = moveEntry.key;
            final prob = moveEntry.value;
            if (prob < 0.02) continue;
            final san = uciToSan(fen, uci);
            if (!repertoireMoves.contains(san)) {
              result.add(
                UnaccountedMove(
                  parentMoves: List<String>.from(entry.value),
                  move: san,
                  gameCount: 0,
                  probability: prob,
                  source: 'maia',
                ),
              );
            }
          }
        } catch (_) {
          // Maia eval failed — skip this position
        }
      }
    }

    return result;
  }

  OpeningTreeNode? _findNodeByFen(OpeningTree tree, String normalizedFen) {
    if (tree.fenToNodes.containsKey(normalizedFen)) {
      final nodes = tree.fenToNodes[normalizedFen];
      if (nodes != null && nodes.isNotEmpty) {
        return nodes.first;
      }
    }
    return null;
  }

  String _formatNumber(int number) {
    if (number >= 1000000) {
      return '${(number / 1000000).toStringAsFixed(1)}M';
    } else if (number >= 1000) {
      return '${(number / 1000).toStringAsFixed(1)}K';
    }
    return number.toString();
  }
}
