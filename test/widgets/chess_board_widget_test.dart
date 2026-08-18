import 'package:chess_auto_prep/widgets/chess_board_widget.dart';
import 'package:chess_auto_prep/widgets/common/piece_image.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Position after(List<String> sans) {
    Position pos = Chess.initial;
    for (final san in sans) {
      pos = pos.play(pos.parseSan(san)!);
    }
    return pos;
  }

  Widget board(Position pos, {double size = 320}) => MaterialApp(
    home: Center(
      child: SizedBox(
        width: size,
        height: size,
        child: ChessBoardWidget(position: pos, enableUserMoves: false),
      ),
    ),
  );

  /// Top-left of each [PieceImage] relative to the board, in board pixels.
  List<Offset> pieceOrigins(WidgetTester tester) {
    final boardOrigin = tester.getTopLeft(find.byType(ChessBoardWidget));
    return find
        .byType(PieceImage)
        .evaluate()
        .map((el) => tester.getTopLeft(find.byWidget(el.widget)) - boardOrigin)
        .toList();
  }

  bool onSquareGrid(Offset origin, double square) {
    bool axisOnGrid(double value) {
      final rem = value % square;
      return rem < 1.5 || (square - rem) < 1.5;
    }

    return axisOnGrid(origin.dx) && axisOnGrid(origin.dy);
  }

  testWidgets('sibling-line jump does not throw', (tester) async {
    await tester.pumpWidget(board(after(['d4', 'd5', 'c4', 'c6'])));
    await tester.pump();
    // …c6 → …e6: black pawns c6→c7 and e7→e6 both change in one jump.
    await tester.pumpWidget(board(after(['d4', 'd5', 'c4', 'e6'])));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('resizing the board does not slide pieces off their squares', (
    tester,
  ) async {
    await tester.pumpWidget(board(Chess.initial, size: 160));
    await tester.pumpAndSettle();

    await tester.pumpWidget(board(Chess.initial, size: 320));
    await tester.pump();

    const square = 40.0;
    for (final origin in pieceOrigins(tester)) {
      expect(
        onSquareGrid(origin, square),
        isTrue,
        reason: 'piece at $origin should already sit on the 40 px grid',
      );
    }
  });

  testWidgets('a played move snaps onto the destination square', (
    tester,
  ) async {
    await tester.pumpWidget(board(Chess.initial, size: 320));
    await tester.pumpAndSettle();

    await tester.pumpWidget(board(after(['e4']), size: 320));
    await tester.pump();

    const square = 40.0;
    for (final origin in pieceOrigins(tester)) {
      expect(onSquareGrid(origin, square), isTrue);
    }
  });
}
