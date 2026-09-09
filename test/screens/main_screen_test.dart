import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chess_auto_prep/core/app_history.dart';
import 'package:chess_auto_prep/core/app_state.dart';
import 'package:chess_auto_prep/screens/main_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets(
    'analysis screen is created lazily and kept alive across mode switches',
    (tester) async {
      final appState = AppState();

      Future<void> pumpNavigation() async {
        // First visit shows a one-frame loading placeholder, then constructs
        // the screen on the next frame (see _MainScreenState.build) — hence
        // the extra pump before the navigation-animation pumps.
        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump(const Duration(milliseconds: 300));
      }

      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<AppState>.value(value: appState),
            ChangeNotifierProvider<AppHistory>(
              lazy: false,
              create: (_) => AppHistory(appState),
            ),
          ],
          child: const MaterialApp(home: MainScreen()),
        ),
      );
      await pumpNavigation();

      expect(find.text('Which player?'), findsNothing);

      appState.setMode(AppMode.positionAnalysis);
      await pumpNavigation();
      expect(find.text('Which player?'), findsOneWidget);
      // Both former primary modifiers must leave the current mode alone.
      for (final modifier in [
        LogicalKeyboardKey.controlLeft,
        LogicalKeyboardKey.metaLeft,
      ]) {
        await tester.sendKeyDownEvent(modifier);
        await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
        await tester.sendKeyUpEvent(modifier);
        await pumpNavigation();
        expect(appState.currentMode, AppMode.positionAnalysis);
      }

      // Picking material stays inside this mode, beneath the app controls.
      expect(find.byTooltip('Settings').hitTestable(), findsOneWidget);
      expect(find.text('Actions').hitTestable(), findsOneWidget);
      expect(find.text('No player selected'), findsNothing);

      appState.setMode(AppMode.tactics);
      await pumpNavigation();
      appState.setMode(AppMode.positionAnalysis);
      await pumpNavigation();

      expect(find.text('Which player?'), findsOneWidget);
      expect(find.byTooltip('Settings').hitTestable(), findsOneWidget);
    },
  );
}
