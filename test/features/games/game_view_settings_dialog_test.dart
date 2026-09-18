import 'package:chess_auto_prep/l10n/generated/app_localizations.dart';
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
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
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
    expect(find.text('Live engine controls'), findsNothing);
    await tester.ensureVisible(find.text('Autosave PGN edits'));
    await tester.tap(find.text('Autosave PGN edits'));
    await tester.pumpAndSettle();
    expect(prefs.autoSave, isFalse);
    await tester.ensureVisible(find.text('Playback controls'));
    await tester.tap(find.text('Playback controls'));
    await tester.pumpAndSettle();
    expect(prefs.playback, isTrue);
    expect(prefs.autoDetectOpenings, isTrue);
    await tester.ensureVisible(
      find.text('Fill missing opening names and ECO codes'),
    );
    await tester.tap(find.text('Fill missing opening names and ECO codes'));
    await tester.pumpAndSettle();
    expect(prefs.autoDetectOpenings, isFalse);
    expect(find.byType(SettingsChoiceTile<double>), findsOneWidget);
    await tester.ensureVisible(find.text('Reset game viewer preferences'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reset game viewer preferences'));
    await tester.pumpAndSettle();
    expect(prefs.autoDetectOpenings, isTrue);
    expect(prefs.graph, isFalse);
    expect(prefs.engine, isFalse);
    expect(prefs.playback, isFalse);
    expect(prefs.autoSave, isTrue);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'reader placement and variation actions work without leaving Settings',
    (tester) async {
      tester.view.physicalSize = const Size(1100, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final actions = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: GameViewSettingsDialog(
              preferences: const GameViewPreferences(),
              onChanged: (_) {},
              onFlip: () {},
              onPerspective: (_) {},
              embedded: true,
              onReadingOptionChanged: actions.add,
            ),
          ),
        ),
      );
      await tester.tap(find.text('Top'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Middle').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Expand variations'));
      await tester.tap(find.text('Fold deep variations'));
      expect(actions, ['0.35', 'expand', 'fold']);
      expect(find.byType(GameViewSettingsDialog), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
