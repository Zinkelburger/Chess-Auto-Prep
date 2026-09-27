import '../../support/runtime_settings.dart';
import 'package:chess_auto_prep/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:chess_auto_prep/core/app_state.dart';
import 'package:chess_auto_prep/features/repertoire/widgets/repertoire_toolbar.dart';

/// Pumps the toolbar alone, at a desktop width.
Future<void> _pump(
  WidgetTester tester, {
  VoidCallback? onOpenAudit,
  VoidCallback? onTrain,
  bool generationLocked = false,
  VoidCallback? onPlanBuild,
  VoidCallback? onGenerate,
  VoidCallback? onImportPgn,
  VoidCallback? onReload,
  VoidCallback? onChoose,
}) async {
  tester.view.physicalSize = const Size(1600, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final appState = AppState();
  addTearDown(appState.dispose);

  final settings = testRuntimeSettings();
  addTearDown(settings.dispose);
  await pumpRuntimeWidget(
    tester,
    settings,
    ChangeNotifierProvider<AppState>.value(
      value: appState,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          appBar: RepertoireToolbar(
            title: const Text('Test'),
            showTrainAction: onTrain != null,
            generationLocked: generationLocked,
            onSettingsClosed: () {},
            onTrainRepertoire: onTrain,
            onOpenAudit: onOpenAudit,
            onPlanBuild: onPlanBuild,
            onOpenGeneration: onGenerate,
            onImportPgn: onImportPgn,
            onReload: onReload,
            onSelectRepertoire: onChoose,
            repertoireSettingsBuilder: (_) => const Text('Repertoire options'),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

Future<void> _openActions(WidgetTester tester) async {
  await tester.tap(find.text('Actions'));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('bar', () {
    testWidgets('Actions is the only labelled control; Train is not a button', (
      tester,
    ) async {
      await _pump(
        tester,
        onTrain: () {},
        onOpenAudit: () {},
        onPlanBuild: () {},
      );

      expect(find.text('Actions'), findsOneWidget);
      expect(find.text('Add lines'), findsNothing);
      expect(find.text('Train'), findsNothing);
      expect(find.byType(FilledButton), findsNothing);
    });

    testWidgets(
      'the gear opens view settings with access to global preferences',
      (tester) async {
        await _pump(tester, onOpenAudit: () {}, onTrain: () {});

        await tester.tap(find.byTooltip('Settings'));
        await tester.pumpAndSettle();

        expect(find.text('Repertoire options'), findsOneWidget);
        expect(find.byKey(const Key('settings-navigation')), findsOneWidget);
        expect(find.byKey(const Key('settings-nav-3')), findsOneWidget);
        expect(find.byKey(const Key('settings-view-tactics')), findsOneWidget);
        expect(find.byIcon(Icons.more_vert), findsNothing);
        expect(find.text('Audit for gaps…'), findsNothing);
        expect(find.text('Train this chapter'), findsNothing);
      },
    );
  });

  group('Actions menu', () {
    testWidgets('library action keeps the empty builder navigable', (
      tester,
    ) async {
      var chosen = false;
      await _pump(tester, onChoose: () => chosen = true);
      await _openActions(tester);
      expect(find.text('LIBRARY'), findsOneWidget);
      await tester.tap(find.text('Choose repertoire…'));
      await tester.pumpAndSettle();
      expect(chosen, isTrue);
    });

    testWidgets('groups its rows under Generate, Import, Train and Check', (
      tester,
    ) async {
      await _pump(
        tester,
        onPlanBuild: () {},
        onGenerate: () {},
        onImportPgn: () {},
        onTrain: () {},
        onOpenAudit: () {},
      );
      await _openActions(tester);

      expect(find.text('GENERATE'), findsOneWidget);
      expect(find.text('Plan the lines…'), findsOneWidget);
      expect(find.text('Generate from here…'), findsOneWidget);
      // Both folded into the planner: moves played on the board at a
      // question, and the "My games" walk.
      expect(find.text('Play the moves myself…'), findsNothing);
      expect(find.text('From my games…'), findsNothing);
      expect(find.text('ADD LINES'), findsNothing);

      expect(find.text('IMPORT'), findsOneWidget);
      // File and paste are one entry: the dialog it opens offers both.
      expect(find.text('Import PGN…'), findsOneWidget);
      expect(find.text('Paste PGN…'), findsNothing);

      expect(find.text('TRAIN'), findsOneWidget);
      expect(find.text('Train this chapter'), findsOneWidget);

      expect(find.text('CHECK'), findsOneWidget);
      expect(find.text('Audit for gaps…'), findsOneWidget);

      // No explaining sentence under any of them — the labels stand alone.
      expect(find.textContaining('Answer a few forks'), findsNothing);
      expect(find.textContaining('the app answers'), findsNothing);
      expect(find.textContaining('Mine lines'), findsNothing);
    });

    testWidgets('an empty group vanishes with its heading', (tester) async {
      await _pump(tester, onPlanBuild: () {}, onGenerate: () {});
      await _openActions(tester);

      expect(find.text('GENERATE'), findsOneWidget);
      expect(find.text('Plan the lines…'), findsOneWidget);
      expect(find.text('IMPORT'), findsNothing);
      expect(find.text('TRAIN'), findsNothing);
      expect(find.text('CHECK'), findsNothing);
    });

    testWidgets('picking a row runs that row', (tester) async {
      final ran = <String>[];
      await _pump(
        tester,
        onPlanBuild: () => ran.add('plan'),
        onGenerate: () => ran.add('generate'),
        onTrain: () => ran.add('train'),
        onOpenAudit: () => ran.add('audit'),
      );

      await _openActions(tester);
      await tester.tap(find.text('Generate from here…'));
      await tester.pumpAndSettle();
      await _openActions(tester);
      await tester.tap(find.text('Train this chapter'));
      await tester.pumpAndSettle();
      await _openActions(tester);
      await tester.tap(find.text('Audit for gaps…'));
      await tester.pumpAndSettle();

      expect(ran, ['generate', 'train', 'audit']);
    });

    testWidgets('import and disk refresh remain accessible from Actions', (
      tester,
    ) async {
      final ran = <String>[];
      await _pump(
        tester,
        onImportPgn: () => ran.add('import'),
        onReload: () => ran.add('reload'),
      );
      expect(find.text('Import PGN…'), findsNothing);
      expect(find.text('Check disk for changes'), findsNothing);
      await _openActions(tester);
      await tester.tap(find.text('Import PGN…'));
      await tester.pumpAndSettle();
      await _openActions(tester);
      await tester.tap(find.text('Check disk for changes'));
      await tester.pumpAndSettle();
      expect(ran, ['import', 'reload']);
    });

    testWidgets('Train waits while a build runs; adding lines does not', (
      tester,
    ) async {
      var trained = false;
      await _pump(
        tester,
        generationLocked: true,
        onPlanBuild: () {},
        onTrain: () => trained = true,
      );
      await _openActions(tester);
      await tester.tap(find.text('Train this chapter'));
      await tester.pumpAndSettle();

      expect(trained, isFalse);
    });

    testWidgets('the empty builder keeps settings accessible in its menu', (
      tester,
    ) async {
      await _pump(tester);

      await _openActions(tester);
      expect(find.text('Settings…'), findsOneWidget);
      expect(find.text('Import PGN…'), findsNothing);
      await tester.tap(find.text('Settings…'));
      await tester.pumpAndSettle();
      expect(find.text('Repertoire options'), findsOneWidget);
      expect(find.byTooltip('Close settings (Esc)'), findsOneWidget);
    });
  });
}
