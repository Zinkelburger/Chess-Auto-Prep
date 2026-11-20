// Import chapters: where a pasted PGN goes once previewed, and what the
// preview says about games it could not read whole.

import 'package:chess_auto_prep/features/study/study_panel.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/status_host.dart';
import '../../support/study_fixture.dart';

void main() {
  late StudyFixture study;

  setUp(() async => study = await openStudy(twoChapterStudy));
  tearDown(() => study.dispose());

  Future<void> preview(WidgetTester tester, String pgn) async {
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
    await tester.tap(find.text('Import chapters…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Paste PGN'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'PGN'), pgn);
    await tester.tap(find.text('Preview chapters'));
    await tester.pumpAndSettle();
  }

  FilledButton confirm(WidgetTester tester, String label) =>
      tester.widget<FilledButton>(find.widgetWithText(FilledButton, label));

  testWidgets('a new study takes the name typed for it', (tester) async {
    await preview(tester, '[Event "Added"]\n\n1. c4 e5 *\n');
    await tester.ensureVisible(find.text('New study'));
    await tester.tap(find.text('New study'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Study name (optional)'),
      '  English games  ',
    );
    await tester.tap(find.text('Import study'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    final made = study.store.documents[studyRef('English games')];
    expect(made, isA<Opened>());
    expect((made! as Opened).text, contains('1. c4 e5'));
  });

  testWidgets('games not read whole are said, and go only to a new study', (
    tester,
  ) async {
    await preview(
      tester,
      '[Event "Valid"]\n\n1. e4 *\n\n[Event "Broken"]\n\n1. d4 e9 *\n',
    );
    expect(
      find.text(
        'Some games are incomplete. A new study preserves their original '
        'text.',
      ),
      findsOneWidget,
    );
    expect(confirm(tester, 'Add chapters').onPressed, isNull);
    await tester.ensureVisible(find.text('New study'));
    await tester.tap(find.text('New study'));
    await tester.pumpAndSettle();
    expect(confirm(tester, 'Import study').onPressed, isNotNull);
  });

  testWidgets('a preview whose games are all whole says nothing about it', (
    tester,
  ) async {
    await preview(tester, '[Event "Added"]\n\n1. c4 e5 *\n');
    expect(find.textContaining('incomplete'), findsNothing);
    expect(confirm(tester, 'Add chapters').onPressed, isNotNull);
  });
}
