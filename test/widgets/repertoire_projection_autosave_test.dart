import 'package:chess_auto_prep/core/repertoire_controller.dart';
import 'package:chess_auto_prep/widgets/interactive_pgn_editor.dart';
import 'package:chess_auto_prep/widgets/pgn/pgn_annotation_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'immutable edits save latest revision before rebuild or chapter switch',
    (tester) async {
      final owner = RepertoireController()..loadMoveHistory(['e4']);
      addTearDown(owner.dispose);
      final firstSaves = <String>[];
      final secondSaves = <String>[];
      Widget host(List<String> saves) {
        final displayed = owner.tree;
        return MaterialApp(
          home: Scaffold(
            body: InteractivePgnEditor(
              tree: displayed,
              snapshotForSave: () {
                final current = owner.tree;
                return identical(current.identity, displayed.identity)
                    ? current
                    : displayed;
              },
              currentPath: owner.path,
              isEditingExistingLine: true,
              onCommentChanged: owner.setCommentAtPath,
              onToggleNag: owner.toggleNagAtPath,
              onAutoSave: saves.add,
            ),
          ),
        );
      }

      await tester.pumpWidget(host(firstSaves));
      final before = owner.tree;
      expect(PgnAnnotationPanel.focusActive(), isTrue);
      await tester.pump();
      await tester.pump();
      final field = find.descendant(
        of: find.byType(PgnAnnotationPanel),
        matching: find.byType(TextField),
      );
      await tester.enterText(field, 'First comment');
      // No host rebuild: its projection still holds the pre-edit values.
      expect(before.commentAt(owner.path), isNull);
      owner.loadMoveHistory(['d4']);
      await tester.pumpWidget(host(secondSaves));
      expect(firstSaves, hasLength(1));
      expect(firstSaves.single, contains('e4 {First comment}'));
      expect(firstSaves.single, isNot(contains('d4')));
      expect(secondSaves, isEmpty);
      expect(PgnAnnotationPanel.focusActive(), isTrue);
      await tester.pump();
      await tester.pump();
      await tester.enterText(field, 'Second comment');
      // Glyph callback also captures the already-committed annotation, even
      // before the host supplies its next immutable projection.
      tester
          .widget<PgnAnnotationPanel>(find.byType(PgnAnnotationPanel))
          .onToggleNag(1);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(secondSaves, hasLength(1));
      expect(secondSaves.single, contains('d4 \$1 {Second comment}'));
      await tester.pump(const Duration(seconds: 3));
      expect(firstSaves, hasLength(1));
      expect(secondSaves, hasLength(1));
    },
  );
}
