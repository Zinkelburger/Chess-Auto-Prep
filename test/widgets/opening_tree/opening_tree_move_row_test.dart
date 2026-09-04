import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/models/opening_tree.dart';
import 'package:chess_auto_prep/widgets/opening_tree/opening_tree_move_row.dart';

PositionGroup _entry({required bool scored}) {
  final node = OpeningTreeNode(
    move: 'e4',
    fen: Chess.initial.play(Chess.initial.parseSan('e4')!).fen,
  );
  for (var i = 0; i < 3; i++) {
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
  testWidgets('unscored course paths are labelled as lines', (tester) async {
    await _pump(tester, _entry(scored: false));

    expect(find.text('3 lines · 75%'), findsOneWidget);
    expect(find.textContaining('games'), findsNothing);
  });

  testWidgets('scored records remain labelled as games', (tester) async {
    await _pump(tester, _entry(scored: true));

    expect(find.text('3 games · 75%'), findsOneWidget);
  });
}
