import 'package:chess_auto_prep/l10n/generated/app_localizations.dart';
import 'dart:io';

import 'package:chess_auto_prep/app/app_dependencies.dart';
import 'package:chess_auto_prep/features/repertoires/models/repertoire_creation.dart';
import 'package:chess_auto_prep/features/repertoires/models/repertoire_recovery_required.dart';
import 'package:chess_auto_prep/infrastructure/repertoires/native_repertoire_publication_store.dart';
import 'package:chess_auto_prep/features/repertoires/widgets/repertoire_list_body.dart';
import 'package:chess_auto_prep/infrastructure/documents/native_pgn_document_store.dart';
import 'package:chess_auto_prep/infrastructure/repertoires/legacy_repertoire_catalog_repository.dart';
import 'package:chess_auto_prep/services/storage/app_paths.dart';
import 'package:chess_auto_prep/services/storage/io_storage_service.dart';
import 'package:chess_auto_prep/design_system/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'uncertain native commit retains creation draft and never duplicates it',
    (tester) async {
      final name = 'Uncertain ${DateTime.now().microsecondsSinceEpoch}';
      final repository = LegacyRepertoireCatalogRepository(
        documents: NativePgnDocumentStore(),
        IOStorageService(
          repertoirePublicationHook: (step) async {
            if (step == RepertoirePublicationStep.installed) {
              throw StateError('Injected publication interruption');
            }
          },
        ),
      );
      await tester.pumpWidget(
        AppDependencies(
          repertoireCatalog: repository,
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            theme: AppTheme.dark(),
            home: Scaffold(body: RepertoireListBody(onSelected: (_) {})),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create new repertoire'));
      await tester.pumpAndSettle();
      final nameField = find.byKey(const ValueKey('repertoire-create-name'));
      await tester.enterText(nameField, name);
      await tester.tap(find.text('Empty repertoire'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Create repertoire'));
      final message = find.text(
        const RepertoireRecoveryRequired('', '').toString(),
      );
      for (var i = 0; i < 100 && message.evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(message, findsOneWidget);
      expect(tester.widget<TextFormField>(nameField).controller!.text, name);
      final root = await AppPaths.repertoiresDirectory();
      final saved = File(p.join(root.path, name, 'Main.pgn'));
      final bytes = await saved.readAsBytes();
      expect(bytes, isNotEmpty);
      await tester.tap(find.widgetWithText(FilledButton, 'Create repertoire'));
      final collision = find.text(RepertoireExistsException(name).toString());
      for (var i = 0; i < 100 && collision.evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(collision, findsOneWidget);
      expect(await saved.readAsBytes(), bytes);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'failed private preparation retains the draft without publishing a folder',
    (tester) async {
      final name = 'Staged failure ${DateTime.now().microsecondsSinceEpoch}';
      final repository = LegacyRepertoireCatalogRepository(
        IOStorageService(),
        documents: NativePgnDocumentStore(
          flushDirectory: (_) async =>
              throw const FileSystemException('Injected stage flush failure'),
        ),
      );
      await tester.pumpWidget(
        AppDependencies(
          repertoireCatalog: repository,
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            theme: AppTheme.dark(),
            home: Scaffold(body: RepertoireListBody(onSelected: (_) {})),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create new repertoire'));
      await tester.pumpAndSettle();
      final nameField = find.byKey(const ValueKey('repertoire-create-name'));
      await tester.enterText(nameField, name);
      await tester.tap(find.text('Empty repertoire'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Create repertoire'));
      final message = find.text(
        const RepertoirePreparationFailed('').toString(),
      );
      for (var i = 0; i < 100 && message.evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(message, findsOneWidget);
      expect(tester.widget<TextFormField>(nameField).controller!.text, name);
      final root = await AppPaths.repertoiresDirectory();
      expect(await Directory(p.join(root.path, name)).exists(), isFalse);
      expect(
        (await IOStorageService().listRepertoires()).any((r) => r.name == name),
        isFalse,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
