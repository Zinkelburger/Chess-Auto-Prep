/// A generated repertoire annotates every move with `[%...]` tokens, and the
/// viewer used to strip all of them as engine noise — so a course-style export
/// read as bare movetext. The tokens now render as a quiet line of plain
/// English under the move, and the raw token text still never reaches the
/// screen.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/widgets/pgn_viewer_widget.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // What the generator writes at full detail, with a refuted alternative
  // hanging off the move it was played instead of.
  const pgn =
      '1. e4 {[%eval +0.31] [%onlyMove] [%myEase 0.81]} '
      '(1. f3? {[%loss 4.30]} e5 2. g4 Qh4#) '
      'e5 {[%maiaProbability 0.420] [%games 128] [%score 54.2%]} *';

  Future<void> pumpViewer(WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: PgnViewerWidget(pgnText: pgn)),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('our move shows its eval, forcedness and naturalness', (
    tester,
  ) async {
    await pumpViewer(tester);

    expect(
      find.textContaining(
        'eval +0.31 · only move · natural for you 81%',
        findRichText: true,
      ),
      findsOneWidget,
    );
  });

  testWidgets('their reply shows how likely it is and how it has gone', (
    tester,
  ) async {
    await pumpViewer(tester);

    expect(
      find.textContaining(
        '42% likely · 128 games · you score 54%',
        findRichText: true,
      ),
      findsOneWidget,
    );
  });

  testWidgets('a refuted sideline says what the move costs', (tester) async {
    await pumpViewer(tester);

    expect(
      find.textContaining('costs 4.30', findRichText: true),
      findsOneWidget,
    );
  });

  testWidgets('the raw tokens themselves never reach the screen', (
    tester,
  ) async {
    await pumpViewer(tester);

    expect(find.textContaining('[%', findRichText: true), findsNothing);
  });
}
