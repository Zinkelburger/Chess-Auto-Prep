/// Overflow probes for panels that render inside the wide-layout Lines side
/// panel, which the user can drag down to 220px wide. Any RenderFlex
/// overflow during layout fails the test.
library;

import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chess_auto_prep/constants/chess_constants.dart';
import 'package:chess_auto_prep/models/opening_tree.dart';
import 'package:chess_auto_prep/models/repertoire_line.dart';
import 'package:chess_auto_prep/widgets/opening_tree_widget.dart';
import 'package:chess_auto_prep/widgets/repertoire_lines_browser.dart';

/// The minimum width the Lines side panel can be dragged to
/// (RepertoireScreen._kLinesPanelMinWidth).
const double kNarrowPanelWidth = 220;

Widget _host(Widget child, {double width = kNarrowPanelWidth, double height = 400}) {
  return MaterialApp(
    home: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(width: width, height: height, child: child),
      ),
    ),
  );
}

OpeningTree _sampleTree() {
  final tree = OpeningTree();
  // Deep line so the header's move-path text is long.
  tree.appendLineFromFen(kStandardStartFen, [
    'e4', 'c5', 'Nf3', 'd6', 'd4', 'cxd4', 'Nxd4', 'Nf6', 'Nc3', 'a6',
  ]);
  tree.appendLineFromFen(kStandardStartFen, ['e4', 'e5', 'Nf3', 'Nc6']);
  tree.appendLineFromFen(kStandardStartFen, ['d4', 'd5', 'c4', 'e6']);
  // Give nodes some stats so the rows render real numbers.
  void stamp(OpeningTreeNode node) {
    node.gamesPlayed = 1234;
    node.wins = 600;
    node.draws = 234;
    node.losses = 400;
    node.children.values.forEach(stamp);
  }

  stamp(tree.root);
  return tree;
}

List<RepertoireLine> _sampleLines() {
  return [
    RepertoireLine(
      id: 'line-1',
      name: 'Sicilian Najdorf — English Attack, long descriptive name',
      moves: const ['e4', 'c5', 'Nf3', 'd6', 'd4', 'cxd4', 'Nxd4', 'Nf6'],
      color: 'white',
      startPosition: Chess.initial,
      fullPgn: '[Event "Sicilian Najdorf — English Attack"]\n\n1. e4 c5 *',
    ),
    RepertoireLine(
      id: 'line-2',
      name: 'Queens Gambit Declined',
      moves: const ['d4', 'd5', 'c4', 'e6'],
      color: 'white',
      startPosition: Chess.initial,
      fullPgn: '[Event "QGD"]\n\n1. d4 d5 *',
    ),
  ];
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('OpeningTreeWidget fits the narrow side panel', (tester) async {
    final tree = _sampleTree();
    await tester.pumpWidget(_host(
      OpeningTreeWidget(
        tree: tree,
        repertoireLines: _sampleLines(),
        currentMoveSequence: const [],
      ),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('OpeningTreeWidget deep position with long move path',
      (tester) async {
    final tree = _sampleTree();
    for (final move in ['e4', 'c5', 'Nf3', 'd6', 'd4', 'cxd4', 'Nxd4']) {
      tree.makeMove(move);
    }
    await tester.pumpWidget(_host(
      OpeningTreeWidget(
        tree: tree,
        repertoireLines: _sampleLines(),
        currentMoveSequence: const [],
        showPgnSearch: true,
      ),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('OpeningTreeWidget out-of-book warning at narrow width',
      (tester) async {
    final tree = _sampleTree();
    await tester.pumpWidget(_host(
      OpeningTreeWidget(
        tree: tree,
        repertoireLines: _sampleLines(),
        currentMoveSequence: const ['e4', 'c5', 'Nf3', 'd6', 'd4', 'g6'],
      ),
      height: 250,
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('RepertoireLinesBrowser fits the narrow side panel',
      (tester) async {
    await tester.pumpWidget(_host(
      RepertoireLinesBrowser(
        lines: _sampleLines(),
        isExpanded: true,
      ),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('RepertoireLinesBrowser at a short height', (tester) async {
    await tester.pumpWidget(_host(
      RepertoireLinesBrowser(
        lines: _sampleLines(),
        isExpanded: true,
      ),
      height: 220,
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
