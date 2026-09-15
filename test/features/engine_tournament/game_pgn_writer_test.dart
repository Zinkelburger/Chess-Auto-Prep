import 'package:chess_auto_prep/constants/chess_constants.dart';
import 'package:chess_auto_prep/features/engine_tournament/models/time_control.dart';
import 'package:chess_auto_prep/features/engine_tournament/services/game_pgn_writer.dart';
import 'package:chess_auto_prep/features/engine_tournament/services/uci_protocol.dart';
import 'package:chess_auto_prep/models/game_outcome.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('formatMoveComment', () {
    test('centipawns are signed pawns with depth and seconds', () {
      expect(
        formatMoveComment(
          const EngineSearch(
            bestMoveUci: 'e2e4',
            elapsedMs: 2001,
            scoreCp: 31,
            depth: 24,
          ),
        ),
        '+0.31/24 2.001s',
      );
      expect(
        formatMoveComment(
          const EngineSearch(
            bestMoveUci: 'e2e4',
            elapsedMs: 10,
            scoreCp: -150,
            depth: 3,
          ),
        ),
        '-1.50/3 0.010s',
      );
    });

    test('mates are written as M<n> with their sign', () {
      expect(
        formatMoveComment(
          const EngineSearch(
            bestMoveUci: 'e2e4',
            elapsedMs: 0,
            scoreMate: 3,
            depth: 5,
          ),
        ),
        '+M3/5 0.000s',
      );
      expect(
        formatMoveComment(
          const EngineSearch(bestMoveUci: 'e2e4', elapsedMs: 0, scoreMate: -2),
        ),
        '-M2 0.000s',
      );
    });

    test('no score at all reads as book', () {
      expect(
        formatMoveComment(
          const EngineSearch(bestMoveUci: 'e2e4', elapsedMs: 500),
        ),
        'book 0.500s',
      );
    });
  });

  group('buildGamePgn', () {
    final start = Chess.fromSetup(Setup.parseFen(kStandardStartFen));

    String pgn({bool annotate = false, String detail = ''}) => buildGamePgn(
      whiteName: 'Alpha',
      blackName: 'Beta',
      context: GamePgnContext(
        event: 'Match',
        site: 'Here',
        round: 2,
        startFen: kStandardStartFen,
        timeControl: const TimeControl.perMove(1000),
        annotateMoves: annotate,
      ),
      startPosition: start,
      sanMoves: const ['e4', 'e5'],
      comments: const ['+0.30/10 1.000s', '+0.10/10 1.000s'],
      result: GameResult.draw,
      termination: TerminationReason.drawAdjudication,
      detail: detail,
      began: DateTime(2026, 9, 15, 10, 30),
      duration: const Duration(hours: 1, minutes: 2, seconds: 3),
    );

    test('writes the headers engine tools expect, in order', () {
      final text = pgn();
      expect(
        text,
        startsWith(
          '[Event "Match"]\n[Site "Here"]\n[Date "2026.09.15"]\n[Round "2"]\n'
          '[White "Alpha"]\n[Black "Beta"]\n[Result "1/2-1/2"]\n'
          '[TimeControl "*1"]\n',
        ),
      );
      expect(text, contains('[PlyCount "2"]\n'));
      expect(text, contains('[GameDuration "01:02:03"]\n'));
      expect(text, isNot(contains('[FEN ')));
    });

    test('the termination leads the movetext and comments are opt-in', () {
      expect(pgn(), endsWith('\n{Adjudicated draw} 1. e4 e5 1/2-1/2\n'));
      expect(
        pgn(annotate: true, detail: 'level'),
        endsWith(
          '{Adjudicated draw: level} 1. e4 {+0.30/10 1.000s} '
          'e5 {+0.10/10 1.000s} 1/2-1/2\n',
        ),
      );
    });

    test('braces and newlines cannot escape the reason comment', () {
      expect(pgn(detail: 'a {b}\nc'), contains('{Adjudicated draw: a b c}'));
    });
  });
}
