import 'dart:async';
import 'package:chess_auto_prep/features/studies/repositories/study_import_repository.dart';
import 'package:chess_auto_prep/l10n/generated/app_localizations.dart';
import 'package:chess_auto_prep/widgets/study/import_from_url_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Repository implements StudyImportRepository {
  final source = _Source();
  @override
  StudyImportSource openSource() => source;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Source implements StudyImportSource {
  final response = Completer<StudyCollectionSource>();
  int closed = 0;
  int requests = 0;
  @override
  Future<StudyCollectionSource> fetchCollection(String id) {
    requests++;
    return response.future;
  }

  @override
  void close() {
    closed++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  Future<_Repository> open(
    WidgetTester tester,
    void Function(StudyImportPlan?) result,
  ) async {
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = _Repository();
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async => result(
                await showDialog<StudyImportPlan>(
                  context: context,
                  builder: (_) => ImportFromUrlDialog(
                    canAppend: false,
                    repository: repository,
                  ),
                ),
              ),
              child: const Text('Start'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Start'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField).first,
      'https://www.chessgames.com/perl/chesscollection?cid=42',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Import'));
    await tester.pump();
    expect(repository.source.requests, 1);
    return repository;
  }

  testWidgets(
    'changing a pasted ID list with the same count imports the revised IDs',
    (tester) async {
      StudyImportPlan? plan;
      final repository = await open(tester, (result) => plan = result);
      repository.source.response.complete((
        gameIds: const <String>[],
        name: 'Collection',
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.enterText(find.byType(TextField).last, '12345');
      await tester.pump();
      await tester.enterText(find.byType(TextField).last, '67890');
      await tester.pump();
      await tester.tap(find.text('Download 1'));
      await tester.pumpAndSettle();
      expect((plan as CollectionPlan).gameIds, ['67890']);
      expect(repository.source.closed, 1);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'dismissed URL import closes its source and rejects its late result',
    (tester) async {
      final results = <StudyImportPlan?>[];
      final repository = await open(tester, results.add);
      await tester.tapAt(const Offset(15, 15));
      await tester.pumpAndSettle();
      expect(repository.source.closed, 1);
      repository.source.response.complete((
        gameIds: <String>['67890'],
        name: 'Late',
      ));
      await tester.pumpAndSettle();
      expect(results, [null]);
      expect(find.byType(ImportFromUrlDialog), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
