// The Study panel's menus: a chapter's clears each ask their own question
// and a No changes nothing; a study keeps its last chapter, and says so;
// a chapter that is not "Chapter N" keeps its name when its players are
// tagged; and the study menu offers nothing for a study not open.
import 'package:chess_auto_prep/features/study/study_panel.dart';
import 'package:chess_auto_prep/storage/chapter_files.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/scripted_store.dart';
import '../../support/status_host.dart';
import '../../support/study_fixture.dart';

const _oneChapter = '''
[Event "Endgames: Rook endings"]
[Result "*"]
[StudyName "Endgames"]
[ChapterName "Rook endings"]

1. e4 {A plan} e5 (1... c5) 2. Nf3 *
''';

void main() {
  late StudyFixture study;
  tearDown(() => study.dispose());

  Future<void> show(WidgetTester tester, String text) async {
    study = await openStudy(text);
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Scaffold(
          body: StatusHost(
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 300,
                child: StudyPanel(
                  studies: study.studies,
                  session: study.session,
                  onOpen: (_, _) {},
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> chapterAction(WidgetTester tester, String label) async {
    await tester.tap(find.byTooltip('Chapter actions').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
  }

  testWidgets('each clear asks its own question, and No clears nothing', (
    tester,
  ) async {
    await show(tester, _oneChapter);
    await chapterAction(tester, 'Clear comments, glyphs and shapes…');
    expect(find.text('Clear annotations?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await chapterAction(tester, 'Clear variations…');
    expect(find.text('Clear variations?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await study.saver.flush();
    expect(study.onDisk, contains('{A plan}'));
    expect(study.onDisk, contains('(1... c5)'));
  });

  testWidgets('a clear confirmed clears', (tester) async {
    await show(tester, _oneChapter);
    await chapterAction(tester, 'Clear comments, glyphs and shapes…');
    await tester.tap(find.text('Clear'));
    await tester.pumpAndSettle();
    await study.saver.flush();
    expect(study.onDisk, isNot(contains('{A plan}')));
  });

  testWidgets('the list of studies gives way to a study opened elsewhere', (
    tester,
  ) async {
    await show(tester, twoChapterStudy);
    await tester.tap(find.byTooltip('Back to studies'));
    await tester.pumpAndSettle();
    expect(find.text('Rook endings'), findsNothing);
    final other = studyRef('Openings');
    const text =
        '[Event "Openings: Italian"]\n[StudyName "Openings"]\n'
        '[ChapterName "Italian"]\n\n1. e4 e5 *\n';
    study.store.documents[other] = Opened(text, scriptedRevision(text));
    await study.session.open(other, game: 0);
    await tester.pumpAndSettle();
    expect(find.text('Italian'), findsOneWidget);
  });

  testWidgets('a study keeps its last chapter, and says so', (tester) async {
    await show(tester, _oneChapter);
    await chapterAction(tester, 'Delete chapter…');
    expect(find.text('A study needs at least one chapter.'), findsOneWidget);
  });

  testWidgets('of two chapters, one can go; No keeps it', (tester) async {
    await show(tester, twoChapterStudy);
    await chapterAction(tester, 'Delete chapter…');
    expect(find.text('Delete chapter “Rook endings”?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(study.session.chapter!.lines, hasLength(2));
  });

  testWidgets('a named chapter keeps its name when its players are tagged', (
    tester,
  ) async {
    await show(tester, twoChapterStudy);
    await chapterAction(tester, 'PGN tags…');
    await tester.enterText(
      find.widgetWithText(TextField, 'Value').at(0),
      'Ann',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Value').at(1),
      'Bob',
    );
    await tester.tap(find.text('Save tags'));
    await tester.pumpAndSettle();
    expect(find.text('Rook endings'), findsOneWidget);
  });

  testWidgets('the study menu offers nothing for a study not open', (
    tester,
  ) async {
    await show(tester, twoChapterStudy);
    // A file of the collections on the board: no study is open.
    final other = ChapterRef.at('/collections/games.pgn');
    study.store.documents[other] = Opened(
      '[Event "Club"]\n\n1. c4 *\n',
      scriptedRevision('[Event "Club"]\n\n1. c4 *\n'),
    );
    await study.session.open(other, game: 0);
    await tester.pumpAndSettle();
    expect(study.studies.open, isNull);
    await tester.tap(find.byTooltip('Study actions'));
    await tester.pumpAndSettle();
    for (final label in [
      'Rename study…',
      'Export study PGN…',
      'Copy study PGN',
      'Delete study…',
    ]) {
      expect(
        tester
            .widget<MenuItemButton>(find.widgetWithText(MenuItemButton, label))
            .onPressed,
        isNull,
        reason: label,
      );
    }
  });
}
