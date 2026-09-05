import 'package:chess_auto_prep/services/training/training_phase.dart';
import 'package:chess_auto_prep/services/training/training_session_controller.dart';
import 'package:chess_auto_prep/theme/app_colors.dart';
import 'package:chess_auto_prep/widgets/training/training_board_controls.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(Widget child) => MaterialApp(
  theme: ThemeData.dark(),
  home: Scaffold(body: SizedBox(width: 400, height: 600, child: child)),
);

const _opponent = MoveDisplayInfo(
  moveIndex: 1,
  san: 'e5',
  fullMoveNumber: 1,
  isWhiteMove: false,
  isOpponentMove: true,
  comment: 'The classical reply.',
);

const _user = MoveDisplayInfo(
  moveIndex: 2,
  san: 'Nf3',
  fullMoveNumber: 2,
  isWhiteMove: true,
  isOpponentMove: false,
  comment: 'Develop and hit e5.',
);

/// The learn walkthrough's panel in one of its states. Everything the drill
/// needs is stubbed out; the learn flags are what each test varies.
Widget _learnPanel({
  String? feedback,
  bool quizzing = false,
  bool waitingForAck = false,
  bool opponentWaitingForAck = false,
  MoveDisplayInfo? opponent = _opponent,
  MoveDisplayInfo? user = _user,
  VoidCallback? onLearnAcknowledged,
  VoidCallback? onOpponentAcknowledged,
}) {
  return TrainingPhasePanel(
    phase: TrainingPhase.learning,
    feedback: feedback,
    learnQuizzing: quizzing,
    learnWaitingForAck: waitingForAck,
    opponentWaitingForAck: opponentWaitingForAck,
    currentPairOpponent: opponent,
    currentPairUser: user,
    replayIndex: 0,
    wrongMoveCount: 0,
    currentMoveIndex: 2,
    waitingForUser: quizzing,
    isWhiteLine: true,
    moveDifficulty: (_, _) => 0,
    onLearnAcknowledged: onLearnAcknowledged ?? () {},
    onOpponentAcknowledged: onOpponentAcknowledged ?? () {},
  );
}

void main() {
  group('TrainingPhasePanel while learning', () {
    testWidgets('your move waits for Next with both moves and notes shown', (
      tester,
    ) async {
      var acknowledged = 0;
      await tester.pumpWidget(
        _wrap(
          _learnPanel(
            waitingForAck: true,
            onLearnAcknowledged: () => acknowledged++,
          ),
        ),
      );

      expect(find.text("Black's move 1... e5"), findsOneWidget);
      expect(find.text('The classical reply.'), findsOneWidget);
      expect(find.text('Your move 2. Nf3'), findsOneWidget);
      expect(find.text('Develop and hit e5.'), findsOneWidget);

      await tester.tap(find.text('Next'));
      expect(acknowledged, 1);
    });

    testWidgets('a commented reply waits for Next on its own', (tester) async {
      var acknowledged = 0;
      await tester.pumpWidget(
        _wrap(
          _learnPanel(
            opponentWaitingForAck: true,
            user: null,
            onOpponentAcknowledged: () => acknowledged++,
          ),
        ),
      );

      expect(find.text("Black's move 1... e5"), findsOneWidget);
      expect(find.text('The classical reply.'), findsOneWidget);
      expect(find.textContaining('Your move'), findsNothing);

      await tester.tap(find.text('Next'));
      expect(acknowledged, 1);
    });

    testWidgets('the quiz hides the answer and the note that gives it away', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(_learnPanel(quizzing: true)));

      // The reply stays as context, without its note …
      expect(find.text("Black's move 1... e5"), findsOneWidget);
      expect(find.text('The classical reply.'), findsNothing);
      // … the move being asked for is not on screen …
      expect(find.text('Your move 2. Nf3'), findsNothing);
      expect(find.text('Develop and hit e5.'), findsNothing);
      // … and the prompt row asks for it.
      expect(find.text('Your move'), findsOneWidget);
      expect(find.text('Next'), findsNothing);
    });

    testWidgets('the verdict shows in colour above the card', (tester) async {
      await tester.pumpWidget(_wrap(_learnPanel(feedback: 'Correct!')));
      expect(find.text('Correct!'), findsOneWidget);
      expect(
        tester.widget<Text>(find.text('Correct!')).style?.color,
        AppColors.success,
      );

      await tester.pumpWidget(
        _wrap(_learnPanel(quizzing: true, feedback: 'Try again')),
      );
      await tester.pumpAndSettle();
      final error = ThemeData.dark().colorScheme.error;
      expect(tester.widget<Text>(find.text('Try again')).style?.color, error);
    });

    testWidgets('nothing to show before the first move lands', (tester) async {
      await tester.pumpWidget(_wrap(_learnPanel(opponent: null, user: null)));
      expect(find.byType(FilledButton), findsNothing);
      expect(find.textContaining('move'), findsNothing);
    });
  });
}
