import 'dart:io';

import 'package:chess_auto_prep/design_system/theme/app_theme.dart';
import 'package:chess_auto_prep/features/repertoire/controllers/repertoire_outline_controller.dart';
import 'package:chess_auto_prep/features/repertoire/services/chapter_splitter.dart';
import 'package:chess_auto_prep/features/repertoire/services/repertoire_outline_service.dart';
import 'package:chess_auto_prep/features/repertoire/widgets/repertoire_outline_panel.dart';
import 'package:chess_auto_prep/features/repertoires/models/repertoire_metadata.dart';
import 'package:chess_auto_prep/features/repertoires/repositories/repertoire_catalog_repository.dart';
import 'package:chess_auto_prep/infrastructure/documents/native_pgn_document_store.dart';
import 'package:chess_auto_prep/infrastructure/repertoires/legacy_repertoire_catalog_repository.dart';
import 'package:chess_auto_prep/l10n/generated/app_localizations.dart';
import 'package:chess_auto_prep/services/storage/io_storage_service.dart';
import 'package:chess_auto_prep/widgets/chapter_list_body.dart';
import 'package:document_file_io/document_file_io.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

Future<void> _until(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 300 && !ready(); i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(ready(), isTrue);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  for (final outline in [false, true]) {
    for (final outcome in ['saved', 'replacement', 'uncertain']) {
      testWidgets(
        'native ${outline ? 'Outline' : 'picker'} deletion: $outcome',
        (tester) async {
          expect(Platform.environment['XDG_DATA_HOME'], contains('/profile/'));
          final root = await Directory.systemTemp.createTemp(
            'chapter-delete-native-',
          );
          addTearDown(() => root.delete(recursive: true));
          const original = '[Event "Original"]\n[Result "*"]\n\n1. e4 e5 *\n';
          final file = File(p.join(root.path, 'Main.pgn'))
            ..writeAsStringSync(original);
          final storage = IOStorageService(
            documentsRoot: root,
            supportRoot: root,
            repertoiresRoot: root,
          );
          var sourceFlushes = 0;
          final documents = NativePgnDocumentStore(
            guardOperation: storage.guardDocumentOperation,
            flushDirectory: (path) async {
              if (path == root.path) {
                sourceFlushes++;
                if (outcome == 'uncertain') {
                  throw const FileSystemException('lost move acknowledgement');
                }
              }
              await syncDirectory(path);
            },
          );
          final catalog = LegacyRepertoireCatalogRepository(
            storage,
            documents: documents,
          );
          final followed = <String?>[];
          final controller = RepertoireOutlineController(
            catalog: catalog,
            service: RepertoireOutlineService(
              catalog: catalog,
              storage: storage,
              splitter: ChapterSplitter(documents: documents, storage: storage),
            ),
            onActiveChapterMoved: followed.add,
          );
          addTearDown(controller.dispose);
          await controller.open(
            rootPath: root.path,
            activeChapterPath: file.path,
            isWhite: true,
          );
          ChapterPick? selected;
          await tester.pumpWidget(
            MaterialApp(
              theme: AppTheme.dark(),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Provider<RepertoireCatalogRepository>.value(
                value: catalog,
                child: Scaffold(
                  body: outline
                      ? RepertoireOutlinePanel(
                          controller: controller,
                          onOpenChapter: (_) {},
                          onOpenLine: (_, _) {},
                        )
                      : ChapterListBody(
                          repertoire: RepertoireMetadata(
                            filePath: root.path,
                            name: 'Course',
                            lastModified: DateTime(2026),
                          ),
                          onSelected: (value) => selected = value,
                        ),
                ),
              ),
            ),
          );
          await _until(tester, () => find.text('Main').evaluate().isNotEmpty);
          if (outline) {
            final gesture = await tester.startGesture(
              tester.getCenter(find.text('Main')),
              kind: PointerDeviceKind.mouse,
              buttons: kSecondaryMouseButton,
            );
            await gesture.up();
            await tester.pumpAndSettle();
            await tester.tap(find.text('Delete chapter…'));
          } else {
            await tester.tap(find.byTooltip('Delete chapter'));
          }
          await _until(
            tester,
            () => find.text('Delete chapter "Main"?').evaluate().isNotEmpty,
          );
          if (outcome == 'replacement') {
            file.renameSync(p.join(root.path, 'original-retained.pgn'));
            file.writeAsStringSync(
              original,
            ); // Same bytes, different native identity.
          }
          await tester.tap(find.text('Delete'));
          if (outcome == 'uncertain') {
            await _until(
              tester,
              () => find.text('Review chapter deletion').evaluate().isNotEmpty,
            );
            expect(file.existsSync(), isFalse);
            expect(sourceFlushes, 1);
            final evidence = tester
                .widget<SelectableText>(find.byType(SelectableText))
                .data!;
            expect(evidence, contains(file.path));
            expect(evidence, contains('.cap-pgn-history'));
            expect(find.text('Retry'), findsNothing);
            if (outline) {
              expect(controller.activeChapterPath, file.path);
              expect(followed, isEmpty);
            }
            await tester.tap(find.text('Close'));
            await _until(tester, () => find.text('Main').evaluate().isEmpty);
          } else if (outcome == 'replacement') {
            await _until(
              tester,
              () => find
                  .textContaining('Nothing was removed')
                  .evaluate()
                  .isNotEmpty,
            );
            expect(file.readAsStringSync(), original);
            expect(sourceFlushes, 0);
            expect(followed, isEmpty);
          } else {
            await _until(
              tester,
              () => find
                  .textContaining('Chapter moved to recovery:')
                  .evaluate()
                  .isNotEmpty,
            );
            expect(file.existsSync(), isFalse);
            final retained = Directory(
              p.join(root.path, '.cap-pgn-history'),
            ).listSync().whereType<File>();
            expect(
              retained.any(
                (candidate) => candidate.readAsStringSync() == original,
              ),
              isTrue,
            );
            if (outline) {
              expect(controller.activeChapterPath, isNull);
              expect(followed, [null]);
            }
          }
          expect(selected, isNull);
          final flushed = sourceFlushes;
          await tester.pump(const Duration(milliseconds: 200));
          expect(sourceFlushes, flushed, reason: 'No automatic retry');
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }
}
