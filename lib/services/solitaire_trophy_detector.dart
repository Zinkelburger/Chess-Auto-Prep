/// Awards solitaire trophies: guesses that were *better* than the move
/// actually played in the game.
///
/// Full-game analysis only evaluates the moves that were played, so a rejected
/// guess has no eval attached to it — that is the whole reason detection needs
/// its own pass. For each wrong attempt we play the move on the position the
/// guess was made from and evaluate the result at the same depth the game
/// analysis used, then compare both evals from the guesser's side.
library;

import 'package:dartchess/dartchess.dart' show Position;
import 'package:flutter/foundation.dart';

import '../features/documents/controllers/solitaire_controller.dart'
    show SolitaireGuess;
import '../models/solitaire_trophy.dart';
import '../utils/chess_utils.dart' show tryParseFen;
import '../utils/eval_constants.dart' show effectiveCpFromScores;
import 'engine/stockfish_pool.dart';
import 'package:chess_auto_prep/chess_core/analysis/move_eval.dart'
    show MoveEval;

/// A guess must beat the game move by at least this much to earn a trophy.
/// Below it the "improvement" is engine noise between two reasonable moves.
const int kTrophyMinAdvantageCp = 50;

/// Advantage in centipawns of the user's move over the game's move, both read
/// from the guesser's side of the board.
///
/// [gmCpWhiteNorm] is White-normalized (the convention [MoveEval] stores).
/// [userCpAfterMove] comes straight off an engine eval of the position after
/// the user's move, so it is relative to *that* position's side to move — the
/// opponent — and gets negated.
@visibleForTesting
int trophyAdvantageCp({
  required int gmCpWhiteNorm,
  required int userCpAfterMove,
  required bool userIsWhite,
}) {
  final gmFromUser = userIsWhite ? gmCpWhiteNorm : -gmCpWhiteNorm;
  final userFromUser = -userCpAfterMove;
  return userFromUser - gmFromUser;
}

/// The strongest qualifying wrong attempt at one position.
typedef _BestAttempt = ({String san, int advantageCp, int userCpFromUser});

/// Scan [guesses] against the completed [evals] and return a trophy for every
/// position where a rejected guess beat the game's move.
///
/// At most one trophy per position (the best attempt). Positions already in
/// [existing] are skipped, so re-running analysis on the same game doesn't
/// duplicate the shelf.
Future<List<SolitaireTrophy>> detectSolitaireTrophies({
  required StockfishPool pool,
  required List<SolitaireGuess> guesses,
  required List<MoveEval> evals,
  required bool userIsWhite,
  required int depth,
  required String gameLabel,
  required Map<String, String> headers,
  required String pgn,
  List<SolitaireTrophy> existing = const [],
  int minAdvantageCp = kTrophyMinAdvantageCp,
}) async {
  if (guesses.isEmpty || evals.isEmpty) return const [];

  final evalByPly = {for (final e in evals) e.ply: e};
  final awarded = {for (final t in existing) _attemptKey(t.fen, t.userMove)};
  final trophies = <SolitaireTrophy>[];

  for (final guess in guesses) {
    if (guess.wrongAttempts.isEmpty) continue;

    // SolitaireGuess.ply is a 0-based mainline index; MoveEval.ply is 1-based.
    final gameMove = evalByPly[guess.ply + 1];
    if (gameMove == null) continue;

    // The analysis must be of the game that was actually guessed. A mismatch
    // means the user switched games between playing and analyzing, and the
    // evals describe positions these guesses were never made in.
    if (gameMove.san != guess.correctSan) {
      debugPrint(
        'Trophy detection: analysis/guess mismatch at ply ${guess.ply} '
        '(${gameMove.san} vs ${guess.correctSan}) — skipping game.',
      );
      return const [];
    }

    final before = tryParseFen(gameMove.fenBefore);
    if (before == null) continue;

    final gmCp = effectiveCpFromScores(
      scoreCp: gameMove.scoreCp,
      scoreMate: gameMove.scoreMate,
    );
    final best = await _bestAttempt(
      pool: pool,
      before: before,
      fenBefore: gameMove.fenBefore,
      attempts: guess.wrongAttempts,
      awarded: awarded,
      gmCp: gmCp,
      userIsWhite: userIsWhite,
      depth: depth,
      minAdvantageCp: minAdvantageCp,
    );
    if (best == null) continue;

    trophies.add(
      SolitaireTrophy(
        id: '${DateTime.now().microsecondsSinceEpoch}_${guess.ply}',
        date: DateTime.now(),
        fen: gameMove.fenBefore,
        userMove: best.san,
        gmMove: gameMove.san,
        // Stored from the guesser's side, which is how the cabinet reads
        // them out ("you played X (+1.2), they played Y (+0.3)").
        userEvalCp: best.userCpFromUser,
        gmEvalCp: userIsWhite ? gmCp : -gmCp,
        advantageCp: best.advantageCp,
        gameLabel: gameLabel,
        headers: headers,
        pgn: pgn,
      ),
    );
  }

  return trophies;
}

String _attemptKey(String fen, String san) => '$fen|$san';

/// Evaluate each of [attempts] from [before] and return the one with the
/// largest advantage over the game move, or null when none clears
/// [minAdvantageCp]. Attempts already in [awarded] and unparseable or
/// failing evaluations are skipped.
Future<_BestAttempt?> _bestAttempt({
  required StockfishPool pool,
  required Position before,
  required String fenBefore,
  required List<String> attempts,
  required Set<String> awarded,
  required int gmCp,
  required bool userIsWhite,
  required int depth,
  required int minAdvantageCp,
}) async {
  _BestAttempt? best;
  for (final san in attempts) {
    if (awarded.contains(_attemptKey(fenBefore, san))) continue;
    final move = before.parseSan(san);
    if (move == null) continue;

    try {
      final after = before.play(move);
      final result = await pool.evaluateFen(after.fen, depth);
      final advantage = trophyAdvantageCp(
        gmCpWhiteNorm: gmCp,
        userCpAfterMove: result.effectiveCp,
        userIsWhite: userIsWhite,
      );
      if (advantage >= minAdvantageCp && advantage > (best?.advantageCp ?? 0)) {
        best = (
          san: san,
          advantageCp: advantage,
          userCpFromUser: -result.effectiveCp,
        );
      }
    } catch (e) {
      debugPrint('Trophy detection: eval of $san failed: $e');
    }
  }
  return best;
}
