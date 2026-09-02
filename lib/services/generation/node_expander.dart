/// Per-mode node expansion strategies for the tree builder.
///
/// The build loop (`TreeBuildService._processBuildNode`) owns the plumbing
/// every mode shares — coverage floor, probability/budget floors, eval
/// window, transposition detection.  What differs per [BuildMode] is how a
/// node grows children, and that lives here behind [NodeExpander]:
///
///   - [StockfishExpander] (`BuildMode.stockfishExpectimax`): our moves
///     from Stockfish MultiPV, opponent moves from the master-games book
///     blended with Maia, or Maia alone.
///   - [MaiaDbExpander] (`BuildMode.maiaDbExplore`): our moves from Maia's
///     policy filtered to positions with database evals; same opponent
///     sources.
///   - [ChessDbBookExpander] (`BuildMode.chessDbBook`): one move per position
///     — whatever ChessDB ranks best — with opponent replies from master
///     practice only, and a single-mainline tail once practice runs out.
///
/// Adding a build mode means adding a subclass, not another copy of the
/// expansion plumbing.  The opponent-children loop in particular exists
/// exactly once ([addOpponentChildren]) — its coverage-floor semantics were
/// historically copy-pasted per source and had already drifted.
///
/// Every child is derived from its parent's parsed [Position] through
/// [BuildRun.childMove]: one legality check and one move generation per
/// child, against a position parsed once per node.  Nothing here parses a
/// FEN string to play a move.
library;

import 'dart:async';

import 'package:dartchess/dartchess.dart' show Move;

import '../../models/build_tree_node.dart';
import '../../utils/chess_utils.dart' show moveToStandardUci;
import '../../utils/fen_utils.dart';
import '../maia/maia_factory.dart';
import '../../models/analysis/discovery_result.dart';
import '../maia/maia_service.dart';
import '../eval/db_move_list.dart';
import 'build_run.dart';
import 'frontier_queue.dart';
import 'generation_config.dart';
import 'opponent_prior.dart';
import 'setup_bias.dart';
import 'skeleton_plan.dart';

part 'chessdb_book_expander.dart';
part 'maia_db_expander.dart';
part 'stockfish_expander.dart';

/// Move probability assigned to an engine-injected PV continuation when
/// Maia has no opinion on it.  Small but non-zero: the move must survive
/// probability floors so the engine's expected reply is present in the
/// tree, without meaningfully distorting the expectimax tail mass.
const double kPvInjectEpsilon = 0.01;

/// Apply the eval window to [node]: outside [TreeBuildConfig.minEvalCp] /
/// [TreeBuildConfig.maxEvalCp] the node gets an explicit [PruneReason] and
/// true is returned (caller stops expanding it).  No-op without an eval.
///
/// The window judges *our* choices, never theirs. Concretely, the too-low
/// half only applies where the opponent is the side to move — a position we
/// walked into, so rejecting it rejects our own move. At a node where **we**
/// are to move, the opponent put us there; calling it too bad and deleting
/// it does not make the move go away, it just means the repertoire has
/// nothing to say when they play it. A position we are forced into still
/// needs an answer, and the worse it is the more we need one.
///
/// This is not hypothetical. On a Benko tree whose root sat at -57cp for
/// Black, a `minEvalCp` of 0 anchored the floor to -57; 6.Nc3 — which Maia
/// gives 73.9% of White's replies — evaluated -76, was flagged here, and
/// [pruneEvalTooLow] deleted the whole subtree. 6.dxe6 at 19.3% survived by
/// two centipawns. The exported repertoire covered under a fifth of what
/// White actually plays and said nothing about the rest.
///
/// Too-high is unchanged and applies to both sides: [PruneReason.evalTooHigh]
/// keeps the node as an annotated leaf rather than deleting it, so it leaves
/// no hole — it only says "you are winning, stop preparing".
///
/// Depth in a bad position is still controlled, just by the gates that
/// belong to it: [TreeBuildConfig.maxEvalLossCp] on our candidate moves, the
/// reach-probability floor, and the expectimax value.
bool evalWindowPrune(BuildTreeNode node, TreeBuildConfig config) {
  if (!node.hasEngineEval) return false;
  final evalUs = node.evalForUs(config.playAsWhite);
  if (evalUs > config.maxEvalCp) {
    node.pruneReason = PruneReason.evalTooHigh;
    node.pruneEvalCp = evalUs;
    return true;
  }
  if (evalUs < config.minEvalCp) {
    // We are the side to move here, so the opponent chose this position for
    // us. Never delete it for being unpleasant.
    if (node.isWhiteToMove == config.playAsWhite) return false;
    node.pruneReason = PruneReason.evalTooLow;
    node.pruneEvalCp = evalUs;
    return true;
  }
  return false;
}

