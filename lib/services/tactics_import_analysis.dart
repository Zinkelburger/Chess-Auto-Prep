part of 'tactics_import_service.dart';

// Lichess winning chances formula (from scalachess)
// Returns [-1, +1] where -1 = losing, 0 = equal, +1 = winning
// https://github.com/lichess-org/scalachess/blob/master/core/src/main/scala/eval.scala
const double _multiplier = -0.00368208;

double _winningChances(int centipawns) {
  final capped = centipawns.clamp(-1000, 1000);
  return 2 / (1 + math.exp(_multiplier * capped)) - 1;
}

/// Human-readable engine eval: pawns with sign ("+0.5", "-2.1") or mate
/// ("#3" delivering, "#-3" getting mated). Scores arrive in side-to-move
/// perspective; pass [negate] when that side is the opponent so the number
/// reads from the user's point of view.
String _formatEval({int? scoreCp, int? scoreMate, bool negate = false}) {
  if (scoreMate != null) {
    final mate = negate ? -scoreMate : scoreMate;
    return '#$mate';
  }
  final cp = negate ? -(scoreCp ?? 0) : (scoreCp ?? 0);
  final pawns = cp / 100.0;
  return '${pawns >= 0 ? '+' : ''}${pawns.toStringAsFixed(1)}';
}

/// Cross-game memo of opening evaluations, keyed by FEN.
///
/// The same player repeats the same first moves across most of their games,
/// so positions up to fullmove [maxFullmove] are searched once per import run
/// and reused. Futures (not results) are stored so two workers reaching the
/// same position concurrently coalesce into one search.
class _OpeningEvalCache {
  _OpeningEvalCache({required this.depth});

  /// Search depth of every cached entry — one cache is only valid for one
  /// depth, which holds because depth is fixed for a whole import run.
  final int depth;

  final Map<String, Future<EvalResult>> _byFen = {};

  static const int maxFullmove = 10;

  static bool _isOpeningFen(String fen) {
    final fields = fen.split(' ');
    if (fields.length < 6) return false;
    final fullmove = int.tryParse(fields[5]);
    return fullmove != null && fullmove <= maxFullmove;
  }

  /// Evaluate [fen] on [worker], serving repeats from the cache.
  Future<EvalResult> evaluate(EvalWorker worker, String fen) async {
    if (!_isOpeningFen(fen)) return worker.evaluateFen(fen, depth);
    final cached = _byFen[fen];
    if (cached != null) return cached;
    final search = worker.evaluateFen(fen, depth);
    _byFen[fen] = search;
    try {
      return await search;
    } catch (_) {
      // Don't let a failed search (engine hiccup, cancellation) poison the
      // position for every later game in the run.
      _byFen.remove(fen);
      rethrow;
    }
  }
}

/// One decision point — a move the user actually played — collected during a
/// cheap synchronous replay of the game, so that the engine work can then be
/// fanned out across the whole worker pool instead of running move by move.
class _UserMoveSite {
  _UserMoveSite({
    required this.plyIndex,
    required this.moveNumber,
    required this.fenBefore,
    required this.san,
    required this.fenAfter,
    required this.endsGame,
  });

