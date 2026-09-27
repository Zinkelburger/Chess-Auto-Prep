/// Repertoire coverage: what share of the master games reaching your root
/// your file still has an answer for.
///
/// Counts come from the local master-games (TWIC) book, not the Lichess
/// Explorer — see [CoverageService.masterBook] for why.
library;

import 'package:chess_auto_prep/chess_core/moves/opening_graph.dart';
import 'dart:async';

import 'package:dartchess/dartchess.dart';

import '../../../services/maia/maia_factory.dart';
import '../../../services/master_games/master_games_db.dart'
    show BookLookup, BookMove;
import '../../../utils/chess_utils.dart';
import '../../../utils/fen_utils.dart';

/// Leaf classification for coverage analysis.
enum LeafCategory { covered, tooShallow, tooDeep }

/// A leaf of the repertoire with the master-game count that reaches it.
class LeafNode {
  const LeafNode({
    required this.fen,
    required this.moves,
    required this.gameCount,
    required this.category,
    required this.reason,
    this.excessPly = 0,
  });

  final String fen;

  /// SAN moves from the coverage root to the leaf.
  final List<String> moves;
  final int gameCount;
  final LeafCategory category;

  /// Human-readable classification, e.g. "Covered (1.2K ≤ 2.0K target)".
  final String reason;

  /// For tooDeep leaves: how many ply past the threshold point.
  final int excessPly;

  bool get isCovered => category == LeafCategory.covered;

  String get moveString => moves.isEmpty ? '(root)' : moves.join(' ');
}

/// Which source named an [UnaccountedMove].
enum UnaccountedSource {
  /// The local TWIC master book.
  masters,

  /// The Maia policy net, asked only where the book has never seen the
  /// position.
  maia,
}

/// An opponent move not covered by the repertoire.
class UnaccountedMove {
  const UnaccountedMove({
    required this.parentMoves,
    required this.move,
    required this.gameCount,
    required this.probability,
    required this.source,
  });

  final List<String> parentMoves;
  final String move;

  /// Master games with this move; zero for a Maia-sourced move.
  final int gameCount;
  final double probability;
  final UnaccountedSource source;
}

