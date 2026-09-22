import 'dart:io';

import 'package:chess_auto_prep/app/pgn_viewer_lifetime.dart';
import 'package:chess_auto_prep/core/app_state.dart';
import 'package:chess_auto_prep/main.dart';
import 'package:chess_auto_prep/services/storage/app_paths.dart';
import 'package:chess_auto_prep/widgets/app_mode_switcher.dart';
import 'package:chess_auto_prep/widgets/pgn/pgn_game_filter_workspace.dart';
import 'package:chess_auto_prep/widgets/slice/header_filters.dart';
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
    'native Viewer filters, reopens the selected game, and clears the saved filter without editing PGN',
    (tester) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('pgn_viewer.auto_detect_openings', false);
      await prefs.remove('pgn_viewer.last_file');
      final root = await Directory(
        '${(await AppPaths.documentsDirectory()).path}/viewer-filters-${DateTime.now().microsecondsSinceEpoch}',
      ).create();
      final file = File('${root.path}/Filter journey.pgn');
      const original =
          '; Native filter preservation\n\n'
          '[Event "First"]\n[White "Alice"]\n[Black "Bob"]\n\n1. e4 e5 *\n\n'
          '[Event "Second"]\n[White "Bob"]\n[Black "Alice"]\n\n1. d4 d5 *\n\n'
          '[Event "Third"]\n[White "Alice"]\n[Black "Carol"]\n\n1. c4 e5 *\n';
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
      await first.document.loadFile(file.path);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('add-collection-filter')));
      await tester.pumpAndSettle();
      expect(find.byType(PgnGameFilterWorkspace), findsOneWidget);
      final field = find
          .byWidgetPredicate(
            (widget) =>
                widget is TextField && widget.decoration?.hintText == 'Search…',
          )
          .last;
      await tester.enterText(field, 'White');
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(CompositedTransformFollower),
          matching: find.text('White'),
        ),
      );
      await tester.pumpAndSettle();
      final filters = tester
          .widget<HeaderFilters>(find.byType(HeaderFilters))
          .controller;
      final value = find.byWidgetPredicate(
        (widget) =>
            widget is TextField &&
            identical(widget.controller, filters.headerRows.single.controller),
      );
      await tester.enterText(value, 'Alice');
      final apply = find.byKey(const ValueKey('apply-game-filters'));
      await waitFor(
        tester,
        () => tester.widget<FilledButton>(apply).onPressed != null,
      );
      await tester.tap(apply);
      await tester.pumpAndSettle();
      expect(
        first.document.collection.visibleGames.map((g) => g.headers['Event']),
        ['First', 'Third'],
      );
      expect(
        first.document.filters.selection.config.headerFilters.single.value,
        'Alice',
      );
      first.document.reading.nextGame();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip(RegExp(r'^Forward')).first);
      await tester.pumpAndSettle();
      expect(first.reader.mainLineIndex, 1);
      await first.document.reading.saveSession();
      expect(await file.readAsString(), original);
      await tester.pumpWidget(const SizedBox.shrink());
      await first.shutdown();
      await tester.pumpAndSettle();

      await tester.pumpWidget(const ChessAutoPrepApp());
      await tester.pumpAndSettle();
      final restartedContext = tester.element(
        find.byType(AppModeSwitcher).first,
      );
      restartedContext.read<AppState>().setMode(AppMode.pgnViewer);
      final restarted = restartedContext.read<PgnViewerLifetime>();
      await waitFor(
        tester,
        () =>
            restarted.document.filePath == file.path &&
            restarted.reader.mainLineIndex == 1,
      );
      expect(
        restarted.document.collection.visibleGames.map(
          (g) => g.headers['Event'],
        ),
        ['First', 'Third'],
      );
      expect(restarted.document.collection.selectedIndex, 1);
      expect(
        restarted.document.filters.selection.config.headerFilters.single.value,
        'Alice',
      );
      await tester.tap(find.byTooltip(RegExp(r'^Remove White name')));
      await tester.pumpAndSettle();
      expect(restarted.document.collection.visibleGames, hasLength(3));
      expect(restarted.document.filters.selection.active, isFalse);
      expect(await restarted.document.preferences.loadSlice(file.path), isNull);
      expect(await file.readAsString(), original);
      await tester.pumpWidget(const SizedBox.shrink());
      await restarted.shutdown();
      await tester.pumpAndSettle();
    },
  );
}
