// The chapter tag editor: a tag the study writes for itself, or keeps out
// of sight, cannot be typed in by hand.

import 'package:chess_auto_prep/features/study/study_panel.dart';
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/status_host.dart';
import '../../support/study_fixture.dart';

void main() {
  late StudyFixture study;

  setUp(() async => study = await openStudy(twoChapterStudy));
  tearDown(() => study.dispose());

  Future<void> openTags(WidgetTester tester) async {
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
    await tester.tap(find.byTooltip('Chapter actions').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('PGN tags…'));
    await tester.pumpAndSettle();
  }

  Future<void> addTag(WidgetTester tester, String key, String value) async {
    await tester.ensureVisible(find.text('Add tag'));
    await tester.tap(find.text('Add tag'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.widgetWithText(TextField, 'Tag').last);
    await tester.enterText(find.widgetWithText(TextField, 'Tag').last, key);
    await tester.enterText(find.widgetWithText(TextField, 'Value').last, value);
    await tester.tap(find.text('Save tags'));
    await tester.pumpAndSettle();
  }

  for (final key in ['StudyName', 'ChapterName', 'Orientation', 'LineID']) {
    testWidgets('$key typed in by hand is refused and nothing is written', (
      tester,
    ) async {
      await openTags(tester);
      await addTag(tester, key, 'Typed');
      expect(find.text('$key belongs to the study.'), findsOneWidget);
      expect(find.text('Chapter PGN tags'), findsOneWidget);
      await study.saver.flush();
      expect(study.onDisk, twoChapterStudy);
    });
  }

  testWidgets('a tag of the chapter\'s own is saved', (tester) async {
    await openTags(tester);
    await addTag(tester, 'Annotator', 'Coach');
    expect(find.text('Chapter PGN tags'), findsNothing);
    await study.saver.flush();
    expect(study.onDisk, contains('[Annotator "Coach"]'));
  });
}
