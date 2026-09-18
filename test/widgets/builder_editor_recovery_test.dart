import 'package:chess_auto_prep/l10n/generated/app_localizations.dart';
import '../support/repertoire_dependencies.dart';
import 'package:chess_auto_prep/widgets/interactive_pgn_editor.dart';
import 'package:chess_auto_prep/widgets/pgn/pgn_annotation_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'owner captures annotation and title before rebuild and retains outgoing scratch',
    (tester) async {
      final owner = testBuilderWorkspace();
      addTearDown(owner.dispose);
      owner.composeMoves(['e4']);
      Widget host() => MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,

        home: Scaffold(
          body: InteractivePgnEditor(
            tree: owner.board.tree,
            currentPath: owner.board.path,
            lineTitle: owner.title,
            onTitleChanged: owner.setTitle,
            onCommentChanged: owner.board.setCommentAtPath,
            onToggleNag: owner.board.toggleNagAtPath,
          ),
        ),
      );
      await tester.pumpWidget(host());
      final before = owner.board.tree;
      expect(PgnAnnotationPanel.focusActive(), isTrue);
      await tester.pump();
      await tester.pump();
      final comment = find.descendant(
        of: find.byType(PgnAnnotationPanel),
        matching: find.byType(TextField),
      );
      await tester.enterText(comment, 'First comment');
      expect(before.commentAt(owner.board.path), isNull);
      // No persistence timer or widget flush: the owner already has the edit.
      expect(
        owner.captureWorkspace().drafts.single.content,
        contains('First comment'),
      );
      final title = find.byWidgetPredicate(
        (widget) =>
            widget is TextField && widget.decoration?.hintText == 'Line title',
      );
      await tester.enterText(title, 'First scratch');
      expect(owner.captureWorkspace().drafts.single.title, 'First scratch');
      owner.composeMoves(['d4']);
      await tester.pumpWidget(host());
      expect(PgnAnnotationPanel.focusActive(), isTrue);
      await tester.pump();
      await tester.pump();
      await tester.enterText(comment, 'Second comment');
      tester
          .widget<PgnAnnotationPanel>(find.byType(PgnAnnotationPanel))
          .onToggleNag(1);
      await tester.pumpWidget(const SizedBox.shrink());
      final drafts = owner.captureWorkspace().drafts;
      expect(drafts, hasLength(2));
      expect(drafts.first.content, contains('e4 {First comment}'));
      expect(drafts.last.content, contains(r'd4 $1 {Second comment}'));
    },
  );
}
