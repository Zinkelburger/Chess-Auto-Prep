// The positions table's header and rows: the column the table is sorted by
// carries the arrow, pointing the way it sorts, and a position's line says
// its unfinished games and its engine score. (Sorting by a column's name is
// in shell_players_test.dart.)
import 'package:chess_auto_prep/chess/fen.dart';
import 'package:chess_auto_prep/features/players/analysis_rows.dart';
import 'package:chess_auto_prep/features/players/player_analysis.dart';
import 'package:chess_auto_prep/features/players/player_games.dart';
import 'package:chess_auto_prep/ui/app_icons.dart';
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/window_fixture.dart';

void main() {
  late WindowFixture w;
  setUp(() => w = WindowFixture());
  tearDown(() => w.dispose());

  Future<void> show(WidgetTester tester, Widget child) => tester.pumpWidget(
    MaterialApp(
      theme: darkTheme(),
      home: Scaffold(body: SizedBox(width: 400, child: child)),
    ),
  );

  /// The column whose name carries the arrow, and which way it points.
  (String, IconData)? sorted(WidgetTester tester) {
    final arrows = find.byWidgetPredicate(
      (w) =>
          w is Icon &&
          (w.icon == AppIcons.sortAscending ||
              w.icon == AppIcons.sortDescending),
    );
    final icons = tester.widgetList<Icon>(arrows).toList();
    expect(icons.length, lessThanOrEqualTo(1));
    if (icons.isEmpty) return null;
    for (final name in ['Eval', 'Games', 'Score']) {
      // The nearest row is the column's own: its name and the arrow.
      final column = find
          .ancestor(of: find.text(name), matching: find.byType(Row))
          .first;
      if (find.descendant(of: column, matching: arrows).evaluate().isNotEmpty) {
        return (name, icons.single.icon!);
      }
    }
    return null;
  }

  testWidgets('the arrow is on the column the table is sorted by, and points '
      'the way it sorts', (tester) async {
    final analysis = w.parts.players.analysis..evals['x'] = 0;
    for (final (order, expected) in [
      (PositionOrder.frequent, ('Games', AppIcons.sortDescending)),
      (PositionOrder.lowScore, ('Score', AppIcons.sortAscending)),
      (PositionOrder.highScore, ('Score', AppIcons.sortDescending)),
      (PositionOrder.badEval, ('Eval', AppIcons.sortDescending)),
    ]) {
      analysis.order = order;
      await show(tester, PositionsHeader(analysis: analysis));
      expect(sorted(tester), expected, reason: '$order');
    }
  });

  testWidgets('a position names its unfinished games, one or more, and its '
      'engine score', (tester) async {
    final position = PlayerPosition(
      fen: Fen.initial,
      side: Side.white,
      line: const ['e4'],
      ply: 1,
    )..addGame(0, '*');
    await show(
      tester,
      PositionRow(position: position, eval: null, onOpen: () {}),
    );
    expect(find.text('+0 =0 −0 · 1 unfinished'), findsOneWidget);
    expect(find.text('–'), findsOneWidget);
    position
      ..addGame(1, '1-0')
      ..addGame(2, '*');
    await show(
      tester,
      PositionRow(position: position, eval: 35, onOpen: () {}),
    );
    expect(find.textContaining('+1 =0 −0 · 2 unfinished · '), findsOneWidget);
    expect(find.text('100%'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
  });
}
