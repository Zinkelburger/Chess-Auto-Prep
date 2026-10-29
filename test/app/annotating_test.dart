import 'package:chess_auto_prep/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/features/library/library_panel.dart';
import 'package:chess_auto_prep/workspace/reading/comment_field.dart';
import 'package:chess_auto_prep/workspace/reading/move_tree_view.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/storage/study_files.dart';

import '../support/scripted_store.dart';
import '../support/study_fixture.dart';
import '../support/window_fixture.dart';

/// Annotating a game move after move: type a note, click the next move,
/// type its note.
void main() {
  late WindowFixture w;
  setUp(() => w = WindowFixture());
  tearDown(() => w.dispose());

  testWidgets('one click on another move while typing a note goes there and '
      'keeps the note on the move it was typed for', (tester) async {
    await w.pumpShell(tester);
    await tester.tap(
      find
          .descendant(
            of: find.byType(LibraryPanel),
            matching: find.text('Main'),
          )
          .last,
    );
    await tester.pumpAndSettle();
    final nf3 = NodePath.of([0, 0]);
    w.session.cursor.goTo(nf3);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyE);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    final field = find.descendant(
      of: find.byType(CommentField),
      matching: find.byType(TextField),
    );
    // A move with no note yet: once the note is in, the move list has a
    // paragraph it did not have.
    await tester.enterText(field, 'Develops and prepares d4.');
    await tester.pump();

    final cxd4 = find.descendant(
      of: find.byType(MoveTreeView),
      matching: find.textContaining('cxd4', findRichText: true),
    );
    // A real click: the window draws frames between the press and the
    // release.
    final click = await tester.startGesture(
      tester.getCenter(cxd4.first),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(const Duration(milliseconds: 50));
    await click.up();
    await tester.pumpAndSettle();

    expect(w.session.cursor.currentMove?.san, 'cxd4');
    expect(w.session.commentAt(nf3), 'Develops and prepares d4.');
    expect(w.session.commentAt(w.session.cursor.value), isNull);
  });

  testWidgets('in a study, one click on the next move while typing a note '
      'goes there', (tester) async {
    final ref = studyRef('Endgames');
    w.store.documents[ref] = Opened(
      twoChapterStudy,
      scriptedRevision(twoChapterStudy),
    );
    w.studyFiles.listing = StudiesListed([ref]);
    await w.pumpShell(tester);
    await w.requests.openStudy(ref, chapter: 0);
    await tester.pumpAndSettle();
    final e4 = NodePath.of([0]);
    w.session.cursor.goTo(e4);
    await tester.pumpAndSettle();
    // Study opens on Edit: the note field is already there.
    final field = find.descendant(
      of: find.byType(CommentField),
      matching: find.byType(TextField),
    );
    await tester.enterText(field, 'Best by test.');
    await tester.pump();
    final nf3 = find.descendant(
      of: find.byType(MoveTreeView),
      matching: find.textContaining('Nf3', findRichText: true),
    );
    final click = await tester.startGesture(
      tester.getCenter(nf3.first),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(const Duration(milliseconds: 50));
    await click.up();
    await tester.pumpAndSettle();

    expect(w.session.cursor.currentMove?.san, 'Nf3');
    expect(w.session.commentAt(e4), 'Best by test.');
  });
}
