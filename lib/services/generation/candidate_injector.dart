/// Our-move candidates that the engine's own MultiPV did not offer.
///
/// Every [NodeExpander] shares this: the setup bias, master practice, the
/// skeleton's transfers and pins all want a move to exist as a child so
/// selection has something to choose, and every one of them is scored in
/// the same single restricted search.  See [CandidateInjector.inject].
library;

import 'package:dartchess/dartchess.dart' show Move;

import '../../chess_core/generation/build_tree_node.dart';
import '../../utils/chess_utils.dart' show moveToStandardUci;
import '../../utils/fen_utils.dart';
import 'build_run.dart';
import 'generation_config.dart';
import 'setup_bias.dart';
import 'skeleton_plan.dart';

/// Where an our-move candidate came from when it was not one of the
/// engine's own MultiPV lines.  See [CandidateInjector.inject].
enum InjectionSource {
  /// Preferred-setup moves ([TreeBuildConfig.setupMoves]).
  setup,

  /// Master practice at a book position.
  master,

  /// The skeleton's move at a near-identical position.
  transfer,

  /// A move the user pinned in the skeleton.
  pin;

  /// Every source, the default for a regular our-move expansion.
  static const Set<InjectionSource> all = {setup, master, transfer, pin};
}

/// One candidate to score and, if it survives the eval-loss window, add.
class _Injection {
  _Injection(this.uci, this.move, {required this.gated});

  final String uci;
  final ChildMove move;

  /// Whether the eval-loss window applies.  A pin bypasses it: the user's
  /// choice stands even if it costs eval, and the UI warns them separately.
  bool gated;
}

/// Adds the our-move candidates a node's move source left out, one
/// restricted engine search per node.
///
/// Owns the per-run caches the sources need — the parsed setup moves, the
/// skeleton's pins by FEN and its transfer lookups — so one instance serves
/// a whole build.
class CandidateInjector {
  CandidateInjector(this.run);

  final BuildRun run;

  TreeBuildConfig get config => run.config;

  /// How many of the book's most-played moves are offered as our-move
  /// candidates at a master-practice position.
  static const int kMasterCandidateCount = 2;

  /// Setup moves, parsed once per run rather than per node.
  late final Set<String> setupSans = parseSetupMoves(config.setupMoves);

  /// Pins by canonical FEN, built once per run ([SkeletonPlan.pinsByFen]
  /// rebuilds the map on every read).
  late final Map<String, String> _pins = config.skeletonPlan.pinsByFen;

  /// Skeleton transfer lookups by FEN.  [SkeletonPlan.transferFor] compares
  /// the position against every skeleton node and is asked twice per
  /// our-move node (injection, then the alternative gate), so the answer is
  /// kept.
  final Map<String, TransferMatch?> _transfers = {};

  /// The skeleton move that transfers to [node]'s position, if any.
  TransferMatch? transferFor(BuildTreeNode node) {
    if (config.skeletonPlan.nodes.isEmpty) return null;
    return _transfers.putIfAbsent(
      node.fen,
      () => config.skeletonPlan.transferFor(
        node.fen,
        position: run.positionOf(node),
      ),
    );
  }

  /// Add our-move candidates that the engine's own MultiPV did not offer,
  /// each subject to the same eval-loss window as a regular candidate (a
  /// pin excepted).  [bestCpWhite] is the best candidate eval in white-POV
  /// centipawns (null = no reference, window not applied).
  ///
  /// The sources, in the order their moves are collected:
  ///
  ///   - **Setup** — quiet system moves (h4, Nh3, …) are often missing from
  ///     Maia/MultiPV top-N, so the selection tie-break would have nothing
  ///     to choose.
  ///   - **Master** — the moves masters actually play here are often in
  ///     MultiPV already, but not always: a theoretical main line the engine
  ///     rates a hair below a sharper try would otherwise never be a
  ///     candidate, and selection cannot choose what it never sees.  The
  ///     book's top [kMasterCandidateCount] moves with at least
  ///     [TreeBuildConfig.masterMinGames] games are offered; children that
  ///     are in the book get the year the move was last played, for the
  ///     recency annotation.
  ///   - **Transfer** — the move the user's skeleton played at the nearest
  ///     position (the experiment found Stockfish's top-8 omits ...c5 at
  ///     both 2.Nf3 and 2.Bf4), so the selector's transfer bias has
  ///     something to choose.
  ///   - **Pin** — a move the user played by hand must exist as a candidate
  ///     even when MultiPV omits it, so selection's pin override has a child
  ///     to mark.  Ungated: the user's choice stands even if it costs eval.
  ///
  /// Every candidate from every source is scored in **one** engine search
  /// (`go … searchmoves`, one PV per move) rather than one `go` apiece: the
  /// searches share the hash, and a six-move setup string no longer costs
  /// six extra searches per our-move node.  Without an engine the database
  /// chain is consulted for all candidates concurrently.
  Future<void> inject(
    BuildTreeNode node, {
    required int? bestCpWhite,
    Set<InjectionSource> sources = InjectionSource.all,
  }) async {
    final injections = _collectInjections(node, sources);

    // Year stamping is about the children that exist, not the ones this call
    // adds: an empty candidate list means the book's top moves are already
    // children (the common case once MultiPV covers them), and those still
    // need their `[%lastPlayed]`.  Stamping therefore runs on every path out.
    if (injections.isNotEmpty) {
      final scoredByUci = await _scoreInjections(node, injections);

      for (final injection in injections) {
        final scored = scoredByUci[injection.uci];
        if (scored == null) continue; // unevaluable here
        final (cpWhite, depth) = scored;
        if (injection.gated && bestCpWhite != null) {
          final evalLoss = node.isWhiteToMove
              ? bestCpWhite - cpWhite
              : cpWhite - bestCpWhite;
          if (evalLoss > config.maxEvalLossCp) continue;
        }
        _addInjected(node, injection, cpWhite, depth: depth);
      }
    }

    if (sources.contains(InjectionSource.master)) _stampBookYears(node);
  }

