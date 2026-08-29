/// Per-run state for a single tree build.
///
/// [BuildRun] is the context object threaded through the build loop and the
/// per-mode [NodeExpander]s.  It owns everything that must exist exactly
/// once per run — the cancellation token, the stopwatch, the node-id
/// allocator, statistics, the debug log, and progress emission — so the
/// expansion code never reaches back into `TreeBuildService` instance
/// fields.  This is what makes concurrent misuse (two builds sharing one
/// service) fail loudly at the entry point instead of corrupting state.
library;

import 'dart:collection';
import 'dart:math' as math;

import 'package:dartchess/dartchess.dart';

import '../../models/build_tree_node.dart';
import '../../utils/chess_utils.dart' show playUciFrom, tryParseFen;
import '../../utils/fen_utils.dart';
import '../engine/stockfish_pool.dart';
import '../master_games/master_games_db.dart' show BookLookup, BookMove;
import '../master_games/position_key.dart';
import 'fen_map.dart';
import 'generation_config.dart';
import 'run_debug_dump.dart';
import 'tree_build_progress.dart';
import 'tree_eval_resolver.dart';

/// Unified cancellation token for one build run.
///
/// A build stops for exactly one of two reasons and every loop must honor
/// both: the owner called `TreeBuildService.stopBuild()` ([stopRequested]),
/// or the caller's `isCancelled` callback flipped ([externallyCancelled]).
/// Historically these were checked inconsistently (`_isBuilding` here, the
/// callback there), which let a callback-cancelled build keep sweeping.
/// Check [isCancelled] and nothing else.
class BuildCancellation {
  final bool Function() _external;
  bool _stopRequested = false;

  BuildCancellation({bool Function()? isCancelledExternally})
    : _external = isCancelledExternally ?? (() => false);

  /// True once `stopBuild()` was called on the owning service.
  bool get stopRequested => _stopRequested;

  /// True when the caller's cancel callback reports cancellation.
  bool get externallyCancelled => _external();

  /// The one check every build loop uses.
  bool get isCancelled => _stopRequested || _external();

  void requestStop() => _stopRequested = true;
}

/// A move played from a parent node, with everything a child needs.
typedef ChildMove = ({String fen, String san, Position after});

/// State owned by one call to `build()` / `buildFromPgnFreqMap()`.
class BuildRun {
  /// Effective config.  Mutable because `relativeEval` shifts the eval
  /// window once the root eval is known.
  TreeBuildConfig config;

  /// Master-games book for opponent priors (null when the database is
  /// absent or switched off): what titled players reply from a position,
  /// blended with Maia the same way a scanned PGN database is.
  final BookLookup? masterBook;

  final BuildTree tree;
  final FenMap fenMap;
  final StockfishPool pool;
  final TreeEvalResolver evalResolver;
  final BuildStats stats;
  final RunDebugLog runLog;
  final TreeBuildProgressTracker progress;
  final void Function(BuildProgress) onProgress;
  final BuildCancellation cancel;

  /// Stops BFS expansion but still runs the coverage sweep and post-build
  /// prune (unlike [cancel], which abandons downstream phases).
  final bool Function() finishNow;

  /// Pause gate, provided by the owning service — pause outlives a single
  /// run (phase 2 shares it), so the service owns the completer.
  final Future<void> Function() waitIfPaused;

  /// Active-build stopwatch; the service pauses it with the pause gate.
  final Stopwatch stopwatch = Stopwatch();

  /// Next node id to allocate; [makeChild] is the only writer during a run.
  int nextNodeId;

  BuildRun({
    required this.config,
    required this.tree,
    required this.fenMap,
    required this.pool,
    required this.evalResolver,
    required this.stats,
    required this.runLog,
    required this.progress,
    required this.onProgress,
    required this.cancel,
    required this.finishNow,
    required this.waitIfPaused,
    required this.nextNodeId,
    this.masterBook,
  }) {
    seedDepthHistogram();
  }

  bool get isCancelled => cancel.isCancelled;

  // ── Concurrency ─────────────────────────────────────────────────────────

