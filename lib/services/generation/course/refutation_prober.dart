/// Showing why the moves that are not in the book are not in the book.
///
/// Two questions a reader asks of a generated line, both answered with a
/// *variation* rather than a sentence, because a variation is clickable and a
/// sentence is not:
///
/// 1. "The line stops on their blunder — so how is it punished?"  The build
///    stops the moment a position is winning enough: there is nothing left to
///    prepare, so the tree keeps the node as a leaf and never expands it.
///    [RefutationProber.probe] asks the engine how the position is won.
/// 2. "Why isn't the natural move here?"  Neither side's rejected moves
///    survive into the tree — ours are filtered to the eval-loss window
///    (an engine-approved alternative is a different move, not a refuted
///    one) and theirs to the candidate floor.  [RefutationProber
///    .probeAlternatives] brings its own move source — Maia's policy, or the
///    game database — and asks the engine what happens after each move a
///    human would consider but the book leaves out.
///
/// One search per distinct position, capped and deduplicated, because a wide
/// build can end thousands of lines this way.
library;

import '../../../models/analysis/discovery_result.dart';
import '../../../models/build_tree_node.dart' show PruneReason;
import '../../../utils/chess_utils.dart';
import '../../../utils/fen_utils.dart';
import '../../engine/stockfish_pool.dart';
import '../../maia/maia_factory.dart';
import '../generation_config.dart';
import '../line_extractor.dart';
import '../pgn_freq_map.dart';

/// Punishing continuations keyed by the position they start from — the FEN
/// at the end of a line, where it is our turn.
typedef RefutationMap = Map<String, List<String>>;

/// A move a human would consider that the book leaves out, with the engine's
/// answer to it.
class RefutedAlternative {
  /// The rejected move, as SAN from the position it is played in.
  final String san;

  /// How it is answered — the opponent's refutation of our natural move, or
  /// our punishment of their try.
  final List<String> continuation;

  /// What the move costs the side that plays it, in centipawns.
  final int lossCp;

  const RefutedAlternative({
    required this.san,
    required this.continuation,
    required this.lossCp,
  });

  /// Loss at or above this reads as a plain mistake rather than an inaccuracy.
  static const int blunderCp = 300;

  String get nag => lossCp >= blunderCp ? '?' : '?!';

  /// What the sideline opens with, mistake mark included.
  String get sanWithNag => '$san$nag';
}

/// Refuted alternatives keyed by [LineChoice.fenBefore] — the position they
/// are played in, which is what lines sharing a prefix share.
typedef AlternativeMap = Map<String, RefutedAlternative>;

class RefutationProber {
  RefutationProber({required this.config, StockfishPool? pool, this.freqMap})
    : pool = pool ?? StockfishPool.instance;

  final TreeBuildConfig config;
  final StockfishPool pool;

  /// Human practice from the build's game database, used as the move source
  /// for [probeAlternatives] when Maia is unavailable.  Null is normal — an
  /// engine-only build has no games.
  final PgnFreqMap? freqMap;

  /// Half-moves of punishment to show.  Long enough that the point is made
  /// (win the piece, then consolidate), short enough that it stays a hint
  /// rather than a line to memorise — the opponent is losing by now and will
  /// not cooperate with the engine's continuation anyway.
  static const int plies = 6;

  /// Ceiling on searches, so a wide build cannot turn this into a second
  /// build.  Lines are probed in export order, which is importance order.
  static const int maxProbes = 150;

  /// Positions [probeAlternatives] will consider, and searches it will spend
  /// on them.  Sites are collected in export order — the first line's opening
  /// moves are both the most important and the most shared, so the cap bites
  /// deep in the tree rather than at the top.
  static const int maxAlternativeSites = 120;
  static const int maxAlternativeProbes = 150;

  /// Candidates tried per position before moving on.  The second exists
  /// because the most likely move is often simply the book move played from a
  /// different position — one fallback, not a sweep.
  static const int maxCandidatesPerSite = 2;

