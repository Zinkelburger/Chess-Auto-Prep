import 'package:chess_auto_prep/app/mode.dart';
import 'package:chess_auto_prep/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/features/study/study_commands.dart';
import 'package:chess_auto_prep/storage/chapter_files.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/storage/study_files.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/scripted_store.dart';
import '../support/study_fixture.dart';
import '../support/viewer_fixture.dart';
import '../support/window_fixture.dart';

/// The PGN Viewer and Study share one card, with `Read | Edit` at its foot:
/// reading holds what is done on the board off the file, editing writes
/// every change, and each mode keeps its own side of the switch.
void main() {
  String onDisk(WindowFixture w, ChapterRef ref) =>
      switch (w.store.documents[ref]) {
        Opened(:final text) => text,
        _ => '',
      };

  bool editing(WidgetTester tester) => tester
      .widget<SegmentedButton<bool>>(find.byType(SegmentedButton<bool>))
      .selected
      .single;

  Future<(WindowFixture, ChapterRef)> openStudy(WidgetTester tester) async {
    final w = WindowFixture();
    addTearDown(w.dispose);
    final ref = studyRef('Endgames');
    w.store.documents[ref] = Opened(
      twoChapterStudy,
      scriptedRevision(twoChapterStudy),
    );
    w.studyFiles.listing = StudiesListed([ref]);
    await w.pumpShell(tester);
    await w.requests.openStudy(ref, chapter: 0);
    await tester.pumpAndSettle();
    return (w, ref);
  }

  testWidgets('the viewer reads: a move is held until Edit, which writes '
      'it, and then every move is written as it is played', (tester) async {
    final w = WindowFixture();
    addTearDown(w.dispose);
    final ref = collectionRef('book');
    w.store.documents[ref] = Opened(
      threeGameFile,
      scriptedRevision(threeGameFile),
    );
    await w.pumpShell(tester);
    w.requests.switchTo(Mode.pgnViewer);
    await w.requests.openFile(ref);
    await tester.pumpAndSettle();
    expect(editing(tester), isFalse);

    w.session.cursor.goTo(NodePath.of([0]));
    w.session.playMove('c7c5');
    await tester.pumpAndSettle();
    expect(w.session.hasHeldEdits, isTrue);
    expect(find.text('Unsaved changes'), findsOneWidget);
    expect(onDisk(w, ref), threeGameFile);

    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    expect(w.session.hasHeldEdits, isFalse);
    expect(onDisk(w, ref), contains('c5'));
    expect(find.text('Saved'), findsOneWidget);

    w.session.playMove('g1f3');
    await tester.pumpAndSettle();
    expect(w.session.hasHeldEdits, isFalse);
    expect(onDisk(w, ref), contains('Nf3'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Study opens on Edit, and each mode keeps the side it was '
      'left on', (tester) async {
    final (w, ref) = await openStudy(tester);
    expect(editing(tester), isTrue);
    w.session.cursor.goTo(NodePath.of([0, 0, 0]));
    w.session.playMove('b8c6');
    await tester.pumpAndSettle();
    expect(onDisk(w, ref), contains('Nc6'));

    await tester.tap(find.text('Read'));
    await tester.pumpAndSettle();
    w.requests.switchTo(Mode.pgnViewer);
    await tester.pumpAndSettle();
    expect(editing(tester), isFalse);
    w.requests.switchTo(Mode.study);
    await tester.pumpAndSettle();
    expect(editing(tester), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reading a study, a chapter renamed is written at once with '
      'the moves held so far', (tester) async {
    final (w, ref) = await openStudy(tester);
    await tester.tap(find.text('Read'));
    await tester.pumpAndSettle();
    w.session.cursor.goTo(NodePath.of([0, 0, 0]));
    w.session.playMove('b8c6');
    await tester.pumpAndSettle();
    expect(w.session.hasHeldEdits, isTrue);
    expect(onDisk(w, ref), twoChapterStudy);

    renameStudyChapter(w.session, index: 0, name: 'Rooks');
    await tester.pumpAndSettle();
    expect(w.session.hasHeldEdits, isFalse);
    expect(onDisk(w, ref), contains('[ChapterName "Rooks"]'));
    expect(onDisk(w, ref), contains('Nc6'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Read in PGN Viewer and Open in Study go between the modes on '
      'the same chapter', (tester) async {
    final (w, ref) = await openStudy(tester);
    w.session.showGame(1);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Read in PGN Viewer'));
    await tester.pumpAndSettle();
    expect(w.requests.mode, Mode.pgnViewer);
    expect(w.session.source?.path, ref.path);
    expect(w.session.game, 1);

    await tester.tap(find.text('Actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open in Study'));
    await tester.pumpAndSettle();
    expect(w.requests.mode, Mode.study);
    expect(w.session.game, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a study chapter opens on its moves alone, and the review '
      'opens under them, not in their place', (tester) async {
    await openStudy(tester);
    Finder pane(int index) => find.byKey(ValueKey('action-pane-$index'));
    expect(pane(1), findsNothing);
    expect(find.byKey(const ValueKey('tab-row-0')), findsNothing);
    await tester.tap(find.byTooltip('Open tools and arrange panes'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(MenuItemButton, 'Game review'));
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: pane(0), matching: find.text('Moves')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: pane(1), matching: find.text('Game review')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: pane(1),
        matching: find.text('Analyze all 2 chapters'),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}
