import 'dart:io';

import 'package:chess_auto_prep/core/app_state.dart';
import 'package:chess_auto_prep/screens/pgn_viewer_screen.dart';
import 'package:chess_auto_prep/services/engine/engine_lifecycle.dart';
import 'package:chess_auto_prep/widgets/pgn/pgn_opening_label.dart';
import 'package:chess_auto_prep/widgets/pgn/pgn_annotation_panel.dart';
import 'package:chess_auto_prep/widgets/slice/header_filters.dart';
import 'package:chess_auto_prep/widgets/pgn/pgn_tree_games_list.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/board_engine_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    EngineLifecycle.instance.resetForTest();
    EngineLifecycle.testMode = true;
    useScriptedBoardEngine();
    const windowChannel = MethodChannel('window_manager');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(windowChannel, (_) async => null);
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(windowChannel, null);
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.getData') {
            return {
              'text':
                  '[White "A"]\n[Black "B"]\n[ECO "E94"]\n[Opening "King’s Indian Defense: Orthodox Variation"]\n\n1. d4 Nf6 *',
            };
          }
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });
    final directory = Directory.systemTemp.createTempSync('engine-shortcut-');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => directory.path);
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      directory.deleteSync(recursive: true);
    });
  });
  tearDown(() => EngineLifecycle.instance.resetForTest());

  testWidgets(
    'Actions toggles opening details and enters a clear comment editor',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final app = AppState()..setMode(AppMode.pgnViewer);
      addTearDown(app.dispose);
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: app,
          child: const MaterialApp(home: PgnViewerScreen()),
        ),
      );
      await tester.pumpAndSettle();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 500)),
      );
      await tester.pumpAndSettle();
      expect(find.byType(PgnOpeningLabel), findsNothing);
      expect(find.text('Edit PGN'), findsNothing);
      expect(find.text('PGN'), findsNothing);
      expect(find.text('Main line'), findsNothing);
      await tester.tap(find.text('Actions'));
      await tester.pumpAndSettle();
      expect(find.text('Filter games'), findsOneWidget);
      await tester.tap(find.text('Turn autosave off'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Autosave on'), findsNothing);
      await tester.tap(find.text('Actions'));
      await tester.pumpAndSettle();
      expect(find.text('Turn autosave on'), findsOneWidget);
      await tester.tap(find.text('Filter games'));
      await tester.pumpAndSettle();
      final filters = tester
          .widget<HeaderFilters>(find.byType(HeaderFilters))
          .controller;
      filters.setHeaderField(0, 'White');
      filters.setHeaderValue(0, 'A');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)),
      );
      await tester.pumpAndSettle();
      final results = tester.widget<PgnTreeGamesList>(
        find.byType(PgnTreeGamesList),
      );
      results.onGameSelected(0);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('return-to-filters')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('return-to-filters')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<HeaderFilters>(find.byType(HeaderFilters)).controller,
        same(filters),
      );
      expect(filters.headerRows.single.value, 'A');
      await tester.tap(find.byKey(const ValueKey('apply-game-filters')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('return-to-filters')), findsNothing);
      await tester.tap(find.text('Actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Show opening'));
      await tester.pumpAndSettle();
      expect(
        find.text('King’s Indian Defense: Orthodox Variation (ECO E94)'),
        findsOneWidget,
      );
      expect(
        (await SharedPreferences.getInstance()).getBool(
          'pgn_viewer.show_opening',
        ),
        isTrue,
      );
      await tester.tap(find.text('Actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Hide opening'));
      await tester.pumpAndSettle();
      expect(find.byType(PgnOpeningLabel), findsNothing);
      await tester.tap(find.text('Actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      expect(find.byType(PgnAnnotationPanel), findsOneWidget);
      expect(find.text('Comment:'), findsOneWidget);
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(find.byType(PgnAnnotationPanel), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      // Let cancellation finish if the background FEN-index isolate was still
      // spawning when the reader was disposed.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pumpAndSettle();
    },
  );
}
