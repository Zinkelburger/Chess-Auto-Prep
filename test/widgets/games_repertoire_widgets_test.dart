import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/models/opening_tree.dart';
import 'package:chess_auto_prep/services/games_repertoire/draft_merge_planner.dart';
import 'package:chess_auto_prep/services/games_repertoire/games_draft.dart';
import 'package:chess_auto_prep/widgets/games_repertoire/draft_tree_view.dart';
import 'package:chess_auto_prep/widgets/games_repertoire/merge_conflict_sheet.dart';

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  group('DraftTreeView', () {
    testWidgets('renders rows and prunes a subtree on discard', (tester) async {
      final tree = OpeningTree()
        ..appendLine(['e4', 'e5'])
        ..appendLine(['d4', 'd5']);
      final draft = GamesDraft(tree: tree, isWhite: true);
      var changes = 0;

      await tester.pumpWidget(
        _wrap(
          DraftTreeView(draft: draft, minGames: 1, onChanged: () => changes++),
        ),
      );

      // All four moves are visible.
      expect(find.text('1. e4'), findsOneWidget);
      expect(find.text('1… e5'), findsOneWidget);
      expect(find.text('1. d4'), findsOneWidget);
      expect(find.text('1… d5'), findsOneWidget);

      // Discard the d4 line: find the delete button inside the d4 row.
      final d4Row = find.ancestor(
        of: find.text('1. d4'),
        matching: find.byType(InkWell),
      );
      final discard = find.descendant(
        of: d4Row,
        matching: find.byTooltip('Discard this line and everything after it'),
      );
      await tester.tap(discard);
      await tester.pumpAndSettle();

      // d4 and its child are gone; the e4 line survives.
      expect(find.text('1. d4'), findsNothing);
      expect(find.text('1… d5'), findsNothing);
      expect(find.text('1. e4'), findsOneWidget);
      expect(changes, 1);
    });

    testWidgets('starts deep lines collapsed and expands on row tap', (
      tester,
    ) async {
      final tree = OpeningTree()..appendLine(['e4', 'e5', 'Nf3']);
      final draft = GamesDraft(tree: tree, isWhite: true);

      await tester.pumpWidget(
        _wrap(DraftTreeView(draft: draft, minGames: 1, onChanged: () {})),
      );

      // e5 is at depth 1, so it starts collapsed: Nf3 is hidden and the row
      // shows the "collapsed" chevron.
      expect(find.text('2. Nf3'), findsNothing);
      final e5Row = find.ancestor(
        of: find.text('1… e5'),
        matching: find.byType(InkWell),
      );
      expect(
        find.descendant(of: e5Row, matching: find.byIcon(Icons.chevron_right)),
        findsOneWidget,
      );

      // Tapping anywhere on the row (not just the icon) expands it.
      await tester.tap(find.text('1… e5'));
      await tester.pumpAndSettle();
      expect(find.text('2. Nf3'), findsOneWidget);

      // Tapping again collapses it back.
      await tester.tap(find.text('1… e5'));
      await tester.pumpAndSettle();
      expect(find.text('2. Nf3'), findsNothing);
    });
  });

  group('MergeConflictSheet', () {
    const conflict = DraftConflict(
      prefixSans: ['e4', 'e5'],
      draftSan: 'Bc4',
      repertoireSans: ['Nf3'],
    );

    // Opens the sheet via a launcher button and exposes the popped value.
    Future<Future<Set<int>?>> pumpSheet(WidgetTester tester) async {
      final completer = Completer<Set<int>?>();
      await tester.pumpWidget(
        _wrap(
          Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                completer.complete(
                  await showModalBottomSheet<Set<int>>(
                    context: context,
                    builder: (_) =>
                        const MergeConflictSheet(conflicts: [conflict]),
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return completer.future;
    }

    testWidgets('defaults to keeping prep; picking mine flips the choice', (
      tester,
    ) async {
      final result = await pumpSheet(tester);

      // Both candidate moves are offered with the position shown.
      expect(find.text('1.e4 e5'), findsOneWidget);
      expect(find.widgetWithText(ActionChip, 'Nf3'), findsOneWidget);
      expect(find.widgetWithText(ActionChip, 'Bc4'), findsOneWidget);
      // Default: prep is kept, the draft branch is skipped.
      expect(find.textContaining('Keeping your prep'), findsOneWidget);

      // Pick my games' move, then continue.
      await tester.tap(find.widgetWithText(ActionChip, 'Bc4'));
      await tester.pumpAndSettle();
      expect(find.textContaining('added as an extra line'), findsOneWidget);

      await tester.tap(find.text('Continue merge'));
      await tester.pumpAndSettle();
      expect(await result, {0});
    });

    testWidgets('cancel pops null so the caller aborts the merge', (
      tester,
    ) async {
      final result = await pumpSheet(tester);

      await tester.tap(find.text('Cancel merge'));
      await tester.pumpAndSettle();
      expect(await result, isNull);
    });
  });
}
