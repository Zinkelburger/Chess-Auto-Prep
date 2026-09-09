import 'package:chess_auto_prep/core/board_editor_controller.dart';
import 'package:chess_auto_prep/widgets/board_editor/board_editor_widget.dart';
import 'package:chess_auto_prep/widgets/board_editor/piece_palette.dart';
import 'package:chess_auto_prep/widgets/board_editor/editable_board.dart';
import 'package:chess_auto_prep/features/bughouse/controllers/bughouse_controller.dart';
import 'package:chess_auto_prep/features/bughouse/models/bughouse_state.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const whiteKnight = Piece(color: Side.white, role: Role.knight);
const blackKnight = Piece(color: Side.black, role: Role.knight);

void main() {
  late BoardEditorController editor;

  Future<void> pumpEditor(WidgetTester tester) async {
    editor = BoardEditorController();
    addTearDown(editor.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListenableBuilder(
            listenable: editor,
            builder: (_, _) => Column(
              children: [
                SizedBox(
                  width: 320,
                  child: SparePieceRow(
                    side: Side.white,
                    tool: editor.tool,
                    onSelect: editor.selectTool,
                  ),
                ),
                SizedBox(
                  width: 320,
                  height: 320,
                  child: BoardEditorWidget(controller: editor),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Offset square(WidgetTester tester, int file, int rank) =>
      tester.getTopLeft(find.byType(EditableBoard)) +
      Offset(file * 40 + 20, (7 - rank) * 40 + 20);

  Finder spare(Piece piece) =>
      find.byWidgetPredicate((w) => w is Draggable<Piece> && w.data == piece);

  testWidgets('palette drag places and leaves the pointer in hand', (
    tester,
  ) async {
    await pumpEditor(tester);
    editor.selectTool(const PieceBrush(blackKnight));
    await tester.pump();

    final origin = tester.getCenter(spare(whiteKnight));
    await tester.dragFrom(origin, square(tester, 4, 3) - origin);
    await tester.pumpAndSettle();
    expect(editor.pieceAt(Square.e4), whiteKnight);
    expect(editor.tool, const PointerTool());
    expect(tester.takeException(), isNull);
  });

  testWidgets('pointer drags pieces freely and off the board removes them', (
    tester,
  ) async {
    await pumpEditor(tester);
    await tester.dragFrom(
      square(tester, 4, 1),
      square(tester, 4, 5) - square(tester, 4, 1),
    );
    await tester.pumpAndSettle();
    expect(editor.pieceAt(Square.e2), isNull);
    expect(editor.pieceAt(Square.e6)?.role, Role.pawn);

    await tester.dragFrom(square(tester, 4, 5), const Offset(400, 0));
    await tester.pumpAndSettle();
    expect(editor.pieceAt(Square.e6), isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('flipped board maps palette drops and piece moves correctly', (
    tester,
  ) async {
    await pumpEditor(tester);
    editor.toggleFlip();
    await tester.pump();
    Offset flippedSquare(int file, int rank) =>
        tester.getTopLeft(find.byType(EditableBoard)) +
        Offset((7 - file) * 40 + 20, rank * 40 + 20);
    final origin = tester.getCenter(spare(whiteKnight));
    await tester.dragFrom(origin, flippedSquare(4, 3) - origin);
    await tester.pumpAndSettle();
    expect(editor.pieceAt(Square.e4), whiteKnight);
    await tester.dragFrom(
      flippedSquare(4, 3),
      flippedSquare(3, 4) - flippedSquare(4, 3),
    );
    await tester.pumpAndSettle();
    expect(editor.pieceAt(Square.e4), isNull);
    expect(editor.pieceAt(Square.d5), whiteKnight);
    expect(tester.takeException(), isNull);
  });

  testWidgets('clicking a spare piece takes it in hand; a press paints it, '
      'pressing the same piece removes it', (tester) async {
    await pumpEditor(tester);
    await tester.tap(spare(whiteKnight));
    await tester.pump();
    expect(editor.tool, const PieceBrush(whiteKnight));

    await tester.tapAt(square(tester, 4, 3));
    await tester.pump();
    expect(editor.pieceAt(Square.e4), whiteKnight);

    await tester.tapAt(square(tester, 4, 3));
    await tester.pump();
    expect(editor.pieceAt(Square.e4), isNull);

    // Clicking the selected spare again puts it down.
    await tester.tap(spare(whiteKnight));
    await tester.pump();
    expect(editor.tool, const PointerTool());
  });

  testWidgets('a held stroke paints every square it crosses', (tester) async {
    await pumpEditor(tester);
    editor.clear();
    editor.selectTool(const PieceBrush(whiteKnight));
    await tester.pump();

    final gesture = await tester.startGesture(square(tester, 0, 3));
    for (var file = 1; file < 8; file++) {
      await gesture.moveTo(square(tester, file, 3));
      await tester.pump();
    }
    await gesture.up();
    await tester.pump();
    for (var file = 0; file < 8; file++) {
      expect(editor.pieceAt(Square(3 * 8 + file)), whiteKnight);
    }
  });

  testWidgets('a stroke that starts by lifting the piece does not paint', (
    tester,
  ) async {
    await pumpEditor(tester);
    editor.clear();
    editor.setPiece(Square.a4, whiteKnight);
    editor.selectTool(const PieceBrush(whiteKnight));
    await tester.pump();

    final gesture = await tester.startGesture(square(tester, 0, 3));
    await gesture.moveTo(square(tester, 1, 3));
    await gesture.moveTo(square(tester, 2, 3));
    await gesture.up();
    await tester.pump();
    expect(editor.pieceAt(Square.a4), isNull);
    expect(editor.pieceAt(Square.b4), isNull);
    expect(editor.pieceAt(Square.c4), isNull);
  });

  testWidgets('the eraser clears along a stroke', (tester) async {
    await pumpEditor(tester);
    editor.selectTool(const EraserTool());
    await tester.pump();

    final gesture = await tester.startGesture(square(tester, 0, 1));
    await gesture.moveTo(square(tester, 1, 1));
    await gesture.moveTo(square(tester, 2, 1));
    await gesture.up();
    await tester.pump();
    expect(editor.pieceAt(Square.a2), isNull);
    expect(editor.pieceAt(Square.b2), isNull);
    expect(editor.pieceAt(Square.c2), isNull);
    expect(editor.pieceAt(Square.d2)?.role, Role.pawn);
  });

  testWidgets(
    'right-click clears with the pointer and swaps the brush colour',
    (tester) async {
      await pumpEditor(tester);
      await tester.tapAt(square(tester, 4, 1), buttons: kSecondaryButton);
      await tester.pump();
      expect(editor.pieceAt(Square.e2), isNull);

      editor.selectTool(const PieceBrush(whiteKnight));
      await tester.pump();
      await tester.tapAt(square(tester, 4, 3), buttons: kSecondaryButton);
      await tester.pump();
      expect(editor.tool, const PieceBrush(blackKnight));
      expect(editor.pieceAt(Square.e4), isNull);
    },
  );

  testWidgets('the palette shows pointer, six pieces and the bin per colour', (
    tester,
  ) async {
    await pumpEditor(tester);
    expect(find.byIcon(Icons.pan_tool_alt_outlined), findsOneWidget);
    expect(find.byIcon(Icons.delete_outline), findsOneWidget);
    expect(find.byType(Draggable<Piece>), findsNWidgets(6));

    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pump();
    expect(editor.tool, const EraserTool());
    await tester.tap(find.byIcon(Icons.pan_tool_alt_outlined));
    await tester.pump();
    expect(editor.tool, const PointerTool());
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

  test('bughouse editor shares the brush semantics', () {
    final controller = BughouseController();
    addTearDown(controller.dispose);
    controller.setAnalysisEnabled(false);
    controller.setMode(BughouseMode.setup);
    controller.clearBoard(BughouseBoard.a);
    controller.setTool(const PieceBrush(whiteKnight));

    controller.applyTool(BughouseBoard.a, Square.e4);
    expect(controller.state.boardA.board.pieceAt(Square.e4), whiteKnight);
    controller.paintSquare(BughouseBoard.a, Square.f4);
    expect(controller.state.boardA.board.pieceAt(Square.f4), whiteKnight);
    controller.applyTool(BughouseBoard.a, Square.e4);
    expect(controller.state.boardA.board.pieceAt(Square.e4), isNull);

    controller.secondaryPress(BughouseBoard.a, Square.f4);
    expect(controller.tool, const PieceBrush(blackKnight));
    expect(controller.state.boardA.board.pieceAt(Square.f4), whiteKnight);

    controller.setTool(const PointerTool());
    controller.secondaryPress(BughouseBoard.a, Square.f4);
    expect(controller.state.boardA.board.pieceAt(Square.f4), isNull);
  });
}
