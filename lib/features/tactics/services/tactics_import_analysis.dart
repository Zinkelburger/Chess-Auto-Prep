/// The engine pass over one of my games: which of my moves lost enough
/// winning chances to become a puzzle, how messy the game was, and the
/// per-ply score series the pass produced on the way.
library;

import 'dart:async';

import 'package:dartchess/dartchess.dart';

import '../../../constants/engine_defaults.dart';
import '../../../services/engine/stockfish_pool.dart';
import '../../../services/eval_cache.dart';
import '../../../services/games_library/game_filter.dart'
    show dedupKeyForHeaders;
import '../../../services/maia/maia_factory.dart';
import '../../../utils/clock_utils.dart' show moveTimeSeconds;
import '../../../utils/chess_utils.dart' show playUciFrom, uciPvToSan, uciToSan;
import '../../../utils/ease_utils.dart' show winningChanceFromCp;
import '../models/tactics_note.dart';
import '../models/tactics_position.dart';
import 'eval_series_annotator.dart';
import 'flaw_tagger.dart';
import 'opening_eval_cache.dart';
import 'parsed_user_game.dart';
import 'tactics_engine.dart';

/// How much winning chance (user perspective, [-1, 1] scale) one of my moves
/// lost, graded the way the puzzle's mistake mark records it.
enum MistakeSeverity {
  inaccuracy('?!', 0.1),
  mistake('?', 0.2),
  blunder('??', 0.3);

  const MistakeSeverity(this.mark, this.minWcDelta);

  /// The mark stored as [TacticsPosition.mistakeType].
  final String mark;

  /// Smallest winning-chance drop that earns this grade (inclusive).
  final double minWcDelta;

  /// The grade for a winning-chance drop of [wcDelta], or null when the move
  /// lost too little to count.
  static MistakeSeverity? ofDelta(double wcDelta) {
    for (final severity in values.reversed) {
      if (wcDelta >= severity.minWcDelta) return severity;
    }
    return null;
  }
}

/// What one game's engine pass produced: the puzzles worth training, and the
/// same pass's verdict on how messy the game was.
///
/// The counts are not a by-product bolted on — they fall out of the very
/// numbers that decide whether a move becomes a puzzle (the winning-chance
/// swing of each of my moves), which is why the review no longer runs a
/// separate full-game analysis to obtain them.
class GameMineOutcome {
  const GameMineOutcome({
    required this.positions,
    required this.dedupKey,
    required this.inaccuracies,
    required this.mistakes,
    required this.blunders,
    this.annotatedMovetext,
  });

  final List<TacticsPosition> positions;

  /// Games-library identity of this game, so the counts can be filed against
  /// the same game the recent-games list shows.
  final String dedupKey;

  final int inaccuracies;
  final int mistakes;
  final int blunders;

  /// This game's movetext with the pass's own `[%eval]` comments written in,
  /// ready to replace the copy in the games cache — or null when the pass
  /// left too many plies unscored for the result to count as an analyzed
  /// game (see [kMaxUnevaluatedPlies]). Clock comments already on the moves
  /// are preserved.
  final String? annotatedMovetext;
}

/// One decision point — a move the user actually played — collected during a
/// cheap synchronous replay of the game, so that the engine work can then be
/// fanned out across the whole worker pool instead of running move by move.
class _UserMoveSite {
  const _UserMoveSite({
    required this.plyIndex,
    required this.fenBefore,
    required this.san,
    required this.fenAfter,
    required this.endsGame,
  });

  final int plyIndex;
  final String fenBefore;
  final String san;
  final String fenAfter;

  /// The user's move ended the game — nothing to punish, only [wcBefore]
  /// feeds the flaw-tag series.
  final bool endsGame;
}

/// Outcome of evaluating one [_UserMoveSite]. [wcAfter] is null when the
/// game ended on the move; [mined] is set when the move lost enough winning
/// chances to become a tactic.
class _SiteResult {
  const _SiteResult({
    required this.wcBefore,
    this.wcAfter,
    this.mined,
    this.isBlunder = false,
  });

