import 'package:chess_auto_prep/features/games/models/game_view_preferences.dart';
import 'package:chess_auto_prep/features/games/widgets/game_view_settings_dialog.dart';
import 'package:chess_auto_prep/widgets/settings/settings_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('grouped view choices update immediately and reset together', (
    tester,
  ) async {
    var prefs = const GameViewPreferences();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => GameViewSettingsDialog(
                  preferences: prefs,
                  onChanged: (value) => prefs = value,
                  onFlip: () {},
                  onPerspective: (_) {},
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Analysis overview'));
    await tester.pumpAndSettle();
    expect(prefs.graph, isTrue);
    await tester.tap(find.text('Live engine controls'));
    await tester.pumpAndSettle();
    expect(prefs.engine, isTrue);
    await tester.tap(find.text('Playback controls'));
    await tester.pumpAndSettle();
    expect(prefs.playback, isTrue);
    expect(find.byType(SettingsChoiceTile<double>), findsOneWidget);
    await tester.ensureVisible(find.text('Restore simple defaults'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Restore simple defaults'));
    await tester.pumpAndSettle();
    expect(prefs.graph, isFalse);
    expect(prefs.engine, isFalse);
    expect(prefs.playback, isFalse);
    expect(tester.takeException(), isNull);
  });
}
