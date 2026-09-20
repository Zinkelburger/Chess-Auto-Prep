import 'package:chess_auto_prep/v2/chess/fen.dart';
import 'package:chess_auto_prep/v2/ui/theme.dart';
import 'package:chess_auto_prep/v2/workspace/board_view.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pump(
    WidgetTester tester, {
    Fen fen = Fen.initial,
    Side orientation = Side.white,
  }) async {
    await tester.binding.setSurfaceSize(const Size(400, 400));
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: BoardView(fen: fen, orientation: orientation, lastMove: null),
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
}
