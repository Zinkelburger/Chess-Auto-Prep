/// How the movetext renders a game an engine has been over.
///
/// A full analysis pass leaves an `[%eval]` on every ply. Rendering each of
/// those as a comment put one move per row and made the game unreadable, so
/// the scores are dropped and only the moves that actually cost something are
/// marked. These pin both halves of that: the silence, and the marks.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/widgets/pgn_viewer_widget.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpPgn(WidgetTester tester, String pgn) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: PgnViewerWidget(pgnText: pgn)),
      ),
    );
    // Not pumpAndSettle: the viewer keeps a progress indicator spinning while
    // it has no engine to talk to, and that never settles under test.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  String renderedText(WidgetTester tester) => tester
      .widgetList<RichText>(find.byType(RichText))
      .map((r) => r.text.toPlainText())
      .join(' ');

  const header = '[Event "Test"]\n[Result "*"]\n\n';

  /// Eight plies, every one scored, White throwing the game away on move 4.
  const analyzed =
      '$header'
      '1. e4 {[%eval 0.20]} e5 {[%eval 0.15]} '
      '2. Nf3 {[%eval 0.25]} Nc6 {[%eval 0.20]} '
      '3. Bb5 {[%eval 0.30]} a6 {[%eval 0.30]} '
      '4. Ng5 {[%eval -6.00] [%pv Ba4,Nf6]} Qxg5 {[%eval -6.10]} *';

  testWidgets('an analyzed game shows none of its per-ply scores', (
    tester,
  ) async {
    await pumpPgn(tester, analyzed);
    final text = renderedText(tester);

    expect(text, isNot(contains('eval +')));
    expect(text, isNot(contains('eval -')));
    // The moves themselves all survive.
    for (final san in ['e4', 'e5', 'Nf3', 'Nc6', 'Bb5', 'a6', 'Ng5']) {
      expect(text, contains(san));
    }
  });

  testWidgets('the move that cost something is marked, before → after', (
    tester,
  ) async {
    await pumpPgn(tester, analyzed);
    final text = renderedText(tester);

    expect(text, contains('Blunder'));
    expect(text, contains('+0.3 → -6.0'));
    // Only the one move is marked, not the seven quiet ones.
    expect('Blunder'.allMatches(text).length, 1);
  });

  testWidgets('a marked move offers the stored line as clickable moves', (
    tester,
  ) async {
    await pumpPgn(tester, analyzed);
    final text = renderedText(tester);

    expect(text, contains('Best:'));
    expect(text, contains('Ba4'));
    expect(text, contains('Nf6'));
  });

  testWidgets('one hand-written eval on a move is still shown', (tester) async {
    await pumpPgn(
      tester,
      '$header'
      '1. e4 {[%eval 0.20]} e5 2. Nf3 Nc6 3. Bb5 a6 4. Ba4 Nf6 *',
    );

    // Not a machine-annotated game — a lone score is a fact worth reading.
    expect(renderedText(tester), contains('eval +0.2'));
  });

  testWidgets('a generated repertoire keeps its per-move facts', (
    tester,
  ) async {
    await pumpPgn(
      tester,
      '$header'
      '1. e4 {[%eval 0.20] [%maiaProbability 0.42]} '
      'e5 {[%eval 0.15] [%maiaProbability 0.55]} '
      '2. Nf3 {[%eval 0.25] [%onlyMove]} '
      'Nc6 {[%eval 0.20] [%maiaProbability 0.61]} '
      '3. Bb5 {[%eval 0.30] [%onlyMove]} '
      'a6 {[%eval 0.30] [%maiaProbability 0.48]} *',
    );

    // These carry more than a score, so they are not eval spam and stay put.
    final text = renderedText(tester);
    expect(text, contains('eval +0.2'));
    expect(text, contains('42% likely'));
    expect(text, contains('only move'));
  });
}