/// Add opponent children to [node] from probability-ranked [candidates].
///
/// This is the single implementation of the opponent fan-out policy, shared
/// by every candidate source (master book, Maia policy, PGN frequency
/// map).  Per candidate, in order:
///
///   1. Coverage floor: a reply at/above [TreeBuildConfig.coverMinProb]
///      local probability bypasses every other filter — it must exist in
///      the tree or the no-silent-holes guarantee breaks.
///   2. Node budget ([respectMaxNodes]), stopping the fan-out.
///   3. Noise filter: fewer than [minGames] observations (skipped while
///      Dirichlet smoothing is on — the prior replaces it).
///   4. Per-move probability floor [minMoveProb].
///   4b. Well-played exemption: a move with at least [wellPlayedGames]
///      recorded games skips the [minMoveProb] floor. That floor is tuned to
///      Maia policy noise; a move masters have actually played hundreds of
///      times is evidence of a different kind and must not be filtered as
///      though it were a weak policy entry.
///   5. Fan-out caps: [maxChildren] count and [massTarget] cumulative
///      probability mass, both stopping the fan-out.  Pass 0 for either to
///      lift it — the root does, because breadth at one position is nearly
///      free and it is where "cover every system" is decided.
///   6. Reach floor: cumulative probability below
///      [TreeBuildConfig.minProbability] skips the move.
///
/// Children get raw (unrenormalized) probabilities — Σpᵢ ≤ 1 — because the
/// expectimax tail term accounts for uncovered mass; renormalizing would
/// silently bias V.  [attachStats] copies per-move W/B/D onto children
/// (book sources only — frequency-map counts carry no outcome split worth
/// storing).  [onChild] runs for each added child (e.g. direct enqueue).
void addOpponentChildren({
  required BuildRun run,
  required BuildTreeNode node,
  required List<SmoothedMove> candidates,
  required bool smoothing,
  int minGames = 0,
  double minMoveProb = 0.0,
  int wellPlayedGames = 0,
  int maxChildren = 0,
  double massTarget = 0.0,
  bool respectMaxNodes = false,
  bool attachStats = false,
  bool emitProgressPerChild = true,
  void Function(BuildTreeNode child)? onChild,
}) {
  final config = run.config;
  final basePri = effectiveSearchPriority(node);
  int childrenAdded = 0;
  double massCovered = 0.0;

  // A planned build may hand replies at the root to sibling chapters. This
  // runs *before* the coverage-floor bypass on purpose (see README, "One
  // deliberate exception"): each excluded reply is the root of another
  // chapter in the same plan, so leaving it out here is ownership, not a
  // hole.
  final excluded = config.rootReplyExclude.isNotEmpty && node.ply == 0
      ? {for (final san in config.rootReplyExclude) normalizeSetupSan(san)}
      : const <String>{};

  for (final move in candidates) {
    // Played once per candidate; illegal moves (a stale book row, a Maia
    // token that does not fit the position) are skipped before any gate.
    final played = run.childMove(node, move.uci);
    if (played == null) continue;
    final san = move.san.isNotEmpty ? move.san : played.san;

    if (excluded.isNotEmpty && excluded.contains(normalizeSetupSan(san))) {
      continue;
    }
    final prob = move.probability;
    final newCumul = node.cumulativeProbability * prob;
    final covered = config.coverMinProb > 0.0 && prob >= config.coverMinProb;
    // Recorded practice, not a share of the position: a move masters have
    // played this often is never dropped for being a small slice.
    final wellPlayed = wellPlayedGames > 0 && move.games >= wellPlayedGames;
    if (!covered) {
      if (respectMaxNodes &&
          config.maxNodes > 0 &&
          run.tree.totalNodes >= config.maxNodes) {
        break;
      }
      if (!smoothing && move.games < minGames) continue;
      if (prob < minMoveProb && !wellPlayed) continue;
      if (maxChildren > 0 && childrenAdded >= maxChildren) break;
      if (massTarget > 0.0 && massCovered >= massTarget) break;
      if (newCumul < config.minProbability) continue;
    }

    final child = run.makeChild(
      parent: node,
      fen: played.fen,
      san: san,
      uci: move.uci,
      position: played.after,
    );
    if (child == null) continue;

    child.moveProbability = prob;
    child.cumulativeProbability = newCumul;
    // Master practice earns search order, not just candidacy: a reply
    // masters have actually played is expanded before an equally likely one
    // nobody has. Stored on the edge so a priority rebuild keeps it.
    final masterFactor = run.masterPriorityFactor(played.fen);
    child.searchPriority = basePri * prob * masterFactor;
    child.searchPriorityDiscount = masterFactor;
    if (attachStats && move.games > 0) {
      child.setLichessStats(move.whiteWins, move.blackWins, move.draws);
    }
    childrenAdded++;
    massCovered += prob;

    onChild?.call(child);
    if (emitProgressPerChild) run.emitNodeProgress(child);
  }
}

