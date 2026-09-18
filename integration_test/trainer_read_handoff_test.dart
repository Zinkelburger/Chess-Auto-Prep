import 'dart:io';

import 'package:chess_auto_prep/app/pgn_viewer_lifetime.dart';
import 'package:chess_auto_prep/core/app_state.dart';
import 'package:chess_auto_prep/services/storage/app_paths.dart';
import 'package:chess_auto_prep/widgets/app_mode_switcher.dart';
import 'package:chess_auto_prep/widgets/training/trainer_browser.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/board_helpers.dart';
import 'helpers/tactics_helpers.dart';

Future<void> _until(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 150 && !ready(); i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(ready(), isTrue);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Trainer Read opens captured games, copies edits and returns safely',
    (tester) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('pgn_viewer.last_file');
      await prefs.setBool('pgn_viewer.auto_detect_openings', false);
      await prefs.setBool('game_view.auto_save', false);
      final root = await AppPaths.studiesDirectory(create: true);
      final nonce = DateTime.now().microsecondsSinceEpoch;
      final source = File('${root.path}/Read practice $nonce.pgn');
      final other = File('${root.path}/Other reading $nonce.pgn');
      final copy = File('${root.path}/Reading copy $nonce.pgn');
      const original =
          '[Event "First reading"]\n[Result "*"]\n\n'
          '1. e4 {First notes} e5 2. Nf3 Nc6 *\n\n'
          '[Event "Second reading"]\n[Result "*"]\n\n'
          '1. d4 {Second notes} d5 2. c4 e6 *\n';
      await source.writeAsString(original);
      await other.writeAsString('[Event "Other reading"]\n\n1. c4 e5 *\n');
      addTearDown(() async {
        for (final file in [source, other, copy]) {
          if (await file.exists()) await file.delete();
        }
      });
      await pumpApp(tester);
      final app = getAppState(tester);
      app.switchToStudyTraining(path: source.path);
      final read = find.byTooltip('Read moves and notes in PGN Viewer');
      await _until(tester, () => read.evaluate().isNotEmpty);
      // Keep the actual old widget callback, then change source before a frame.
      // Its captured lines must not be combined with the newer source's title.
      final staleRead = tester
          .widget<InkWell>(
            find.ancestor(of: read, matching: find.byType(InkWell)).first,
          )
          .onTap!;
      app.switchToStudyTraining(path: other.path);
      staleRead();
      expect(app.currentMode, AppMode.repertoireTrainer);
      await _until(
        tester,
        () =>
            read.evaluate().isNotEmpty &&
            find.text('Other reading $nonce').evaluate().isNotEmpty,
      );
      // A→B→A reload retains the same path but produces new line identities.
      app.switchToStudyTraining(path: source.path);
      await _until(
        tester,
        () =>
            read.evaluate().isNotEmpty &&
            find.text('Read practice $nonce').evaluate().isNotEmpty,
      );
      staleRead();
      expect(app.currentMode, AppMode.repertoireTrainer);
      await tester.tap(read);
      final lifetime = tester
          .element(find.byType(AppModeSwitcher).first)
          .read<PgnViewerLifetime>();
      await _until(
        tester,
        () =>
            lifetime.document.collection.games.length == 2 &&
            !lifetime.document.isLoading,
      );
      expect(app.currentMode, AppMode.pgnViewer);
      expect(lifetime.document.filePath, isNull);
      expect(lifetime.document.errorMessage, isNull);
      expect(
        lifetime.document.collection.games.map((g) => g.headers['Event']),
        ['First reading', 'Second reading'],
      );
      expect(await source.readAsString(), original);
      final cache = File(
        '${(await AppPaths.documentsDirectory()).path}/cache/'
        'trainer-reading/Read practice $nonce.pgn',
      );
      expect(await cache.exists(), isFalse);

      lifetime.document.persistMoveCommentsFor(
        lifetime.document.collection.games.first,
        '1. e4 {Independent reading edit} e5 2. Nf3 Nc6 *',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('pgn-save-recovery')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('document-save-copy')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('pgn-copy-directory')),
        root.path,
      );
      await tester.enterText(
        find.byKey(const ValueKey('pgn-copy-name')),
        'Reading copy $nonce',
      );
      await tester.tap(find.byKey(const ValueKey('pgn-copy-confirm')));
      await _until(
        tester,
        () => copy.existsSync() && lifetime.document.filePath == copy.path,
      );
      expect(await copy.readAsString(), contains('Independent reading edit'));
      expect(await source.readAsString(), original);
      await tester.tap(find.widgetWithText(TextButton, 'Close').last);
      await tester.pumpAndSettle();
      app.setMode(AppMode.repertoireTrainer);
      await _until(
        tester,
        () => find.byType(TrainerBrowser).evaluate().isNotEmpty,
      );
      expect(find.text('Read practice $nonce'), findsWidgets);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
}
