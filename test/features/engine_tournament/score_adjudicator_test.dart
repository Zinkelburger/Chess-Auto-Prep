import 'package:chess_auto_prep/features/engine_tournament/models/adjudication_rules.dart';
import 'package:chess_auto_prep/features/engine_tournament/services/game_ending.dart';
import 'package:chess_auto_prep/features/engine_tournament/services/score_adjudicator.dart';
import 'package:chess_auto_prep/models/game_outcome.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter_test/flutter_test.dart';

/// Feed [plies] alternating moves, White first, each with [score] from the
/// mover's side, and return the first ending.
GameEnding? _feed(
  ScoreAdjudicator adjudicator, {
  required int plies,
  required int? Function(Side side, int ply) score,
  int startMove = 50,
  bool Function(int ply)? resets,
}) {
  for (var ply = 0; ply < plies; ply++) {
    final side = ply.isEven ? Side.white : Side.black;
    final ending = adjudicator.observe(
      mover: side,
      moverName: side.name,
      scoreCp: score(side, ply),
      resetsDrawCounter: resets?.call(ply) ?? false,
      fullmoves: startMove + ply ~/ 2,
    );
    if (ending != null) return ending;
  }
  return null;
}

void main() {
  const rules = AdjudicationRules(
    drawMoveNumber: 10,
    drawMoveCount: 3,
    drawScoreCp: 10,
    resignMoveCount: 2,
    resignScoreCp: 500,
  );

  group('draw', () {
    test('needs drawMoveCount full moves of level scores from both', () {
      final ending = _feed(
        ScoreAdjudicator(rules),
        plies: 6,
        score: (_, _) => 5,
      );
      expect(ending, isNotNull);
      expect(ending!.result, GameResult.draw);
      expect(ending.termination, TerminationReason.drawAdjudication);
      expect(ending.detail, 'both engines under 10cp for 3 moves');
      expect(
        _feed(ScoreAdjudicator(rules), plies: 5, score: (_, _) => 5),
        isNull,
      );
    });

    test('waits for the move number even with the streak met', () {
      expect(
        _feed(
          ScoreAdjudicator(rules),
          plies: 8,
          startMove: 1,
          score: (_, _) => 0,
        ),
        isNull,
      );
    });

    test('a capture or pawn move restarts the count', () {
      expect(
        _feed(
          ScoreAdjudicator(rules),
          plies: 8,
          score: (_, _) => 0,
          resets: (ply) => ply == 3,
        ),
        isNull,
      );
    });

    test('a missing score breaks the streak', () {
      expect(
        _feed(
          ScoreAdjudicator(rules),
          plies: 8,
          score: (_, ply) => ply == 4 ? null : 0,
        ),
        isNull,
      );
    });

    test('is off when disabled', () {
      expect(
        _feed(
          ScoreAdjudicator(rules.copyWith(drawEnabled: false)),
          plies: 40,
          score: (_, _) => 0,
        ),
        isNull,
      );
    });
  });

  group('resignation', () {
    test('two-sided: the winner must agree', () {
      final oneSided = _feed(
        ScoreAdjudicator(rules),
        plies: 8,
        score: (side, _) => side == Side.white ? -900 : 0,
      );
      expect(oneSided, isNull);

      final agreed = _feed(
        ScoreAdjudicator(rules),
        plies: 8,
        score: (side, _) => side == Side.white ? -900 : 900,
      );
      expect(agreed, isNotNull);
      expect(agreed!.result, GameResult.blackWins);
      expect(agreed.termination, TerminationReason.resignAdjudication);
      expect(agreed.detail, 'white below -500cp for 2 moves');
    });

    test('one-sided needs only the loser\'s word', () {
      final ending = _feed(
        ScoreAdjudicator(rules.copyWith(twoSidedResign: false)),
        plies: 8,
        score: (side, _) => side == Side.black ? -900 : 0,
      );
      expect(ending, isNotNull);
      expect(ending!.result, GameResult.whiteWins);
    });

    test('one hopeful score breaks the losing streak', () {
      expect(
        _feed(
          ScoreAdjudicator(rules.copyWith(twoSidedResign: false)),
          plies: 5,
          score: (side, ply) => side == Side.white && ply != 2 ? -900 : 0,
        ),
        isNull,
      );
    });

    test('a level game is filed as a draw before a resignation is checked', () {
      // Both rules are met on the same ply: the draw is reported.
      final ending = _feed(
        ScoreAdjudicator(
          rules.copyWith(
            drawMoveCount: 1,
            resignScoreCp: 0,
            resignMoveCount: 1,
          ),
        ),
        plies: 2,
        score: (_, _) => 0,
      );
      expect(ending!.termination, TerminationReason.drawAdjudication);
    });
  });
}
