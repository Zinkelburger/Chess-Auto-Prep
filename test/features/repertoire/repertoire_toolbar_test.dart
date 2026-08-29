import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:chess_auto_prep/core/app_state.dart';
import 'package:chess_auto_prep/features/repertoire/widgets/repertoire_toolbar.dart';

/// Pumps the toolbar alone, wide enough that it renders its labelled buttons
/// rather than the compact icon-only variants.
Future<void> _pump(
  WidgetTester tester, {
  VoidCallback? onOpenAudit,
  VoidCallback? onTrain,
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
            showTrainButton: onTrain != null,
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('bar', () {
    testWidgets('Add lines and Train are the only actions with labels', (
      tester,
    ) async {
      await _pump(
        tester,
        onTrain: () {},
        onOpenAudit: () {},
        onPlanBuild: () {},
      );

      expect(find.text('Add lines'), findsOneWidget);
      expect(find.text('Train'), findsOneWidget);
    });

    testWidgets('Audit is in the overflow, not a button of its own', (
      tester,
    ) async {
      var audited = false;
      await _pump(tester, onOpenAudit: () => audited = true);

      expect(find.text('Audit'), findsNothing);

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Audit for gaps…'));
      await tester.pumpAndSettle();

      expect(audited, isTrue);
    });

    testWidgets('the overflow keeps both settings dialogs', (tester) async {
      await _pump(tester, onOpenAudit: () {});

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();

      expect(find.text('Repertoire settings…'), findsOneWidget);
      expect(find.text('App settings…'), findsOneWidget);
    });
  });

  group('Add lines menu', () {
    Future<void> openMenu(WidgetTester tester) async {
      await tester.tap(find.text('Add lines'));
      await tester.pumpAndSettle();
    }

    testWidgets('offers every way of adding lines, labels only', (
      tester,
    ) async {
      await _pump(
        tester,
        onPlanBuild: () {},
        onGenerate: () {},
        onBuildByPlaying: () {},
        onBuildFromGames: () {},
        onImportPgn: () {},
      );
      await openMenu(tester);

      expect(find.text('Plan the lines…'), findsOneWidget);
      expect(find.text('Generate from here…'), findsOneWidget);
      expect(find.text('Play the moves myself…'), findsOneWidget);
      expect(find.text('From my games…'), findsOneWidget);
      // File and paste are one entry: the dialog it opens offers both.
      expect(find.text('From a PGN…'), findsOneWidget);
      expect(find.text('Paste PGN…'), findsNothing);

      // No explaining sentence under any of them — the labels stand alone.
      expect(find.textContaining('Answer a few forks'), findsNothing);
      expect(find.textContaining('the app answers'), findsNothing);
      expect(find.textContaining('Mine lines'), findsNothing);
    });

    testWidgets('an unwired entry is left out rather than shown dead', (
      tester,
    ) async {
      await _pump(tester, onPlanBuild: () {}, onGenerate: () {});
      await openMenu(tester);

      expect(find.text('Plan the lines…'), findsOneWidget);
      expect(find.text('From my games…'), findsNothing);
      expect(find.text('From a PGN…'), findsNothing);
    });

    testWidgets('picking an entry runs that entry', (tester) async {
      var played = false;
      await _pump(
        tester,
        onPlanBuild: () {},
        onBuildByPlaying: () => played = true,
      );
      await openMenu(tester);
      await tester.tap(find.text('Play the moves myself…'));
      await tester.pumpAndSettle();

      expect(played, isTrue);
    });

    testWidgets('the menu disappears entirely when nothing is wired', (
      tester,
    ) async {
      await _pump(tester, onOpenAudit: () {});

      expect(find.text('Add lines'), findsNothing);
    });
  });
}
