/// Where a planning question gets its evidence.
///
/// For a position, [PlanDataSource.candidates] returns the moves worth
/// showing with whatever each source knows about them:
///
/// - the ECO trie names them and says how much book lies below each;
/// - Maia says how likely each is for a player of the user's strength (this
///   is the share coverage is thresholded on — local and quota-free; the
///   Lichess explorer is not used for probabilities);
/// - ChessDB (or the local eval cache) says how good the resulting position
///   is, so a fashionable-but-dubious move is visibly so.
///
/// The interface exists so the walk controller can be tested with a fake;
/// [DefaultPlanDataSource] is the real thing and degrades gracefully — any
/// source that fails just leaves its column blank.
library;

import 'dart:async';

import '../../../constants/engine_defaults.dart';
import '../../../services/engine/engine_lifecycle.dart';
import '../../../services/engine/stockfish_pool.dart';
import '../../../models/eval_database_settings.dart';
import '../../../services/eval/cdbdirect_eval_provider.dart';
import '../../../services/eval/chessdb_api_provider.dart';
import '../../../services/eval/external_eval_provider.dart';
import '../../../services/maia/maia_factory.dart';
import '../../../utils/chess_utils.dart';
import '../models/plan_models.dart';
import 'eco_trie.dart';
import '../../../utils/fen_utils.dart';

abstract class PlanDataSource {
  /// Candidates at [fen] (reached by [moves] from the start), ranked by
  /// database share, then book weight. [ourMove] says whose turn it is; the
  /// sources are the same, the caller only uses it to phrase things.
  Future<List<PlanCandidate>> candidates({
    required String fen,
    required List<String> moves,
    required bool ourMove,
    required int elo,
  });

  /// The book's name for the position after [moves], if any.
  Future<String?> nameFor(List<String> moves);

  /// Tabiya score after [moves] (see [EcoTrie]); 0 out of book.
  Future<int> tabiyaScore(List<String> moves);

  /// Run the local engine on [fen] (on demand, when a candidate has no
  /// evaluation). White-normalized cp and the depth reached; null when no
  /// engine is available.
  Future<({int cp, int depth})?> engineEval(String fen);

  /// Database evaluation of [fen] (ChessDB, local or cloud) with its depth
  /// and source label; null on a miss. Called per candidate *after* the
  /// question is already on screen, so rows fill in as answers land.
  Future<({int cp, int depth, String source})?> dbEval(String fen);
}

class DefaultPlanDataSource implements PlanDataSource {
  DefaultPlanDataSource({
    Future<EcoTrie>? trie,
    ExternalEvalProvider? evals,
    this.evalCandidates = 6,
    this.evalTimeout = const Duration(seconds: 6),
    this.engineDepth = kDefaultGenerationEvalDepth,
  }) : _trie = trie ?? EcoTrieService.instance.load() {
    _evals = evals;
  }

  /// Depth for on-demand Stockfish evaluations.
  final int engineDepth;

  final Future<EcoTrie> _trie;
  ExternalEvalProvider? _evals;
  Future<void>? _evalsInit;

  /// How many of the top candidates get an evaluation lookup.
  final int evalCandidates;
  final Duration evalTimeout;

  final Map<String, List<PlanCandidate>> _cache = {};

  /// Which source evaluations come from, once resolved: one source for the
  /// whole session, named on every cell — no mixing, no guessing.
  ///
  /// - The local ChessDB (cdbdirect) when Settings point at one: every
  ///   candidate is looked up, it is local and free.
  /// - Otherwise the ChessDB cloud API for the top candidates.
  /// - Stockfish only ever runs on demand (a click on an empty cell), and is
  ///   labelled as such.
  String evalSourceLabel = 'ChessDB';
  bool _localDb = false;

  Future<ExternalEvalProvider?> _evalProvider() async {
    if (_evals != null) return _evals;
    _evalsInit ??= () async {
      final settings = EvalDatabaseSettings.instance;
      if (!settings.isLoaded) {
        try {
          await settings.load();
        } catch (_) {}
      }
      if (settings.enableCdbDirect &&
          settings.cdbDirectPath.isNotEmpty &&
          CdbDirectEvalProvider.isAvailable) {
        try {
          final local = CdbDirectEvalProvider(path: settings.cdbDirectPath);
          if (await local.init()) {
            _evals = local;
            _localDb = true;
            evalSourceLabel = 'ChessDB (local)';
            return;
          }
        } catch (_) {}
      }
      try {
        final api = ChessDbApiProvider(dailyQuota: 800, concurrency: 3);
        await api.init();
        _evals = api;
        evalSourceLabel = 'ChessDB';
      } catch (_) {
        _evals = null;
      }
    }();
    await _evalsInit;
    return _evals;
  }