  /// How many frontier nodes the build loop expands at once.
  ///
  /// One per engine worker when the engine is the bottleneck — each lane
  /// keeps a worker busy while the others wait on Maia, the database or the
  /// eval cache — capped by the configured thread budget so a pool left over
  /// from interactive analysis cannot oversubscribe the machine.  Modes that
  /// never touch the engine run a single lane: Maia inference is serialised
  /// on one ORT session anyway, and one lane keeps their expansion order
  /// deterministic.
  int get expansionLanes {
    if (!config.usesStockfish) return 1;
    final budget = math.max(1, config.resolvedEngineThreads);
    return pool.workerCount.clamp(1, budget);
  }

  // ── Positions ───────────────────────────────────────────────────────────

  /// Parsed positions by node id, most recently used last.  A node is
  /// expanded once, but its position is read several times on the way — for
  /// every child derived from it, for candidate injection, and again if the
  /// coverage sweep revisits it — so the parse is kept for a while.  Bounded
  /// because a best-first frontier can hold tens of thousands of nodes.
  final LinkedHashMap<int, Position> _positions = LinkedHashMap();
  static const int _positionCacheSize = 4096;

  /// The position [node] stands in, parsed at most once per node while it
  /// stays in the cache.  Children created by [makeChild] with their
  /// [Position] never parse at all.
  Position positionOf(BuildTreeNode node) =>
      positionOrNullOf(node) ?? Chess.initial;

  /// [positionOf] without the substitution: null when [node]'s FEN does not
  /// parse.  Anything that *derives* a position from a node — every
  /// expander's child creation, through [childMove] — must refuse instead,
  /// or the move is played from the initial board and the child ends up
  /// describing a position the tree never reached.  The failure is also not
  /// memoised, so a substitute board cannot poison later reads.
  Position? positionOrNullOf(BuildTreeNode node) {
    final cached = _positions.remove(node.nodeId);
    if (cached != null) {
      _positions[node.nodeId] = cached; // Refresh recency.
      return cached;
    }
    final parsed = tryParseFen(node.fen);
    if (parsed == null) return null;
    _rememberPosition(node.nodeId, parsed);
    return parsed;
  }

  void _rememberPosition(int nodeId, Position position) {
    _positions[nodeId] = position;
    if (_positions.length > _positionCacheSize) {
      _positions.remove(_positions.keys.first);
    }
  }

  /// [uci] played from [parent]: the child's FEN, SAN and position, or null
  /// when [parent]'s FEN does not parse or the move is illegal there.  One legality check and one move
  /// generation, against a position that is parsed once per parent — every
  /// expander used to re-parse the parent's FEN twice per child.
  ChildMove? childMove(BuildTreeNode parent, String uci) {
    final from = positionOrNullOf(parent);
    if (from == null) return null;
    final played = playUciFrom(from, uci);
    if (played == null) return null;
    return (fen: played.after.fen, san: played.san, after: played.after);
  }

  // ── Master practice ─────────────────────────────────────────────────────

  /// Book rows by canonical position, filled on first lookup.
  ///
  /// The book is asked about the same position many times over — for the
  /// reply fan-out, our-move injection, the depth cap, and once *per child*
  /// for the priority factor — so without this an our-move node with eight
  /// children issued ten identical `SELECT`s, and the query counters below
  /// measured that repetition rather than how often the book knew anything.
  final Map<int, List<BookMove>> _bookByPosition = {};
  final Map<int, int> _bookGamesByPosition = {};

  /// Book moves from [fen]; empty when there is no book, the position is
  /// unknown, or the lookup fails (logged once per position, never thrown —
  /// a broken database must not kill a build).
  List<BookMove> bookAt(String fen) {
    final lookup = masterBook;
    if (lookup == null) return const [];
    final key = positionKey(fen);
    final cached = _bookByPosition[key];
    if (cached != null) return cached;

    List<BookMove> moves;
    try {
      moves = lookup(fen);
      // Counted here because this is the single funnel every book read goes
      // through — reply candidates, our-move injection and the depth cap
      // all land on it — and counted once per position, not per read.
      stats.masterBookQueries++;
      if (moves.isNotEmpty) stats.masterBookHits++;
    } catch (e) {
      log('Master book lookup failed @ $fen: $e');
      moves = const [];
    }
    _bookByPosition[key] = moves;
    var games = 0;
    for (final m in moves) {
      games += m.games;
    }
    _bookGamesByPosition[key] = games;
    return moves;
  }

  /// Master games from [fen] (sum over moves); 0 off-book.
  int masterGamesAt(String fen) {
    if (masterBook == null) return 0;
    final key = positionKey(fen);
    final cached = _bookGamesByPosition[key];
    if (cached != null) return cached;
    bookAt(fen);
    return _bookGamesByPosition[key] ?? 0;
  }

