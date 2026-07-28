import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chess_auto_prep/features/repertoire/widgets/repertoire_tree_pane.dart';
import 'package:chess_auto_prep/models/opening_tree.dart';

const _startFen = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';

Widget _pane({OpeningTree? tree, double height = 800}) => MaterialApp(
  home: Scaffold(
    body: SizedBox(
      height: height,
      child: RepertoireTreePane(
        tree: tree,
        repertoireLines: const [],
        currentMoveSequence: const [],
        fen: _startFen,
        onMoveSelected: (_) {},
        onGoBack: () {},
        onGoForward: () {},
        repertoireMovesAtPosition: () => const {'e4'},
        onPlayMove: (_) {},
        onAddMove: (_) {},
      ),
    ),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('tree area', () {
    testWidgets('prompts to load a repertoire when there is no tree', (
      tester,
    ) async {
      await tester.pumpWidget(_pane());
      await tester.pump();

      expect(find.textContaining('No opening tree available'), findsOneWidget);
      expect(find.text('Repertoire tree'), findsOneWidget);
    });
  });

  group('explorer toggle', () {
    testWidgets('is off until asked for, then splits the pane', (tester) async {
      await tester.pumpWidget(_pane(tree: OpeningTree()..appendLine(['e4'])));
      await tester.pump();

      final show = find.byTooltip('Show Lichess opening explorer');
      expect(show, findsOneWidget);

      await tester.tap(show);
      await tester.pump();

      expect(find.byTooltip('Hide opening explorer'), findsOneWidget);

      // And back off again.
      await tester.tap(find.byTooltip('Hide opening explorer'));
      await tester.pump();
      expect(find.byTooltip('Show Lichess opening explorer'), findsOneWidget);
    });
  });

  group('treeHeightFor', () {
    test('splits by ratio when both halves fit', () {
      expect(RepertoireTreePane.treeHeightFor(1000, 0.6), 600);
    });

    test('keeps each half usable at the extremes of the ratio', () {
      expect(
        RepertoireTreePane.treeHeightFor(400, 0.05),
        RepertoireTreePane.minTreeHeight,
      );
      expect(
        RepertoireTreePane.treeHeightFor(400, 0.99),
        400 - RepertoireTreePane.minExplorerHeight,
      );
    });

    test('does not invert its bounds when the pane is tiny', () {
      // Below 220px the two minimums cross, and clamping one against the
      // other throws — which is exactly what the inline version in the screen
      // did. The result just has to be finite and inside the pane.
      for (final available in [0.0, 50.0, 150.0, 219.0]) {
        final height = RepertoireTreePane.treeHeightFor(available, 0.6);
        expect(height, greaterThanOrEqualTo(0));
        expect(height, lessThanOrEqualTo(available));
      }
    });
  });
}