  /// A move played less often than this is not the move a reader wonders
  /// about; refuting it teaches nothing.
  static const double minHumanShare = 0.05;

  /// Centipawns a move must cost the side that plays it before the export
  /// claims it is refuted.  Below this the honest answer is "both are
  /// playable", which the book already says by containing one of them.
  static const int minLossCp = 150;

  /// Positions in [lines] that need punishing, in export order and without
  /// duplicates.
  ///
  /// A line qualifies when it ends because the opponent's move left us
  /// winning — the leaf is eval-pruned and it is our turn there.  A line that
  /// ends on *our* move needs nothing: we are the ones who just played well.
  List<String> targets(List<ExtractedLine> lines) {
    final seen = <String>{};
    final out = <String>[];
    for (final line in lines) {
      if (line.leafPruneReason != PruneReason.evalTooHigh) continue;
      final fen = line.leafFen;
      if (fen == null || fen.isEmpty) continue;
      if (isWhiteToMove(fen) != config.playAsWhite) continue;
      if (!seen.add(fen)) continue;
      out.add(fen);
      if (out.length >= maxProbes) break;
    }
    return out;
  }

  /// Probe every target and return what to play, in SAN from each position.
  ///
  /// Best-effort throughout: an engine that is unavailable, a search that
  /// returns nothing, a PV that will not replay — each drops that one
  /// position and leaves the line exactly as it was.
  Future<RefutationMap> probe(
    List<ExtractedLine> lines, {
    bool Function()? isCancelled,
    void Function(int done, int total)? onProgress,
  }) async {
    final fens = targets(lines);
    if (fens.isEmpty || pool.workerCount == 0) return const {};

    final out = <String, List<String>>{};
    for (var i = 0; i < fens.length; i++) {
      if (isCancelled?.call() ?? false) break;
      final moves = await _lineFrom(fens[i]);
      if (moves.isNotEmpty) out[fens[i]] = moves;
      onProgress?.call(i + 1, fens.length);
    }
    return out;
  }

  Future<List<String>> _lineFrom(String fen) async {
    final result = await _search(fen);
    if (result == null || result.lines.isEmpty) return const [];
    // A PV that stops replaying — truncated, or already mate — yields the
    // prefix that did play, which is still a usable variation.
    return uciPvToSan(fen, result.lines.first.pv, maxMoves: plies);
  }

  // ── Alternatives the book leaves out ───────────────────────────────────

  /// Positions worth asking about, in export order and without duplicates.
  ///
  /// A position with no evaluated child is skipped: "this alternative loses a
  /// pawn" is a comparison, and there is nothing to compare against.
  List<LineChoice> alternativeSites(List<ExtractedLine> lines) {
    final seen = <String>{};
    final out = <LineChoice>[];
    for (final line in lines) {
      for (final choice in line.choices) {
        if (choice.bestEvalCpForUs == null) continue;
        if (!seen.add(choice.fenBefore)) continue;
        out.add(choice);
        if (out.length >= maxAlternativeSites) return out;
      }
    }
    return out;
  }

  /// For each site, the most plausible human move the book leaves out — if
  /// the engine says it is a mistake.
  ///
  /// Best-effort throughout, like [probe]: no move source, no engine, or a
  /// candidate that turns out to be perfectly playable each cost that one
  /// variation and nothing else.  A playable move is *supposed* to drop out —
  /// writing "we don't play this" about a move that is fine would be a lie.
  Future<AlternativeMap> probeAlternatives(
    List<ExtractedLine> lines, {
    bool Function()? isCancelled,
    void Function(int done, int total)? onProgress,
  }) async {
    final sites = alternativeSites(lines);
    if (sites.isEmpty || pool.workerCount == 0) return const {};

    final out = <String, RefutedAlternative>{};
    var probesLeft = maxAlternativeProbes;
    for (var i = 0; i < sites.length; i++) {
      if ((isCancelled?.call() ?? false) || probesLeft <= 0) break;
      final site = sites[i];
      for (final uci in await _humanCandidates(site)) {
        if (probesLeft <= 0) break;
        probesLeft--;
        final found = await _refute(site, uci);
        if (found != null) {
          out[site.fenBefore] = found;
          break;
        }
      }
      onProgress?.call(i + 1, sites.length);
    }
    return out;
  }