/// Maia policy for Dirichlet smoothing, or empty when smoothing is off,
/// Maia is unavailable, or [totalGames] is large enough that the prior's
/// weight would be negligible (saves the inference).
///
/// Top-level because both the [NodeExpander]s and the PGN frequency-map
/// build (which has no expander) smooth opponent frequencies the same way.
Future<Map<String, double>> maiaPolicyForSmoothing(
  BuildRun run,
  String fen,
  int totalGames,
) async {
  final config = run.config;
  if (!smoothingWorthwhile(totalGames, config.maiaPriorGames)) {
    return const {};
  }
  if (!MaiaFactory.isAvailable || MaiaFactory.instance == null) {
    return const {};
  }
  try {
    final sw = Stopwatch()..start();
    final result = await MaiaFactory.instance!.evaluate(fen, config.maiaElo);
    run.stats.maiaEvals++;
    run.stats.maiaTotalMs += sw.elapsedMilliseconds;
    return applyPolicyTemperature(result.policy, config.oppPolicyTemperature);
  } catch (e) {
    run.log('Maia prior lookup failed @ $fen: $e');
    return const {};
  }
}

/// Where an our-move candidate came from when it was not one of the
/// engine's own MultiPV lines.  See [NodeExpander.injectCandidates].
enum InjectionSource {
  /// Preferred-setup moves ([TreeBuildConfig.setupMoves]).
  setup,

  /// Master practice at a book position.
  master,

  /// The skeleton's move at a near-identical position.
  transfer,

  /// A move the user pinned in the skeleton.
  pin,
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

/// Strategy for growing a node's children in one [BuildMode].
abstract class NodeExpander {
  final BuildRun run;

  NodeExpander(this.run);

  /// The expander for [run]'s configured build mode.
  ///
  /// `BuildMode.dbExplorer` never reaches here — it has its own entry point
  /// driven by the PGN frequency map rather than per-node move sources.
  factory NodeExpander.forRun(BuildRun run) => switch (run.config.buildMode) {
    BuildMode.maiaDbExplore => MaiaDbExpander(run),
    BuildMode.chessDbBook => ChessDbBookExpander(run),
    _ => StockfishExpander(run),
  };

