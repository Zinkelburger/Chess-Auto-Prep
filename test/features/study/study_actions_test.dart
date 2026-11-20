// The study panel's whole-study commands from its header menu and toolbar:
// each asks its question, and what was confirmed happens while what was
// cancelled does not.

import 'package:chess_auto_prep/features/study/study_panel.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/storage/pgn_export.dart';
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/status_host.dart';
import '../../support/study_fixture.dart';

void main() {
  late StudyFixture study;
  late int foldersAsked;

  setUp(() async {
    foldersAsked = 0;
    study = await openStudy(
      twoChapterStudy,
      exporter: PgnExport(
        pickDirectory: () async {
          foldersAsked++;
          return null;
        },
      ),
    );
  });

  tearDown(() => study.dispose());

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Scaffold(
          body: StatusHost(
            child: StudyPanel(
              studies: study.studies,
              session: study.session,
              onOpen: (_, _) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> studyAction(WidgetTester tester, String label) async {
    await tester.tap(find.byTooltip('Study actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
  }

  Future<void> answerName(WidgetTester tester, String name, String confirm) async {
    await tester.enterText(find.byType(TextField).last, name);
    await tester.tap(find.widgetWithText(FilledButton, confirm));
    await tester.pumpAndSettle();
  }

  testWidgets('New study makes the named study', (tester) async {
    await pump(tester);
    await studyAction(tester, 'New study…');
    await answerName(tester, 'Openings', 'Create');
    expect(study.store.documents.containsKey(studyRef('Openings')), isTrue);
  });

  testWidgets('Rename study renames the open study', (tester) async {
    await pump(tester);
    await studyAction(tester, 'Rename study…');
    await answerName(tester, 'Rook and pawn', 'Rename');
    expect(study.store.documents.containsKey(studyRef('Rook and pawn')), isTrue);
    expect(study.store.documents.containsKey(study.ref), isFalse);
    expect(study.session.source, studyRef('Rook and pawn'));
  });

  testWidgets('Export study PGN asks for a folder once the name is given', (
    tester,
  ) async {
    await pump(tester);
    await studyAction(tester, 'Export study PGN…');
    await answerName(tester, 'Endgames copy', 'Choose folder');
    expect(foldersAsked, 1);
    expect(find.text('The open study changed. Export it again.'), findsNothing);
  });

  testWidgets('Delete study moves the file away once confirmed', (
    tester,
  ) async {
    await pump(tester);
    await studyAction(tester, 'Delete study…');
    expect(find.text('Delete study “Endgames”?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(study.store.documents.containsKey(study.ref), isFalse);
    expect(study.session.source, isNull);
  });

  testWidgets('a cancelled Delete study keeps the study', (tester) async {
    await pump(tester);
    await studyAction(tester, 'Delete study…');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(study.store.documents[study.ref], isA<Opened>());
    expect(study.session.source, study.ref);
  });

  testWidgets('New chapter adds the named chapter at the end', (tester) async {
    await pump(tester);
    await tester.tap(find.text('New chapter…'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Chapter name'),
      'Queen endings',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();
    await study.saver.flush();
    expect(study.session.chapter!.lines, hasLength(3));
    expect(study.onDisk, contains('[ChapterName "Queen endings"]'));
  });
}