  final int plyIndex;
  final int moveNumber;
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
  _SiteResult({
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

/// Persist a side-to-move [EvalResult] into the shared White-normalized
/// [EvalCache] (the same store tree generation and audit read). Mate scores
/// are skipped — the cache is centipawns-only and its consumers assume cp
/// semantics.
Future<void> _putSharedEval(
  String fen,
  EvalResult result, {
  required bool sideToMoveIsWhite,
  required int depth,
}) async {
  final cp = result.scoreCp;
  if (cp == null || result.scoreMate != null) return;
  await EvalCache.instance.putEvalCpWhite(
    fen,
    sideToMoveIsWhite ? cp : -cp,
    depth,
  );
}

/// Position after playing [uci] from [fen], or null when it doesn't apply.
///
/// FEN identity is how the user's played move is compared against the
/// engine's best move: comparing UCI strings directly would misjudge
/// castling, where dartchess emits king→rook (e1h1) and Stockfish
/// king→destination (e1g1). dartchess accepts either encoding in
/// [Position.makeSan] and produces the same resulting position.
String? _fenAfterUci(String fen, String uci) {
  final pos = Chess.fromSetup(Setup.parseFen(fen));
  final (san, newPos) = _makeUciMoveAndGetSan(pos, uci);
  return san == null ? null : newPos.fen;
}

/// Analyze a single game for tactics. Returns them in game order.
///
/// The replay is synchronous; every engine evaluation is distributed across
/// the whole [pool], so even a single game keeps all workers busy — the
/// common incremental import fetches only one or two new games, which used
/// to run on a single worker while the rest idled.
///
/// Per user move the position before it is always searched (best move +
/// solution line). The position after it is searched only when the played
/// move differs from the engine's best — playing the engine's own choice
/// cannot have lost winning chances at this depth, so the confirming search
/// is skipped and `wcAfter := wcBefore`.
Future<List<TacticsPosition>> _analyzeGameParallel({
  required StockfishPool pool,
  required String gameText,
  required String username,
  required int depth,
  required String gameId,
  MaiaEvaluator? maia,
  int maiaElo = 2200,
  _OpeningEvalCache? evalCache,

  /// Polled between engine calls so a cancelled import stops launching new
  /// searches mid-game instead of only between games.
  bool Function()? shouldAbort,

  /// Reports evaluated site counts for progress display.
  void Function(int done, int total)? onSiteProgress,
}) async {
  final game = PgnGame.parsePgn(gameText);

  final white = (game.headers['White'] ?? '').toLowerCase();
  final black = (game.headers['Black'] ?? '').toLowerCase();

  // Exact (case-insensitive) match only. A substring fallback can
  // misattribute the user's side when an opponent's name is a superstring
  // of the username (e.g. user "tal" vs opponent "talinda").
  Side? userColor;
  if (white == username) {
    userColor = Side.white;
  } else if (black == username) {
    userColor = Side.black;
  }
  if (userColor == null) return [];

  final moves = <String>[];
  final clocks = <double?>[];
  var node = game.moves;
  while (node.children.isNotEmpty) {
    final child = node.children.first;
    moves.add(child.data.san);
    clocks.add(clockSecondsFromComments(child.data.comments));
    node = child;
  }

  // Flaw-tag context: base time / increment for tempo tags, final result
  // for the end-of-game lucky rule.
  final (baseTime, increment) = parseTimeControl(game.headers['TimeControl']);
  final gameResult = game.headers['Result'] ?? '*';
  final userLost =
      (gameResult == '1-0' && userColor == Side.black) ||
      (gameResult == '0-1' && userColor == Side.white);

  final setupFlag = game.headers['SetUp'] ?? game.headers['Setup'] ?? '';
  final fenHeader = game.headers['FEN'] ?? '';
  final startsFromStandard = !(setupFlag == '1' && fenHeader.isNotEmpty);
  Position pos;
  if (startsFromStandard) {
    pos = Chess.initial;
  } else {
    pos = Chess.fromSetup(Setup.parseFen(fenHeader));
  }
  // Capture the whole game once so every tactic mined from it can show the
  // full game in the analysis tab without re-fetching. Only for standard
  // starts — a numbered movetext replayed from move 1 would be illegal for a
  // game that began from a custom position (rare; those fall back to
  // solution-only display).
  final sourceMovetext = startsFromStandard
      ? buildNumberedMovetext(moves, startMoveNumber: 1, whiteToMoveFirst: true)
      : '';

  // ── Phase 1: replay the game, collecting the user's decision points ──
  final sites = <_UserMoveSite>[];
  var moveNumber = 1;
  for (var plyIndex = 0; plyIndex < moves.length; plyIndex++) {
    final san = moves[plyIndex];
    final isUserTurn = pos.turn == userColor;
    final fenBefore = pos.fen;
    final move = pos.parseSan(san);
    if (move == null) break;
    pos = pos.play(move);
    if (isUserTurn) {
      sites.add(
        _UserMoveSite(
          plyIndex: plyIndex,
          moveNumber: moveNumber,
          fenBefore: fenBefore,
          san: san,
          fenAfter: pos.fen,
          endsGame: pos.isGameOver,
        ),
      );
    }
    if (pos.turn == Side.white) moveNumber++;
  }

  // ── Phase 2: evaluate all sites across the pool ──
  final results = List<_SiteResult?>.filled(sites.length, null);
  var sitesDone = 0;

  Future<void> evaluateSite(EvalWorker worker, int i) async {
    final site = sites[i];
    Future<EvalResult> evaluate(String fen) =>
        evalCache?.evaluate(worker, fen) ?? worker.evaluateFen(fen, depth);

    void reportDone() {
      sitesDone++;
      onSiteProgress?.call(sitesDone, sites.length);
    }

    if (shouldAbort?.call() ?? false) return;
    final evalA = await evaluate(site.fenBefore);
    unawaited(
      _putSharedEval(
        site.fenBefore,
        evalA,
        sideToMoveIsWhite: userColor == Side.white,
        depth: depth,
      ),
    );

    // evalA is the user's turn → already the user's perspective.
    final wcBefore = _winningChances(evalA.effectiveCp);

    if (site.endsGame) {
      results[i] = _SiteResult(wcBefore: wcBefore);
      reportDone();
      return;
    }

    // Best-move skip: when the played move reaches the exact position the
    // engine's first PV move does, the user played the engine's own choice.
    final bestFenAfter = evalA.pv.isEmpty
        ? null
        : _fenAfterUci(site.fenBefore, evalA.pv.first);
    if (bestFenAfter != null && bestFenAfter == site.fenAfter) {
      results[i] = _SiteResult(wcBefore: wcBefore, wcAfter: wcBefore);
      reportDone();
      return;
    }

    // Shared-cache screen-out: a full-game analysis pass (this game reviewed
    // in the viewer, or the background auto-analysis job) has usually
    // already scored this exact position at ≥ this depth. When that score
    // says the move lost nothing, the confirming search is skipped — only
    // suspected mistakes go to the engine, because a mined card needs the
    // search's PV and exact eval, which the cp-only cache cannot provide.
    final cachedCpWhite = await EvalCache.instance.getEvalCpWhite(
      site.fenAfter,
      minDepth: depth,
    );
    if (cachedCpWhite != null) {
      final cachedCpUser = userColor == Side.white
          ? cachedCpWhite
          : -cachedCpWhite;
      final wcAfterCached = _winningChances(cachedCpUser);
      if (wcBefore - wcAfterCached < 0.1) {
        results[i] = _SiteResult(wcBefore: wcBefore, wcAfter: wcAfterCached);
        reportDone();
        return;
      }
    }

    if (shouldAbort?.call() ?? false) return;
    final evalB = await evaluate(site.fenAfter);
    unawaited(
      _putSharedEval(
        site.fenAfter,
        evalB,
        sideToMoveIsWhite: userColor != Side.white,
        depth: depth,
      ),
    );

    // evalB is the opponent's turn → negate for the user's perspective.
    final cpB = -evalB.effectiveCp;
    final wcAfter = _winningChances(cpB);
    final delta = wcBefore - wcAfter;

    final isBlunder = delta >= 0.3;
    final isMistake = delta >= 0.2 && delta < 0.3;
    final isInaccuracy = delta >= 0.1 && delta < 0.2;

    TacticsPosition? mined;
    if ((isBlunder || isMistake || isInaccuracy) && evalA.pv.isNotEmpty) {
      // Cancelled games are discarded and re-analyzed on resume, so bail
      // before buildTrainableLine burns more Maia/Stockfish calls.
      if (shouldAbort?.call() ?? false) return;
      final bestMoveUci = evalA.pv.first;

      final allPvSan = <String>[];
      Position tempPos = Chess.fromSetup(Setup.parseFen(site.fenBefore));
      for (final uci in evalA.pv) {
        final (sanMove, newPos) = _makeUciMoveAndGetSan(tempPos, uci);
        if (sanMove == null) break;
        allPvSan.add(sanMove);
        tempPos = newPos;
      }

      final solutionPv = allPvSan
          .take(TacticsEngine.maxSolutionPvPlies)
          .toList();
      final correctLine = await TacticsEngine.buildTrainableLine(
        allPvSan,
        maia: maia,
        worker: worker,
        maiaElo: maiaElo,
        startFen: site.fenBefore,
      );

      final bestMoveSan = _formatUciToSan(site.fenBefore, bestMoveUci);
      final opponentResponse = evalB.pv.isNotEmpty
          ? _formatUciToSan(site.fenAfter, evalB.pv.first)
          : '';

      final mistakeType = isBlunder
          ? '??'
          : isMistake
          ? '?'
          : '?!';
      // Note shown as the flashcard back, deliberately terse:
      // "h5 +0.5 → -2.1, Qf3 +0.5" — the played move with the eval arc,
      // then the best move keeping the pre-move eval. Evals are from the
      // user's perspective and mate-aware. No prose: the mistake label
      // already shows as ??/?/?!, and wordier phrasings collided with
      // filterDisplayComment's Lichess-classification stripper.
      final evalBest = _formatEval(
        scoreCp: evalA.scoreCp,
        scoreMate: evalA.scoreMate,
      );
      final evalAfterMove = _formatEval(
        scoreCp: evalB.scoreCp,
        scoreMate: evalB.scoreMate,
        negate: true,
      );
      final analysis =
          '${site.san} $evalBest → $evalAfterMove, $bestMoveSan $evalBest';

      mined = TacticsPosition(
        fen: site.fenBefore,
        userMove: site.san,
        correctLine: correctLine,
        solutionPv: solutionPv,
        mistakeType: mistakeType,
        mistakeAnalysis: analysis,
        opponentBestResponse: opponentResponse,
        positionContext:
            'Move ${site.moveNumber}, '
            '${userColor == Side.white ? 'White' : 'Black'} to play',
        gameWhite: game.headers['White'] ?? '',
        gameBlack: game.headers['Black'] ?? '',
        gameResult: gameResult,
        gameDate: game.headers['Date'] ?? '',
        gameId: gameId,
        sourceMovetext: sourceMovetext,
      );
    }

    results[i] = _SiteResult(
      wcBefore: wcBefore,
      wcAfter: wcAfter,
      mined: mined,
      isBlunder: isBlunder,
    );
    reportDone();
  }

  // One site per task. Batching consecutive sites onto one worker (for
  // transposition-table locality) was benchmarked and lost: the serial
  // batch tail at each game's end left the rest of the pool idle and cost
  // more than the warmer hash saved.
  await pool.forEachParallel<int>(
    [for (var i = 0; i < sites.length; i++) i],
    evaluateSite,
    stopWhen: shouldAbort,
  );

  // A cancelled game is discarded whole (and re-analyzed on resume), so the
  // partially-filled results are not worth assembling.
  if (shouldAbort?.call() ?? false) return [];

  // ── Phase 3: assemble in game order + tag pass ──
  // Tags need the full user-move eval series (miss looks back one user
  // move, lucky looks ahead one), so they are assigned after all sites
  // completed. results[i] pairs with sites[i]; both are in game order.
  final positions = <TacticsPosition>[];
  for (var i = 0; i < results.length; i++) {
    final result = results[i];
    final mined = result?.mined;
    if (result == null || mined == null) continue;
    final wcAfter = result.wcAfter;
    if (wcAfter == null) continue; // mined moves always have a post-eval
    final site = sites[i];
    final prev = i > 0 ? results[i - 1] : null;
    final next = i + 1 < results.length ? results[i + 1] : null;
    final tags = buildFlawTags(
      isBlunder: result.isBlunder,
      wcBefore: result.wcBefore,
      wcAfter: wcAfter,
      wcAfterPrevUserMove: prev?.wcAfter,
      wcBeforeNextUserMove: next?.wcBefore,
      userLost: userLost,
      fenBefore: site.fenBefore,
      clockAfterSeconds: site.plyIndex < clocks.length
          ? clocks[site.plyIndex]
          : null,
      moveTimeSeconds: moveTimeSeconds(clocks, site.plyIndex, increment ?? 0),
      baseTimeSeconds: baseTime,
    );
    positions.add(mined.copyWith(flawTags: tags));
  }

  return positions;
}

(String? san, Position newPos) _makeUciMoveAndGetSan(Position pos, String uci) {
  final move = Move.parse(uci);
  if (move == null) return (null, pos);
  try {
    final (newPos, san) = pos.makeSan(move);
    return (san, newPos);
  } catch (_) {
    return (null, pos);
  }
}

String _formatUciToSan(String fen, String uci) {
  final pos = Chess.fromSetup(Setup.parseFen(fen));
  final (san, _) = _makeUciMoveAndGetSan(pos, uci);
  return san ?? uci;
}
