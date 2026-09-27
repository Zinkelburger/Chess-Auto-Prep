import 'package:chess_auto_prep/infrastructure/documents/native_pgn_document_store.dart';
import 'package:chess_auto_prep/l10n/generated/app_localizations.dart';
import 'dart:io';

import 'package:chess_auto_prep/app/app_dependencies.dart';
import 'package:chess_auto_prep/features/repertoires/models/repertoire_recovery_required.dart';
import 'package:chess_auto_prep/features/repertoires/widgets/repertoire_list_body.dart';
import 'package:chess_auto_prep/features/settings/models/repertoire_books.dart';
import 'package:chess_auto_prep/infrastructure/repertoires/legacy_repertoire_catalog_repository.dart';
import 'package:chess_auto_prep/infrastructure/repertoires/repertoire_directory_mutations.dart';
import 'package:chess_auto_prep/infrastructure/settings/fresh_desktop_preferences_store.dart';
import 'package:chess_auto_prep/infrastructure/settings/shared_preferences_app_settings_repository.dart';
import 'package:chess_auto_prep/services/storage/app_paths.dart';
import 'package:chess_auto_prep/services/storage/io_storage_service.dart';
import 'package:chess_auto_prep/design_system/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  installFreshDesktopPreferencesStore();
  testWidgets(
    'rename interruption recovers through the UI and survives a fresh catalog',
    (tester) async {
      final fixture = Directory(
        p.join(
          (await AppPaths.supportDirectory()).path,
          'rename-${DateTime.now().microsecondsSinceEpoch}',
        ),
      );
      final root = await Directory(
        p.join(fixture.path, 'repertoires'),
      ).create(recursive: true);
      final old = await Directory(p.join(root.path, 'Before')).create();
      await File(
        p.join(old.path, 'Main.pgn'),
      ).writeAsString('{keep annotation}\n1. e4 e5 *');
      final training = File(
        p.join(fixture.path, 'repertoire_move_progress.csv'),
      );
      await training.writeAsString(
        'repertoire_id,line_id,move_index,correct_streak,learned\n${p.join(old.path, 'Main.pgn')},line,2,7,true\n',
      );
      final settings = SharedPreferencesAppSettingsRepository();
      await settings.repertoireBooks.setPaths(BookSide.white, [old.path]);

      Future<void> pumpCatalog({required bool fail}) async {
        final storage = IOStorageService(
          documentsRoot: fixture,
          supportRoot: fixture,
          repertoiresRoot: root,
          repertoireBooks: settings.repertoireBooks,
          repertoireMoveHook: fail
              ? (step) async {
                  if (step == RepertoireMoveStep.moved) {
                    throw StateError('Injected interruption');
                  }
                }
              : null,
        );
        await tester.pumpWidget(
          AppDependencies(
            repertoireCatalog: LegacyRepertoireCatalogRepository(
              storage,
              documents: NativePgnDocumentStore(),
            ),
            child: MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              theme: AppTheme.dark(),
              home: Scaffold(body: RepertoireListBody(onSelected: (_) {})),
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      Future<void> waitFor(Finder finder) async {
        for (var i = 0; i < 100 && finder.evaluate().isEmpty; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(finder, findsOneWidget);
      }

      await pumpCatalog(fail: true);
      await waitFor(find.text('Before'));
      await tester.tap(find.byTooltip('Rename repertoire'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        ),
        'After',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Rename'));
      await waitFor(
        find.text(const RepertoireRecoveryRequired('', '').toString()),
      );
      expect(await old.exists(), isFalse);
      expect(settings.repertoireBooks.state.committed!.white, [old.path]);
      expect(await training.readAsString(), contains(old.path));
      await tester.tap(find.text('Recover library'));
      await waitFor(find.text('After'));
      expect(find.text('Recover library'), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await pumpCatalog(fail: false);
      await waitFor(find.text('After'));
      final moved = p.join(root.path, 'After');
      expect(settings.repertoireBooks.state.committed!.white, [moved]);
      expect(
        await training.readAsString(),
        contains('$moved${p.separator}Main.pgn,line,2,7,true'),
      );
      expect(
        await File(p.join(moved, 'Main.pgn')).readAsString(),
        contains('{keep annotation}'),
      );
      final restarted = SharedPreferencesAppSettingsRepository();
      await restarted.repertoireBooks.ensureLoaded();
      expect(restarted.repertoireBooks.state.committed!.white, [moved]);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'interrupted restore keeps original name and recovers through the UI',
    (tester) async {
      final fixture = await Directory(
        p.join(
          (await AppPaths.supportDirectory()).path,
          'restore-${DateTime.now().microsecondsSinceEpoch}',
        ),
      ).create();
      final root = await Directory(
        p.join(fixture.path, 'repertoires'),
      ).create();
      final source = await Directory(p.join(root.path, 'Restore me')).create();
      final chapter = File(p.join(source.path, 'Main.pgn'));
      await chapter.writeAsString('{retained annotation} 1. d4 d5 *');
      final bytes = await chapter.readAsBytes();
      final settings = SharedPreferencesAppSettingsRepository();
      await settings.repertoireBooks.setPaths(BookSide.black, [source.path]);
      var interruptRestore = false;
      final storage = IOStorageService(
        documentsRoot: fixture,
        supportRoot: fixture,
        repertoiresRoot: root,
        repertoireBooks: settings.repertoireBooks,
        repertoireMoveHook: (step) async {
          if (interruptRestore && step == RepertoireMoveStep.moved) {
            throw StateError('Interrupted restore');
          }
        },
      );
      Future<void> waitFor(Finder finder) async {
        for (var i = 0; i < 100 && finder.evaluate().isEmpty; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(finder, findsOneWidget);
        await tester.pumpAndSettle();
      }

      await tester.pumpWidget(
        AppDependencies(
          repertoireCatalog: LegacyRepertoireCatalogRepository(
            storage,
            documents: NativePgnDocumentStore(),
          ),
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            theme: AppTheme.dark(),
            home: Scaffold(body: RepertoireListBody(onSelected: (_) {})),
          ),
        ),
      );
      await waitFor(find.text('Restore me'));
      await tester.tap(find.byTooltip('Delete repertoire'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('Delete'),
        ),
      );
      await waitFor(find.text('No repertoires yet'));
      expect(await chapter.exists(), isFalse);
      await tester.tap(find.text('Recovery'));
      await waitFor(find.text('Restore me'));
      await tester.tap(find.widgetWithText(TextButton, 'Restore'));
      await tester.pumpAndSettle();
      interruptRestore = true;
      await tester.tap(find.widgetWithText(FilledButton, 'Restore'));
      await waitFor(find.text('Recover library'));
      expect(await chapter.readAsBytes(), bytes);
      expect(
        settings.repertoireBooks.state.committed!.black.single,
        contains('.chess_auto_prep_trash'),
      );
      interruptRestore = false;
      await tester.tap(find.text('Recover library'));
      await waitFor(find.text('Recovery is empty'));
      await tester.tap(find.text('Back to library'));
      await waitFor(find.text('Restore me'));
      expect(settings.repertoireBooks.state.committed!.black, [source.path]);
      final fresh = IOStorageService(
        documentsRoot: fixture,
        supportRoot: fixture,
        repertoiresRoot: root,
        repertoireBooks: settings.repertoireBooks,
      );
      expect((await fresh.listRepertoires()).single.name, 'Restore me');
      expect(await fresh.listRepertoireRecovery(), isEmpty);
      expect(await chapter.readAsBytes(), bytes);
      expect(tester.takeException(), isNull);
    },
  );
}
