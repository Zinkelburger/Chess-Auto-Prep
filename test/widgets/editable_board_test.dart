import 'package:chess_auto_prep/core/board_editor_controller.dart';
import 'package:chess_auto_prep/widgets/board_editor/board_editor_widget.dart';
import 'package:chess_auto_prep/widgets/board_editor/piece_palette.dart';
import 'package:chess_auto_prep/widgets/board_editor/editable_board.dart';
import 'package:chess_auto_prep/features/bughouse/controllers/bughouse_controller.dart';
import 'package:chess_auto_prep/features/bughouse/models/bughouse_state.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('palette drag, free board drag, and off-board removal', (
    tester,
  ) async {
    final editor = BoardEditorController();
    addTearDown(editor.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              PiecePalette(controller: editor),
              SizedBox(
                width: 320,
                height: 320,
                child: BoardEditorWidget(controller: editor),
              ),
            ],
          ),
        ),
      ),
    );
    final board = find.byType(EditableBoard);
    Offset square(int file, int rank) =>
        tester.getTopLeft(board) + Offset(file * 40 + 20, (7 - rank) * 40 + 20);
    final knight = find.byWidgetPredicate(
      (w) =>
          w is Draggable<Piece> &&
          w.data == const Piece(color: Side.white, role: Role.knight),
    );
    final origin = tester.getCenter(knight);
    await tester.dragFrom(origin, square(4, 3) - origin);
    await tester.pumpAndSettle();
    expect(editor.pieceAt(Square.e4)?.role, Role.knight);
    await tester.dragFrom(square(4, 3), square(4, 5) - square(4, 3));
    await tester.pumpAndSettle();
    expect(editor.pieceAt(Square.e4), isNull);
    expect(editor.pieceAt(Square.e6)?.role, Role.knight);
    await tester.dragFrom(square(4, 5), const Offset(400, 0));
    await tester.pumpAndSettle();
    expect(editor.pieceAt(Square.e6), isNull);
    expect(tester.takeException(), isNull);
  });

  test(
    'bughouse editor moves a king atomically without a legal-move constraint',
    () {
      final controller = BughouseController();
      addTearDown(controller.dispose);
      controller.setAnalysisEnabled(false);
      controller.moveEditorPiece(BughouseBoard.a, Square.e1, Square.e4);
      expect(controller.state.boardA.board.pieceAt(Square.e1), isNull);
      expect(controller.state.boardA.board.pieceAt(Square.e4)?.role, Role.king);
      expect(controller.state.boardB, BughouseState.initial().boardB);
    },
  );
}