  TreeBuildConfig get config => run.config;

  /// Expand an our-move node: generate candidates, attach evals, assign
  /// best-first priorities, and enqueue the children that deserve subtrees.
  ///
  /// [coverageOnly]: the node exists to answer a coverage-floor opponent
  /// move — add evaluated children but grow no subtrees (they stay
  /// unexplored leaves a future resume can deepen).
  Future<void> expandOurMove(
    BuildTreeNode node,
    FrontierQueue queue, {
    bool coverageOnly = false,
  });

  /// Expand an opponent node and enqueue all children — eval-window checks
  /// happen when each child is dequeued.
  ///
  /// Candidates come from the master-games book when the run has one and
  /// the position is in it (titled-player frequencies blended with Maia,
  /// exactly like a scanned PGN database in [BuildMode.dbExplorer]), else
  /// from Maia's policy alone.
  Future<void> expandOpponentMove(
    BuildTreeNode node,
    FrontierQueue queue,
  ) async {
    final fromBook = await _addOpponentChildrenFromMasterBook(node);
    if (!fromBook) {
      // Off-book (or no book at all).  With a book in use, an off-book
      // position is one no master has reached: fan out narrowly and let the
      // budget go to depth in the lines that are practice.
      await _addOpponentChildrenFromMaia(
        node,
        maiaForInject: true,
        offBook: run.masterBook != null,
      );
    }
    if (node.children.isEmpty) return;

    enqueueChildren(List.of(node.children), queue);
  }

  /// Put [children] on the frontier and warm Maia for them.
  ///
  /// Every child's own expansion will ask Maia about its position — for the
  /// opponent's reply distribution or for our moves' naturalness — and Maia
  /// inference is serialised on one ORT session.  Asking now, while the
  /// engine is busy with the next frontier node, is the overlap that keeps
  /// both busy; by the time the child is popped its policy is a cache hit.
  void enqueueChildren(Iterable<BuildTreeNode> children, FrontierQueue queue) {
    for (final child in children) {
      if (run.isCancelled) break;
      queue.add(child);
      prefetchMaia(child.fen);
    }
  }

  /// Start a Maia inference for [fen] without waiting for it.  Errors are
  /// dropped: the real read handles them when it happens.
  void prefetchMaia(String fen) {
    final maia = MaiaFactory.instance;
    if (!MaiaFactory.isAvailable || maia == null) return;
    unawaited(maia.evaluate(fen, config.maiaElo).then((_) {}, onError: (_) {}));
  }

  // ── Shared opponent sources ─────────────────────────────────────────────

  /// Below this many book games the position is too thin to drive
  /// expansion on its own; Maia (through smoothing) must be there too.
  static const int _minBookGamesWithoutMaia = 5;

