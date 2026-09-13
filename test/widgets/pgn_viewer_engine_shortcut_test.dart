import 'dart:io';

import 'package:chess_auto_prep/core/app_state.dart';
import 'package:chess_auto_prep/screens/pgn_viewer_screen.dart';
import 'package:chess_auto_prep/services/engine/engine_lifecycle.dart';
import 'package:chess_auto_prep/widgets/engine/inline_engine_bar.dart';
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
            return {'text': '[White "A"]\n[Black "B"]\n\n1. e4 e5 *'};
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

  for (final initiallyEnabled in [false, true]) {
    testWidgets(
      'E reveals the hidden engine (enabled: $initiallyEnabled), then stops without hiding',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1280, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final app = AppState()..setMode(AppMode.pgnViewer);
        addTearDown(app.dispose);
        if (initiallyEnabled) await EngineLifecycle.instance.toggleOn();
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
        expect(find.byType(InlineEngineBar), findsNothing);

        await tester.sendKeyEvent(LogicalKeyboardKey.keyE);
        await tester.pumpAndSettle();
        expect(find.byType(InlineEngineBar), findsOneWidget);
        expect(InlineEngineBar.isEngineEnabled, isTrue);
        expect(find.byTooltip('Toggle engine (E)'), findsOneWidget);

        await tester.sendKeyEvent(LogicalKeyboardKey.keyE);
        await tester.pumpAndSettle();
        expect(InlineEngineBar.isEngineEnabled, isFalse);
        expect(find.byType(InlineEngineBar), findsOneWidget);

        await tester.sendKeyEvent(LogicalKeyboardKey.keyE);
        await tester.pumpAndSettle();
        expect(InlineEngineBar.isEngineEnabled, isTrue);
        expect(find.byType(InlineEngineBar), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
      timeout: const Timeout(Duration(seconds: 20)),
    );
  }
}
