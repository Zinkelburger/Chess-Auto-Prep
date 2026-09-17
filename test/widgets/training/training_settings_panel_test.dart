import 'package:chess_auto_prep/infrastructure/training/preferences_training_settings.dart';
import 'package:chess_auto_prep/features/training/models/training_settings.dart';
import 'package:chess_auto_prep/widgets/training/training_settings_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> mount(
    WidgetTester tester,
    TrainingSettings settings, {
    Size size = const Size(1100, 850),
    VoidCallback? changeSide,
    ValueChanged<bool?>? selectSide,
    VoidCallback? grouping,
    bool declined = false,
  }) async {
    tester.view.resetPhysicalSize();
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var repetition = RepetitionMode.spaced;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => TrainingSettingsPanel(
              saveSettings: () => PreferencesTrainingSettings().save(settings),
              settings: settings,
              trainingMode: TrainingMode.repertoire,
              repetitionMode: repetition,
              onSettingsChanged: () => setState(() {}),
              onQueueSettingsChanged: () {},
              onTrainingModeChanged: (_) {},
              onRepetitionModeChanged: (v) => setState(() => repetition = v),
              playingWhite: false,
              onChangePlayingSide: changeSide,
              onPlayingSideChanged: selectSide,
              onOpenChapterSetup: grouping,
              chaptersDeclined: declined,
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('one training form edits learning and session preferences', (
    tester,
  ) async {
    final settings = TrainingSettings()..newLinesPerSession = 20;
    await mount(tester, settings);
    expect(find.byKey(const Key('training-settings-nav-0')), findsNothing);
    await tester.enterText(find.byKey(const ValueKey('New lines')), '12');
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Train the whole line'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Train the whole line'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const Key('training-depth')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.enterText(find.byKey(const Key('training-depth')), '8');
    await tester.pumpAndSettle();
    expect((await PreferencesTrainingSettings().load()).newLinesPerSession, 12);
    expect((await PreferencesTrainingSettings().load()).trainingDepth, 8);
    expect(tester.takeException(), isNull);
  });

  testWidgets('session limits have an explicit unlimited choice', (
    tester,
  ) async {
    final settings = TrainingSettings()..newLinesPerSession = 20;
    await mount(tester, settings, size: const Size(540, 850));
    await tester.tap(find.text('Unlimited new lines'));
    await tester.pumpAndSettle();
    expect(settings.newLinesPerSession, 0);
    expect(find.byKey(const ValueKey('New lines')), findsNothing);
    await tester.tap(find.text('Unlimited new lines'));
    await tester.pumpAndSettle();
    expect(settings.newLinesPerSession, greaterThan(0));
    expect(find.byKey(const ValueKey('New lines')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('playing side is a direct choice with no dialog', (tester) async {
    bool? chosen;
    await mount(
      tester,
      TrainingSettings(),
      selectSide: (value) => chosen = value,
    );
    await tester.scrollUntilVisible(
      find.text('You play Black'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('From file'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('White').last);
    await tester.pumpAndSettle();
    expect(chosen, isTrue);
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
