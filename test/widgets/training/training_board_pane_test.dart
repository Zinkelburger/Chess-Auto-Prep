import 'package:chess_auto_prep/core/repertoire_controller.dart';
import 'package:chess_auto_prep/widgets/chess_board_widget.dart';
import 'package:chess_auto_prep/widgets/training/move_input_widget.dart';
import 'package:chess_auto_prep/widgets/training/training_board_controls.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(Widget child) => MaterialApp(
  theme: ThemeData.dark(),
  home: Scaffold(body: SizedBox(width: 600, height: 700, child: child)),
);

void main() {
  group('TrainingBoardPane', () {
    testWidgets('drilling a line shows the board and the move field', (
      tester,
    ) async {
      final session = RepertoireController();
      addTearDown(session.dispose);

      await tester.pumpWidget(
        _wrap(
          TrainingBoardPane(
            session: session,
            boardFlipped: false,
            waitingForUser: true,
            onMove: (_) {},
          ),
        ),
      );

      expect(find.byType(ChessBoardWidget), findsOneWidget);
      expect(find.byType(MoveInputWidget), findsOneWidget);
    });

    testWidgets('idle board keeps the board but drops the move field', (
      tester,
    ) async {
      final session = RepertoireController();
      addTearDown(session.dispose);

      await tester.pumpWidget(
        _wrap(
          TrainingBoardPane(
            session: session,
            boardFlipped: false,
            waitingForUser: false,
            showMoveInput: false,
          ),
        ),
      );

      // The browse screens still look like the rest of the app…
      final board = tester.widget<ChessBoardWidget>(
        find.byType(ChessBoardWidget),
      );
      // …but nothing on it can be played or typed.
      expect(board.enableUserMoves, isFalse);
      expect(find.byType(MoveInputWidget), findsNothing);
    });
  });
}
