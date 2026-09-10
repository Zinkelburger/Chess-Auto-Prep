import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/models/opening_tree.dart';
import 'package:chess_auto_prep/widgets/opening_tree/opening_tree_move_row.dart';
import 'package:chess_auto_prep/widgets/opening_tree/win_draw_loss_bar.dart';

PositionGroup _entry({required bool scored, int count = 3}) {
  final node = OpeningTreeNode(
    move: 'e4',
    fen: Chess.initial.play(Chess.initial.parseSan('e4')!).fen,
  );
  for (var i = 0; i < count; i++) {
    node.updateStats(scored ? 1 : null);
  }
  return PositionGroup([node]);
}

Future<void> _pump(WidgetTester tester, PositionGroup entry) =>
    tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: OpeningTreeMoveRow(entry: entry, parentGamesPlayed: 4),
        ),
      ),
    );

void main() {
  testWidgets('single paths and games use singular labels', (tester) async {
    await _pump(tester, _entry(scored: false, count: 1));
    expect(find.text('1 path · 25%'), findsOneWidget);
    await _pump(tester, _entry(scored: true, count: 1));
    expect(find.text('1 game · 25%'), findsOneWidget);
  });

  testWidgets('unscored course variations are labelled as paths', (
    tester,
  ) async {
    await _pump(tester, _entry(scored: false));

    expect(find.text('3 paths · 75%'), findsOneWidget);
    expect(find.textContaining('games'), findsNothing);
  });

  testWidgets('scored records remain labelled as games', (tester) async {
    await _pump(tester, _entry(scored: true));

    expect(find.text('3 games · 75%'), findsOneWidget);
  });

  testWidgets('scored rows stay on one line with a bounded result bar', (
    tester,
  ) async {
    for (final width in [220.0, 640.0, 1000.0]) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: width,
                child: OpeningTreeMoveRow(
                  entry: _entry(scored: true),
                  parentGamesPlayed: 4,
                ),
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(
        tester.getSize(find.byType(WinDrawLossBar)).width,
        lessThanOrEqualTo(180),
      );
      expect(
        tester.getSize(find.byType(OpeningTreeMoveRow)).height,
        lessThanOrEqualTo(36),
      );
      expect(
        tester.getCenter(find.text('e4')).dy,
        closeTo(tester.getCenter(find.byType(WinDrawLossBar)).dy, 1),
      );
    }
  });
}
