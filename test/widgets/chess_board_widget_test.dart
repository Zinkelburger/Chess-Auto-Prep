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

  group('promotion', () {
    // White pawn on b7, black king h8, white king e1: b7-b8 promotes.
    final promo = Chess.fromSetup(
      Setup.parseFen('7k/1P6/8/8/8/8/8/4K3 w - - 0 1'),
    );

    Widget interactive(void Function(CompletedMove) onMove) => MaterialApp(
      home: Center(
        child: SizedBox(
          width: 320,
          height: 320,
          child: ChessBoardWidget(position: promo, onMove: onMove),
        ),
      ),
    );

    Offset squareCenter(WidgetTester tester, String square) {
      final origin = tester.getTopLeft(find.byType(ChessBoardWidget));
      final file = square.codeUnitAt(0) - 'a'.codeUnitAt(0);
      final rank = int.parse(square[1]) - 1;
      return origin + Offset(file * 40 + 20, (7 - rank) * 40 + 20);
    }

    testWidgets('a pawn reaching the last rank opens the picker, not a queen', (
      tester,
    ) async {
      final moves = <CompletedMove>[];
      await tester.pumpWidget(interactive(moves.add));
      await tester.tapAt(squareCenter(tester, 'b7'));
      await tester.pump();
      await tester.tapAt(squareCenter(tester, 'b8'));
      await tester.pump();

      expect(moves, isEmpty);
      expect(find.byKey(const Key('promotion-choice')), findsOneWidget);
      for (final r in ['Q', 'N', 'R', 'B']) {
        expect(find.byKey(ValueKey('promote-$r')), findsOneWidget);
      }
    });

    testWidgets('picking the knight plays an underpromotion', (tester) async {
      final moves = <CompletedMove>[];
      await tester.pumpWidget(interactive(moves.add));
      await tester.tapAt(squareCenter(tester, 'b7'));
      await tester.pump();
      await tester.tapAt(squareCenter(tester, 'b8'));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('promote-N')));
      await tester.pump();

      expect(moves.map((m) => m.uci), ['b7b8n']);
      expect(moves.single.san, 'b8=N');
      expect(find.byKey(const Key('promotion-choice')), findsNothing);
    });

    testWidgets('the choices sit on the promotion file from the last rank', (
      tester,
    ) async {
      await tester.pumpWidget(interactive((_) {}));
      await tester.tapAt(squareCenter(tester, 'b7'));
      await tester.pump();
      await tester.tapAt(squareCenter(tester, 'b8'));
      await tester.pump();

      // Queen on b8, then knight b7, rook b6, bishop b5 — lila's order.
      expect(
        tester.getCenter(find.byKey(const ValueKey('promote-Q'))),
        squareCenter(tester, 'b8'),
      );
      expect(
        tester.getCenter(find.byKey(const ValueKey('promote-B'))),
        squareCenter(tester, 'b5'),
      );
    });

    testWidgets('clicking off the column cancels', (tester) async {
      final moves = <CompletedMove>[];
      await tester.pumpWidget(interactive(moves.add));
      await tester.tapAt(squareCenter(tester, 'b7'));
      await tester.pump();
      await tester.tapAt(squareCenter(tester, 'b8'));
      await tester.pump();
      await tester.tapAt(squareCenter(tester, 'f4'));
      await tester.pump();

      expect(moves, isEmpty);
      expect(find.byKey(const Key('promotion-choice')), findsNothing);
    });
  });
}