  /// The distinct legal candidates [sources] offer at [node] that are not
  /// already children.  A move offered by several sources is kept once; a
  /// pin makes it ungated whichever source listed it first.
  List<_Injection> _collectInjections(
    BuildTreeNode node,
    Set<InjectionSource> sources,
  ) {
    final byUci = <String, _Injection>{};

    /// Whether [uci] is (now) an injection: false when illegal here or
    /// already a child.  A move several sources offer is kept once.
    bool offer(String uci, {required bool gated}) {
      final existing = byUci[uci];
      if (existing != null) {
        existing.gated = existing.gated && gated;
        return true;
      }
      final played = run.childMove(node, uci);
      if (played == null) return false; // not legal here
      if (node.children.any((c) => c.fen == played.fen || c.moveUci == uci)) {
        return false; // already a candidate
      }
      byUci[uci] = _Injection(uci, played, gated: gated);
      return true;
    }

    if (sources.contains(InjectionSource.setup) && setupSans.isNotEmpty) {
      final position = run.positionOf(node);
      for (final san in setupSans) {
        final Move? move;
        try {
          move = position.parseSan(san);
        } catch (_) {
          // dartchess rejects a malformed SAN by throwing rather than
          // returning null; a bad token in the setup string is not a
          // candidate, not a failed build.
          continue;
        }
        if (move == null) continue; // not legal here (or already played)
        offer(moveToStandardUci(position, move), gated: true);
      }
    }

    if (sources.contains(InjectionSource.master) && run.masterBook != null) {
      final book = run.bookAt(node.fen); // most played first
      if (run.masterGamesAt(node.fen) >= config.masterMinGames) {
        // The top [kMasterCandidateCount] book moves are the candidates,
        // whether or not the engine offered them too: the rule is "what
        // masters play", not "what the engine missed".
        var considered = 0;
        for (final m in book) {
          if (considered >= kMasterCandidateCount) break;
          if (m.games < config.masterMinGames) break; // sorted by games desc
          considered++;
          if (offer(m.uci, gated: true)) run.stats.masterCandidatesInjected++;
        }
      }
    }

    if (sources.contains(InjectionSource.transfer)) {
      // Only at our-move nodes we did not pin (a pinned node's move is
      // already a candidate through the normal sources, or will be forced by
      // selection).
      final match = transferFor(node);
      if (match != null) offer(match.uci, gated: true);
    }

    if (sources.contains(InjectionSource.pin) && _pins.isNotEmpty) {
      final uci = _pins[normalizeFen(node.fen)];
      if (uci != null) offer(uci, gated: false);
    }

    return byUci.values.toList();
  }

  /// White-POV score per candidate, by UCI, *with the depth it was searched
  /// to*.  Moves the engine (or the database) could not score are absent.
  ///
  /// The depth travels with the score because the two sources do not agree
  /// on it: a MultiPV search really did reach [TreeBuildConfig.evalDepth],
  /// while the database chain answers at whatever depth it happens to hold.
  /// Writing the latter into the cache as full-depth would let a shallow
  /// ChessDB number outrank a real search and never be refined.
  Future<Map<String, (int cpWhite, int depth)>> _scoreInjections(
    BuildTreeNode node,
    List<_Injection> injections,
  ) async {
    final out = <String, (int, int)>{};
    if (config.usesStockfish && run.pool.workerCount > 0) {
      final discovery = await run.pool.discoverMoves(
        fen: node.fen,
        depth: config.evalDepth,
        multiPv: injections.length,
        isWhiteToMove: node.isWhiteToMove,
        searchMoves: [for (final i in injections) i.uci],
      );
      run.stats.sfMultipvCalls++;
      // Discovery scores are White-POV already.
      for (final line in discovery.lines) {
        if (line.moveUci.isNotEmpty) {
          out[line.moveUci] = (line.effectiveCp, config.evalDepth);
        }
      }
      return out;
    }

    final evals = await Future.wait([
      for (final i in injections)
        run.evalResolver.lookupDbEvalWhite(i.move.fen, config),
    ]);
    for (var k = 0; k < injections.length; k++) {
      final eval = evals[k];
      if (eval != null) out[injections[k].uci] = (eval.$1, eval.$2);
    }
    return out;
  }

  void _addInjected(
    BuildTreeNode node,
    _Injection injection,
    int cpWhite, {
    required int depth,
  }) {
    final child = run.makeChild(
      parent: node,
      fen: injection.move.fen,
      san: injection.move.san,
      uci: injection.uci,
      position: injection.move.after,
    );
    if (child == null) return;

    child.moveProbability = 1.0;
    child.cumulativeProbability = node.cumulativeProbability;
    child.engineEvalCp = child.isWhiteToMove ? cpWhite : -cpWhite;
    run.evalResolver.cacheEvalWhite(child.fen, cpWhite, depth);

    run.emitNodeProgress(child);
  }

  /// Give every child that is in the book the year its move was last
  /// played, when nothing set it yet.
  void _stampBookYears(BuildTreeNode node) {
    if (run.masterBook == null) return;
    final book = run.bookAt(node.fen);
    if (book.isEmpty) return;
    final yearByUci = {for (final m in book) m.uci: m.lastYear};
    for (final child in node.children) {
      final y = yearByUci[child.moveUci];
      if (y != null && y > 0 && child.lastPlayedYear <= 0) {
        child.lastPlayedYear = y;
      }
    }
  }
}
