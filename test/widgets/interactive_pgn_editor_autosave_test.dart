import 'package:chess_auto_prep/models/move_tree.dart';
import 'package:chess_auto_prep/chess_core/moves/tree_path.dart';
import 'package:chess_auto_prep/widgets/interactive_pgn_editor.dart';
import 'package:chess_auto_prep/widgets/pgn/pgn_annotation_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'chapter switch flushes a comment to the captured save destination',
    (tester) async {
      final first = MoveTree.fromMoves(['e4']);
      final second = MoveTree.fromMoves(['d4']);
      final savedFirst = <String>[];
      final savedSecond = <String>[];
      Widget host(MoveTree tree, List<String> saves) => MaterialApp(
        home: Scaffold(
          body: InteractivePgnEditor(
            tree: tree,
            currentPath: TreePath.empty,
            isEditingExistingLine: true,
            onCommentChanged: tree.setComment,
            onAutoSave: saves.add,
          ),
        ),
      );
      await tester.pumpWidget(host(first, savedFirst));
      expect(PgnAnnotationPanel.focusActive(), isTrue);
      await tester.pump();
      await tester.pump();
      final field = find.descendant(
        of: find.byType(PgnAnnotationPanel),
        matching: find.byType(TextField),
      );
      await tester.enterText(field, 'Keep my first comment');
      expect(savedFirst, isEmpty);
      await tester.pumpWidget(host(second, savedSecond));
      expect(savedFirst, hasLength(1));
      expect(savedFirst.single, contains('Keep my first comment'));
      expect(savedFirst.single, contains('e4'));
      expect(savedSecond, isEmpty);
      await tester.pump(const Duration(seconds: 3));
      expect(savedFirst, hasLength(1));
      expect(savedSecond, isEmpty);

      expect(PgnAnnotationPanel.focusActive(), isTrue);
      await tester.pump();
      await tester.pump();
      await tester.enterText(field, 'Keep my second comment');
      await tester.pumpWidget(const SizedBox());
      expect(savedSecond, hasLength(1));
      expect(savedSecond.single, contains('Keep my second comment'));
    },
  );
}
