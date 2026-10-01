import 'dart:ui' as ui;
import 'package:chess_auto_prep/chess/fen.dart';
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:chess_auto_prep/workspace/board_view.dart';
import 'package:chessground/chessground.dart';
import 'package:dartchess/dartchess.dart';
import 'package:chess_auto_prep/chess/pgn/board_shapes.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final played = <String>[];

  setUp(played.clear);

  Future<void> pump(
    WidgetTester tester, {
    Fen fen = Fen.initial,
    Side orientation = Side.white,
    String? lastMove,
    bool movable = true,
  }) async {
    await tester.binding.setSurfaceSize(const Size(400, 400));
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: BoardView(
          fen: fen,
          orientation: orientation,
          lastMove: lastMove,
          movable: movable,
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

  // Read the actual hint layer's pixels, including square corners: a dot or
  // ring would not pass. Pieces are drawn separately above this background.
  Future<Set<String>> hints(WidgetTester tester) async =>
      (await tester.runAsync(() async {
        final painter = tester
            .widget<CustomPaint>(
              find.byKey(const ValueKey('legal-move-highlights')),
            )
            .foregroundPainter!;
        final recorder = ui.PictureRecorder();
        painter.paint(Canvas(recorder), const Size(400, 400));
        final picture = recorder.endRecording();
        final image = await picture.toImage(400, 400);
        final data = (await image.toByteData())!;
        final squares = <String>{};
        for (var file = 0; file < 8; file++) {
          for (var rank = 0; rank < 8; rank++) {
            final x = file * 50;
            final y = (7 - rank) * 50;
            final alpha = data.getUint8(((y + 2) * 400 + x + 2) * 4 + 3);
            if (alpha == 0) continue;
            expect(data.getUint8(((y + 25) * 400 + x + 25) * 4 + 3), alpha);
            expect(data.getUint8(((y + 47) * 400 + x + 47) * 4 + 3), alpha);
            squares.add('${String.fromCharCode(97 + file)}${rank + 1}');
          }
        }
        image.dispose();
        picture.dispose();
        return squares;
      }))!;

  testWidgets('selection tints whole legal squares and clears on deselection', (
    tester,
  ) async {
    await pump(tester);
    expect(await hints(tester), isEmpty);
    await tester.tapAt(at('e2'));
    await tester.pump();
    expect(await hints(tester), {'e3', 'e4'});
    await tester.tapAt(at('g1'));
    await tester.pump();
    expect(await hints(tester), {'f3', 'h3'});
    await tester.tapAt(at('g1'));
    await tester.pump();
    expect(await hints(tester), isEmpty);
  });

  testWidgets(
    'dragging shows legal squares, never the hovered illegal square',
    (tester) async {
      await pump(tester);
      final gesture = await tester.startGesture(at('g1'));
      await gesture.moveTo(at('e4'));
      await tester.pump();
      expect(await hints(tester), {'f3', 'h3'});
      expect(
        tester
            .widget<Chessboard>(find.byType(Chessboard))
            .settings
            .dragTargetKind,
        DragTargetKind.none,
      );
      await gesture.up();
      await tester.pump();
      expect(await hints(tester), isEmpty);
      expect(played, isEmpty);
    },
  );

  testWidgets('capture and en passant destinations use the same square tint', (
    tester,
  ) async {
    await pump(tester, fen: const Fen('7k/8/3n4/3pP3/8/8/8/K7 w - - 0 1'));
    // Use an ordinary capture first, then the same destination en passant.
    await tester.tapAt(at('e5'));
    await tester.pump();
    expect(await hints(tester), {'d6', 'e6'});
    await pump(tester, fen: const Fen('7k/8/8/3pP3/8/8/8/K7 w - d6 0 1'));
    expect(await hints(tester), isEmpty);
    await tester.tapAt(at('e5'));
    await tester.pump();
    expect(await hints(tester), {'d6', 'e6'});
  });

  testWidgets(
    'pinned pieces have no illegal hints and read-only boards have none',
    (tester) async {
      await pump(tester, fen: const Fen('4r2k/8/8/8/8/8/4N3/4K3 w - - 0 1'));
      await tester.tapAt(at('e2'));
      await tester.pump();
      expect(await hints(tester), isEmpty);
      await pump(tester);
      await tester.tapAt(at('e2'));
      await tester.pump();
      await pump(tester, movable: false);
      await tester.pumpAndSettle();
      expect(await hints(tester), isEmpty);
    },
  );

  testWidgets('hints follow a flipped board and clear on a new position', (
    tester,
  ) async {
    await pump(tester, orientation: Side.black);
    await tester.tapAt(at('d7')); // e2 seen from Black
    await tester.pump();
    expect(await hints(tester), {'d6', 'd5'});
    await pump(tester, fen: const Fen('7k/8/8/8/8/8/8/K7 w - - 0 1'));
    await tester.pumpAndSettle();
    expect(await hints(tester), isEmpty);
  });

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

  group('arrows and circles', () {
    final kept = <BoardShape>[];
    setUp(kept.clear);

    Future<void> board(
      WidgetTester tester, {
      Fen fen = Fen.initial,
      List<BoardShape> shapes = const [],
      BoardShape? threat,
      bool keeps = false,
      VoidCallback? onClear,
    }) async {
      await tester.binding.setSurfaceSize(const Size(400, 400));
      await tester.pumpWidget(
        MaterialApp(
          theme: darkTheme(),
          home: BoardView(
            fen: fen,
            orientation: Side.white,
            onMove: played.add,
            shapes: shapes,
            threat: threat,
            onDraw: keeps ? kept.add : null,
            onClear: onClear,
          ),
        ),
      );
    }

    /// Circles are chessground's; arrows are drawn over it, Lichess-sized.
    Set<Object> drawn(WidgetTester tester) => {
      ...tester.widget<Chessboard>(find.byType(Chessboard)).shapes,
      ...tester.widget<BoardArrows>(find.byType(BoardArrows)).arrows,
    };

    Future<void> rightDrag(WidgetTester tester, String from, String to) async {
      final gesture = await tester.startGesture(
        at(from),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryButton,
      );
      await gesture.moveTo(at(to));
      await gesture.up();
      await tester.pump();
    }

    testWidgets('a right-drag draws an arrow and a right-click a circle; a '
        'left click wipes them', (tester) async {
      await board(tester);
      await rightDrag(tester, 'g1', 'f3');
      await rightDrag(tester, 'd4', 'd4');
      expect(drawn(tester), {
        const BoardShape(Square.g1, Square.f3, ShapeColour.green),
        const Circle(color: shapeGreen, orig: Square.d4),
      });
      await rightDrag(tester, 'd4', 'd4');
      expect(drawn(tester), hasLength(1), reason: 'drawn twice, it goes');
      await tester.tapAt(at('e5'));
      await tester.pump();
      expect(drawn(tester), isEmpty);
      expect(played, isEmpty);
    });

    testWidgets('a new position wipes what was drawn on the old one', (
      tester,
    ) async {
      await board(tester);
      await rightDrag(tester, 'e2', 'e4');
      expect(drawn(tester), hasLength(1));
      await board(
        tester,
        fen: const Fen(
          'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1',
        ),
      );
      expect(drawn(tester), isEmpty);
    });

    testWidgets('with somewhere to keep them, shapes go there in the colour '
        'the keys held say, and what is kept is drawn', (tester) async {
      await board(tester, keeps: true);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await rightDrag(tester, 'e2', 'e4');
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await rightDrag(tester, 'c3', 'c3');
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      expect(kept, const [
        BoardShape(Square.e2, Square.e4, ShapeColour.red),
        BoardShape.circle(Square.c3, ShapeColour.blue),
      ]);
      expect(drawn(tester), isEmpty, reason: 'the keeper draws them back');
      await board(
        tester,
        keeps: true,
        shapes: const [BoardShape.circle(Square.c3, ShapeColour.yellow)],
      );
      expect(drawn(tester), {
        const Circle(color: shapeYellow, orig: Square.c3),
      });
    });

    testWidgets('a left click asks for kept shapes to go and leaves the '
        'threat', (tester) async {
      var cleared = 0;
      const threat = BoardShape(Square.d8, Square.h4, ShapeColour.red);
      await board(
        tester,
        keeps: true,
        shapes: const [BoardShape(Square.e2, Square.e4, ShapeColour.green)],
        threat: threat,
        onClear: () => cleared++,
      );
      await tester.tapAt(at('e5'));
      await tester.pump();
      expect(cleared, 1);
    });

    testWidgets('with nowhere to take them from, a left click hides the '
        'shapes until the position changes; the threat stays', (tester) async {
      const arrow = BoardShape(Square.e2, Square.e4, ShapeColour.green);
      const threat = BoardShape(Square.d8, Square.h4, ShapeColour.red);
      await board(tester, shapes: const [arrow], threat: threat);
      expect(drawn(tester), {arrow, threat});
      await tester.tapAt(at('e5'));
      await tester.pump();
      expect(drawn(tester), {threat});
      expect(played, isEmpty);
      await board(
        tester,
        fen: const Fen(
          'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1',
        ),
        shapes: const [arrow],
        threat: threat,
      );
      expect(drawn(tester), {arrow, threat});
    });
  });
}
