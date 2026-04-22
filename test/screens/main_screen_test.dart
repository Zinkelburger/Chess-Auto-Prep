import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
        ChangeNotifierProvider<AppState>.value(
          value: appState,
          child: const MaterialApp(home: MainScreen()),
        ),
      );
      await pumpNavigation();

      expect(find.text('Select Player to Analyze'), findsNothing);

      appState.setMode(AppMode.positionAnalysis);
      await pumpNavigation();
      expect(find.text('Select Player to Analyze'), findsOneWidget);

      await tester.tap(find.byTooltip('Back'));
      await pumpNavigation();
      expect(find.text('No Player Selected'), findsOneWidget);

      appState.setMode(AppMode.tactics);
      await pumpNavigation();
      appState.setMode(AppMode.positionAnalysis);
      await pumpNavigation();

      expect(find.text('Select Player to Analyze'), findsNothing);
      expect(find.text('No Player Selected'), findsOneWidget);
    },
  );
}