  /// Master-games book source.  Returns false when the run has no book, the
  /// position is unknown, or the sample is too thin to use without Maia —
  /// the caller then falls back to the Maia-only source.
  ///
  /// [smoothWithMaia] off makes the frequencies literal — the ChessDB book
  /// wants recorded practice and nothing else, and the Dirichlet prior adds
  /// moves that are merely plausible.
  Future<bool> _addOpponentChildrenFromMasterBook(
    BuildTreeNode node, {
    bool smoothWithMaia = true,
  }) async {
    if (run.masterBook == null) return false;
    final book = run.bookAt(node.fen);
    if (book.isEmpty) return false;

    var total = 0;
    var whiteWins = 0;
    var draws = 0;
    var blackWins = 0;
    for (final m in book) {
      total += m.games;
      whiteWins += m.whiteWins;
      draws += m.draws;
      blackWins += m.blackWins;
    }
    if (total <= 0) return false;

    final maia = smoothWithMaia
        ? await maiaPolicyForSmoothing(run, node.fen, total)
        : const <String, double>{};
    if (smoothWithMaia &&
        maia.isEmpty &&
        total < _minBookGamesWithoutMaia &&
        MaiaFactory.isAvailable) {
      return false;
    }

    node.setLichessStats(whiteWins, blackWins, draws);
    run.stats.masterOppExpansions++;
    final observed = [
      for (final m in book)
        ObservedMove(
          uci: m.uci,
          san: '',
          games: m.games,
          whiteWins: m.whiteWins,
          blackWins: m.blackWins,
          draws: m.draws,
        ),
    ];
    final smoothed = smoothOpponentMoves(
      observed: observed,
      totalGames: total,
      maiaPolicy: maia,
      priorGames: config.maiaPriorGames,
    );
    final yearByUci = {for (final m in book) m.uci: m.lastYear};
    // The root fans out uncapped. It is a single position, so breadth costs
    // one extra subtree rather than one per node of the tree, and it is
    // where the course decides which systems it covers at all — a cap there
    // does not save a budget, it silently drops a chapter. Everywhere else
    // an extra reply multiplies, so the caps stand.
    final atRoot = node.ply == 0;
    addOpponentChildren(
      run: run,
      node: node,
      candidates: smoothed,
      smoothing: true,
      minMoveProb: config.maiaMinProb,
      wellPlayedGames: config.masterMinMoveGames,
      maxChildren: atRoot
          ? 0
          : config.effectiveOppMaxChildren(effectiveSearchPriority(node)),
      massTarget: atRoot ? 0.0 : config.oppMassTarget,
      attachStats: true,
      onChild: (child) {
        final y = yearByUci[child.moveUci];
        if (y != null && y > 0) child.lastPlayedYear = y;
        final p = maia[child.moveUci];
        if (p != null) child.maiaFrequency = p;
      },
    );
    if (smoothWithMaia) {
      await _maybeInjectPvContinuation(node, maiaPolicy: maia);
    }
    return true;
  }

  Future<void> _addOpponentChildrenFromMaia(
    BuildTreeNode node, {
    bool maiaForInject = false,
    bool offBook = false,
  }) async {
    if (!MaiaFactory.isAvailable || MaiaFactory.instance == null) return;

    final sw = Stopwatch()..start();
    final MaiaResult maiaResult;
    try {
      maiaResult = await MaiaFactory.instance!.evaluate(
        node.fen,
        config.maiaElo,
      );
    } catch (e) {
      run.log('Maia eval failed @ ${node.fen}: $e');
      return;
    }
    run.stats.maiaEvals++;
    run.stats.maiaTotalMs += sw.elapsedMilliseconds;
    if (maiaResult.policy.isEmpty) {
      if (maiaForInject) {
        await _maybeInjectPvContinuation(node);
      }
      return;
    }

    final policy = applyPolicyTemperature(
      maiaResult.policy,
      config.oppPolicyTemperature,
    );
    final sortedMoves = policy.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    addOpponentChildren(
      run: run,
      node: node,
      candidates: [
        for (final e in sortedMoves)
          SmoothedMove(uci: e.key, san: '', probability: e.value, games: 0),
      ],
      smoothing: false,
      minMoveProb: config.maiaMinProb,
      maxChildren: _offBookCap(
        config.effectiveOppMaxChildren(effectiveSearchPriority(node)),
        offBook: offBook,
      ),
      massTarget: config.oppMassTarget,
    );

    if (maiaForInject) {
      await _maybeInjectPvContinuation(node, maiaPolicy: policy);
    }
  }

  /// [TreeBuildConfig.offBookOppMaxChildren] applied on top of the regular
  /// cap at off-book positions; the smaller wins, 0 means no narrowing.
  int _offBookCap(int cap, {required bool offBook}) {
    final off = config.offBookOppMaxChildren;
    if (!offBook || off <= 0) return cap;
    if (cap <= 0) return off;
    return cap < off ? cap : off;
  }