  final double wcBefore;
  final double? wcAfter;
  final TacticsPosition? mined;
  final bool isBlunder;
}

/// Analyzes single games for a tactics import run: puzzles in game order
/// plus my mistake counts, with every engine search distributed across the
/// whole [pool].
///
/// Per user move the position before it is always searched (best move +
/// solution line). The position after it is searched only when the played
/// move differs from the engine's best — playing the engine's own choice
/// cannot have lost winning chances at this depth, so the confirming search
/// is skipped and `wcAfter := wcBefore`.
class TacticsGameAnalyzer {
  TacticsGameAnalyzer({
    required this.pool,
    required this.depth,
    this.maia,
    this.maiaElo = kDefaultMaiaElo,
    this.evalCache,
    this.shouldAbort,
  });

  final StockfishPool pool;
  final int depth;
  final MaiaEvaluator? maia;
  final int maiaElo;
  final OpeningEvalCache? evalCache;

  /// Polled between engine calls so a cancelled import stops launching new
  /// searches mid-game instead of only between games.
  final bool Function()? shouldAbort;

  bool get _aborted => shouldAbort?.call() ?? false;

  /// Analyze one game. Null when there is nothing to say about it — it isn't
  /// one of mine (neither header matches [username]), or the run was
  /// cancelled partway, in which case the game is discarded whole and
  /// re-analyzed on resume.
  ///
  /// Even a single game keeps all workers busy — the common incremental
  /// import fetches only one or two new games, which used to run on a single
  /// worker while the rest idled.
  ///
  /// [onSiteProgress] reports evaluated site counts for progress display.
  Future<GameMineOutcome?> analyze({
    required String gameText,
    required String username,
    required String gameId,
    void Function(int done, int total)? onSiteProgress,
  }) async {
    final parsed = ParsedUserGame.parse(gameText, username);
    if (parsed == null) return null;
    final pass = _GamePass(
      analyzer: this,
      game: parsed,
      gameId: gameId,
      onSiteProgress: onSiteProgress,
    );

    // One site per task. Batching consecutive sites onto one worker (for
    // transposition-table locality) was benchmarked and lost: the serial
    // batch tail at each game's end left the rest of the pool idle and cost
    // more than the warmer hash saved.
    await pool.forEachParallel<int>(
      [for (var i = 0; i < pass.workCount; i++) i],
      pass.evaluateWork,
      stopWhen: shouldAbort,
    );

    // A cancelled game is discarded whole (and re-analyzed on resume), so the
    // partially-filled results are not worth assembling.
    if (_aborted) return null;
    return pass.assemble();
  }
}

/// The mutable state of one game's pass: the sites to evaluate, and the
/// per-site and per-ply results the concurrent fan-out fills in.
class _GamePass {
  _GamePass({
    required this.analyzer,
    required this.game,
    required this.gameId,
    required this.onSiteProgress,
  }) {
    _collectSites();
    results = List<_SiteResult?>.filled(sites.length, null);
    plyEvals = List<PlyEval?>.filled(game.moves.length, null);
    plyPvs = List<List<String>?>.filled(game.moves.length, null);
  }

  final TacticsGameAnalyzer analyzer;
  final ParsedUserGame game;
  final String gameId;
  final void Function(int done, int total)? onSiteProgress;

  /// The user's decision points, in game order.
  final sites = <_UserMoveSite>[];

  /// Only the final ply can be checkmate, and only when the replay actually
  /// reached it — an unparseable move partway leaves the replay mid-game,
  /// where `isCheckmate` would be about the wrong position.
  bool lastPlyIsCheckmate = false;

  /// `results[i]` pairs with `sites[i]`.
  late final List<_SiteResult?> results;

  /// Scores by 0-based ply, filled in as sites complete. Site `p` writes ply
  /// `p - 1` (its before-position is what the opponent's last move reached)
  /// and ply `p` (its after-position), so no two sites write the same index
  /// and the concurrent fan-out needs no coordination.
  late final List<PlyEval?> plyEvals;