  /// Moves a human would consider at [site] that the tree does not hold,
  /// most likely first.
  ///
  /// Maia is asked first because it answers for *any* position; the game
  /// database only knows positions that occur in it, but where it does the
  /// count is real evidence rather than a prediction.
  Future<List<String>> _humanCandidates(LineChoice site) async {
    final known = site.knownUcis.toSet();
    final ranked = await _maiaPolicy(site.fenBefore) ?? _databaseShares(site);
    final out = <String>[];
    for (final entry in ranked) {
      if (entry.value < minHumanShare) break;
      if (known.contains(entry.key)) continue;
      out.add(entry.key);
      if (out.length >= maxCandidatesPerSite) break;
    }
    return out;
  }

  /// Maia's policy at [fen], most likely first, or null when Maia is not
  /// available or has nothing to say.
  Future<List<MapEntry<String, double>>?> _maiaPolicy(String fen) async {
    if (!MaiaFactory.isAvailable || MaiaFactory.instance == null) return null;
    try {
      final result = await MaiaFactory.instance!.evaluate(fen, config.maiaElo);
      if (result.policy.isEmpty) return null;
      return result.policy.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
    } catch (_) {
      return null;
    }
  }

  /// Database frequencies at [site], as shares of the games played there.
  List<MapEntry<String, double>> _databaseShares(LineChoice site) {
    final position = freqMap?.get(site.fenBefore);
    if (position == null) return const [];
    final total = position.playedTotal;
    if (total <= 0) return const [];
    return [
      for (final move in position.moves) MapEntry(move.uci, move.count / total),
    ]..sort((a, b) => b.value.compareTo(a.value));
  }

  /// Play [uci] at [site] and ask the engine what it runs into.  Null when the
  /// move is legal-but-fine, unplayable, or the search came back empty.
  Future<RefutedAlternative?> _refute(LineChoice site, String uci) async {
    final afterFen = playUciMove(site.fenBefore, uci);
    if (afterFen == null) return null;

    final result = await _search(afterFen);
    if (result == null || result.lines.isEmpty) return null;
    final cpWhite = result.lines.first.effectiveCp;
    final evalForUs = config.playAsWhite ? cpWhite : -cpWhite;

    // A move is only worth showing when it costs the side that played it: we
    // lose ground by playing ours, they hand us ground by playing theirs.
    final best = site.bestEvalCpForUs!;
    final lossCp = site.isOurMove ? best - evalForUs : evalForUs - best;
    if (lossCp < minLossCp) return null;

    final san = uciToSanOrNull(site.fenBefore, uci);
    if (san == null) return null;
    final continuation = uciPvToSan(
      afterFen,
      result.lines.first.pv,
      maxMoves: plies,
    );
    // Nothing to show is not a refutation — the whole point is the answer.
    if (continuation.isEmpty) return null;

    return RefutedAlternative(
      san: san,
      continuation: continuation,
      lossCp: lossCp,
    );
  }

  /// One search, or null if the engine could not deliver it.
  Future<DiscoveryResult?> _search(String fen) async {
    try {
      return await pool.discoverMoves(
        fen: fen,
        depth: config.resolvedVerifyDepth,
        multiPv: 1,
        isWhiteToMove: isWhiteToMove(fen),
      );
    } catch (_) {
      // The pool is stopped, or the position was rejected: no variation.
      return null;
    }
  }
}
