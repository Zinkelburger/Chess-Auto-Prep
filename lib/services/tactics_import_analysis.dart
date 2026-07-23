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

/// Analyze a single game using a pool worker. Returns discovered tactics.
Future<List<TacticsPosition>> _analyzeGameWithWorker({
  required EvalWorker worker,
  required String gameText,
  required String username,
  required int depth,
  required String gameId,
  MaiaEvaluator? maia,
  int maiaElo = 2200,

  /// Polled between engine calls so a cancelled import stops launching new
  /// searches mid-game instead of only between games.
  bool Function()? shouldAbort,
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

  // Winning chances around every evaluated user move (wcAfter null when the
  // game ended on the move), plus one pending record per mined tactic so
  // tags can be assigned after the walk — `lucky` needs the NEXT user
  // move's pre-move eval, which doesn't exist yet while mining.
  final userWc = <({double wcBefore, double? wcAfter})>[];
  final pendingTags =
      <
        ({
          int posIndex,
          int userMoveIndex,
          bool isBlunder,
          String fenBefore,
          int plyIndex,
        })
      >[];

  final positions = <TacticsPosition>[];
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
  int moveNumber = 1;

  for (var plyIndex = 0; plyIndex < moves.length; plyIndex++) {
    final san = moves[plyIndex];
    if (shouldAbort?.call() ?? false) break;
    final isUserTurn = pos.turn == userColor;

    if (isUserTurn) {
      final evalA = await worker.evaluateFen(pos.fen, depth);

      final fenBefore = pos.fen;
      final move = pos.parseSan(san);
      if (move == null) break;
      pos = pos.play(move);

      // evalA is the user's turn → already the user's perspective.
      final wcBefore = _winningChances(evalA.effectiveCp);

      if (pos.isGameOver) {
        userWc.add((wcBefore: wcBefore, wcAfter: null));
        if (pos.turn == Side.white) moveNumber++;
        continue;
      }

      if (shouldAbort?.call() ?? false) break;
      final evalB = await worker.evaluateFen(pos.fen, depth);
      final fenAfter = pos.fen;

      // evalB is the opponent's turn → negate for the user's perspective.
      final cpB = -evalB.effectiveCp;

      final wcAfter = _winningChances(cpB);
      final delta = wcBefore - wcAfter;
      userWc.add((wcBefore: wcBefore, wcAfter: wcAfter));

      final isBlunder = delta >= 0.3;
      final isMistake = delta >= 0.2 && delta < 0.3;
      final isInaccuracy = delta >= 0.1 && delta < 0.2;

      if ((isBlunder || isMistake || isInaccuracy) && evalA.pv.isNotEmpty) {
        // Cancelled games are discarded and re-analyzed on resume, so bail
        // before buildTrainableLine burns more Maia/Stockfish calls.
        if (shouldAbort?.call() ?? false) break;
        final bestMoveUci = evalA.pv.first;

        final allPvSan = <String>[];
        Position tempPos = Chess.fromSetup(Setup.parseFen(fenBefore));
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
          startFen: fenBefore,
        );

        final bestMoveSan = _formatUciToSan(fenBefore, bestMoveUci);
        final opponentResponse = evalB.pv.isNotEmpty
            ? _formatUciToSan(fenAfter, evalB.pv.first)
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
            '$san $evalBest → $evalAfterMove, $bestMoveSan $evalBest';

        positions.add(
          TacticsPosition(
            fen: fenBefore,
            userMove: san,
            correctLine: correctLine,
            solutionPv: solutionPv,
            mistakeType: mistakeType,
            mistakeAnalysis: analysis,
            opponentBestResponse: opponentResponse,
            positionContext:
                'Move $moveNumber, '
                '${userColor == Side.white ? 'White' : 'Black'} to play',
            gameWhite: game.headers['White'] ?? '',
            gameBlack: game.headers['Black'] ?? '',
            gameResult: gameResult,
            gameDate: game.headers['Date'] ?? '',
            gameId: gameId,
            sourceMovetext: sourceMovetext,
          ),
        );
        pendingTags.add((
          posIndex: positions.length - 1,
          userMoveIndex: userWc.length - 1,
          isBlunder: isBlunder,
          fenBefore: fenBefore,
          plyIndex: plyIndex,
        ));
      }
    } else {
      final move = pos.parseSan(san);
      if (move != null) pos = pos.play(move);
    }

    if (pos.turn == Side.white) moveNumber++;
  }

  // Tag pass: needs the full user-move eval series (miss looks back one
  // user move, lucky looks ahead one), so it runs after the walk.
  for (final entry in pendingTags) {
    final k = entry.userMoveIndex;
    final wcAfter = userWc[k].wcAfter;
    if (wcAfter == null) continue; // mined moves always have a post-eval
    final tags = buildFlawTags(
      isBlunder: entry.isBlunder,
      wcBefore: userWc[k].wcBefore,
      wcAfter: wcAfter,
      wcAfterPrevUserMove: k > 0 ? userWc[k - 1].wcAfter : null,
      wcBeforeNextUserMove: k + 1 < userWc.length
          ? userWc[k + 1].wcBefore
          : null,
      userLost: userLost,
      fenBefore: entry.fenBefore,
      clockAfterSeconds: entry.plyIndex < clocks.length
          ? clocks[entry.plyIndex]
          : null,
      moveTimeSeconds: moveTimeSeconds(clocks, entry.plyIndex, increment ?? 0),
      baseTimeSeconds: baseTime,
    );
    positions[entry.posIndex] = positions[entry.posIndex].copyWith(
      flawTags: tags,
    );
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
