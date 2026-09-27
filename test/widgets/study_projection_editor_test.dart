import 'package:chess_auto_prep/l10n/generated/app_localizations.dart';
import 'package:chess_auto_prep/chess_core/moves/tree_path.dart';
import 'package:chess_auto_prep/widgets/interactive_pgn_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:chess_auto_prep/widgets/pgn/movetext_primitives.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/study_fixture.dart';

void main() {
  testWidgets('a stale move menu cannot act on a reordered sibling', (
    tester,
  ) async {
    final study = memoryStudy();
    addTearDown(study.dispose);
    study.playSan('e4');
    study.goToStart();
    study.playSan('d4');
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,

        home: Scaffold(
          body: AnimatedBuilder(
            animation: study,
            builder: (_, _) => InteractivePgnEditor(
              tree: study.tree,
              currentPath: study.path,
              onCommentChanged: study.setComment,
            ),
          ),
        ),
      ),
    );
    await tester.tap(
      find.byWidgetPredicate(
        (widget) => widget is MoveChip && widget.san == 'd4',
      ),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    study.promote(const TreePath([1]));
    await tester.pump();
    await tester.tap(find.text('Start Quiz From This Move'));
    await tester.pumpAndSettle();
    expect(study.doc.toPgn(), isNot(contains('%tstart')));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'immutable revisions preserve annotation focus and chapter targets',
    (tester) async {
      final study = memoryStudy();
      addTearDown(study.dispose);
      study.playSan('e4');
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,

          home: Scaffold(
            body: AnimatedBuilder(
              animation: study,
              builder: (_, _) => InteractivePgnEditor(
                tree: study.tree,
                currentPath: study.path,
                showAnnotationPanel: true,
                onJump: study.jump,
                onCommentChanged: study.setComment,
                onToggleNag: study.toggleNag,
              ),
            ),
          ),
        ),
      );
      final field = find.byType(TextField);
      await tester.tap(field);
      await tester.enterText(field, 'First');
      await tester.pump();
      final initialEditor = tester.state(find.byType(EditableText));
      final old = study.chapter;
      await tester.enterText(field, 'First chapter annotation');
      await tester.pump();
      expect(tester.state(find.byType(EditableText)), same(initialEditor));
      expect(
        tester
            .widget<EditableText>(find.byType(EditableText))
            .focusNode
            .hasFocus,
        isTrue,
      );
      expect(study.cursorComment, 'First chapter annotation');
      expect(old.tree.commentAt(const TreePath([0])), 'First');
      study.toggleNag(study.path, 1);
      await tester.pump();
      expect(tester.state(find.byType(EditableText)), same(initialEditor));
      study.addChapter('Second');
      await tester.pump();
      await tester.enterText(field, 'Second chapter introduction');
      await tester.pump();
      expect(study.cursorComment, 'Second chapter introduction');
      study.selectChapter(0);
      study.goForward();
      await tester.pump();
      expect(study.cursorComment, 'First chapter annotation');
      expect(
        tester.widget<TextField>(field).controller!.text,
        'First chapter annotation',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
