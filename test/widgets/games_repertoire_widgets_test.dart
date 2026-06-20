import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/core/repertoire_controller.dart';
import 'package:chess_auto_prep/models/move_tree.dart';
import 'package:chess_auto_prep/models/opening_tree.dart';
import 'package:chess_auto_prep/services/games_repertoire/games_draft.dart';
import 'package:chess_auto_prep/services/games_repertoire/repertoire_merge.dart';
import 'package:chess_auto_prep/widgets/games_repertoire/draft_tree_view.dart';
import 'package:chess_auto_prep/widgets/games_repertoire/merge_conflict_sheet.dart';

Widget _wrap(Widget child) =>
    MaterialApp(home: Scaffold(body: child));

void main() {
  group('DraftTreeView', () {
    testWidgets('renders rows and prunes a subtree on discard', (tester) async {
      final tree = OpeningTree()
        ..appendLine(['e4', 'e5'])
        ..appendLine(['d4', 'd5']);
      final draft = GamesDraft(tree: tree, isWhite: true);
      var changes = 0;

      await tester.pumpWidget(_wrap(DraftTreeView(
        draft: draft,
        minGames: 1,
        onChanged: () => changes++,
      )));

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

    testWidgets('starts deep lines collapsed and expands on row tap',
        (tester) async {
      final tree = OpeningTree()..appendLine(['e4', 'e5', 'Nf3']);
      final draft = GamesDraft(tree: tree, isWhite: true);

      await tester.pumpWidget(_wrap(DraftTreeView(
        draft: draft,
        minGames: 1,
        onChanged: () {},
      )));

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
    testWidgets('shows candidates and resolves by promoting to mainline',
        (tester) async {
      final controller = RepertoireController();
      controller.loadMoveSequence(['e4', 'e5', 'Nf3']);
      // Merge a draft where I played Bc4 instead of Nf3 → one conflict.
      final result = controller.mergeDraft(
        MoveTree.fromMoves(['e4', 'e5', 'Bc4']),
        isWhite: true,
      );
      expect(result.hasConflicts, isTrue);

      await tester.pumpWidget(_wrap(MergeConflictSheet(
        controller: controller,
        conflicts: result.conflicts,
      )));
      await tester.pumpAndSettle();

      // Both candidate moves are offered.
      expect(find.widgetWithText(ActionChip, 'Nf3'), findsOneWidget);
      expect(find.widgetWithText(ActionChip, 'Bc4'), findsOneWidget);

      // Before resolving, Nf3 is the mainline (index 0).
      final before = controller.tree.nodeAt(const TreePath([0, 0]))!;
      expect(before.children.first.san, 'Nf3');

      // Pick Bc4 as my main line.
      await tester.tap(find.widgetWithText(ActionChip, 'Bc4'));
      await tester.pumpAndSettle();

      final after = controller.tree.nodeAt(const TreePath([0, 0]))!;
      expect(after.children.first.san, 'Bc4');
      // The resolved conflict is marked done.
      expect(find.byIcon(Icons.check_circle), findsOneWidget);
    });
  });
}