  /// The line the engine would play from the position *before* each ply, in
  /// SAN — the other half of what a search returns. Site `p` searched both
  /// of the positions that produce these, so it writes ply `p` (from its
  /// before-position) and ply `p + 1` (from its after-position): the same
  /// disjoint pattern as [plyEvals], one index later.
  late final List<List<String>?> plyPvs;

  // The opponent's final move has no following user site to score it.
  Position? _opponentFinalPosition;

  int get workCount => sites.length + (_opponentFinalPosition == null ? 0 : 1);

  int _sitesDone = 0;

  int get _depth => analyzer.depth;

  /// Replay the game synchronously, collecting the user's decision points.
  void _collectSites() {
    var pos = game.startPosition;
    var replayComplete = true;
    for (var plyIndex = 0; plyIndex < game.moves.length; plyIndex++) {
      final san = game.moves[plyIndex];
      final isUserTurn = pos.turn == game.userColor;
      final fenBefore = pos.fen;
      final move = pos.parseSan(san);
      if (move == null) {
        replayComplete = false;
        break;
      }
      pos = pos.play(move);
      if (isUserTurn) {
        sites.add(
          _UserMoveSite(
            plyIndex: plyIndex,
            fenBefore: fenBefore,
            san: san,
            fenAfter: pos.fen,
            endsGame: pos.isGameOver,
          ),
        );
      }
    }
    lastPlyIsCheckmate = replayComplete && pos.isCheckmate;
    if (replayComplete && game.moves.isNotEmpty && pos.turn == game.userColor) {
      _opponentFinalPosition = pos;
    }
  }

  Future<EvalResult> _evaluate(EvalWorker worker, String fen) =>
      analyzer.evalCache?.evaluate(worker, fen) ??
      worker.evaluateFen(fen, _depth);

  void _finishSite(int i, _SiteResult result) {
    results[i] = result;
    _sitesDone++;
    onSiteProgress?.call(_sitesDone, workCount);
  }

  /// Record the line the engine would play from the position before
  /// [plyIndex], when that ply exists.
  void _recordPv(int plyIndex, String fen, List<String> uciPv) {
    if (plyIndex < plyPvs.length) plyPvs[plyIndex] = uciPvToSan(fen, uciPv);
  }

  /// Include the final opponent position in the same worker pass, without
  /// treating their move as a user decision to mine for puzzles.
  Future<void> evaluateWork(EvalWorker worker, int i) async {
    if (i < sites.length) return evaluateSite(worker, i);
    if (analyzer._aborted) return;
    final pos = _opponentFinalPosition!;
    if (pos.isGameOver) {
      if (!pos.isCheckmate) {
        plyEvals[game.moves.length - 1] = PlyEval(cp: 0, depth: _depth);
      }
    } else {
      final result = await _evaluate(worker, pos.fen);
      if (analyzer._aborted) return;
      plyEvals[game.moves.length - 1] = _whiteNormalizedEval(
        result,
        sideToMoveIsWhite: pos.turn == Side.white,
      );
      unawaited(
        _putSharedEval(
          pos.fen,
          result,
          sideToMoveIsWhite: pos.turn == Side.white,
        ),
      );
    }
    _sitesDone++;
    onSiteProgress?.call(_sitesDone, workCount);
  }