  /// True when [fen] is master practice: a book is in use and the position
  /// has at least [TreeBuildConfig.masterMinGames] games.
  bool isMasterPractice(String fen) {
    if (masterBook == null) return false;
    final games = masterGamesAt(fen);
    if (games < config.masterMinGames) return false;
    stats.masterPracticeHits++;
    stats.masterGamesAtHits += games;
    return true;
  }

  /// Search-order multiplier for [fen]: `1 + weight * ln(1 + games)` over the
  /// master games there, 1.0 off-book or with the weight at 0.  Kept on the
  /// edge (see [BuildTreeNode.searchPriorityDiscount]) so a priority rebuild
  /// re-derives it instead of dropping back to raw reach probability.
  double masterPriorityFactor(String fen) {
    final weight = config.masterPriorityWeight;
    if (weight <= 0 || masterBook == null) return 1.0;
    final games = masterGamesAt(fen);
    if (games <= 0) return 1.0;
    return 1.0 + weight * math.log(1 + games);
  }

  /// Where the build stops for a node in [fen] at [ply]: [TreeBuildConfig.
  /// maxPly], extended by [TreeBuildConfig.masterDepthBonusPlies] while the
  /// position is master practice.  The extension is per position, not per
  /// line — the first off-book position past [maxPly] ends the line, so
  /// depth follows the book and nothing else.
  int plyCapAt(String fen, int ply) {
    final base = config.maxPly;

    // The ChessDB book inverts the usual bargain. [maxPly] caps *branching*
    // there and nothing else — [ChessDbBookExpander.expandOpponentMove]
    // enforces it by taking a single database move past that depth. Every
    // line then costs a node per ply rather than a fan-out, so depth is
    // cheap and the mainline runs on until ChessDB stops answering. Capping
    // it here as well would truncate exactly the deepest theory the book
    // exists to carry.
    if (config.isChessDbBook) return config.resolvedBookTailMaxPly;

    final bonus = config.masterDepthBonusPlies;
    if (bonus <= 0 || ply < base || masterBook == null) return base;
    if (!isMasterPractice(fen)) return base;
    stats.masterDepthBonusGrants++;
    return base + bonus;
  }

  // ── Budget ──────────────────────────────────────────────────────────────

  /// True once [TreeBuildConfig.timeBudgetMinutes] of active build time has
  /// elapsed (0 = no budget).  The stopwatch is paused with the pause gate,
  /// so a paused build does not burn its budget.
  bool get budgetExhausted =>
      budgetSpent(stopwatch.elapsed, config.timeBudgetMinutes);

  /// Whether [elapsed] has used up a [minutes]-long budget, plus [grace] of
  /// it again.  Zero or negative [minutes] means no budget at all.
  ///
  /// Pure so the thresholds can be pinned without waiting on a real clock.
  static bool budgetSpent(Duration elapsed, int minutes, {double grace = 0}) {
    if (minutes <= 0) return false;
    return elapsed.inSeconds >= minutes * 60 * (1 + grace);
  }

  /// The one "stop expanding, but still finish the run cleanly" check:
  /// either the owner pressed Finish now, or the time budget ran out.
  /// Unlike [isCancelled] this still runs the coverage sweep, selection and
  /// export, and leaves the tree resumable.
  bool shouldFinish() => finishNow() || budgetExhausted;

  /// Extra share of [TreeBuildConfig.timeBudgetMinutes] the coverage sweep
  /// may spend after the search loop has stopped.
  ///
  /// The sweep runs *because* the budget ran out — it answers the holes the
  /// search was cut off before reaching — so gating it on [budgetExhausted]
  /// would skip it entirely on exactly the builds that need it.  It cannot be
  /// unbounded either: an overnight Benko build stopped its search on time at
  /// 300 minutes and then swept for 152 more, answering 4,590 holes, for a
  /// run half again as long as asked for.  The overrun grows with whatever
  /// frontier was left, so the tighter the budget the worse it gets.
  static const double coverageSweepGrace = 0.2;

  /// True once the budget *and* the coverage sweep's grace have elapsed.
  /// Past this the sweep stops answering holes and just removes the leaves it
  /// did not get to, which keeps the invariant it exists for — no line ends
  /// on an opponent move we have no reply to — without more engine work.
  bool get sweepBudgetExhausted => budgetSpent(
    stopwatch.elapsed,
    config.timeBudgetMinutes,
    grace: coverageSweepGrace,
  );

