import 'package:chess_auto_prep/features/bughouse/controllers/bughouse_controller.dart';
import 'package:chess_auto_prep/features/bughouse/models/bughouse_state.dart';
import 'package:chess_auto_prep/features/bughouse/widgets/bughouse_board_card.dart';
import 'package:chess_auto_prep/widgets/chess_board_widget.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Dropping a reserve piece by dragging it, which is how a piece gets onto a
/// bughouse board most of the time.
void main() {
  const withPawn =
      'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR[P] w KQkq - 0 1';
  const plain = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR[] w KQkq - 0 1';

  /// The centre of [square] on a board drawn in [rect], unflipped.
  Offset centreOf(Rect rect, Square square) {
    final cell = rect.width / 8;
    final col = square.file.value;
    final row = 7 - square.rank.value;
    return Offset(
      rect.left + (col + 0.5) * cell,
      rect.top + (row + 0.5) * cell,
    );
  }

  testWidgets('a reserve piece dragged onto a square lands there', (
    tester,
  ) async {
    final controller = BughouseController();
    addTearDown(controller.dispose);
    controller.loadDualFen('$withPawn|$plain');
    expect(controller.state.boardA.pockets!.of(Side.white, Role.pawn), 1);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 420,
              child: BughouseBoardCard(
                controller: controller,
                which: BughouseBoard.a,
              ),
            ),
          ),
        ),
      ),
    );

    final board = tester.getRect(find.byType(ChessBoardWidget));
    final pawn = find.byKey(
      const ValueKey('bughouse-pocket-a-white-pawn'),
      skipOffstage: false,
    );
    expect(pawn, findsOneWidget);

    final gesture = await tester.startGesture(tester.getCenter(pawn));
    await tester.pump(const Duration(milliseconds: 30));
    await gesture.moveTo(centreOf(board, Square.e4));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(
      controller.state.boardA.board.pieceAt(Square.e4),
      const Piece(color: Side.white, role: Role.pawn),
    );
    expect(controller.state.boardA.pockets!.of(Side.white, Role.pawn), 0);
    // And the drop counted as a move: it is Black's turn now.
    expect(controller.state.boardA.turn, Side.black);
  });

  testWidgets('a drag that ends off the board changes nothing', (tester) async {
    final controller = BughouseController();
    addTearDown(controller.dispose);
    controller.loadDualFen('$withPawn|$plain');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 420,
              child: BughouseBoardCard(
                controller: controller,
                which: BughouseBoard.a,
              ),
            ),
          ),
        ),
      ),
    );

    final pawn = find.byKey(const ValueKey('bughouse-pocket-a-white-pawn'));
    final gesture = await tester.startGesture(tester.getCenter(pawn));
    await tester.pump(const Duration(milliseconds: 30));
    await gesture.moveTo(const Offset(4, 4));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(controller.state.boardA.pockets!.of(Side.white, Role.pawn), 1);
    expect(controller.state.boardA.turn, Side.white);
    // The piece is no longer held either — a cancelled drag puts it back.
    expect(controller.pendingDrop, isNull);
  });
}