  /// Ensure the engine's preferred opponent reply (stashed on the node by
  /// the our-move MultiPV pass) exists as a child, with Maia's probability
  /// for it when available, else [kPvInjectEpsilon].
  Future<void> _maybeInjectPvContinuation(
    BuildTreeNode node, {
    Map<String, double>? maiaPolicy,
  }) async {
    final pvUci = node.pvContinuationMove;
    if (pvUci == null || pvUci.isEmpty) return;

    if (node.children.any((c) => c.moveUci == pvUci)) return;

    final played = run.childMove(node, pvUci);
    if (played == null) return;

    final child = run.makeChild(
      parent: node,
      fen: played.fen,
      san: played.san,
      uci: pvUci,
      position: played.after,
    );
    if (child == null) return;

    double prob = maiaPolicy?[pvUci] ?? -1.0;
    if (prob < 0 && MaiaFactory.isAvailable && MaiaFactory.instance != null) {
      try {
        final maiaResult = await MaiaFactory.instance!.evaluate(
          node.fen,
          config.maiaElo,
        );
        run.stats.maiaEvals++;
        prob = maiaResult.policy[pvUci] ?? -1.0;
      } catch (_) {
        // Best-effort Maia lookup for injected move probability.
      }
    }
    if (prob < 0) prob = kPvInjectEpsilon;

    child.moveProbability = prob;
    child.cumulativeProbability = node.cumulativeProbability * prob;
    final masterFactor = run.masterPriorityFactor(child.fen);
    child.searchPriority = effectiveSearchPriority(node) * prob * masterFactor;
    child.searchPriorityDiscount = masterFactor;
    child.engineInjected = true;

    run.emitNodeProgress(child);
  }

  // ── Shared our-move plumbing: candidate injection ───────────────────────

  /// How many of the book's most-played moves are offered as our-move
  /// candidates at a master-practice position.
  static const int kMasterCandidateCount = 2;

  /// Setup moves, parsed once per run rather than per node.
  late final Set<String> _setupSans = parseSetupMoves(config.setupMoves);

  /// Pins by canonical FEN, built once per run ([SkeletonPlan.pinsByFen]
  /// rebuilds the map on every read).
  late final Map<String, String> _pins = config.skeletonPlan.pinsByFen;

  /// Skeleton transfer lookups by FEN.  [SkeletonPlan.transferFor] compares
  /// the position against every skeleton node and is asked twice per
  /// our-move node (injection, then the alternative gate), so the answer is
  /// kept.
  final Map<String, TransferMatch?> _transfers = {};

