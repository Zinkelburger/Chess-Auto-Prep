import 'dart:io';

import 'package:chess_auto_prep/core/app_state.dart';
import 'package:chess_auto_prep/features/repertoire/widgets/repertoire_outline_panel.dart';
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
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: app,
          child: const MaterialApp(home: RepertoireLibraryScreen()),
        ),
      );
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
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );
}
