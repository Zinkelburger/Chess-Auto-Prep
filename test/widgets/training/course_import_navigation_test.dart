import 'package:chess_auto_prep/l10n/generated/app_localizations.dart';
import 'package:chess_auto_prep/app/app_dependencies.dart';
import 'dart:io';

import 'package:chess_auto_prep/features/repertoires/models/repertoire_metadata.dart';
import 'package:chess_auto_prep/features/repertoires/widgets/repertoire_chapters_screen.dart';
import 'package:chess_auto_prep/services/storage/io_storage_service.dart';
import 'package:chess_auto_prep/services/storage/storage_factory.dart';
import 'package:chess_auto_prep/widgets/pgn_import_dialog.dart';
import 'package:chess_auto_prep/features/repertoires/widgets/repertoire_list_body.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('import opens every chapter instead of only the introduction', (
    tester,
  ) async {
    final root = Directory.systemTemp.createTempSync('train-course-import');
    addTearDown(() {
      StorageFactory.instanceForTest = null;
      root.deleteSync(recursive: true);
    });
    Directory('${root.path}/repertoires').createSync();
    StorageFactory.instanceForTest = IOStorageService(
      documentsRoot: root,
      supportRoot: root,
      repertoiresRoot: Directory('${root.path}/repertoires'),
    );
    String game(String chapter, String title, String moves) =>
        '[Event "?"]\r\n[White "$chapter"]\r\n[Black "$title"]\r\n'
        '[Result "*"]\r\n\r\n$moves *\r\n\r\n';
    final course =
        '${game('Introduction', 'Welcome', '1. d4 Nf6')}'
        '${game('Quickstarter', 'Classical', '1. d4 Nf6 2. c4 g6')}'
        '${game('Quickstarter', 'Fianchetto', '1. d4 Nf6 2. Nf3 g6')}';
    RepertoireMetadata? selected;
    await pumpCatalogWidget(
      tester,
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: RepertoireListBody(
            onSelected: (value) => selected = value,
            pickPgn: () async => PickedPgnImport(
              result: PgnImportResult(
                pgnContent: course,
                gameCount: 3,
                fileName: 'Course.pgn',
              ),
              suggestedName: 'Course',
              suggestedColor: 'Black',
            ),
          ),
        ),
      ),
    );
    // The import and chapter listing use real isolated file I/O. Advance
    // real I/O and Flutter frames until the requested screen is ready.
    Future<void> until(bool Function() ready) async {
      for (var i = 0; i < 200 && !ready(); i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(ready(), isTrue);
    }

    await until(() => find.text('Open PGN file…').evaluate().isNotEmpty);
    await tester.runAsync(() async {
      await tester.tap(find.text('Open PGN file…'));
      for (
        var i = 0;
        i < 200 &&
            !File(
              '${root.path}/repertoires/Course/Quickstarter.pgn',
            ).existsSync();
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await until(() => find.text('Quickstarter').evaluate().isNotEmpty);
    expect(find.byType(RepertoireChaptersScreen), findsOneWidget);
    expect(find.text('Introduction'), findsOneWidget);
    expect(selected, isNull);
    await tester.tap(find.text('Quickstarter'));
    await tester.pump();
    await until(
      () =>
          selected != null &&
          find.text('Open PGN file…').evaluate().isNotEmpty &&
          find.byType(CircularProgressIndicator).evaluate().isEmpty,
    );
    await tester.pump(const Duration(seconds: 1));
    expect(selected?.filePath, endsWith('Quickstarter.pgn'));
    expect(selected?.name, 'Quickstarter');
    expect(tester.takeException(), isNull);
    await pumpCatalogWidget(tester, const SizedBox.shrink());
  });
}

Future<void> pumpCatalogWidget(WidgetTester tester, Widget child) =>
    tester.pumpWidget(AppDependencies(child: child));
