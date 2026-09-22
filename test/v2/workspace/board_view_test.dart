import 'package:chess_auto_prep/v2/chess/fen.dart';
import 'package:chess_auto_prep/v2/ui/theme.dart';
import 'package:chess_auto_prep/v2/workspace/board_view.dart';
import 'package:chessground/chessground.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final played = <String>[];

  setUp(played.clear);

  Future<void> pump(
    WidgetTester tester, {
    Fen fen = Fen.initial,
    Side orientation = Side.white,
    String? lastMove,
  }) async {
    await tester.binding.setSurfaceSize(const Size(400, 400));
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: BoardView(
          fen: fen,
          orientation: orientation,
          lastMove: lastMove,
          onMove: played.add,
        ),
      ),
    );
  }

  /// The pieces the board is showing, from its controller: they are painted,
  /// not widgets, so this is the one way to ask.
  Map<Square, Piece> pieces(WidgetTester tester) =>
      tester.widget<Chessboard>(find.byType(Chessboard)).controller.pieces;

  ChessboardController controller(WidgetTester tester) =>
      tester.widget<Chessboard>(find.byType(Chessboard)).controller;

  /// The centre of a square, with the board 400px wide and White below.
  Offset at(String square) {
    final file = square.codeUnitAt(0) - 'a'.codeUnitAt(0);
    final rank = int.parse(square[1]) - 1;
    return Offset(file * 50 + 25, (7 - rank) * 50 + 25);
  }

  testWidgets('puts every piece of the start position on the board', (
    tester,
  ) async {
    await pump(tester);
    expect(pieces(tester), hasLength(32));
    expect(pieces(tester)[Square.e1], Piece.whiteKing);
    expect(pieces(tester)[Square.e7], Piece.blackPawn);
  });

  testWidgets('shows the chosen side at the bottom', (tester) async {
    await pump(tester, orientation: Side.black);
    expect(
      tester.widget<Chessboard>(find.byType(Chessboard)).orientation,
      Side.black,
    );
    // From Black's side a1 is top right, so a tap there is on the white rook.
    await tester.tapAt(at('h8'));
    await tester.pump();
    await tester.tapAt(at('h6'));
    await tester.pump();
    expect(played, isEmpty, reason: 'a rook blocked by its pawn cannot move');
    await tester.tapAt(at('g8'));
    await tester.pump();
    await tester.tapAt(at('f6'));
    await tester.pump();
    expect(played, ['b1c3'], reason: 'g8 from Black is b1 on the board');
  });

  testWidgets('an empty board has no pieces', (tester) async {
    await pump(tester, fen: const Fen('8/8/8/8/8/8/8/8 w - - 0 1'));
    expect(pieces(tester), isEmpty);
  });

  testWidgets('a position nobody can read is drawn empty, not thrown', (
    tester,
  ) async {
    await pump(tester, fen: const Fen(''));
    expect(tester.takeException(), isNull);
    expect(pieces(tester), isEmpty);
    await pump(tester, fen: const Fen('rubbish'));
    expect(tester.takeException(), isNull);
    expect(pieces(tester), isEmpty);
  });

  testWidgets('a new position replaces the old one', (tester) async {
    await pump(tester);
    await pump(
      tester,
      fen: const Fen(
        'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1',
      ),
      lastMove: 'e2e4',
    );
    await tester.pumpAndSettle();
    expect(pieces(tester)[Square.e4], Piece.whitePawn);
    expect(pieces(tester)[Square.e2], isNull);
    expect(controller(tester).lastMove, Move.parse('e2e4'));
  });

  testWidgets('a piece and then a square plays that move', (tester) async {
    await pump(tester);
    await tester.tapAt(at('e2'));
    await tester.pump();
    await tester.tapAt(at('e4'));
    await tester.pump();
    expect(played, ['e2e4']);
  });

  testWidgets('a square with nothing to play there changes nothing', (
    tester,
  ) async {
    await pump(tester);
    await tester.tapAt(at('e2'));
    await tester.pump();
    await tester.tapAt(at('e5'));
    await tester.pump();
    expect(played, isEmpty);
    await tester.tapAt(at('d2'));
    await tester.pump();
    await tester.tapAt(at('d4'));
    await tester.pump();
    expect(played, ['d2d4'], reason: 'the second piece is the selected one');
  });

  testWidgets('the other side cannot be moved', (tester) async {
    await pump(tester);
    await tester.tapAt(at('e7'));
    await tester.pump();
    await tester.tapAt(at('e5'));
    await tester.pump();
    expect(played, isEmpty);
  });

  testWidgets('dragging a piece plays the move', (tester) async {
    await pump(tester);
    await tester.dragFrom(at('g1'), at('f3') - at('g1'));
    await tester.pump();
    expect(played, ['g1f3']);
  });

  testWidgets('letting go away from the board plays no move', (tester) async {
    await pump(tester);
    await tester.dragFrom(at('g1'), const Offset(430, 250) - at('g1'));
    await tester.pump();
    expect(played, isEmpty);
  });

  testWidgets('a promotion waits for the piece and then plays it', (
    tester,
  ) async {
    await pump(tester, fen: const Fen('8/4P3/8/8/8/8/8/K6k w - - 0 1'));
    await tester.tapAt(at('e7'));
    await tester.pump();
    await tester.tapAt(at('e8'));
    await tester.pump();
    await tester.pump();
    expect(played, isEmpty, reason: 'nothing is played until a piece is named');
    expect(controller(tester).pendingPromotion, isNotNull);
    // The choices run down the file from the last rank: queen, knight, rook,
    // bishop.
    await tester.tapAt(at('e7'));
    await tester.pump();
    expect(played, ['e7e8n']);
  });

  testWidgets('a promotion nobody answers plays no move', (tester) async {
    await pump(tester, fen: const Fen('8/4P3/8/8/8/8/8/K6k w - - 0 1'));
    await tester.tapAt(at('e7'));
    await tester.pump();
    await tester.tapAt(at('e8'));
    await tester.pump();
    await tester.pump();
    await tester.tapAt(at('a4')); // away from the choices
    await tester.pump();
    expect(played, isEmpty);
    expect(controller(tester).pendingPromotion, isNull);
  });
}
