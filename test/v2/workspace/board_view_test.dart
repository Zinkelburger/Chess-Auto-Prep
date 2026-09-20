import 'package:chess_auto_prep/v2/chess/fen.dart';
import 'package:chess_auto_prep/v2/ui/theme.dart';
import 'package:chess_auto_prep/v2/workspace/board_view.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final played = <String>[];

  setUp(played.clear);

  Future<void> pump(
    WidgetTester tester, {
    Fen fen = Fen.initial,
    Side orientation = Side.white,
  }) async {
    await tester.binding.setSurfaceSize(const Size(400, 400));
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: BoardView(
          fen: fen,
          orientation: orientation,
          lastMove: null,
          onMove: played.add,
        ),
      ),
    );
  }

  Finder piece(String asset) => find.byWidgetPredicate(
    (w) => w is SvgPicture && '${w.bytesLoader}'.contains(asset),
  );

  testWidgets('puts every piece of the start position on the board', (
    tester,
  ) async {
    await pump(tester);
    expect(find.byType(SvgPicture), findsNWidgets(32));
    expect(piece('wK.svg'), findsOneWidget);
    expect(piece('bP.svg'), findsNWidgets(8));
  });

  testWidgets('shows the chosen side at the bottom', (tester) async {
    await pump(tester);
    final whiteKingFromWhite = tester.getCenter(piece('wK.svg'));
    await pump(tester, orientation: Side.black);
    final whiteKingFromBlack = tester.getCenter(piece('wK.svg'));
    expect(whiteKingFromWhite.dy, greaterThan(200));
    expect(whiteKingFromBlack.dy, lessThan(200));
    expect(
      whiteKingFromWhite.dx,
      greaterThan(200),
      reason: 'e1 is right of centre',
    );
    expect(whiteKingFromBlack.dx, lessThan(200));
  });

  testWidgets('an empty board has no pieces', (tester) async {
    await pump(tester, fen: const Fen('8/8/8/8/8/8/8/8 w - - 0 1'));
    expect(find.byType(SvgPicture), findsNothing);
  });

  testWidgets('a position nobody can read is drawn empty, not thrown', (
    tester,
  ) async {
    await pump(tester, fen: const Fen(''));
    expect(tester.takeException(), isNull);
    expect(find.byType(SvgPicture), findsNothing);
    await pump(tester, fen: const Fen('rubbish'));
    expect(tester.takeException(), isNull);
    expect(find.byType(SvgPicture), findsNothing);
  });

  /// The centre of a square, with the board 400px wide and White below.
  Offset at(String square) {
    final file = square.codeUnitAt(0) - 'a'.codeUnitAt(0);
    final rank = int.parse(square[1]) - 1;
    return Offset(file * 50 + 25, (7 - rank) * 50 + 25);
  }

  testWidgets('a piece and then a square plays that move', (tester) async {
    await pump(tester);
    await tester.tapAt(at('e2'));
    await tester.pump();
    await tester.tapAt(at('e4'));
    expect(played, ['e2e4']);
  });

  testWidgets('a square with nothing to play there changes nothing', (
    tester,
  ) async {
    await pump(tester);
    await tester.tapAt(at('e2'));
    await tester.tapAt(at('e5'));
    await tester.pump();
    expect(played, isEmpty);
    await tester.tapAt(at('d2'));
    await tester.tapAt(at('d4'));
    expect(played, ['d2d4'], reason: 'the second piece is the selected one');
  });

  testWidgets('the other side cannot be moved', (tester) async {
    await pump(tester);
    await tester.tapAt(at('e7'));
    await tester.tapAt(at('e5'));
    await tester.pump();
    expect(played, isEmpty);
  });

  testWidgets('dragging a piece plays the move', (tester) async {
    await pump(tester);
    final gesture = await tester.startGesture(at('g1'));
    await gesture.moveTo(at('f3'));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    expect(played, ['g1f3']);
  });

  testWidgets('letting go away from the board plays no move', (tester) async {
    await pump(tester);
    final gesture = await tester.startGesture(at('g1'));
    await gesture.moveTo(const Offset(430, 250)); // past the right edge
    await tester.pump();
    await gesture.up();
    await tester.pump();
    expect(played, isEmpty);
  });

  testWidgets('a promotion waits for the piece and then plays it', (
    tester,
  ) async {
    await pump(tester, fen: const Fen('8/4P3/8/8/8/8/8/K6k w - - 0 1'));
    await tester.tapAt(at('e7'));
    await tester.tapAt(at('e8'));
    await tester.pump();
    expect(played, isEmpty, reason: 'nothing is played until a piece is named');
    expect(find.byKey(const ValueKey('promote-q')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('promote-n')));
    await tester.pump();
    expect(played, ['e7e8n']);
  });

  testWidgets('a promotion nobody answers plays no move', (tester) async {
    await pump(tester, fen: const Fen('8/4P3/8/8/8/8/8/K6k w - - 0 1'));
    await tester.tapAt(at('e7'));
    await tester.tapAt(at('e8'));
    await tester.pump();
    await tester.tapAt(at('a4')); // the scrim, away from the choices
    await tester.pump();
    expect(played, isEmpty);
    expect(find.byKey(const ValueKey('promote-q')), findsNothing);
  });
}