  TransferMatch? _transferFor(BuildTreeNode node) {
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
  Future<void> injectCandidates(
    BuildTreeNode node, {
    required int? bestCpWhite,
    Set<InjectionSource> sources = const {
      InjectionSource.setup,
      InjectionSource.master,
      InjectionSource.transfer,
      InjectionSource.pin,
    },
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
        final childCpWhite = scored.$1;
        if (injection.gated && bestCpWhite != null) {
          final evalLoss = node.isWhiteToMove
              ? bestCpWhite - childCpWhite
              : childCpWhite - bestCpWhite;
          if (evalLoss > config.maxEvalLossCp) continue;
        }
        _addInjected(node, injection, childCpWhite, depth: scored.$2);
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

    if (sources.contains(InjectionSource.setup) && _setupSans.isNotEmpty) {
      final position = run.positionOf(node);
      for (final san in _setupSans) {
        final Move? move;
        try {
          move = position.parseSan(san);
        } catch (_) {
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
      final match = _transferFor(node);
      if (match != null) offer(match.uci, gated: true);
    }

    if (sources.contains(InjectionSource.pin) && _pins.isNotEmpty) {
      final uci = _pins[normalizeFen(node.fen)];
      if (uci != null) offer(uci, gated: false);
    }

    return byUci.values.toList();
  }

  /// White-POV eval of each injection's child position, by UCI.  Moves the
  /// engine (or the database) could not score are absent.
  /// White-POV score per candidate, *with the depth it was searched to*.
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

  // ── Shared our-move plumbing: priorities and gating ─────────────────────

  /// Best-first priorities at an our-move node: the incumbent (best eval for
  /// us at expansion time) inherits the parent's priority; alternatives are
  /// discounted so they stay shallow unless the mainline budget runs out.
  /// Returns the incumbent (null when the node has no children).
  BuildTreeNode? assignOurMovePriorities(BuildTreeNode node) {
    if (node.children.isEmpty) return null;
    final basePri = effectiveSearchPriority(node);

    BuildTreeNode? incumbent;
    var bestCp = 0;
    for (final child in node.children) {
      // evalForUs returns 0 for an eval-less child; skip those so a missing
      // eval can never masquerade as a 0cp incumbent over real (negative-eval)
      // siblings.  Every our-move child currently carries an eval, so this is
      // a guard for future expanders, not a behavior change today.
      if (!child.hasEngineEval) continue;
      final cp = child.evalForUs(config.playAsWhite);
      if (incumbent == null || cp > bestCp) {
        bestCp = cp;
        incumbent = child;
      }
    }
    // Fall back to the first child only when none carry an eval.
    incumbent ??= node.children.first;
    for (final child in node.children) {
      final isIncumbent = identical(child, incumbent);
      final discount = isIncumbent ? 1.0 : config.ourAltDiscount;
      final masterFactor = run.masterPriorityFactor(child.fen);
      child.searchPriority = basePri * discount * masterFactor;
      child.searchPriorityDiscount = discount * masterFactor;
    }
    return incumbent;
  }

  /// Fast alternative gating: which our-move children deserve a subtree.
  ///
  /// The incumbent always expands.  Alternatives expand only while within
  /// [TreeBuildConfig.fastAltGapCp] of the incumbent's eval, best first, at
  /// most [TreeBuildConfig.fastMaxExpandedAlts] of them — a move 30+cp
  /// behind only wins the argmax if deep search flips the ordering by more
  /// than the gap, which the verification pass would catch anyway.  Gated
  /// children stay evaluated leaves: selection still sees them, and a
  /// resume with more budget may deepen them.
  ///
  /// Everything expands under Pure (exhaustive by contract), in the
  /// wide-opening band (the first [TreeBuildConfig.openingWidthPlies]
  /// of our moves grow every in-window alternative), and for preferred-setup
  /// candidates (the setup bias needs them alive).
  List<BuildTreeNode> ourChildrenToExpand(
    BuildTreeNode node,
    BuildTreeNode? incumbent,
  ) {
    final children = List.of(node.children);
    if (config.searchAlgorithm == SearchAlgorithm.pure ||
        config.widensOpeningAtPly(node.ply) ||
        config.fastAltGapCp <= 0 ||
        incumbent == null ||
        !incumbent.hasEngineEval) {
      return children;
    }

    // A skeleton-transfer move is kept alive like a setup move: its subtree
    // must exist in case selection prefers it.
    final transferUci = _transferFor(node)?.uci;
    final incumbentCp = incumbent.evalForUs(config.playAsWhite);
    final alts =
        [
          for (final c in children)
            if (!identical(c, incumbent)) c,
        ]..sort(
          (a, b) => b
              .evalForUs(config.playAsWhite)
              .compareTo(a.evalForUs(config.playAsWhite)),
        );

    final expand = <BuildTreeNode>[incumbent];
    var altsTaken = 0;
    for (final alt in alts) {
      if (_setupSans.contains(alt.moveSan) ||
          (transferUci != null && alt.moveUci == transferUci)) {
        expand.add(alt);
        continue;
      }
      if (!alt.hasEngineEval) continue;
      final gapCp = incumbentCp - alt.evalForUs(config.playAsWhite);
      if (config.expandAlternative(
        gapCp: gapCp,
        altsAlreadyExpanded: altsTaken,
      )) {
        expand.add(alt);
        altsTaken++;
      }
    }
    return expand;
  }
}