/// Results from coverage analysis.
class CoverageResult {
  const CoverageResult({
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

  String get rootDescription =>
      rootMoves.isEmpty ? 'Starting position' : rootMoves.join(' ');

  double get coveragePercent => _percentOfRoot(totalCoveredGames);
  double get shallowPercent => _percentOfRoot(totalShallowGames);
  double get deepPercent => _percentOfRoot(totalDeepGames);
  double get unaccountedPercent => _percentOfRoot(totalUnaccountedGames);

  double _percentOfRoot(int games) =>
      rootGameCount == 0 ? 0.0 : games / rootGameCount * 100;

  /// All leaves regardless of category.
  List<LeafNode> get allLeaves => [
    ...coveredLeaves,
    ...tooShallowLeaves,
    ...tooDeepLeaves,
  ];

  /// All "gap" items: too-shallow leaves and unaccounted moves, sorted by
  /// move-path length (tree order). Returns move sequences.
  List<List<String>> get _allGaps => [
    for (final leaf in tooShallowLeaves) leaf.moves,
    for (final um in unaccountedMoves) [...um.parentMoves, um.move],
  ]..sort((a, b) => a.length.compareTo(b.length));

  /// First gap in tree order (shortest move path).
  List<String>? findNextGap() => _allGaps.firstOrNull;

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

/// A master-book move at a position, SAN-resolved, with its result counts.
class MasterMoveCount {
  const MasterMoveCount({
    required this.san,
    required this.uci,
    required this.whiteWins,
    required this.draws,
    required this.blackWins,
  });

  final String san;
  final String uci;
  final int whiteWins;
  final int draws;
  final int blackWins;

  /// Games with a decided result, which is what the unaccounted counts and
  /// probabilities are measured in.
  int get games => whiteWins + draws + blackWins;
}

/// Progress callback for coverage analysis.
typedef CoverageProgressCallback =
    void Function(String message, double progress);

/// Coverage Calculator Service.
class CoverageService {
  CoverageService({this.useMaia = false, this.maiaElo = 2200, this.masterBook});

  /// Leaves extending this many ply past the first sub-threshold node
  /// are classified as "too deep".
  static const tooDeepThresholdPly = 4;

  /// Maia replies below this probability are not worth an unaccounted entry.
  static const double _minMaiaReplyProbability = 0.02;

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
  /// mislabelled. Coverage does not go through it — it reads [masterBook].
  Future<Map<String, dynamic>?> getPositionData(String fen) async => null;

  /// Master games that reached [fen], as the sum over the moves played from
  /// it. A position no master ever left — the last position of every game
  /// that ended there — contributes nothing, which is the same convention the
  /// book itself is built on and is immaterial at opening depth.
  Future<int> getGameCount(String fen) async =>
      bookMovesAt(fen).fold<int>(0, (sum, m) => sum + m.games);

  /// Moves played from [fen] with their result counts, most-played first.
  ///
  /// The book stores UCI; a move whose SAN cannot be derived (an unparsable
  /// FEN, a move illegal in it — a corrupt row) is dropped rather than
  /// reported under a raw `e2e4`, which would never match a repertoire SAN
  /// and so would show up as a permanent phantom gap.
  Future<List<MasterMoveCount>> getMovesWithCounts(String fen) async => [
    for (final m in bookMovesAt(fen))
      if (uciToSanOrNull(fen, m.uci) case final san?)
        MasterMoveCount(
          san: san,
          uci: m.uci,
          whiteWins: m.whiteWins,
          draws: m.draws,
          blackWins: m.blackWins,
        ),
  ];

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
  ({List<String> moves, OpeningNodeView node, String fen}) findRepertoireRoot(
    OpeningGraph tree, {
    required bool isWhiteRepertoire,
  }) {
    final moves = <String>[];
    Chess position = Chess.initial;
    OpeningNodeView current = tree.root;

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
    OpeningGraph tree, {
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

    onProgress?.call(
      'Root: ${rootMoves.isEmpty ? "Starting position" : rootMoves.join(" ")}',
      0.02,
    );

    final rootGameCount = await getGameCount(root.fen);
    final targetGameCount = (rootGameCount * targetPercent / 100).round();

    onProgress?.call(
      'Root: ${_formatNumber(rootGameCount)} games → Target: '
      '${_formatNumber(targetGameCount)} (${targetPercent.toStringAsFixed(1)}%)',
      0.05,
    );

    // The walk starts at the ROOT NODE, not at `tree.root`: every position
    // below is derived as `rootMoves + currentMoves`, so a walk that began at
    // the true root would re-apply the prefix on top of a path that already
    // contains it and compute a nonsense (usually illegal, therefore silently
    // unchanged) FEN for every node in the tree.
    final leaves = _LeafCollector(
      service: this,
      rootMoves: rootMoves,
      targetGameCount: targetGameCount,
    );
    await leaves.collect(root.node);

    onProgress?.call('Found ${leaves.leaves.length} leaf positions', 0.6);

    final byCategory = <LeafCategory, List<LeafNode>>{
      for (final category in LeafCategory.values)
        category: leaves.leaves.where((l) => l.category == category).toList(),
    };
    int gamesIn(LeafCategory category) =>
        byCategory[category]!.fold(0, (sum, l) => sum + l.gameCount);

    onProgress?.call('Calculating unaccounted moves...', 0.7);
    final unaccountedMoves = await _calculateUnaccounted(
      tree,
      leaves.positions,
      isWhiteRepertoire: isWhiteRepertoire,
      rootMoves: rootMoves,
      onProgress: onProgress,
    );

    onProgress?.call('Analysis complete!', 1.0);

    return CoverageResult(
      rootFen: root.fen,
      rootMoves: rootMoves,
      rootGameCount: rootGameCount,
      targetPercent: targetPercent,
      targetGameCount: targetGameCount,
      coveredLeaves: byCategory[LeafCategory.covered]!,
      tooShallowLeaves: byCategory[LeafCategory.tooShallow]!,
      tooDeepLeaves: byCategory[LeafCategory.tooDeep]!,
      unaccountedMoves: unaccountedMoves,
      totalCoveredGames: gamesIn(LeafCategory.covered),
      totalShallowGames: gamesIn(LeafCategory.tooShallow),
      totalDeepGames: gamesIn(LeafCategory.tooDeep),
      totalUnaccountedGames: unaccountedMoves.fold(
        0,
        (sum, m) => sum + m.gameCount,
      ),
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
  static Chess? _positionAfter(List<String> prefix, List<String> rest) {
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

  /// Opponent moves the master book (or, failing that, Maia) sees at the
  /// repertoire's opponent-to-move positions and the file does not answer.
  Future<List<UnaccountedMove>> _calculateUnaccounted(
    OpeningGraph tree,
    Map<String, List<String>> positions, {
    required bool isWhiteRepertoire,
    required List<String> rootMoves,
    CoverageProgressCallback? onProgress,
  }) async {
    final result = <UnaccountedMove>[];
    int checked = 0;
    final total = positions.length;

    for (final MapEntry(key: normalizedFen, value: pathMoves)
        in positions.entries) {
      checked++;
      if (checked % 10 == 0) {
        onProgress?.call(
          'Checking unaccounted ($checked/$total)...',
          0.7 + (0.25 * checked / total),
        );
      }

      final position = _positionAfter(rootMoves, pathMoves);
      if (position == null) continue;
      final isMyTurn = (position.turn == Side.white) == isWhiteRepertoire;
      if (isMyTurn) continue;

      final node = tree.fenToNodes[normalizedFen]?.firstOrNull;
      if (node == null || node.children.isEmpty) continue;

      final repertoireMoves = node.children.keys.toSet();
      final fen = position.fen;
      final bookMoves = await getMovesWithCounts(fen);

      if (bookMoves.isNotEmpty) {
        final totalGames = bookMoves.fold<int>(0, (s, m) => s + m.games);
        for (final bookMove in bookMoves) {
          if (repertoireMoves.contains(bookMove.san)) continue;
          result.add(
            UnaccountedMove(
              parentMoves: List<String>.from(pathMoves),
              move: bookMove.san,
              gameCount: bookMove.games,
              probability: totalGames > 0 ? bookMove.games / totalGames : 0.0,
              source: UnaccountedSource.masters,
            ),
          );
        }
      } else if (useMaia && MaiaFactory.isAvailable) {
        final maia = MaiaFactory.instance;
        if (maia == null) continue;
        try {
          final maiaResult = await maia.evaluate(fen, maiaElo);
          for (final MapEntry(key: uci, value: probability)
              in maiaResult.policy.entries) {
            if (probability < _minMaiaReplyProbability) continue;
            final san = uciToSan(fen, uci);
            if (repertoireMoves.contains(san)) continue;
            result.add(
              UnaccountedMove(
                parentMoves: List<String>.from(pathMoves),
                move: san,
                gameCount: 0,
                probability: probability,
                source: UnaccountedSource.maia,
              ),
            );
          }
        } catch (_) {
          // Maia could not evaluate this position; the book had nothing
          // either, so there is no source left to ask — skip it.
        }
      }
    }

    return result;
  }

  static String _formatNumber(int number) {
    if (number >= 1000000) {
      return '${(number / 1000000).toStringAsFixed(1)}M';
    } else if (number >= 1000) {
      return '${(number / 1000).toStringAsFixed(1)}K';
    }
    return number.toString();
  }
}

/// Depth-first collection of the repertoire's leaves below the coverage
/// root, each classified against the target game count, plus every position
/// visited on the way (normalised FEN → moves from the root).
class _LeafCollector {
  _LeafCollector({
    required this.service,
    required this.rootMoves,
    required this.targetGameCount,
  });

  final CoverageService service;
  final List<String> rootMoves;
  final int targetGameCount;

  final List<LeafNode> leaves = [];
  final Map<String, List<String>> positions = {};

  Future<void> collect(OpeningNodeView root) =>
      _visit(root, const [], firstBelowThresholdPly: null);

  /// [firstBelowThresholdPly] is the ply at which the game count first
  /// dropped below the target on this path; a leaf
  /// [CoverageService.tooDeepThresholdPly] or more beyond it is "too deep".
  Future<void> _visit(
    OpeningNodeView node,
    List<String> currentMoves, {
    required int? firstBelowThresholdPly,
  }) async {
    final position = CoverageService._positionAfter(rootMoves, currentMoves);
    if (position == null) return;

    final fen = position.fen;
    positions[normalizeFen(fen)] = List.from(currentMoves);
    final currentPly = currentMoves.length;

    if (node.children.isEmpty) {
      leaves.add(
        await _classifyLeaf(
          position,
          currentMoves,
          firstBelowThresholdPly: firstBelowThresholdPly,
        ),
      );
      return;
    }

    // Track the threshold crossing at intermediate nodes too.
    var firstBelow = firstBelowThresholdPly;
    if (firstBelow == null) {
      final gameCount = await service.getGameCount(fen);
      if (gameCount <= targetGameCount) firstBelow = currentPly;
    }
    for (final child in node.children.values) {
      await _visit(child, [
        ...currentMoves,
        child.move,
      ], firstBelowThresholdPly: firstBelow);
    }
  }

  Future<LeafNode> _classifyLeaf(
    Chess position,
    List<String> moves, {
    required int? firstBelowThresholdPly,
  }) async {
    final fen = position.fen;
    final currentPly = moves.length;
    final gameCount = await service.getGameCount(fen);
    final isGameOver = position.isGameOver;
    final belowThreshold = gameCount <= targetGameCount || isGameOver;
    final firstBelow =
        firstBelowThresholdPly ?? (belowThreshold ? currentPly : null);
    final excessPly = firstBelow != null ? currentPly - firstBelow : 0;

    final LeafCategory category;
    final String reason;
    if (isGameOver) {
      category = LeafCategory.covered;
      reason = position.isCheckmate
          ? 'Checkmate'
          : position.isStalemate
          ? 'Stalemate'
          : 'Game over';
    } else if (!belowThreshold) {
      category = LeafCategory.tooShallow;
      reason =
          'Too shallow (${CoverageService._formatNumber(gameCount)} > '
          '${CoverageService._formatNumber(targetGameCount)} target)';
    } else if (firstBelow != null &&
        excessPly >= CoverageService.tooDeepThresholdPly) {
      category = LeafCategory.tooDeep;
      reason = '$excessPly ply past threshold';
    } else {
      category = LeafCategory.covered;
      reason =
          'Covered (${CoverageService._formatNumber(gameCount)} ≤ '
          '${CoverageService._formatNumber(targetGameCount)} target)';
    }

    return LeafNode(
      fen: fen,
      moves: moves,
      gameCount: gameCount,
      category: category,
      reason: reason,
      excessPly: excessPly,
    );
  }
}
