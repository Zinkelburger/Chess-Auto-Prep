import 'package:chess_auto_prep/l10n/generated/app_localizations.dart';
import 'package:chess_auto_prep/app/app_dependencies.dart';
import 'package:chess_auto_prep/app/repertoire_dependencies.dart';
import 'dart:io';

import 'package:chess_auto_prep/core/app_state.dart';
import 'package:chess_auto_prep/features/repertoire/services/repertoire_outline_service.dart';
import 'package:chess_auto_prep/features/repertoire/widgets/repertoire_outline_panel.dart';
import 'package:chess_auto_prep/features/repertoires/repositories/repertoire_catalog_repository.dart';
import 'package:chess_auto_prep/infrastructure/documents/legacy_pgn_document_store.dart';
import 'package:chess_auto_prep/screens/repertoire_library_screen.dart';
import 'package:chess_auto_prep/services/storage/io_storage_service.dart';
import 'package:chess_auto_prep/services/storage/storage_factory.dart';
import 'package:chess_auto_prep/widgets/chess_board_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets(
    'library organizes chapters and hands the selected source to read, train and build',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final root = Directory.systemTemp.createTempSync('repertoire-library');
      final folder = Directory('${root.path}/repertoires/Caro')
        ..createSync(recursive: true);
      final nested = Directory('${folder.path}/Sidelines')..createSync();
      final chapter = File('${nested.path}/Main.pgn')
        ..writeAsStringSync(
          '// Color: Black\n\n[Event "Main line"]\n\n1. e4 c6 2. d4 d5 *\n',
        );
      StorageFactory.instanceForTest = IOStorageService(
        documentsRoot: root,
        supportRoot: root,
        repertoiresRoot: Directory('${root.path}/repertoires'),
      );
      final app = AppState()..setMode(AppMode.repertoireLibrary);
      addTearDown(() {
        StorageFactory.instanceForTest = null;
        root.deleteSync(recursive: true);
        app.dispose();
      });
      final library = ChangeNotifierProvider.value(
        value: app,
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: RepertoireLibraryScreen(),
        ),
      );
      await pumpCatalogWidget(tester, library);
      expect(find.byType(RepertoireLibraryScreen), findsOneWidget);
      expect(find.byType(RepertoireOutlinePanel), findsNothing);
      // Closing the library before opening a folder must not resolve its
      // outline dependencies for the first time from a deactivated context.
      await pumpCatalogWidget(tester, const SizedBox());
      expect(find.byType(RepertoireLibraryScreen), findsNothing);
      expect(tester.takeException(), isNull);
      await pumpCatalogWidget(tester, library);
      Future<void> until(bool Function() ready) async {
        for (var i = 0; i < 200 && !ready(); i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump(const Duration(milliseconds: 20));
        }
        expect(ready(), isTrue);
      }

      await until(() => find.text('Caro').evaluate().isNotEmpty);
      await tester.tap(find.text('Caro'));
      await until(() => find.text('Read chapter').evaluate().isNotEmpty);
      expect(find.byType(ChessBoardWidget), findsNothing);
      expect(
        tester
            .widget<RepertoireOutlinePanel>(find.byType(RepertoireOutlinePanel))
            .controller
            .isWhite,
        isFalse,
      );
      await tester.tap(find.text('Read chapter'));
      expect(app.currentMode, AppMode.pgnViewer);
      expect((app.takeHandoff<OpenPgnViewer>())!.pgnPath, chapter.path);
      app.setMode(AppMode.repertoireLibrary);
      await until(() => find.text('Train chapter').evaluate().isNotEmpty);
      await tester.tap(find.text('Train chapter'));
      expect((app.takeHandoff<TrainRepertoire>())!.sourcePath, chapter.path);
      app.setMode(AppMode.repertoireLibrary);
      await tester.pump();
      await tester.tap(find.text('Train repertoire'));
      expect((app.takeHandoff<TrainRepertoire>())!.sourcePath, folder.path);
      app.setMode(AppMode.repertoireLibrary);
      await tester.pump();
      await tester.tap(find.text('Build chapter'));
      final build = app.takeHandoff<OpenBuilder>()!;
      expect(build.repertoirePath, chapter.path);
      expect(build.reloadFromDisk, isTrue);
      await pumpCatalogWidget(tester, const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> pumpCatalogWidget(WidgetTester tester, Widget child) =>
    tester.pumpWidget(
      AppDependencies(
        child: Provider<RepertoireOutlineService>(
          create: (context) => createRepertoireOutline(
            catalog: context.read<RepertoireCatalogRepository>(),
            documents: LegacyPgnDocumentStore(StorageFactory.instance),
          ),
          child: child,
        ),
      ),
    );
