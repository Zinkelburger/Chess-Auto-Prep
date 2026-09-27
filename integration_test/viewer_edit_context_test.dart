import 'dart:io';

import 'package:chess_auto_prep/app/pgn_viewer_lifetime.dart';
import 'package:chess_auto_prep/core/app_state.dart';
import 'package:chess_auto_prep/features/documents/models/pgn_document.dart';
import 'package:chess_auto_prep/features/documents/models/viewer_perspective.dart';
import 'package:chess_auto_prep/main.dart';
import 'package:chess_auto_prep/services/storage/app_paths.dart';
import 'package:chess_auto_prep/widgets/app_mode_switcher.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native navigation preserves drill exclusions, save baselines and copies',
    (tester) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('pgn_viewer.auto_detect_openings', false);
      await prefs.remove('pgn_viewer.last_file');
      final root = await Directory(
        '${(await AppPaths.documentsDirectory()).path}/viewer-edit-context-${DateTime.now().microsecondsSinceEpoch}',
      ).create();
      final source = File('${root.path}/Navigation edits.pgn');
      final copy = File('${root.path}/Saved copy.pgn');
      const second =
          '[Event "Untouched"]\n[White "C"]\n[Black "D"]\n\n1. d4 {keep this} d5 *\n';
      const original =
          '; Preserve this banner\n\n'
          '[Event "Drill"]\n[White "A"]\n[Black "B"]\n\n1. e4 e5 *\n\n$second';
      await source.writeAsString(original);
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await tester.pumpWidget(const ChessAutoPrepApp());
      await tester.pumpAndSettle();
      final context = tester.element(find.byType(AppModeSwitcher).first);
      context.read<AppState>().setMode(AppMode.pgnViewer);
      final lifetime = context.read<PgnViewerLifetime>();
      final controller = lifetime.document;
      await controller.loadFile(source.path);
      await tester.pumpAndSettle();
      final game = controller.collection.games.first;
      controller.persistMoveCommentsFor(
        game,
        '1. e4 {drill-only} e5 *',
        writeToFile: false,
      );
      await tester.pumpAndSettle();
      final back = controller.captureNavigationContext();
      await controller.loadPgnContent('[Event "Temporary"]\n\n1. Nf3 *');
      await tester.pumpAndSettle();
      expect(await back(), isTrue);
      await tester.pumpAndSettle();
      expect(game.pgnText, contains('drill-only'));
      expect(
        controller.editor.snapshotForSave()[game],
        isNot(contains('drill-only')),
      );
      expect(await source.readAsString(), original);

      controller.setPerspective(const Perspective(mode: PerspectiveMode.black));
      await controller.editor.flushPendingMetadata();
      await tester.pumpAndSettle();
      final savedSource = await source.readAsString();
      expect(savedSource, startsWith('; Preserve this banner'));
      expect(savedSource, contains(second));
      expect(savedSource, contains('[StudyPerspective "black"]'));
      expect(savedSource, isNot(contains('drill-only')));
      expect(controller.editor.hasUnsavedChanges, isFalse);
      expect(await controller.editor.saveCopy(copy.path), isA<PgnSaved>());
      await tester.pumpAndSettle();
      expect(await copy.readAsString(), isNot(contains('drill-only')));
      expect(await copy.readAsString(), contains(second));
      expect(await source.readAsString(), savedSource);
      expect(controller.filePath, copy.path);
      await controller.reading.saveSession();
      await tester.pumpWidget(const SizedBox.shrink());
      await lifetime.shutdown();
      await tester.pumpAndSettle();

      await tester.pumpWidget(const ChessAutoPrepApp());
      await tester.pumpAndSettle();
      final nextContext = tester.element(find.byType(AppModeSwitcher).first);
      nextContext.read<AppState>().setMode(AppMode.pgnViewer);
      final next = nextContext.read<PgnViewerLifetime>();
      for (var i = 0; i < 200 && next.document.filePath != copy.path; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.pumpAndSettle();
      expect(next.document.filePath, copy.path);
      expect(
        next.document.collection.games.first.pgnText,
        isNot(contains('drill-only')),
      );
      expect(next.document.presentation.boardFlipped, isTrue);
      await tester.tap(find.byTooltip(RegExp(r'^Next game')).first);
      await tester.pumpAndSettle();
      expect(next.document.collection.selectedIndex, 1);
      expect(
        next.document.collection.visibleGames[1].pgnText,
        contains('keep this'),
      );
      expect(await source.readAsString(), savedSource);
      await tester.pumpWidget(const SizedBox.shrink());
      await next.shutdown();
      await tester.pumpAndSettle();
    },
  );
}