  /// Evaluate site [i] on [worker]. Leaves `results[i]` null when the run is
  /// aborted partway.
  Future<void> evaluateSite(EvalWorker worker, int i) async {
    final site = sites[i];
    if (analyzer._aborted) return;

    final evalBefore = await _evaluate(worker, site.fenBefore);
    unawaited(
      _putSharedEval(
        site.fenBefore,
        evalBefore,
        sideToMoveIsWhite: game.userIsWhite,
      ),
    );
    if (site.plyIndex > 0) {
      plyEvals[site.plyIndex - 1] = _whiteNormalizedEval(
        evalBefore,
        sideToMoveIsWhite: game.userIsWhite,
      );
    }
    _recordPv(site.plyIndex, site.fenBefore, evalBefore.pv);

    // evalBefore is the user's turn → already the user's perspective.
    final wcBefore = winningChanceFromCp(evalBefore.effectiveCp);

    if (site.endsGame) {
      // Mate is restored from the board; terminal draws have an exact score.
      final after = Chess.fromSetup(Setup.parseFen(site.fenAfter));
      if (!after.isCheckmate) {
        plyEvals[site.plyIndex] = PlyEval(cp: 0, depth: _depth);
      }
      _finishSite(i, _SiteResult(wcBefore: wcBefore));
      return;
    }

    if (_playedEngineChoice(site, evalBefore)) {
      _recordBestMoveSkip(site, evalBefore);
      _finishSite(i, _SiteResult(wcBefore: wcBefore, wcAfter: wcBefore));
      return;
    }

    final wcAfterCached = await _cachedWcAfter(site, wcBefore);
    if (wcAfterCached != null) {
      _finishSite(i, _SiteResult(wcBefore: wcBefore, wcAfter: wcAfterCached));
      return;
    }

    if (analyzer._aborted) return;
    final evalAfter = await _evaluate(worker, site.fenAfter);
    unawaited(
      _putSharedEval(
        site.fenAfter,
        evalAfter,
        sideToMoveIsWhite: !game.userIsWhite,
      ),
    );
    plyEvals[site.plyIndex] = _whiteNormalizedEval(
      evalAfter,
      sideToMoveIsWhite: !game.userIsWhite,
    );
    _recordPv(site.plyIndex + 1, site.fenAfter, evalAfter.pv);

    // evalAfter is the opponent's turn → negate for the user's perspective.
    final wcAfter = winningChanceFromCp(-evalAfter.effectiveCp);
    final severity = MistakeSeverity.ofDelta(wcBefore - wcAfter);

    TacticsPosition? mined;
    if (severity != null && evalBefore.pv.isNotEmpty) {
      // Cancelled games are discarded and re-analyzed on resume, so bail
      // before buildTrainableLine burns more Maia/Stockfish calls.
      if (analyzer._aborted) return;
      mined = await _minePosition(
        worker,
        site,
        severity: severity,
        evalBefore: evalBefore,
        evalAfter: evalAfter,
      );
    }
    _finishSite(
      i,
      _SiteResult(
        wcBefore: wcBefore,
        wcAfter: wcAfter,
        mined: mined,
        isBlunder: severity == MistakeSeverity.blunder,
      ),
    );
  }

  /// Best-move skip: the played move reaches the exact position the
  /// engine's first PV move does, so the user played the engine's own
  /// choice.
  ///
  /// FEN identity is how the user's played move is compared against the
  /// engine's best move: comparing UCI strings directly would misjudge
  /// castling, where dartchess emits king→rook (e1h1) and Stockfish
  /// king→destination (e1g1). dartchess accepts either encoding in
  /// [Position.makeSan] and produces the same resulting position.
  bool _playedEngineChoice(_UserMoveSite site, EvalResult evalBefore) {
    if (evalBefore.pv.isEmpty) return false;
    final pos = Chess.fromSetup(Setup.parseFen(site.fenBefore));
    return playUciFrom(pos, evalBefore.pv.first)?.after.fen == site.fenAfter;
  }

  /// Write the after-position's score and line without a second search.
  ///
  /// The score of a position is the score of the line the engine would play
  /// from it, so [evalBefore] already *is* the after-position's score. A
  /// mate-in-N for me before the move is a mate-in-(N-1) after it (one of my
  /// N moves is now on the board); a mate against me keeps its distance (the
  /// opponent still needs every one of theirs). Written as a mate, not as
  /// the collapsed centipawn value: that packs to 10000-N, which the viewer
  /// unpacks as mate-in-N again — the off-by-one this arithmetic exists to
  /// avoid.
  void _recordBestMoveSkip(_UserMoveSite site, EvalResult evalBefore) {
    final mateBefore = evalBefore.scoreMate;
    final mateAfter = mateBefore == null
        ? null
        : mateBefore > 1
        ? mateBefore - 1
        : mateBefore;
    plyEvals[site.plyIndex] = _whiteNormalizedEval(
      EvalResult(
        scoreCp: evalBefore.scoreCp,
        scoreMate: mateAfter,
        depth: evalBefore.depth,
      ),
      sideToMoveIsWhite: game.userIsWhite,
    );
    // Its first move is the one that was played, so the rest of the same
    // line is what the engine plays on from here — no second search to get
    // the next ply's best line either.
    _recordPv(site.plyIndex + 1, site.fenAfter, evalBefore.pv.skip(1).toList());
  }

