import 'package:chess_auto_prep/l10n/generated/app_localizations.dart';
import 'dart:async';
import 'package:chess_auto_prep/features/settings/models/settings_state.dart';
import 'package:chess_auto_prep/features/training/controllers/training_settings_controller.dart';
import '../../support/training_settings.dart';
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
    final owner = TrainingSettingsController(MemoryTrainingSettings(settings));
    addTearDown(owner.dispose);
    await owner.ensureLoaded();
    var repetition = RepetitionMode.spaced;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => TrainingSettingsPanel(
              configuration: owner,
              trainingMode: TrainingMode.repertoire,
              repetitionMode: repetition,
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
    final owner = tester
        .widget<TrainingSettingsPanel>(find.byType(TrainingSettingsPanel))
        .configuration;
    expect(owner.state.committed!.toSettings().newLinesPerSession, 12);
    expect(owner.state.committed!.toSettings().trainingDepth, 8);
    expect(tester.takeException(), isNull);
  });

  testWidgets('session limits have an explicit unlimited choice', (
    tester,
  ) async {
    final settings = TrainingSettings()..newLinesPerSession = 20;
    await mount(tester, settings, size: const Size(540, 850));
    await tester.tap(find.text('Unlimited new lines'));
    await tester.pumpAndSettle();
    final owner = tester
        .widget<TrainingSettingsPanel>(find.byType(TrainingSettingsPanel))
        .configuration;
    expect(owner.state.committed!.toSettings().newLinesPerSession, 0);
    expect(find.byKey(const ValueKey('New lines')), findsNothing);
    await tester.tap(find.text('Unlimited new lines'));
    await tester.pumpAndSettle();
    expect(
      owner.state.committed!.toSettings().newLinesPerSession,
      greaterThan(0),
    );
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
  testWidgets('two panels keep independent edits and expose failure retry', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1500, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final storage = MemoryTrainingSettings(
      TrainingSettings(newLinesPerSession: 20, reviewsPerSession: 40),
    );
    final owner = TrainingSettingsController(storage);
    addTearDown(owner.dispose);
    await owner.ensureLoaded();
    Widget panel(String key, bool active) => Expanded(
      child: TrainingSettingsPanel(
        key: ValueKey(key),
        configuration: owner,
        applyNextSitting: active,
        trainingMode: TrainingMode.repertoire,
        repetitionMode: RepetitionMode.spaced,
        onTrainingModeChanged: (_) {},
        onRepetitionModeChanged: (_) {},
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Row(
            children: [
              panel('first-panel', true),
              panel('second-panel', false),
            ],
          ),
        ),
      ),
    );
    final first = find.byKey(const ValueKey('first-panel'));
    final second = find.byKey(const ValueKey('second-panel'));
    Finder field(Finder panel, String key) =>
        find.descendant(of: panel, matching: find.byKey(ValueKey(key)));
    storage.writeGate = Completer<void>();
    await tester.enterText(field(first, 'New lines'), '12');
    await tester.pump();
    await tester.enterText(field(second, 'Reviews'), '25');
    await tester.pump();
    expect(owner.state.phase, SettingsPhase.saving);
    storage.writeGate!.complete();
    storage.writeGate = null;
    await tester.pumpAndSettle();
    final saved = owner.state.committed!.toSettings();
    expect(saved.newLinesPerSession, 12);
    expect(saved.reviewsPerSession, 25);
    expect(
      tester.widget<TextFormField>(field(second, 'New lines')).controller!.text,
      '12',
    );
    expect(
      tester.widget<TextFormField>(field(first, 'Reviews')).controller!.text,
      '25',
    );
    expect(
      find.text('Saved changes apply to your next sitting.'),
      findsOneWidget,
    );
    storage.failWrites = true;
    await tester.enterText(field(first, 'New lines'), '15');
    await tester.pumpAndSettle();
    expect(find.text('Retry'), findsNWidgets(2));
    expect(owner.state.committed!.toSettings().newLinesPerSession, 12);
    expect(owner.state.draft!.toSettings().newLinesPerSession, 15);
    storage.failWrites = false;
    await tester.tap(find.descendant(of: first, matching: find.text('Retry')));
    await tester.pumpAndSettle();
    expect(find.text('Retry'), findsNothing);
    expect(owner.state.committed!.toSettings().newLinesPerSession, 15);
    expect(tester.takeException(), isNull);
  });

  Widget settingsHost(TrainingSettingsController owner) => MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: TrainingSettingsPanel(
        configuration: owner,
        trainingMode: TrainingMode.repertoire,
        repetitionMode: RepetitionMode.spaced,
        onTrainingModeChanged: (_) {},
        onRepetitionModeChanged: (_) {},
      ),
    ),
  );

  testWidgets(
    'focused drafts survive notifications and owner replacement detaches',
    (tester) async {
      final first = TrainingSettingsController(
        MemoryTrainingSettings(TrainingSettings(newLinesPerSession: 20)),
      );
      final second = TrainingSettingsController(
        MemoryTrainingSettings(TrainingSettings(newLinesPerSession: 35)),
      );
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      await first.ensureLoaded();
      await second.ensureLoaded();
      await tester.pumpWidget(settingsHost(first));
      final field = find.byKey(const ValueKey('New lines'));
      String text() => tester.widget<TextFormField>(field).controller!.text;
      await tester.enterText(field, '-');
      await first.edit({'trainer_new_lines_per_session': 12});
      await tester.pump();
      expect(text(), '-');
      FocusScope.of(tester.element(field)).unfocus();
      await tester.pump();
      expect(text(), '12');

      await tester.pumpWidget(settingsHost(second));
      expect(text(), '35');
      await first.edit({'trainer_new_lines_per_session': 18});
      await tester.pump();
      expect(text(), '35');
      await second.edit({'trainer_new_lines_per_session': 25});
      await tester.pump();
      expect(text(), '25');
      await tester.pumpWidget(const SizedBox());
      await second.edit({'trainer_new_lines_per_session': 30});
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('host owns initial load and panel exposes read failure retry', (
    tester,
  ) async {
    final storage = MemoryTrainingSettings(
      TrainingSettings(newLinesPerSession: 37),
    )..failReads = true;
    final owner = TrainingSettingsController(storage);
    addTearDown(owner.dispose);
    await tester.pumpWidget(settingsHost(owner));
    expect(storage.reads, 0);
    expect(find.text('Loading training settings…'), findsOneWidget);
    await expectLater(owner.ensureLoaded(), throwsStateError);
    await tester.pump();
    expect(owner.state.committed, isNull);
    expect(find.text('Training settings could not be loaded.'), findsOneWidget);
    expect(storage.writes, isEmpty);
    storage.failReads = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('Retry'), findsNothing);
    expect(owner.state.committed!.toSettings().newLinesPerSession, 37);
    expect(
      tester
          .widget<TextFormField>(find.byKey(const ValueKey('New lines')))
          .controller!
          .text,
      '37',
    );
    expect(storage.writes, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
