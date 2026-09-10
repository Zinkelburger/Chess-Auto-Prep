import 'package:chess_auto_prep/models/repertoire_metadata.dart';
import 'package:chess_auto_prep/services/storage/storage_factory.dart';
import 'package:chess_auto_prep/services/storage/storage_service.dart';
import 'package:chess_auto_prep/widgets/pgn/add_to_study_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Studies extends Fake implements StorageService {
  _Studies(this.names);
  final List<String> names;

  @override
  Future<List<RepertoireMetadata>> listStudyFiles() async => [
    for (final name in names)
      RepertoireMetadata(
        filePath: '/studies/$name.pgn',
        name: name,
        lastModified: DateTime(2026),
      ),
  ];
}

void main() {
  tearDown(() => StorageFactory.instanceForTest = null);

  Future<void> openPicker(
    WidgetTester tester, {
    List<String> studies = const [],
    String? summary,
    required ValueChanged<AddToStudyResult?> onResult,
  }) async {
    StorageFactory.instanceForTest = _Studies(studies);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async => onResult(
                await showDialog<AddToStudyResult>(
                  context: context,
                  builder: (_) => AddToStudyDialog(
                    initialChapterName: 'My line',
                    selectionSummary: summary,
                  ),
                ),
              ),
              child: const Text('Add'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
  }

  testWidgets('create immediately with a suggested unused name', (
    tester,
  ) async {
    AddToStudyResult? result;
    await openPicker(
      tester,
      studies: ['New study'],
      onResult: (v) => result = v,
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Chapter name'),
      'Edited chapter',
    );
    await tester.tap(find.text('Add new study'));
    await tester.pumpAndSettle();
    expect(find.text('New study (2)'), findsOneWidget);
    await tester.tap(find.text('Create and add'));
    await tester.pumpAndSettle();
    expect(result?.newStudyName, 'New study (2)');
    expect(result?.existingPath, isNull);
    expect(result?.chapterName, 'Edited chapter');
  });

  testWidgets(
    'empty library and batch selection can create without searching',
    (tester) async {
      AddToStudyResult? result;
      await openPicker(
        tester,
        summary: '2 games · one chapter per game',
        onResult: (v) => result = v,
      );
      await tester.tap(find.text('Add new study'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create and add'));
      await tester.pumpAndSettle();
      expect(result?.newStudyName, 'New study');
    },
  );

  testWidgets(
    'duplicate name stays in the prompt and cancellation keeps picker',
    (tester) async {
      AddToStudyResult? result;
      await openPicker(
        tester,
        studies: ['Openings'],
        onResult: (v) => result = v,
      );
      await tester.tap(find.text('Add new study'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Study name'),
        'openings',
      );
      await tester.tap(find.text('Create and add'));
      await tester.pumpAndSettle();
      expect(
        find.text('A study with this name already exists.'),
        findsOneWidget,
      );
      expect(result, isNull);
      await tester.tap(find.text('Cancel').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Openings'));
      await tester.pumpAndSettle();
      expect(result?.existingPath, '/studies/Openings.pgn');
    },
  );

  testWidgets('search Enter only picks an existing study', (tester) async {
    AddToStudyResult? result;
    await openPicker(
      tester,
      studies: ['Openings'],
      onResult: (v) => result = v,
    );
    final search = find.widgetWithText(TextField, 'Search existing studies');
    await tester.enterText(search, 'Unknown');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(result, isNull);
    expect(find.text('No studies match your search.'), findsOneWidget);
    expect(find.text('Add new study'), findsOneWidget);
    await tester.enterText(search, 'Open');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(result?.existingPath, '/studies/Openings.pgn');
  });
}
