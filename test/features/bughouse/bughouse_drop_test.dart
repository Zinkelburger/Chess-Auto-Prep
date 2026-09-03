import 'package:chess_auto_prep/features/bughouse/controllers/bughouse_controller.dart';
import 'package:chess_auto_prep/features/bughouse/models/bughouse_state.dart';
import 'package:chess_auto_prep/features/bughouse/widgets/bughouse_board_card.dart';
import 'package:chess_auto_prep/widgets/chess_board_widget.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Dropping a reserve piece by dragging it, which is how a piece gets onto a
/// bughouse board most of the time.
void main() {
  const withPawn =
      'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR[P] w KQkq - 0 1';
  const plain = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR[] w KQkq - 0 1';

  /// The centre of [square] on a board drawn in [rect].
  ///
  /// Deliberately written from the square to the pixel, the opposite direction
  /// to the widget's own pixel-to-square mapping, so the two have to agree.
  Offset centreOf(Rect rect, Square square, {bool flipped = false}) {
    final cell = rect.width / 8;
    final col = flipped ? 7 - square.file.value : square.file.value;
    final row = flipped ? square.rank.value : 7 - square.rank.value;
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
          // A board card is a column of a board, two reserves, two seat
          // rows and a movetext, so it is taller than a test viewport.
          // These tests are about where a dragged piece lands, not fitting.
          body: SingleChildScrollView(
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

  testWidgets('a drop lands on the square under the pointer, either way up', (
    tester,
  ) async {
    // `_DropTarget` re-derives the board's geometry rather than asking the
    // board widget for it, so the two can drift apart silently — a padding or
    // a border on `ChessBoardWidget` would send every drop to the wrong
    // square with nothing to notice it. Corners in both orientations pin the
    // file/rank mapping in the direction that would break first.
    const knight = '4k3/8/8/8/8/8/8/4K3[N] w - - 0 1';

    for (final (flipped, square) in [
      (false, Square.a1),
      (false, Square.h8),
      (true, Square.a1),
      (true, Square.h8),
    ]) {
      final controller = BughouseController();
      addTearDown(controller.dispose);
      controller.loadDualFen('$knight|$plain');
      if (flipped) controller.toggleFlip(BughouseBoard.a);
      expect(controller.isFlipped(BughouseBoard.a), flipped);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            // A board card is a column of a board, two reserves, two seat
            // rows and a movetext, so it is taller than a test viewport.
            // These tests are about where a dragged piece lands, not fitting.
            body: SingleChildScrollView(
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
      final piece = find.byKey(
        const ValueKey('bughouse-pocket-a-white-knight'),
        skipOffstage: false,
      );
      final gesture = await tester.startGesture(tester.getCenter(piece));
      await tester.pump(const Duration(milliseconds: 30));
      await gesture.moveTo(centreOf(board, square, flipped: flipped));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(
        controller.state.boardA.board.pieceAt(square),
        const Piece(color: Side.white, role: Role.knight),
        reason: 'dropping on ${square.name} with flipped=$flipped',
      );
    }
  });

  testWidgets('a drag that ends off the board changes nothing', (tester) async {
    final controller = BughouseController();
    addTearDown(controller.dispose);
    controller.loadDualFen('$withPawn|$plain');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          // A board card is a column of a board, two reserves, two seat
          // rows and a movetext, so it is taller than a test viewport.
          // These tests are about where a dragged piece lands, not fitting.
          body: SingleChildScrollView(
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

  testWidgets('the editor places and clears pieces by clicking the board', (
    tester,
  ) async {
    // The board widget swallows every tap when user moves are off, which is
    // what the editor runs with — so its clicks never reached the controller
    // and picking a piece then clicking a square did nothing at all.
    final controller = BughouseController();
    addTearDown(controller.dispose);
    controller.loadDualFen('$plain|$plain');
    controller.setMode(BughouseMode.setup);
    controller.setTool(
      const PlaceTool(Piece(color: Side.white, role: Role.queen)),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
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
    await tester.tapAt(centreOf(board, Square.e5));
    await tester.pumpAndSettle();
    expect(
      controller.state.boardA.board.pieceAt(Square.e5),
      const Piece(color: Side.white, role: Role.queen),
    );

    // Right-click clears, whichever tool is selected.
    await tester.tapAt(centreOf(board, Square.e5), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(controller.state.boardA.board.pieceAt(Square.e5), isNull);
  });
}