  void log(String msg) => runLog.add('[TreeBuild] $msg');

  // ── Tree mutation ───────────────────────────────────────────────────────

  /// Create, register, and index a child of [parent], or return null when a
  /// sibling already covers [fen] (castling-representation dedup).
  ///
  /// Pass [position] when the caller derived the child by playing a move —
  /// [childMove] does — so the child's own expansion never parses its FEN.
  BuildTreeNode? makeChild({
    required BuildTreeNode parent,
    required String fen,
    required String san,
    required String uci,
    Position? position,
  }) {
    if (parent.children.any((c) => c.fen == fen)) return null;

    final child = BuildTreeNode(
      fen: fen,
      moveSan: san,
      moveUci: uci,
      ply: parent.ply + 1,
      isWhiteToMove: position != null
          ? position.turn == Side.white
          : isWhiteToMove(fen),
      nodeId: nextNodeId++,
      parent: parent,
    );
    parent.children.add(child);
    tree.registerNode(child);
    tree.totalNodes++;
    child.extEvalMode = parent.extEvalMode;
    if (child.ply > tree.maxPlyReached) {
      tree.maxPlyReached = child.ply;
    }
    if (position != null) _rememberPosition(child.nodeId, position);
    _countNode(child.ply, 1);
    return child;
  }

  /// Mark [node] fully processed.  Every `explored = true` in the build goes
  /// through here so the per-ply histogram stays exact without a tree walk.
  void markExplored(BuildTreeNode node) {
    if (node.explored) return;
    node.explored = true;
    _countExplored(node.ply, 1);
  }

  /// Detach the childless [node] from the tree (coverage sweep removal).
  void removeLeaf(BuildTreeNode node) {
    final parent = node.parent;
    if (parent == null) return;
    if (!parent.children.remove(node)) return;
    tree.nodeIndex.remove(node.nodeId);
    tree.totalNodes--;
    _positions.remove(node.nodeId);
    _countNode(node.ply, -1);
    if (node.explored) _countExplored(node.ply, -1);
  }

  // ── Depth histogram ─────────────────────────────────────────────────────

  /// Per-ply node counts, index = ply, maintained incrementally by
  /// [makeChild] / [markExplored] / [removeLeaf].
  ///
  /// Progress used to rebuild these with a full tree walk on every emitted
  /// event — at the 250 ms emit cap on a 30k-node tree that is well over a
  /// hundred thousand node visits per second on the UI isolate, for two
  /// lists of integers.
  List<int> get depthTotals => List.unmodifiable(_depthTotals);
  List<int> get depthExplored => List.unmodifiable(_depthExplored);
  final List<int> _depthTotals = [];
  final List<int> _depthExplored = [];

  /// Recount from the tree.  Called once per run at construction; a resumed
  /// build's saved nodes are counted here and never again.
  void seedDepthHistogram() {
    _depthTotals.clear();
    _depthExplored.clear();
    final (totals, explored) = TreeBuildProgressTracker.depthHistogram(
      tree.root,
    );
    _depthTotals.addAll(totals);
    _depthExplored.addAll(explored);
  }

  void _countNode(int ply, int delta) {
    _growHistogram(ply);
    _depthTotals[ply] += delta;
  }

  void _countExplored(int ply, int delta) {
    _growHistogram(ply);
    _depthExplored[ply] += delta;
  }

  void _growHistogram(int ply) {
    while (_depthTotals.length <= ply) {
      _depthTotals.add(0);
      _depthExplored.add(0);
    }
  }

  /// Throttled progress emission anchored at [node].
  void emitNodeProgress(BuildTreeNode node) {
    progress.emitProgress(
      tree,
      node.ply,
      node.fen,
      onProgress,
      config.maxPly,
      buildSw: stopwatch,
      depthTotals: _depthTotals,
      depthExplored: _depthExplored,
    );
  }
}

/// Highest node id in [node]'s subtree — resume seeds the id allocator past
/// every id the loaded tree already uses.
int findMaxNodeId(BuildTreeNode node) {
  int maxId = node.nodeId;
  for (final child in node.children) {
    final childMax = findMaxNodeId(child);
    if (childMax > maxId) maxId = childMax;
  }
  return maxId;
}
