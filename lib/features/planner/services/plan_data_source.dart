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
import '../../settings/models/eval_database_configuration.dart';
import '../../../services/engine/engine_lifecycle.dart';
import '../../../services/engine/stockfish_pool.dart';
import '../../../services/eval/cdbdirect_eval_provider.dart';
import '../../../services/eval/chessdb_api_provider.dart';
import '../../../services/eval/external_eval_provider.dart';
import '../../../services/maia/maia_factory.dart';
import '../../../utils/chess_utils.dart';
import '../../../utils/fen_utils.dart';
import '../models/plan_models.dart';
import 'eco_trie.dart';

/// An engine's verdict on a position: white-normalized centipawns and the
/// depth it was reached at.
typedef PlanEngineEval = ({int cp, int depth});

/// A database's verdict on a position, with the source it came from.
typedef PlanDatabaseEval = ({int cp, int depth, String source});

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
  /// evaluation). Null when no engine is available.
  Future<PlanEngineEval?> engineEval(String fen);

  /// Database evaluation of [fen] (ChessDB, local or cloud); null on a miss.
  /// Called per candidate *after* the question is already on screen, so rows
  /// fill in as answers land.
  Future<PlanDatabaseEval?> dbEval(String fen);
}

class DefaultPlanDataSource implements PlanDataSource {
  DefaultPlanDataSource({
    required this.pool,
    required this.lifecycle,
    required this.databases,
    Future<EcoTrie>? trie,
    ExternalEvalProvider? evals,
    this.evalTimeout = const Duration(seconds: 6),
    this.engineDepth = kDefaultGenerationEvalDepth,
  }) : _trie = trie ?? EcoTrieService.instance.load() {
    _evals = evals;
  }

  /// Depth for on-demand Stockfish evaluations.
  final StockfishPool pool;
  final EngineLifecycle lifecycle;
  final EvalDatabaseConfiguration databases;
  final int engineDepth;

  /// How long one database lookup may take before its cell stays blank.
  final Duration evalTimeout;

  /// How long Maia may take per position before its column stays blank.
  static const Duration _maiaTimeout = Duration(seconds: 6);

  /// A move no book line names needs at least this Maia probability to get
  /// a row at all.
  static const double _minUnnamedMaiaProbability = 0.02;

  /// Below this share a move is the long tail of one-game moves and is
  /// dropped, unless the book or the user's chapters know it.
  static const double _minShareToList = 0.01;

  static const int _chessDbDailyQuota = 800;
  static const int _chessDbConcurrency = 3;

  final Future<EcoTrie> _trie;
  ExternalEvalProvider? _evals;
  Future<void>? _evalsInit;

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

  Future<ExternalEvalProvider?> _evalProvider() async {
    if (_evals != null) return _evals;
    await (_evalsInit ??= _resolveEvalProvider());
    return _evals;
  }

  Future<void> _resolveEvalProvider() async {
    final local = await _openLocalDatabase(databases);
    if (local != null) {
      _evals = local;
      evalSourceLabel = 'ChessDB (local)';
      return;
    }
    try {
      final api = ChessDbApiProvider(
        dailyQuota: _chessDbDailyQuota,
        concurrency: _chessDbConcurrency,
      );
      await api.init();
      _evals = api;
      evalSourceLabel = 'ChessDB';
    } catch (_) {
      // No database at all: every cell waits for an on-demand engine run.
      _evals = null;
    }
  }

  Future<ExternalEvalProvider?> _openLocalDatabase(
    EvalDatabaseConfiguration settings,
  ) async {
    if (!settings.enableCdbDirect ||
        settings.cdbDirectPath.isEmpty ||
        !CdbDirectEvalProvider.isAvailable) {
      return null;
    }
    try {
      final local = CdbDirectEvalProvider(path: settings.cdbDirectPath);
      return await local.init() ? local : null;
    } catch (_) {
      // A missing or corrupt dump is not fatal — the API provider is next.
      return null;
    }
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

    final node = (await _trie).nodeAt(moves);
    final bySan = <String, PlanCandidate>{};

    // Book children first: names and weight.
    if (node != null) {
      for (final child in node.childrenByWeight) {
        bySan[child.san] = _bookCandidate(child);
      }
    }

    // Maia is the probability source: local, quota-free, and tuned to the
    // user's strength. (The Lichess explorer is deliberately not consulted
    // here — one call per position would be slow and burn its rate limit.)
    final policy = await _maiaPolicy(fen, elo);
    for (final entry in policy.entries) {
      final san = uciToSanOrNull(fen, entry.key);
      if (san == null) continue;
      final existing = bySan[san];
      if (existing == null && entry.value < _minUnnamedMaiaProbability) {
        continue;
      }
      bySan[san] = (existing ?? PlanCandidate(san: san)).copyWith(
        maiaProb: entry.value,
      );
    }

    // Names for database-only moves that are still in book.
    if (node != null) {
      for (final entry in bySan.entries.toList()) {
        if (entry.value.name != null) continue;
        final child = node.children[entry.key];
        final name = child?.nearestName;
        if (child != null && name != null) {
          bySan[entry.key] = entry.value.copyWith(
            name: name.name,
            eco: name.eco,
            bookBelow: child.entriesBelow,
          );
        }
      }
    }

    final ranked = bySan.values.toList()..sort(_rank);
    final list = [
      for (final c in ranked)
        if (_worthListing(c)) c,
    ];
    _cache[key] = list;
    return list;
  }

  static PlanCandidate _bookCandidate(EcoNode child) {
    final entry = child.nearestName;
    return PlanCandidate(
      san: child.san,
      name: entry?.name,
      eco: entry?.eco,
      bookBelow: child.entriesBelow,
    );
  }

  /// Maia's move probabilities (UCI → probability) at [fen] for [elo]; empty
  /// when Maia is unavailable or fails — its column is optional.
  Future<Map<String, double>> _maiaPolicy(String fen, int elo) async {
    final maia = MaiaFactory.isAvailable ? MaiaFactory.instance : null;
    if (maia == null) return const {};
    try {
      final result = await maia.evaluate(fen, elo).timeout(_maiaTimeout);
      return result.policy;
    } catch (_) {
      // Maia is an optional overlay on the candidate list; without it the
      // rows simply carry no predicted-reply share.
      return const {};
    }
  }

  static bool _worthListing(PlanCandidate c) {
    final share = c.share;
    return share == null ||
        share >= _minShareToList ||
        c.bookBelow > 0 ||
        c.inChapters;
  }

  @override
  Future<PlanDatabaseEval?> dbEval(String fen) async {
    final provider = await _evalProvider();
    if (provider == null) return null;
    try {
      final r = await provider.lookup(fen, minDepth: 1).timeout(evalTimeout);
      final hit = r.hit;
      if (hit == null) return null;
      return (cp: hit.cp, depth: hit.depth, source: evalSourceLabel);
    } catch (_) {
      // A slow or failing database leaves the cell blank; the engine can
      // still fill it on demand.
      return null;
    }
  }

  @override
  Future<PlanEngineEval?> engineEval(String fen) async {
    // A running build owns the engine; don't fight it.
    if (lifecycle.state == EngineState.generating) return null;
    try {
      await pool.ensureWorkers(1);
      final result = await pool.evaluateFen(fen, engineDepth);
      final cp = isWhiteToMove(fen) ? result.effectiveCp : -result.effectiveCp;
      return (cp: cp, depth: result.depth);
    } catch (_) {
      // No engine (or one that failed to start) means no evaluation.
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
