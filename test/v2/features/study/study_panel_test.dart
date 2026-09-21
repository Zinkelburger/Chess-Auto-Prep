import 'package:chess_auto_prep/v2/features/study/study_panel.dart';
import 'package:chess_auto_prep/v2/storage/chapter_files.dart';
import 'package:chess_auto_prep/v2/storage/study_files.dart';
import 'package:chess_auto_prep/v2/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/study_fixture.dart';

void main() {
  late StudyFixture study;
  late List<(ChapterRef, int)> opened;

  setUp(() async {
    study = await openStudy(twoChapterStudy);
    opened = [];
  });

  tearDown(() => study.dispose());

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Scaffold(
          body: SizedBox(
            width: studyPanelWidth,
            child: StudyPanel(
              studies: study.studies,
              session: study.session,
              onOpen: (ref, chapter) => opened.add((ref, chapter)),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('lists the studies and the chapters of the open one', (
    tester,
  ) async {
    await pump(tester);
    expect(find.text('Endgames'), findsOneWidget);
    expect(find.text('Rook endings'), findsOneWidget);
    expect(find.text('Pawn endings'), findsOneWidget);
    // The ordinals say which game of the file each chapter is.
    expect(find.text('1'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
  });

  testWidgets('clicking a chapter asks the host to open that game', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.text('Pawn endings'));
    await tester.pump();
    expect(opened, [(study.ref, 1)]);
  });

  testWidgets('searching narrows the list and says when nothing matches', (
    tester,
  ) async {
    await pump(tester);
    await tester.enterText(find.byType(TextField), 'openings');
    await tester.pumpAndSettle();
    expect(find.textContaining('Nothing matches'), findsOneWidget);
  });

  testWidgets('a folder that could not be read offers to try again', (
    tester,
  ) async {
    study.files.listing = const StudiesUnreadable('permission denied');
    await study.studies.refresh();
    await pump(tester);
    expect(find.textContaining('Could not read'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('the row menu renames a chapter', (tester) async {
    await pump(tester);
    await tester.tap(find.byTooltip('Chapter actions').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename…'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Rooks');
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();
    expect(find.text('Rooks'), findsOneWidget);
    expect(study.onDisk, contains('[ChapterName "Rooks"]'));
  });

  testWidgets('the import dialog says what it recognised, and what it did '
      'not', (tester) async {
    await pump(tester);
    await tester.tap(find.byTooltip('Study actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Import from URL…'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'nonsense');
    await tester.pumpAndSettle();
    expect(find.text('Not a Lichess study link.'), findsOneWidget);
    await tester.enterText(
      find.byType(TextField).last,
      'lichess.org/study/abcd1234',
    );
    await tester.pumpAndSettle();
    expect(find.text('Lichess study · abcd1234'), findsOneWidget);
  });

  testWidgets('an import that cannot reach Lichess says so in plain English', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.byTooltip('Study actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Import from URL…'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField).last,
      'lichess.org/study/abcd1234',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Import'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Lichess did not respond'),
      findsOneWidget,
    );
  });
}
