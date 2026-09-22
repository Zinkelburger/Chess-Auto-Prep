import 'package:provider/provider.dart';
import 'package:chess_auto_prep/features/repertoires/repositories/repertoire_catalog_repository.dart';
import 'package:chess_auto_prep/infrastructure/repertoires/legacy_repertoire_catalog_repository.dart';
import 'package:chess_auto_prep/infrastructure/documents/legacy_pgn_document_store.dart';
import 'dart:io';

import 'package:chess_auto_prep/features/repertoires/models/repertoire_metadata.dart';
import 'package:chess_auto_prep/services/storage/io_storage_service.dart';
import 'package:chess_auto_prep/services/storage/storage_factory.dart';
import 'package:chess_auto_prep/design_system/theme/app_theme.dart';
import 'package:chess_auto_prep/widgets/chapter_list_body.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final brightness in Brightness.values) {
    testWidgets(
      'large courses stay compact, searchable and readable in a narrow pane: $brightness',
      (tester) async {
        final root = Directory.systemTemp.createTempSync('chapter-readability');
        final folder = Directory('${root.path}/repertoires/Course')
          ..createSync(recursive: true);
        addTearDown(() {
          StorageFactory.instanceForTest = null;
          root.deleteSync(recursive: true);
        });
        StorageFactory.instanceForTest = IOStorageService(
          documentsRoot: root,
          supportRoot: root,
          repertoiresRoot: Directory('${root.path}/repertoires'),
        );
        String title(int i) =>
            'Chapter $i: A very long course title about move orders and practical sidelines that must remain identifiable';
        File('${folder.path}/Complete course.pgn').writeAsStringSync(
          [
            for (var i = 0; i < 30; i++)
              for (var j = 0; j < 2; j++)
                '[Event "?"]\n[White "${title(i)}"]\n[Black "Line $j"]\n[Result "*"]\n\n1. e4 e5 *\n',
          ].join('\n'),
        );
        ChapterPick? picked;
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => Provider<RepertoireCatalogRepository>(
              create: (_) => LegacyRepertoireCatalogRepository(
                StorageFactory.instance,
                documents: LegacyPgnDocumentStore(StorageFactory.instance),
              ),
              child: child!,
            ),
            theme: brightness == Brightness.dark
                ? AppTheme.dark()
                : AppTheme.light(),
            home: Scaffold(
              body: SizedBox(
                width: 420,
                child: ChapterListBody(
                  repertoire: RepertoireMetadata(
                    filePath: folder.path,
                    name: 'Course',
                    gameCount: 60,
                    lastModified: DateTime.now(),
                  ),
                  onSelected: (value) => picked = value,
                ),
              ),
            ),
          ),
        );
        for (
          var i = 0;
          i < 200 && find.text('Show all 30 chapters').evaluate().isEmpty;
          i++
        ) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
        }
        expect(find.text('Show all 30 chapters'), findsOneWidget);
        expect(find.text(title(0)), findsOneWidget);
        expect(find.text(title(3)), findsNothing);
        expect(tester.getSize(find.text(title(0))).height, lessThan(60));
        expect(find.byTooltip(title(0)), findsOneWidget);
        final count = tester.widget<RichText>(
          find.descendant(
            of: find.text('2 lines').first,
            matching: find.byType(RichText),
          ),
        );
        final foreground = count.text.style!.color!;
        final background = tester
            .widget<Material>(
              find
                  .descendant(
                    of: find.byType(Card).first,
                    matching: find.byType(Material),
                  )
                  .first,
            )
            .color!;
        final light = foreground.computeLuminance();
        final dark = background.computeLuminance();
        final contrast = light > dark
            ? (light + 0.05) / (dark + 0.05)
            : (dark + 0.05) / (light + 0.05);
        expect(contrast, greaterThanOrEqualTo(4.5));
        await tester.tap(find.text('Show all 30 chapters'));
        await tester.pump();
        expect(find.text(title(3)), findsOneWidget);
        await tester.enterText(find.byType(TextField), 'Chapter 29:');
        await tester.pump();
        expect(find.text(title(29)), findsOneWidget);
        expect(find.text(title(0)), findsNothing);
        await tester.tap(find.text(title(29)));
        expect(picked?.courseChapter, title(29));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
