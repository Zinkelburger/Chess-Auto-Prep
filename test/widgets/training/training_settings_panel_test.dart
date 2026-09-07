import 'package:chess_auto_prep/models/training_settings.dart';
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
              settings: settings,
              trainingMode: TrainingMode.repertoire,
              repetitionMode: repetition,
              onSettingsChanged: () => setState(() {}),
              onQueueSettingsChanged: () {},
              onTrainingModeChanged: (_) {},
              onRepetitionModeChanged: (v) => setState(() => repetition = v),
              playingWhite: false,
              onChangePlayingSide: changeSide,
              onOpenChapterSetup: grouping,
              chaptersDeclined: declined,
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('settings show one category and retain edits across categories', (
    tester,
  ) async {
    final settings = TrainingSettings();
    await mount(tester, settings);
    expect(find.text('New lines'), findsOneWidget);
    expect(find.text('Drill depth'), findsNothing);
    expect(find.text('Change side…'), findsNothing);
    await tester.enterText(find.byKey(const ValueKey('New lines')), '12');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('training-settings-nav-1')));
    await tester.pumpAndSettle();
    expect(find.text('New lines'), findsNothing);
    await tester.enterText(find.byKey(const Key('training-depth')), '8');
    await tester.pumpAndSettle();
    expect((await TrainingSettings.load()).trainingDepth, 8);
    await tester.tap(find.byKey(const Key('training-settings-nav-0')));
    await tester.pumpAndSettle();
    expect(find.text('12'), findsOneWidget);
    expect((await TrainingSettings.load()).newLinesPerSession, 12);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'material exposes colour and explicit grouping without extra menus',
    (tester) async {
      var side = 0;
      var grouping = 0;
      await mount(
        tester,
        TrainingSettings(),
        changeSide: () => side++,
        grouping: () => grouping++,
      );
      await tester.tap(find.byKey(const Key('training-settings-nav-3')));
      await tester.pumpAndSettle();
      expect(find.text('You play Black'), findsOneWidget);
      await tester.tap(find.text('Change side…'));
      await tester.tap(find.text('Preview chapter grouping…'));
      expect(side, 1);
      expect(grouping, 1);
      expect(find.text('Name separator'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'narrow settings use a section picker and one pass hides session limits',
    (tester) async {
      await mount(tester, TrainingSettings(), size: const Size(540, 850));
      expect(
        find.byKey(const Key('training-settings-section')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('training-settings-nav-0')), findsNothing);
      await tester.tap(find.text('Spaced repetition'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('One pass').last);
      await tester.pumpAndSettle();
      expect(find.text('Session size'), findsNothing);
      await tester.tap(find.byKey(const Key('training-settings-section')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Playback').last);
      await tester.pumpAndSettle();
      expect(find.text('Wait for Next'), findsOneWidget);
      expect(find.text('Review schedule'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
