/// Comments render as plain flowing prose by default: double spaces inside
/// prose (common in Lichess study exports) are collapsed instead of being
/// treated as book-PGN paragraph breaks, and no bordered comment blocks are
/// created. Book formatting stays available behind [PgnViewerWidget.bookFormatting].
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/widgets/pgn_viewer_widget.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Alon's Modern Benoni style: double spaces around square/piece names.
  const pgn = '1. d4 {Opening the  d -file and letting the  c1 -bishop '
      'threaten a future  Bg5  are two simple ideas that justify it.} Nf6 *';

  Future<void> pumpViewer(WidgetTester tester, {bool bookFormatting = false}) {
    return tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: PgnViewerWidget(pgnText: pgn, bookFormatting: bookFormatting),
      ),
    ));
  }

  testWidgets('double spaces collapse to one flowing comment by default',
      (tester) async {
    await pumpViewer(tester);
    await tester.pumpAndSettle();

    // The whole comment flows as one run of prose with whitespace collapsed
    // (no paragraph split at the double spaces).
    expect(
      find.textContaining('Opening the d -file and letting the c1 -bishop',
          findRichText: true),
      findsOneWidget,
    );
  });

  testWidgets('book formatting still splits on double spaces when opted in',
      (tester) async {
    await pumpViewer(tester, bookFormatting: true);
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Opening the d -file', findRichText: true),
      findsNothing,
    );
    expect(
      find.textContaining('Opening the', findRichText: true),
      findsOneWidget,
    );
  });
}