  /// Shared-cache screen-out: a full-game analysis pass (this game reviewed
  /// in the viewer, or the background auto-analysis job) has usually already
  /// scored this exact position at ≥ this depth. When that score says the
  /// move lost nothing, the confirming search is skipped and its winning
  /// chance returned — only suspected mistakes go to the engine, because a
  /// mined card needs the search's PV and exact eval, which the cp-only
  /// cache cannot provide.
  Future<double?> _cachedWcAfter(_UserMoveSite site, double wcBefore) async {
    final cachedCpWhite = await EvalCache.instance.getEvalCpWhite(
      site.fenAfter,
      minDepth: _depth,
    );
    if (cachedCpWhite == null) return null;
    final cachedCpUser = game.userIsWhite ? cachedCpWhite : -cachedCpWhite;
    final wcAfterCached = winningChanceFromCp(cachedCpUser);
    if (wcBefore - wcAfterCached >= MistakeSeverity.inaccuracy.minWcDelta) {
      return null;
    }
    plyEvals[site.plyIndex] = PlyEval(cp: cachedCpWhite, depth: _depth);
    return wcAfterCached;
  }

  /// Build the puzzle for a move that lost winning chances.
  Future<TacticsPosition> _minePosition(
    EvalWorker worker,
    _UserMoveSite site, {
    required MistakeSeverity severity,
    required EvalResult evalBefore,
    required EvalResult evalAfter,
  }) async {
    // Keep every legal ply Stockfish returned. The trainable line below is
    // deliberately the only one constrained by what makes a good training
    // prompt; revealing the answer should still show the engine's full PV.
    final solutionPv = _pvToSan(site.fenBefore, evalBefore.pv);
    final correctLine = await TacticsEngine.buildTrainableLine(
      solutionPv,
      maia: analyzer.maia,
      worker: worker,
      maiaElo: analyzer.maiaElo,
      startFen: site.fenBefore,
    );

    final bestMoveSan = uciToSan(site.fenBefore, evalBefore.pv.first);
    final opponentResponse = evalAfter.pv.isNotEmpty
        ? uciToSan(site.fenAfter, evalAfter.pv.first)
        : '';

    // The flashcard back (see [TacticsNote]): the played move with its eval
    // arc, then the best move. Evals are from the user's perspective and
    // mate-aware, hence the negate on the post-move score.
    final analysis = TacticsNote.compose(
      playedSan: site.san,
      evalBefore: TacticsNote.formatEval(
        scoreCp: evalBefore.scoreCp,
        scoreMate: evalBefore.scoreMate,
      ),
      evalAfter: TacticsNote.formatEval(
        scoreCp: evalAfter.scoreCp,
        scoreMate: evalAfter.scoreMate,
        negate: true,
      ),
      bestSan: bestMoveSan,
    );

    final headers = game.game.headers;
    return TacticsPosition(
      fen: site.fenBefore,
      userMove: site.san,
      correctLine: correctLine,
      solutionPv: solutionPv,
      mistakeType: severity.mark,
      mistakeAnalysis: analysis,
      opponentBestResponse: opponentResponse,
      gameWhite: headers['White'] ?? '',
      gameBlack: headers['Black'] ?? '',
      gameResult: game.result,
      gameDate: headers['Date'] ?? '',
      gameId: gameId,
      sourceMovetext: game.sourceMovetext,
    );
  }