  @override
  Future<String?> nameFor(List<String> moves) async =>
      (await _trie).nameFor(moves)?.name;

  @override
  Future<int> tabiyaScore(List<String> moves) async =>
      (await _trie).tabiyaScoreAt(moves);

  @override
  Future<List<PlanCandidate>> candidates({
    required String fen,
    required List<String> moves,
    required bool ourMove,
    required int elo,
  }) async {
    final key = '$fen|$elo';
    final cached = _cache[key];
    if (cached != null) return cached;

    final trie = await _trie;
    final node = trie.nodeAt(moves);
    final bySan = <String, PlanCandidate>{};

    // Book children first: names and weight.
    if (node != null) {
      for (final child in node.childrenByWeight) {
        final entry = child.nearestName;
        bySan[child.san] = PlanCandidate(
          san: child.san,
          name: entry?.name,
          eco: entry?.eco,
          bookBelow: child.entriesBelow,
        );
      }
    }

    // Maia is the probability source: local, quota-free, and tuned to the
    // user's strength. (The Lichess explorer is deliberately not consulted
    // here — one call per position would be slow and burn its rate limit.)
    if (MaiaFactory.isAvailable && MaiaFactory.instance != null) {
      try {
        final result = await MaiaFactory.instance!
            .evaluate(fen, elo)
            .timeout(const Duration(seconds: 6));
        for (final e in result.policy.entries) {
          final san = uciToSanOrNull(fen, e.key);
          if (san == null) continue;
          final existing = bySan[san];
          if (existing == null && e.value < 0.02) continue;
          bySan[san] = (existing ?? PlanCandidate(san: san)).copyWith(
            maiaProb: e.value,
          );
        }
      } catch (_) {}
    }

    // Names for database-only moves that are still in book.
    if (node != null) {
      for (final san in bySan.keys.toList()) {
        final c = bySan[san]!;
        if (c.name != null) continue;
        final child = node.children[san];
        if (child?.nearestName != null) {
          bySan[san] = c.copyWith(
            name: child!.nearestName!.name,
            eco: child.nearestName!.eco,
            bookBelow: child.entriesBelow,
          );
        }
      }
    }

    var list = bySan.values.toList()..sort(_rank);
    // Drop the long tail of one-game moves.
    list = list.where((c) {
      final s = c.share;
      return s == null || s >= 0.01 || c.bookBelow > 0 || c.inChapters;
    }).toList();

    _cache[key] = list;
    return list;
  }

  @override
  Future<({int cp, int depth, String source})?> dbEval(String fen) async {
    final provider = await _evalProvider();
    if (provider == null) return null;
    try {
      final r = await provider.lookup(fen, minDepth: 1).timeout(evalTimeout);
      final hit = r.hit;
      if (hit == null) return null;
      return (cp: hit.cp, depth: hit.depth, source: evalSourceLabel);
    } catch (_) {
      return null;
    }
  }

  /// Whether the database is local — then every candidate is looked up,
  /// not just the top few.
  bool get hasLocalDb => _localDb;

  @override
  Future<({int cp, int depth})?> engineEval(String fen) async {
    // A running build owns the engine; don't fight it.
    if (EngineLifecycle.instance.state == EngineState.generating) return null;
    try {
      final pool = StockfishPool.instance;
      await pool.ensureWorkers(1);
      final result = await pool.evaluateFen(fen, engineDepth);
      final whiteToMove = isWhiteToMove(fen);
      final cp = whiteToMove ? result.effectiveCp : -result.effectiveCp;
      return (cp: cp, depth: result.depth);
    } catch (_) {
      return null;
    }
  }

  static int _rank(PlanCandidate a, PlanCandidate b) {
    final sa = a.share ?? -1;
    final sb = b.share ?? -1;
    if (sa != sb) return sb.compareTo(sa);
    return b.bookBelow.compareTo(a.bookBelow);
  }
}
