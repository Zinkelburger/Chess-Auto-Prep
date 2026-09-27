import 'dart:io';

import 'package:chess_auto_prep/design_system/theme/app_theme.dart';
import 'package:chess_auto_prep/features/repertoires/models/repertoire_metadata.dart';
import 'package:chess_auto_prep/features/repertoires/repositories/repertoire_catalog_repository.dart';
import 'package:chess_auto_prep/infrastructure/documents/native_pgn_document_store.dart';
import 'package:chess_auto_prep/infrastructure/repertoires/legacy_repertoire_catalog_repository.dart';
import 'package:chess_auto_prep/services/storage/io_storage_service.dart';
import 'package:chess_auto_prep/widgets/chapter_list_body.dart';
import 'package:document_file_io/document_file_io.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  for (final outcome in ['saved', 'collision', 'uncertain']) {
    testWidgets('native chapter picker: $outcome has one final outcome', (
      tester,
    ) async {
      final root = await Directory.systemTemp.createTemp(
        'chapter-picker-native-',
      );
      addTearDown(() => root.delete(recursive: true));
      final path = p.join(root.path, 'New.pgn');
      ChapterPick? selected;
      var observations = 0;
      var flushes = 0;
      final documents = NativePgnDocumentStore(
        observe: (candidate) async {
          final observed = await observeFile(candidate);
          if (candidate == path &&
              ++observations == 2 &&
              outcome == 'collision') {
            await File(path).writeAsString('competing writer');
          }
          return observed;
        },
        flushDirectory: (directory) async {
          flushes++;
          if (outcome == 'uncertain') {
            throw const FileSystemException('lost directory acknowledgement');
          }
          await syncDirectory(directory);
        },
      );
      final catalog = LegacyRepertoireCatalogRepository(
        IOStorageService(
          documentsRoot: root,
          supportRoot: root,
          repertoiresRoot: root,
        ),
        documents: documents,
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(),
          home: Provider<RepertoireCatalogRepository>.value(
            value: catalog,
            child: Scaffold(
              body: ChapterListBody(
                repertoire: RepertoireMetadata(
                  filePath: root.path,
                  name: 'Course',
                  lastModified: DateTime(2026),
                ),
                onSelected: (chapter) => selected = chapter,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add chapter'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'New');
      await tester.tap(find.text('Create'));
      final expected = switch (outcome) {
        'collision' => find.text('That chapter already exists.'),
        'uncertain' => find.textContaining(
          'Chapter creation needs verification:',
        ),
        _ => find.text('Add chapter'),
      };
      for (var i = 0; i < 200; i++) {
        await tester.pump(const Duration(milliseconds: 20));
        if (outcome == 'saved'
            ? selected != null
            : expected.evaluate().isNotEmpty) {
          break;
        }
      }
      if (outcome == 'saved') {
        expect(selected?.chapter.filePath, path);
        expect(await File(path).readAsString(), contains('// Color: White'));
      } else {
        expect(selected, isNull);
        expect(expected, findsOneWidget);
        if (outcome == 'collision') {
          expect(await File(path).readAsString(), 'competing writer');
        } else {
          expect(find.textContaining(path), findsOneWidget);
          expect(find.textContaining('Do not retry.'), findsOneWidget);
          expect(flushes, 1);
          expect(await File(path).readAsString(), contains('// New'));
        }
        final count = observations;
        await tester.pump(const Duration(milliseconds: 500));
        expect(observations, count, reason: 'No automatic mutation retry');
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