  /// Assemble the outcome in game order and run the tag pass.
  ///
  /// Tags need the full user-move eval series (miss looks back one user
  /// move, lucky looks ahead one), so they are assigned after all sites
  /// completed.
  GameMineOutcome assemble() {
    final positions = <TacticsPosition>[];
    var inaccuracies = 0, mistakes = 0, blunders = 0;
    for (var i = 0; i < results.length; i++) {
      final result = results[i];
      if (result == null) continue;
      final wcAfter = result.wcAfter;
      // Moves that ended the game have no post-eval and cannot be mistakes.
      if (wcAfter == null) continue;
      // Count every one of my moves that lost winning chances, whether or
      // not it became a puzzle: a move can be a mistake and still be
      // untrainable (no PV to build a solution from), and the counts must
      // not silently drop those.
      switch (MistakeSeverity.ofDelta(result.wcBefore - wcAfter)) {
        case MistakeSeverity.blunder:
          blunders++;
        case MistakeSeverity.mistake:
          mistakes++;
        case MistakeSeverity.inaccuracy:
          inaccuracies++;
        case null:
          break;
      }
      final mined = result.mined;
      if (mined == null) continue;
      final site = sites[i];
      final prev = i > 0 ? results[i - 1] : null;
      final next = i + 1 < results.length ? results[i + 1] : null;
      final tags = buildFlawTags(
        isBlunder: result.isBlunder,
        wcBefore: result.wcBefore,
        wcAfter: wcAfter,
        wcAfterPrevUserMove: prev?.wcAfter,
        wcBeforeNextUserMove: next?.wcBefore,
        userLost: game.userLost,
        fenBefore: site.fenBefore,
        clockAfterSeconds: site.plyIndex < game.clocks.length
            ? game.clocks[site.plyIndex]
            : null,
        moveTimeSeconds: moveTimeSeconds(
          game.clocks,
          site.plyIndex,
          game.incrementSeconds ?? 0.0,
        ),
        baseTimeSeconds: game.baseTimeSeconds,
      );
      positions.add(mined.copyWith(flawTags: tags));
    }

    return GameMineOutcome(
      positions: positions,
      dedupKey: dedupKeyForHeaders(game.game.headers, pgn: game.gameText),
      inaccuracies: inaccuracies,
      mistakes: mistakes,
      blunders: blunders,
      // The scores are written onto the parsed tree's own nodes, and the
      // text that comes back replaces this game in the games cache.
      annotatedMovetext: annotateMovetextWithEvals(
        game: game.game,
        plyEvals: plyEvals,
        plyPvs: plyPvs,
        lastPlyIsCheckmate: lastPlyIsCheckmate,
      ),
    );
  }

  /// Persist a side-to-move [EvalResult] into the shared White-normalized
  /// [EvalCache] (the same store tree generation and audit read). Mate
  /// scores are skipped — the cache is centipawns-only and its consumers
  /// assume cp semantics.
  Future<void> _putSharedEval(
    String fen,
    EvalResult result, {
    required bool sideToMoveIsWhite,
  }) async {
    final cp = result.scoreCp;
    if (cp == null || result.scoreMate != null) return;
    await EvalCache.instance.putEvalCpWhite(
      fen,
      sideToMoveIsWhite ? cp : -cp,
      _depth,
    );
  }
}

int? _negateScore(int? v) => v == null ? null : -v;

/// A side-to-move [EvalResult] as a White-normalized [PlyEval] — the sign
/// convention `[%eval]` comments use, whoever was to move.
PlyEval _whiteNormalizedEval(
  EvalResult result, {
  required bool sideToMoveIsWhite,
}) => PlyEval(
  cp: sideToMoveIsWhite ? result.scoreCp : _negateScore(result.scoreCp),
  mate: sideToMoveIsWhite ? result.scoreMate : _negateScore(result.scoreMate),
  depth: result.depth,
);

/// Every legal ply of [uciPv] from [fen] in SAN, stopping at the first that
/// does not apply. Unlike [uciPvToSan] this keeps the whole line.
List<String> _pvToSan(String fen, List<String> uciPv) {
  final san = <String>[];
  Position pos = Chess.fromSetup(Setup.parseFen(fen));
  for (final uci in uciPv) {
    final played = playUciFrom(pos, uci);
    if (played == null) break;
    san.add(played.san);
    pos = played.after;
  }
  return san;
}
