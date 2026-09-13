import 'package:chess_auto_prep/models/repertoire_line.dart';
import 'package:chess_auto_prep/services/training/training_phase.dart';
import 'package:chess_auto_prep/widgets/pgn/pgn_movetext_view.dart';
import 'package:chess_auto_prep/widgets/training/training_board_controls.dart';
import 'package:dartchess/dartchess.dart' show Chess;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final _line = RepertoireLine(
  id: 'line',
  name: 'Opening',
  moves: ['e4', 'e5', 'Nf3', 'Nc6'],
  color: 'white',
  startPosition: Chess.initial,
  fullPgn: '{A first lesson.} 1. e4 e5 2. Nf3 Nc6 *',
  comments: {'1': 'The classical reply.', '2': 'Develop and hit e5.'},
);

Widget _panel({
  TrainingPhase phase = TrainingPhase.learning,
  bool quizzing = false,
  String? feedback,
  String? annotation,
  VoidCallback? onNext,
}) => MaterialApp(
  home: Scaffold(
    body: SizedBox(
      width: 400,
      height: 600,
      child: TrainingPhasePanel(
        phase: phase,
        feedback: feedback,
        currentAnnotation: annotation,
        learnQuizzing: quizzing,
        learnWaitingForAck: onNext != null,
        opponentWaitingForAck: false,
        replayIndex: 0,
        wrongMoveCount: 1,
        currentLine: _line,
        currentMoveIndex: 2,
        waitingForUser: quizzing,
        isWhiteLine: true,
        moveDifficulty: (_, _) => 0,
        onLearnAcknowledged: onNext ?? () {},
        onOpponentAcknowledged: () {},
      ),
    ),
  ),
);

void main() {
  testWidgets(
    'lesson uses PGN notation, reveals only played moves and compact Next',
    (tester) async {
      var next = 0;
      await tester.pumpWidget(_panel(onNext: () => next++));
      final notation = tester.widget<PgnMovetextView>(
        find.byType(PgnMovetextView),
      );
      expect(notation.moveHistory.map((move) => move.san), ['e4', 'e5', 'Nf3']);
      expect(notation.moveHistory.last.comments, ['Develop and hit e5.']);
      expect(notation.game!.comments, ['A first lesson.']);
      expect(notation.variationsByPly, isEmpty);
      expect(tester.getSize(find.byType(FilledButton)).width, lessThan(160));
      await tester.tap(find.text('Next'));
      expect(next, 1);
    },
  );
  testWidgets('quiz conceals the answer and prose that could reveal it', (
    tester,
  ) async {
    await tester.pumpWidget(_panel(quizzing: true));
    final notation = tester.widget<PgnMovetextView>(
      find.byType(PgnMovetextView),
    );
    expect(notation.moveHistory.map((move) => move.san), ['e4', 'e5']);
    expect(
      notation.moveHistory.every((move) => move.comments?.isEmpty ?? true),
      isTrue,
    );
    expect(notation.game, isNull);
    expect(find.text('Your move'), findsOneWidget);
    expect(find.text('Next'), findsNothing);
  });
  testWidgets('drill stays quiet until a correction needs explanation', (
    tester,
  ) async {
    await tester.pumpWidget(
      _panel(
        phase: TrainingPhase.drilling,
        feedback: 'Correct!',
        annotation: 'Develop and hit e5.',
      ),
    );
    expect(find.text('Correct!'), findsNothing);
    expect(find.text('Develop and hit e5.'), findsNothing);
    expect(find.byType(PgnMovetextView), findsNothing);
    await tester.pumpWidget(
      _panel(
        phase: TrainingPhase.drilling,
        feedback: 'Play Nf3',
        annotation: 'Develop and hit e5.',
      ),
    );
    expect(find.text('Play Nf3'), findsOneWidget);
    expect(find.text('Develop and hit e5.'), findsOneWidget);
  });
}
