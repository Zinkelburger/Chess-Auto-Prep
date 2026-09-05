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
  VoidCallback? onBuildByPlaying,
  VoidCallback? onBuildFromGames,
  VoidCallback? onImportPgn,
}) async {
  tester.view.physicalSize = const Size(1600, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final appState = AppState();
  addTearDown(appState.dispose);

  await tester.pumpWidget(
    ChangeNotifierProvider<AppState>.value(
      value: appState,
      child: MaterialApp(
        home: Scaffold(
          appBar: RepertoireToolbar(
            title: const Text('Test'),
            showTrainAction: onTrain != null,
            generationLocked: generationLocked,
            onOpenSettings: () {},
            onTrainRepertoire: onTrain,
            onOpenAudit: onOpenAudit,
            onPlanBuild: onPlanBuild,
            onOpenGeneration: onGenerate,
            onBuildByPlaying: onBuildByPlaying,
            onBuildFromGames: onBuildFromGames,
            onImportPgn: onImportPgn,
            isWhiteRepertoire: true,
            onOpenRepertoireOptions: () {},
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
      'the overflow holds the two settings dialogs and nothing else',
      (tester) async {
        await _pump(tester, onOpenAudit: () {}, onTrain: () {});

        await tester.tap(find.byIcon(Icons.more_vert));
        await tester.pumpAndSettle();

        expect(find.text('Repertoire settings…'), findsOneWidget);
        expect(find.text('App settings…'), findsOneWidget);
        expect(find.text('Audit for gaps…'), findsNothing);
        expect(find.text('Train this chapter'), findsNothing);
      },
    );
  });

  group('Actions menu', () {
    testWidgets('groups its rows under Add lines, Train and Check', (
      tester,
    ) async {
      await _pump(
        tester,
        onPlanBuild: () {},
        onGenerate: () {},
        onBuildByPlaying: () {},
        onBuildFromGames: () {},
        onImportPgn: () {},
        onTrain: () {},
        onOpenAudit: () {},
      );
      await _openActions(tester);

      expect(find.text('ADD LINES'), findsOneWidget);
      expect(find.text('Plan the lines…'), findsOneWidget);
      expect(find.text('Generate from here…'), findsOneWidget);
      expect(find.text('Play the moves myself…'), findsOneWidget);
      expect(find.text('From my games…'), findsOneWidget);
      // File and paste are one entry: the dialog it opens offers both.
      expect(find.text('From a PGN…'), findsOneWidget);
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

      expect(find.text('ADD LINES'), findsOneWidget);
      expect(find.text('Plan the lines…'), findsOneWidget);
      expect(find.text('From my games…'), findsNothing);
      expect(find.text('TRAIN'), findsNothing);
      expect(find.text('CHECK'), findsNothing);
    });

    testWidgets('picking a row runs that row', (tester) async {
      final ran = <String>[];
      await _pump(
        tester,
        onPlanBuild: () => ran.add('plan'),
        onBuildByPlaying: () => ran.add('play'),
        onTrain: () => ran.add('train'),
        onOpenAudit: () => ran.add('audit'),
      );

      await _openActions(tester);
      await tester.tap(find.text('Play the moves myself…'));
      await tester.pumpAndSettle();
      await _openActions(tester);
      await tester.tap(find.text('Train this chapter'));
      await tester.pumpAndSettle();
      await _openActions(tester);
      await tester.tap(find.text('Audit for gaps…'));
      await tester.pumpAndSettle();

      expect(ran, ['play', 'train', 'audit']);
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

    testWidgets('the menu disappears entirely when nothing is wired', (
      tester,
    ) async {
      await _pump(tester);

      expect(find.text('Actions'), findsNothing);
    });
  });
}
