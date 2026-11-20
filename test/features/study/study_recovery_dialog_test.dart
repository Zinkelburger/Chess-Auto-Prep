// Deleted studies: the dialog the study panel opens to bring a deleted study
// back, under its own name or another, and what it says when that fails.

import 'package:chess_auto_prep/features/study/study_panel.dart';
import 'package:chess_auto_prep/storage/chapter_files.dart';
import 'package:chess_auto_prep/storage/deleted_chapters.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/scripted_store.dart';
import '../../support/status_host.dart';
import '../../support/study_fixture.dart';

const _deletedText = '''
[Event "Openings: Alpha"]
[StudyName "Openings"]
[ChapterName "Alpha"]

1. e4 *
''';

final _deleted = DeletedChapter(
  path: '$studiesRoot/$recoveryFolder/Openings.pgn',
  folder: studiesRoot,
  name: 'Openings',
  deletedAt: DateTime.utc(2026, 11, 2),
);

void main() {
  late StudyFixture study;

  setUp(() async {
    study = await openStudy(twoChapterStudy);
    study.files.deletedListing = DeletedChapters([_deleted]);
    study.store.documents[ChapterRef.at(_deleted.path)] = Opened(
      _deletedText,
      scriptedRevision(_deletedText),
    );
  });

  tearDown(() => study.dispose());

  Future<void> openRecovery(WidgetTester tester) async {
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
    await tester.tap(find.text('Deleted studies'));
    await tester.pumpAndSettle();
  }

  bool restoredAs(String name) => study.store.documents.containsKey(
    ChapterRef.at('$studiesRoot/$name.pgn'),
  );

  testWidgets('Restore brings the study back under its own name and reads '
      'the list again', (tester) async {
    await openRecovery(tester);
    expect(find.textContaining('Openings'), findsOneWidget);

    study.files.deletedListing = const DeletedChapters([]);
    await tester.tap(find.text('Restore'));
    await tester.pumpAndSettle();
    expect(restoredAs('Openings'), isTrue);
    expect(find.text('Study restored.'), findsOneWidget);
    expect(find.text('No deleted studies.'), findsOneWidget);
  });

  testWidgets('Restore as asks for the name it comes back under', (
    tester,
  ) async {
    await openRecovery(tester);
    await tester.tap(find.text('Restore as…'));
    await tester.pumpAndSettle();
    expect(find.text('Restore study as'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, 'Old openings');
    await tester.tap(find.widgetWithText(FilledButton, 'Restore'));
    await tester.pumpAndSettle();
    expect(restoredAs('Old openings'), isTrue);
    expect(restoredAs('Openings'), isFalse);
    expect(find.text('Study restored.'), findsOneWidget);
  });

  testWidgets('backing out of Restore as restores nothing', (tester) async {
    await openRecovery(tester);
    await tester.tap(find.text('Restore as…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(restoredAs('Openings'), isFalse);
    expect(study.store.documents, contains(ChapterRef.at(_deleted.path)));
    expect(find.text('Study restored.'), findsNothing);
  });

  testWidgets('a name already taken is said, and nothing is restored', (
    tester,
  ) async {
    study.store.moves.add(const Collision());
    await openRecovery(tester);
    await tester.tap(find.text('Restore'));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'A study with that name already exists. Use Restore as to choose '
        'another name.',
      ),
      findsOneWidget,
    );
    expect(find.text('Study restored.'), findsNothing);
    expect(find.textContaining('Openings'), findsWidgets);
  });

  testWidgets('a restore the disk did not confirm offers Retry save, which '
      'finishes it', (tester) async {
    study.store.moves.add(const IoFailure('disk full'));
    await openRecovery(tester);
    expect(find.text('Retry save'), findsNothing);
    await tester.tap(find.text('Restore'));
    await tester.pumpAndSettle();
    expect(
      find.text('Restore was not confirmed: disk full. Retry save to finish.'),
      findsOneWidget,
    );
    expect(restoredAs('Openings'), isFalse);

    await tester.tap(find.text('Retry save'));
    await tester.pumpAndSettle();
    expect(restoredAs('Openings'), isTrue);
    expect(find.text('Study restored.'), findsOneWidget);
    expect(find.text('Retry save'), findsNothing);
  });

  testWidgets('a listing that cannot be read says so, and Try again reads '
      'it again', (tester) async {
    study.files.deletedListing = const DeletedUnreadable('permission denied');
    await openRecovery(tester);
    expect(find.text('Could not read the deleted studies.'), findsOneWidget);

    study.files.deletedListing = DeletedChapters([_deleted]);
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(find.text('Could not read the deleted studies.'), findsNothing);
    expect(find.text('Restore as…'), findsOneWidget);
  });

  testWidgets('Refresh reads the list again and Close shuts the dialog', (
    tester,
  ) async {
    await openRecovery(tester);
    study.files.deletedListing = const DeletedChapters([]);
    await tester.tap(find.text('Refresh'));
    await tester.pumpAndSettle();
    expect(find.text('No deleted studies.'), findsOneWidget);

    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
  });
}
