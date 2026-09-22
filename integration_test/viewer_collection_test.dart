import 'dart:io';

import 'package:chess_auto_prep/app/pgn_viewer_lifetime.dart';
import 'package:chess_auto_prep/core/app_state.dart';
import 'package:chess_auto_prep/main.dart';
import 'package:chess_auto_prep/models/pgn_filter_models.dart';
import 'package:chess_auto_prep/services/storage/app_paths.dart';
import 'package:chess_auto_prep/widgets/app_mode_switcher.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> waitFor(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 200 && !ready(); i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(ready(), isTrue);
  await tester.pumpAndSettle();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native Viewer keeps file order while sorting, navigating, returning and reopening',
    (tester) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('pgn_viewer.auto_detect_openings', false);
      await prefs.remove('pgn_viewer.last_file');
      final root = await Directory(
        '${(await AppPaths.documentsDirectory()).path}/viewer-collection-${DateTime.now().microsecondsSinceEpoch}',
      ).create();
      final file = File('${root.path}/Collection journey.pgn');
      const original =
          '; Keep source order and bytes\n\n'
          '[Event "Oldest"]\n[White "Alice"]\n[Black "Bob"]\n[Date "2020.01.01"]\n\n1. e4 e5 *\n\n'
          '[Event "Newest"]\n[White "Carol"]\n[Black "Dan"]\n[Date "2026.01.01"]\n\n1. d4 d5 *\n\n'
          '[Event "Middle"]\n[White "Eve"]\n[Black "Frank"]\n[Date "2023.01.01"]\n\n1. c4 e5 *\n';
      await file.writeAsString(original);
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
      await tester.pumpAndSettle();
      final first = context.read<PgnViewerLifetime>();
      final controller = first.document;
      await controller.loadFile(file.path);
      await tester.pumpAndSettle();
      final fileOrder = controller.collection.games;
      final previousView = controller.collection.visibleGames;
      controller.setSortMode(GameSortMode.dateDesc);
      await tester.pumpAndSettle();
      expect(
        controller.collection.visibleGames.map((g) => g.headers['Event']),
        ['Newest', 'Middle', 'Oldest'],
      );
      expect(previousView.map((g) => g.headers['Event']), [
        'Oldest',
        'Newest',
        'Middle',
      ]);
      expect(controller.collection.games, same(fileOrder));
      controller.applySlice([0, 2], const SliceConfig.empty());
      await tester.pumpAndSettle();
      expect(
        controller.collection.visibleGames.map((g) => g.headers['Event']),
        ['Middle', 'Oldest'],
      );
      controller.resetFilters();
      await tester.pumpAndSettle();
      expect(
        controller.collection.visibleGames.map((g) => g.headers['Event']),
        ['Newest', 'Middle', 'Oldest'],
      );
      await tester.tap(find.byTooltip(RegExp(r'^Next game')).first);
      await tester.pumpAndSettle();
      expect(controller.collection.selectedIndex, 1);
      await tester.tap(find.byTooltip(RegExp(r'^Forward')).first);
      await tester.pumpAndSettle();
      expect(first.reader.mainLineIndex, 1);
      expect(first.reader.currentFen, contains('2P5'));
      final back = controller.captureNavigationContext();
      await controller.loadPgnContent('[Event "Temporary"]\n\n1. Nf3 *');
      await tester.pumpAndSettle();
      expect(await back(), isTrue);
      await tester.pumpAndSettle();
      expect(controller.collection.selectedIndex, 1);
      expect(
        controller.collection.visibleGames.map((g) => g.headers['Event']),
        ['Newest', 'Middle', 'Oldest'],
      );
      expect(first.reader.mainLineIndex, 1);
      await controller.reading.saveSession();
      expect(await file.readAsString(), original);
      await tester.pumpWidget(const SizedBox.shrink());
      await first.shutdown();
      await tester.pumpAndSettle();

      await tester.pumpWidget(const ChessAutoPrepApp());
      await tester.pumpAndSettle();
      final nextContext = tester.element(find.byType(AppModeSwitcher).first);
      nextContext.read<AppState>().setMode(AppMode.pgnViewer);
      final next = nextContext.read<PgnViewerLifetime>();
      await waitFor(
        tester,
        () =>
            next.document.filePath == file.path &&
            next.reader.mainLineIndex == 1,
      );
      expect(next.document.collection.sortMode, GameSortMode.dateDesc);
      expect(next.document.collection.selectedIndex, 1);
      expect(
        next.document.collection.visibleGames.map((g) => g.headers['Event']),
        ['Newest', 'Middle', 'Oldest'],
      );
      expect(next.document.collection.games.map((g) => g.headers['Event']), [
        'Oldest',
        'Newest',
        'Middle',
      ]);
      expect(await file.readAsString(), original);
      await tester.pumpWidget(const SizedBox.shrink());
      await next.shutdown();
      await tester.pumpAndSettle();
    },
  );
}
